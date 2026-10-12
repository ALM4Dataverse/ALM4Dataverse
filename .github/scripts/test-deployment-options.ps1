#Requires -Modules powershell-yaml

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$tokens = $null
$parseErrors = $null
$deploymentAst = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $repoRoot 'pipelines/scripts/deploy.ps1'),
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count) {
    throw ($parseErrors | Out-String)
}

$selectionAst = $deploymentAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.ForEachStatementAst] -and
        $node.Variable.VariablePath.UserPath -eq 'solutionConfig'
}, $true)
$serviceAccountAst = $deploymentAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and
        $node.Extent.Text.StartsWith('if ($solution.ContainsKey(''serviceAccountUpnConfigKey'')')
}, $true)
if (-not $selectionAst -or -not $serviceAccountAst) {
    throw 'Deployment option selection blocks not found.'
}

$selection = [scriptblock]::Create($selectionAst.Extent.Text)
$serviceAccountSelection = [scriptblock]::Create($serviceAccountAst.Extent.Text)
$ArtifactsPath = [IO.Path]::GetTempPath()
$testCases = @(
    @{
        Name = 'Missing optional keys'
        Config = @{ name = 'Example' }
        AllUnmanaged = $false
        ExpectedFile = 'Example_managed.zip'
        ExpectedKey = 'DataverseServiceAccountUpn'
    },
    @{
        Name = 'Per-solution unmanaged and service-account overrides'
        Config = @{ name = 'Example'; deployUnmanaged = $true; serviceAccountUpnConfigKey = 'CustomUpn' }
        AllUnmanaged = $false
        ExpectedFile = 'Example.zip'
        ExpectedKey = 'CustomUpn'
    },
    @{
        Name = 'Explicit managed and empty service-account key'
        Config = @{ name = 'Example'; deployUnmanaged = $false; serviceAccountUpnConfigKey = '' }
        AllUnmanaged = $false
        ExpectedFile = 'Example_managed.zip'
        ExpectedKey = 'DataverseServiceAccountUpn'
    },
    @{
        Name = 'Null optional values'
        Config = @{ name = 'Example'; deployUnmanaged = $null; serviceAccountUpnConfigKey = $null }
        AllUnmanaged = $false
        ExpectedFile = 'Example_managed.zip'
        ExpectedKey = 'DataverseServiceAccountUpn'
    },
    @{
        Name = 'IMPORT overrides per-solution managed preference'
        Config = @{ name = 'Example'; deployUnmanaged = $false; serviceAccountUpnConfigKey = 'CustomUpn' }
        AllUnmanaged = $true
        ExpectedFile = 'Example.zip'
        ExpectedKey = 'CustomUpn'
    },
    @{
        Name = 'IMPORT with missing optional keys'
        Config = @{ name = 'Example' }
        AllUnmanaged = $true
        ExpectedFile = 'Example.zip'
        ExpectedKey = 'DataverseServiceAccountUpn'
    }
)

foreach ($testCase in $testCases) {
    $solutionsConfig = @{ solutions = @($testCase.Config) }
    $UseUnmanagedSolutions = $testCase.AllUnmanaged
    $solutions = @()
    . $selection
    if ($solutions.Count -ne 1 -or [IO.Path]::GetFileName($solutions[0].File) -ne $testCase.ExpectedFile) {
        throw "$($testCase.Name): unexpected solution package selection."
    }
    $solution = $solutions[0]
    $serviceAccountUpnKey = $null
    . $serviceAccountSelection
    if ($serviceAccountUpnKey -ne $testCase.ExpectedKey) {
        throw "$($testCase.Name): unexpected service-account key '$serviceAccountUpnKey'."
    }
    Write-Host "PASS: $($testCase.Name)"
}

$solution = @{ Name = 'LegacyEntry'; File = 'LegacyEntry_managed.zip' }
. $serviceAccountSelection
if ($serviceAccountUpnKey -ne 'DataverseServiceAccountUpn') {
    throw 'Missing activation key must use the default service account.'
}
Write-Host 'PASS: Missing activation key'
Write-Host 'All deployment option checks passed under StrictMode Latest; no Dataverse access required.'

$setupAst = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $repoRoot 'setup-github.ps1'), [ref]$tokens, [ref]$parseErrors
)
if ($parseErrors.Count) {
    throw ($parseErrors | Out-String)
}
$generator = $setupAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Update-DeployWorkflowInRepoClone'
}, $true)
if (-not $generator) {
    throw 'Deployment workflow generator not found.'
}
. ([scriptblock]::Create($generator.Extent.Text))

function Merge-SecretsJsonInputs {
    param([string]$ExistingContent, [string]$GeneratedContent)
    if ($ExistingContent) {
        throw 'This test expects a new generated workflow.'
    }
    return $GeneratedContent
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('alm-workflow-test-' + [Guid]::NewGuid().ToString('N'))
try {
    foreach ($mode in @('manual-gate-tag', 'environment-approval')) {
        $modeRoot = Join-Path $testRoot $mode
        Update-DeployWorkflowInRepoClone -RepoRoot $modeRoot -Branch main `
            -DeploymentEnvironments @([pscustomobject]@{ ShortName = 'TEST-main' }, [pscustomobject]@{ ShortName = 'PROD' }) `
            -SharedWorkflowRepository 'ALM4Dataverse/ALM4Dataverse' -SharedWorkflowRef stable -PromotionMode $mode

        $workflow = Get-Content (Join-Path $modeRoot '.github/workflows/DEPLOY-main.yml') -Raw | ConvertFrom-Yaml
        $condition = [string]$workflow.jobs['deploy-prod']['if']
        if (-not $condition.Contains('!cancelled()')) {
            throw "$mode requires a status-aware manual condition."
        }
        if ($workflow.jobs['deploy-prod'].needs -ne 'deploy-test-main') {
            throw 'Predecessor dependency was lost.'
        }
        if ($mode -eq 'environment-approval' -and
            -not $condition.Contains("needs['deploy-test-main'].result == 'success'")) {
            throw 'Automatic runs must require successful predecessors.'
        }
        Write-Host "PASS: $mode generated YAML and stage guards"
    }

    $copied = Get-Content (Join-Path $repoRoot 'copy-to-your-repo/.github/workflows/DEPLOY-main.yml') -Raw | ConvertFrom-Yaml
    $condition = [string]$copied.jobs['deploy-prod']['if']
    if (-not $condition.Contains('!cancelled()') -or
        -not $condition.Contains("needs['deploy-test'].result == 'success'")) {
        throw 'Copied workflow must preserve manual and automatic stage guards.'
    }
    Write-Host 'PASS: Copied deployment workflow guards'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
