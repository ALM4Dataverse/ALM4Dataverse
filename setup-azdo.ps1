#!/usr/bin/env pwsh
<#
.SYNOPSIS
Interactively configures Azure DevOps repositories, pipelines and Dataverse environments.
.DESCRIPTION
Requires an interactive Windows PowerShell 5.1 session on Windows or PowerShell 7 on
Windows or Linux, and identities allowed to administer the selected Azure DevOps project
and Dataverse environments. Downloads pinned modules and portable Git on Windows; on
Linux, uses system Git from PATH. Authenticates, then offers branch-aware setup and
publication choices. Remote resource provisioning can occur before repository changes
are published; cancelling publication does not roll back those resources.
ApplyConfig reads the selected existing repository's committed alm-config.psd1,
reviews generated changes and publishes them without editing settings or provisioning
Azure DevOps pipelines, permissions or environment resources.
.NOTES
Selected mutation helpers support ShouldProcess; the interactive installer as a whole
does not provide a dry run.
.PARAMETER TenantId
Optional tenant hint for the initial Azure DevOps token acquisition.
.PARAMETER UseDeviceAuthentication
Retained for invocation compatibility; the current authentication flow does not use it.
.PARAMETER ALM4DataverseRef
Upstream template ref. Releases supply a default; development resolves a local branch or
commit after Git is available, falling back to stable.
.PARAMETER ApplyConfig
Read the committed alm-config.psd1 from an existing repository, review the generated
changes and publish them without running the configuration editors.
.PARAMETER PreviewOnly
With ApplyConfig, display the generated change summary and select individual file
diffs to view without publishing. Selected diffs are written without paging.
.EXAMPLE
.\setup-azdo.ps1 -TenantId contoso.onmicrosoft.com -ALM4DataverseRef stable
.EXAMPLE
.\setup-azdo.ps1 -ApplyConfig
.EXAMPLE
.\setup-azdo.ps1 -ApplyConfig -PreviewOnly
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'UseDeviceAuthentication', Justification = 'Legacy installer switch retained for invocation compatibility; current authentication does not consume it.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'TenantId', Justification = 'Captured by the ordered setup authentication prerequisite.')]
[CmdletBinding()]
param(
    [Parameter()]
    [string]$TenantId,

    [Parameter()]
    [switch]$UseDeviceAuthentication,

    [Parameter()]
    [string]$ALM4DataverseRef,

    [Parameter()]
    [switch]$ApplyConfig,

    [Parameter()]
    [switch]$PreviewOnly
)

$resolveDevRefAfterGitIsAvailable = $false

# ALM4DataverseRef default handling - injected during release, fallback for development
if (-not $ALM4DataverseRef) {
    $injectedRef = '__ALM4DATAVERSE_REF__'
    if ($injectedRef -like '__*') {
        # Placeholders not replaced - development mode.
        # We resolve this after Git is available to support local branch/commit selection.
        $resolveDevRefAfterGitIsAvailable = $true
        Write-Host "Development mode: Will resolve ALM4DataverseRef from current branch/commit after Git is available (fallback: 'stable')." -ForegroundColor Yellow
        $ALM4DataverseRef = 'stable'
    } else {
        $ALM4DataverseRef = $injectedRef
    }
}

$script:SetupDefaultHelpDocRelativePath = 'docs/setup/azdo-automated-setup.md'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue' # Suppress progress bars

if ($PreviewOnly -and -not $ApplyConfig) {
    throw 'PreviewOnly requires ApplyConfig.'
}

# Release preparation embeds the ordered helper source into this installer.
# Version numbers and the ALM4Dataverse ref are injected during release.

# Keep the user-facing setup steps aligned with docs/setup/azdo-automated-setup.md.

# Dot-sourced helper fragments share this script's state; release preparation embeds
# the same source so the published installer remains a single file.
$script:SetupRepositoryRoot = if ($PSScriptRoot) { $PSScriptRoot } else { $null }
$setupCommonPath = if ($script:SetupRepositoryRoot) { Join-Path $script:SetupRepositoryRoot 'setup/setup-common.ps1' } else { $null }
if ($setupCommonPath -and (Test-Path -LiteralPath $setupCommonPath)) {
    . $setupCommonPath
}
else {
    __SETUP_COMMON_LIB__
}

$setupAzDoBootstrapPath = if ($script:SetupRepositoryRoot) { Join-Path $script:SetupRepositoryRoot 'setup/setup-azdo-bootstrap.ps1' } else { $null }
if ($setupAzDoBootstrapPath -and (Test-Path -LiteralPath $setupAzDoBootstrapPath)) {
    . $setupAzDoBootstrapPath
}
else {
    __SETUP_AZDO_BOOTSTRAP_LIB__
}

#region Initialization

Write-Section `
    -Message "Initialising setup"

$TempModuleRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ALM4Dataverse\Modules"
New-DirectoryIfMissing -Path $TempModuleRoot

$delim = Get-ModulePathDelimiter
if (-not ($env:PSModulePath -split [Regex]::Escape($delim) | Where-Object { $_ -eq $TempModuleRoot })) {
    $env:PSModulePath = "$TempModuleRoot$delim$env:PSModulePath"
}

Write-Host "Using temp module root: $TempModuleRoot"

# The product version is distinct from the upstream template ref.
$script:ALM4DataverseVersion = '__ALM4DATAVERSE_VERSION__'
if ($script:ALM4DataverseVersion -like '__*') {
    $script:ALM4DataverseVersion = 'Development'
}

# Version numbers are injected during release process
# For development/testing, fall back to reading from config file if placeholders are present
$rnwoodDataverseVersion = '__RNWOOD_DATAVERSE_VERSION__'
if ($rnwoodDataverseVersion -like '__*') {
    # Placeholders not replaced - must be running from repository for development
    $configPath = Join-Path $PSScriptRoot 'alm-config-defaults.psd1'
    if (Test-Path $configPath) {
        Write-Host "Development mode: Reading version from $configPath" -ForegroundColor Yellow
        $config = Import-PowerShellDataFile -Path $configPath
        $rnwoodDataverseVersion = $config.scriptDependencies.'Rnwood.Dataverse.Data.PowerShell'
    } else {
        throw "This script appears to be running in development mode but alm-config-defaults.psd1 was not found at $configPath. Please download the released version from https://github.com/ALM4Dataverse/ALM4Dataverse/releases/latest/download/setup-azdo.ps1"
    }
}

# Upstream repository URL is injected during release process
# For development/testing, use local workspace path or fallback to GitHub
$upstreamRepo = '__UPSTREAM_REPO__'
if ($upstreamRepo -like '__*') {
    # Placeholders not replaced - must be running from repository for development
    if ($PSScriptRoot) {
        Write-Host "Development mode: Using local workspace path as upstream repo" -ForegroundColor Yellow
        $upstreamRepo = $PSScriptRoot
    } else {
        Write-Host "Development mode: Using default GitHub URL as upstream repo" -ForegroundColor Yellow
        $upstreamRepo = 'https://github.com/ALM4Dataverse/ALM4Dataverse.git'
    }
}

$requiredModules = @{
    'VSTeam'                           = '7.15.2'
    'Rnwood.Dataverse.Data.PowerShell' = $rnwoodDataverseVersion
}

# Resolve exact module versions before importing; shared helpers handle dependency compatibility.
foreach ($modName in $requiredModules.Keys) {
    $version = $requiredModules[$modName]
    if (-not (Get-ModuleAvailableExact -Name $modName -RequiredVersion $version)) {
        Save-ModuleExact -Name $modName -RequiredVersion $version -Destination $TempModuleRoot
    }
}

foreach ($modName in $requiredModules.Keys) {
    $version = $requiredModules[$modName]
    Import-RequiredModuleVersion -Name $modName -RequiredVersion $version -Destination $TempModuleRoot
}

# Install portable Git on Windows or use system Git on non-Windows systems.
$gitBinDir = Install-PortableGit -Destination $TempModuleRoot

# Add Git to PATH for this session
if (-not ($env:PATH -split [Regex]::Escape($delim) | Where-Object { $_ -eq $gitBinDir })) {
    $env:PATH = "$gitBinDir$delim$env:PATH"
}

# Verify Git is now available
$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) {
    throw "Git was installed but is still not available in PATH"
}

Write-Host "Git is now available: $($git.Source)"
Write-Host "Version: $(git --version)"

if ($resolveDevRefAfterGitIsAvailable) {
    $ALM4DataverseRef = Resolve-DevelopmentDefaultAlm4DataverseRef -PrimaryRepositoryPath $upstreamRepo -FallbackRef $ALM4DataverseRef
    Write-Host "Development mode: Resolved ALM4DataverseRef to '$ALM4DataverseRef'" -ForegroundColor Yellow
}

if ($ApplyConfig) {
    $script:existingSetupMode = $true
}
else {
    $setupModeChoice = Select-FromMenu `
        -Title 'Choose setup type' `
        -ShowProductBrand `
        -Items @('Set up a new application repository', 'Configure an existing repository') `
        -PromptGuidanceLines @(
            'Choose whether this run should create a new application repository or configure one that already exists.',
            'Existing-repository setup authenticates and selects its resources before opening the guided configuration menu.'
        ) `
        -PromptGuidanceDocRelativePath 'docs/setup/azdo-automated-setup.md' `
        -PromptGuidanceRef $ALM4DataverseRef
    if ($null -eq $setupModeChoice) {
        return
    }

    $script:existingSetupMode = $setupModeChoice -eq 1
}

$setupAzDoSourcePath = if ($script:SetupRepositoryRoot) { Join-Path $script:SetupRepositoryRoot "setup/setup-azdo.ps1" } else { $null }
if ($setupAzDoSourcePath -and (Test-Path -LiteralPath $setupAzDoSourcePath -PathType Leaf)) {
    . $setupAzDoSourcePath
}
else {
    __SETUP_AZDO_LIB__
}

#region Azure DevOps Setup

















#endregion

#region Dataverse Environment Selection Helper







#endregion

#region Pipeline Setup

































































# Authentication and project selection finish before the configuration menu. The main
# menu starts with shared-repository selection, followed by version reconciliation.
$startupSteps = @(
    [pscustomobject]@{
        Name = 'Authenticate with Azure DevOps'
        HelpDocRelativePath = 'docs/setup/azdo-automated-setup.md'
        LockAfterCompletion = $true
        Action = {
            $authentication = Initialize-AzDoAuthentication -TenantId $TenantId
            $script:adoAuthResult = $authentication.AuthResult
            $script:adoAccessToken = $authentication.AccessToken
            $script:secureToken = $authentication.SecureToken
        }
    }
    [pscustomobject]@{
        Name = 'Select Azure DevOps organization'
        HelpDocRelativePath = 'docs/setup/azdo-organisation-requirements.md'
        LockAfterCompletion = $true
        Action = {
            $organization = Initialize-AzDoOrganization
            if (-not $organization) {
                Request-SetupWizardBack
            }
            $script:orgName = $organization.Name
            $script:orgUri = $organization.Uri
        }
    }
    [pscustomobject]@{
        Name = 'Select project and application repository'
        HelpDocRelativePath = 'docs/setup/azdo-automated-setup.md'
        LockAfterCompletion = $true
        Action = {
            $script:initialization = Initialize-AzDoProjectAndRepository `
                -ApplyConfig:$ApplyConfig `
                -ExistingSetupMode:$existingSetupMode `
                -DeferSharedRepositorySelection:($existingSetupMode -and -not $ApplyConfig) `
                -SkipSharedRepositoryVersionUpdate
            if (-not $script:initialization) {
                Request-SetupWizardBack
            }
        }
    }
)

try {
    Invoke-SetupWizard `
        -Title 'Azure DevOps setup prerequisites' `
        -Steps $startupSteps `
        -HelpDocRelativePath 'docs/setup/azdo-automated-setup.md' `
        -HelpRef $ALM4DataverseRef | Out-Null
}
catch {
    if ($_.Exception.Message -eq 'Setup cancelled before changes were applied.' -or (Test-IsSetupWizardBackException -Exception $_.Exception)) {
        Write-Host 'Azure DevOps setup cancelled before branch configuration.' -ForegroundColor Yellow
        return
    }
    throw
}

$initialSetupSteps = @()

# Normal setup may provision resources before branch review; ApplyConfig only reads existing resources.
$initialization = $script:initialization
if (-not $initialization) {
    return
}

$selectedProject = $initialization.SelectedProject
$mainRepo = $initialization.MainRepo
$mainRepoWorkingTree = $initialization.MainRepoWorkingTree
$mainRepoWorkingRoot = $initialization.MainRepoWorkingRoot
$azDevOpsAccessToken = $initialization.AzDevOpsAccessToken
$sharedRepoName = $initialization.SharedRepoName
$sharedRepositoryRef = $initialization.SharedRepositoryRef
$isNewRepository = [bool]$initialization.MainRepoIsNew

Write-Section `
    -Message "Ensuring main repository contains pipeline YAMLs"

$repoPublishResults = @()
$script:yamlFiles = @(
    'pipelines/BUILD.yml',
    'pipelines/EXPORT.yml',
    'pipelines/IMPORT.yml'
)

Push-Location $mainRepoWorkingRoot
try {
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'

        & git checkout $script:mainRepoBranch 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            & git checkout -b $script:mainRepoBranch 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to check out branch '$script:mainRepoBranch' in the working tree."
            }
        }

        & git -c "http.extraheader=AUTHORIZATION: bearer $azDevOpsAccessToken" fetch origin '+refs/heads/*:refs/remotes/origin/*' --prune 2>&1 | Out-Null
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}
finally {
    Pop-Location
}


$localCopyRoot = $null
if ($PSScriptRoot) {
    $candidateCopyRoot = Join-Path $PSScriptRoot 'copy-to-your-repo'
    if (Test-Path -LiteralPath $candidateCopyRoot -PathType Container) {
        $localCopyRoot = $candidateCopyRoot
    }
}

$script:sharedRepositoryState = [ordered]@{
    Repository = $null
    Name = ''
    Ref = ''
    CopyRoot = $localCopyRoot
    ClonePath = $null
    UsesLocalCopyRoot = [bool]$localCopyRoot
    ValidationError = [string](Get-OptionalObjectPropertyValue -InputObject $initialization -PropertyName 'SharedRepositorySelectionError')
}
[void](Set-AzDoSharedRepositoryState `
    -RepositoryState $script:sharedRepositoryState `
    -Initialization $initialization `
    -AccessToken $azDevOpsAccessToken `
    -UpstreamGitSource $upstreamRepo)
$sharedRepoName = [string]$script:sharedRepositoryState.Name
if ([string]::IsNullOrWhiteSpace($sharedRepoName)) {
    $sharedRepoName = 'ALM4Dataverse'
}
$sharedRepositoryRef = [string]$script:sharedRepositoryState.Ref
$copyRoot = [string]$script:sharedRepositoryState.CopyRoot
$sharedRepoClone = [string]$script:sharedRepositoryState.ClonePath
$initialSetupSteps += [pscustomobject]@{
    Name = 'Select shared repository'
    HelpDocRelativePath = 'docs/setup/azdo-automated-setup.md'
    Summary = {
        if ([string]::IsNullOrWhiteSpace([string]$script:sharedRepositoryState.ValidationError)) {
            "$($script:sharedRepositoryState.Name) ($($script:sharedRepositoryState.Ref))"
        }
        else {
            "Unavailable: $($script:sharedRepositoryState.ValidationError)"
        }
    }
    Action = {
        if ($ApplyConfig) {
            throw 'The shared repository cannot be changed while applying committed configuration.'
        }

        $updatedInitialization = Initialize-AzDoProjectAndRepository `
            -SharedRepositoryOnly `
            -SelectedProjectForSharedRepository $selectedProject `
            -MainRepoForSharedRepository $mainRepo `
            -MainRepoWorkingTreeForSharedRepository $mainRepoWorkingTree `
            -MainRepoWorkingRootForSharedRepository $mainRepoWorkingRoot `
            -AccessTokenForSharedRepository $azDevOpsAccessToken `
            -PreferredSharedRepositoryName ([string]$script:sharedRepositoryState.Name) `
            -PreferredSharedRepositoryRef ([string]$script:sharedRepositoryState.Ref) `
            -SkipSharedRepositoryVersionUpdate
        [void](Set-AzDoSharedRepositoryState `
            -RepositoryState $script:sharedRepositoryState `
            -Initialization $updatedInitialization `
            -AccessToken $azDevOpsAccessToken `
            -UpstreamGitSource $upstreamRepo)
    }
    IsComplete = [string]::IsNullOrWhiteSpace([string]$script:sharedRepositoryState.ValidationError)
    IsLocked = [bool]$ApplyConfig
}
$initialSetupSteps += [pscustomobject]@{
    Name = 'Check and update shared repository version'
    HelpDocRelativePath = 'docs/setup/azdo-automated-setup.md'
    Summary = {
        if ($ApplyConfig) {
            'Skipped by -ApplyConfig'
        }
        else {
            "Check against $ALM4DataverseRef"
        }
    }
    Action = {
        if ($ApplyConfig) {
            throw 'The shared repository version cannot be updated while applying committed configuration.'
        }

        $updatedInitialization = Initialize-AzDoProjectAndRepository `
            -SharedRepositoryOnly `
            -UsePreferredSharedRepository `
            -SelectedProjectForSharedRepository $selectedProject `
            -MainRepoForSharedRepository $mainRepo `
            -MainRepoWorkingTreeForSharedRepository $mainRepoWorkingTree `
            -MainRepoWorkingRootForSharedRepository $mainRepoWorkingRoot `
            -AccessTokenForSharedRepository $azDevOpsAccessToken `
            -PreferredSharedRepositoryName ([string]$script:sharedRepositoryState.Name) `
            -PreferredSharedRepositoryRef ([string]$script:sharedRepositoryState.Ref)
        [void](Set-AzDoSharedRepositoryState `
            -RepositoryState $script:sharedRepositoryState `
            -Initialization $updatedInitialization `
            -AccessToken $azDevOpsAccessToken `
            -UpstreamGitSource $upstreamRepo)
    }
    IsComplete = [bool]$ApplyConfig
    IsLocked = [bool]$ApplyConfig
}

try {
    Invoke-WithErrorHandling -OperationName "Preparing main repository working tree" -ScriptBlock {
        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            Sync-CopyToYourRepoIntoGitRepo `
                -SourceRoot $copyRoot `
                -TargetRoot $mainRepoWorkingRoot `
                -RepositoryName $mainRepo.Name `
                -SharedRepositoryName $sharedRepoName `
                -SharedRepositoryRef $sharedRepositoryRef `
                -Branch $script:mainRepoBranch `
                -UseAlm4DataverseExtension $script:useAlm4DataverseExtension
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
    } -StatusMessage 'Preparing the main repository working tree...' -CaptureOutputInPanel | Out-Null
}
catch {
    if ($sharedRepoClone -and (Test-Path -LiteralPath $sharedRepoClone)) {
        try { Remove-Item -LiteralPath $sharedRepoClone -Recurse -Force -ErrorAction Stop } catch { Write-Verbose 'Could not remove the shared repository clone; continuing cleanup.' }
    }
    throw
}

#endregion

#region Dev Environment and Solutions Selection







#endregion

#region Deployment Environments Selection



















































# Keep publication in the retryable Apply action so a failure returns to the wizard
# with branch choices intact. Earlier branch publications are not rolled back.
$providerOptions = [ordered]@{
    azDOUseAlm4DataverseExtension = [bool]$script:useAlm4DataverseExtension
}
try {
    $postApplyAction = $null
    if (-not $ApplyConfig) {
        $postApplyAction = {
            param($setupResult)
            Invoke-AzDoSetupPostApply `
                -SetupResult $setupResult `
                -SelectedProject $selectedProject `
                -MainRepo $mainRepo `
                -SharedRepository $script:sharedRepositoryState.Repository `
                -OrganizationName $orgName
        }
    }

    $azDoSetupResult = Invoke-AzDoBranchAwareSetup `
        -MainRepoWorkingRoot $mainRepoWorkingRoot `
        -MainRepo $mainRepo `
        -SelectedProject $selectedProject `
        -OrganizationName $orgName `
        -TenantId $adoAuthResult.TenantId `
        -DefaultBranch $script:mainRepoBranch `
        -AccessToken $azDevOpsAccessToken `
        -CopyRoot $copyRoot `
        -SharedRepositoryName $sharedRepoName `
        -SharedRepositoryRef $sharedRepositoryRef `
        -UseAlm4DataverseExtension $script:useAlm4DataverseExtension `
        -ALM4DataverseRef $ALM4DataverseRef `
        -ProviderOptions $providerOptions `
        -PrerequisiteSteps $initialSetupSteps `
        -SharedRepositoryState $script:sharedRepositoryState `
        -PostApplyAction $postApplyAction `
        -ApplyConfig:$ApplyConfig `
        -IsNewRepository:$isNewRepository `
        -PreviewOnly:$PreviewOnly
}
catch {
    if (
        $_.Exception.Message -in @('Setup cancelled before changes were applied.', 'Setup exited without applying changes.') -or
        (Test-IsSetupWizardBackException -Exception $_.Exception)
    ) {
        Write-Host 'Azure DevOps setup exited before applying changes.' -ForegroundColor Yellow
        if ($mainRepoWorkingRoot -and (Test-Path -LiteralPath $mainRepoWorkingRoot)) {
            try { Remove-Item -LiteralPath $mainRepoWorkingRoot -Recurse -Force -ErrorAction Stop } catch { Write-Verbose 'Could not remove the main repository clone; continuing cleanup.' }
        }
        return
    }
    throw
}
finally {
    if ($sharedRepoClone -and (Test-Path -LiteralPath $sharedRepoClone)) {
        try { Remove-Item -LiteralPath $sharedRepoClone -Recurse -Force -ErrorAction Stop } catch { Write-Verbose 'Could not remove the shared repository clone; continuing cleanup.' }
    }
}

$branchStates = @($azDoSetupResult.BranchStates)
$solutionSourceBranch = $azDoSetupResult.SolutionSourceBranch
$buildValidationEnabled = @($branchStates | Where-Object { $_.BuildValidationEnabled }).Count -gt 0
$enabledBuildBranchStates = @($branchStates | Where-Object { $_.BuildValidationEnabled })
$repoPublishResults = @($azDoSetupResult.PublishResults)
$allConfiguredEnvironments = @()
foreach ($branchState in @($branchStates)) {
    if ($branchState.DevEnvironmentConfiguration) {
        $allConfiguredEnvironments += $branchState.DevEnvironmentConfiguration
    }
    $allConfiguredEnvironments += @($branchState.DeploymentEnvironments)
    if ($branchState.BuildValidationEnabled -and $branchState.BuildValidationEnvironmentConfiguration) {
        $allConfiguredEnvironments += $branchState.BuildValidationEnvironmentConfiguration
    }
}

#endregion

if ($mainRepoWorkingRoot -and (Test-Path $mainRepoWorkingRoot)) {
    try { Remove-Item -LiteralPath $mainRepoWorkingRoot -Recurse -Force -ErrorAction Stop } catch { Write-Verbose 'Could not remove the main repository clone; continuing cleanup.' }
}

if ($PreviewOnly) {
    return
}

Show-SetupCompletionScreen `
    -Heading 'Azure DevOps setup completed successfully!' `
    -AccessLabel 'Open your Azure DevOps project' `
    -AccessUrl "https://dev.azure.com/$orgName/$($selectedProject.Name)/_build" `
    -SummaryValues ([ordered]@{
        'Azure DevOps project'   = $selectedProject.Name
        'Main repository'        = $mainRepo.Name
        'Shared repository'      = $sharedRepoName
        'Configured branches'    = [string]$branchStates.Count
        'Solution source branch' = $(if ([string]::IsNullOrWhiteSpace($solutionSourceBranch)) { '<none>' } else { $solutionSourceBranch })
        'Publish mode'           = (Get-AzDoPublishSummaryText -PublishResults $repoPublishResults)
        'BUILD validation'       = $(if ($buildValidationEnabled) { 'Enabled' } else { 'Disabled' })
        'BUILD validation environments' = $(if ($enabledBuildBranchStates.Count -gt 0) { @($enabledBuildBranchStates | ForEach-Object { "$($_.BranchName): $($_.BuildValidationEnvironmentName)" }) -join '; ' } else { '<none>' })
        'Configured environments' = [string]$allConfiguredEnvironments.Count
    }) `
    -NextStepLinks @(
        $(foreach ($repoPublishResult in @($repoPublishResults | Where-Object { $_.Mode -eq 'PullRequest' -and -not [string]::IsNullOrWhiteSpace($_.PullRequestUrl) })) {
            @{ Label = "Review and merge the setup pull request for branch '$($repoPublishResult.TargetBranch)'"; Url = $repoPublishResult.PullRequestUrl }
        }),
        @{ Label = 'Run EXPORT for your DEV environment'; Url = (Get-Alm4DataverseDocUrl -RelativePath 'docs/usage/exporting-changes.md' -Ref $ALM4DataverseRef) },
        @{ Label = 'Configure EV and CR values for environments'; Url = (Get-Alm4DataverseDocUrl -RelativePath 'docs/config/azdo-environment-variable-group.md' -Ref $ALM4DataverseRef) },
        @{ Label = 'Run DEPLOY to promote the build'; Url = (Get-Alm4DataverseDocUrl -RelativePath 'docs/usage/deploying.md' -Ref $ALM4DataverseRef) }
    )
