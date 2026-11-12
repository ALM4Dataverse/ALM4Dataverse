#Requires -Version 7.2

<#
.SYNOPSIS
    Runs one EXPORT, BUILD and DEPLOY cycle in the Azure DevOps test application.
.DESCRIPTION
    Waits until neither test platform has active runs, then force-pushes
    SharedRef to the project's shared repository and regenerates the application
    repository from this checkout with the setup generators. It raises the
    unpacked solution version to the shared Dev version, pushes with skip-CI
    markers, writes a unique marker to the Dev environment variable definition,
    queues EXPORT, and follows the CI BUILD of EXPORT's commit and the DEPLOY-<Branch>
    run triggered by that BUILD. Succeeds only when the Test environment ends with
    the same marker.

    With -StopActiveRuns it instead cancels every active build in the project and
    waits for them to stop, so the shared E2E lock is not released while a child
    run can still change Dev or Test.
.PARAMETER SharedRef
    Commit under test. It must exist in this checkout with its history, because
    the whole commit graph is pushed to the shared repository.
.PARAMETER AppRepositoryName
    Application repository name, which is also the pipeline folder setup creates.
.PARAMETER GitHubAppRepository
    Optional owner/name of the GitHub test application, also checked for idleness
    because both platforms share the Dev and Test environments.
.NOTES
    Requires git and an Azure CLI sign-in whose identity is an Azure DevOps member
    able to push to both repositories and queue and cancel pipelines, and that can
    administer the Dev and Test environments. GH_TOKEN is used for the optional
    GitHub idle check. Rewrites the shared repository's Branch.
.EXAMPLE
    ./.github/scripts/e2e/Invoke-AzDoE2E.ps1 -OrganizationUrl https://dev.azure.com/contoso -Project alm-e2e -AppRepositoryName alm-e2e-app -SharedRef 0123abcd -DevUrl https://contoso-dev.crm.dynamics.com -TestUrl https://contoso-test.crm.dynamics.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OrganizationUrl,
    [Parameter(Mandatory)][string]$Project,
    [Parameter()][string]$AppRepositoryName,
    [Parameter()][string]$SharedRepositoryName = 'ALM4Dataverse',
    [Parameter()][string]$SharedRef,
    [Parameter()][string]$DevUrl,
    [Parameter()][string]$TestUrl,
    [Parameter()][string]$GitHubAppRepository,
    [Parameter()][bool]$UseAlm4DataverseExtension = $true,
    [Parameter()][string]$RunLabel = 'local',
    [Parameter()][string]$SolutionName = 'ALM4DataverseE2E',
    [Parameter()][string]$MarkerSchemaName = 'alm4dv_E2EMarker',
    [Parameter()][string]$Branch = 'main',
    [Parameter()][string]$DeploymentEnvironmentName = 'TEST-main',
    [Parameter()][string]$WorkRoot = [System.IO.Path]::GetTempPath(),
    [Parameter()][double]$StageTimeoutMinutes = 90,
    [Parameter()][int]$PollSeconds = 30,
    [Parameter()][switch]$StopActiveRuns
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$almRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
if (-not (Get-Module -Name E2E)) {
    Import-Module (Join-Path $PSScriptRoot 'E2E.psm1')
}

$context = Get-E2EAzDoContext -OrganizationUrl $OrganizationUrl -Project $Project -AccessToken (Get-E2EAzDoAccessToken)

if ($StopActiveRuns) {
    Stop-E2EAzDoActiveBuild -Context $context -Confirm:$false
    Wait-E2EResourceIdle -AzDoContext $context -TimeoutMinutes 15 -PollSeconds $PollSeconds
    return
}

foreach ($required in 'AppRepositoryName', 'SharedRef', 'DevUrl', 'TestUrl') {
    if ([string]::IsNullOrWhiteSpace((Get-Variable -Name $required -ValueOnly))) {
        throw "-$required is required unless -StopActiveRuns is used."
    }
}

Wait-E2EResourceIdle -GitHubRepository $GitHubAppRepository -AzDoContext $context -TimeoutMinutes $StageTimeoutMinutes -PollSeconds $PollSeconds

# The header is passed per command so the token is never stored in a remote URL or Git config.
$authConfig = "http.extraheader=AUTHORIZATION: bearer $($context.AccessToken)"
$projectGitUrl = "$($context.OrganizationUrl)/$([uri]::EscapeDataString($Project))/_git"

& git -C $almRoot -c $authConfig push --force "$projectGitUrl/$([uri]::EscapeDataString($SharedRepositoryName))" "${SharedRef}:refs/heads/$Branch"
if ($LASTEXITCODE -ne 0) { throw "Could not push $SharedRef to $SharedRepositoryName." }

$appRoot = Join-Path $WorkRoot ('alm4dataverse-e2e-azdo-' + [guid]::NewGuid().ToString('N'))
& git -c $authConfig clone --quiet --branch $Branch "$projectGitUrl/$([uri]::EscapeDataString($AppRepositoryName))" $appRoot
if ($LASTEXITCODE -ne 0) { throw "Could not clone $AppRepositoryName." }

Add-E2EStepSummary -Markdown "## Azure DevOps E2E`n`nShared repository ``$SharedRepositoryName`` at ``$SharedRef```n`n| Stage | Result | Link |`n|---|---|---|"

Update-E2EAzDoAppRepository -RepositoryRoot $appRoot -AlmRoot $almRoot -RepositoryName $AppRepositoryName -SharedRepositoryName $SharedRepositoryName `
    -SolutionName $SolutionName -UseAlm4DataverseExtension $UseAlm4DataverseExtension -Branch $Branch `
    -DeploymentEnvironmentName $DeploymentEnvironmentName -Confirm:$false

Install-E2EDependency -AlmRoot $almRoot -RepositoryRoot $appRoot

$devConnection = Get-E2EDataverseConnection -Url $DevUrl
$devVersion = Get-E2ESolutionVersion -Connection $devConnection -SolutionName $SolutionName
$null = Set-E2ESolutionSourceVersion -RepositoryRoot $appRoot -SolutionName $SolutionName -MinimumVersion $devVersion -Confirm:$false
$null = Publish-E2EAppRepository -RepositoryRoot $appRoot -Branch $Branch -GitConfig @($authConfig) `
    -Message "E2E: regenerate from $SharedRef [skip ci] ***NO_CI***" -Confirm:$false

$folder = "\$AppRepositoryName"
$exportId = Get-E2EAzDoPipelineId -Context $context -Folder $folder -Name EXPORT
$buildId = Get-E2EAzDoPipelineId -Context $context -Folder $folder -Name BUILD
$deployId = Get-E2EAzDoPipelineId -Context $context -Folder $folder -Name "DEPLOY-$Branch"

$marker = "e2e-$RunLabel-$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'))"
Set-E2EMarker -Connection $devConnection -SchemaName $MarkerSchemaName -Value $marker -Confirm:$false
Write-Host "Dev marker set to '$marker'."

# The margin absorbs clock skew between this runner and Azure DevOps; the lock and
# idle check mean no unrelated build can appear inside it.
$exportStart = (Get-Date).ToUniversalTime().AddMinutes(-1)
$exportRunId = Start-E2EAzDoPipelineRun -Context $context -PipelineId $exportId -Branch $Branch `
    -TemplateParameter @{ commitMessage = "E2E $marker" } -Confirm:$false
$null = Wait-E2EStage -Description 'EXPORT' -TimeoutMinutes $StageTimeoutMinutes -PollSeconds $PollSeconds -GetState {
    Get-E2EAzDoBuildState -Context $context -BuildId $exportRunId
}

$exportedCommit = Get-E2EAzDoBranchHead -Context $context -Repository $AppRepositoryName -Branch $Branch
$build = Wait-E2EResult -Description "the BUILD of exported commit $exportedCommit" -TimeoutMinutes 10 -PollSeconds $PollSeconds -ScriptBlock {
    Find-E2EAzDoBuild -Context $context -DefinitionId $buildId -MinTime $exportStart -SourceVersion $exportedCommit
}
$null = Wait-E2EStage -Description 'BUILD' -TimeoutMinutes $StageTimeoutMinutes -PollSeconds $PollSeconds -GetState {
    Get-E2EAzDoBuildState -Context $context -BuildId $build.Id
}

$deploy = Wait-E2EResult -Description "the DEPLOY-$Branch run triggered by BUILD $($build.Id)" -TimeoutMinutes 10 -PollSeconds $PollSeconds -ScriptBlock {
    Find-E2EAzDoBuild -Context $context -DefinitionId $deployId -MinTime $exportStart -TriggeredByBuildId $build.Id
}
$null = Wait-E2EStage -Description "DEPLOY-$Branch" -TimeoutMinutes $StageTimeoutMinutes -PollSeconds $PollSeconds -GetState {
    Get-E2EAzDoBuildState -Context $context -BuildId $deploy.Id
}

$testMarker = Get-E2EMarker -Connection (Get-E2EDataverseConnection -Url $TestUrl) -SchemaName $MarkerSchemaName
if ($testMarker -ne $marker) {
    throw "Test environment marker is '$testMarker'; expected '$marker' from this run's export."
}
Add-E2EStepSummary -Markdown "`nTest environment marker matches ``$marker``."
Write-Host "E2E cycle succeeded: Test environment has marker '$marker'."
