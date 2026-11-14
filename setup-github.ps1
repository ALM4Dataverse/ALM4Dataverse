#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Interactively configures ALM4Dataverse GitHub Actions repositories and identities.
.DESCRIPTION
    Normal setup requires Git and access to manage the selected GitHub repositories,
    Entra app registrations and Dataverse users/roles. ApplyConfig skips Azure sign-in
    but still requires Git and GitHub repository access. Downloads missing setup
    dependencies and a Windows GitHub CLI when necessary. Prompts for authentication,
    shared workflow source, branch/environment mappings, validation and publication
    plans.
    Can create repositories, apps, secrets, federated trusts and administrator users,
    then commit/push workflow changes directly or through pull requests.
    ApplyConfig reads the selected existing repository's committed alm-config.psd1,
    reviews generated changes and publishes them without Azure sign-in, editing settings
    or provisioning GitHub environments, secrets or other provider resources.
    Individual helpers support ShouldProcess, but the full wizard is not a dry run
    and changes across services are not rolled back together.
.PARAMETER TenantId
    Azure tenant identifier for provider setup. Ignored when ApplyConfig is specified.
.PARAMETER UseDeviceAuthentication
    Legacy invocation-compatible switch; current authentication does not consume it.
.PARAMETER ALM4DataverseRef
    Upstream template ref. Releases inject a default; repository development resolves
    the current branch/commit after Git is available, with stable as a fallback.
.PARAMETER ApplyConfig
    Read the committed alm-config.psd1 from an existing repository, review the generated
    changes and publish them without Azure sign-in or running the configuration editors.
.PARAMETER PreviewOnly
    With ApplyConfig, display the generated change summary and select individual file
    diffs to view without publishing. Selected diffs are written without paging.
.EXAMPLE
    .\setup-github.ps1 -TenantId 'contoso.onmicrosoft.com' -ALM4DataverseRef 'stable'
    Starts interactive setup using the specified tenant and template ref.
.EXAMPLE
    .\setup-github.ps1 -ApplyConfig
    Applies the selected existing repository's committed alm-config.psd1 to its workflows.
.EXAMPLE
    .\setup-github.ps1 -ApplyConfig -PreviewOnly
    Previews the changes produced by the selected existing repository's committed alm-config.psd1.
.NOTES
    Development loads helper fragments from setup/. Release preparation embeds those
    fragments so the downloaded installer can run without a repository checkout.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'UseDeviceAuthentication', Justification = 'Legacy installer switch retained for invocation compatibility; current authentication does not consume it.')]
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

# Release builds supply a pinned ref; development defers branch/commit discovery
# until Git has been checked, retaining stable as the fallback.
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

$script:SetupDefaultHelpDocRelativePath = 'docs/setup/github-setup.md'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue' # Suppress progress bars

if ($PreviewOnly -and -not $ApplyConfig) {
    throw 'PreviewOnly requires ApplyConfig.'
}

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
        throw "This script appears to be running in development mode but alm-config-defaults.psd1 was not found at $configPath. Please download the released version from https://github.com/ALM4Dataverse/ALM4Dataverse/releases/latest/download/setup-github.ps1"
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
    'Rnwood.Dataverse.Data.PowerShell' = $rnwoodDataverseVersion
}

# Resolve exact dependency versions before import; do not silently use a newer
# module already installed in the session's search path.
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

$setupGitHubBootstrapPath = if ($script:SetupRepositoryRoot) { Join-Path $script:SetupRepositoryRoot 'setup/setup-github-bootstrap.ps1' } else { $null }
if ($setupGitHubBootstrapPath -and (Test-Path -LiteralPath $setupGitHubBootstrapPath)) {
    . $setupGitHubBootstrapPath
}
else {
    __SETUP_GITHUB_BOOTSTRAP_LIB__
}

# Download GitHub CLI to the temporary setup directory when it is not installed.
$ghCmd = Get-Command gh -ErrorAction SilentlyContinue
if (-not $ghCmd) {
    $ghBinDir = Install-PortableGitHubCli -Destination $TempModuleRoot
    if (-not ($env:PATH -split ';' | Where-Object { $_ -eq $ghBinDir })) {
        $env:PATH = "$ghBinDir;$env:PATH"
    }
    $ghCmd = Get-Command gh -ErrorAction SilentlyContinue
}
if (-not $ghCmd) {
    throw "GitHub CLI was downloaded but is still not available in PATH."
}

# Verify Git is available
$gitCmd = Get-Command git -ErrorAction SilentlyContinue
if (-not $gitCmd) {
    Write-Host ""
    Write-Host "Git is required but was not found." -ForegroundColor Red
    Write-Host "Please install it from https://git-scm.com/ and re-run this script." -ForegroundColor Red
    Write-Host ""
    throw "Git not found."
}

Write-Host "GitHub CLI: $($ghCmd.Source)"
Write-Host "Git: $($gitCmd.Source)"

if ($resolveDevRefAfterGitIsAvailable) {
    $ALM4DataverseRef = Resolve-DevelopmentDefaultAlm4DataverseRef -PrimaryRepositoryPath $upstreamRepo -FallbackRef $ALM4DataverseRef
    Write-Host "Development mode: Resolved ALM4DataverseRef to '$ALM4DataverseRef'" -ForegroundColor Yellow
}

#region GitHub CLI Operations

$setupGitHubSourcePath = if ($script:SetupRepositoryRoot) { Join-Path $script:SetupRepositoryRoot "setup/setup-github.ps1" } else { $null }
if ($setupGitHubSourcePath -and (Test-Path -LiteralPath $setupGitHubSourcePath -PathType Leaf)) {
    . $setupGitHubSourcePath
}
else {
    __SETUP_GITHUB_LIB__
}































































#endregion

#region Entra ID Operations









#endregion

#region Dataverse Operations



















#endregion

#region Repository Setup









































#endregion

# ---------------------------------------------------------------------
#  MAIN SETUP FLOW
# ---------------------------------------------------------------------





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
        -PromptGuidanceDocRelativePath 'docs/setup/github-setup.md' `
        -PromptGuidanceRef $ALM4DataverseRef
    if ($null -eq $setupModeChoice) {
        return
    }
    $script:existingSetupMode = $setupModeChoice -eq 1
}

$authenticationStepName = if ($ApplyConfig) { 'Authenticate with GitHub' } else { 'Authenticate with GitHub and Azure' }
$startupSteps = @(
    [pscustomobject]@{
        Name = $authenticationStepName
        HelpDocRelativePath = 'docs/setup/github-setup.md'
        LockAfterCompletion = $true
        Action = {
            $script:githubAuthentication = Initialize-GitHubSetupAuthentication -TenantId $TenantId -ApplyConfig:$ApplyConfig
            $script:TenantId = $script:githubAuthentication.TenantId
        }
    }
    [pscustomobject]@{
        Name = 'Select and inspect application repository'
        HelpDocRelativePath = 'docs/setup/github-setup.md'
        LockAfterCompletion = $true
        Action = {
            $script:githubRepositoryContext = Initialize-GitHubApplicationRepositoryContext `
                -TenantId $script:TenantId `
                -ApplyConfig:$ApplyConfig `
                -ExistingSetupMode:$existingSetupMode
        }
    }
)

try {
    Invoke-SetupWizard `
        -Title 'GitHub setup prerequisites' `
        -Steps $startupSteps `
        -HelpDocRelativePath 'docs/setup/github-setup.md' `
        -HelpRef $ALM4DataverseRef | Out-Null
}
catch {
    if ($_.Exception.Message -eq 'Setup cancelled before changes were applied.' -or (Test-IsSetupWizardBackException -Exception $_.Exception)) {
        Write-Host 'GitHub setup cancelled before branch configuration.' -ForegroundColor Yellow
        return
    }
    throw
}

$initialSetupSteps = @()

$TenantId = $script:githubAuthentication.TenantId
$repoOwner = $script:githubRepositoryContext.RepoOwner
$repoName = $script:githubRepositoryContext.RepoName
$repoFullName = $script:githubRepositoryContext.RepoFullName
$repoIdentity = $script:githubRepositoryContext.RepoIdentity
$repoOwnerId = $script:githubRepositoryContext.RepoOwnerId
$repoId = $script:githubRepositoryContext.RepoId
$useImmutableWifSubject = $script:githubRepositoryContext.UseImmutableWifSubject
$defaultBranch = $script:githubRepositoryContext.DefaultBranch
$cloneRoot = $script:githubRepositoryContext.CloneRoot
$existingSetupState = $script:githubRepositoryContext.ExistingSetupState
$isNewRepository = [bool]$script:githubRepositoryContext.IsNewRepository

$existingConfiguration = Get-OptionalObjectPropertyValue -InputObject $existingSetupState -PropertyName 'ExistingConfiguration'
if ($ApplyConfig) {
    [void](Assert-AlmSetupConfigurationForApply -Configuration $existingConfiguration -Provider GitHub)
}

# ---------------------------------------------------------------------
Write-Section `
    -Message "Preparing Shared Workflow Repository Selection"

$upstreamWorkflowRepoFullName = Resolve-GitHubRepoFullNameFromSource -Source $upstreamRepo -Fallback 'ALM4Dataverse/ALM4Dataverse'
$upstreamGitSource = Resolve-UpstreamGitRemoteSource -ConfiguredSource $upstreamRepo -GitHubFullName $upstreamWorkflowRepoFullName

Write-Host "Upstream workflow source: $upstreamWorkflowRepoFullName" -ForegroundColor DarkGray
Write-Host "Using ALM4Dataverse ref: $ALM4DataverseRef" -ForegroundColor DarkGray


$existingDevEnvironment = $existingSetupState.DevEnvironment
$existingDevEnvironmentUrl = $null

if ($existingDevEnvironment) {
    foreach ($urlPropertyName in @('Url', 'EnvironmentUrl', 'DataverseUrl', 'WebApplicationUrl')) {
        if ($existingDevEnvironment.PSObject.Properties.Name -contains $urlPropertyName) {
            $candidateUrl = ConvertTo-NormalizedEnvironmentUrl -Url $existingDevEnvironment.$urlPropertyName
            if (-not [string]::IsNullOrWhiteSpace($candidateUrl)) {
                $existingDevEnvironmentUrl = $candidateUrl
                break
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($existingDevEnvironmentUrl) -and $existingDevEnvironment.PSObject.Properties.Name -contains 'Endpoints' -and $existingDevEnvironment.Endpoints) {
        if ($existingDevEnvironment.Endpoints.ContainsKey('WebApplication')) {
            $existingDevEnvironmentUrl = ConvertTo-NormalizedEnvironmentUrl -Url $existingDevEnvironment.Endpoints['WebApplication']
        }
    }

}

if ($existingSetupState.SharedWorkflowRepository) {
    Write-Host "Existing shared workflow repository detected: $($existingSetupState.SharedWorkflowRepository)" -ForegroundColor DarkGray
}
if ($existingSetupState.SharedWorkflowReference) {
    Write-Host "Existing shared workflow ref detected: $($existingSetupState.SharedWorkflowReference)" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------
Write-Section -Message $(if ($ApplyConfig) { 'Reading shared workflow source from alm-config.psd1' } else { 'Selecting Shared Workflow Repository' })

$sharedWorkflowRepositoryValidationError = ''
if ($ApplyConfig) {
    $sharedWorkflowRepository = [string]$existingConfiguration.repository
    $sharedWorkflowReference = [string]$existingConfiguration.ref
}
elseif ($existingSetupMode) {
    $repositoryValidationState = Get-GitHubSharedWorkflowRepositoryValidationState `
        -Repository ([string]$existingSetupState.SharedWorkflowRepository) `
        -Reference ([string]$existingSetupState.SharedWorkflowReference) `
        -UpstreamFullName $upstreamWorkflowRepoFullName `
        -DefaultOwner $repoOwner `
        -UpstreamGitSource $upstreamGitSource `
        -ALM4DataverseRef $ALM4DataverseRef
    $sharedWorkflowRepository = [string]$repositoryValidationState.Repository
    $sharedWorkflowReference = [string]$repositoryValidationState.Reference
    $sharedWorkflowRepositoryValidationError = [string]$repositoryValidationState.ValidationError
    if (-not [string]::IsNullOrWhiteSpace($sharedWorkflowRepositoryValidationError)) {
        Write-Warning "$sharedWorkflowRepositoryValidationError Select the shared workflow repository menu step to choose an accessible repository."
    }
}
else {
    $preferredSharedWorkflowRepository = [string]$existingSetupState.SharedWorkflowRepository
    if ([string]::IsNullOrWhiteSpace($preferredSharedWorkflowRepository)) {
        $sharedWorkflowRepo = Invoke-WithErrorHandling `
            -OperationName 'Selecting shared workflow repository' `
            -StatusMessage 'Selecting a shared workflow repository...' `
            -ScriptBlock {
                Initialize-GitHubSharedWorkflowFork `
                    -UpstreamFullName $upstreamWorkflowRepoFullName `
                    -DefaultOwner $repoOwner `
                    -UpstreamGitSource $upstreamGitSource `
                    -Reference $ALM4DataverseRef `
                    -SelectOnly
            }
    }
    else {
        try {
            $sharedWorkflowRepo = Invoke-WithErrorHandling `
                -OperationName "Accessing configured shared workflow repository '$preferredSharedWorkflowRepository'" `
                -StatusMessage "Accessing configured shared workflow repository '$preferredSharedWorkflowRepository'..." `
                -ScriptBlock {
                    Initialize-GitHubSharedWorkflowFork `
                        -UpstreamFullName $upstreamWorkflowRepoFullName `
                        -DefaultOwner $repoOwner `
                        -UpstreamGitSource $upstreamGitSource `
                        -Reference $ALM4DataverseRef `
                        -PreferredRepositoryFullName $preferredSharedWorkflowRepository `
                        -SelectOnly `
                        -UsePreferredRepository
                }
        }
        catch {
            if (Test-IsUserInterruptException -Exception $_.Exception) {
                throw
            }
            Write-Warning "Could not access configured shared workflow repository '$preferredSharedWorkflowRepository': $($_.Exception.Message) Select an accessible repository instead."
            $sharedWorkflowRepo = Invoke-WithErrorHandling `
                -OperationName 'Selecting a replacement shared workflow repository' `
                -StatusMessage 'Select an accessible shared workflow repository...' `
                -ScriptBlock {
                    Initialize-GitHubSharedWorkflowFork `
                        -UpstreamFullName $upstreamWorkflowRepoFullName `
                        -DefaultOwner $repoOwner `
                        -UpstreamGitSource $upstreamGitSource `
                        -Reference $ALM4DataverseRef `
                        -PreferredRepositoryFullName $preferredSharedWorkflowRepository `
                        -SelectOnly
                }
        }
    }

    $sharedWorkflowRepository = $sharedWorkflowRepo.nameWithOwner
    $sharedWorkflowReference = if (
        $sharedWorkflowRepository -ieq [string]$existingSetupState.SharedWorkflowRepository
    ) {
        [string]$existingSetupState.SharedWorkflowReference
    }
    else {
        $null
    }
    if ([string]::IsNullOrWhiteSpace($sharedWorkflowReference)) {
        $sharedWorkflowReference = 'main'
        if ($sharedWorkflowRepo.defaultBranchRef -and $sharedWorkflowRepo.defaultBranchRef.name) {
            $sharedWorkflowReference = $sharedWorkflowRepo.defaultBranchRef.name
        }
    }
}

Write-Host "Shared workflow repository: $sharedWorkflowRepository" -ForegroundColor Green
Write-Host "Shared workflow reference: $sharedWorkflowReference" -ForegroundColor Green

$script:sharedWorkflowRepositoryState = [ordered]@{
    Repository      = $sharedWorkflowRepository
    Reference       = $sharedWorkflowReference
    ValidationError = $sharedWorkflowRepositoryValidationError
}
$initialSetupSteps += [pscustomobject]@{
    Name = 'Select shared workflow repository'
    HelpDocRelativePath = 'docs/setup/github-setup.md'
    Summary = {
        if ([string]::IsNullOrWhiteSpace([string]$script:sharedWorkflowRepositoryState.ValidationError)) {
            "$($script:sharedWorkflowRepositoryState.Repository) ($($script:sharedWorkflowRepositoryState.Reference))"
        }
        else {
            "Unavailable: $($script:sharedWorkflowRepositoryState.ValidationError)"
        }
    }
    Action = {
        [void](Select-GitHubSharedWorkflowRepositoryState `
            -RepositoryState $script:sharedWorkflowRepositoryState `
            -UpstreamFullName $upstreamWorkflowRepoFullName `
            -DefaultOwner $repoOwner `
            -UpstreamGitSource $upstreamGitSource `
            -Reference $ALM4DataverseRef)
        $selectedRepository = [string]$script:sharedWorkflowRepositoryState.Repository
        $selectedReference = [string]$script:sharedWorkflowRepositoryState.Reference
        $script:sharedWorkflowRepository = $selectedRepository
        $script:sharedWorkflowReference = $selectedReference
    }
    IsComplete = [string]::IsNullOrWhiteSpace([string]$script:sharedWorkflowRepositoryState.ValidationError)
    IsLocked = [bool]$ApplyConfig
}
$initialSetupSteps += [pscustomobject]@{
    Name = 'Check and update shared workflow repository version'
    HelpDocRelativePath = 'docs/setup/github-setup.md'
    Summary = {
        if ($ApplyConfig) {
            'Skipped by -ApplyConfig'
        }
        else {
            "Check against $ALM4DataverseRef"
        }
    }
    Action = {
        [void](Update-GitHubSharedWorkflowRepositoryState `
            -RepositoryState $script:sharedWorkflowRepositoryState `
            -UpstreamFullName $upstreamWorkflowRepoFullName `
            -DefaultOwner $repoOwner `
            -UpstreamGitSource $upstreamGitSource `
            -Reference $ALM4DataverseRef)
        $script:sharedWorkflowRepository = [string]$script:sharedWorkflowRepositoryState.Repository
        $script:sharedWorkflowReference = [string]$script:sharedWorkflowRepositoryState.Reference
    }
    IsComplete = [bool]$ApplyConfig
    IsLocked = [bool]$ApplyConfig
}

$existingConfiguration = Get-OptionalObjectPropertyValue -InputObject $existingSetupState -PropertyName 'ExistingConfiguration'
$enableEnvironmentApprovals = $false
$environmentApprovalReviewerIds = @()
if ($ApplyConfig) {
    $useGitHubEnvironments = if ($existingConfiguration.Contains('GitHubUseEnvironments')) {
        if ($existingConfiguration.GitHubUseEnvironments -isnot [bool]) {
            throw 'GitHubUseEnvironments in alm-config.psd1 must be a Boolean.'
        }
        [bool]$existingConfiguration.GitHubUseEnvironments
    }
    else {
        $true
    }

    $useRepositoryVariablePrefix = if ($existingConfiguration.Contains('GitHubUseRepositoryVariablePrefix')) {
        if ($existingConfiguration.GitHubUseRepositoryVariablePrefix -isnot [bool]) {
            throw 'GitHubUseRepositoryVariablePrefix in alm-config.psd1 must be a Boolean.'
        }
        [bool]$existingConfiguration.GitHubUseRepositoryVariablePrefix
    }
    else {
        $true
    }

    $useImmutableWifSubject = if ($existingConfiguration.Contains('GitHubUseImmutableWifSubject')) {
        if ($existingConfiguration.GitHubUseImmutableWifSubject -isnot [bool]) {
            throw 'GitHubUseImmutableWifSubject in alm-config.psd1 must be a Boolean.'
        }
        [bool]$existingConfiguration.GitHubUseImmutableWifSubject
    }
    else {
        $false
    }

    $deploymentPromotionMode = if ($existingConfiguration.Contains('GitHubDeploymentPromotionMode')) {
        [string]$existingConfiguration.GitHubDeploymentPromotionMode
    }
    else {
        'manual-gate-tag'
    }
    if ($deploymentPromotionMode -notin @('manual-gate-tag', 'environment-approval')) {
        throw "Unsupported GitHubDeploymentPromotionMode '$deploymentPromotionMode' in alm-config.psd1."
    }
    $enableEnvironmentApprovals = $deploymentPromotionMode -eq 'environment-approval'
    if ($enableEnvironmentApprovals -and -not $useGitHubEnvironments) {
        throw 'GitHubDeploymentPromotionMode selects environment-approval, but GitHubUseEnvironments is false.'
    }
}
else {
    # Preserve discovered credential storage only for normal interactive setup.
    $useGitHubEnvironments = $false
    $useRepositoryVariablePrefix = $existingSetupState.CredentialStorageScope -ne 'RepositoryUnprefixed'
    $deploymentPromotionMode = 'manual-gate-tag'

    $environmentCapabilities = Invoke-WithSpectreStatus -Status "Checking GitHub environment capabilities for '$repoFullName'..." -ScriptBlock {
        Get-GitHubEnvironmentCapability -Owner $repoOwner -Repo $repoName -ApprovalReviewerId $script:ghUserId
    }

    if ($existingSetupState.CredentialStorageScope -eq 'Environment' -and $environmentCapabilities.EnvironmentsAvailable) {
        $useGitHubEnvironments = $true
        if ($environmentCapabilities.ApprovalsAvailable) {
            $enableEnvironmentApprovals = $true
            $deploymentPromotionMode = 'environment-approval'
            if ($script:ghUserId) {
                $environmentApprovalReviewerIds = @($script:ghUserId)
            }
        }

        Write-Host 'Existing repository configuration already uses GitHub environments, so setup will preserve that as the baseline.' -ForegroundColor Green
    }
    elseif ($existingSetupState.CredentialStorageScope -in @('RepositoryPrefix', 'RepositoryUnprefixed')) {
        $useGitHubEnvironments = $false
        $enableEnvironmentApprovals = $false
        $deploymentPromotionMode = 'manual-gate-tag'
        if ($useRepositoryVariablePrefix) {
            Write-Host 'Existing repository configuration uses environment-prefixed repo-level credentials, so setup will preserve that as the baseline.' -ForegroundColor Green
        }
        else {
            Write-Host 'Existing repository configuration uses unprefixed repo-level credentials, so setup will preserve that as the baseline.' -ForegroundColor Green
        }
    }
    elseif ($environmentCapabilities.EnvironmentsAvailable) {
        $useGitHubEnvironments = $true
        if ($environmentCapabilities.ApprovalsAvailable) {
            $enableEnvironmentApprovals = $true
            $deploymentPromotionMode = 'environment-approval'
            if ($script:ghUserId) {
                $environmentApprovalReviewerIds = @($script:ghUserId)
            }

            Write-Host "GitHub environments and required reviewers are available. Setup will configure environment credentials and approval gates." -ForegroundColor Green
        }
        else {
            Write-Host "GitHub environments are available, but required reviewers are unavailable. Setup will use environment-scoped credentials and tag-based promotion." -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "GitHub environments are unavailable for this repository. Setup will use repo-level credentials and tag-based promotion." -ForegroundColor Yellow
    }

    if (-not [string]::IsNullOrWhiteSpace($environmentCapabilities.Message)) {
        Write-Host $environmentCapabilities.Message -ForegroundColor DarkGray
    }

    $hasPersistedGitHubSettings = -not $ApplyConfig -and
        $existingConfiguration -is [System.Collections.IDictionary] -and
        [string](Get-OptionalObjectPropertyValue -InputObject $existingConfiguration -PropertyName 'provider') -ieq 'GitHub'
    if ($hasPersistedGitHubSettings) {
        if ($existingConfiguration.Contains('GitHubUseEnvironments')) {
            if ($existingConfiguration.GitHubUseEnvironments -isnot [bool]) {
                throw 'GitHubUseEnvironments in alm-config.psd1 must be a Boolean.'
            }
            $useGitHubEnvironments = [bool]$existingConfiguration.GitHubUseEnvironments
        }
        if ($useGitHubEnvironments -and -not $environmentCapabilities.EnvironmentsAvailable) {
            throw 'alm-config.psd1 enables GitHub environments, but this repository cannot use them. Update the GitHub settings or repository plan/permissions before continuing.'
        }

        if ($existingConfiguration.Contains('GitHubUseRepositoryVariablePrefix')) {
            if ($existingConfiguration.GitHubUseRepositoryVariablePrefix -isnot [bool]) {
                throw 'GitHubUseRepositoryVariablePrefix in alm-config.psd1 must be a Boolean.'
            }
            $useRepositoryVariablePrefix = [bool]$existingConfiguration.GitHubUseRepositoryVariablePrefix
        }

        if ($existingConfiguration.Contains('GitHubDeploymentPromotionMode')) {
            $configuredPromotionMode = [string]$existingConfiguration.GitHubDeploymentPromotionMode
            if ($configuredPromotionMode -notin @('manual-gate-tag', 'environment-approval')) {
                throw "Unsupported GitHubDeploymentPromotionMode '$configuredPromotionMode' in alm-config.psd1."
            }
            $deploymentPromotionMode = $configuredPromotionMode
            $enableEnvironmentApprovals = $configuredPromotionMode -eq 'environment-approval'
            if ($enableEnvironmentApprovals -and (-not $useGitHubEnvironments -or -not $environmentCapabilities.ApprovalsAvailable)) {
                throw 'alm-config.psd1 selects environment-approval promotion, but GitHub environments with required reviewers are unavailable.'
            }
            if ($enableEnvironmentApprovals -and $script:ghUserId) {
                $environmentApprovalReviewerIds = @($script:ghUserId)
            }
        }

        if ($existingConfiguration.Contains('GitHubUseImmutableWifSubject')) {
            if ($existingConfiguration.GitHubUseImmutableWifSubject -isnot [bool]) {
                throw 'GitHubUseImmutableWifSubject in alm-config.psd1 must be a Boolean.'
            }
            $useImmutableWifSubject = [bool]$existingConfiguration.GitHubUseImmutableWifSubject
        }
    }
}

$providerOptions = [ordered]@{
    GitHubUseEnvironments               = [bool]$useGitHubEnvironments
    GitHubDeploymentPromotionMode       = [string]$deploymentPromotionMode
    GitHubUseRepositoryVariablePrefix   = [bool]$useRepositoryVariablePrefix
    GitHubUseImmutableWifSubject        = [bool]$useImmutableWifSubject
}

Write-Host "DEPLOY workflow promotion mode: $deploymentPromotionMode" -ForegroundColor DarkGray

$postApplyAction = $null
if (-not $ApplyConfig) {
    $postApplyAction = {
        param($setupResult)
        Invoke-GitHubSetupPostApply `
            -SetupResult $setupResult `
            -RepoIdentity $repoIdentity `
            -TenantId $TenantId `
            -RepoOwner $repoOwner `
            -RepoName $repoName `
            -RepoFullName $repoFullName `
            -RepoOwnerId $repoOwnerId `
            -RepoId $repoId `
            -UseGitHubEnvironments $useGitHubEnvironments `
            -UseRepositoryVariablePrefix $useRepositoryVariablePrefix `
            -EnableEnvironmentApprovals $enableEnvironmentApprovals `
            -RequiredReviewerIds $environmentApprovalReviewerIds
    }
}

try {
    $githubSetupResult = Invoke-GitHubBranchAwareSetup `
        -CloneRoot $cloneRoot `
        -RepoOwner $repoOwner `
        -RepoName $repoName `
        -RepoFullName $repoFullName `
        -RepoIdentity $repoIdentity `
        -DefaultBranch $defaultBranch `
        -TenantId $TenantId `
        -ExistingSetupState $existingSetupState `
        -SharedWorkflowRepository $sharedWorkflowRepository `
        -SharedWorkflowReference $sharedWorkflowReference `
        -SharedWorkflowRepositoryState $script:sharedWorkflowRepositoryState `
        -UpstreamGitSource $upstreamGitSource `
        -ALM4DataverseRef $ALM4DataverseRef `
        -UseGitHubEnvironments $useGitHubEnvironments `
        -DeploymentPromotionMode $deploymentPromotionMode `
        -ProviderOptions $providerOptions `
        -PrerequisiteSteps $initialSetupSteps `
        -PostApplyAction $postApplyAction `
        -ApplyConfig:$ApplyConfig `
        -IsNewRepository:$isNewRepository `
        -PreviewOnly:$PreviewOnly `
        -UseRepositoryVariablePrefix $useRepositoryVariablePrefix `
        -EnableEnvironmentApprovals $enableEnvironmentApprovals `
        -RequiredReviewerIds $environmentApprovalReviewerIds
}
catch {
    if (
        $_.Exception.Message -in @('Setup cancelled before changes were applied.', 'Setup exited without applying changes.') -or
        (Test-IsSetupWizardBackException -Exception $_.Exception)
    ) {
        Write-Host 'GitHub setup exited before applying changes.' -ForegroundColor Yellow
        if ($cloneRoot -and (Test-Path -LiteralPath $cloneRoot)) {
            try { Remove-Item -LiteralPath $cloneRoot -Recurse -Force -ErrorAction Stop } catch { Write-Verbose 'Could not remove the repository clone; continuing cleanup.' }
        }
        return
    }
    throw
}

$branchStates = @($githubSetupResult.BranchStates)
$solutionSourceBranch = $githubSetupResult.SolutionSourceBranch
$buildValidationEnabled = @($branchStates | Where-Object { $_.BuildValidationEnabled }).Count -gt 0
$enabledBuildBranchStates = @($branchStates | Where-Object { $_.BuildValidationEnabled })
$useImmutableWifSubject = [bool]$githubSetupResult.UseImmutableWifSubject
$repoPublishResults = @($githubSetupResult.PublishResults)
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

# Apply includes repository publication and provider configuration. Remove the clone
# after the retryable setup menu has completed successfully.
try { Remove-Item -LiteralPath $cloneRoot -Recurse -Force -ErrorAction Stop } catch { Write-Verbose 'Could not remove the repository clone; continuing cleanup.' }

if ($PreviewOnly) {
    return
}

Show-SetupCompletionScreen `
    -Heading 'GitHub Actions setup completed successfully!' `
    -AccessLabel 'Open your GitHub Actions page' `
    -AccessUrl "https://github.com/$repoFullName/actions" `
    -SummaryValues ([ordered]@{
        'Repository'              = $repoFullName
        'Shared workflow source'  = $sharedWorkflowRepository
        'Configured branches'     = [string]$branchStates.Count
        'Solution source branch'  = $(if ([string]::IsNullOrWhiteSpace($solutionSourceBranch)) { '<none>' } else { $solutionSourceBranch })
        'Repository publish'      = (Get-GitHubPublishSummaryText -PublishResults $repoPublishResults)
        'Promotion mode'          = $deploymentPromotionMode
        'Credential storage'      = $(if ($useGitHubEnvironments) { 'GitHub environments' } elseif ($useRepositoryVariablePrefix) { 'Environment-prefixed repository variables + environment secrets' } else { 'Unprefixed repository variables + environment secrets' })
        'BUILD validation'        = $(if ($buildValidationEnabled) { 'Enabled' } else { 'Disabled' })
        'BUILD validation environments' = $(if ($enabledBuildBranchStates.Count -gt 0) { @($enabledBuildBranchStates | ForEach-Object { "$($_.BranchName): $($_.BuildValidationEnvironmentName)" }) -join '; ' } else { '<none>' })
        'Configured environments' = [string]$allConfiguredEnvironments.Count
    }) `
    -NextStepLinks @(
        $(foreach ($repoPublishResult in @($repoPublishResults | Where-Object { $_.Mode -eq 'PullRequest' -and -not [string]::IsNullOrWhiteSpace($_.PullRequestUrl) })) {
            @{ Label = "Review and merge the setup pull request for branch '$($repoPublishResult.TargetBranch)'"; Url = $repoPublishResult.PullRequestUrl }
        }),
        @{ Label = 'Run EXPORT for your DEV environment'; Url = (Get-Alm4DataverseDocUrl -RelativePath 'docs/usage/exporting-changes.md' -Ref $ALM4DataverseRef) },
        @{ Label = 'Configure EV and CR values for environments'; Url = (Get-Alm4DataverseDocUrl -RelativePath 'docs/setup/github-variables.md' -Ref $ALM4DataverseRef) },
        @{ Label = 'Run DEPLOY to promote the build'; Url = (Get-Alm4DataverseDocUrl -RelativePath 'docs/usage/deploying.md' -Ref $ALM4DataverseRef) }
    )
