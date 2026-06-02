[CmdletBinding()]
param(
    [Parameter()]
    [string]$TenantId,

    [Parameter()]
    [switch]$UseDeviceAuthentication,

    [Parameter()]
    [string]$ALM4DataverseRef
)

$resolveDevRefAfterGitIsAvailable = $false

# ALM4DataverseRef default handling - injected during release, fallback for development
if (-not $ALM4DataverseRef) {
    $injectedRef = '__ALM4DATAVERSE_REF__'
    # Check if placeholder was replaced by comparing if it starts with double underscore
    if ($injectedRef -like '__*') {
        # Placeholders not replaced - development mode.
        # We resolve this after Git is available to support local branch/commit selection.
        $resolveDevRefAfterGitIsAvailable = $true
        Write-Host "Development mode: Will resolve ALM4DataverseRef from current branch/commit after Git is available (fallback: 'stable')." -ForegroundColor Yellow
        $ALM4DataverseRef = 'stable'
    } else {
        # Placeholder was replaced during release - use the injected value
        $ALM4DataverseRef = $injectedRef
    }
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue' # Suppress progress bars

# This script is designed to be downloadable and self-contained.
# It's therefore quite long, as it includes all necessary functions and logic.
# Version numbers and ALM4Dataverse ref are injected during the release process.

# Shared helper functions are loaded from setup-common.ps1 during development
# and embedded during release preparation for the downloadable one-file script.
$setupCommonPath = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'setup-common.ps1' } else { $null }
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

# Version numbers are injected during release process
# For development/testing, fall back to reading from config file if placeholders are present
$rnwoodDataverseVersion = '__RNWOOD_DATAVERSE_VERSION__'
# Check if placeholder was replaced by comparing if it starts with double underscore
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
# Check if placeholder was replaced by comparing if it starts with double-underscore
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

# Ensure modules are downloaded before loading so we can patch them
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

# Verify GitHub CLI is available
$ghCmd = Get-Command gh -ErrorAction SilentlyContinue
if (-not $ghCmd) {
    Write-Host ""
    Write-Host "GitHub CLI (gh) is required but was not found." -ForegroundColor Red
    Write-Host "Please install it from https://cli.github.com/ and re-run this script." -ForegroundColor Red
    Write-Host ""
    throw "GitHub CLI (gh) not found."
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

function Invoke-GhApi {
    <#
    .SYNOPSIS
        Calls the GitHub REST API using the gh CLI.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [Parameter()][string]$Method = 'GET',
        [Parameter()][object]$Body,
        [Parameter()][switch]$AllowNotFound
    )

    $ghArgs = @('api', '--method', $Method, $Endpoint)
    
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'

        if ($Body) {
            $json = $Body | ConvertTo-Json -Depth 10 -Compress
            $ghArgs += @('--input', '-')

            $result = @($json | & gh @ghArgs 2>&1)
        }
        else {
            $result = @(& gh @ghArgs 2>&1)
        }

        $ghExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($ghExitCode -ne 0) {
        $errText = @($result | ForEach-Object { [string]$_ }) -join "`n"
        if ($AllowNotFound -and ($errText -match '404' -or $errText -match 'Not Found')) {
            return $null
        }
        throw "gh api call failed (exit code $ghExitCode): $errText"
    }
    
    if ($result) {
        try {
            return (@($result) -join [Environment]::NewLine) | ConvertFrom-Json
        }
        catch {
            return $result
        }
    }
    return $null
}

function Ensure-GitHubEnvironment {
    <#
    .SYNOPSIS
        Ensures a GitHub repository environment exists and optionally configures approvals.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter()][int[]]$RequiredReviewerIds,
        [Parameter()][switch]$EnableApprovals
    )

    Write-Host "Ensuring GitHub environment '$EnvironmentName'..." -ForegroundColor DarkGray

    # Check if environment already exists
    $existing = Invoke-GhApi -Endpoint "repos/$Owner/$Repo/environments/$([Uri]::EscapeDataString($EnvironmentName))" -AllowNotFound

    $body = $null
    $appliedApprovals = $false
    if ($EnableApprovals) {
        $reviewers = @()
        foreach ($reviewerId in @($RequiredReviewerIds)) {
            if ($reviewerId -gt 0) {
                $reviewers += @{ type = 'User'; id = $reviewerId }
            }
        }

        if ($reviewers.Count -gt 0) {
            $body = @{ reviewers = $reviewers }
            $appliedApprovals = $true
        }
        else {
            Write-Host "Approvals were requested but no valid reviewer IDs were supplied; configuring environment without required reviewers." -ForegroundColor Yellow
        }
    }

    $action = if ($existing) { 'Updating' } else { 'Creating' }
    Write-Host "$action environment '$EnvironmentName'..." -ForegroundColor Yellow
    if ($body) {
        $updated = Invoke-GhApi -Endpoint "repos/$Owner/$Repo/environments/$([Uri]::EscapeDataString($EnvironmentName))" -Method 'PUT' -Body $body
    }
    else {
        $updated = Invoke-GhApi -Endpoint "repos/$Owner/$Repo/environments/$([Uri]::EscapeDataString($EnvironmentName))" -Method 'PUT'
    }

    if ($appliedApprovals) {
        Write-Host "Configured environment '$EnvironmentName' with required reviewers." -ForegroundColor DarkGray
    }
    else {
        Write-Host "Configured environment '$EnvironmentName'." -ForegroundColor DarkGray
    }

    return $updated
}

function Set-GitHubEnvironmentSecret {
    <#
    .SYNOPSIS
        Sets a secret in a GitHub repository environment using the gh CLI.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][string]$SecretName,
        [Parameter(Mandatory)][string]$SecretValue
    )

    Write-Host "Setting secret '$SecretName' in environment '$EnvironmentName'..." -ForegroundColor DarkGray

    # Avoid piping to native commands here: PowerShell appends a trailing newline
    # when sending strings over stdin, which would corrupt client secret values.
    $normalizedSecretValue = ($SecretValue -replace "[\r\n]+$", "")

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $result = @(& gh secret set $SecretName `
            --repo "$Owner/$Repo" `
            --env $EnvironmentName `
            --body $normalizedSecretValue 2>&1)
        $setExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($setExitCode -ne 0) {
        throw "Failed to set secret '$SecretName': $($result -join "`n")"
    }
    Write-Host "Set secret '$SecretName'." -ForegroundColor DarkGray
}

function Set-GitHubEnvironmentVariable {
    <#
    .SYNOPSIS
        Sets a variable in a GitHub repository environment using the gh CLI.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][string]$VariableName,
        [Parameter(Mandatory)][string]$VariableValue
    )

    Write-Host "Setting variable '$VariableName' in environment '$EnvironmentName'..." -ForegroundColor DarkGray

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $result = @(& gh variable set $VariableName `
            --repo "$Owner/$Repo" `
            --env $EnvironmentName `
            --body $VariableValue 2>&1)
        $setExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($setExitCode -ne 0) {
        throw "Failed to set variable '$VariableName': $($result -join "`n")"
    }
    Write-Host "Set variable '$VariableName'." -ForegroundColor DarkGray
}

function Set-GitHubRepoSecret {
    <#
    .SYNOPSIS
        Sets a repository-level secret using the gh CLI.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$SecretName,
        [Parameter(Mandatory)][string]$SecretValue
    )

    Write-Host "Setting repo-level secret '$SecretName'..." -ForegroundColor DarkGray

    # Avoid piping to native commands here: PowerShell appends a trailing newline
    # when sending strings over stdin, which would corrupt client secret values.
    $normalizedSecretValue = ($SecretValue -replace "[\r\n]+$", "")

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $result = @(& gh secret set $SecretName `
            --repo "$Owner/$Repo" `
            --body $normalizedSecretValue 2>&1)
        $setExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($setExitCode -ne 0) {
        throw "Failed to set repo secret '$SecretName': $($result -join "`n")"
    }
    Write-Host "Set repo-level secret '$SecretName'." -ForegroundColor DarkGray
}

function Set-GitHubRepoVariable {
    <#
    .SYNOPSIS
        Sets a repository-level variable using the gh CLI.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$VariableName,
        [Parameter(Mandatory)][string]$VariableValue
    )

    Write-Host "Setting repo-level variable '$VariableName'..." -ForegroundColor DarkGray

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $result = @(& gh variable set $VariableName `
            --repo "$Owner/$Repo" `
            --body $VariableValue 2>&1)
        $setExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($setExitCode -ne 0) {
        throw "Failed to set repo variable '$VariableName': $($result -join "`n")"
    }
    Write-Host "Set repo-level variable '$VariableName'." -ForegroundColor DarkGray
}

function Get-GitHubEnvironmentCapabilities {
    <#
    .SYNOPSIS
        Detects whether GitHub environments and environment approval rules are available for a repository.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter()][int]$ApprovalReviewerId
    )

    $probeName = "alm4dataverse-setup-probe-$([guid]::NewGuid().ToString('n').Substring(0, 8))"
    $probeEndpoint = "repos/$Owner/$Repo/environments/$([Uri]::EscapeDataString($probeName))"

    $result = [ordered]@{
        EnvironmentsAvailable = $false
        ApprovalsAvailable    = $false
        Message               = ''
    }

    try {
        try {
            # Probe base environment availability without optional protection rules.
            [void](Invoke-GhApi -Endpoint $probeEndpoint -Method 'PUT')
            $result.EnvironmentsAvailable = $true
        }
        catch {
            $result.Message = "GitHub environments are not available for this repository: $($_.Exception.Message)"
        }

        if ($result.EnvironmentsAvailable) {
            if ($ApprovalReviewerId -gt 0) {
                try {
                    # Probe required-reviewer availability separately from base environments support.
                    [void](Invoke-GhApi -Endpoint $probeEndpoint -Method 'PUT' -Body @{ reviewers = @(@{ type = 'User'; id = $ApprovalReviewerId }) })
                    $result.ApprovalsAvailable = $true
                    $result.Message = 'GitHub environments and required reviewers are available.'
                }
                catch {
                    $result.Message = "GitHub environments are available, but required reviewers are not available for this repository: $($_.Exception.Message)"
                }
            }
            else {
                $result.Message = 'GitHub environments are available, but required-reviewer support could not be probed because no reviewer id was provided.'
            }
        }
    }
    finally {
        try {
            [void](Invoke-GhApi -Endpoint $probeEndpoint -Method 'DELETE' -AllowNotFound)
        }
        catch {
            # ignore probe cleanup errors
        }
    }

    return [pscustomobject]$result
}

function Get-GitHubEnvironmentPrefix {
    <#
    .SYNOPSIS
        Derives a repository-level prefix from an environment name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EnvironmentName
    )

    $normalized = ($EnvironmentName.Trim().ToUpperInvariant() -replace '[^A-Z0-9]+', '_').Trim('_')
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        throw "Could not derive a prefix from environment name '$EnvironmentName'."
    }

    return "${normalized}_"
}

function Set-GitHubPrefixedEnvironmentCredentials {
    <#
    .SYNOPSIS
        Stores per-environment credentials as prefixed repository-level variables/secrets.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][object]$Credentials,
        [Parameter(Mandatory)][string]$DataverseUrl,
        [Parameter(Mandatory)][string]$ServiceAccountUPN
    )

    $prefix = Get-GitHubEnvironmentPrefix -EnvironmentName $EnvironmentName
    Write-Host "Setting prefixed repo-level credentials for '$EnvironmentName' using prefix '$prefix'..." -ForegroundColor DarkGray

    Set-GitHubRepoVariable -Owner $Owner -Repo $Repo -VariableName "${prefix}AZURE_CLIENT_ID" -VariableValue $Credentials.ApplicationId
    Set-GitHubRepoVariable -Owner $Owner -Repo $Repo -VariableName "${prefix}AZURE_TENANT_ID" -VariableValue $Credentials.TenantId

    if ($Credentials.AuthType -eq 'Secret' -and $Credentials.ClientSecret) {
        Set-GitHubRepoSecret -Owner $Owner -Repo $Repo -SecretName "${prefix}AZURE_CLIENT_SECRET" -SecretValue $Credentials.ClientSecret
    }

    Set-GitHubRepoVariable -Owner $Owner -Repo $Repo -VariableName "${prefix}DATAVERSE_URL" -VariableValue $DataverseUrl
    Set-GitHubRepoVariable -Owner $Owner -Repo $Repo -VariableName "${prefix}DATAVERSE_SERVICE_ACCOUNT_UPN" -VariableValue $ServiceAccountUPN
}

function Get-GitHubRepoList {
    <#
    .SYNOPSIS
        Returns a list of repos the authenticated user has write access to.
    #>
    [CmdletBinding()]
    param()

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $result = @(& gh repo list --json nameWithOwner,name,owner,defaultBranchRef --limit 100 2>&1)
        $listExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($listExitCode -ne 0) {
        throw "Failed to list repositories: $($result -join "`n")"
    }
    return (@($result) -join [Environment]::NewLine) | ConvertFrom-Json
}

function Get-GitHubRepo {
    <#
    .SYNOPSIS
        Returns repository details for a single GitHub repository.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $result = @(& gh repo view "$Owner/$Repo" --json nameWithOwner,name,owner,defaultBranchRef 2>&1)
        $viewExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($viewExitCode -ne 0) {
        throw "Failed to get repository '$Owner/$Repo': $($result -join "`n")"
    }
    return (@($result) -join [Environment]::NewLine) | ConvertFrom-Json
}

function Ensure-GitHubSharedWorkflowAccessPolicy {
    <#
    .SYNOPSIS
        Ensures a private shared workflow repository has its Actions access policy configured
        to allow other repositories owned by the same user or organization to use its reusable workflows.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo
    )

    $repoDetails = Invoke-GhApi -Endpoint "repos/$Owner/$Repo"
    if (-not $repoDetails) {
        Write-Warning "Could not retrieve repository details for '$Owner/$Repo'; skipping Actions access policy check."
        return
    }

    if (-not $repoDetails.private) {
        Write-Host "Shared workflow repository '$Owner/$Repo' is public; no Actions access policy configuration required." -ForegroundColor DarkGray
        return
    }

    # Private repo: set access_level so other repos owned by the same user/org can call its reusable workflows.
    # See: https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository#allowing-access-to-components-in-a-private-repository
    $ownerType = $repoDetails.owner.type
    $accessLevel = if ($ownerType -eq 'Organization') { 'organization' } else { 'user' }

    $currentPolicy = Invoke-GhApi -Endpoint "repos/$Owner/$Repo/actions/permissions/access" -AllowNotFound
    if ($currentPolicy -and $currentPolicy.access_level -eq $accessLevel) {
        Write-Host "Shared workflow repository '$Owner/$Repo' Actions access policy is already set to '$accessLevel'." -ForegroundColor DarkGray
        return
    }

    Write-Host "Setting Actions access policy on '$Owner/$Repo' to '$accessLevel' so its reusable workflows are accessible from other private repositories..." -ForegroundColor Yellow
    Invoke-GhApi -Endpoint "repos/$Owner/$Repo/actions/permissions/access" -Method 'PUT' -Body @{ access_level = $accessLevel } | Out-Null
    Write-Host "Actions access policy set to '$accessLevel' on '$Owner/$Repo'." -ForegroundColor Green
}

function Get-GitHubActionsVariableValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$VariableName,
        [Parameter()][string]$EnvironmentName
    )

    $encodedVariableName = [Uri]::EscapeDataString($VariableName)
    $endpoint = if ([string]::IsNullOrWhiteSpace($EnvironmentName)) {
        "repos/$Owner/$Repo/actions/variables/$encodedVariableName"
    }
    else {
        $encodedEnvironmentName = [Uri]::EscapeDataString($EnvironmentName)
        "repos/$Owner/$Repo/environments/$encodedEnvironmentName/variables/$encodedVariableName"
    }

    $result = Invoke-GhApi -Endpoint $endpoint -AllowNotFound
    if ($null -eq $result) {
        return $null
    }

    if ($result.PSObject.Properties.Name -contains 'value') {
        return [string]$result.value
    }

    return $null
}

function Test-GitHubActionsSecretExists {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$SecretName,
        [Parameter()][string]$EnvironmentName
    )

    $encodedSecretName = [Uri]::EscapeDataString($SecretName)
    $endpoint = if ([string]::IsNullOrWhiteSpace($EnvironmentName)) {
        "repos/$Owner/$Repo/actions/secrets/$encodedSecretName"
    }
    else {
        $encodedEnvironmentName = [Uri]::EscapeDataString($EnvironmentName)
        "repos/$Owner/$Repo/environments/$encodedEnvironmentName/secrets/$encodedSecretName"
    }

    $result = Invoke-GhApi -Endpoint $endpoint -AllowNotFound
    return ($null -ne $result)
}

function Get-GitHubWorkflowReferenceFromRepoClone {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$DefaultBranch
    )

    $candidateFiles = @(
        (Join-Path $RepoRoot '.github/workflows/BUILD.yml'),
        (Join-Path $RepoRoot ".github/workflows/DEPLOY-$DefaultBranch.yml"),
        (Join-Path $RepoRoot '.github/workflows/EXPORT.yml'),
        (Join-Path $RepoRoot '.github/workflows/IMPORT.yml')
    )

    foreach ($candidateFile in $candidateFiles) {
        if (-not (Test-Path -LiteralPath $candidateFile)) {
            continue
        }

        $content = Get-Content -LiteralPath $candidateFile -Raw
        $match = [regex]::Match($content, 'uses:\s*([^/\s]+/[^/\s]+)/\.github/workflows/[A-Za-z0-9._-]+@([^\s''"`]+)')
        if ($match.Success) {
            return [pscustomobject]@{
                Repository = $match.Groups[1].Value
                Reference  = $match.Groups[2].Value
            }
        }
    }

    return $null
}

function Get-GitHubDeploymentEnvironmentNamesFromRepoClone {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$DefaultBranch
    )

    $deployFilePath = Join-Path $RepoRoot ".github/workflows/DEPLOY-$DefaultBranch.yml"
    if (-not (Test-Path -LiteralPath $deployFilePath)) {
        return @()
    }

    $content = Get-Content -LiteralPath $deployFilePath -Raw
    $environmentNameMatches = [regex]::Matches($content, '(?m)^\s*environment-name:\s*["'']?([^"''\r\n]+)["'']?\s*$')
    $names = @()
    foreach ($environmentNameMatch in $environmentNameMatches) {
        $name = $environmentNameMatch.Groups[1].Value.Trim()
        if (-not [string]::IsNullOrWhiteSpace($name) -and $names -notcontains $name) {
            $names += $name
        }
    }

    return @($names)
}

function Get-GitHubDeploymentEnvironmentNamesFromWorkflowContent {
    [CmdletBinding()]
    param(
        [Parameter()][string]$WorkflowContent
    )

    if ([string]::IsNullOrWhiteSpace($WorkflowContent)) {
        return @()
    }

    $environmentNameMatches = [regex]::Matches($WorkflowContent, '(?m)^\s*environment-name:\s*["'']?([^"''\r\n]+)["'']?\s*$')
    $names = @()
    foreach ($environmentNameMatch in $environmentNameMatches) {
        $name = $environmentNameMatch.Groups[1].Value.Trim()
        if (-not [string]::IsNullOrWhiteSpace($name) -and $names -notcontains $name) {
            $names += $name
        }
    }

    return @($names)
}

function Get-GitHubBuildEnvironmentNameFromWorkflowContent {
    [CmdletBinding()]
    param(
        [Parameter()][string]$WorkflowContent
    )

    if ([string]::IsNullOrWhiteSpace($WorkflowContent)) {
        return $null
    }

    $match = [regex]::Match($WorkflowContent, '(?mi)^\s*environment-name\s*:\s*[''\"]?(?<name>[^''\"\r\n]*)[''\"]?\s*$')
    if (-not $match.Success) {
        return $null
    }

    $value = [string]$match.Groups['name'].Value
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    return $value.Trim()
}

function Get-SolutionCheckEnabledFromConfigContent {
    [CmdletBinding()]
    param(
        [Parameter()][string]$ConfigContent
    )

    if ([string]::IsNullOrWhiteSpace($ConfigContent)) {
        return $false
    }

    $match = [regex]::Match($ConfigContent, '(?mis)solutionCheck\s*=\s*@\{.*?\benabled\s*=\s*\$(true|false)')
    if (-not $match.Success) {
        return $false
    }

    return ($match.Groups[1].Value -ieq 'true')
}

function Get-GitHubBuildValidationEnabledFromRepoClone {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch
    )

    $buildWorkflowContent = Get-GitRepoFileContentFromRemoteBranch -RepoRoot $RepoRoot -Branch $Branch -RelativePath '.github/workflows/BUILD.yml'
    $buildEnvironmentName = Get-GitHubBuildEnvironmentNameFromWorkflowContent -WorkflowContent $buildWorkflowContent
    $hasBuildEnvironmentAssociation = -not [string]::IsNullOrWhiteSpace($buildEnvironmentName)

    $almConfigContent = Get-GitRepoFileContentFromRemoteBranch -RepoRoot $RepoRoot -Branch $Branch -RelativePath 'alm-config.psd1'
    $solutionCheckEnabled = Get-SolutionCheckEnabledFromConfigContent -ConfigContent $almConfigContent

    return ($hasBuildEnvironmentAssociation -or $solutionCheckEnabled)
}

function Get-GitRepoFileContentFromRemoteBranch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$RelativePath
    )

    $normalizedPath = $RelativePath.Replace('\\', '/')
    $candidateRefs = @("origin/$Branch", $Branch)
    foreach ($candidateRef in $candidateRefs) {
        $content = (& git -C $RepoRoot show "${candidateRef}:${normalizedPath}" 2>$null | Out-String)
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($content)) {
            return $content
        }
    }

    return $null
}

function Get-GitHubDeployWorkflowBranchMappingsFromRepoClone {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $branchRefs = @(& git -C $RepoRoot for-each-ref --format='%(refname:short)' refs/remotes/origin/* 2>$null)
    $branches = @($branchRefs | ForEach-Object {
        $candidate = [string]$_
        if ($candidate -match '^origin/(.+)$') { $candidate = $Matches[1] }

        if ([string]::IsNullOrWhiteSpace($candidate)) {
            return $null
        }

        if ($candidate -in @('HEAD', 'origin')) {
            return $null
        }

        if ($candidate -match '^origin/') {
            return $null
        }

        return $candidate
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)

    $mappings = @()
    foreach ($branch in $branches) {
        $remoteRef = "origin/$branch"
        & git -C $RepoRoot rev-parse --verify $remoteRef 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            continue
        }

        $workflowFiles = @(& git -C $RepoRoot ls-tree -r --name-only $remoteRef '.github/workflows' 2>$null)
        foreach ($workflowFile in $workflowFiles) {
            if ($workflowFile -notmatch '^\.github/workflows/DEPLOY-(.+)\.yml$') {
                continue
            }

            $fileBranchName = [string]$Matches[1]
            $workflowContent = Get-GitRepoFileContentFromRemoteBranch -RepoRoot $RepoRoot -Branch $branch -RelativePath $workflowFile
            $environmentNames = Get-GitHubDeploymentEnvironmentNamesFromWorkflowContent -WorkflowContent $workflowContent

            $mappings += [pscustomobject]@{
                BranchName       = $fileBranchName
                SourceBranch     = $branch
                WorkflowPath     = $workflowFile
                EnvironmentNames = @($environmentNames)
            }
        }
    }

    return @($mappings | Sort-Object BranchName -Unique)
}

function Get-GitHubExistingEnvironmentState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter()][string]$TenantId
    )

    $environmentClientId = Get-GitHubActionsVariableValue -Owner $Owner -Repo $Repo -EnvironmentName $EnvironmentName -VariableName 'AZURE_CLIENT_ID'
    $environmentTenantId = Get-GitHubActionsVariableValue -Owner $Owner -Repo $Repo -EnvironmentName $EnvironmentName -VariableName 'AZURE_TENANT_ID'
    $environmentUrl = Get-GitHubActionsVariableValue -Owner $Owner -Repo $Repo -EnvironmentName $EnvironmentName -VariableName 'DATAVERSE_URL'
    $environmentServiceAccount = Get-GitHubActionsVariableValue -Owner $Owner -Repo $Repo -EnvironmentName $EnvironmentName -VariableName 'DATAVERSESERVICEACCOUNTUPN'
    $environmentSecretExists = Test-GitHubActionsSecretExists -Owner $Owner -Repo $Repo -EnvironmentName $EnvironmentName -SecretName 'AZURE_CLIENT_SECRET'

    $storageScope = $null
    $applicationId = $environmentClientId
    $resolvedTenantId = $environmentTenantId
    $environmentUrl = ConvertTo-NormalizedEnvironmentUrl -Url $environmentUrl
    $serviceAccountUPN = $environmentServiceAccount
    $hasExistingSecret = $environmentSecretExists

    if (-not [string]::IsNullOrWhiteSpace($environmentClientId) -or -not [string]::IsNullOrWhiteSpace($environmentUrl) -or -not [string]::IsNullOrWhiteSpace($environmentServiceAccount) -or $environmentSecretExists) {
        $storageScope = 'Environment'
    }
    else {
        $prefix = Get-GitHubEnvironmentPrefix -EnvironmentName $EnvironmentName
        $applicationId = Get-GitHubActionsVariableValue -Owner $Owner -Repo $Repo -VariableName "${prefix}AZURE_CLIENT_ID"
        $resolvedTenantId = Get-GitHubActionsVariableValue -Owner $Owner -Repo $Repo -VariableName "${prefix}AZURE_TENANT_ID"
        $environmentUrl = ConvertTo-NormalizedEnvironmentUrl -Url (Get-GitHubActionsVariableValue -Owner $Owner -Repo $Repo -VariableName "${prefix}DATAVERSE_URL")
        $serviceAccountUPN = Get-GitHubActionsVariableValue -Owner $Owner -Repo $Repo -VariableName "${prefix}DATAVERSE_SERVICE_ACCOUNT_UPN"
        $hasExistingSecret = Test-GitHubActionsSecretExists -Owner $Owner -Repo $Repo -SecretName "${prefix}AZURE_CLIENT_SECRET"

        if (-not [string]::IsNullOrWhiteSpace($applicationId) -or -not [string]::IsNullOrWhiteSpace($environmentUrl) -or -not [string]::IsNullOrWhiteSpace($serviceAccountUPN) -or $hasExistingSecret) {
            $storageScope = 'RepositoryPrefix'
        }
    }

    if (-not $storageScope) {
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($resolvedTenantId)) {
        $resolvedTenantId = $TenantId
    }

    $existingCredential = $null
    if (-not [string]::IsNullOrWhiteSpace($applicationId)) {
        $application = Resolve-EntraIdApplicationByAppId -ApplicationId $applicationId -TenantId $resolvedTenantId
        $existingCredential = [pscustomobject]@{
            Name                = $(if ($application -and -not [string]::IsNullOrWhiteSpace($application.displayName)) { $application.displayName } else { "Existing-$EnvironmentName" })
            ApplicationId       = $applicationId
            ApplicationObjectId = $(if ($application) { $application.id } else { $null })
            ClientSecret        = $null
            TenantId            = $resolvedTenantId
            AuthType            = $(if ($hasExistingSecret) { 'Secret' } else { 'WIF' })
            HasExistingSecret   = $hasExistingSecret
            IsExistingCredential = $true
        }
    }

    $friendlyName = Resolve-DataverseEnvironmentFriendlyName -EnvironmentUrl $environmentUrl -FallbackName $EnvironmentName

    return [pscustomobject]@{
        ShortName         = $EnvironmentName
        FriendlyName      = $friendlyName
        Url               = $environmentUrl
        Credentials       = $existingCredential
        ServiceAccountUPN = $serviceAccountUPN
        StorageScope      = $storageScope
    }
}

function Get-GitHubRepositoryExistingSetupState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$RepoOwner,
        [Parameter(Mandatory)][string]$RepoName,
        [Parameter(Mandatory)][string]$DefaultBranch,
        [Parameter()][string]$TenantId
    )

    $workflowReference = Get-GitHubWorkflowReferenceFromRepoClone -RepoRoot $RepoRoot -DefaultBranch $DefaultBranch
    $devEnvironmentName = "Dev-$DefaultBranch"
    $devEnvironment = Get-GitHubExistingEnvironmentState -Owner $RepoOwner -Repo $RepoName -EnvironmentName $devEnvironmentName -TenantId $TenantId
    $deploymentEnvironments = @()
    $deploymentBranchMappings = @()
    $storageScope = $null
    $defaultBranchBuildValidationEnabled = Get-GitHubBuildValidationEnabledFromRepoClone -RepoRoot $RepoRoot -Branch $DefaultBranch

    $workflowBranchMappings = @(Get-GitHubDeployWorkflowBranchMappingsFromRepoClone -RepoRoot $RepoRoot)
    foreach ($workflowBranchMapping in $workflowBranchMappings) {
        $mappedEnvironmentStates = @()
        foreach ($environmentName in @($workflowBranchMapping.EnvironmentNames)) {
            if ([string]::IsNullOrWhiteSpace($environmentName)) {
                continue
            }

            $existingState = $deploymentEnvironments | Where-Object { $_.ShortName -ieq $environmentName } | Select-Object -First 1
            if ($existingState) {
                $mappedEnvironmentStates += $existingState
                continue
            }

            $environmentState = Get-GitHubExistingEnvironmentState -Owner $RepoOwner -Repo $RepoName -EnvironmentName $environmentName -TenantId $TenantId
            if ($environmentState) {
                $deploymentEnvironments += $environmentState
                $mappedEnvironmentStates += $environmentState
                if (-not $storageScope -and $environmentState.StorageScope) {
                    $storageScope = $environmentState.StorageScope
                }
            }
            else {
                $placeholderState = [pscustomobject]@{
                    ShortName         = $environmentName
                    FriendlyName      = $environmentName
                    Url               = $null
                    Credentials       = $null
                    ServiceAccountUPN = $null
                    StorageScope      = $null
                }
                $deploymentEnvironments += $placeholderState
                $mappedEnvironmentStates += $placeholderState
            }
        }

        $deploymentBranchMappings += [pscustomobject]@{
            BranchName   = $workflowBranchMapping.BranchName
            Environments = @($mappedEnvironmentStates)
            SourceBranch = $workflowBranchMapping.SourceBranch
        }
    }

    if ($deploymentEnvironments.Count -eq 0) {
        foreach ($environmentName in @(Get-GitHubDeploymentEnvironmentNamesFromRepoClone -RepoRoot $RepoRoot -DefaultBranch $DefaultBranch)) {
            $environmentState = Get-GitHubExistingEnvironmentState -Owner $RepoOwner -Repo $RepoName -EnvironmentName $environmentName -TenantId $TenantId
            if ($environmentState) {
                $deploymentEnvironments += $environmentState
                if (-not $storageScope -and $environmentState.StorageScope) {
                    $storageScope = $environmentState.StorageScope
                }
            }
            else {
                $deploymentEnvironments += [pscustomobject]@{
                    ShortName         = $environmentName
                    FriendlyName      = $environmentName
                    Url               = $null
                    Credentials       = $null
                    ServiceAccountUPN = $null
                    StorageScope      = $null
                }
            }
        }
    }

    if ($deploymentBranchMappings.Count -eq 0 -and $deploymentEnvironments.Count -gt 0) {
        $deploymentBranchMappings = @(
            [pscustomobject]@{
                BranchName   = $DefaultBranch
                Environments = @($deploymentEnvironments)
                SourceBranch = $DefaultBranch
            }
        )
    }

    if ($deploymentBranchMappings.Count -eq 0) {
        $deploymentBranchMappings = @(
            [pscustomobject]@{
                BranchName   = $DefaultBranch
                Environments = @()
                SourceBranch = $DefaultBranch
            }
        )
    }

    if (-not $storageScope -and $devEnvironment -and $devEnvironment.StorageScope) {
        $storageScope = $devEnvironment.StorageScope
    }

    return [pscustomobject]@{
        SharedWorkflowRepository = $(if ($workflowReference) { $workflowReference.Repository } else { $null })
        SharedWorkflowReference  = $(if ($workflowReference) { $workflowReference.Reference } else { $null })
        DefaultBranchBuildValidationEnabled = [bool]$defaultBranchBuildValidationEnabled
        BuildValidationEnabled   = [bool]$defaultBranchBuildValidationEnabled
        BuildValidationEnvironmentName = (Get-GitHubBuildEnvironmentNameFromWorkflowContent -WorkflowContent (Get-GitRepoFileContentFromRemoteBranch -RepoRoot $RepoRoot -Branch $DefaultBranch -RelativePath '.github/workflows/BUILD.yml'))
        ExistingBuildValidationEnvironment = $(
            $buildEnvName = Get-GitHubBuildEnvironmentNameFromWorkflowContent -WorkflowContent (Get-GitRepoFileContentFromRemoteBranch -RepoRoot $RepoRoot -Branch $DefaultBranch -RelativePath '.github/workflows/BUILD.yml')
            if ([string]::IsNullOrWhiteSpace($buildEnvName)) {
                $null
            }
            else {
                Get-GitHubExistingEnvironmentState -Owner $RepoOwner -Repo $RepoName -EnvironmentName $buildEnvName -TenantId $TenantId
            }
        )
        CredentialStorageScope   = $storageScope
        DevEnvironment           = $devEnvironment
        DeploymentEnvironments   = @($deploymentEnvironments)
        DeploymentBranchMappings = @($deploymentBranchMappings)
    }
}

function Get-GitHubInitialBranchMappings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$ExistingSetupState,
        [Parameter(Mandatory)][string]$DefaultBranch
    )

    $branchMappings = @()
    foreach ($mapping in @($ExistingSetupState.DeploymentBranchMappings)) {
        if ($null -eq $mapping -or [string]::IsNullOrWhiteSpace([string]$mapping.BranchName)) {
            continue
        }

        $branchMappings += [pscustomobject]@{
            BranchName   = [string]$mapping.BranchName
            Environments = @($mapping.Environments | Where-Object { $null -ne $_ })
        }
    }

    if ($branchMappings.Count -eq 0) {
        $defaultEnvironments = @($ExistingSetupState.DeploymentEnvironments | Where-Object { $null -ne $_ })
        $branchMappings = @(
            [pscustomobject]@{
                BranchName   = $DefaultBranch
                Environments = $defaultEnvironments
            }
        )
    }
    elseif (
        -not ($branchMappings | Where-Object { $_.BranchName -ieq $DefaultBranch }) -and
        $ExistingSetupState.DevEnvironment
    ) {
        $branchMappings += [pscustomobject]@{
            BranchName   = $DefaultBranch
            Environments = @()
        }
    }

    return @($branchMappings | Sort-Object BranchName -Unique)
}

function New-GitHubBranchSetupState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BranchName,
        [Parameter()][object]$ExistingDevEnvironment,
        [Parameter()][array]$DeploymentEnvironments,
        [Parameter()][object]$PublishPlan
    )

    $normalizedDeploymentEnvironments = @($DeploymentEnvironments | Where-Object { $null -ne $_ })

    return [pscustomobject]@{
        BranchName                  = $BranchName
        ExistingDevEnvironment      = $ExistingDevEnvironment
        DevEnvironmentConfiguration = $null
        DeploymentEnvironments      = $normalizedDeploymentEnvironments
        PublishPlan                 = $PublishPlan
    }
}

function Get-GitHubOwnedReposForOwner {
    <#
    .SYNOPSIS
        Returns repositories owned by the specified GitHub account.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner
    )

    $repos = Invoke-GhApi -Endpoint "users/$Owner/repos?type=owner&sort=updated&per_page=100"
    if (-not $repos) {
        return @()
    }

    $normalized = @()
    foreach ($repo in @($repos)) {
        $repoFullName = $null

        if ($repo.PSObject.Properties.Name -contains 'full_name' -and -not [string]::IsNullOrWhiteSpace($repo.full_name)) {
            $repoFullName = [string]$repo.full_name
        }
        elseif (
            ($repo.PSObject.Properties.Name -contains 'owner') -and $repo.owner -and
            ($repo.owner.PSObject.Properties.Name -contains 'login') -and -not [string]::IsNullOrWhiteSpace($repo.owner.login) -and
            ($repo.PSObject.Properties.Name -contains 'name') -and -not [string]::IsNullOrWhiteSpace($repo.name)
        ) {
            $repoFullName = "$($repo.owner.login)/$($repo.name)"
        }

        if ([string]::IsNullOrWhiteSpace($repoFullName)) {
            continue
        }

        $normalized += [pscustomobject]@{
            full_name = $repoFullName
        }
    }

    return @($normalized | Sort-Object -Property full_name -Unique)
}

function Resolve-GitHubRepoFullNameFromSource {
    <#
    .SYNOPSIS
        Resolves a GitHub repository full name (owner/repo) from URL, owner/repo text, or a local git repository path.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][string]$Source,
        [Parameter()][string]$Fallback = 'ALM4Dataverse/ALM4Dataverse'
    )

    if (-not [string]::IsNullOrWhiteSpace($Source)) {
        $trimmed = $Source.Trim()

        if ($trimmed -match '^[^/\s]+/[^/\s]+$') {
            return $trimmed
        }

        if ($trimmed -match 'github\.com[:/]+([^/]+)/([^/]+?)(?:\.git)?/?$') {
            return "$($Matches[1])/$($Matches[2])"
        }

        if (Test-Path -LiteralPath $trimmed) {
            try {
                $originUrl = (& git -C $trimmed config --get remote.origin.url 2>$null).Trim()
                if (-not [string]::IsNullOrWhiteSpace($originUrl) -and $originUrl -match 'github\.com[:/]+([^/]+)/([^/]+?)(?:\.git)?/?$') {
                    return "$($Matches[1])/$($Matches[2])"
                }
            }
            catch {
                # Fall through to fallback
            }
        }
    }

    return $Fallback
}

function Resolve-UpstreamGitRemoteSource {
    <#
    .SYNOPSIS
        Resolves an upstream git remote source usable by `git fetch`/`git clone`.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][string]$ConfiguredSource,
        [Parameter(Mandatory)][string]$GitHubFullName
    )

    if (-not [string]::IsNullOrWhiteSpace($ConfiguredSource)) {
        $trimmed = $ConfiguredSource.Trim()

        if (Test-Path -LiteralPath $trimmed) {
            return $trimmed
        }

        if ($trimmed -match '^https?://' -or $trimmed -match '^git@') {
            return $trimmed
        }

        if ($trimmed -match '^[^/\s]+/[^/\s]+$') {
            return "https://github.com/$trimmed.git"
        }

        if ($trimmed -match 'github\.com[:/]+([^/]+)/([^/]+?)(?:\.git)?/?$') {
            return "https://github.com/$($Matches[1])/$($Matches[2]).git"
        }
    }

    return "https://github.com/$GitHubFullName.git"
}

function Resolve-GitTargetRefFromRemote {
    <#
    .SYNOPSIS
        Resolves a branch/tag/commit ref against a remote to a local git ref for checkout/merge operations.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RemoteName,
        [Parameter(Mandatory)][string]$Ref,
        [Parameter()][string]$RepositoryPath
    )

    $gitArgs = @()
    if (-not [string]::IsNullOrWhiteSpace($RepositoryPath)) {
        $gitArgs += @('-C', $RepositoryPath)
    }

    & git @gitArgs ls-remote --exit-code $RemoteName $Ref | Out-Null
    if ($LASTEXITCODE -eq 2) {
        throw "Could not resolve reference '$Ref' from remote '$RemoteName'."
    }
    if ($LASTEXITCODE -ne 0) {
        throw "git ls-remote failed for '$RemoteName' with exit code $LASTEXITCODE"
    }

    $lsRemoteOutput = (& git @gitArgs ls-remote $RemoteName $Ref | Select-Object -First 1)
    if (-not $lsRemoteOutput) {
        throw "Could not resolve reference '$Ref' from remote '$RemoteName'."
    }

    if ($lsRemoteOutput -match '^([a-f0-9]+)\s+(.+)$') {
        $commitSha = $Matches[1]
        $fullRef = $Matches[2]

        if ($fullRef -match '^refs/heads/(.+)$') {
            return "$RemoteName/$($Matches[1])"
        }
        elseif ($fullRef -match '^refs/tags/') {
            return $commitSha
        }
        else {
            return $Ref
        }
    }

    return $Ref
}

function Get-GitHubForkSyncState {
    <#
    .SYNOPSIS
        Clones a GitHub shared workflow repository into a temporary working tree and computes its sync state against upstream.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ForkFullName,
        [Parameter(Mandatory)][string]$WorkRoot,
        [Parameter(Mandatory)][string]$UpstreamGitSource,
        [Parameter(Mandatory)][string]$UpstreamFullName,
        [Parameter(Mandatory)][string]$Reference,
        [Parameter(Mandatory)][string]$DefaultBranch
    )

    if (Test-Path -LiteralPath $WorkRoot) {
        try {
            Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        catch {
            # Best effort cleanup before clone.
        }
    }

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $cloneOutput = @(& gh repo clone $ForkFullName $WorkRoot 2>&1)
        $cloneExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($cloneExitCode -ne 0) {
        $cloneErrorDetails = @($cloneOutput | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $cloneErrorMessage = if ($cloneErrorDetails.Count -gt 0) { $cloneErrorDetails[-1] } else { "Exit code: $cloneExitCode" }
        throw "Failed to clone repository '$ForkFullName'. $cloneErrorMessage"
    }

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $checkoutOutput = @(& git -C $WorkRoot checkout $DefaultBranch 2>&1)
        $checkoutExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($checkoutExitCode -ne 0) {
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $checkoutOutput = @(& git -C $WorkRoot checkout -b $DefaultBranch "origin/$DefaultBranch" 2>&1)
            $checkoutExitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        if ($checkoutExitCode -ne 0) {
            $checkoutErrorDetails = @($checkoutOutput | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $checkoutErrorMessage = if ($checkoutErrorDetails.Count -gt 0) { $checkoutErrorDetails[-1] } else { "Exit code: $checkoutExitCode" }
            throw "Failed to check out repository default branch '$DefaultBranch'. $checkoutErrorMessage"
        }
    }

    & git -C $WorkRoot remote remove upstream 2>$null | Out-Null
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $addRemoteOutput = @(& git -C $WorkRoot remote add upstream $UpstreamGitSource 2>&1)
        $addRemoteExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($addRemoteExitCode -ne 0) {
        $addRemoteErrorDetails = @($addRemoteOutput | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $addRemoteErrorMessage = if ($addRemoteErrorDetails.Count -gt 0) { $addRemoteErrorDetails[-1] } else { "Exit code: $addRemoteExitCode" }
        throw "Failed to add upstream remote '$UpstreamGitSource'. $addRemoteErrorMessage"
    }

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $fetchUpstreamOutput = @(& git -C $WorkRoot fetch upstream 2>&1)
        $fetchUpstreamExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($fetchUpstreamExitCode -ne 0) {
        $fetchUpstreamErrorDetails = @($fetchUpstreamOutput | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $fetchUpstreamErrorMessage = if ($fetchUpstreamErrorDetails.Count -gt 0) { $fetchUpstreamErrorDetails[-1] } else { "Exit code: $fetchUpstreamExitCode" }
        throw "Failed to fetch upstream remote. $fetchUpstreamErrorMessage"
    }

    $upstreamRef = Resolve-GitTargetRefFromRemote -RemoteName 'upstream' -Ref $Reference -RepositoryPath $WorkRoot

    $localHash = (& git -C $WorkRoot rev-parse HEAD).Trim()
    $upstreamHash = (& git -C $WorkRoot rev-parse $upstreamRef).Trim()
    $matchesCanonicalUpstreamDefault = $false

    $canonicalUpstreamSource = Resolve-UpstreamGitRemoteSource -ConfiguredSource $UpstreamFullName -GitHubFullName $UpstreamFullName
    if (-not [string]::IsNullOrWhiteSpace($canonicalUpstreamSource)) {
        $remoteNames = @(& git -C $WorkRoot remote 2>$null)
        $hasCanonicalUpstreamRemote = (@($remoteNames | ForEach-Object { [string]$_ } | Where-Object { $_ -eq 'upstream-github' }).Count -gt 0)
        if ($hasCanonicalUpstreamRemote) {
            $previousErrorActionPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                [void](& git -C $WorkRoot remote remove upstream-github 2>&1)
            }
            finally {
                $ErrorActionPreference = $previousErrorActionPreference
            }
        }

        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            [void](& git -C $WorkRoot remote add upstream-github $canonicalUpstreamSource 2>&1)
            $addCanonicalRemoteExitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        if ($addCanonicalRemoteExitCode -eq 0) {
            $previousErrorActionPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                [void](& git -C $WorkRoot fetch upstream-github $DefaultBranch 2>&1)
                $fetchCanonicalRemoteExitCode = $LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $previousErrorActionPreference
            }

            if ($fetchCanonicalRemoteExitCode -eq 0) {
                $canonicalUpstreamHash = (& git -C $WorkRoot rev-parse "upstream-github/$DefaultBranch").Trim()
                $matchesCanonicalUpstreamDefault = ($localHash -eq $canonicalUpstreamHash)
            }
        }
    }

    $canFastForward = $false
    $isAhead = $false
    if ($localHash -ne $upstreamHash) {
        & git -C $WorkRoot merge-base --is-ancestor HEAD $upstreamRef
        $canFastForward = ($LASTEXITCODE -eq 0)

        if (-not $canFastForward) {
            & git -C $WorkRoot merge-base --is-ancestor $upstreamRef HEAD
            $isAhead = ($LASTEXITCODE -eq 0)
        }
    }

    return [pscustomobject]@{
        UpstreamRef                     = $upstreamRef
        LocalHash                       = $localHash
        UpstreamHash                    = $upstreamHash
        MatchesCanonicalUpstreamDefault = $matchesCanonicalUpstreamDefault
        CanFastForward                  = $canFastForward
        IsAhead                         = $isAhead
    }
}

function Get-GitHubForksOfRepositoryForOwner {
    <#
    .SYNOPSIS
        Lists repositories owned by a user that are forks of the specified upstream repository.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$UpstreamFullName
    )

    $ownedRepos = Invoke-GhApi -Endpoint "users/$Owner/repos?type=owner&sort=updated&per_page=100"
    if (-not $ownedRepos) {
        return @()
    }

    $matchingForks = @()

    foreach ($repo in @($ownedRepos)) {
        $isFork = $false
        if ($repo.PSObject.Properties.Name -contains 'fork') {
            $isFork = [bool]$repo.fork
        }
        if (-not $isFork) {
            continue
        }

        $repoFullName = $null
        if ($repo.PSObject.Properties.Name -contains 'full_name' -and -not [string]::IsNullOrWhiteSpace($repo.full_name)) {
            $repoFullName = [string]$repo.full_name
        }
        elseif (
            ($repo.PSObject.Properties.Name -contains 'owner') -and $repo.owner -and
            ($repo.owner.PSObject.Properties.Name -contains 'login') -and -not [string]::IsNullOrWhiteSpace($repo.owner.login) -and
            ($repo.PSObject.Properties.Name -contains 'name') -and -not [string]::IsNullOrWhiteSpace($repo.name)
        ) {
            $repoFullName = "$($repo.owner.login)/$($repo.name)"
        }

        if ([string]::IsNullOrWhiteSpace($repoFullName)) {
            continue
        }

        # Some API responses do not include 'parent'. Resolve using repo details when required.
        $parentFullName = $null
        if (
            ($repo.PSObject.Properties.Name -contains 'parent') -and $repo.parent -and
            ($repo.parent.PSObject.Properties.Name -contains 'full_name') -and -not [string]::IsNullOrWhiteSpace($repo.parent.full_name)
        ) {
            $parentFullName = [string]$repo.parent.full_name
        }
        else {
            $repoDetails = Invoke-GhApi -Endpoint "repos/$repoFullName" -AllowNotFound
            if (
                $repoDetails -and
                ($repoDetails.PSObject.Properties.Name -contains 'parent') -and $repoDetails.parent -and
                ($repoDetails.parent.PSObject.Properties.Name -contains 'full_name') -and -not [string]::IsNullOrWhiteSpace($repoDetails.parent.full_name)
            ) {
                $parentFullName = [string]$repoDetails.parent.full_name
            }
        }

        if ($parentFullName -ieq $UpstreamFullName) {
            $matchingForks += [pscustomobject]@{
                full_name = $repoFullName
            }
        }
    }

    return @($matchingForks)
}

function Ensure-GitHubForkForSharedWorkflows {
    <#
    .SYNOPSIS
        Ensures the user has a shared workflow repository and optionally updates it from upstream.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UpstreamFullName,
        [Parameter(Mandatory)][string]$ForkOwner,
        [Parameter(Mandatory)][string]$UpstreamGitSource,
        [Parameter(Mandatory)][string]$Reference,
        [Parameter()][string]$PreferredRepositoryFullName
    )

    $sharedRepositoryOptions = Invoke-WithSpectreStatus -Status 'Retrieving shared workflow repository options...' -ScriptBlock {
        [pscustomobject]@{
            ExistingForks = @(Get-GitHubForksOfRepositoryForOwner -Owner $ForkOwner -UpstreamFullName $UpstreamFullName)
            OwnedRepos    = @(Get-GitHubOwnedReposForOwner -Owner $ForkOwner)
        }
    }

    $existingForks = @($sharedRepositoryOptions.ExistingForks)
    $ownedRepos = @($sharedRepositoryOptions.OwnedRepos)

    $menuItems = @()
    $menuActions = @()

    if (-not [string]::IsNullOrWhiteSpace($PreferredRepositoryFullName)) {
        $preferredOwnedRepo = $ownedRepos | Where-Object { $_.full_name -ieq $PreferredRepositoryFullName } | Select-Object -First 1
        if ($preferredOwnedRepo) {
            $menuItems += "Use current shared workflow repository: $($preferredOwnedRepo.full_name)"
            $menuActions += @{ Type = 'UseExisting'; FullName = $preferredOwnedRepo.full_name }

            $existingForks = @($existingForks | Where-Object { $_.full_name -ine $preferredOwnedRepo.full_name })
            $ownedRepos = @($ownedRepos | Where-Object { $_.full_name -ine $preferredOwnedRepo.full_name })
        }
    }

    foreach ($fork in $existingForks) {
        $menuItems += "Use existing fork: $($fork.full_name)"
        $menuActions += @{ Type = 'UseExisting'; FullName = $fork.full_name }
    }

    $forkFullNameMap = @{}
    foreach ($fork in $existingForks) {
        if ($fork.full_name) {
            $forkFullNameMap[$fork.full_name.ToLowerInvariant()] = $true
        }
    }

    $nonForkRepos = @($ownedRepos | Where-Object {
        $repoFullName = $_.full_name
        if ([string]::IsNullOrWhiteSpace($repoFullName)) {
            return $false
        }

        return -not $forkFullNameMap.ContainsKey($repoFullName.ToLowerInvariant())
    })

    $menuItems += 'Create a new repository'
    $menuActions += @{ Type = 'CreateNew' }

    foreach ($repo in $nonForkRepos) {
        $menuItems += "Use existing repository: $($repo.full_name)"
        $menuActions += @{ Type = 'UseExisting'; FullName = $repo.full_name }
    }

  

    $selection = Select-FromMenu `
        -Title "Select shared workflow repository" `
        -Items $menuItems `
        -PromptGuidanceLines @(
            'Choose or create a repository that will host the reusable ALM4Dataverse workflow templates.'
        ) `
        -PromptGuidanceDocRelativePath 'docs/setup/github-setup.md' `
        -PromptGuidanceRef $ALM4DataverseRef
    if ($null -eq $selection) {
        throw "No shared workflow repository selected."
    }

    $selectedSharedRepositoryFullName = $null
    $createdNewSharedRepository = $false
    $selectedAction = $menuActions[$selection]
    if ($selectedAction.Type -eq 'UseExisting') {
        $selectedSharedRepositoryFullName = $selectedAction.FullName
    }

    if (-not $selectedSharedRepositoryFullName) {
        $upstreamParts = $UpstreamFullName.Split('/', 2)
        $defaultRepositoryName = $upstreamParts[1]
        if (-not [string]::IsNullOrWhiteSpace($PreferredRepositoryFullName) -and $PreferredRepositoryFullName -match '^[^/]+/(.+)$') {
            $defaultRepositoryName = $Matches[1]
        }

        while ($true) {
            $repositoryName = Read-TextWithDefault -Prompt 'Shared workflow repository name' -DefaultValue $defaultRepositoryName

            if ($repositoryName -match '^[A-Za-z0-9._-]+$') {
                break
            }

            Write-Warning "Repository name contains invalid characters. Use letters, numbers, dot (.), underscore (_), or hyphen (-)."
        }

        $selectedSharedRepositoryFullName = "$ForkOwner/$repositoryName"

        $creationModeItems = @(
            'Public (fork)',
            'Private'
        )
        $creationModeSelection = Select-FromMenu -Title "How should '$selectedSharedRepositoryFullName' be created?" -Items $creationModeItems -PromptGuidanceLines @(
            'Choose whether the shared workflow repository should be public (fork style) or private.',
            'Pick an option that target repositories can access for reusable workflow calls.'
        ) -PromptGuidanceDocRelativePath 'docs/setup/github-setup.md' -PromptGuidanceRef $ALM4DataverseRef
        if ($null -eq $creationModeSelection) {
            throw 'No shared workflow repository type selected.'
        }

        if ($creationModeSelection -eq 0) {
            $createResult = Invoke-WithSpectreStatus -Status "Creating public fork '$selectedSharedRepositoryFullName' from '$UpstreamFullName'..." -ScriptBlock {
                $createArgs = @('repo', 'fork', $UpstreamFullName, '--clone=false', '--fork-name', $repositoryName)
                $createOutput = @(& gh @createArgs 2>&1)
                return [pscustomobject]@{
                    ExitCode = $LASTEXITCODE
                    Output   = $createOutput
                }
            }
        }
        else {
            $createResult = Invoke-WithSpectreStatus -Status "Creating private shared workflow repository '$selectedSharedRepositoryFullName'..." -ScriptBlock {
                $createArgs = @('repo', 'create', $selectedSharedRepositoryFullName, '--private', '--add-readme')
                $createOutput = @(& gh @createArgs 2>&1)
                return [pscustomobject]@{
                    ExitCode = $LASTEXITCODE
                    Output   = $createOutput
                }
            }
        }

        if ($createResult.ExitCode -ne 0) {
            $errText = @($createResult.Output) -join "`n"
            if ($errText -match 'already exists') {
                Write-Host "Repository '$selectedSharedRepositoryFullName' already exists; continuing." -ForegroundColor Yellow
            }
            else {
                throw "Failed to create shared workflow repository '$selectedSharedRepositoryFullName': $errText"
            }
        }
        else {
            $createdNewSharedRepository = $true
        }
    }

    $sharedRepoParts = $selectedSharedRepositoryFullName.Split('/', 2)
    $sharedRepoOwnerName = $sharedRepoParts[0]
    $sharedRepoName = $sharedRepoParts[1]
    $sharedRepo = Invoke-WithSpectreStatus -Status "Loading repository details for '$selectedSharedRepositoryFullName'..." -ScriptBlock {
        Get-GitHubRepo -Owner $sharedRepoOwnerName -Repo $sharedRepoName
    }

    $defaultBranch = 'main'
    if ($sharedRepo.defaultBranchRef -and $sharedRepo.defaultBranchRef.name) {
        $defaultBranch = $sharedRepo.defaultBranchRef.name
    }

    $workParent = Join-Path $env:TEMP ("ALM4Dataverse-ForkSync-" + [guid]::NewGuid().ToString('n'))
    $workRoot = Join-Path $workParent 'repo'
    New-DirectoryIfMissing -Path $workParent

    try {
        $forkSyncState = Invoke-WithSpectreStatus -Status "Checking shared workflow repository '$selectedSharedRepositoryFullName' against upstream '$UpstreamFullName'..." -ScriptBlock {
            Get-GitHubForkSyncState `
                -ForkFullName $selectedSharedRepositoryFullName `
                -WorkRoot $workRoot `
                -UpstreamGitSource $UpstreamGitSource `
                -UpstreamFullName $UpstreamFullName `
                -Reference $Reference `
                -DefaultBranch $defaultBranch
        }

        if ($forkSyncState.LocalHash -eq $forkSyncState.UpstreamHash) {
            Write-Host "Shared workflow repository is already up to date for ref '$Reference'."
        }
        else {
            if ($createdNewSharedRepository -or $forkSyncState.MatchesCanonicalUpstreamDefault) {
                Invoke-WithErrorHandling -OperationName "Aligning shared workflow repository '$selectedSharedRepositoryFullName'" -StatusMessage "Aligning shared workflow repository '$selectedSharedRepositoryFullName' to ref '$Reference'..." -CaptureOutputInPanel -ScriptBlock {
                    $previousErrorActionPreference = $ErrorActionPreference
                    try {
                        $ErrorActionPreference = 'Continue'

                        & git -C $workRoot reset --hard $forkSyncState.UpstreamRef 2>&1 | Out-Host
                        if ($LASTEXITCODE -ne 0) {
                            throw "Failed to align shared workflow repository '$selectedSharedRepositoryFullName' to ref '$Reference'."
                        }

                        & git -C $workRoot push --force-with-lease origin $defaultBranch 2>&1 | Out-Host
                        if ($LASTEXITCODE -ne 0) { throw 'Git push failed.' }
                    }
                    finally {
                        $ErrorActionPreference = $previousErrorActionPreference
                    }
                } | Out-Null

                Write-Host "Shared workflow repository aligned successfully."
                return Get-GitHubRepo -Owner $sharedRepoOwnerName -Repo $sharedRepoName
            }

            if ($forkSyncState.CanFastForward) {
                if (Read-YesNo -Prompt "Updates are available from upstream (fast-forward). Update '$selectedSharedRepositoryFullName'?" ) {
                    Invoke-WithErrorHandling -OperationName "Fast-forwarding shared workflow repository '$selectedSharedRepositoryFullName'" -StatusMessage "Fast-forwarding shared workflow repository '$selectedSharedRepositoryFullName'..." -CaptureOutputInPanel -ScriptBlock {
                        $previousErrorActionPreference = $ErrorActionPreference
                        try {
                            $ErrorActionPreference = 'Continue'

                            & git -C $workRoot merge --ff-only $forkSyncState.UpstreamRef 2>&1 | Out-Host
                            if ($LASTEXITCODE -ne 0) { throw 'Git merge failed.' }

                            & git -C $workRoot push origin $defaultBranch 2>&1 | Out-Host
                            if ($LASTEXITCODE -ne 0) { throw 'Git push failed.' }
                        }
                        finally {
                            $ErrorActionPreference = $previousErrorActionPreference
                        }
                    } | Out-Null

                    Write-Host "Shared workflow repository updated successfully."
                }
            }
            else {
                if ($forkSyncState.IsAhead) {
                    Write-Host "Shared workflow repository is ahead of upstream for ref '$Reference'." -ForegroundColor Yellow
                }
                else {
                    $divergedMenuItems = @(
                        "Rebase '$selectedSharedRepositoryFullName' onto ref '$Reference'",
                        "Reset '$selectedSharedRepositoryFullName' '$defaultBranch' to ref '$Reference' (force push)",
                        "Leave '$selectedSharedRepositoryFullName' unchanged"
                    )
                    $divergedSelection = Select-FromMenu -Title "Shared workflow repository '$selectedSharedRepositoryFullName' has diverged from upstream. Choose how to update it." -Items $divergedMenuItems -PromptGuidanceLines @(
                        'Choose how to reconcile divergence between your shared repository and upstream templates.',
                        'Rebase preserves local commits, reset force-aligns to upstream, and leave keeps the current state.'
                    ) -PromptGuidanceDocRelativePath 'docs/setup/github-setup.md' -PromptGuidanceRef $ALM4DataverseRef

                    switch ($divergedSelection) {
                        0 {
                            Invoke-WithErrorHandling -OperationName "Rebasing shared workflow repository '$selectedSharedRepositoryFullName'" -StatusMessage "Rebasing shared workflow repository '$selectedSharedRepositoryFullName' onto '$Reference'..." -CaptureOutputInPanel -ScriptBlock {
                                $previousErrorActionPreference = $ErrorActionPreference
                                try {
                                    $ErrorActionPreference = 'Continue'

                                    & git -C $workRoot rebase $forkSyncState.UpstreamRef 2>&1 | Out-Host
                                    if ($LASTEXITCODE -ne 0) {
                                        throw "Git rebase failed - resolve conflicts manually in '$selectedSharedRepositoryFullName'."
                                    }

                                    & git -C $workRoot push --force-with-lease origin $defaultBranch 2>&1 | Out-Host
                                    if ($LASTEXITCODE -ne 0) { throw 'Git push failed.' }
                                }
                                finally {
                                    $ErrorActionPreference = $previousErrorActionPreference
                                }
                            } | Out-Null

                            Write-Host "Shared workflow repository updated successfully."
                        }
                        1 {
                            Invoke-WithErrorHandling -OperationName "Resetting shared workflow repository '$selectedSharedRepositoryFullName'" -StatusMessage "Resetting shared workflow repository '$selectedSharedRepositoryFullName' to '$Reference'..." -CaptureOutputInPanel -ScriptBlock {
                                $previousErrorActionPreference = $ErrorActionPreference
                                try {
                                    $ErrorActionPreference = 'Continue'

                                    & git -C $workRoot reset --hard $forkSyncState.UpstreamRef 2>&1 | Out-Host
                                    if ($LASTEXITCODE -ne 0) {
                                        throw "Failed to reset shared workflow repository '$selectedSharedRepositoryFullName' to ref '$Reference'."
                                    }

                                    & git -C $workRoot push --force-with-lease origin $defaultBranch 2>&1 | Out-Host
                                    if ($LASTEXITCODE -ne 0) { throw 'Git push failed.' }
                                }
                                finally {
                                    $ErrorActionPreference = $previousErrorActionPreference
                                }
                            } | Out-Null

                            Write-Host "Shared workflow repository updated successfully."
                        }
                        default {
                            Write-Host "Leaving shared workflow repository unchanged." -ForegroundColor Yellow
                        }
                    }
                }
            }
        }
    }
    finally {
        try { Remove-Item -LiteralPath $workParent -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }

    return Get-GitHubRepo -Owner $sharedRepoOwnerName -Repo $sharedRepoName
}

function New-GitHubRepositoryInteractive {
    <#
    .SYNOPSIS
        Interactively creates a new GitHub repository.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DefaultOwner
    )

    Write-Host ""
    Write-Host "Create a new GitHub repository" -ForegroundColor Green
    Write-Host ""

    $owner = Read-TextWithDefault -Prompt 'Repository owner (user or organization)' -DefaultValue $DefaultOwner

    $repoName = $null
    while ($true) {
        $repoName = Read-TextWithDefault -Prompt 'New repository name'
        if ([string]::IsNullOrWhiteSpace($repoName)) {
            Write-Warning "Repository name cannot be empty."
            continue
        }

        if ($repoName -match '^[A-Za-z0-9._-]+$') {
            break
        }

        Write-Warning "Repository name contains invalid characters. Use letters, numbers, dot (.), underscore (_), or hyphen (-)."
    }

    $visibilityItems = @('Private', 'Public')
    $visibilitySelection = Select-FromMenu -Title "Select repository visibility" -Items $visibilityItems -PromptGuidanceLines @(
        'Choose whether the new repository should be private or public.',
        'Private is recommended unless you intentionally want public visibility.'
    ) -PromptGuidanceDocRelativePath 'docs/setup/github-setup.md' -PromptGuidanceRef $ALM4DataverseRef
    if ($null -eq $visibilitySelection) {
        throw "No repository visibility selected."
    }

    $visibilityFlag = if ($visibilitySelection -eq 0) { '--private' } else { '--public' }
    $repoFullName = "$owner/$repoName"

    $createResult = Invoke-WithSpectreStatus -Status "Creating repository '$repoFullName'..." -ScriptBlock {
        $createArgs = @('repo', 'create', $repoFullName, $visibilityFlag, '--add-readme')
        $output = @(& gh @createArgs 2>&1)
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = $output
        }
    }

    if ($createResult.ExitCode -ne 0) {
        throw "Failed to create repository '$repoFullName': $(@($createResult.Output) -join "`n")"
    }

    Write-Host "Created repository '$repoFullName'." -ForegroundColor Green
    return Invoke-WithSpectreStatus -Status "Loading repository details for '$repoFullName'..." -ScriptBlock {
        Get-GitHubRepo -Owner $owner -Repo $repoName
    }
}

#endregion

#region Entra ID Operations

function Ensure-EntraIdServicePrincipal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ApplicationId,
        [Parameter(Mandatory)][string]$TenantId
    )

    $graphToken = Get-AuthToken -ResourceUrl "https://graph.microsoft.com" -TenantId $TenantId
    $headers = @{
        Authorization  = "Bearer $($graphToken.AccessToken)"
        "Content-Type" = "application/json"
    }

    $uri = "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$ApplicationId'"
    $existing = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get

    if ($existing.value.Count -gt 0) {
        Write-Host "Service Principal for App '$ApplicationId' already exists."
        return $existing.value[0]
    }

    Write-Host "Creating Service Principal for App '$ApplicationId'..." -ForegroundColor Yellow
    $body = @{ appId = $ApplicationId }
    $sp = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/servicePrincipals" -Headers $headers -Method Post -Body ($body | ConvertTo-Json)
    Write-Host "Created Service Principal."
    return $sp
}

function Add-EntraIdFederatedCredential {
    <#
    .SYNOPSIS
        Adds a federated identity credential to an Entra ID application for Workload Identity Federation.
    
    .DESCRIPTION
        Creates a federated identity credential that allows GitHub Actions to authenticate to Azure
        without a client secret.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ApplicationObjectId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$CredentialName,
        [Parameter()][string]$Description = 'GitHub Actions WIF credential (created by setup-github.ps1)'
    )

    $graphToken = Get-AuthToken -ResourceUrl "https://graph.microsoft.com" -TenantId $TenantId
    $headers = @{
        Authorization  = "Bearer $($graphToken.AccessToken)"
        "Content-Type" = "application/json"
    }

    Write-Host "Adding federated identity credential '$CredentialName'..." -ForegroundColor Yellow

    # Check if a credential with this name already exists
    $listUri = "https://graph.microsoft.com/beta/applications/$ApplicationObjectId/federatedIdentityCredentials"
    try {
        $existing = Invoke-RestMethod -Uri $listUri -Headers $headers -Method Get
        $match = $existing.value | Where-Object { $_.name -eq $CredentialName } | Select-Object -First 1
        if ($match) {
            Write-Host "Federated credential '$CredentialName' already exists."
            return $match
        }
    }
    catch {
        Write-Warning "Failed to check for existing federated credentials: $($_.Exception.Message)"
    }

    # Create the federated credential
    $body = @{
        name      = $CredentialName
        issuer    = 'https://token.actions.githubusercontent.com'
        subject   = $Subject
        audiences = @('api://AzureADTokenExchange')
        description = $Description
    }

    try {
        $result = Invoke-RestMethod -Uri $listUri -Headers $headers -Method Post -Body ($body | ConvertTo-Json)
        Write-Host "Created federated identity credential successfully."
        return $result
    }
    catch {
        Write-Error "Failed to create federated identity credential: $($_.Exception.Message)"
        throw
    }
}

function New-EntraIdApplication {
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter()][string]$AuthType = 'WIF'
    )
    
    # Get token for Graph
    $graphToken = Get-AuthToken -ResourceUrl "https://graph.microsoft.com" -TenantId $TenantId
    $headers = @{
        Authorization  = "Bearer $($graphToken.AccessToken)"
        "Content-Type" = "application/json"
    }

    # Check if app exists
    $filter = "displayName eq '$DisplayName'"
    $uri = "https://graph.microsoft.com/v1.0/applications?`$filter=$filter"
    
    $existing = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
    
    $app = $null
    if ($existing.value.Count -gt 0) {
        $app = $existing.value[0]
        Write-Host "Found existing App Registration '$DisplayName' ($($app.appId))."
    }
    else {
        Write-Host "Creating App Registration '$DisplayName'..." -ForegroundColor Yellow
        $body = @{
            displayName    = $DisplayName
            signInAudience = "AzureADMyOrg"
        }
        $app = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/applications" -Headers $headers -Method Post -Body ($body | ConvertTo-Json)
        Write-Host "Created App Registration '$DisplayName' ($($app.appId))."
    }

    [void](Ensure-EntraIdServicePrincipal -ApplicationId $app.appId -TenantId $TenantId)

    $result = [pscustomobject]@{
        Name                = $DisplayName
        ApplicationId       = $app.appId
        ApplicationObjectId = $app.id
        ClientSecret        = $null
        TenantId            = $TenantId
        AuthType            = $AuthType
    }

    if ($AuthType -eq 'Secret') {
        # Create secret for traditional authentication
        Write-Host "Creating client secret..." -ForegroundColor Yellow
        $result.ClientSecret = New-EntraIdApplicationSecret -ApplicationObjectId $app.id -TenantId $TenantId
    }

    return $result
}

function Get-GitHubCredentialsForEnvironment {
    <#
    .SYNOPSIS
        Interactively selects or creates Entra ID credentials for a GitHub environment.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][array]$ExistingCredentials,
        [Parameter()][string]$TenantId,
        [Parameter()][string]$RepoName,
        [Parameter()][string]$EnvironmentName,
        [Parameter()][object]$ExistingCredential
    )

    # Build Menu
    $menuItems  = @()
    $menuActions = @()

    if ($ExistingCredential -and -not [string]::IsNullOrWhiteSpace($ExistingCredential.ApplicationId)) {
        $existingLabel = "Use existing: $($ExistingCredential.Name) ($($ExistingCredential.ApplicationId))"
        if ($ExistingCredential.AuthType -eq 'Secret' -and $ExistingCredential.HasExistingSecret) {
            $existingLabel += ' [secret already configured]'
        }
        elseif ($ExistingCredential.AuthType -eq 'WIF') {
            $existingLabel += ' [workload identity federation]'
        }

        $menuItems += $existingLabel
        $menuActions += @{ Type = 'Existing'; Creds = $ExistingCredential }
    }

    $menuItems  += "Create new App Registration (Entra ID)"
    $menuActions += @{ Type = 'CreateNew' }

    $menuItems  += "Enter existing App Registration details"
    $menuActions += @{ Type = 'Manual' }

    foreach ($c in $ExistingCredentials) {
        $menuItems  += "Reuse: $($c.Name) ($($c.ApplicationId))"
        $menuActions += @{ Type = 'Cached'; Creds = $c }
    }

    Write-Host ""
    Write-SetupGuidance -Lines @(
        "App Registration credentials are used to authenticate the workflow to Dataverse.",
        "Best practice: use a separate App Registration per environment and prefer Workload Identity Federation where possible."
    ) -DocRelativePath 'docs/config/github-secrets.md' -Ref $ALM4DataverseRef -Header 'App registration guidance'
    
    $selection = Select-FromMenu -Title "Select App Registration credentials for '$EnvironmentName'" -Items $menuItems -PromptGuidanceLines @(
        'Select existing credentials or create a new App Registration for this environment.',
        'Prefer workload identity federation where possible to avoid client-secret rotation overhead.'
    ) -PromptGuidanceDocRelativePath 'docs/config/github-secrets.md' -PromptGuidanceRef $ALM4DataverseRef
    if ($null -eq $selection) { throw "No credential selected." }

    $action = $menuActions[$selection]

    if ($action.Type -eq 'Existing') {
        $selectedCredential = $action.Creds.PSObject.Copy()

        if ($selectedCredential.AuthType -eq 'Secret' -and $selectedCredential.HasExistingSecret) {
            $secretHandlingItems = @(
                'Keep the existing client secret',
                'Generate a new client secret now'
            )

            $secretHandlingSelection = Select-FromMenu -Title "How should setup handle the existing client secret for '$EnvironmentName'?" -Items $secretHandlingItems -PromptGuidanceLines @(
                'Choose whether to keep the existing secret or rotate it now.',
                'Rotate when policy requires periodic renewal or the current secret is no longer trusted.'
            ) -PromptGuidanceDocRelativePath 'docs/config/github-secrets.md' -PromptGuidanceRef $ALM4DataverseRef
            if ($null -eq $secretHandlingSelection) {
                throw 'No client secret handling option selected.'
            }

            if ($secretHandlingSelection -eq 1) {
                if ([string]::IsNullOrWhiteSpace($selectedCredential.ApplicationObjectId)) {
                    $resolvedApplication = Resolve-EntraIdApplicationByAppId -ApplicationId $selectedCredential.ApplicationId -TenantId $selectedCredential.TenantId
                    if ($resolvedApplication) {
                        $selectedCredential.ApplicationObjectId = $resolvedApplication.id
                        if ([string]::IsNullOrWhiteSpace($selectedCredential.Name) -and -not [string]::IsNullOrWhiteSpace($resolvedApplication.displayName)) {
                            $selectedCredential.Name = $resolvedApplication.displayName
                        }
                    }
                }

                if ([string]::IsNullOrWhiteSpace($selectedCredential.ApplicationObjectId)) {
                    throw "Cannot generate a new client secret for '$($selectedCredential.ApplicationId)' because the App Registration object id could not be resolved."
                }

                Write-Host 'Generating a new client secret...' -ForegroundColor Yellow
                $selectedCredential.ClientSecret = New-EntraIdApplicationSecret -ApplicationObjectId $selectedCredential.ApplicationObjectId -TenantId $selectedCredential.TenantId
            }

            return $selectedCredential
        }

        return $selectedCredential
    }
    elseif ($action.Type -eq 'Cached') {
        return $action.Creds
    }
    elseif ($action.Type -eq 'CreateNew') {
        # Prompt for authentication type
        Write-Host ""
        $authTypeItems = @(
            "Workload Identity Federation (recommended, no secrets)",
            "Service Principal with Secret (traditional)"
        )
        $authTypeSelection = Select-FromMenu -Title "Select authentication type for the new App Registration" -Items $authTypeItems -PromptGuidanceLines @(
            'Choose between workload identity federation and client-secret authentication.',
            'Workload identity federation is recommended when supported because it removes shared secret management.'
        ) -PromptGuidanceDocRelativePath 'docs/config/github-secrets.md' -PromptGuidanceRef $ALM4DataverseRef
        if ($null -eq $authTypeSelection) { throw "No authentication type selected." }
        
        $authType = if ($authTypeSelection -eq 0) { 'WIF' } else { 'Secret' }
        
        $appName = "$RepoName - $EnvironmentName - deployment"
        
        return New-EntraIdApplication -DisplayName $appName -TenantId $TenantId -AuthType $authType
    }
    else { # Manual
        Write-Host "Enter App Registration details:" -ForegroundColor Cyan
        $name = Read-TextWithDefault -Prompt 'Friendly name (for reuse reference)' -AllowEmpty
        if ([string]::IsNullOrWhiteSpace($name)) { $name = "Credential-" + (Get-Date -Format "HHmm") }
        
        while ($true) {
            $appId = Read-TextWithDefault -Prompt 'Application ID (Client ID)'
            if ($appId -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
                break
            }
            else {
                Write-Warning "The Application ID must be a valid GUID. Please try again."
            }
        }

        while ($true) {
            $appObjectId = Read-TextWithDefault -Prompt 'Application object ID (from App registrations > Overview, not the enterprise app object ID)'
            if ($appObjectId -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
                break
            }
            else {
                Write-Warning "The Application Object ID must be a valid GUID. Please try again."
            }
        }

        # Prompt for authentication type
        Write-Host ""
        $authTypeItems = @(
            "Workload Identity Federation (recommended, no secrets)",
            "Service Principal with Secret (traditional)"
        )
        $authTypeSelection = Select-FromMenu -Title "Select authentication type" -Items $authTypeItems -PromptGuidanceLines @(
            'Choose the authentication mode for the provided App Registration details.',
            'Use secret-based auth only when workload identity federation is not suitable for your scenario.'
        ) -PromptGuidanceDocRelativePath 'docs/config/github-secrets.md' -PromptGuidanceRef $ALM4DataverseRef
        if ($null -eq $authTypeSelection) { throw "No authentication type selected." }
        
        $authType = if ($authTypeSelection -eq 0) { 'WIF' } else { 'Secret' }
        
        $secret = $null
        if ($authType -eq 'Secret') {
            while ($true) {
                $secret = Read-SecretText -Prompt 'Client Secret'
                
                if ($secret -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
                    Write-Warning "The Client Secret looks like a GUID. You should enter the Secret VALUE, not the Secret ID."
                    if (Read-YesNo -Prompt "Are you sure this is the Secret Value?" -DefaultNo) {
                        break
                    }
                } else {
                    break
                }
            }
        }

        [void](Ensure-EntraIdServicePrincipal -ApplicationId $appId -TenantId $TenantId)

        return [pscustomobject]@{
            Name                = $name
            ApplicationId       = $appId
            ApplicationObjectId = $appObjectId
            ClientSecret        = $secret
            TenantId            = $TenantId
            AuthType            = $authType
        }
    }
}

#endregion

#region Dataverse Operations

function Get-GitHubExistingEnvironmentSelectionSummary {
    [CmdletBinding()]
    param(
        [Parameter()][object]$ExistingEnvironment
    )

    if (-not $ExistingEnvironment) {
        return $null
    }

    $summaryParts = @()
    if ($ExistingEnvironment.PSObject.Properties.Name -contains 'Credentials' -and $ExistingEnvironment.Credentials) {
        $summaryParts += (Get-CredentialSummaryText -Credentials $ExistingEnvironment.Credentials)
    }
    if ($ExistingEnvironment.PSObject.Properties.Name -contains 'ServiceAccountUPN' -and -not [string]::IsNullOrWhiteSpace($ExistingEnvironment.ServiceAccountUPN)) {
        $summaryParts += "Service account: $($ExistingEnvironment.ServiceAccountUPN)"
    }

    if ($summaryParts.Count -eq 0) {
        return $null
    }

    return ($summaryParts -join ' | ')
}

function Get-DataverseEnvironmentCatalog {
    [CmdletBinding()]
    param(
        [Parameter()][switch]$ForceRefresh,
        [Parameter()][switch]$ShowStatus
    )

    $hasCachedCatalog = ($null -ne (Get-Variable -Name 'dataverseEnvironmentCatalog' -Scope Script -ErrorAction SilentlyContinue)) -and $null -ne $script:dataverseEnvironmentCatalog
    if (-not $ForceRefresh -and $hasCachedCatalog) {
        return @($script:dataverseEnvironmentCatalog)
    }

    $fetchCatalog = {
        @(Get-DataverseEnvironment -AccessToken {
            param($resource)
            if (-not $resource) { $resource = 'https://globaldisco.crm.dynamics.com/' }
            try {
                $uri = [System.Uri]$resource
                $resource = $uri.GetLeftPart([System.UriPartial]::Authority)
            }
            catch {}

            $auth = Get-AuthToken -ResourceUrl $resource -TenantId $TenantId
            return $auth.AccessToken
        })
    }

    if ($ShowStatus) {
        $script:dataverseEnvironmentCatalog = @(Invoke-WithSpectreStatus -Status 'Retrieving Dataverse environments...' -ScriptBlock $fetchCatalog)
    }
    else {
        $script:dataverseEnvironmentCatalog = @(& $fetchCatalog)
    }

    if (-not $script:dataverseEnvironmentCatalog -or $script:dataverseEnvironmentCatalog.Count -eq 0) {
        throw 'No Dataverse environments found. Ensure the account has access to at least one environment.'
    }

    return @($script:dataverseEnvironmentCatalog)
}

function Select-DataverseEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter()][string]$ExcludeUrl,
        [Parameter()][string]$PreferredUrl,
        [Parameter()][string]$PreferredSelectionSummary,
        [Parameter()][switch]$KeepPreferredInList,
        [Parameter()][string[]]$PromptGuidanceLines,
        [Parameter()][string]$PromptGuidanceDocRelativePath,
        [Parameter()][string]$PromptGuidanceRef
    )

    Write-Host ""

    $environments = @(Get-DataverseEnvironmentCatalog -ShowStatus)

    $normalizedExcludeUrl = ConvertTo-NormalizedEnvironmentUrl -Url $ExcludeUrl
    $normalizedPreferredUrl = ConvertTo-NormalizedEnvironmentUrl -Url $PreferredUrl

    if (-not [string]::IsNullOrWhiteSpace($ExcludeUrl)) {
        $environments = @($environments | Where-Object {
            (ConvertTo-NormalizedEnvironmentUrl -Url $_.Endpoints["WebApplication"]) -ne $normalizedExcludeUrl
        })
    }

    if ($environments.Count -eq 0) {
        throw "No selectable Dataverse environments found (all were excluded)."
    }

    $menuItems = @()
    $menuActions = @()

    if (-not [string]::IsNullOrWhiteSpace($normalizedPreferredUrl)) {
        $preferredEnvironment = $environments | Where-Object {
            (ConvertTo-NormalizedEnvironmentUrl -Url $_.Endpoints['WebApplication']) -eq $normalizedPreferredUrl
        } | Select-Object -First 1

        if ($preferredEnvironment) {
            $preferredMenuItem = "Use existing environment: $($preferredEnvironment.FriendlyName) ($($preferredEnvironment.Endpoints['WebApplication']))"
            if (-not [string]::IsNullOrWhiteSpace($PreferredSelectionSummary)) {
                $preferredMenuItem += " | $PreferredSelectionSummary"
            }

            $menuItems += $preferredMenuItem
            $menuActions += [pscustomobject]@{
                Environment = [pscustomobject]@{
                    FriendlyName             = $preferredEnvironment.FriendlyName
                    UniqueName               = $preferredEnvironment.UniqueName
                    Endpoints                = $preferredEnvironment.Endpoints
                    UseExistingConfiguration = $true
                }
            }

            if (-not $KeepPreferredInList) {
                $environments = @($environments | Where-Object {
                    (ConvertTo-NormalizedEnvironmentUrl -Url $_.Endpoints['WebApplication']) -ne $normalizedPreferredUrl
                })
            }
        }
    }

    foreach ($environment in $environments) {
        $menuItems += "$($environment.FriendlyName) ($($environment.Endpoints['WebApplication']))"
        $menuActions += [pscustomobject]@{ Environment = $environment }
    }
    
    $index = Select-FromMenu `
        -Title $Prompt `
        -Items $menuItems `
        -PromptGuidanceLines $PromptGuidanceLines `
        -PromptGuidanceDocRelativePath $PromptGuidanceDocRelativePath `
        -PromptGuidanceRef $PromptGuidanceRef
    if ($null -eq $index) { return $null }

    return $menuActions[$index].Environment
}

function Ensure-DataverseApplicationUser {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EnvironmentUrl,
        [Parameter(Mandatory)][string]$ApplicationId,
        [Parameter(Mandatory)][string]$TenantId
    )

    Write-Host "Ensuring application user '$ApplicationId' exists in '$EnvironmentUrl'..." -ForegroundColor DarkGray

    $conn = Get-DataverseConnection -Url $EnvironmentUrl -AccessToken { 
        param($resource)
        if (-not $resource) { $resource = $EnvironmentUrl }
        try {
            $uri = [System.Uri]$resource
            $resource = $uri.GetLeftPart([System.UriPartial]::Authority)
        } catch {}
        $auth = Get-AuthToken -ResourceUrl $resource -TenantId $TenantId
        return $auth.AccessToken
    }

    if (-not $conn) {
        throw "Failed to connect to Dataverse."
    }

    # 1. Get Root Business Unit
    $rootBu = Get-DataverseRecord -Connection $conn -TableName "businessunit" -FilterValues @{ parentbusinessunitid = $null } -Columns "businessunitid" | Select-Object -First 1
    if (-not $rootBu) { throw "Could not find root business unit." }
    $rootBuId = $rootBu.businessunitid

    # 2. Get System Administrator Role
    $roleName = "System Administrator"
    $role = Get-DataverseRecord -Connection $conn -TableName "role" -FilterValues @{ name = $roleName; businessunitid = $rootBuId } -Columns "roleid" | Select-Object -First 1
    if (-not $role) { throw "Could not find '$roleName' role in root business unit." }
    $roleId = $role.roleid

    # 3. Check/Create System User
    $user = Get-DataverseRecord -Connection $conn -TableName "systemuser" -FilterValues @{ applicationid = $ApplicationId } -Columns "systemuserid" | Select-Object -First 1
    $userId = $null

    if ($user) {
        Write-Host "User already exists. ID: $($user.systemuserid)"
        $userId = $user.systemuserid
    }
    else {
        Write-Host "Creating application user..."
        $userAttributes = @{
            "applicationid"  = $ApplicationId
            "businessunitid" = $rootBuId
        }
        $createdUser = $userAttributes | Set-DataverseRecord -Connection $conn -TableName "systemuser" -CreateOnly -PassThru
        $userId = $createdUser.Id
        Write-Host "User created. ID: $userId"
    }

    # 4. Associate User with Role
    $existingAssociation = Get-DataverseRecord -Connection $conn -TableName "systemuserroles" -FilterValues @{ systemuserid = $userId; roleid = $roleId } -Top 1
    if (-not $existingAssociation) {
        Write-Host "Associating user with '$roleName' role..."
        @{
            systemuserid = $userId
            roleid       = $roleId
        } | Set-DataverseRecord -Connection $conn -TableName "systemuserroles" -CreateOnly
        Write-Host "Association successful."
    }
    else {
        Write-Host "User is already associated with '$roleName' role."
    }
}

function Ensure-DataverseServiceAccountUser {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EnvironmentUrl,
        [Parameter(Mandatory)][string]$ServiceAccountUPN,
        [Parameter(Mandatory)][string]$TenantId
    )

    Write-Host "Ensuring service account '$ServiceAccountUPN' has System Administrator role in '$EnvironmentUrl'..." -ForegroundColor DarkGray

    $conn = Get-DataverseConnection -Url $EnvironmentUrl -AccessToken { 
        param($resource)
        if (-not $resource) { $resource = $EnvironmentUrl }
        try {
            $uri = [System.Uri]$resource
            $resource = $uri.GetLeftPart([System.UriPartial]::Authority)
        } catch {}
        $auth = Get-AuthToken -ResourceUrl $resource -TenantId $TenantId
        return $auth.AccessToken
    }

    if (-not $conn) { throw "Failed to connect to Dataverse." }

    $rootBu = Get-DataverseRecord -Connection $conn -TableName "businessunit" -FilterValues @{ parentbusinessunitid = $null } -Columns "businessunitid" | Select-Object -First 1
    if (-not $rootBu) { throw "Could not find root business unit." }
    $rootBuId = $rootBu.businessunitid

    $roleName = "System Administrator"
    $role = Get-DataverseRecord -Connection $conn -TableName "role" -FilterValues @{ name = $roleName; businessunitid = $rootBuId } -Columns "roleid" | Select-Object -First 1
    if (-not $role) { throw "Could not find '$roleName' role in root business unit." }
    $roleId = $role.roleid

    $user = Get-DataverseRecord -Connection $conn -TableName "systemuser" -FilterValues @{ domainname = $ServiceAccountUPN } -Columns "systemuserid","fullname" | Select-Object -First 1
    $userId = $null

    if ($user) {
        $userId = $user.systemuserid
        Write-Host "Found service account: $($user.fullname) (ID: $userId)"
    }
    else {
        Write-Host "Service account '$ServiceAccountUPN' not found. Creating..." -ForegroundColor Yellow
        $userAttributes = @{
            "domainname"           = $ServiceAccountUPN
            "businessunitid"       = $rootBuId
            "internalemailaddress" = $ServiceAccountUPN
            "firstname"            = "Service"
            "lastname"             = "Account"
        }
        $createdUser = $userAttributes | Set-DataverseRecord -Connection $conn -TableName "systemuser" -CreateOnly -PassThru
        $userId = $createdUser.Id
        Write-Host "Service account created. ID: $userId"
    }

    $existingAssociation = Get-DataverseRecord -Connection $conn -TableName "systemuserroles" -FilterValues @{ systemuserid = $userId; roleid = $roleId } -Top 1
    if (-not $existingAssociation) {
        Write-Host "Associating service account with '$roleName' role..."
        @{
            systemuserid = $userId
            roleid       = $roleId
        } | Set-DataverseRecord -Connection $conn -TableName "systemuserroles" -CreateOnly
        Write-Host "Association successful."
    }
    else {
        Write-Host "Service account is already associated with '$roleName' role."
    }
}

function Get-DataverseServiceAccountUPN {
    [CmdletBinding()]
    param(
        [Parameter()][array]$ExistingServiceAccounts,
        [Parameter()][string]$EnvironmentName,
        [Parameter()][string]$ExistingValue
    )

    $menuItems  = @()
    $menuActions = @()

    if (-not [string]::IsNullOrWhiteSpace($ExistingValue)) {
        $menuItems  += "Use existing: $ExistingValue"
        $menuActions += @{ Type = 'Existing'; UPN = $ExistingValue }
    }

    $menuItems  += "Enter a new service account UPN"
    $menuActions += @{ Type = 'Manual' }

    foreach ($sa in $ExistingServiceAccounts) {
        if ($sa -ne $ExistingValue) {
            $menuItems  += "Reuse: $sa"
            $menuActions += @{ Type = 'Cached'; UPN = $sa }
        }
    }

    Write-Host ""
    Write-SetupGuidance -Lines @(
        "Service Account credentials are used for ownership and licensing of Cloud Flows.",
        "Use a licensed user account with System Administrator role.",
        "Best practice: keep this separate from your personal admin account so automation ownership stays stable."
    ) -DocRelativePath 'docs/config/github-secrets.md' -Ref $ALM4DataverseRef -Header 'Service account guidance'
    
    $selection = Select-FromMenu `
        -Title "Select Dataverse Service Account for '$EnvironmentName'" `
        -Items $menuItems `
        -PromptGuidanceLines @(
            "Choose the service account UPN that should own flow activation and runtime ownership in '$EnvironmentName'.",
            'Reusing an existing service account keeps ownership consistent; entering a new one changes who owns activated processes.'
        ) `
        -PromptGuidanceDocRelativePath 'docs/config/github-secrets.md' `
        -PromptGuidanceRef $ALM4DataverseRef
    if ($null -eq $selection) { throw "No service account selected." }

    $action = $menuActions[$selection]

    if ($action.Type -in @('Cached', 'Existing')) {
        return $action.UPN
    }
    else { # Manual
        Write-Host ""
        Write-Host "IMPORTANT: The service account must be licensed with an appropriate D365/PowerApps/etc licence." -ForegroundColor Yellow
        Write-Host ""
        
        while ($true) {
            $upn = Read-TextWithDefault -Prompt 'Service Account UPN (for example: serviceaccount@contoso.com)'
            if ([string]::IsNullOrWhiteSpace($upn)) {
                Write-Warning "Service Account UPN cannot be empty."
                continue
            }
            if ($upn -match '^[^@]+@[^@]+\.[^@]+$') {
                return $upn
            }
            else {
                Write-Warning "The UPN does not appear to be in a valid format."
            }
        }
    }
}

function Get-DataverseSolutionsSelection {
    [CmdletBinding()]
    param(
        [Parameter()][string]$ExistingConfigPath,
        [Parameter()][string]$ExistingEnvironmentUrl,
        [Parameter()][object]$ExistingEnvironmentConfiguration
    )
    
    Write-Host ""
    Write-SetupGuidance -Lines @(
        "Select the Dataverse DEV environment that contains the unmanaged solutions you want ALM4Dataverse to export and build from source control.",
        "The selected environment becomes the source of truth for solution discovery during setup, so choose the DEV environment that your team actively customises in.",
        "Best practice: add solutions in dependency order because that is the order written into alm-config.psd1 and later reused by the automation."
    ) -DocRelativePath 'docs/config/alm-config.md' -Ref $ALM4DataverseRef -Header 'Solution source guidance'

    $existingEnvironmentSummary = Get-GitHubExistingEnvironmentSelectionSummary -ExistingEnvironment $ExistingEnvironmentConfiguration
    $selectedEnv = Select-DataverseEnvironment `
        -Prompt "Select your DEV environment" `
        -PreferredUrl $ExistingEnvironmentUrl `
        -PreferredSelectionSummary $existingEnvironmentSummary `
        -PromptGuidanceLines @(
            'Choose the DEV Dataverse environment used to discover unmanaged solutions for alm-config.psd1.',
            'Pick the environment that currently reflects the source-controlled customization baseline.'
        ) `
        -PromptGuidanceDocRelativePath 'docs/config/alm-config.md' `
        -PromptGuidanceRef $ALM4DataverseRef
    if (-not $selectedEnv) { throw "No environment selected." }

    $devEnvUrl = ConvertTo-NormalizedEnvironmentUrl -Url $selectedEnv.Endpoints["WebApplication"]
    $normalizedExistingEnvironmentUrl = ConvertTo-NormalizedEnvironmentUrl -Url $ExistingEnvironmentUrl
    $reuseExistingConfiguration = (
        ($selectedEnv.PSObject.Properties.Name -contains 'UseExistingConfiguration' -and $selectedEnv.UseExistingConfiguration) -or
        (
            -not [string]::IsNullOrWhiteSpace($normalizedExistingEnvironmentUrl) -and
            $devEnvUrl -ieq $normalizedExistingEnvironmentUrl
        )
    )

    Write-Host "Selected: $($selectedEnv.FriendlyName) ($devEnvUrl)" -ForegroundColor Cyan

    $connection = Invoke-WithSpectreStatus -Status 'Connecting to the selected DEV environment...' -ScriptBlock {
        Get-DataverseConnection -Url $devEnvUrl -AccessToken {
            param($resource)
            if (-not $resource) { $resource = 'https://globaldisco.crm.dynamics.com/' }
            try {
                $uri = [System.Uri]$resource
                $resource = $uri.GetLeftPart([System.UriPartial]::Authority)
            } catch {}
            $auth = Get-AuthToken -ResourceUrl $resource -TenantId $TenantId
            return $auth.AccessToken
        }
    }
    
    if (-not $connection) { throw "Failed to connect to Dataverse environment." }
    
    Write-Host "Connected to: $($connection.ConnectedOrgFriendlyName)"
    
    $allSolutions = Invoke-WithSpectreStatus -Status 'Retrieving unmanaged solutions from Dataverse...' -ScriptBlock {
        Get-DataverseRecord -Connection $connection -TableName 'solution' -Columns @('solutionid','uniquename','friendlyname','version','ismanaged') -FilterValues @{
            'isvisible' = $true
            'ismanaged' = $false
        }
    }
    
    if (-not $allSolutions -or $allSolutions.Count -eq 0) {
        Write-Host "No unmanaged solutions found in the environment." -ForegroundColor Yellow
        return [pscustomobject]@{ Solutions = @(); EnvironmentUrl = $devEnvUrl; ReuseExistingConfiguration = $reuseExistingConfiguration }
    }
    
    $userSolutions = @($allSolutions | Where-Object { 
        $_.uniquename -notmatch '^(Default|Active|Basic|msdyn_|ms|MicrosoftFlow|PowerPlatform)' -and 
        $_.uniquename -ne 'System' 
    } | Sort-Object friendlyname)
    
    if ($userSolutions.Count -eq 0) {
        Write-Host "No user-created solutions found." -ForegroundColor Yellow
        return [pscustomobject]@{ Solutions = @(); EnvironmentUrl = $devEnvUrl; ReuseExistingConfiguration = $reuseExistingConfiguration }
    }

    # Pre-populate from existing alm-config.psd1 if available
    $selectedSolutions = @()
    if ($ExistingConfigPath -and (Test-Path -LiteralPath $ExistingConfigPath)) {
        try {
            $existingConfig = Import-PowerShellDataFile -Path $ExistingConfigPath
            if ($existingConfig.solutions) {
                foreach ($existing in $existingConfig.solutions) {
                    $match = $userSolutions | Where-Object { $_.uniquename -eq $existing.name } | Select-Object -First 1
                    if ($match) { $selectedSolutions += $match }
                }
                if ($selectedSolutions.Count -gt 0) {
                    Write-Host "Pre-selected $($selectedSolutions.Count) solution(s) from existing configuration." -ForegroundColor Green
                    Start-Sleep -Seconds 2
                }
            }
        }
        catch { <# ignore #> }
    }

    $selectedSolutions = @(Select-OrderedSolutions -AvailableSolutions $userSolutions -InitiallySelectedSolutions $selectedSolutions)
    
    # Convert to alm-config.psd1 format
    $configSolutions = @()
    foreach ($sol in $selectedSolutions) {
        $configSolutions += @{ name = $sol.uniquename; deployUnmanaged = $false }
    }
    
    return [pscustomobject]@{ Solutions = $configSolutions; EnvironmentUrl = $devEnvUrl; EnvironmentFriendlyName = $selectedEnv.FriendlyName; ReuseExistingConfiguration = $reuseExistingConfiguration }
}

function Get-GitHubEnvironmentConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][string]$EnvironmentUrl,
        [Parameter()][string]$FriendlyName,
        [Parameter()][array]$ExistingCredentials,
        [Parameter()][array]$ExistingServiceAccounts,
        [Parameter()][string]$TenantId,
        [Parameter()][string]$RepoName,
        [Parameter()][object]$ExistingCredential,
        [Parameter()][string]$ExistingServiceAccountUPN
    )

    $creds = Get-GitHubCredentialsForEnvironment `
        -ExistingCredentials $ExistingCredentials `
        -TenantId $TenantId `
        -RepoName $RepoName `
        -EnvironmentName $EnvironmentName `
        -ExistingCredential $ExistingCredential

    $serviceAccountUPN = Get-DataverseServiceAccountUPN `
        -ExistingServiceAccounts $ExistingServiceAccounts `
        -EnvironmentName $EnvironmentName `
        -ExistingValue $ExistingServiceAccountUPN

    return [pscustomobject]@{
        ShortName        = $EnvironmentName
        FriendlyName     = $(if ([string]::IsNullOrWhiteSpace($FriendlyName)) { $EnvironmentName } else { $FriendlyName })
        Url              = (ConvertTo-NormalizedEnvironmentUrl -Url $EnvironmentUrl)
        Credentials      = $creds
        ServiceAccountUPN = $serviceAccountUPN
    }
}

function Apply-GitHubEnvironmentConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$EnvironmentConfiguration,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$RepoOwner,
        [Parameter(Mandatory)][string]$RepoName,
        [Parameter(Mandatory)][string]$RepoFullName,
        [Parameter()][bool]$UseGitHubEnvironments = $true,
        [Parameter()][bool]$EnableApprovals = $false,
        [Parameter()][array]$RequiredReviewerIds = @()
    )

    $creds = $EnvironmentConfiguration.Credentials
    $serviceAccountUPN = $EnvironmentConfiguration.ServiceAccountUPN

    if ($creds.AuthType -eq 'WIF' -and $creds.ApplicationObjectId) {
        $credName = ConvertTo-UrlSafeName -Name "gha-$RepoName-env-$($EnvironmentConfiguration.ShortName)"
        [void](Add-EntraIdFederatedCredential `
            -ApplicationObjectId $creds.ApplicationObjectId `
            -TenantId $TenantId `
            -Subject "repo:${RepoFullName}:environment:$($EnvironmentConfiguration.ShortName)" `
            -CredentialName $credName)
    }

    if ($UseGitHubEnvironments) {
        [void](Ensure-GitHubEnvironment `
            -Owner $RepoOwner `
            -Repo $RepoName `
            -EnvironmentName $EnvironmentConfiguration.ShortName `
            -EnableApprovals:$EnableApprovals `
            -RequiredReviewerIds $RequiredReviewerIds)

        Set-GitHubEnvironmentVariable -Owner $RepoOwner -Repo $RepoName -EnvironmentName $EnvironmentConfiguration.ShortName `
            -VariableName 'AZURE_CLIENT_ID' -VariableValue $creds.ApplicationId
        Set-GitHubEnvironmentVariable -Owner $RepoOwner -Repo $RepoName -EnvironmentName $EnvironmentConfiguration.ShortName `
            -VariableName 'AZURE_TENANT_ID' -VariableValue $creds.TenantId

        if ($creds.AuthType -eq 'Secret' -and $creds.ClientSecret) {
            Set-GitHubEnvironmentSecret -Owner $RepoOwner -Repo $RepoName -EnvironmentName $EnvironmentConfiguration.ShortName `
                -SecretName 'AZURE_CLIENT_SECRET' -SecretValue $creds.ClientSecret
        }

        Set-GitHubEnvironmentVariable -Owner $RepoOwner -Repo $RepoName -EnvironmentName $EnvironmentConfiguration.ShortName `
            -VariableName 'DATAVERSE_URL' -VariableValue $EnvironmentConfiguration.Url

        Set-GitHubEnvironmentVariable -Owner $RepoOwner -Repo $RepoName -EnvironmentName $EnvironmentConfiguration.ShortName `
            -VariableName 'DATAVERSESERVICEACCOUNTUPN' -VariableValue $serviceAccountUPN
    }
    else {
        Set-GitHubPrefixedEnvironmentCredentials `
            -Owner $RepoOwner `
            -Repo $RepoName `
            -EnvironmentName $EnvironmentConfiguration.ShortName `
            -Credentials $creds `
            -DataverseUrl $EnvironmentConfiguration.Url `
            -ServiceAccountUPN $serviceAccountUPN
    }

    Ensure-DataverseApplicationUser -EnvironmentUrl $EnvironmentConfiguration.Url -ApplicationId $creds.ApplicationId -TenantId $TenantId
    Ensure-DataverseServiceAccountUser -EnvironmentUrl $EnvironmentConfiguration.Url -ServiceAccountUPN $serviceAccountUPN -TenantId $TenantId
}

#endregion

#region Repository Setup

function Copy-WorkflowTemplatesToRepo {
    <#
    .SYNOPSIS
        Copies ALM4Dataverse workflow templates into the user's GitHub repository clone.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$SharedWorkflowRepository,
        [Parameter(Mandatory)][string]$SharedWorkflowRef,
        [Parameter()][switch]$SkipDeployWorkflow
    )

    if (-not (Test-Path -LiteralPath $SourceRoot)) {
        throw "Source folder not found: $SourceRoot"
    }

    Write-Section `
        -Message "Syncing workflow files into repository"
    Write-Host "Source: $SourceRoot" -ForegroundColor DarkGray
    Write-Host "Target: $TargetRoot" -ForegroundColor DarkGray

    $allSourceFiles = Get-ChildItem -LiteralPath $SourceRoot -Recurse -Force | Where-Object { -not $_.PSIsContainer }

    foreach ($file in $allSourceFiles) {
        $relativePath = $file.FullName.Substring($SourceRoot.Length).TrimStart('\', '/')
        $normalizedRelativePath = $relativePath -replace '\\','/'
        $destPath     = Join-Path $TargetRoot $relativePath

        if ($normalizedRelativePath -eq 'alm-config.psd1' -and (Test-Path -LiteralPath $destPath)) {
            if (Test-Path -LiteralPath "$destPath.template") {
                Remove-Item -LiteralPath "$destPath.template" -Force
            }

            Write-Host 'Preserving existing alm-config.psd1 so current solution defaults and extended config can be merged later.' -ForegroundColor DarkGray
            continue
        }

        $destDir = Split-Path -Parent $destPath
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }

        $sourceFileToUse = $file.FullName
        $isTempFile      = $false

        # Patch all shared workflow references (build/export/import/deploy/etc.) to the selected repository/ref.
        # BUILD.yml repository_dispatch branch/SHA resolution is template-driven and is copied verbatim.
        if ($normalizedRelativePath -like '.github/workflows/*.yml') {
            $content = Get-Content -LiteralPath $sourceFileToUse -Raw
            $updatedContent = [Regex]::Replace(
                $content,
                'ALM4Dataverse/ALM4Dataverse/\.github/workflows/([A-Za-z0-9._-]+)@[A-Za-z0-9._/\-]+',
                {
                    param($m)
                    return "$SharedWorkflowRepository/.github/workflows/$($m.Groups[1].Value)@$SharedWorkflowRef"
                }
            )

            if ($updatedContent -ne $content) {
                if ($isTempFile) {
                    Set-Content -LiteralPath $sourceFileToUse -Value $updatedContent -NoNewline
                }
                else {
                    $tempFile = [System.IO.Path]::GetTempFileName()
                    Set-Content -LiteralPath $tempFile -Value $updatedContent -NoNewline
                    $sourceFileToUse = $tempFile
                    $isTempFile      = $true
                }
            }
        }

        # Rename DEPLOY-main.yml to match the branch, and patch branch references
        if ($normalizedRelativePath -eq '.github/workflows/DEPLOY-main.yml') {
            if ($SkipDeployWorkflow) {
                continue
            }

            $destPath = Join-Path $TargetRoot ".github/workflows/DEPLOY-$Branch.yml"
            
            $content = Get-Content -LiteralPath $sourceFileToUse -Raw
            $content = $content -replace "branches:\s*\[\s*main\s*\]", "branches: [ $Branch ]"
            $content = $content -replace 'workflow_name: ''BUILD''', "workflow_name: 'BUILD'"
            $content = $content -replace '\bTEST-main\b', 'TEST'

            if ($isTempFile) {
                Set-Content -LiteralPath $sourceFileToUse -Value $content -NoNewline
            }
            else {
                $tempFile = [System.IO.Path]::GetTempFileName()
                Set-Content -LiteralPath $tempFile -Value $content -NoNewline
                $sourceFileToUse = $tempFile
                $isTempFile      = $true
            }
        }

        try {
            if (Test-Path -LiteralPath $destPath) {
                $srcHash = Get-FileHash -LiteralPath $sourceFileToUse -Algorithm MD5
                $dstHash = Get-FileHash -LiteralPath $destPath        -Algorithm MD5

                if ($srcHash.Hash -ne $dstHash.Hash) {
                    Copy-Item -LiteralPath $sourceFileToUse -Destination $destPath -Force
                    if (Test-Path -LiteralPath "$destPath.template") {
                        Remove-Item -LiteralPath "$destPath.template" -Force
                    }
                }
                else {
                    if (Test-Path -LiteralPath "$destPath.template") {
                        Remove-Item -LiteralPath "$destPath.template" -Force
                    }
                }
            }
            else {
                Copy-Item -LiteralPath $sourceFileToUse -Destination $destPath -Force
            }
        }
        finally {
            if ($isTempFile -and (Test-Path -LiteralPath $sourceFileToUse)) {
                Remove-Item -LiteralPath $sourceFileToUse -Force
            }
        }
    }

    Write-Host "Workflow files synced." -ForegroundColor Green
}

function Update-AlmConfigInRepoClone {
    <#
    .SYNOPSIS
        Updates the alm-config.psd1 file in a local clone with the selected solutions.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][array]$Solutions,
        [Parameter(Mandatory)][bool]$BuildValidationEnabled,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $configPath = Join-Path $RepoRoot 'alm-config.psd1'
    $templatePath = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'copy-to-your-repo\alm-config.psd1' } else { $null }

    $effectiveSolutions = @()
    if ($null -ne $Solutions) {
        $effectiveSolutions = @($Solutions)
        [void](Set-AlmConfigSolutionsInFile -ConfigPath $configPath -Solutions $effectiveSolutions -CreateIfMissing -TemplatePath $templatePath)
    }
    else {
        Write-Host 'Skipping solution list updates in alm-config.psd1 because solution selection was not run.' -ForegroundColor Yellow
    }

    [void](Set-AlmConfigSolutionCheckEnabledInFile -ConfigPath $configPath -Enabled $BuildValidationEnabled -CreateIfMissing -TemplatePath $templatePath)
    Write-Host "Updated alm-config.psd1 with $($effectiveSolutions.Count) solution(s); solutionCheck.enabled=$BuildValidationEnabled."
}

function Update-BuildWorkflowInRepoClone {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$SharedWorkflowRepository,
        [Parameter(Mandatory)][string]$SharedWorkflowReference,
        [Parameter(Mandatory)][AllowEmptyString()][string]$BuildEnvironmentName,
        [Parameter(Mandatory)][bool]$BuildValidationEnabled
    )

    $buildWorkflowPath = Join-Path $RepoRoot '.github/workflows/BUILD.yml'
    if (-not (Test-Path -LiteralPath $buildWorkflowPath)) {
        throw "Build workflow file not found: $buildWorkflowPath"
    }

    $escapedBuildEnvironmentName = ([string]$BuildEnvironmentName).Replace("'", "''")

    $environmentInput = if ($BuildValidationEnabled -and -not [string]::IsNullOrWhiteSpace($BuildEnvironmentName)) {
        $escapedBuildEnvironmentName
    }
    else {
        ''
    }

        $newContent = @"
name: BUILD

# Triggers on every push to any branch.
# Also supports manual runs and repository_dispatch from EXPORT.
# Packs Dataverse solutions into deployable artifacts and tags the source commit.
#
# See docs/usage/building-releases.md and docs/setup/github-setup.md

run-name: `${{ format('{0}-{1}-{2}-{3}', github.event.repository.name, (github.event_name == 'repository_dispatch' && github.event.client_payload.branch) || github.ref_name, (github.event_name == 'repository_dispatch' && github.event.client_payload.exported_at) || github.event.head_commit.timestamp || github.event.repository.updated_at || github.run_id, github.run_number) }}

on:
    push:
        branches:
            - '**'
    workflow_dispatch:
    repository_dispatch:
        types:
            - alm4dataverse-export-build

jobs:
    build:
        uses: $SharedWorkflowRepository/.github/workflows/build.yml@$SharedWorkflowReference
        with:
            build-name: `${{ format('{0}-{1}-{2}-{3}', github.event.repository.name, (github.event_name == 'repository_dispatch' && github.event.client_payload.branch) || github.ref_name, (github.event_name == 'repository_dispatch' && github.event.client_payload.exported_at) || github.event.head_commit.timestamp || github.event.repository.updated_at || github.run_id, github.run_number) }}
            source-branch: `${{ (github.event_name == 'repository_dispatch' && github.event.client_payload.branch) || github.ref_name }}
            source-ref: `${{ (github.event_name == 'repository_dispatch' && github.event.client_payload.sha) || github.sha }}
            environment-name: '$environmentInput'
            timeout-minutes: 360
        permissions:
            contents: write
            actions: write
            id-token: write
"@

    Set-Content -LiteralPath $buildWorkflowPath -Value $newContent.TrimStart("`r", "`n") -NoNewline
}

function Update-DeployWorkflowInRepoClone {
    <#
    .SYNOPSIS
        Rebuilds DEPLOY-{branch}.yml using selected deployment environments.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][array]$DeploymentEnvironments,
        [Parameter(Mandatory)][string]$SharedWorkflowRepository,
        [Parameter(Mandatory)][string]$SharedWorkflowRef,
        [Parameter()][ValidateSet('manual-gate-tag','environment-approval')][string]$PromotionMode = 'manual-gate-tag'
    )

    $deployFilePath = Join-Path $RepoRoot ".github/workflows/DEPLOY-$Branch.yml"

    $deployDirectory = Split-Path -Parent $deployFilePath
    if (-not (Test-Path -LiteralPath $deployDirectory)) {
        New-Item -ItemType Directory -Path $deployDirectory -Force | Out-Null
    }

    if (-not $DeploymentEnvironments -or $DeploymentEnvironments.Count -eq 0) {
        if (Test-Path -LiteralPath $deployFilePath) {
            Remove-Item -LiteralPath $deployFilePath -Force
            Write-Host "Removed DEPLOY workflow '$deployFilePath' because branch '$Branch' has no deployment environments configured." -ForegroundColor Yellow
        }
        else {
            Write-Host "No deployment environments selected for branch '$Branch'; no DEPLOY workflow file will be created." -ForegroundColor Yellow
        }

        return
    }

    $usesRef = "$SharedWorkflowRepository/.github/workflows/deploy.yml@$SharedWorkflowRef"

    $lines = New-Object System.Collections.Generic.List[string]

    $lines.Add("name: DEPLOY-$Branch")
    if ($PromotionMode -eq 'environment-approval') {
        $lines.Add('run-name: ${{ github.event_name == ''workflow_dispatch'' && format(''Deploy {0} <- {1}'', github.event.inputs[''target-environment''] || ''auto'', github.event.inputs[''build-run-name''] || format(''latest from {0}'', github.ref_name)) || format(''Deploy auto <- run {0}'', github.run_id) }}')
    }
    else {
        $lines.Add('run-name: ${{ github.event_name == ''workflow_dispatch'' && format(''Deploy {0} <- {1}'', github.event.inputs[''target-environment''], github.event.inputs[''build-run-name''] || format(''latest from {0}'', github.ref_name)) || format(''Deploy auto <- run {0}'', github.run_id) }}')
    }
    $lines.Add("")
    $lines.Add('# Stage-per-environment deployment workflow (generated by setup-github.ps1).')
    $lines.Add('#')
    $lines.Add('# To add another environment later:')
    $lines.Add('#   1. Add it to workflow_dispatch target-environment options.')
    $lines.Add('#   2. Add a deploy-* job and chain needs to the previous stage.')
    $lines.Add('#   3. Set previous-environment-name to the previous stage short name.')
    $lines.Add('#   4. In environment-approval mode, keep the repository_dispatch trigger enabled.')
    $lines.Add('')
    $lines.Add('permissions:')
    $lines.Add('  actions: read')
    $lines.Add('  contents: write')
    $lines.Add('  id-token: write')
    $lines.Add('')
    $lines.Add('on:')
    if ($PromotionMode -eq 'environment-approval') {
        $dispatchBranchToken = ($Branch.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
        if ([string]::IsNullOrWhiteSpace($dispatchBranchToken)) {
            throw "Could not derive repository_dispatch event type token from branch '$Branch'."
        }

        $lines.Add('  repository_dispatch:')
        $lines.Add("    types: ['alm4dataverse-build-deploy-$dispatchBranchToken']")
    }
    $lines.Add('  workflow_dispatch:')
    $lines.Add('    inputs:')
    $lines.Add('      build-run-name:')
    $lines.Add("        description: 'Optional exact BUILD name to deploy. Leave blank to use the latest successful BUILD from this branch. Numeric run IDs also work.'")
    $lines.Add('        required: false')
    $lines.Add('        type: string')
    $lines.Add('      target-environment:')
    if ($PromotionMode -eq 'environment-approval') {
        $validEnvironmentList = ($DeploymentEnvironments | ForEach-Object { $_.ShortName }) -join ', '
        $validEnvironmentListEscaped = $validEnvironmentList.Replace("'", "''")
        $lines.Add("        description: 'Optional target environment. Leave blank to start from the first configured stage. Valid values: $validEnvironmentListEscaped.'")
        $lines.Add('        required: false')
        $lines.Add('        type: string')
    }
    else {
        $lines.Add("        description: 'Target environment to deploy to'")
        $lines.Add('        required: true')
        $lines.Add('        type: choice')
        $lines.Add('        options:')

        foreach ($env in $DeploymentEnvironments) {
            $envNameEscaped = ([string]$env.ShortName).Replace("'", "''")
            $lines.Add("          - '$envNameEscaped'")
        }
    }

    $lines.Add('')
    $lines.Add('jobs:')

    $previousJobId = $null
    $previousEnvName = ''
    $jobIdSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    for ($i = 0; $i -lt $DeploymentEnvironments.Count; $i++) {
        $envName = [string]$DeploymentEnvironments[$i].ShortName
        $envNameEscaped = $envName.Replace("'", "''")

        $baseJobId = ('deploy-' + (($envName.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')))
        if ([string]::IsNullOrWhiteSpace($baseJobId) -or $baseJobId -eq 'deploy-') {
            $baseJobId = "deploy-stage-$($i + 1)"
        }

        $jobId = $baseJobId
        $suffix = 2
        while ($jobIdSet.Contains($jobId)) {
            $jobId = "$baseJobId-$suffix"
            $suffix++
        }
        [void]$jobIdSet.Add($jobId)

        $lines.Add("  ${jobId}:")
        if ($i -eq 0) {
            $lines.Add('    # First stage in the chain.')
            if ($PromotionMode -eq 'manual-gate-tag') {
                $lines.Add('    # Manual-gate-tag mode requires an explicit workflow_dispatch, even for stage 1.')
            }
        }
        else {
            $lines.Add("    needs: $previousJobId")
            $lines.Add('    # Allow manual targeted deploys even when earlier jobs are skipped in this run,')
            $lines.Add('    # but do not bypass failed prerequisite stages on automatic runs.')
            if ($PromotionMode -eq 'environment-approval') {
                $lines.Add('    if: >-')
                $lines.Add('      (')
                $lines.Add("        github.event_name == 'workflow_dispatch' &&")
                $lines.Add(("        inputs.target-environment == '{0}'" -f $envNameEscaped))
                $lines.Add('      ) || (')
                $lines.Add(("        (github.event_name != 'workflow_dispatch' || inputs.target-environment == '') && needs['{0}'].result == 'success'" -f $previousJobId))
                $lines.Add('      )')
            }
            else {
                $lines.Add(('    if: ${{{{ github.event_name == ''workflow_dispatch'' || needs[''{0}''].result == ''success'' }}}}' -f $previousJobId))
            }
        }

        $lines.Add("    uses: $usesRef")
        $lines.Add('    permissions:')
        $lines.Add('      actions: read')
        $lines.Add('      contents: write')
        $lines.Add('      id-token: write')
        $lines.Add('    with:')
        $lines.Add("      environment-name: '$envNameEscaped'")
        if ($i -eq 0) {
            $lines.Add("      previous-environment-name: ''")
        }
        else {
            $prevEscaped = $previousEnvName.Replace("'", "''")
            $lines.Add("      previous-environment-name: '$prevEscaped'")
        }
        $lines.Add("      promotion-mode: $PromotionMode")
        $lines.Add("      trigger-branch: '$Branch'")
        $lines.Add('      github-context-json: ${{ toJSON(github) }}')
        $lines.Add('      caller-inputs-json: ${{ toJSON(inputs) }}')
        $lines.Add('      timeout-minutes: 360')
        $lines.Add('    secrets: inherit')
        $lines.Add('')

        $previousJobId = $jobId
        $previousEnvName = $envName
    }

    $output = ($lines -join [Environment]::NewLine).TrimEnd() + [Environment]::NewLine
    Set-Content -LiteralPath $deployFilePath -Value $output -NoNewline

    $envList = ($DeploymentEnvironments | ForEach-Object { $_.ShortName }) -join ', '
    Write-Host "Updated DEPLOY workflow '$deployFilePath' with environments: $envList (promotion mode: $PromotionMode)" -ForegroundColor Green
}

function Publish-GitHubRepoChanges {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][object]$PublishPlan
    )

    Push-Location $RepoRoot
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & git add -A
        if ($LASTEXITCODE -ne 0) { throw 'Git add failed.' }

        & git diff --cached --quiet
        $hasChanges = ($LASTEXITCODE -ne 0)

        if (-not $hasChanges) {
            Write-Host "No content changes detected, but ensuring branch '$($PublishPlan.BranchName)' exists on origin..." -ForegroundColor Yellow
            & git push -u origin $PublishPlan.BranchName 2>&1
            if ($LASTEXITCODE -ne 0) { throw 'Git push failed.' }

            Write-Host 'No changes to commit; repository already contains the required files.' -ForegroundColor Green
            return [pscustomobject]@{
                HasChanges     = $false
                BranchName     = $PublishPlan.BranchName
                TargetBranch   = $PublishPlan.TargetBranch
                PullRequestUrl = $null
                Mode           = $PublishPlan.Mode
            }
        }

        & git config user.name 'ALM4Dataverse Setup'
        & git config user.email 'setup@alm4dataverse.local'
        & git commit -m $PublishPlan.CommitMessage 2>&1
        if ($LASTEXITCODE -ne 0) { throw 'Git commit failed.' }

        Write-Host "Pushing to origin/$($PublishPlan.BranchName)..." -ForegroundColor Yellow
        & git push -u origin $PublishPlan.BranchName 2>&1
        if ($LASTEXITCODE -ne 0) { throw 'Git push failed.' }

        $pullRequestUrl = $null
        if ($PublishPlan.Mode -eq 'PullRequest') {
            $existingPrOutput = (& gh pr list --head $PublishPlan.BranchName --base $PublishPlan.TargetBranch --state open --json number,url 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -ne 0) {
                throw 'Failed to query existing pull requests.'
            }

            $existingPullRequests = @()
            if (-not [string]::IsNullOrWhiteSpace($existingPrOutput)) {
                $existingPullRequests = @($existingPrOutput | ConvertFrom-Json)
            }

            $existingPullRequest = $existingPullRequests | Select-Object -First 1
            if ($existingPullRequest) {
                Write-Host "Updating existing pull request #$($existingPullRequest.number)..." -ForegroundColor Yellow
                & gh pr edit $existingPullRequest.number --title $PublishPlan.PullRequestTitle --body $PublishPlan.PullRequestDescription 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw 'Failed to update the pull request.'
                }
                $pullRequestUrl = $existingPullRequest.url
            }
            else {
                Write-Host "Creating pull request into '$($PublishPlan.TargetBranch)'..." -ForegroundColor Yellow
                $pullRequestUrl = (& gh pr create --title $PublishPlan.PullRequestTitle --body $PublishPlan.PullRequestDescription --base $PublishPlan.TargetBranch --head $PublishPlan.BranchName 2>&1 | Out-String).Trim()
                if ($LASTEXITCODE -ne 0) {
                    throw 'Failed to create the pull request.'
                }
            }
        }

        Write-Host 'Repository updated successfully.' -ForegroundColor Green
        return [pscustomobject]@{
            HasChanges     = $true
            BranchName     = $PublishPlan.BranchName
            TargetBranch   = $PublishPlan.TargetBranch
            PullRequestUrl = $pullRequestUrl
            Mode           = $PublishPlan.Mode
        }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        Pop-Location
    }
}

function Publish-GitHubBranchSetupChanges {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ConfiguredBranch,
        [Parameter(Mandatory)][object]$PublishPlan,
        [Parameter(Mandatory)][string]$DefaultBranch,
        [Parameter(Mandatory)][string]$CopyRoot,
        [Parameter(Mandatory)][string]$SharedWorkflowRepository,
        [Parameter(Mandatory)][string]$SharedWorkflowReference,
        [Parameter(Mandatory)][string]$PromotionMode,
        [Parameter()][AllowNull()][array]$Solutions,
        [Parameter()][array]$DeploymentEnvironments,
        [Parameter()][array]$DeployWorkflowBranchDefinitions,
        [Parameter()][bool]$BuildValidationEnabled = $false,
        [Parameter()][AllowEmptyString()][string]$BuildValidationEnvironmentName = '',
        [Parameter()][switch]$SkipDeployWorkflow
    )

    Push-Location $RepoRoot
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & git fetch origin '+refs/heads/*:refs/remotes/origin/*' --prune 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'Failed to refresh remote branches before publishing.'
        }

        & git reset --hard HEAD 2>&1 | Out-Null
        & git clean -fd 2>&1 | Out-Null

        & git ls-remote --exit-code --heads origin $ConfiguredBranch 2>&1 | Out-Null
        $targetBranchExistsOnOrigin = ($LASTEXITCODE -eq 0)

        & git ls-remote --exit-code --heads origin $DefaultBranch 2>&1 | Out-Null
        $defaultBranchExistsOnOrigin = ($LASTEXITCODE -eq 0)

        $seedRef = if ($targetBranchExistsOnOrigin) {
            "origin/$ConfiguredBranch"
        }
        elseif ($defaultBranchExistsOnOrigin) {
            "origin/$DefaultBranch"
        }
        else {
            $null
        }

        if ($PublishPlan.Mode -eq 'PullRequest' -and -not $targetBranchExistsOnOrigin) {
            Write-Host "Initializing target branch '$ConfiguredBranch' on origin before creating a pull request..." -ForegroundColor Yellow

            if ($seedRef) {
                & git checkout -B $ConfiguredBranch $seedRef 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to create local target branch '$ConfiguredBranch' from '$seedRef'."
                }
            }
            else {
                & git checkout --orphan $ConfiguredBranch 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to create orphan target branch '$ConfiguredBranch'."
                }
            }

            & git config user.name 'ALM4Dataverse Setup' 2>$null
            & git config user.email 'setup@alm4dataverse.local' 2>$null

            & git rev-parse --verify HEAD 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                & git commit --allow-empty -m "Initialize repository branch '$ConfiguredBranch' for ALM4Dataverse setup" 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to create initial commit for branch '$ConfiguredBranch'."
                }
            }

            & git push -u origin $ConfiguredBranch 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to push target branch '$ConfiguredBranch' to origin."
            }

            $targetBranchExistsOnOrigin = $true
            $seedRef = $ConfiguredBranch
        }

        if ($PublishPlan.Mode -eq 'PullRequest') {
            $workingBaseRef = if ($targetBranchExistsOnOrigin) { "origin/$ConfiguredBranch" } elseif ($seedRef) { $seedRef } else { 'HEAD' }
            & git checkout -B $PublishPlan.BranchName $workingBaseRef 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to create or switch to working branch '$($PublishPlan.BranchName)'."
            }
        }
        else {
            $directBaseRef = if ($targetBranchExistsOnOrigin) { "origin/$ConfiguredBranch" } elseif ($seedRef) { $seedRef } else { 'HEAD' }
            & git checkout -B $ConfiguredBranch $directBaseRef 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to create or switch to target branch '$ConfiguredBranch'."
            }
        }

        Copy-WorkflowTemplatesToRepo `
            -SourceRoot $CopyRoot `
            -TargetRoot $RepoRoot `
            -Branch $ConfiguredBranch `
            -SharedWorkflowRepository $SharedWorkflowRepository `
            -SharedWorkflowRef $SharedWorkflowReference `
            -SkipDeployWorkflow:$SkipDeployWorkflow

        Update-AlmConfigInRepoClone -Solutions $Solutions -BuildValidationEnabled $BuildValidationEnabled -RepoRoot $RepoRoot

        $buildEnvironmentName = if ($BuildValidationEnabled) { [string]$BuildValidationEnvironmentName } else { '' }
        Update-BuildWorkflowInRepoClone `
            -RepoRoot $RepoRoot `
            -SharedWorkflowRepository $SharedWorkflowRepository `
            -SharedWorkflowReference $SharedWorkflowReference `
            -BuildEnvironmentName:$buildEnvironmentName `
            -BuildValidationEnabled $BuildValidationEnabled

        if (-not $SkipDeployWorkflow) {
            $effectiveDeployWorkflowDefinitions = @()
            if ($DeployWorkflowBranchDefinitions -and @($DeployWorkflowBranchDefinitions).Count -gt 0) {
                $effectiveDeployWorkflowDefinitions = @($DeployWorkflowBranchDefinitions)
            }
            else {
                $effectiveDeployWorkflowDefinitions = @(
                    [pscustomobject]@{
                        BranchName             = $ConfiguredBranch
                        DeploymentEnvironments = @($DeploymentEnvironments)
                    }
                )
            }

            foreach ($deployDefinition in @($effectiveDeployWorkflowDefinitions)) {
                $workflowBranchName = [string]$deployDefinition.BranchName
                $workflowDeploymentEnvironments = @($deployDefinition.DeploymentEnvironments)

                if ([string]::IsNullOrWhiteSpace($workflowBranchName)) {
                    continue
                }

                Update-DeployWorkflowInRepoClone `
                    -RepoRoot $RepoRoot `
                    -Branch $workflowBranchName `
                    -DeploymentEnvironments $workflowDeploymentEnvironments `
                    -SharedWorkflowRepository $SharedWorkflowRepository `
                    -SharedWorkflowRef $SharedWorkflowReference `
                    -PromotionMode $PromotionMode
            }
        }

        return Publish-GitHubRepoChanges -RepoRoot $RepoRoot -PublishPlan $PublishPlan
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        Pop-Location
    }
}

function Get-GitHubPublishSummaryText {
    [CmdletBinding()]
    param(
        [Parameter()][array]$PublishResults
    )

    $results = @($PublishResults | Where-Object { $null -ne $_ })
    if ($results.Count -eq 0) {
        return 'No repository changes were needed'
    }

    $changedResults = @($results | Where-Object { $_.HasChanges })
    if ($changedResults.Count -eq 0) {
        return 'No repository changes were needed'
    }

    $pullRequestResults = @($changedResults | Where-Object { $_.Mode -eq 'PullRequest' })
    $directResults = @($changedResults | Where-Object { $_.Mode -ne 'PullRequest' })

    $summaryParts = @()
    if ($directResults.Count -gt 0) {
        $summaryParts += "$($directResults.Count) direct branch update(s)"
    }
    if ($pullRequestResults.Count -gt 0) {
        $summaryParts += "$($pullRequestResults.Count) pull request branch update(s)"
    }

    return ($summaryParts -join ' - ')
}

function Invoke-GitHubBranchAwareSetup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CloneRoot,
        [Parameter(Mandatory)][string]$RepoOwner,
        [Parameter(Mandatory)][string]$RepoName,
        [Parameter(Mandatory)][string]$RepoFullName,
        [Parameter(Mandatory)][string]$DefaultBranch,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][object]$ExistingSetupState,
        [Parameter(Mandatory)][string]$SharedWorkflowRepository,
        [Parameter(Mandatory)][string]$SharedWorkflowReference,
        [Parameter(Mandatory)][string]$UpstreamGitSource,
        [Parameter(Mandatory)][string]$ALM4DataverseRef,
        [Parameter(Mandatory)][bool]$UseGitHubEnvironments,
        [Parameter(Mandatory)][bool]$EnableEnvironmentApprovals,
        [Parameter()][array]$EnvironmentApprovalReviewerIds = @(),
        [Parameter(Mandatory)][string]$DeploymentPromotionMode
    )

    $cachedCredentials = @()
    $cachedServiceAccounts = @()
    $publishResults = @()
    $solutionResult = $null
    $solutionSourceBranch = $null
    $copyRoot = $null
    $upstreamClone = $null

    $initialBranchMappings = @(Get-GitHubInitialBranchMappings -ExistingSetupState $ExistingSetupState -DefaultBranch $DefaultBranch)
    $branchStates = @()
    foreach ($mapping in $initialBranchMappings) {
        $branchName = [string]$mapping.BranchName
        $existingDevEnvironment = if ($branchName -ieq $DefaultBranch) {
            $ExistingSetupState.DevEnvironment
        }
        else {
            Get-GitHubExistingEnvironmentState -Owner $RepoOwner -Repo $RepoName -EnvironmentName "Dev-$branchName" -TenantId $TenantId
        }

        $branchStates += New-GitHubBranchSetupState -BranchName $branchName -ExistingDevEnvironment $existingDevEnvironment -DeploymentEnvironments @($mapping.Environments)
    }

    if ($PSScriptRoot) {
        $copyRoot = Join-Path $PSScriptRoot 'copy-to-your-repo'
    }

    if (-not $copyRoot -or -not (Test-Path -LiteralPath $copyRoot)) {
        $upstreamClone = Join-Path ([System.IO.Path]::GetTempPath()) ("ALM4Dataverse-Templates-" + [guid]::NewGuid().ToString('n'))
        New-DirectoryIfMissing -Path $upstreamClone

        Invoke-WithErrorHandling -OperationName 'Fetching workflow templates' -StatusMessage 'Fetching workflow templates from the selected ALM4Dataverse source...' -CaptureOutputInPanel -ScriptBlock {
            & git clone --depth 1 --branch $ALM4DataverseRef $UpstreamGitSource $upstreamClone 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw 'Failed to clone ALM4Dataverse templates.'
            }
        } | Out-Null

        $copyRoot = Join-Path $upstreamClone 'copy-to-your-repo'
    }

    try {
        $wizardState = [pscustomobject]@{
            BranchStates        = @($branchStates)
            SolutionResult      = $null
            SolutionSourceBranch = $null
            BranchEnvironmentMappingCompleted = $false
            BuildValidationEnabled = [bool](Get-OptionalObjectPropertyValue -InputObject $ExistingSetupState -PropertyName 'BuildValidationEnabled')
            BuildValidationEnvironmentName = [string](Get-OptionalObjectPropertyValue -InputObject $ExistingSetupState -PropertyName 'BuildValidationEnvironmentName')
            BuildValidationEnvironmentConfiguration = (Get-OptionalObjectPropertyValue -InputObject $ExistingSetupState -PropertyName 'ExistingBuildValidationEnvironment')
        }

        Invoke-SetupWizard -Title 'GitHub Actions ALM4Dataverse setup' -Steps @(
            [pscustomobject]@{
                Name = 'Configure branches'
                Action = {
                    $currentBranchMappings = @($wizardState.BranchStates | ForEach-Object {
                        [pscustomobject]@{
                            BranchName                  = [string]$_.BranchName
                            DevEnvironmentConfiguration = $_.DevEnvironmentConfiguration
                            ExistingDevEnvironment      = $_.ExistingDevEnvironment
                            Environments                = @($_.DeploymentEnvironments)
                        }
                    })

                    $selectedBranchMappings = @(Invoke-WithErrorHandling -OperationName 'Selecting deployment branches' -ScriptBlock {
                        Select-BranchEnvironmentMappings `
                            -InitialBranchMappings $currentBranchMappings `
                            -Title 'Manage deployment branches' `
                            -GuidanceLines @(
                                'Start by choosing the Git branches that should receive ALM4Dataverse workflow setup.',
                                'You can add long-lived release branches as well as mainline branches, and you can come back later to change the list.'
                            ) `
                            -DocRelativePath 'docs/setup/github-setup.md' `
                            -Ref $ALM4DataverseRef `
                            -EditDevEnvironmentScriptBlock {
                                param($allMappings, $mappingToEdit)

                                $branchName = [string]$mappingToEdit.BranchName
                                $existingDevEnvironment = $mappingToEdit.ExistingDevEnvironment
                                $currentDevConfiguration = $mappingToEdit.DevEnvironmentConfiguration

                                if ($UseGitHubEnvironments) {
                                    Write-Host "Preparing GitHub environment 'Dev-$branchName' for the DEV Dataverse environment." -ForegroundColor Green
                                }
                                else {
                                    Write-Host "Preparing prefixed repo-level credentials for DEV environment 'Dev-$branchName'." -ForegroundColor Green
                                }
                                Write-Host ''

                                $existingDevEnvironmentSummary = if ($currentDevConfiguration) {
                                    Get-GitHubExistingEnvironmentSelectionSummary -ExistingEnvironment $currentDevConfiguration
                                }
                                else {
                                    Get-GitHubExistingEnvironmentSelectionSummary -ExistingEnvironment $existingDevEnvironment
                                }

                                $preferredDevEnvironmentUrl = if ($currentDevConfiguration) {
                                    $currentDevConfiguration.Url
                                }
                                elseif ($existingDevEnvironment) {
                                    $existingDevEnvironment.Url
                                }
                                else {
                                    $null
                                }

                                $hasExistingDevConfiguration = ($currentDevConfiguration -or $existingDevEnvironment)
                                if ($hasExistingDevConfiguration) {
                                    $shouldConfigureDevEnvironment = Read-YesNo -Prompt "Configure a DEV Dataverse environment for branch '$branchName'?"
                                }
                                else {
                                    $shouldConfigureDevEnvironment = Read-YesNo -Prompt "Configure a DEV Dataverse environment for branch '$branchName'?" -DefaultNo
                                }

                                if (-not $shouldConfigureDevEnvironment) {
                                    return $null
                                }

                                $devEnvSelection = Select-DataverseEnvironment -Prompt "Select the DEV Dataverse environment for branch '$branchName'" -PreferredUrl $preferredDevEnvironmentUrl -PreferredSelectionSummary $existingDevEnvironmentSummary
                                if (-not $devEnvSelection) {
                                    return $currentDevConfiguration
                                }

                                $devEnvUrl = ConvertTo-NormalizedEnvironmentUrl -Url $devEnvSelection.Endpoints['WebApplication']
                                $devEnvFriendlyName = $devEnvSelection.FriendlyName
                                $reuseExistingDevEnvironmentConfiguration = (
                                    ($devEnvSelection.PSObject.Properties.Name -contains 'UseExistingConfiguration' -and $devEnvSelection.UseExistingConfiguration) -or
                                    (
                                        -not [string]::IsNullOrWhiteSpace($preferredDevEnvironmentUrl) -and
                                        $devEnvUrl -ieq (ConvertTo-NormalizedEnvironmentUrl -Url $preferredDevEnvironmentUrl)
                                    )
                                )

                                $existingDevCredential = $null
                                $existingDevServiceAccount = $null
                                if ($reuseExistingDevEnvironmentConfiguration -and $existingDevEnvironment) {
                                    $existingDevCredential = $existingDevEnvironment.Credentials
                                    $existingDevServiceAccount = $existingDevEnvironment.ServiceAccountUPN
                                }
                                elseif ($currentDevConfiguration) {
                                    $existingDevCredential = $currentDevConfiguration.Credentials
                                    $existingDevServiceAccount = $currentDevConfiguration.ServiceAccountUPN
                                }

                                $canReuseExistingDevConfiguration = (
                                    $reuseExistingDevEnvironmentConfiguration -and
                                    $existingDevEnvironment -and
                                    $existingDevEnvironment.Credentials -and
                                    -not [string]::IsNullOrWhiteSpace($existingDevEnvironment.ServiceAccountUPN)
                                )

                                if ($canReuseExistingDevConfiguration) {
                                    $updatedDevConfiguration = [pscustomobject]@{
                                        ShortName         = "Dev-$branchName"
                                        FriendlyName      = $(if ([string]::IsNullOrWhiteSpace($devEnvFriendlyName)) { "Dev-$branchName" } else { $devEnvFriendlyName })
                                        Url               = $devEnvUrl
                                        Credentials       = $existingDevEnvironment.Credentials
                                        ServiceAccountUPN = $existingDevEnvironment.ServiceAccountUPN
                                    }
                                }
                                else {
                                    $updatedDevConfiguration = Get-GitHubEnvironmentConfiguration `
                                        -EnvironmentName "Dev-$branchName" `
                                        -EnvironmentUrl $devEnvUrl `
                                        -FriendlyName $devEnvFriendlyName `
                                        -ExistingCredentials $cachedCredentials `
                                        -ExistingServiceAccounts $cachedServiceAccounts `
                                        -TenantId $TenantId `
                                        -RepoName $RepoName `
                                        -ExistingCredential $existingDevCredential `
                                        -ExistingServiceAccountUPN $existingDevServiceAccount
                                }

                                if ($updatedDevConfiguration -and -not ($cachedCredentials | Where-Object { $_.ApplicationId -eq $updatedDevConfiguration.Credentials.ApplicationId -and $_.TenantId -eq $updatedDevConfiguration.Credentials.TenantId })) {
                                    $cachedCredentials += $updatedDevConfiguration.Credentials
                                }
                                if ($updatedDevConfiguration -and $cachedServiceAccounts -notcontains $updatedDevConfiguration.ServiceAccountUPN) {
                                    $cachedServiceAccounts += $updatedDevConfiguration.ServiceAccountUPN
                                }

                                return $updatedDevConfiguration
                            } `
                            -EditDeploymentEnvironmentsScriptBlock {
                                param($allMappings, $mappingToEdit)

                                $branchName = [string]$mappingToEdit.BranchName
                                $excludedDevUrl = if ($mappingToEdit.DevEnvironmentConfiguration) { $mappingToEdit.DevEnvironmentConfiguration.Url } else { $null }
                                $selectedDeploymentEnvironments = @(Select-ConfiguredDeploymentEnvironments `
                                    -InitialEnvironments @($mappingToEdit.Environments) `
                                    -Heading "Target deployment environments for branch '$branchName'" `
                                    -Title "Manage deployment environments for branch '$branchName'" `
                                    -GuidanceLines @(
                                        "Select the Dataverse targets branch '$branchName' should promote through.",
                                        'Order defines promotion flow: first environment is the first stage, and each later stage depends on the previous one.'
                                    ) `
                                    -DocRelativePath 'docs/setup/github-setup.md' `
                                    -Ref $ALM4DataverseRef `
                                    -AddEnvironmentScriptBlock {
                                        param($currentSelections)

                                        $selectedEnv = Select-DataverseEnvironment -Prompt "Select a Dataverse environment for branch '$branchName'" -ExcludeUrl $excludedDevUrl
                                        if (-not $selectedEnv) {
                                            return $null
                                        }

                                        $url = ConvertTo-NormalizedEnvironmentUrl -Url $selectedEnv.Endpoints['WebApplication']
                                        if ($currentSelections | Where-Object { $_.Url -ieq $url }) {
                                            Write-Host 'An environment with that URL is already selected for this branch.' -ForegroundColor Red
                                            return $null
                                        }

                                        Write-Host 'Use a short deployment environment name (for example: TEST, UAT, PROD).' -ForegroundColor DarkGray
                                        $shortName = Read-TextWithDefault -Prompt 'Enter a short name for this environment' -DefaultValue ''
                                        if ($currentSelections | Where-Object { $_.ShortName -ieq $shortName }) {
                                            Write-Host 'An environment with that short name is already selected for this branch.' -ForegroundColor Red
                                            return $null
                                        }

                                        $environmentConfiguration = Get-GitHubEnvironmentConfiguration `
                                            -EnvironmentName $shortName `
                                            -EnvironmentUrl $url `
                                            -FriendlyName $selectedEnv.FriendlyName `
                                            -ExistingCredentials $cachedCredentials `
                                            -ExistingServiceAccounts $cachedServiceAccounts `
                                            -TenantId $TenantId `
                                            -RepoName $RepoName

                                        if (-not ($cachedCredentials | Where-Object { $_.ApplicationId -eq $environmentConfiguration.Credentials.ApplicationId -and $_.TenantId -eq $environmentConfiguration.Credentials.TenantId })) {
                                            $cachedCredentials += $environmentConfiguration.Credentials
                                        }
                                        if ($cachedServiceAccounts -notcontains $environmentConfiguration.ServiceAccountUPN) {
                                            $cachedServiceAccounts += $environmentConfiguration.ServiceAccountUPN
                                        }

                                        return [pscustomobject]@{
                                            ShortName            = $environmentConfiguration.ShortName
                                            FriendlyName         = $environmentConfiguration.FriendlyName
                                            Url                  = $environmentConfiguration.Url
                                            Credentials          = $environmentConfiguration.Credentials
                                            ServiceAccountUPN    = $environmentConfiguration.ServiceAccountUPN
                                            ConfigurationPending = $false
                                        }
                                    } `
                                    -EditEnvironmentScriptBlock {
                                        param($currentSelections, $environmentToEdit, $environmentIndex)

                                        $otherSelections = @()
                                        for ($selectionIndex = 0; $selectionIndex -lt $currentSelections.Count; $selectionIndex++) {
                                            if ($selectionIndex -ne $environmentIndex) {
                                                $otherSelections += $currentSelections[$selectionIndex]
                                            }
                                        }

                                        $currentUrl = ConvertTo-NormalizedEnvironmentUrl -Url $environmentToEdit.Url
                                        $selectedEnv = Select-DataverseEnvironment -Prompt "Select the Dataverse environment for '$($environmentToEdit.ShortName)' in branch '$branchName'" -ExcludeUrl $excludedDevUrl -PreferredUrl $currentUrl
                                        if (-not $selectedEnv) {
                                            return $null
                                        }

                                        $url = ConvertTo-NormalizedEnvironmentUrl -Url $selectedEnv.Endpoints['WebApplication']
                                        if ($otherSelections | Where-Object { $_.Url -ieq $url }) {
                                            Write-Host 'An environment with that URL is already selected for this branch.' -ForegroundColor Red
                                            return $null
                                        }

                                        Write-Host 'Use a short deployment environment name (for example: TEST, UAT, PROD).' -ForegroundColor DarkGray
                                        $shortName = Read-TextWithDefault -Prompt 'Enter a short name for this environment' -DefaultValue $environmentToEdit.ShortName
                                        if ($otherSelections | Where-Object { $_.ShortName -ieq $shortName }) {
                                            Write-Host 'An environment with that short name is already selected for this branch.' -ForegroundColor Red
                                            return $null
                                        }

                                        $currentCredentials = @($cachedCredentials)
                                        $currentCredentials += @($otherSelections | ForEach-Object { $_.Credentials } | Where-Object { $null -ne $_ })
                                        $currentServiceAccounts = @($cachedServiceAccounts)
                                        $currentServiceAccounts += @($otherSelections | ForEach-Object { $_.ServiceAccountUPN } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

                                        $environmentConfiguration = Get-GitHubEnvironmentConfiguration `
                                            -EnvironmentName $shortName `
                                            -EnvironmentUrl $url `
                                            -FriendlyName $selectedEnv.FriendlyName `
                                            -ExistingCredentials $currentCredentials `
                                            -ExistingServiceAccounts $currentServiceAccounts `
                                            -TenantId $TenantId `
                                            -RepoName $RepoName `
                                            -ExistingCredential $environmentToEdit.Credentials `
                                            -ExistingServiceAccountUPN $environmentToEdit.ServiceAccountUPN

                                        if (-not ($cachedCredentials | Where-Object { $_.ApplicationId -eq $environmentConfiguration.Credentials.ApplicationId -and $_.TenantId -eq $environmentConfiguration.Credentials.TenantId })) {
                                            $cachedCredentials += $environmentConfiguration.Credentials
                                        }
                                        if ($cachedServiceAccounts -notcontains $environmentConfiguration.ServiceAccountUPN) {
                                            $cachedServiceAccounts += $environmentConfiguration.ServiceAccountUPN
                                        }

                                        return [pscustomobject]@{
                                            ShortName            = $environmentConfiguration.ShortName
                                            FriendlyName         = $environmentConfiguration.FriendlyName
                                            Url                  = $environmentConfiguration.Url
                                            Credentials          = $environmentConfiguration.Credentials
                                            ServiceAccountUPN    = $environmentConfiguration.ServiceAccountUPN
                                            ConfigurationPending = $false
                                        }
                                    })

                                return @($selectedDeploymentEnvironments)
                            }
                    })

                    $existingStateByBranch = @{}
                    foreach ($branchState in @($wizardState.BranchStates)) {
                        $existingStateByBranch[$branchState.BranchName.ToLowerInvariant()] = $branchState
                    }

                    $updatedBranchStates = @()
                    foreach ($selectedBranchMapping in $selectedBranchMappings) {
                        $branchName = [string]$selectedBranchMapping.BranchName
                        $branchKey = $branchName.ToLowerInvariant()
                        if ($existingStateByBranch.ContainsKey($branchKey)) {
                            $existingBranchState = $existingStateByBranch[$branchKey]
                            $existingBranchState.DevEnvironmentConfiguration = $selectedBranchMapping.DevEnvironmentConfiguration
                            $existingBranchState.DeploymentEnvironments = @($selectedBranchMapping.Environments)
                            $updatedBranchStates += $existingBranchState
                            continue
                        }

                        $existingDevEnvironment = if ($branchName -ieq $DefaultBranch) {
                            $ExistingSetupState.DevEnvironment
                        }
                        else {
                            Get-GitHubExistingEnvironmentState -Owner $RepoOwner -Repo $RepoName -EnvironmentName "Dev-$branchName" -TenantId $TenantId
                        }

                        $newBranchState = New-GitHubBranchSetupState -BranchName $branchName -ExistingDevEnvironment $existingDevEnvironment -DeploymentEnvironments @()
                        $newBranchState.DevEnvironmentConfiguration = $selectedBranchMapping.DevEnvironmentConfiguration
                        $newBranchState.DeploymentEnvironments = @($selectedBranchMapping.Environments)
                        $updatedBranchStates += $newBranchState
                    }

                    foreach ($branchState in @($updatedBranchStates)) {
                        $branchState.PublishPlan = Get-BranchTargetedRepoChangePublishPlan `
                            -ProviderName 'GitHub' `
                            -RepositoryName $RepoFullName `
                            -TargetBranch $branchState.BranchName `
                            -DefaultCommitMessage "Add ALM4Dataverse GitHub Actions workflows for branch '$($branchState.BranchName)'" `
                            -DefaultPullRequestTitle "Add ALM4Dataverse GitHub Actions workflows for branch '$($branchState.BranchName)'" `
                            -DefaultPullRequestDescription "This pull request adds or updates the ALM4Dataverse GitHub Actions workflow and repository configuration for branch '$($branchState.BranchName)'." `
                            -GuidanceLines @(
                                "Choose how the generated files for branch '$($branchState.BranchName)' should be published.",
                                'Use pull-request mode when reviews or branch protection must happen before the branch becomes active.'
                            ) `
                            -DocRelativePath 'docs/setup/github-setup.md' `
                            -Ref $ALM4DataverseRef
                    }

                    $wizardState.BranchStates = @($updatedBranchStates | Sort-Object BranchName)

                    $branchMappingsForValidation = @($wizardState.BranchStates | ForEach-Object {
                        [pscustomobject]@{
                            BranchName   = [string]$_.BranchName
                            Environments = @($_.DeploymentEnvironments)
                        }
                    })
                    if (Test-BranchEnvironmentMappingsHaveDuplicates -BranchMappings $branchMappingsForValidation) {
                        throw 'Each deployment environment can only be assigned to one branch. Resolve duplicate environment assignments before continuing.'
                    }

                    $branchesWithNoEnvironments = @($selectedBranchMappings | Where-Object {
                        ($null -eq $_.DevEnvironmentConfiguration) -and (@($_.Environments).Count -eq 0)
                    } | ForEach-Object { $_.BranchName })
                    if ($branchesWithNoEnvironments.Count -gt 0) {
                        $branchList = ($branchesWithNoEnvironments -join ', ')
                        throw "Each configured branch must have at least one mapped environment (DEV or deployment). Remove unused branches or configure environments for: $branchList"
                    }

                    $wizardState.BranchStates = @($selectedBranchMappings | ForEach-Object {
                        $mappedBranch = $_
                        $existingBranchState = $updatedBranchStates | Where-Object { $_.BranchName -ieq $mappedBranch.BranchName } | Select-Object -First 1
                        if (-not $existingBranchState) {
                            $existingBranchState = New-GitHubBranchSetupState -BranchName ([string]$mappedBranch.BranchName) -ExistingDevEnvironment $null -DeploymentEnvironments @()
                        }

                        $existingBranchState.DevEnvironmentConfiguration = $mappedBranch.DevEnvironmentConfiguration
                        $existingBranchState.DeploymentEnvironments = @($mappedBranch.Environments)
                        $existingBranchState
                    })

                    $wizardState.BranchEnvironmentMappingCompleted = $true
                }
            },
            [pscustomobject]@{
                Name = 'Configure DEV environments'
                Action = {
                    if ($wizardState.BranchEnvironmentMappingCompleted) {
                        [Spectre.Console.AnsiConsole]::MarkupLine('[grey]DEV environments were already configured while defining branches.[/]')
                        return
                    }

                    foreach ($branchState in @($wizardState.BranchStates)) {
                        $branchName = [string]$branchState.BranchName
                        Write-Section `
                            -Message "Configure DEV environment for branch '$branchName'"

                        if ($UseGitHubEnvironments) {
                            Write-Host "Preparing GitHub environment 'Dev-$branchName' for the DEV Dataverse environment." -ForegroundColor Green
                        }
                        else {
                            Write-Host "Preparing prefixed repo-level credentials for DEV environment 'Dev-$branchName'." -ForegroundColor Green
                        }
                        Write-Host ''

                        $existingDevEnvironment = $branchState.ExistingDevEnvironment
                        $currentDevConfiguration = $branchState.DevEnvironmentConfiguration
                        $existingDevEnvironmentSummary = if ($currentDevConfiguration) {
                            Get-GitHubExistingEnvironmentSelectionSummary -ExistingEnvironment $currentDevConfiguration
                        }
                        else {
                            Get-GitHubExistingEnvironmentSelectionSummary -ExistingEnvironment $existingDevEnvironment
                        }

                        $preferredDevEnvironmentUrl = if ($currentDevConfiguration) {
                            $currentDevConfiguration.Url
                        }
                        elseif ($existingDevEnvironment) {
                            $existingDevEnvironment.Url
                        }
                        else {
                            $null
                        }

                        $hasExistingDevConfiguration = ($currentDevConfiguration -or $existingDevEnvironment)
                        if ($hasExistingDevConfiguration) {
                            $shouldConfigureDevEnvironment = Read-YesNo -Prompt "Configure a DEV Dataverse environment for branch '$branchName'?"
                        }
                        else {
                            $shouldConfigureDevEnvironment = Read-YesNo -Prompt "Configure a DEV Dataverse environment for branch '$branchName'?" -DefaultNo
                        }

                        if (-not $shouldConfigureDevEnvironment) {
                            $branchState.DevEnvironmentConfiguration = $null
                            continue
                        }

                        $devEnvSelection = Select-DataverseEnvironment -Prompt "Select the DEV Dataverse environment for branch '$branchName'" -PreferredUrl $preferredDevEnvironmentUrl -PreferredSelectionSummary $existingDevEnvironmentSummary
                        if (-not $devEnvSelection) {
                            $branchState.DevEnvironmentConfiguration = $null
                            continue
                        }

                        $devEnvUrl = ConvertTo-NormalizedEnvironmentUrl -Url $devEnvSelection.Endpoints['WebApplication']
                        $devEnvFriendlyName = $devEnvSelection.FriendlyName
                        $reuseExistingDevEnvironmentConfiguration = (
                            ($devEnvSelection.PSObject.Properties.Name -contains 'UseExistingConfiguration' -and $devEnvSelection.UseExistingConfiguration) -or
                            (
                                -not [string]::IsNullOrWhiteSpace($preferredDevEnvironmentUrl) -and
                                $devEnvUrl -ieq (ConvertTo-NormalizedEnvironmentUrl -Url $preferredDevEnvironmentUrl)
                            )
                        )

                        $existingDevCredential = $null
                        $existingDevServiceAccount = $null
                        if ($reuseExistingDevEnvironmentConfiguration -and $existingDevEnvironment) {
                            $existingDevCredential = $existingDevEnvironment.Credentials
                            $existingDevServiceAccount = $existingDevEnvironment.ServiceAccountUPN
                        }
                        elseif ($currentDevConfiguration) {
                            $existingDevCredential = $currentDevConfiguration.Credentials
                            $existingDevServiceAccount = $currentDevConfiguration.ServiceAccountUPN
                        }

                        $canReuseExistingDevConfiguration = (
                            $reuseExistingDevEnvironmentConfiguration -and
                            $existingDevEnvironment -and
                            $existingDevEnvironment.Credentials -and
                            -not [string]::IsNullOrWhiteSpace($existingDevEnvironment.ServiceAccountUPN)
                        )

                        if ($canReuseExistingDevConfiguration) {
                            $branchState.DevEnvironmentConfiguration = [pscustomobject]@{
                                ShortName         = "Dev-$branchName"
                                FriendlyName      = $(if ([string]::IsNullOrWhiteSpace($devEnvFriendlyName)) { "Dev-$branchName" } else { $devEnvFriendlyName })
                                Url               = $devEnvUrl
                                Credentials       = $existingDevEnvironment.Credentials
                                ServiceAccountUPN = $existingDevEnvironment.ServiceAccountUPN
                            }
                        }
                        else {
                            $branchState.DevEnvironmentConfiguration = Get-GitHubEnvironmentConfiguration `
                                -EnvironmentName "Dev-$branchName" `
                                -EnvironmentUrl $devEnvUrl `
                                -FriendlyName $devEnvFriendlyName `
                                -ExistingCredentials $cachedCredentials `
                                -ExistingServiceAccounts $cachedServiceAccounts `
                                -TenantId $TenantId `
                                -RepoName $RepoName `
                                -ExistingCredential $existingDevCredential `
                                -ExistingServiceAccountUPN $existingDevServiceAccount
                        }

                        if ($branchState.DevEnvironmentConfiguration -and -not ($cachedCredentials | Where-Object { $_.ApplicationId -eq $branchState.DevEnvironmentConfiguration.Credentials.ApplicationId -and $_.TenantId -eq $branchState.DevEnvironmentConfiguration.Credentials.TenantId })) {
                            $cachedCredentials += $branchState.DevEnvironmentConfiguration.Credentials
                        }
                        if ($branchState.DevEnvironmentConfiguration -and $cachedServiceAccounts -notcontains $branchState.DevEnvironmentConfiguration.ServiceAccountUPN) {
                            $cachedServiceAccounts += $branchState.DevEnvironmentConfiguration.ServiceAccountUPN
                        }
                    }
                }
            },
            [pscustomobject]@{
                Name = 'Configure deployment environments'
                Action = {
                    if ($wizardState.BranchEnvironmentMappingCompleted) {
                        [Spectre.Console.AnsiConsole]::MarkupLine('[grey]Deployment environments were already configured while defining branches.[/]')
                        return
                    }

                    foreach ($branchState in @($wizardState.BranchStates)) {
                        $branchName = [string]$branchState.BranchName
                        Write-Section `
                            -Message "Configure deployment environments for branch '$branchName'"

                        $excludedDevUrl = if ($branchState.DevEnvironmentConfiguration) { $branchState.DevEnvironmentConfiguration.Url } else { $null }
                        $initialDeploymentEnvironments = @()
                        foreach ($existingDeploymentEnvironment in @($branchState.DeploymentEnvironments)) {
                            if ([string]::IsNullOrWhiteSpace($existingDeploymentEnvironment.ShortName)) {
                                continue
                            }

                            $existingEnvironmentUrl = ConvertTo-NormalizedEnvironmentUrl -Url $existingDeploymentEnvironment.Url
                            if ($existingEnvironmentUrl -and -not [string]::IsNullOrWhiteSpace($excludedDevUrl) -and $existingEnvironmentUrl -ieq $excludedDevUrl) {
                                Write-Warning "Skipping existing deployment stage '$($existingDeploymentEnvironment.ShortName)' for branch '$branchName' because it points at that branch's DEV environment URL."
                                continue
                            }

                            $initialDeploymentEnvironments += [pscustomobject]@{
                                ShortName            = $existingDeploymentEnvironment.ShortName
                                FriendlyName         = $existingDeploymentEnvironment.FriendlyName
                                Url                  = $existingEnvironmentUrl
                                Credentials          = $existingDeploymentEnvironment.Credentials
                                ServiceAccountUPN    = $existingDeploymentEnvironment.ServiceAccountUPN
                                ConfigurationPending = (($null -eq $existingDeploymentEnvironment.Credentials) -or [string]::IsNullOrWhiteSpace($existingDeploymentEnvironment.ServiceAccountUPN))
                            }
                        }

                        $selectedDeploymentEnvironments = @(Select-ConfiguredDeploymentEnvironments `
                            -InitialEnvironments $initialDeploymentEnvironments `
                            -Heading "Target deployment environments for branch '$branchName'" `
                            -Title "Manage deployment environments for branch '$branchName'" `
                            -GuidanceLines @(
                                "Add each target Dataverse environment that branch '$branchName' should deploy to.",
                                'Keep the environments in promotion order because the generated DEPLOY workflow stages follow that sequence.'
                            ) `
                            -DocRelativePath 'docs/setup/github-setup.md' `
                            -Ref $ALM4DataverseRef `
                            -AddEnvironmentScriptBlock {
                                param($currentSelections)

                                $selectedEnv = Select-DataverseEnvironment -Prompt "Select a Dataverse environment for branch '$branchName'" -ExcludeUrl $excludedDevUrl
                                if (-not $selectedEnv) {
                                    return $null
                                }

                                $url = ConvertTo-NormalizedEnvironmentUrl -Url $selectedEnv.Endpoints['WebApplication']
                                if ($currentSelections | Where-Object { $_.Url -ieq $url }) {
                                    Write-Host 'An environment with that URL is already selected for this branch.' -ForegroundColor Red
                                    return $null
                                }

                                Write-Host 'Use a short deployment environment name (for example: TEST, UAT, PROD).' -ForegroundColor DarkGray
                                $shortName = Read-TextWithDefault -Prompt 'Enter a short name for this environment' -DefaultValue ''
                                if ($currentSelections | Where-Object { $_.ShortName -ieq $shortName }) {
                                    Write-Host 'An environment with that short name is already selected for this branch.' -ForegroundColor Red
                                    return $null
                                }

                                $environmentConfiguration = Get-GitHubEnvironmentConfiguration `
                                    -EnvironmentName $shortName `
                                    -EnvironmentUrl $url `
                                    -FriendlyName $selectedEnv.FriendlyName `
                                    -ExistingCredentials $cachedCredentials `
                                    -ExistingServiceAccounts $cachedServiceAccounts `
                                    -TenantId $TenantId `
                                    -RepoName $RepoName

                                if (-not ($cachedCredentials | Where-Object { $_.ApplicationId -eq $environmentConfiguration.Credentials.ApplicationId -and $_.TenantId -eq $environmentConfiguration.Credentials.TenantId })) {
                                    $cachedCredentials += $environmentConfiguration.Credentials
                                }
                                if ($cachedServiceAccounts -notcontains $environmentConfiguration.ServiceAccountUPN) {
                                    $cachedServiceAccounts += $environmentConfiguration.ServiceAccountUPN
                                }

                                return [pscustomobject]@{
                                    ShortName            = $environmentConfiguration.ShortName
                                    FriendlyName         = $environmentConfiguration.FriendlyName
                                    Url                  = $environmentConfiguration.Url
                                    Credentials          = $environmentConfiguration.Credentials
                                    ServiceAccountUPN    = $environmentConfiguration.ServiceAccountUPN
                                    ConfigurationPending = $false
                                }
                            } `
                            -EditEnvironmentScriptBlock {
                                param($currentSelections, $environmentToEdit, $environmentIndex)

                                $otherSelections = @()
                                for ($selectionIndex = 0; $selectionIndex -lt $currentSelections.Count; $selectionIndex++) {
                                    if ($selectionIndex -ne $environmentIndex) {
                                        $otherSelections += $currentSelections[$selectionIndex]
                                    }
                                }

                                $currentUrl = ConvertTo-NormalizedEnvironmentUrl -Url $environmentToEdit.Url
                                $selectedEnv = Select-DataverseEnvironment -Prompt "Select the Dataverse environment for '$($environmentToEdit.ShortName)' in branch '$branchName'" -ExcludeUrl $excludedDevUrl -PreferredUrl $currentUrl
                                if (-not $selectedEnv) {
                                    return $null
                                }

                                $url = ConvertTo-NormalizedEnvironmentUrl -Url $selectedEnv.Endpoints['WebApplication']
                                if ($otherSelections | Where-Object { $_.Url -ieq $url }) {
                                    Write-Host 'An environment with that URL is already selected for this branch.' -ForegroundColor Red
                                    return $null
                                }

                                Write-Host 'Use a short deployment environment name (for example: TEST, UAT, PROD).' -ForegroundColor DarkGray
                                $shortName = Read-TextWithDefault -Prompt 'Enter a short name for this environment' -DefaultValue $environmentToEdit.ShortName
                                if ($otherSelections | Where-Object { $_.ShortName -ieq $shortName }) {
                                    Write-Host 'An environment with that short name is already selected for this branch.' -ForegroundColor Red
                                    return $null
                                }

                                $currentCredentials = @($cachedCredentials)
                                $currentCredentials += @($otherSelections | ForEach-Object { $_.Credentials } | Where-Object { $null -ne $_ })
                                $currentServiceAccounts = @($cachedServiceAccounts)
                                $currentServiceAccounts += @($otherSelections | ForEach-Object { $_.ServiceAccountUPN } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

                                $environmentConfiguration = Get-GitHubEnvironmentConfiguration `
                                    -EnvironmentName $shortName `
                                    -EnvironmentUrl $url `
                                    -FriendlyName $selectedEnv.FriendlyName `
                                    -ExistingCredentials $currentCredentials `
                                    -ExistingServiceAccounts $currentServiceAccounts `
                                    -TenantId $TenantId `
                                    -RepoName $RepoName `
                                    -ExistingCredential $environmentToEdit.Credentials `
                                    -ExistingServiceAccountUPN $environmentToEdit.ServiceAccountUPN

                                if (-not ($cachedCredentials | Where-Object { $_.ApplicationId -eq $environmentConfiguration.Credentials.ApplicationId -and $_.TenantId -eq $environmentConfiguration.Credentials.TenantId })) {
                                    $cachedCredentials += $environmentConfiguration.Credentials
                                }
                                if ($cachedServiceAccounts -notcontains $environmentConfiguration.ServiceAccountUPN) {
                                    $cachedServiceAccounts += $environmentConfiguration.ServiceAccountUPN
                                }

                                return [pscustomobject]@{
                                    ShortName            = $environmentConfiguration.ShortName
                                    FriendlyName         = $environmentConfiguration.FriendlyName
                                    Url                  = $environmentConfiguration.Url
                                    Credentials          = $environmentConfiguration.Credentials
                                    ServiceAccountUPN    = $environmentConfiguration.ServiceAccountUPN
                                    ConfigurationPending = $false
                                }
                            })

                        $resolvedDeploymentEnvironments = @()
                        foreach ($selectedDeploymentEnvironment in @($selectedDeploymentEnvironments)) {
                            if ([string]::IsNullOrWhiteSpace($selectedDeploymentEnvironment.ShortName)) {
                                continue
                            }

                            $resolvedEnvironmentUrl = ConvertTo-NormalizedEnvironmentUrl -Url $selectedDeploymentEnvironment.Url
                            $resolvedFriendlyName = if ([string]::IsNullOrWhiteSpace($selectedDeploymentEnvironment.FriendlyName)) { $selectedDeploymentEnvironment.ShortName } else { $selectedDeploymentEnvironment.FriendlyName }

                            if ([string]::IsNullOrWhiteSpace($resolvedEnvironmentUrl)) {
                                $resolvedEnvironment = Select-DataverseEnvironment -Prompt "Resolve the Dataverse environment for existing deployment stage '$($selectedDeploymentEnvironment.ShortName)' in branch '$branchName'" -ExcludeUrl $excludedDevUrl -PreferredUrl $selectedDeploymentEnvironment.Url
                                if (-not $resolvedEnvironment) {
                                    throw "No Dataverse environment selected for existing deployment stage '$($selectedDeploymentEnvironment.ShortName)' in branch '$branchName'."
                                }

                                $resolvedEnvironmentUrl = ConvertTo-NormalizedEnvironmentUrl -Url $resolvedEnvironment.Endpoints['WebApplication']
                                $resolvedFriendlyName = $resolvedEnvironment.FriendlyName
                            }

                            if ($resolvedEnvironmentUrl -and -not [string]::IsNullOrWhiteSpace($excludedDevUrl) -and $resolvedEnvironmentUrl -ieq $excludedDevUrl) {
                                Write-Warning "Skipping deployment environment '$($selectedDeploymentEnvironment.ShortName)' for branch '$branchName' because it points at that branch's DEV environment URL."
                                continue
                            }

                            $needsConfiguration = (
                                ($selectedDeploymentEnvironment.PSObject.Properties.Name -contains 'ConfigurationPending' -and $selectedDeploymentEnvironment.ConfigurationPending) -or
                                ($null -eq $selectedDeploymentEnvironment.Credentials) -or
                                [string]::IsNullOrWhiteSpace($selectedDeploymentEnvironment.ServiceAccountUPN)
                            )

                            if ($needsConfiguration) {
                                $completedEnvironment = Get-GitHubEnvironmentConfiguration `
                                    -EnvironmentName $selectedDeploymentEnvironment.ShortName `
                                    -EnvironmentUrl $resolvedEnvironmentUrl `
                                    -FriendlyName $resolvedFriendlyName `
                                    -ExistingCredentials $cachedCredentials `
                                    -ExistingServiceAccounts $cachedServiceAccounts `
                                    -TenantId $TenantId `
                                    -RepoName $RepoName `
                                    -ExistingCredential $selectedDeploymentEnvironment.Credentials `
                                    -ExistingServiceAccountUPN $selectedDeploymentEnvironment.ServiceAccountUPN
                            }
                            else {
                                $completedEnvironment = [pscustomobject]@{
                                    ShortName         = $selectedDeploymentEnvironment.ShortName
                                    FriendlyName      = $resolvedFriendlyName
                                    Url               = $resolvedEnvironmentUrl
                                    Credentials       = $selectedDeploymentEnvironment.Credentials
                                    ServiceAccountUPN = $selectedDeploymentEnvironment.ServiceAccountUPN
                                }
                            }

                            $resolvedDeploymentEnvironments += $completedEnvironment
                            if ($completedEnvironment.Credentials -and -not ($cachedCredentials | Where-Object { $_.ApplicationId -eq $completedEnvironment.Credentials.ApplicationId -and $_.TenantId -eq $completedEnvironment.Credentials.TenantId })) {
                                $cachedCredentials += $completedEnvironment.Credentials
                            }
                            if (-not [string]::IsNullOrWhiteSpace($completedEnvironment.ServiceAccountUPN) -and $cachedServiceAccounts -notcontains $completedEnvironment.ServiceAccountUPN) {
                                $cachedServiceAccounts += $completedEnvironment.ServiceAccountUPN
                            }
                        }

                        $branchState.DeploymentEnvironments = @($resolvedDeploymentEnvironments)
                    }

                    $branchMappingsForValidation = @($wizardState.BranchStates | ForEach-Object {
                        [pscustomobject]@{
                            BranchName   = [string]$_.BranchName
                            Environments = @($_.DeploymentEnvironments)
                        }
                    })
                    if (Test-BranchEnvironmentMappingsHaveDuplicates -BranchMappings $branchMappingsForValidation) {
                        throw 'Each deployment environment can only be assigned to one branch. Resolve duplicate environment assignments before continuing.'
                    }

                    $branchesWithNoEnvironments = @($wizardState.BranchStates | Where-Object {
                        ($null -eq $_.DevEnvironmentConfiguration) -and (@($_.DeploymentEnvironments).Count -eq 0)
                    } | ForEach-Object { $_.BranchName })
                    if ($branchesWithNoEnvironments.Count -gt 0) {
                        $branchList = ($branchesWithNoEnvironments -join ', ')
                        throw "Each configured branch must have at least one mapped environment (DEV or deployment). Remove unused branches or configure environments for: $branchList"
                    }
                }
            },
            [pscustomobject]@{
                Name = 'Configure BUILD validation'
                Action = {
                    Write-Section `
                        -Message 'Configure solution validation during BUILD'
                    Write-SetupGuidance -Lines @(
                        'When enabled, BUILD uses one global Dataverse environment for pre-build connect/auth and solution validation.',
                        'This is configured once and then applied across all configured branches.'
                    ) -DocRelativePath 'docs/usage/building-releases.md' -Ref $ALM4DataverseRef -Header 'Build validation guidance'

                    $enableBuildValidation = if ([bool]$wizardState.BuildValidationEnabled) {
                        Read-YesNo -Prompt 'Enable solution validation during BUILD?'
                    }
                    else {
                        Read-YesNo -Prompt 'Enable solution validation during BUILD?' -DefaultNo
                    }

                    if (-not $enableBuildValidation) {
                        $wizardState.BuildValidationEnabled = $false
                        $wizardState.BuildValidationEnvironmentName = ''
                        $wizardState.BuildValidationEnvironmentConfiguration = $null
                        return
                    }

                    $existingBuildValidationEnvironment = $wizardState.BuildValidationEnvironmentConfiguration
                    $existingBuildValidationEnvironmentUrl = [string](Get-OptionalObjectPropertyValue -InputObject $existingBuildValidationEnvironment -PropertyName 'Url')
                    $existingBuildValidationEnvironmentName = [string](Get-OptionalObjectPropertyValue -InputObject $existingBuildValidationEnvironment -PropertyName 'ShortName')
                    if ([string]::IsNullOrWhiteSpace($existingBuildValidationEnvironmentName)) {
                        $existingBuildValidationEnvironmentName = [string](Get-OptionalObjectPropertyValue -InputObject $wizardState -PropertyName 'BuildValidationEnvironmentName')
                    }
                    $existingBuildValidationEnvironmentCredential = Get-OptionalObjectPropertyValue -InputObject $existingBuildValidationEnvironment -PropertyName 'Credentials'
                    $existingBuildValidationServiceAccountUPN = [string](Get-OptionalObjectPropertyValue -InputObject $existingBuildValidationEnvironment -PropertyName 'ServiceAccountUPN')

                    if ($UseGitHubEnvironments) {
                        Write-Host 'Preparing a global GitHub environment for BUILD validation.' -ForegroundColor Green
                    }
                    else {
                        Write-Host 'Preparing global prefixed repo-level credentials for BUILD validation.' -ForegroundColor Green
                    }
                    Write-Host ''

                    $selectedBuildEnvironment = Select-DataverseEnvironment -Prompt 'Select the Dataverse environment for global BUILD validation' -PreferredUrl $existingBuildValidationEnvironmentUrl
                    if (-not $selectedBuildEnvironment) {
                        throw 'BUILD validation was enabled, but no Dataverse environment was selected.'
                    }

                    $buildValidationEnvironmentName = Read-TextWithDefault -Prompt 'Enter the GitHub environment name for BUILD validation' -DefaultValue $(if ([string]::IsNullOrWhiteSpace($existingBuildValidationEnvironmentName)) { 'Build' } else { $existingBuildValidationEnvironmentName })
                    if ([string]::IsNullOrWhiteSpace($buildValidationEnvironmentName)) {
                        throw 'A GitHub environment name is required for global BUILD validation.'
                    }

                    $wizardState.BuildValidationEnvironmentName = $buildValidationEnvironmentName

                    $wizardState.BuildValidationEnvironmentConfiguration = Get-GitHubEnvironmentConfiguration `
                        -EnvironmentName $buildValidationEnvironmentName `
                        -EnvironmentUrl (ConvertTo-NormalizedEnvironmentUrl -Url $selectedBuildEnvironment.Endpoints['WebApplication']) `
                        -FriendlyName $selectedBuildEnvironment.FriendlyName `
                        -ExistingCredentials $cachedCredentials `
                        -ExistingServiceAccounts $cachedServiceAccounts `
                        -TenantId $TenantId `
                        -RepoName $RepoName `
                        -ExistingCredential $existingBuildValidationEnvironmentCredential `
                        -ExistingServiceAccountUPN $existingBuildValidationServiceAccountUPN

                    if ($wizardState.BuildValidationEnvironmentConfiguration -and -not ($cachedCredentials | Where-Object { $_.ApplicationId -eq $wizardState.BuildValidationEnvironmentConfiguration.Credentials.ApplicationId -and $_.TenantId -eq $wizardState.BuildValidationEnvironmentConfiguration.Credentials.TenantId })) {
                        $cachedCredentials += $wizardState.BuildValidationEnvironmentConfiguration.Credentials
                    }
                    if ($wizardState.BuildValidationEnvironmentConfiguration -and $cachedServiceAccounts -notcontains $wizardState.BuildValidationEnvironmentConfiguration.ServiceAccountUPN) {
                        $cachedServiceAccounts += $wizardState.BuildValidationEnvironmentConfiguration.ServiceAccountUPN
                    }

                    if ($wizardState.BuildValidationEnvironmentConfiguration -and -not [string]::IsNullOrWhiteSpace([string]$wizardState.BuildValidationEnvironmentConfiguration.ShortName)) {
                        $wizardState.BuildValidationEnvironmentName = [string]$wizardState.BuildValidationEnvironmentConfiguration.ShortName
                    }

                    $wizardState.BuildValidationEnabled = $true
                }
            },
            [pscustomobject]@{
                Name = 'Configure solutions'
                Action = {
                    Write-Section `
                        -Message 'Configure Solutions (alm-config.psd1)'

                    $candidateBranches = @($wizardState.BranchStates | Where-Object { $_.DevEnvironmentConfiguration })
                    if ($candidateBranches.Count -eq 0) {
                        [Spectre.Console.AnsiConsole]::MarkupLine('[yellow]No branch currently has a DEV environment configured, so solution selection will be skipped for now.[/]')
                        $wizardState.SolutionResult = $null
                        $wizardState.SolutionSourceBranch = $null
                        return
                    }

                    if ($candidateBranches.Count -eq 1) {
                        $sourceBranchState = $candidateBranches[0]
                    }
                    else {
                        $branchMenuItems = @($candidateBranches | ForEach-Object {
                            $friendlyName = if ($_.DevEnvironmentConfiguration -and -not [string]::IsNullOrWhiteSpace($_.DevEnvironmentConfiguration.FriendlyName)) {
                                [string]$_.DevEnvironmentConfiguration.FriendlyName
                            }
                            else {
                                [string]$_.BranchName
                            }
                            "Use branch '$($_.BranchName)' ($friendlyName) for solution discovery"
                        })
                        $branchSelection = Select-FromMenu -Title 'Select which configured branch should provide the DEV environment for solution discovery' -Items $branchMenuItems -PromptGuidanceLines @(
                            'Choose the branch whose DEV environment should be used for solution discovery.',
                            'Use the branch that currently reflects your source-controlled customization baseline.'
                        ) -PromptGuidanceDocRelativePath 'docs/config/alm-config.md' -PromptGuidanceRef $ALM4DataverseRef
                        if ($null -eq $branchSelection) {
                            throw 'No solution source branch selected.'
                        }

                        $sourceBranchState = $candidateBranches[$branchSelection]
                    }

                    $wizardState.SolutionSourceBranch = $sourceBranchState.BranchName
                    $existingConfigPath = Join-Path $CloneRoot 'alm-config.psd1'
                    $wizardState.SolutionResult = Invoke-WithErrorHandling -OperationName 'Selecting solutions' -ScriptBlock {
                        Get-DataverseSolutionsSelection `
                            -ExistingConfigPath $existingConfigPath `
                            -ExistingEnvironmentUrl $sourceBranchState.DevEnvironmentConfiguration.Url `
                            -ExistingEnvironmentConfiguration $sourceBranchState.DevEnvironmentConfiguration
                    }
                }
            },
            [pscustomobject]@{
                Name = 'Review choices'
                Action = {
                    Write-Section `
                        -Message 'Review setup choices'

                    $allConfiguredEnvironments = @()
                    foreach ($branchState in @($wizardState.BranchStates)) {
                        if ($branchState.DevEnvironmentConfiguration) {
                            $allConfiguredEnvironments += $branchState.DevEnvironmentConfiguration
                        }
                        $allConfiguredEnvironments += @($branchState.DeploymentEnvironments)
                    }

                    $branchMappingsForReview = @($wizardState.BranchStates | ForEach-Object {
                        [pscustomobject]@{
                            BranchName   = [string]$_.BranchName
                            Environments = @($_.DeploymentEnvironments)
                        }
                    })

                    Show-KeyValueSummaryTable -Heading 'Setup review' -Values ([ordered]@{
                        'Repository'               = $RepoFullName
                        'Shared workflow source'   = $SharedWorkflowRepository
                        'Shared workflow ref'      = $SharedWorkflowReference
                        'Credential storage'       = $(if ($UseGitHubEnvironments) { 'GitHub environments' } else { 'Prefixed repository variables/secrets' })
                        'Promotion mode'           = $DeploymentPromotionMode
                        'Configured branches'      = [string]$wizardState.BranchStates.Count
                        'BUILD validation'         = $(if ($wizardState.BuildValidationEnabled) { 'Enabled' } else { 'Disabled' })
                        'BUILD validation environment' = $(if (-not [string]::IsNullOrWhiteSpace([string]$wizardState.BuildValidationEnvironmentName)) { [string]$wizardState.BuildValidationEnvironmentName } elseif ($wizardState.BuildValidationEnvironmentConfiguration) { $wizardState.BuildValidationEnvironmentConfiguration.ShortName } else { '<none>' })
                        'Solution source branch'   = $(if ([string]::IsNullOrWhiteSpace($wizardState.SolutionSourceBranch)) { '<none>' } else { $wizardState.SolutionSourceBranch })
                        'Solutions selected'       = [string]$(if ($wizardState.SolutionResult) { @($wizardState.SolutionResult.Solutions).Count } else { 0 })
                    })

                    Show-BranchEnvironmentMappingTable -BranchMappings $branchMappingsForReview
                    [Spectre.Console.AnsiConsole]::WriteLine()

                    foreach ($branchState in @($wizardState.BranchStates)) {
                        $publishSummary = if ($branchState.PublishPlan -and $branchState.PublishPlan.Mode -eq 'PullRequest') {
                            "Pull request into $($branchState.PublishPlan.TargetBranch) from $($branchState.PublishPlan.BranchName)"
                        }
                        elseif ($branchState.PublishPlan) {
                            "Direct commit to $($branchState.PublishPlan.BranchName)"
                        }
                        else {
                            '<not configured>'
                        }

                        Show-KeyValueSummaryTable -Heading "Branch '$($branchState.BranchName)'" -Values ([ordered]@{
                            'Publish mode'            = $publishSummary
                            'DEV environment'         = $(if ($branchState.DevEnvironmentConfiguration) { $branchState.DevEnvironmentConfiguration.ShortName } else { '<none>' })
                            'Deployment environments' = [string]@($branchState.DeploymentEnvironments).Count
                        })
                    }

                    if ($allConfiguredEnvironments.Count -gt 0) {
                        Show-EnvironmentConfigurationTable -EnvironmentConfigurations $allConfiguredEnvironments
                    }

                    Confirm-SetupReviewAction
                }
            }
        )

        $selectedBranchNames = @($wizardState.BranchStates | ForEach-Object { [string]$_.BranchName })
        $existingConfiguredBranchNames = @($ExistingSetupState.DeploymentBranchMappings | ForEach-Object {
            if ($null -eq $_) {
                return $null
            }

            if ($_.PSObject.Properties.Name -contains 'BranchName') {
                return [string]$_.BranchName
            }

            return $null
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)

        $removedBranchNames = @($existingConfiguredBranchNames | Where-Object { $_ -notin $selectedBranchNames -and $_ -ne $DefaultBranch })

        $publishBranchStates = @($wizardState.BranchStates)
        $defaultBranchState = $publishBranchStates | Where-Object { $_.BranchName -ieq $DefaultBranch } | Select-Object -First 1
        if (-not $defaultBranchState) {
            $defaultBranchState = New-GitHubBranchSetupState -BranchName $DefaultBranch -ExistingDevEnvironment $ExistingSetupState.DevEnvironment -DeploymentEnvironments @()
            $defaultBranchState.PublishPlan = Get-BranchTargetedRepoChangePublishPlan `
                -ProviderName 'GitHub' `
                -RepositoryName $RepoFullName `
                -TargetBranch $DefaultBranch `
                -DefaultCommitMessage "Sync ALM4Dataverse workflow availability updates on '$DefaultBranch'" `
                -DefaultPullRequestTitle "Sync ALM4Dataverse workflow availability updates on '$DefaultBranch'" `
                -DefaultPullRequestDescription "This pull request ensures ALM4Dataverse workflow availability updates are present on '$DefaultBranch', including deploy workflow definitions for configured branches." `
                -GuidanceLines @(
                    "GitHub requires workflows to be present on '$DefaultBranch' for availability.",
                    'Choose how to publish these default-branch workflow availability updates.'
                ) `
                -DocRelativePath 'docs/setup/github-setup.md' `
                -Ref $ALM4DataverseRef

            $publishBranchStates += $defaultBranchState
        }

        foreach ($removedBranchName in @($removedBranchNames)) {
            $removedBranchState = New-GitHubBranchSetupState -BranchName $removedBranchName -ExistingDevEnvironment $null -DeploymentEnvironments @()
            $removedBranchState.PublishPlan = Get-BranchTargetedRepoChangePublishPlan `
                -ProviderName 'GitHub' `
                -RepositoryName $RepoFullName `
                -TargetBranch $removedBranchName `
                -DefaultCommitMessage "Sync non-deploy ALM4Dataverse workflow updates for branch '$removedBranchName'" `
                -DefaultPullRequestTitle "Sync non-deploy ALM4Dataverse workflow updates for branch '$removedBranchName'" `
                -DefaultPullRequestDescription "This pull request updates non-deploy ALM4Dataverse workflow files on '$removedBranchName' so shared workflow changes stay aligned across long-lived branches." `
                -GuidanceLines @(
                    "Branch '$removedBranchName' is no longer mapped for deployment, but shared non-deploy workflow updates still need to be merged.",
                    'Choose how to publish these synchronization updates.'
                ) `
                -DocRelativePath 'docs/setup/github-setup.md' `
                -Ref $ALM4DataverseRef

            $publishBranchStates += $removedBranchState
        }

        $buildValidationEnvironmentNameForPublish = ''
        if (-not [string]::IsNullOrWhiteSpace([string]$wizardState.BuildValidationEnvironmentName)) {
            $buildValidationEnvironmentNameForPublish = [string]$wizardState.BuildValidationEnvironmentName
        }
        elseif ($wizardState.BuildValidationEnvironmentConfiguration -and -not [string]::IsNullOrWhiteSpace([string]$wizardState.BuildValidationEnvironmentConfiguration.ShortName)) {
            $buildValidationEnvironmentNameForPublish = [string]$wizardState.BuildValidationEnvironmentConfiguration.ShortName
        }

        $defaultBranchDeployWorkflowDefinitions = @()
        foreach ($configuredBranchState in @($wizardState.BranchStates)) {
            $defaultBranchDeployWorkflowDefinitions += [pscustomobject]@{
                BranchName             = [string]$configuredBranchState.BranchName
                DeploymentEnvironments = @($configuredBranchState.DeploymentEnvironments)
            }
        }
        foreach ($removedBranchName in @($removedBranchNames)) {
            $defaultBranchDeployWorkflowDefinitions += [pscustomobject]@{
                BranchName             = [string]$removedBranchName
                DeploymentEnvironments = @()
            }
        }

        foreach ($branchState in @($publishBranchStates)) {
            $isSelectedBranch = ($selectedBranchNames -contains [string]$branchState.BranchName)
            $isRemovedBranch = ($removedBranchNames -contains [string]$branchState.BranchName)
            $isDefaultPublishBranch = ([string]$branchState.BranchName -ieq $DefaultBranch)

            $solutionsForBranchPublish = if ($isSelectedBranch) {
                $(if ($wizardState.SolutionResult) { @($wizardState.SolutionResult.Solutions) } else { @() })
            }
            else {
                @()
            }

            $deployDefinitionsForBranchPublish = if ($isDefaultPublishBranch) {
                @($defaultBranchDeployWorkflowDefinitions)
            }
            else {
                @()
            }

            $publishResult = Invoke-WithErrorHandling -OperationName "Publishing repository changes for branch '$($branchState.BranchName)'" -StatusMessage "Publishing repository changes for branch '$($branchState.BranchName)'..." -CaptureOutputInPanel -ScriptBlock {
                Publish-GitHubBranchSetupChanges `
                    -RepoRoot $CloneRoot `
                    -ConfiguredBranch $branchState.BranchName `
                    -PublishPlan $branchState.PublishPlan `
                    -DefaultBranch $DefaultBranch `
                    -CopyRoot $copyRoot `
                    -SharedWorkflowRepository $SharedWorkflowRepository `
                    -SharedWorkflowReference $SharedWorkflowReference `
                    -PromotionMode $DeploymentPromotionMode `
                        -Solutions $solutionsForBranchPublish `
                        -DeploymentEnvironments @($branchState.DeploymentEnvironments) `
                        -DeployWorkflowBranchDefinitions $deployDefinitionsForBranchPublish `
                        -BuildValidationEnabled ([bool]$wizardState.BuildValidationEnabled) `
                        -BuildValidationEnvironmentName $buildValidationEnvironmentNameForPublish `
                        -SkipDeployWorkflow:$isRemovedBranch
            }

            $publishResults += [pscustomobject]@{
                ConfiguredBranch = $branchState.BranchName
                BranchName       = $publishResult.BranchName
                TargetBranch     = $publishResult.TargetBranch
                PullRequestUrl   = $publishResult.PullRequestUrl
                Mode             = $publishResult.Mode
                HasChanges       = $publishResult.HasChanges
            }
        }

        return [pscustomobject]@{
            BranchStates         = @($wizardState.BranchStates)
            SolutionResult       = $wizardState.SolutionResult
            SolutionSourceBranch = $wizardState.SolutionSourceBranch
            BuildValidationEnabled = [bool]$wizardState.BuildValidationEnabled
            BuildValidationEnvironmentName = [string]$wizardState.BuildValidationEnvironmentName
            BuildValidationEnvironmentConfiguration = $wizardState.BuildValidationEnvironmentConfiguration
            PublishResults       = @($publishResults)
        }
    }
    finally {
        if ($upstreamClone -and (Test-Path -LiteralPath $upstreamClone)) {
            try { Remove-Item -LiteralPath $upstreamClone -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
}

#endregion

# ─────────────────────────────────────────────────────────────
#  MAIN SETUP FLOW
# ─────────────────────────────────────────────────────────────

Write-Section `
    -Message "Authenticating with GitHub"

$ghStatusProbe = Invoke-WithSpectreStatus -Status 'Checking GitHub CLI authentication status...' -ScriptBlock {
    $output = @(& gh auth status --hostname github.com 2>&1)
    return [pscustomobject]@{
        Output   = $output
        ExitCode = $LASTEXITCODE
    }
}
$ghStatus = @($ghStatusProbe.Output)
$hasExistingGitHubLogin = ($ghStatusProbe.ExitCode -eq 0)

if ($hasExistingGitHubLogin) {
    $existingGhUser = (& gh api user --jq '.login' 2>&1 | Out-String).Trim()

    $ghMenuItems = @()
    if (-not [string]::IsNullOrWhiteSpace($existingGhUser)) {
        $ghMenuItems += "Use existing GitHub login: $existingGhUser"
    }
    else {
        $ghMenuItems += "Use existing GitHub login"
    }
    $ghMenuItems += "Sign in with a different GitHub account"

    $ghChoice = Select-FromMenu `
        -Title "GitHub authentication" `
        -Items $ghMenuItems `
        -PromptGuidanceLines @(
            'Choose whether to continue with the currently authenticated GitHub account or switch to another one.',
            'Use the account that should own or manage workflow and repository settings for this setup.'
        ) `
        -PromptGuidanceDocRelativePath 'docs/setup/github-setup.md' `
        -PromptGuidanceRef $ALM4DataverseRef
    if ($null -eq $ghChoice) {
        throw "No GitHub authentication option selected."
    }

    if ($ghChoice -eq 0) {
        Write-Host "Using existing GitHub login." -ForegroundColor Green
    }
    else {
        Write-Host "Signing in with a different GitHub account..." -ForegroundColor Yellow
        & gh auth logout --hostname github.com 2>&1 | Out-Host
        & gh auth login --web --hostname github.com
        if ($LASTEXITCODE -ne 0) {
            throw "GitHub authentication failed."
        }
    }
}
else {
    Write-Host "Not logged in to GitHub. Opening browser for authentication..." -ForegroundColor Yellow
    & gh auth login --web --hostname github.com
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub authentication failed."
    }
}

# Get the authenticated username
$script:ghUser = (& gh api user --jq '.login' 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "Failed to determine GitHub username."
}

$script:ghUserId = $null
$ghUserIdRaw = (& gh api user --jq '.id' 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -eq 0 -and $ghUserIdRaw -match '^\d+$') {
    $script:ghUserId = [int]$ghUserIdRaw
}

Write-Host "Logged in as: $script:ghUser" -ForegroundColor Green
if ($script:ghUserId) {
    Write-Host "GitHub user id: $script:ghUserId" -ForegroundColor DarkGray
}

Write-Section `
    -Message "Authenticating with Azure"

Write-Host "To enable automated setup, we need to authenticate with Azure." -ForegroundColor Green
Write-Host ""
Write-Host "When prompted, please log in with an account that has access to:" -ForegroundColor Green
Write-Host "- Your Entra ID tenant (to manage App Registrations)" -ForegroundColor Green
Write-Host "- Your Dataverse DEV environment (SYSTEM ADMINISTRATOR role)" -ForegroundColor Green
Write-Host ""

$cachedAzureAccounts = @(Get-AuthToken -ResourceUrl "https://graph.microsoft.com" -TenantId $TenantId -ListAccountsOnly)
$preferredAzureUsername = $null
$forceAzureInteractive = $false

if ($cachedAzureAccounts.Count -gt 0) {
    $azureAuthMenuItems = @($cachedAzureAccounts | ForEach-Object { "Use existing Azure login: $_" })
    $azureAuthMenuItems += "Sign in with a different Azure account"

    $azureAuthChoice = Select-FromMenu `
        -Title "Azure authentication" `
        -Items $azureAuthMenuItems `
        -PromptGuidanceLines @(
            'Choose whether to reuse an existing Azure login context or sign in with a different identity.',
            'Select an identity that can manage app registrations and Dataverse users in the target tenant.'
        ) `
        -PromptGuidanceDocRelativePath 'docs/setup/github-setup.md' `
        -PromptGuidanceRef $ALM4DataverseRef
    if ($null -eq $azureAuthChoice) {
        throw "No Azure authentication option selected."
    }

    if ($azureAuthChoice -lt $cachedAzureAccounts.Count) {
        $preferredAzureUsername = $cachedAzureAccounts[$azureAuthChoice]
    }
    else {
        $forceAzureInteractive = $true
        Wait-ForUserAcknowledgement -Message 'Open the browser for Azure authentication when you are ready.' -ContinueLabel 'Open browser'
    }
}
else {
    Wait-ForUserAcknowledgement -Message 'Open the browser for Azure authentication when you are ready.' -ContinueLabel 'Open browser'
}

$script:azureAuthResult = Invoke-WithErrorHandling -OperationName "Azure Authentication" -ScriptBlock {
    # Request a Graph token to confirm authentication works
    $result = Get-AuthToken -ResourceUrl "https://graph.microsoft.com" -TenantId $TenantId -PreferredUsername $preferredAzureUsername -ForceInteractive:$forceAzureInteractive
    if (-not $result -or -not $result.AccessToken) {
        throw "Failed to acquire an Azure access token."
    }
    return $result
}

Write-Host "Authenticated as: $($script:azureAuthResult.Account.Username)" -ForegroundColor Green

# Resolve tenant ID from the token if not supplied
if ([string]::IsNullOrWhiteSpace($TenantId)) {
    $TenantId = $script:azureAuthResult.TenantId
    Write-Host "Using tenant: $TenantId"
}

Assert-ValidTenantIdentifier -TenantIdentifier $TenantId -Source 'Resolved Azure tenant ID'

# ─────────────────────────────────────────────────────────────
Write-Section `
    -Message "Ensuring Shared Workflow Repository"

$upstreamWorkflowRepoFullName = Resolve-GitHubRepoFullNameFromSource -Source $upstreamRepo -Fallback 'ALM4Dataverse/ALM4Dataverse'
$upstreamGitSource = Resolve-UpstreamGitRemoteSource -ConfiguredSource $upstreamRepo -GitHubFullName $upstreamWorkflowRepoFullName

Write-Host "Upstream workflow source: $upstreamWorkflowRepoFullName" -ForegroundColor DarkGray
Write-Host "Using ALM4Dataverse ref: $ALM4DataverseRef" -ForegroundColor DarkGray

# ─────────────────────────────────────────────────────────────
Write-Section `
    -Message "Select GitHub Repository"

$repos = @(Invoke-WithSpectreStatus -Status 'Fetching repositories you have write access to...' -ScriptBlock {
    Get-GitHubRepoList
})
$selectedRepo = $null

$repos = @($repos | Sort-Object -Property nameWithOwner)
$repoMenuItems = @()
$repoMenuActions = @()


$repoMenuItems += 'Create a new repository'
$repoMenuActions += @{ Type = 'CreateNew' }

foreach ($repo in $repos) {
    $repoMenuItems += "Use existing repository: $($repo.nameWithOwner)"
    $repoMenuActions += @{ Type = 'UseExisting'; Repo = $repo }
}


$repoSelection = Select-FromMenu -Title "Select the repository to set up ALM4Dataverse in" -Items $repoMenuItems -PromptGuidanceLines @(
    'Choose the target repository for ALM4Dataverse shared workflows.',
    'This must be a separate repository from your main application repository.'
) -PromptGuidanceDocRelativePath 'docs/setup/github-setup.md' -PromptGuidanceRef $ALM4DataverseRef
if ($null -eq $repoSelection) {
    throw "No repository selected."
}

$repoAction = $repoMenuActions[$repoSelection]
if ($repoAction.Type -eq 'UseExisting') {
    $selectedRepo = $repoAction.Repo
}
else {
    $selectedRepo = Invoke-WithErrorHandling -OperationName "Creating GitHub repository" -ScriptBlock {
        New-GitHubRepositoryInteractive -DefaultOwner $script:ghUser
    }
}

$repoOwner    = $selectedRepo.owner.login
$repoName     = $selectedRepo.name
$repoFullName = $selectedRepo.nameWithOwner

Write-Host "Selected: $repoFullName" -ForegroundColor Cyan

# Determine default branch
$defaultBranch = 'main'
if ($selectedRepo.defaultBranchRef -and $selectedRepo.defaultBranchRef.name) {
    $defaultBranch = $selectedRepo.defaultBranchRef.name
}
Write-Host "Default branch: $defaultBranch"

$cloneRoot = $null

Write-Section `
    -Message "Cloning Repository"

    $cloneRoot = Invoke-WithErrorHandling -OperationName "Cloning repository" -ScriptBlock {
    $attemptCloneRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ALM4Dataverse-GH-" + [guid]::NewGuid().ToString('n'))
    Write-Host "Cloning $repoFullName to $attemptCloneRoot..." -ForegroundColor Yellow

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $cloneOutput = @(& gh repo clone $repoFullName $attemptCloneRoot -- --depth 1 2>&1)
        $cloneExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($cloneExitCode -ne 0) {
        $cloneErrorDetails = @($cloneOutput | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $cloneErrorMessage = if ($cloneErrorDetails.Count -gt 0) { $cloneErrorDetails[-1] } else { "Exit code: $cloneExitCode" }
        throw "gh repo clone failed. $cloneErrorMessage"
    }

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $fetchOutput = @(& git -C $attemptCloneRoot fetch origin '+refs/heads/*:refs/remotes/origin/*' --prune 2>&1)
        $fetchExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($fetchExitCode -ne 0) {
        $fetchErrorDetails = @($fetchOutput | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $fetchErrorMessage = if ($fetchErrorDetails.Count -gt 0) { $fetchErrorDetails[-1] } else { "Exit code: $fetchExitCode" }
        throw "git fetch failed while retrieving remote branches. $fetchErrorMessage"
    }

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        [void](& git -C $attemptCloneRoot reset --hard HEAD 2>&1)
        [void](& git -C $attemptCloneRoot clean -fd 2>&1)

        $checkoutOutput = @(& git -C $attemptCloneRoot checkout -f $defaultBranch 2>&1)
        $checkoutExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($checkoutExitCode -ne 0) {
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $checkoutOutput = @(& git -C $attemptCloneRoot checkout -B $defaultBranch "origin/$defaultBranch" 2>&1)
            $checkoutExitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
    }

    if ($checkoutExitCode -ne 0) {
        $checkoutErrorDetails = @($checkoutOutput | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $checkoutErrorMessage = if ($checkoutErrorDetails.Count -gt 0) { $checkoutErrorDetails[-1] } else { "Exit code: $checkoutExitCode" }
        throw "Failed to check out repository base branch '$defaultBranch'. $checkoutErrorMessage"
    }

    return [pscustomobject]@{
        CloneRoot = $attemptCloneRoot
    }
} -StatusMessage 'Cloning the selected repository...' -CaptureOutputInPanel

$cloneRoot = if ($cloneRoot -and $cloneRoot.PSObject.Properties.Name -contains 'CloneRoot') { [string]$cloneRoot.CloneRoot } else { [string]$cloneRoot }

if ([string]::IsNullOrWhiteSpace($cloneRoot)) {
    throw 'Clone operation did not produce a working directory path.'
}

$existingSetupState = Invoke-WithSpectreStatus -Status 'Inspecting the existing repository configuration...' -ScriptBlock {
    Get-GitHubRepositoryExistingSetupState `
        -RepoRoot $cloneRoot `
        -RepoOwner $repoOwner `
        -RepoName $repoName `
        -DefaultBranch $defaultBranch `
        -TenantId $TenantId
}

$existingDevEnvironment = $existingSetupState.DevEnvironment
$existingDevEnvironmentUrl = $null
$existingDevEnvironmentCredentials = $null
$existingDevEnvironmentServiceAccountUPN = $null

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

    if ($existingDevEnvironment.PSObject.Properties.Name -contains 'Credentials') {
        $existingDevEnvironmentCredentials = $existingDevEnvironment.Credentials
    }

    if ($existingDevEnvironment.PSObject.Properties.Name -contains 'ServiceAccountUPN') {
        $existingDevEnvironmentServiceAccountUPN = $existingDevEnvironment.ServiceAccountUPN
    }
}

if ($existingSetupState.SharedWorkflowRepository) {
    Write-Host "Existing shared workflow repository detected: $($existingSetupState.SharedWorkflowRepository)" -ForegroundColor DarkGray
}
if ($existingSetupState.SharedWorkflowReference) {
    Write-Host "Existing shared workflow ref detected: $($existingSetupState.SharedWorkflowReference)" -ForegroundColor DarkGray
}

# ─────────────────────────────────────────────────────────────
Write-Section `
    -Message "Ensuring Shared Workflow Repository"

$sharedWorkflowRepo = Invoke-WithErrorHandling -OperationName "Ensuring shared workflow repository" -ScriptBlock {
    Ensure-GitHubForkForSharedWorkflows `
        -UpstreamFullName $upstreamWorkflowRepoFullName `
        -ForkOwner $script:ghUser `
        -UpstreamGitSource $upstreamGitSource `
        -Reference $ALM4DataverseRef `
        -PreferredRepositoryFullName $existingSetupState.SharedWorkflowRepository
}

$sharedWorkflowRepository = $sharedWorkflowRepo.nameWithOwner
$sharedWorkflowReference = 'main'
if ($sharedWorkflowRepo.defaultBranchRef -and $sharedWorkflowRepo.defaultBranchRef.name) {
    $sharedWorkflowReference = $sharedWorkflowRepo.defaultBranchRef.name
}

Write-Host "Shared workflow repository: $sharedWorkflowRepository" -ForegroundColor Green
Write-Host "Shared workflow reference (synced branch): $sharedWorkflowReference" -ForegroundColor Green

$sharedWorkflowRepoParts = $sharedWorkflowRepository.Split('/', 2)
Invoke-WithSpectreStatus -Status "Checking Actions access policy on shared workflow repository '$sharedWorkflowRepository'..." -ScriptBlock {
    Ensure-GitHubSharedWorkflowAccessPolicy -Owner $sharedWorkflowRepoParts[0] -Repo $sharedWorkflowRepoParts[1]
} | Out-Null

$useGitHubEnvironments = $false
$enableEnvironmentApprovals = $false
$environmentApprovalReviewerIds = @()
$deploymentPromotionMode = 'manual-gate-tag'

$environmentCapabilities = Invoke-WithSpectreStatus -Status "Checking GitHub environment capabilities for '$repoFullName'..." -ScriptBlock {
    Get-GitHubEnvironmentCapabilities -Owner $repoOwner -Repo $repoName -ApprovalReviewerId $script:ghUserId
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
elseif ($existingSetupState.CredentialStorageScope -eq 'RepositoryPrefix') {
    $useGitHubEnvironments = $false
    $enableEnvironmentApprovals = $false
    $deploymentPromotionMode = 'manual-gate-tag'
    Write-Host 'Existing repository configuration uses prefixed repo-level credentials, so setup will preserve that as the baseline.' -ForegroundColor Green
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
    Write-Host "GitHub environments are unavailable for this repository. Setup will use prefixed repo-level credentials and tag-based promotion." -ForegroundColor Yellow
}

if (-not [string]::IsNullOrWhiteSpace($environmentCapabilities.Message)) {
    Write-Host $environmentCapabilities.Message -ForegroundColor DarkGray
}

Write-Host "DEPLOY workflow promotion mode: $deploymentPromotionMode" -ForegroundColor DarkGray

$githubSetupResult = Invoke-GitHubBranchAwareSetup `
    -CloneRoot $cloneRoot `
    -RepoOwner $repoOwner `
    -RepoName $repoName `
    -RepoFullName $repoFullName `
    -DefaultBranch $defaultBranch `
    -TenantId $TenantId `
    -ExistingSetupState $existingSetupState `
    -SharedWorkflowRepository $sharedWorkflowRepository `
    -SharedWorkflowReference $sharedWorkflowReference `
    -UpstreamGitSource $upstreamGitSource `
    -ALM4DataverseRef $ALM4DataverseRef `
    -UseGitHubEnvironments $useGitHubEnvironments `
    -EnableEnvironmentApprovals $enableEnvironmentApprovals `
    -EnvironmentApprovalReviewerIds $environmentApprovalReviewerIds `
    -DeploymentPromotionMode $deploymentPromotionMode

$branchStates = @($githubSetupResult.BranchStates)
$solutionResult = $githubSetupResult.SolutionResult
$solutionSourceBranch = $githubSetupResult.SolutionSourceBranch
$buildValidationEnabled = [bool](Get-OptionalObjectPropertyValue -InputObject $githubSetupResult -PropertyName 'BuildValidationEnabled')
$buildValidationEnvironmentConfiguration = Get-OptionalObjectPropertyValue -InputObject $githubSetupResult -PropertyName 'BuildValidationEnvironmentConfiguration'
$repoPublishResults = @($githubSetupResult.PublishResults)
$allConfiguredEnvironments = @()
$allDeploymentEnvironments = @()
foreach ($branchState in @($branchStates)) {
    if ($branchState.DevEnvironmentConfiguration) {
        $allConfiguredEnvironments += $branchState.DevEnvironmentConfiguration
    }

    $allDeploymentEnvironments += @($branchState.DeploymentEnvironments)
    $allConfiguredEnvironments += @($branchState.DeploymentEnvironments)
}

try { Remove-Item -LiteralPath $cloneRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }

# ─────────────────────────────────────────────────────────────
Write-Section `
    -Message "Configure Dev Environment Credentials"

$devBranchStates = @($branchStates | Where-Object { $_.DevEnvironmentConfiguration })
if ($devBranchStates.Count -eq 0) {
    [Spectre.Console.AnsiConsole]::MarkupLine('[yellow]No DEV environment credentials were configured in the wizard, so this step will be skipped.[/]')
}
else {
    foreach ($branchState in $devBranchStates) {
        $devEnvironmentConfiguration = $branchState.DevEnvironmentConfiguration
        Write-Section `
            -Message "Apply DEV environment configuration for branch '$($branchState.BranchName)'"
        if ($useGitHubEnvironments) {
            Write-Host "Setting up GitHub environment '$($devEnvironmentConfiguration.ShortName)' for branch '$($branchState.BranchName)'." -ForegroundColor Green
        }
        else {
            Write-Host "Setting up prefixed repo-level credentials for DEV environment '$($devEnvironmentConfiguration.ShortName)'." -ForegroundColor Green
        }
        Write-Host ""

        Invoke-WithErrorHandling -OperationName "Setting up DEV credentials for branch '$($branchState.BranchName)'" -StatusMessage "Applying DEV environment credentials for branch '$($branchState.BranchName)'..." -CaptureOutputInPanel -ScriptBlock {
            Apply-GitHubEnvironmentConfiguration `
                -EnvironmentConfiguration $devEnvironmentConfiguration `
                -TenantId $TenantId `
                -RepoOwner $repoOwner `
                -RepoName $repoName `
                -RepoFullName $repoFullName `
                -UseGitHubEnvironments $useGitHubEnvironments `
                -EnableApprovals:$false
        } | Out-Null
    }
}

# ─────────────────────────────────────────────────────────────
Write-Section `
    -Message "Configure Global BUILD Validation Environment"

if (-not $buildValidationEnabled -or -not $buildValidationEnvironmentConfiguration) {
    [Spectre.Console.AnsiConsole]::MarkupLine('[yellow]Global BUILD validation is disabled, so BUILD environment credentials will be skipped.[/]')
}
else {
    Write-Host "Applying global BUILD validation environment '$($buildValidationEnvironmentConfiguration.ShortName)'." -ForegroundColor Green
    Write-Host ""

    Invoke-WithErrorHandling -OperationName 'Applying global BUILD validation environment configuration' -AllowSkip -ScriptBlock {
        Apply-GitHubEnvironmentConfiguration `
            -EnvironmentConfiguration $buildValidationEnvironmentConfiguration `
            -TenantId $TenantId `
            -RepoOwner $repoOwner `
            -RepoName $repoName `
            -RepoFullName $repoFullName `
            -UseGitHubEnvironments $useGitHubEnvironments `
            -EnableApprovals:$false
    } -StatusMessage 'Applying global BUILD validation environment configuration...' -CaptureOutputInPanel | Out-Null
}

# ─────────────────────────────────────────────────────────────
Write-Section `
    -Message "Configure Deployment Environment Credentials"

if ($useGitHubEnvironments) {
    Write-Host "Configuring GitHub environment credentials for deployment stages." -ForegroundColor Green
}
else {
    Write-Host "Configuring prefixed repo-level credentials for deployment stages." -ForegroundColor Green
}
Write-Host ""

if ($allDeploymentEnvironments.Count -eq 0) {
    Write-Host "No deployment environments selected. You can run this script again to add them later." -ForegroundColor Yellow
}
else {
    foreach ($branchState in @($branchStates)) {
        foreach ($env in @($branchState.DeploymentEnvironments)) {
            Write-Section `
                -Message "Applying environment configuration '$($env.ShortName)' for branch '$($branchState.BranchName)'"
            Write-Host "Dataverse URL: $($env.Url)" -ForegroundColor DarkGray
            Write-Host ""

            Invoke-WithErrorHandling -OperationName "Applying environment configuration for $($env.ShortName)" -AllowSkip -ScriptBlock {
                Apply-GitHubEnvironmentConfiguration `
                    -EnvironmentConfiguration $env `
                    -TenantId $TenantId `
                    -RepoOwner $repoOwner `
                    -RepoName $repoName `
                    -RepoFullName $repoFullName `
                    -UseGitHubEnvironments $useGitHubEnvironments `
                    -EnableApprovals:$enableEnvironmentApprovals `
                    -RequiredReviewerIds $environmentApprovalReviewerIds
            } -StatusMessage "Applying configuration for environment '$($env.ShortName)'..." -CaptureOutputInPanel | Out-Null
        }
    }
}

# ─────────────────────────────────────────────────────────────
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
        'Credential storage'      = $(if ($useGitHubEnvironments) { 'GitHub environments' } else { 'Prefixed repository variables/secrets' })
        'BUILD validation'        = $(if ($buildValidationEnabled) { 'Enabled' } else { 'Disabled' })
        'BUILD validation environment' = $(if ($buildValidationEnvironmentConfiguration) { $buildValidationEnvironmentConfiguration.ShortName } else { '<none>' })
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
