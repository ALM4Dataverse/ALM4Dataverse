#Requires -Version 7.2

# Helpers for the maintainer E2E workflows. They drive dedicated test applications
# that share one Dev and one Test Dataverse environment across both platforms, so
# every caller must hold the shared E2E concurrency lock and leave no runs active.

Set-StrictMode -Version Latest

$script:SetupGeneratorModuleName = 'ALM4DataverseE2ESetupGenerators'

function Import-SetupGeneratorFunction {
    <#
    .SYNOPSIS
        Loads the setup scripts' caller generators without running the wizard.
    .DESCRIPTION
        Builds a global dynamic module from setup-common.ps1 followed by only the
        top-level function definitions of the provider setup script, matching the
        setup script's own load order so provider definitions win. Write-Section is
        replaced with plain host output because the wizard version clears and redraws
        the console. A previously imported generator module is replaced.
    .OUTPUTS
        The imported PSModuleInfo.
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.PSModuleInfo])]
    param(
        [Parameter(Mandatory)][string]$AlmRoot,
        [Parameter(Mandatory)][ValidateSet('GitHub', 'AzureDevOps')][string]$Platform
    )

    $providerScript = if ($Platform -eq 'GitHub') { 'setup-github.ps1' } else { 'setup-azdo.ps1' }
    $sources = [System.Collections.Generic.List[string]]::new()
    $sources.Add([System.IO.File]::ReadAllText((Join-Path $AlmRoot 'setup-common.ps1')))

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $AlmRoot $providerScript), [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) {
        throw "Could not parse ${providerScript}: $($parseErrors[0].Message)"
    }
    foreach ($definition in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        $sources.Add($definition.Extent.Text)
    }
    $sources.Add(@'
function Write-Section {
    param(
        [Parameter(Mandatory)][string]$Message,
        [string[]]$GuidanceLines,
        [string]$GuidanceDocRelativePath,
        [string]$GuidanceRef,
        [string]$GuidanceLinkLabel
    )
    Write-Host "== $Message"
}
'@)

    Remove-Module -Name $script:SetupGeneratorModuleName -Force -ErrorAction SilentlyContinue
    $module = New-Module -Name $script:SetupGeneratorModuleName -ScriptBlock ([scriptblock]::Create($sources -join [Environment]::NewLine))
    return (Import-Module -ModuleInfo $module -Global -Force -PassThru)
}

function Clear-E2EAppRepository {
    <#
    .SYNOPSIS
        Deletes every tracked file in a test application clone except preserved paths.
    .DESCRIPTION
        PreservePath entries are repository-relative prefixes using forward slashes.
        Directories left empty are removed; the .git directory is never touched.
        Untracked files are left alone because callers work on fresh clones.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter()][string[]]$PreservePath = @('solutions')
    )

    if (-not $PSCmdlet.ShouldProcess($RepositoryRoot, 'Remove tracked application files')) { return }

    $trackedFiles = @(& git -C $RepositoryRoot -c core.quotepath=off ls-files)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not list tracked files in '$RepositoryRoot'."
    }

    $prefixes = @($PreservePath | ForEach-Object { $_.Trim('/') } | Where-Object { $_ })
    foreach ($relativePath in $trackedFiles) {
        $isPreserved = $false
        foreach ($prefix in $prefixes) {
            if ($relativePath -eq $prefix -or $relativePath.StartsWith("$prefix/", [System.StringComparison]::Ordinal)) {
                $isPreserved = $true
                break
            }
        }
        $fullPath = Join-Path $RepositoryRoot $relativePath
        if (-not $isPreserved -and (Test-Path -LiteralPath $fullPath)) {
            Remove-Item -LiteralPath $fullPath -Force
        }
    }

    $gitDirectory = Join-Path $RepositoryRoot '.git'
    $directories = @(Get-ChildItem -LiteralPath $RepositoryRoot -Directory -Recurse -Force |
        Where-Object { $_.FullName -ne $gitDirectory -and -not $_.FullName.StartsWith("$gitDirectory$([IO.Path]::DirectorySeparatorChar)") } |
        Sort-Object { $_.FullName.Length } -Descending)
    foreach ($directory in $directories) {
        if (@(Get-ChildItem -LiteralPath $directory.FullName -Force).Count -eq 0) {
            Remove-Item -LiteralPath $directory.FullName -Force
        }
    }
}

function Update-E2EGitHubAppRepository {
    <#
    .SYNOPSIS
        Regenerates a GitHub test application from copy-to-your-repo and the setup generators.
    .DESCRIPTION
        Clears everything except solutions/, then produces what setup would for one
        branch: copied templates with every shared action pinned to SharedWorkflowRef,
        a BUILD without validation, an environment-approval DEPLOY targeting only
        DeploymentEnvironmentName, and alm-config.psd1 listing SolutionName. Does not commit.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$AlmRoot,
        [Parameter(Mandatory)][string]$SharedWorkflowRepository,
        [Parameter(Mandatory)][string]$SharedWorkflowRef,
        [Parameter(Mandatory)][string]$SolutionName,
        [Parameter()][string]$Branch = 'main',
        [Parameter()][string]$DeploymentEnvironmentName = 'TEST-main'
    )

    if (-not $PSCmdlet.ShouldProcess($RepositoryRoot, 'Regenerate GitHub test application')) { return }

    $null = Import-SetupGeneratorFunction -AlmRoot $AlmRoot -Platform GitHub
    Clear-E2EAppRepository -RepositoryRoot $RepositoryRoot -Confirm:$false
    Copy-WorkflowTemplatesToRepo -SourceRoot (Join-Path $AlmRoot 'copy-to-your-repo') -TargetRoot $RepositoryRoot -Branch $Branch `
        -SharedWorkflowRepository $SharedWorkflowRepository -SharedWorkflowRef $SharedWorkflowRef
    $null = Update-BuildWorkflowInRepoClone -RepoRoot $RepositoryRoot -SharedWorkflowRepository $SharedWorkflowRepository `
        -SharedWorkflowReference $SharedWorkflowRef -BuildEnvironmentName '' -BuildValidationEnabled $false -Confirm:$false
    $null = Update-DeployWorkflowInRepoClone -RepoRoot $RepositoryRoot -Branch $Branch `
        -DeploymentEnvironments @([pscustomobject]@{ ShortName = $DeploymentEnvironmentName }) `
        -SharedWorkflowRepository $SharedWorkflowRepository -SharedWorkflowRef $SharedWorkflowRef `
        -PromotionMode environment-approval -Confirm:$false
    $null = Set-AlmConfigSolutionsInFile -ConfigPath (Join-Path $RepositoryRoot 'alm-config.psd1') -Solutions @(@{ name = $SolutionName }) `
        -CreateIfMissing -TemplatePath (Join-Path $AlmRoot 'copy-to-your-repo/alm-config.psd1') -Confirm:$false
}

function Update-E2EAzDoAppRepository {
    <#
    .SYNOPSIS
        Regenerates an Azure DevOps test application from copy-to-your-repo and the setup generators.
    .DESCRIPTION
        Clears everything except solutions/, then produces what setup would for one
        branch: synced pipeline callers naming SharedRepositoryName, a BUILD without
        validation, a DEPLOY with one stage for DeploymentEnvironmentName, and
        alm-config.psd1 listing SolutionName. RepositoryName must match the pipeline
        folder because DEPLOY's BUILD resource is '<RepositoryName>\BUILD'. Does not commit.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$AlmRoot,
        [Parameter(Mandatory)][string]$RepositoryName,
        [Parameter(Mandatory)][string]$SolutionName,
        [Parameter()][string]$SharedRepositoryName = 'ALM4Dataverse',
        [Parameter()][bool]$UseAlm4DataverseExtension = $true,
        [Parameter()][string]$Branch = 'main',
        [Parameter()][string]$DeploymentEnvironmentName = 'TEST-main'
    )

    if (-not $PSCmdlet.ShouldProcess($RepositoryRoot, 'Regenerate Azure DevOps test application')) { return }

    $null = Import-SetupGeneratorFunction -AlmRoot $AlmRoot -Platform AzureDevOps
    Clear-E2EAppRepository -RepositoryRoot $RepositoryRoot -Confirm:$false
    Sync-CopyToYourRepoIntoGitRepo -SourceRoot (Join-Path $AlmRoot 'copy-to-your-repo') -TargetRoot $RepositoryRoot `
        -RepositoryName $RepositoryName -SharedRepositoryName $SharedRepositoryName -Branch $Branch `
        -UseAlm4DataverseExtension $UseAlm4DataverseExtension
    $null = Update-AzDoBuildPipelineInWorkingTree -RepoRoot $RepositoryRoot -SharedRepositoryName $SharedRepositoryName `
        -BuildEnvironmentName '' -UseAlm4DataverseExtension $UseAlm4DataverseExtension -Confirm:$false
    $null = Update-DeployPipelineInWorkingTree -Environments @([pscustomobject]@{ ShortName = $DeploymentEnvironmentName }) `
        -RepoRoot $RepositoryRoot -Branch $Branch -UseAlm4DataverseExtension $UseAlm4DataverseExtension -Confirm:$false
    $null = Set-AlmConfigSolutionsInFile -ConfigPath (Join-Path $RepositoryRoot 'alm-config.psd1') -Solutions @(@{ name = $SolutionName }) `
        -CreateIfMissing -TemplatePath (Join-Path $AlmRoot 'copy-to-your-repo/alm-config.psd1') -Confirm:$false
}

function Set-E2ESolutionSourceVersion {
    <#
    .SYNOPSIS
        Raises the unpacked solution version to at least the shared Dev version.
    .DESCRIPTION
        Both test applications export the same solution from one Dev environment and
        EXPORT continues from the repository's Solution.xml. Without this, a repository
        that is behind would export, and then deploy, a version lower than the one
        already in Test. A source version that is already equal or higher is kept.
    .OUTPUTS
        True when Solution.xml was rewritten.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$SolutionName,
        [Parameter(Mandatory)][version]$MinimumVersion
    )

    $solutionXmlPath = Join-Path $RepositoryRoot "solutions/$SolutionName/Other/Solution.xml"
    if (-not (Test-Path -LiteralPath $solutionXmlPath)) {
        throw "Solution source not found at '$solutionXmlPath'. Export '$SolutionName' into the test application once before running E2E."
    }

    [xml]$solutionXml = Get-Content -LiteralPath $solutionXmlPath -Raw
    $manifest = $solutionXml.ImportExportXml.SolutionManifest
    if ([version]$manifest.Version -ge $MinimumVersion) { return $false }
    if (-not $PSCmdlet.ShouldProcess($solutionXmlPath, "Set solution version to $MinimumVersion")) { return $false }

    Write-Host "Raising $SolutionName source version from $($manifest.Version) to Dev version $MinimumVersion."
    $manifest.Version = $MinimumVersion.ToString()
    $solutionXml.Save($solutionXmlPath)
    return $true
}

function Publish-E2EAppRepository {
    <#
    .SYNOPSIS
        Commits all working-tree changes and pushes them to Branch on origin.
    .DESCRIPTION
        GitConfig entries are passed as 'git -c' values, for example an Azure DevOps
        bearer header. Include the platform's skip-CI marker in Message, otherwise the
        push starts a BUILD and DEPLOY outside the orchestrated cycle.
    .OUTPUTS
        True when a commit was pushed; false when there was nothing to commit.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$Message,
        [Parameter()][string]$Branch = 'main',
        [Parameter()][string[]]$GitConfig = @()
    )

    if (-not $PSCmdlet.ShouldProcess($RepositoryRoot, "Commit and push to $Branch")) { return $false }

    $configArguments = @(
        foreach ($entry in @('user.name=ALM4Dataverse E2E', 'user.email=alm4dataverse-e2e@users.noreply.github.com') + $GitConfig) { '-c'; $entry }
    )
    & git -C $RepositoryRoot add -A
    if ($LASTEXITCODE -ne 0) { throw 'git add failed.' }
    & git -C $RepositoryRoot diff --cached --quiet
    if ($LASTEXITCODE -eq 0) {
        Write-Host 'Test application already matches the commit under test.'
        return $false
    }
    & git -C $RepositoryRoot @configArguments commit --quiet -m $Message
    if ($LASTEXITCODE -ne 0) { throw 'git commit failed.' }
    & git -C $RepositoryRoot @configArguments push origin "HEAD:refs/heads/$Branch"
    if ($LASTEXITCODE -ne 0) { throw "git push to $Branch failed." }
    return $true
}

function Install-E2EDependency {
    # Runs the shared dependency installer from the application root so it reads that
    # alm-config.psd1; the modules it imports stay loaded in this process.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AlmRoot,
        [Parameter(Mandatory)][string]$RepositoryRoot
    )

    Push-Location $RepositoryRoot
    try {
        & (Join-Path $AlmRoot 'pipelines/scripts/installdependencies.ps1')
    }
    finally {
        Pop-Location
    }
}

function Get-E2EDataverseConnection {
    # Uses the ambient Azure identity (azure/login in CI) through DefaultAzureCredential.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Url)

    return (Get-DataverseConnection -Url $Url -DefaultAzureCredential)
}

function Get-E2ESolutionVersion {
    # Throws when the solution is missing so a misconfigured environment fails before EXPORT.
    [CmdletBinding()]
    [OutputType([version])]
    param(
        [Parameter(Mandatory)][object]$Connection,
        [Parameter(Mandatory)][string]$SolutionName
    )

    $solution = @(Get-DataverseRecord -Connection $Connection -TableName solution -FilterValues @{ uniquename = $SolutionName } -Columns version) | Select-Object -First 1
    if (-not $solution) {
        throw "Solution '$SolutionName' was not found in the Dev environment."
    }
    return [version]$solution.version
}

function Get-E2EMarkerDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Connection,
        [Parameter(Mandatory)][string]$SchemaName
    )

    $definition = @(Get-DataverseRecord -Connection $Connection -TableName environmentvariabledefinition -FilterValues @{ schemaname = $SchemaName } -Columns defaultvalue) | Select-Object -First 1
    if (-not $definition) {
        throw "Environment variable definition '$SchemaName' was not found."
    }
    return $definition
}

function Get-E2EMarker {
    # Returns the definition's default value, which managed upgrades replace; an
    # environment-specific value record is deliberately ignored.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][object]$Connection,
        [Parameter(Mandatory)][string]$SchemaName
    )

    return [string](Get-E2EMarkerDefinition -Connection $Connection -SchemaName $SchemaName).defaultvalue
}

function Set-E2EMarker {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][object]$Connection,
        [Parameter(Mandatory)][string]$SchemaName,
        [Parameter(Mandatory)][string]$Value
    )

    $definition = Get-E2EMarkerDefinition -Connection $Connection -SchemaName $SchemaName
    if (-not $PSCmdlet.ShouldProcess($SchemaName, "Set default value to '$Value'")) { return }
    @{ defaultvalue = $Value } | Set-DataverseRecord -Connection $Connection -TableName environmentvariabledefinition -Id $definition.environmentvariabledefinitionid -NoCreate
}

function Wait-E2EResult {
    <#
    .SYNOPSIS
        Polls ScriptBlock until it outputs a value, and returns that value.
    .DESCRIPTION
        ScriptBlock signals "not ready" by returning nothing. A timeout throws with
        Description; exceptions from ScriptBlock propagate immediately. ArgumentList is
        passed positionally to ScriptBlock on every poll.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [Parameter()][object[]]$ArgumentList = @(),
        [Parameter()][double]$TimeoutMinutes = 60,
        [Parameter()][int]$PollSeconds = 30
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ($true) {
        $result = & $ScriptBlock @ArgumentList
        if ($null -ne $result) { return $result }
        if ((Get-Date) -ge $deadline) {
            throw "Timed out after $TimeoutMinutes minutes waiting for $Description."
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Add-E2EStepSummary {
    # Appends Markdown to the GitHub job summary when one is available.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Markdown)

    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
        Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $Markdown -Encoding utf8
    }
}

function Wait-E2EStage {
    <#
    .SYNOPSIS
        Waits for one child run to finish, records it in the summary, and requires success.
    .DESCRIPTION
        GetState returns an object with Completed, Succeeded, Result and Url. A failed
        or cancelled run throws with its URL so the orchestrator stops at that stage.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$GetState,
        [Parameter()][double]$TimeoutMinutes = 60,
        [Parameter()][int]$PollSeconds = 30
    )

    Write-Host "Waiting for $Description..."
    $state = Wait-E2EResult -Description $Description -TimeoutMinutes $TimeoutMinutes -PollSeconds $PollSeconds -ArgumentList @(, $GetState) -ScriptBlock {
        param([scriptblock]$StateReader)
        $current = & $StateReader
        if ($null -ne $current -and $current.Completed) { $current }
    }
    Add-E2EStepSummary -Markdown "| $Description | $($state.Result) | [run]($($state.Url)) |"
    if (-not $state.Succeeded) {
        throw "$Description finished with result '$($state.Result)': $($state.Url)"
    }
    Write-Host "$Description succeeded: $($state.Url)"
    return $state
}

function Invoke-E2EGitHubApi {
    <#
    .SYNOPSIS
        Calls the GitHub REST API through gh and returns the parsed JSON response.
    .DESCRIPTION
        gh authenticates with GH_TOKEN. An empty response returns null; a failed call
        throws, with gh's own error written to the host.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][ValidateSet('GET', 'POST')][string]$Method = 'GET'
    )

    $output = @(& gh api --method $Method $Path)
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub API $Method $Path failed."
    }
    $text = ($output | ForEach-Object { [string]$_ }) -join "`n"
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return ($text | ConvertFrom-Json)
}

function ConvertTo-E2EGitHubRunState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Run)

    $conclusion = [string]$Run.conclusion
    [pscustomobject]@{
        Id        = $Run.id
        Completed = ($Run.status -eq 'completed')
        Succeeded = ($Run.status -eq 'completed' -and $conclusion -eq 'success')
        Result    = if ($Run.status -eq 'completed') { $conclusion } else { [string]$Run.status }
        Url       = [string]$Run.html_url
    }
}

function Find-E2EGitHubRun {
    <#
    .SYNOPSIS
        Returns the earliest run of a workflow for an event created at or after CreatedAfter.
    .DESCRIPTION
        Returns null when no such run exists yet. Callers rely on the shared E2E lock and
        the idle check for this to be the run their previous stage started.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Workflow,
        [Parameter(Mandatory)][string]$EventName,
        [Parameter(Mandatory)][datetime]$CreatedAfter
    )

    $response = Invoke-E2EGitHubApi -Path "repos/$Repository/actions/workflows/$Workflow/runs?event=$EventName&per_page=30"
    $threshold = $CreatedAfter.ToUniversalTime()
    $run = @($response.workflow_runs |
        Where-Object { ([datetime]$_.created_at).ToUniversalTime() -ge $threshold } |
        Sort-Object { ([datetime]$_.created_at).ToUniversalTime() }) | Select-Object -First 1
    if ($null -eq $run) { return $null }
    return (ConvertTo-E2EGitHubRunState -Run $run)
}

function Get-E2EGitHubRunState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$RunId
    )

    return (ConvertTo-E2EGitHubRunState -Run (Invoke-E2EGitHubApi -Path "repos/$Repository/actions/runs/$RunId"))
}

function Get-E2EGitHubActiveRun {
    # Lists runs that are not completed (queued, waiting, pending or in progress).
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$Repository)

    $response = Invoke-E2EGitHubApi -Path "repos/$Repository/actions/runs?per_page=100"
    return @($response.workflow_runs | Where-Object { $_.status -ne 'completed' })
}

function Stop-E2EGitHubActiveRun {
    # Requests cancellation of every active run in the dedicated test repository;
    # cancellation is asynchronous, so callers wait for idleness afterwards.
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)][string]$Repository)

    foreach ($run in @(Get-E2EGitHubActiveRun -Repository $Repository)) {
        if ($PSCmdlet.ShouldProcess("$Repository run $($run.id)", 'Cancel workflow run')) {
            Write-Host "Cancelling $($run.html_url)"
            $null = Invoke-E2EGitHubApi -Method POST -Path "repos/$Repository/actions/runs/$($run.id)/cancel"
        }
    }
}

function Get-E2EAzDoContext {
    # Holds the organisation, project and bearer token shared by the Azure DevOps helpers.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OrganizationUrl,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$AccessToken
    )

    [pscustomobject]@{
        OrganizationUrl = $OrganizationUrl.TrimEnd('/')
        Project         = $Project
        AccessToken     = $AccessToken
    }
}

function Get-E2EAzDoAccessToken {
    # Exchanges the ambient Azure CLI identity for an Azure DevOps token and masks it in logs.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $token = (& az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken --output tsv)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
        throw 'Could not get an Azure DevOps access token from the Azure CLI. Run azure/login first.'
    }
    $token = ([string]$token).Trim()
    if ($env:GITHUB_ACTIONS -eq 'true') { Write-Host "::add-mask::$token" }
    return $token
}

function Invoke-E2EAzDoApi {
    <#
    .SYNOPSIS
        Calls a project-scoped Azure DevOps REST API with api-version 7.1.
    .PARAMETER Path
        Path after '_apis/', optionally with a query string.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][ValidateSet('GET', 'POST', 'PATCH')][string]$Method = 'GET',
        [Parameter()][object]$Body
    )

    $separator = if ($Path.Contains('?')) { '&' } else { '?' }
    $parameters = @{
        Uri         = "$($Context.OrganizationUrl)/$([uri]::EscapeDataString($Context.Project))/_apis/$Path${separator}api-version=7.1"
        Method      = $Method
        Headers     = @{ Authorization = "Bearer $($Context.AccessToken)" }
        ContentType = 'application/json'
    }
    if ($null -ne $Body) {
        $parameters.Body = $Body | ConvertTo-Json -Depth 10 -Compress
    }
    return (Invoke-RestMethod @parameters)
}

function Get-E2EAzDoPipelineId {
    # Folder is the pipeline path setup uses, '\<application repository name>'.
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][string]$Name
    )

    $response = Invoke-E2EAzDoApi -Context $Context -Path "build/definitions?name=$([uri]::EscapeDataString($Name))&path=$([uri]::EscapeDataString($Folder))"
    $definition = @($response.value) | Select-Object -First 1
    if (-not $definition) {
        throw "Azure DevOps pipeline '$Folder\$Name' was not found."
    }
    return [int]$definition.id
}

function Start-E2EAzDoPipelineRun {
    # Returns the run ID, which is also the build ID used by the build APIs.
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][int]$PipelineId,
        [Parameter()][string]$Branch = 'main',
        [Parameter()][hashtable]$TemplateParameter = @{}
    )

    if (-not $PSCmdlet.ShouldProcess("pipeline $PipelineId", 'Queue run')) { return }
    $body = @{
        resources          = @{ repositories = @{ self = @{ refName = "refs/heads/$Branch" } } }
        templateParameters = $TemplateParameter
    }
    $run = Invoke-E2EAzDoApi -Context $Context -Method POST -Path "pipelines/$PipelineId/runs" -Body $body
    return [int]$run.id
}

function ConvertTo-E2EAzDoBuildState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Build)

    $result = if ($Build.PSObject.Properties['result']) { [string]$Build.result } else { '' }
    [pscustomobject]@{
        Id        = [int]$Build.id
        Completed = ($Build.status -eq 'completed')
        Succeeded = ($Build.status -eq 'completed' -and $result -eq 'succeeded')
        Result    = if ($Build.status -eq 'completed') { $result } else { [string]$Build.status }
        Url       = [string]$Build._links.web.href
    }
}

function Get-E2EAzDoBuildState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][int]$BuildId
    )

    return (ConvertTo-E2EAzDoBuildState -Build (Invoke-E2EAzDoApi -Context $Context -Path "build/builds/$BuildId"))
}

function Find-E2EAzDoBuild {
    <#
    .SYNOPSIS
        Returns the earliest build of a definition queued at or after MinTime that matches a filter.
    .DESCRIPTION
        SourceVersion selects a CI build of an exact commit; TriggeredByBuildId selects a
        run started by a pipeline-resource trigger from that build. Returns null when no
        matching build exists yet.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][int]$DefinitionId,
        [Parameter(Mandatory)][datetime]$MinTime,
        [Parameter()][string]$SourceVersion,
        [Parameter()][int]$TriggeredByBuildId
    )

    $minTimeText = [uri]::EscapeDataString($MinTime.ToUniversalTime().ToString('o'))
    $response = Invoke-E2EAzDoApi -Context $Context -Path "build/builds?definitions=$DefinitionId&minTime=$minTimeText&queryOrder=queueTimeAscending"
    $build = @($response.value | Where-Object {
            (-not $SourceVersion -or $_.sourceVersion -eq $SourceVersion) -and
            (-not $TriggeredByBuildId -or ($_.PSObject.Properties['triggeredByBuild'] -and $_.triggeredByBuild -and [int]$_.triggeredByBuild.id -eq $TriggeredByBuildId))
        }) | Select-Object -First 1
    if ($null -eq $build) { return $null }
    return (ConvertTo-E2EAzDoBuildState -Build $build)
}

function Get-E2EAzDoActiveBuild {
    # Lists the project's most recent builds that have not completed.
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][object]$Context)

    $response = Invoke-E2EAzDoApi -Context $Context -Path 'build/builds?$top=100&queryOrder=queueTimeDescending'
    return @($response.value | Where-Object { $_.status -ne 'completed' })
}

function Stop-E2EAzDoActiveBuild {
    # Requests cancellation of every active build in the dedicated test project.
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)][object]$Context)

    foreach ($build in @(Get-E2EAzDoActiveBuild -Context $Context)) {
        if ($build.status -eq 'cancelling') { continue }
        if ($PSCmdlet.ShouldProcess("build $($build.id)", 'Cancel build')) {
            Write-Host "Cancelling Azure DevOps build $($build.id)"
            $null = Invoke-E2EAzDoApi -Context $Context -Method PATCH -Path "build/builds/$($build.id)" -Body @{ status = 'cancelling' }
        }
    }
}

function Get-E2EAzDoBranchHead {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter()][string]$Branch = 'main'
    )

    $response = Invoke-E2EAzDoApi -Context $Context -Path "git/repositories/$([uri]::EscapeDataString($Repository))/refs?filter=$([uri]::EscapeDataString("heads/$Branch"))"
    $ref = @($response.value | Where-Object { $_.name -eq "refs/heads/$Branch" }) | Select-Object -First 1
    if (-not $ref) {
        throw "Branch '$Branch' was not found in Azure DevOps repository '$Repository'."
    }
    return [string]$ref.objectId
}

function Wait-E2EResourceIdle {
    <#
    .SYNOPSIS
        Waits until neither test platform has active runs that could touch Dev or Test.
    .DESCRIPTION
        The GitHub concurrency group only serializes the E2E workflows themselves.
        This also covers child runs left by an earlier failure and manual runs in the
        test applications. Pass whichever platforms the caller can reach.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][string]$GitHubRepository,
        [Parameter()][object]$AzDoContext,
        [Parameter()][double]$TimeoutMinutes = 60,
        [Parameter()][int]$PollSeconds = 30
    )

    $null = Wait-E2EResult -Description 'the shared Dataverse environments to become idle' -TimeoutMinutes $TimeoutMinutes -PollSeconds $PollSeconds -ArgumentList @($GitHubRepository, $AzDoContext) -ScriptBlock {
        param([string]$Repository, [object]$Context)
        $active = @()
        if ($Repository) {
            $active += @(Get-E2EGitHubActiveRun -Repository $Repository | ForEach-Object { "GitHub $($_.html_url)" })
        }
        if ($Context) {
            $active += @(Get-E2EAzDoActiveBuild -Context $Context | ForEach-Object { "Azure DevOps build $($_.id)" })
        }
        if ($active.Count -eq 0) { return $true }
        Write-Host "Waiting for active test application runs: $($active -join ', ')"
    }
}

Export-ModuleMember -Function @(
    'Import-SetupGeneratorFunction'
    'Clear-E2EAppRepository'
    'Update-E2EGitHubAppRepository'
    'Update-E2EAzDoAppRepository'
    'Set-E2ESolutionSourceVersion'
    'Publish-E2EAppRepository'
    'Install-E2EDependency'
    'Get-E2EDataverseConnection'
    'Get-E2ESolutionVersion'
    'Get-E2EMarker'
    'Set-E2EMarker'
    'Wait-E2EResult'
    'Wait-E2EStage'
    'Add-E2EStepSummary'
    'Invoke-E2EGitHubApi'
    'Find-E2EGitHubRun'
    'Get-E2EGitHubRunState'
    'Get-E2EGitHubActiveRun'
    'Stop-E2EGitHubActiveRun'
    'Get-E2EAzDoContext'
    'Get-E2EAzDoAccessToken'
    'Invoke-E2EAzDoApi'
    'Get-E2EAzDoPipelineId'
    'Start-E2EAzDoPipelineRun'
    'Get-E2EAzDoBuildState'
    'Find-E2EAzDoBuild'
    'Get-E2EAzDoActiveBuild'
    'Stop-E2EAzDoActiveBuild'
    'Get-E2EAzDoBranchHead'
    'Wait-E2EResourceIdle'
)
