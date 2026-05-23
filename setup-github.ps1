
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

#region Common Functions

function Write-Section {
    param([Parameter(Mandatory)][string]$Message)
    
    Write-Progress -Completed -Activity "Done"
    Clear-Host
    Write-Host "==== $Message ====" -ForegroundColor Cyan
    Write-Host ""
}

function New-DirectoryIfMissing {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Select-FromMenu {
    <#
    .SYNOPSIS
        Simple interactive console menu selection using PSMenu.

    .DESCRIPTION
        Arrow keys to move, Enter to select, Esc to cancel.

        This function wraps the PSMenu module's Show-Menu function.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string[]]$Items
    )

    if ($Items.Count -eq 0) { return $null }

    # Use PSMenu's Show-Menu with title display
    Write-Host $Title -ForegroundColor Green
    Write-Host "" # Add spacing
    
    $selectedIndex = Show-Menu -MenuItems $Items -ReturnIndex
    return $selectedIndex
}

function Read-YesNo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter()][switch]$DefaultNo
    )

    $suffix = if ($DefaultNo) { ' [y/N]' } else { ' [Y/n]' }
    $answer = Read-Host ($Prompt + $suffix)
    if ([string]::IsNullOrWhiteSpace($answer)) {
        return (-not $DefaultNo)
    }
    return ($answer.Trim().ToLowerInvariant() -in @('y', 'yes'))
}

function ConvertFrom-GitRefToBranchName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Ref
    )

    if ($Ref -match '^refs/heads/(.+)$') {
        return $Matches[1]
    }
    return $Ref
}

function ConvertTo-UrlSafeName {
    <#
    .SYNOPSIS
        Converts a name to a URL-safe format for use in federated identity credential names.
    
    .DESCRIPTION
        Replaces characters that are not safe in URL segments with hyphens.
        Allowed characters are: A-Z, a-z, 0-9, and hyphens.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name
    )

    # Replace any character that is not alphanumeric or hyphen with a hyphen
    $safeName = $Name -replace '[^a-zA-Z0-9-]', '-'
    
    # Remove consecutive hyphens
    $safeName = $safeName -replace '-+', '-'
    
    # Trim hyphens from start and end
    $safeName = $safeName.Trim('-')
    
    return $safeName
}

function Test-IsValidTenantIdentifier {
    <#
    .SYNOPSIS
        Validates an Entra tenant identifier.

    .DESCRIPTION
        Accepts either a tenant GUID or a tenant domain name
        (for example contoso.onmicrosoft.com).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantIdentifier
    )

    $value = $TenantIdentifier.Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $false
    }

    $isGuid = $value -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
    $isDns = $value -match '^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}$'

    return ($isGuid -or $isDns)
}

function Assert-ValidTenantIdentifier {
    <#
    .SYNOPSIS
        Throws when an Entra tenant identifier is invalid.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantIdentifier,
        [Parameter()][string]$Source = 'TenantId'
    )

    if (-not (Test-IsValidTenantIdentifier -TenantIdentifier $TenantIdentifier)) {
        throw "$Source value '$TenantIdentifier' is invalid. Use a tenant GUID or tenant domain (for example, contoso.onmicrosoft.com)."
    }
}

#endregion

#region Initialization

function Get-ModulePathDelimiter {
    # Use platform-agnostic delimiter for PSModulePath.
    # ';' on Windows, ':' on Unix.
    return [System.IO.Path]::PathSeparator
}

function Install-NuGetProviderIfMissing {
    # Save-Module requires a package provider (NuGet). This installs the provider if missing.
    $nuget = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
    if (-not $nuget) {
        Write-Host "Installing NuGet package provider (required for Save-Module)..." -ForegroundColor Yellow
        Install-PackageProvider -Name NuGet -Force -Scope CurrentUser | Out-Null
    }
}

function Get-ModuleAvailableExact {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$RequiredVersion
    )

    # Use ListAvailable so we also see modules in our temp PSModulePath.
    $mods = Get-Module -Name $Name -ListAvailable -ErrorAction SilentlyContinue
    if (-not $mods) { return $null }

    return $mods | Where-Object { $_.Version -eq [version]$RequiredVersion } | Select-Object -First 1
}

function Save-ModuleExact {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$RequiredVersion,
        [Parameter(Mandatory)][string]$Destination
    )

    Install-NuGetProviderIfMissing

    Write-Host "Downloading $Name $RequiredVersion to $Destination" -ForegroundColor Yellow
    Save-Module -Name $Name -RequiredVersion $RequiredVersion -Path $Destination -Force
}

function Import-RequiredModuleVersion {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$RequiredVersion,
        [Parameter(Mandatory)][string]$Destination
    )

    # Use a different variable name to avoid conflicts
    $targetVersion = $RequiredVersion

    $available = Get-ModuleAvailableExact -Name $Name -RequiredVersion $targetVersion
    if (-not $available) {
        Save-ModuleExact -Name $Name -RequiredVersion $targetVersion -Destination $Destination
        $available = Get-ModuleAvailableExact -Name $Name -RequiredVersion $targetVersion
        if (-not $available) {
            throw "Module $Name $targetVersion was downloaded but is still not discoverable on PSModulePath."
        }
    }

    # Import the exact version we found.
    Import-Module -Name $Name -RequiredVersion $targetVersion -Force -ErrorAction Stop
    $loaded = Get-Module -Name $Name | Where-Object { $_.Version -eq [version]$targetVersion } | Select-Object -First 1
    if (-not $loaded) {
        throw "Failed to import $Name version $targetVersion. Loaded version: $((Get-Module -Name $Name | Select-Object -First 1).Version)"
    }

    Write-Host "Loaded $Name $($loaded.Version)"
}

function Resolve-DevelopmentDefaultAlm4DataverseRef {
    [CmdletBinding()]
    param(
        [Parameter()][string]$PrimaryRepositoryPath,
        [Parameter()][string]$FallbackRef = 'stable'
    )

    # Try candidate local repositories in order; use first one that resolves.
    $candidateRepos = @()
    foreach ($candidate in @($PrimaryRepositoryPath, $PSScriptRoot)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $candidateRepos += $candidate
        }
    }
    $candidateRepos = @($candidateRepos | Select-Object -Unique)

    foreach ($repoPath in $candidateRepos) {
        $gitDir = Join-Path $repoPath '.git'
        if (-not (Test-Path -LiteralPath $gitDir)) {
            continue
        }

        try {
            $branch = (& git -C $repoPath branch --show-current 2>$null).Trim()
            if (-not [string]::IsNullOrWhiteSpace($branch)) {
                Write-Host "Development mode: Using current local branch '$branch' as ALM4DataverseRef" -ForegroundColor Yellow
                return $branch
            }

            $commit = (& git -C $repoPath rev-parse HEAD 2>$null).Trim()
            if ($commit -match '^[0-9a-f]{40}$') {
                Write-Host "Development mode: Repository is in detached HEAD; using commit '$commit' as ALM4DataverseRef" -ForegroundColor Yellow
                return $commit
            }
        }
        catch {
            throw "Could not resolve development ALM4DataverseRef from '$repoPath': $($_.Exception.Message)"
        }
    }

    Write-Host "Development mode: Could not resolve current branch/commit. Using '$FallbackRef' as ALM4DataverseRef" -ForegroundColor Yellow
    return $FallbackRef
}

Write-Section "Initialising setup"

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
    'PSMenu'                           = '0.2.0'
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

#endregion

#region Authentication

function Invoke-WithErrorHandling {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [Parameter(Mandatory)][string]$OperationName,
        [Parameter()][switch]$AllowSkip
    )

    while ($true) {
        try {
            # Execute the script block and return its result
            return & $ScriptBlock
        }
        catch {
            Write-Host "`n" -NoNewline
            Write-Host "ERROR in $OperationName" -ForegroundColor Red -BackgroundColor Black
            Write-Host "="*80 -ForegroundColor Red
            Write-Host "Error Type: $($_.Exception.GetType().Name)" -ForegroundColor Yellow
            Write-Host "Error Message: $($_.Exception.Message)" -ForegroundColor Yellow
            
            if ($_.ScriptStackTrace) {
                Write-Host "`nStack Trace:" -ForegroundColor DarkGray
                Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
            }
            
            if ($_.InvocationInfo.PositionMessage) {
                Write-Host "`nLocation:" -ForegroundColor DarkGray
                Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor DarkGray
            }
            
            Write-Host "="*80 -ForegroundColor Red
            Write-Host ""

            # Build menu options
            $options = @('Retry')
            if ($AllowSkip) {
                $options += 'Skip (Not Recommended)'
            }
            $options += 'Abort Setup'

            $choice = Select-FromMenu -Title "How would you like to proceed?" -Items $options
            
            if ($null -eq $choice) {
                Write-Host "Setup aborted by user." -ForegroundColor Yellow
                throw "Setup aborted by user."
            }

            switch ($options[$choice]) {
                'Retry' {
                    Write-Host "Retrying $OperationName..." -ForegroundColor Cyan
                    continue
                }
                'Skip (Not Recommended)' {
                    Write-Host "Skipping $OperationName. This may cause issues later." -ForegroundColor Yellow
                    return $null
                }
                'Abort Setup' {
                    Write-Host "Setup aborted by user." -ForegroundColor Yellow
                    throw "Setup aborted by user after error in $OperationName"
                }
            }
        }
    }
}

function Get-AuthToken {
    param(
        [Parameter(Mandatory)][string]$ResourceUrl,
        [Parameter()][string]$TenantId,
        [Parameter()][string]$ClientId = '1950a258-227b-4e31-a9cf-717495945fc2', # Azure PowerShell Client ID
        [Parameter()][switch]$ForceInteractive,
        [Parameter()][string]$PreferredUsername,
        [Parameter()][switch]$ListAccountsOnly
    )

    # Try to load the assembly using LoadWithPartialName as requested
    [void][System.Reflection.Assembly]::LoadWithPartialName("Microsoft.Identity.Client")

    # If the type is still not available, try to load it explicitly from the Rnwood module
    try {
        [void][Microsoft.Identity.Client.PublicClientApplicationBuilder]
    }
    catch {
        Write-Host "Type not found, attempting to load from module..." -ForegroundColor Yellow
        $module = Get-Module -Name "Rnwood.Dataverse.Data.PowerShell"
        if ($module) {
            $base = $module.ModuleBase
            $dllPath = $null
            
            if ($PSVersionTable.PSEdition -eq 'Core') {
                $dllPath = Join-Path $base "cmdlets\net8.0\Microsoft.Identity.Client.dll"
                if (-not (Test-Path $dllPath)) {
                    $dllPath = Join-Path $base "cmdlets\netcoreapp3.1\Microsoft.Identity.Client.dll"
                }
            }
            else {
                $dllPath = Join-Path $base "cmdlets\net462\Microsoft.Identity.Client.dll"
            }

            if ($dllPath -and (Test-Path $dllPath)) {
                Write-Host "Loading MSAL from: $dllPath" -ForegroundColor DarkGray
                Add-Type -Path $dllPath
            }
            else {
                $allDlls = Get-ChildItem $base -Recurse -Filter "Microsoft.Identity.Client.dll"
                $found = $null
                if ($PSVersionTable.PSEdition -eq 'Core') {
                    $found = $allDlls | Where-Object { $_.FullName -match 'netcore|netstandard|net\d\.\d' } | Select-Object -First 1
                }
                else {
                    $found = $allDlls | Where-Object { $_.FullName -match 'net4' } | Select-Object -First 1
                }
                
                if ($found) {
                    Write-Host "DLL found recursively at: $($found.FullName)" -ForegroundColor Yellow
                    Add-Type -Path $found.FullName
                }
            }
        }
    }

    $ResourceUrl = $ResourceUrl.TrimEnd('/')
    $scopes = [string[]]@("$ResourceUrl/.default")
    
    $app = $null
    try {
        $app = Get-Variable -Name "MsalApp" -Scope Script -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Value
    }
    catch {}

    if (-not $app) {
        $builder = [Microsoft.Identity.Client.PublicClientApplicationBuilder]::Create($ClientId)
        
        $authority = "https://login.microsoftonline.com/common"
        if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
            $authority = "https://login.microsoftonline.com/$TenantId"
        }
        
        $builder = $builder.WithAuthority($authority)
        $builder = $builder.WithRedirectUri("http://localhost")
        $app = $builder.Build()
        
        Set-Variable -Name "MsalApp" -Value $app -Scope Script
    }

    # Persist token cache between script runs so cached Azure logins can be reused.
    $msalCacheDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ALM4Dataverse'
    New-DirectoryIfMissing -Path $msalCacheDir
    $msalCachePath = Join-Path $msalCacheDir 'msal-token-cache.bin'

    try {
        if (Test-Path -LiteralPath $msalCachePath) {
            $cacheBytes = [System.IO.File]::ReadAllBytes($msalCachePath)
            if ($cacheBytes -and $cacheBytes.Length -gt 0) {
                $app.UserTokenCache.DeserializeMsalV3($cacheBytes, $true)
            }
        }
    }
    catch {
        Write-Warning "Failed to load MSAL token cache from '$msalCachePath': $($_.Exception.Message)"
    }

    $accounts = @($app.GetAccountsAsync().GetAwaiter().GetResult())

    if ($ListAccountsOnly) {
        return @($accounts | ForEach-Object { $_.Username } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    }

    $account = $null
    if (-not [string]::IsNullOrWhiteSpace($PreferredUsername)) {
        $account = $accounts | Where-Object { $_.Username -ieq $PreferredUsername } | Select-Object -First 1
        if (-not $account) {
            Write-Host "Preferred cached Azure login '$PreferredUsername' was not found; using the default cached account selection." -ForegroundColor Yellow
        }
    }

    if (-not $account) {
        $account = $accounts | Select-Object -First 1
    }

    $authResult = $null

    try {
        if (-not $ForceInteractive -and $account) {
            $authResult = $app.AcquireTokenSilent($scopes, $account).ExecuteAsync().GetAwaiter().GetResult()
        }
    }
    catch {
        # Silent acquisition failed, try interactive
    }

    if (-not $authResult) {
        try {
            $interactiveBuilder = $app.AcquireTokenInteractive($scopes)

            if ($ForceInteractive) {
                $interactiveBuilder = $interactiveBuilder.WithPrompt([Microsoft.Identity.Client.Prompt]::SelectAccount)
            }

            if (-not [string]::IsNullOrWhiteSpace($PreferredUsername)) {
                $interactiveBuilder = $interactiveBuilder.WithLoginHint($PreferredUsername)
            }

            $authResult = $interactiveBuilder.ExecuteAsync().GetAwaiter().GetResult()
        }
        catch {
            Write-Error "Failed to acquire token interactively: $_"
            throw
        }
    }

    try {
        $updatedCacheBytes = $app.UserTokenCache.SerializeMsalV3()
        if ($updatedCacheBytes -and $updatedCacheBytes.Length -gt 0) {
            [System.IO.File]::WriteAllBytes($msalCachePath, $updatedCacheBytes)
        }
    }
    catch {
        Write-Warning "Failed to save MSAL token cache to '$msalCachePath': $($_.Exception.Message)"
    }

    return $authResult
}

#endregion

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
    
    if ($Body) {
        $json = $Body | ConvertTo-Json -Depth 10 -Compress
        $ghArgs += @('--input', '-')
        
        $result = $json | & gh @ghArgs 2>&1
    }
    else {
        $result = & gh @ghArgs 2>&1
    }
    
    if ($LASTEXITCODE -ne 0) {
        $errText = $result -join "`n"
        if ($AllowNotFound -and ($errText -match '404' -or $errText -match 'Not Found')) {
            return $null
        }
        throw "gh api call failed (HTTP $LASTEXITCODE): $errText"
    }
    
    if ($result) {
        try {
            return $result | ConvertFrom-Json
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
        Creates a GitHub repository environment if it does not already exist.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$EnvironmentName
    )

    Write-Host "Ensuring GitHub environment '$EnvironmentName'..." -ForegroundColor DarkGray

    # Check if environment already exists
    $existing = Invoke-GhApi -Endpoint "repos/$Owner/$Repo/environments/$([Uri]::EscapeDataString($EnvironmentName))" -AllowNotFound

    if ($existing) {
        Write-Host "Environment '$EnvironmentName' already exists."
        return $existing
    }

    Write-Host "Creating environment '$EnvironmentName'..." -ForegroundColor Yellow
    $body = @{ wait_timer = 0 }
    $created = Invoke-GhApi -Endpoint "repos/$Owner/$Repo/environments/$([Uri]::EscapeDataString($EnvironmentName))" -Method 'PUT' -Body $body

    Write-Host "Created environment '$EnvironmentName'."
    return $created
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

    $result = $SecretValue | & gh secret set $SecretName `
        --repo "$Owner/$Repo" `
        --env $EnvironmentName `
        --body - 2>&1

    if ($LASTEXITCODE -ne 0) {
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

    $result = & gh variable set $VariableName `
        --repo "$Owner/$Repo" `
        --env $EnvironmentName `
        --body $VariableValue 2>&1

    if ($LASTEXITCODE -ne 0) {
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

    $result = $SecretValue | & gh secret set $SecretName `
        --repo "$Owner/$Repo" `
        --body - 2>&1

    if ($LASTEXITCODE -ne 0) {
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

    $result = & gh variable set $VariableName `
        --repo "$Owner/$Repo" `
        --body $VariableValue 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to set repo variable '$VariableName': $($result -join "`n")"
    }
    Write-Host "Set repo-level variable '$VariableName'." -ForegroundColor DarkGray
}

function Get-GitHubRepoList {
    <#
    .SYNOPSIS
        Returns a list of repos the authenticated user has write access to.
    #>
    [CmdletBinding()]
    param()

    $result = & gh repo list --json nameWithOwner,name,owner,defaultBranchRef --limit 100 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to list repositories: $($result -join "`n")"
    }
    return $result | ConvertFrom-Json
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

    $result = & gh repo view "$Owner/$Repo" --json nameWithOwner,name,owner,defaultBranchRef 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to get repository '$Owner/$Repo': $($result -join "`n")"
    }
    return $result | ConvertFrom-Json
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
        [Parameter(Mandatory)][string]$Ref
    )

    & git ls-remote --exit-code $RemoteName $Ref | Out-Null
    if ($LASTEXITCODE -eq 2) {
        throw "Could not resolve reference '$Ref' from remote '$RemoteName'."
    }
    if ($LASTEXITCODE -ne 0) {
        throw "git ls-remote failed for '$RemoteName' with exit code $LASTEXITCODE"
    }

    $lsRemoteOutput = (& git ls-remote $RemoteName $Ref | Select-Object -First 1)
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
        Ensures the user has a fork of the ALM4Dataverse shared workflow repository and optionally updates it from upstream.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UpstreamFullName,
        [Parameter(Mandatory)][string]$ForkOwner,
        [Parameter(Mandatory)][string]$UpstreamGitSource,
        [Parameter(Mandatory)][string]$Reference
    )

    $existingForks = @(Get-GitHubForksOfRepositoryForOwner -Owner $ForkOwner -UpstreamFullName $UpstreamFullName)
    $ownedRepos = @(Get-GitHubOwnedReposForOwner -Owner $ForkOwner)

    $menuItems = @()
    $menuActions = @()

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

    foreach ($repo in $nonForkRepos) {
        $menuItems += "Use existing repository: $($repo.full_name)"
        $menuActions += @{ Type = 'UseExisting'; FullName = $repo.full_name }
    }

    $menuItems += 'Create a new repository'
    $menuActions += @{ Type = 'CreateNew' }

    $selection = Select-FromMenu -Title "Select shared workflow repository" -Items $menuItems
    if ($null -eq $selection) {
        throw "No shared workflow repository selected."
    }

    $selectedForkFullName = $null
    $selectedAction = $menuActions[$selection]
    if ($selectedAction.Type -eq 'UseExisting') {
        $selectedForkFullName = $selectedAction.FullName
    }

    if (-not $selectedForkFullName) {
        $upstreamParts = $UpstreamFullName.Split('/', 2)
        $defaultForkName = $upstreamParts[1]

        while ($true) {
            $forkName = Read-Host "Fork repository name [$defaultForkName]"
            if ([string]::IsNullOrWhiteSpace($forkName)) {
                $forkName = $defaultForkName
            }

            if ($forkName -match '^[A-Za-z0-9._-]+$') {
                break
            }

            Write-Warning "Repository name contains invalid characters. Use letters, numbers, dot (.), underscore (_), or hyphen (-)."
        }

        $selectedForkFullName = "$ForkOwner/$forkName"
        Write-Host "Creating fork '$selectedForkFullName' from '$UpstreamFullName'..." -ForegroundColor Yellow

        $createArgs = @('repo', 'fork', $UpstreamFullName, '--clone=false', '--fork-name', $forkName)
        $createResult = & gh @createArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            $errText = $createResult -join "`n"
            if ($errText -match 'already exists') {
                Write-Host "Repository '$selectedForkFullName' already exists; continuing." -ForegroundColor Yellow
            }
            else {
                throw "Failed to create fork '$selectedForkFullName': $errText"
            }
        }
    }

    $forkParts = $selectedForkFullName.Split('/', 2)
    $forkOwnerName = $forkParts[0]
    $forkRepoName = $forkParts[1]
    $forkRepo = Get-GitHubRepo -Owner $forkOwnerName -Repo $forkRepoName

    $defaultBranch = 'main'
    if ($forkRepo.defaultBranchRef -and $forkRepo.defaultBranchRef.name) {
        $defaultBranch = $forkRepo.defaultBranchRef.name
    }

    $workParent = Join-Path $env:TEMP ("ALM4Dataverse-ForkSync-" + [guid]::NewGuid().ToString('n'))
    $workRoot = Join-Path $workParent 'repo'
    New-DirectoryIfMissing -Path $workParent

    $didPushLocation = $false
    try {
        Write-Host "Checking fork '$selectedForkFullName' against upstream '$UpstreamFullName'..." -ForegroundColor DarkGray

        & gh repo clone $selectedForkFullName $workRoot 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to clone fork '$selectedForkFullName'."
        }

        Push-Location $workRoot
        $didPushLocation = $true

        & git checkout $defaultBranch 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            & git checkout -b $defaultBranch "origin/$defaultBranch" 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to check out fork default branch '$defaultBranch'."
            }
        }

        # Reset upstream remote to the configured source
        & git remote remove upstream 2>$null | Out-Null
        & git remote add upstream $UpstreamGitSource 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to add upstream remote '$UpstreamGitSource'."
        }

        & git fetch upstream 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to fetch upstream remote."
        }

        $upstreamRef = Resolve-GitTargetRefFromRemote -RemoteName 'upstream' -Ref $Reference

        $localHash = (& git rev-parse HEAD).Trim()
        $upstreamHash = (& git rev-parse $upstreamRef).Trim()

        if ($localHash -eq $upstreamHash) {
            Write-Host "Fork is already up to date for ref '$Reference'."
        }
        else {
            & git merge-base --is-ancestor HEAD $upstreamRef
            $canFastForward = ($LASTEXITCODE -eq 0)

            if ($canFastForward) {
                if (Read-YesNo -Prompt "Updates are available from upstream (fast-forward). Update '$selectedForkFullName'?" ) {
                    Write-Host "Fast-forwarding fork..." -ForegroundColor Yellow
                    & git merge --ff-only $upstreamRef 2>&1 | Out-Host
                    if ($LASTEXITCODE -ne 0) { throw "Git merge failed." }

                    & git push origin $defaultBranch 2>&1 | Out-Host
                    if ($LASTEXITCODE -ne 0) { throw "Git push failed." }

                    Write-Host "Fork updated successfully."
                }
            }
            else {
                & git merge-base --is-ancestor $upstreamRef HEAD
                $isAhead = ($LASTEXITCODE -eq 0)

                if ($isAhead) {
                    Write-Host "Fork is ahead of upstream for ref '$Reference'." -ForegroundColor Yellow
                }
                else {
                    if (Read-YesNo -Prompt "Fork '$selectedForkFullName' has diverged from upstream. Attempt rebase to update?" ) {
                        Write-Host "Rebasing fork onto upstream ref..." -ForegroundColor Yellow
                        & git rebase $upstreamRef 2>&1 | Out-Host
                        if ($LASTEXITCODE -ne 0) {
                            throw "Git rebase failed - resolve conflicts manually in '$selectedForkFullName'."
                        }

                        Write-Host "Pushing rebased branch (force-with-lease)..." -ForegroundColor Yellow
                        & git push --force-with-lease origin $defaultBranch 2>&1 | Out-Host
                        if ($LASTEXITCODE -ne 0) { throw "Git push failed." }

                        Write-Host "Fork updated successfully."
                    }
                }
            }
        }
    }
    finally {
        if ($didPushLocation) {
            Pop-Location
        }
        try { Remove-Item -LiteralPath $workParent -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }

    return Get-GitHubRepo -Owner $forkOwnerName -Repo $forkRepoName
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

    $owner = Read-Host "Repository owner (user or org) [$DefaultOwner]"
    if ([string]::IsNullOrWhiteSpace($owner)) {
        $owner = $DefaultOwner
    }

    $repoName = $null
    while ($true) {
        $repoName = Read-Host "New repository name"
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
    $visibilitySelection = Select-FromMenu -Title "Select repository visibility" -Items $visibilityItems
    if ($null -eq $visibilitySelection) {
        throw "No repository visibility selected."
    }

    $visibilityFlag = if ($visibilitySelection -eq 0) { '--private' } else { '--public' }
    $repoFullName = "$owner/$repoName"

    Write-Host "Creating repository '$repoFullName'..." -ForegroundColor Yellow
    $createArgs = @('repo', 'create', $repoFullName, $visibilityFlag, '--add-readme')
    $result = & gh @createArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create repository '$repoFullName': $($result -join "`n")"
    }

    Write-Host "Created repository '$repoFullName'." -ForegroundColor Green
    return Get-GitHubRepo -Owner $owner -Repo $repoName
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
        $secretBody = @{
            passwordCredential = @{
                displayName = "ALM4Dataverse Setup"
            }
        }
        $secretUri = "https://graph.microsoft.com/v1.0/applications/$($app.id)/addPassword"
        $secretResponse = Invoke-RestMethod -Uri $secretUri -Headers $headers -Method Post -Body ($secretBody | ConvertTo-Json)
        $result.ClientSecret = $secretResponse.secretText
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
        [Parameter()][string]$EnvironmentName
    )

    # Build Menu
    $menuItems  = @()
    $menuActions = @()

    $menuItems  += "Create new App Registration (Entra ID)"
    $menuActions += @{ Type = 'CreateNew' }

    $menuItems  += "Enter existing App Registration details"
    $menuActions += @{ Type = 'Manual' }

    foreach ($c in $ExistingCredentials) {
        $menuItems  += "Reuse: $($c.Name) ($($c.ApplicationId))"
        $menuActions += @{ Type = 'Cached'; Creds = $c }
    }

    Write-Host ""
    Write-Host "App Registration credentials are used to authenticate the workflow to Dataverse." -ForegroundColor Green
    Write-Host "Learn more: https://github.com/ALM4Dataverse/ALM4Dataverse/tree/$ALM4DataverseRef/docs/config/github-secrets.md" -ForegroundColor Green
    Write-Host ""
    
    $selection = Select-FromMenu -Title "Select App Registration credentials for '$EnvironmentName'" -Items $menuItems
    if ($null -eq $selection) { throw "No credential selected." }

    $action = $menuActions[$selection]

    if ($action.Type -eq 'Cached') {
        return $action.Creds
    }
    elseif ($action.Type -eq 'CreateNew') {
        # Prompt for authentication type
        Write-Host ""
        $authTypeItems = @(
            "Workload Identity Federation (recommended, no secrets)",
            "Service Principal with Secret (traditional)"
        )
        $authTypeSelection = Select-FromMenu -Title "Select authentication type for the new App Registration" -Items $authTypeItems
        if ($null -eq $authTypeSelection) { throw "No authentication type selected." }
        
        $authType = if ($authTypeSelection -eq 0) { 'WIF' } else { 'Secret' }
        
        $appName = "$RepoName - $EnvironmentName - deployment"
        
        return New-EntraIdApplication -DisplayName $appName -TenantId $TenantId -AuthType $authType
    }
    else { # Manual
        Write-Host "Enter App Registration details:" -ForegroundColor Cyan
        $name = Read-Host "Friendly name (for reuse reference)"
        if ([string]::IsNullOrWhiteSpace($name)) { $name = "Credential-" + (Get-Date -Format "HHmm") }
        
        while ($true) {
            $appId = Read-Host "Application ID (Client ID)"
            if ($appId -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
                break
            }
            else {
                Write-Warning "The Application ID must be a valid GUID. Please try again."
            }
        }

        while ($true) {
            $appObjectId = Read-Host "Application Object ID (from Entra ID > App registrations > Overview, NOT the 'Object ID' of the enterprise app)"
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
        $authTypeSelection = Select-FromMenu -Title "Select authentication type" -Items $authTypeItems
        if ($null -eq $authTypeSelection) { throw "No authentication type selected." }
        
        $authType = if ($authTypeSelection -eq 0) { 'WIF' } else { 'Secret' }
        
        $secret = $null
        if ($authType -eq 'Secret') {
            while ($true) {
                $secretSecure = Read-Host "Client Secret" -AsSecureString
                $bstr   = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secretSecure)
                $secret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
                
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

function Select-DataverseEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter()][string]$ExcludeUrl
    )

    Write-Host ""
    Write-Host "Retrieving Dataverse environments..." -ForegroundColor Yellow
    
    $environments = @(Get-DataverseEnvironment -AccessToken { 
        param($resource)
        if (-not $resource) { $resource = 'https://globaldisco.crm.dynamics.com/' }
        try {
            $uri = [System.Uri]$resource
            $resource = $uri.GetLeftPart([System.UriPartial]::Authority)
        } catch {}
        $auth = Get-AuthToken -ResourceUrl $resource -TenantId $TenantId
        return $auth.AccessToken
    })

    if ($environments.Count -eq 0) {
        throw "No Dataverse environments found. Ensure the account has access to at least one environment."
    }

    if (-not [string]::IsNullOrWhiteSpace($ExcludeUrl)) {
        $environments = @($environments | Where-Object {
            $_.Endpoints["WebApplication"] -ne $ExcludeUrl
        })
    }

    if ($environments.Count -eq 0) {
        throw "No selectable Dataverse environments found (all were excluded)."
    }

    $envNames = @($environments | ForEach-Object { 
        "$($_.FriendlyName) ($($_.Endpoints['WebApplication']))" 
    })
    
    $index = Select-FromMenu -Title $Prompt -Items $envNames
    if ($null -eq $index) { return $null }

    return $environments[$index]
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
    Write-Host "Service Account credentials are used for ownership and licensing of Cloud Flows." -ForegroundColor Green
    Write-Host "This must be a licensed user account with System Administrator role." -ForegroundColor Green
    Write-Host "Learn more: https://github.com/ALM4Dataverse/ALM4Dataverse/tree/$ALM4DataverseRef/docs/config/github-secrets.md" -ForegroundColor Green
    Write-Host ""
    
    $selection = Select-FromMenu -Title "Select Dataverse Service Account for '$EnvironmentName'" -Items $menuItems
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
            $upn = Read-Host "Service Account UPN (e.g., serviceaccount@contoso.com)"
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
        [Parameter()][string]$ExistingConfigPath
    )
    
    Write-Host ""
    Write-Host "When prompted, select your Dataverse DEV environment containing the solutions you want to manage." -ForegroundColor Green
    Write-Host ""

    $selectedEnv = Select-DataverseEnvironment -Prompt "Select your DEV environment"
    if (-not $selectedEnv) { throw "No environment selected." }

    $devEnvUrl = $selectedEnv.Endpoints["WebApplication"]
    Write-Host "Selected: $($selectedEnv.FriendlyName) ($devEnvUrl)" -ForegroundColor Cyan

    $connection = Get-DataverseConnection -Url $devEnvUrl -AccessToken { 
        param($resource)
        if (-not $resource) { $resource = 'https://globaldisco.crm.dynamics.com/' }
        try {
            $uri = [System.Uri]$resource
            $resource = $uri.GetLeftPart([System.UriPartial]::Authority)
        } catch {}
        $auth = Get-AuthToken -ResourceUrl $resource -TenantId $TenantId
        return $auth.AccessToken
    }
    
    if (-not $connection) { throw "Failed to connect to Dataverse environment." }
    
    Write-Host "Connected to: $($connection.ConnectedOrgFriendlyName)"
    Write-Host "Retrieving solutions..." -ForegroundColor Yellow
    
    $allSolutions = Get-DataverseRecord -Connection $connection -TableName 'solution' -Columns @('solutionid','uniquename','friendlyname','version','ismanaged') -FilterValues @{
        'isvisible' = $true
        'ismanaged' = $false
    }
    
    if (-not $allSolutions -or $allSolutions.Count -eq 0) {
        Write-Host "No unmanaged solutions found in the environment." -ForegroundColor Yellow
        return @{ Solutions = @(); EnvironmentUrl = $devEnvUrl }
    }
    
    $userSolutions = @($allSolutions | Where-Object { 
        $_.uniquename -notmatch '^(Default|Active|Basic|msdyn_|ms|MicrosoftFlow|PowerPlatform)' -and 
        $_.uniquename -ne 'System' 
    } | Sort-Object friendlyname)
    
    if ($userSolutions.Count -eq 0) {
        Write-Host "No user-created solutions found." -ForegroundColor Yellow
        return @{ Solutions = @(); EnvironmentUrl = $devEnvUrl }
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

    while ($true) {
        Clear-Host
        Write-Host "Solutions Configuration" -ForegroundColor Cyan
        Write-Host "=======================" -ForegroundColor Cyan
        Write-Host ""
        
        if ($selectedSolutions.Count -eq 0) {
            Write-Host "No solutions selected." -ForegroundColor DarkGray
        }
        else {
            Write-Host "Selected solutions (in dependency order):" -ForegroundColor Green
            $selectedSolutions | Select-Object @{N='Friendly Name';E={$_.friendlyname}}, @{N='Unique Name';E={$_.uniquename}}, Version | Format-Table -AutoSize | Out-Host
        }
        Write-Host ""

        $menuItems = @('Add a solution', 'Clear list')
        if ($selectedSolutions.Count -gt 0) { $menuItems += 'Done' }

        $selection = Select-FromMenu -Title "Manage solutions" -Items $menuItems

        if ($null -eq $selection) { 
            if ($selectedSolutions.Count -gt 0) { break }
            return @{ Solutions = @(); EnvironmentUrl = $devEnvUrl } 
        }

        $action = $menuItems[$selection]

        switch ($action) {
            'Add a solution' {
                $available = @($userSolutions | Where-Object { 
                    $u = $_.uniquename
                    -not ($selectedSolutions | Where-Object { $_.uniquename -eq $u })
                })

                if ($available.Count -eq 0) {
                    Write-Host "All solutions already selected." -ForegroundColor Yellow
                    Start-Sleep -Seconds 2
                    continue
                }

                $solMenu = @($available | ForEach-Object { "$($_.friendlyname) ($($_.uniquename))" })
                $solMenu += "--- Cancel ---"

                $solIndex = Select-FromMenu -Title "Select a solution to add" -Items $solMenu
                if ($null -ne $solIndex -and $solIndex -lt $available.Count) {
                    $selectedSolutions += $available[$solIndex]
                }
            }
            'Clear list' {
                $selectedSolutions = @()
                Write-Host "List cleared." -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
            'Done' { break }
        }
        
        if ($action -eq 'Done') { break }
    }
    
    # Convert to alm-config.psd1 format
    $configSolutions = @()
    foreach ($sol in $selectedSolutions) {
        $configSolutions += @{ name = $sol.uniquename; deployUnmanaged = $false }
    }
    
    return @{ Solutions = $configSolutions; EnvironmentUrl = $devEnvUrl }
}

function Get-DeploymentEnvironmentsSelection {
    [CmdletBinding()]
    param(
        [Parameter()][string]$ExcludeUrl
    )

    $selectedEnvironments = @()

    while ($true) {
        Clear-Host
        Write-Host "Target Deployment Environments" -ForegroundColor Cyan
        Write-Host "==============================" -ForegroundColor Cyan
        Write-Host ""
        
        if ($selectedEnvironments.Count -eq 0) {
            Write-Host "No environments selected." -ForegroundColor DarkGray
        }
        else {
            Write-Host "Selected environments ($($selectedEnvironments.Count)):" -ForegroundColor Green
            $selectedEnvironments | Format-Table -Property ShortName, FriendlyName, Url -AutoSize | Out-Host
        }
        Write-Host ""

        $menuItems = @('Add an environment', 'Clear list')
        if ($selectedEnvironments.Count -gt 0) { $menuItems += 'Done' }

        $selection = Select-FromMenu -Title "Manage deployment environments" -Items $menuItems
        if ($null -eq $selection) { return $selectedEnvironments }

        $action = $menuItems[$selection]

        switch ($action) {
            'Add an environment' {
                try {
                    $selectedEnv = Select-DataverseEnvironment -Prompt "Select a Dataverse environment for deployment" -ExcludeUrl $ExcludeUrl
                    
                    if (-not $selectedEnv) { continue }

                    $url = $selectedEnv.Endpoints["WebApplication"]

                    if ($selectedEnvironments | Where-Object { $_.Url -ieq $url }) {
                        Write-Host "An environment with that URL is already selected." -ForegroundColor Red
                        Start-Sleep -Seconds 2
                        continue
                    }

                    Write-Host "Use a short deployment environment name (for example: TEST, UAT, PROD)." -ForegroundColor DarkGray

                    $shortName = Read-Host "Enter a short name for this environment (e.g. TEST, UAT, PROD)"
                    $shortName = $shortName.Trim()
                    if ([string]::IsNullOrWhiteSpace($shortName)) {
                        Write-Host "Short name is required." -ForegroundColor Red
                        Start-Sleep -Seconds 2
                        continue
                    }

                    if ($selectedEnvironments | Where-Object { $_.ShortName -ieq $shortName }) {
                        Write-Host "An environment with that short name is already selected." -ForegroundColor Red
                        Start-Sleep -Seconds 2
                        continue
                    }

                    $selectedEnvironments += [pscustomobject]@{
                        ShortName    = $shortName
                        FriendlyName = $selectedEnv.FriendlyName
                        Url          = $url
                    }
                }
                catch {
                    Write-Host "Failed to add environment: $_" -ForegroundColor Red
                    Start-Sleep -Seconds 3
                }
            }
            'Clear list' {
                $selectedEnvironments = @()
                Write-Host "List cleared." -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
            'Done' { return $selectedEnvironments }
        }
    }
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
        [Parameter(Mandatory)][string]$SharedWorkflowRef
    )

    if (-not (Test-Path -LiteralPath $SourceRoot)) {
        throw "Source folder not found: $SourceRoot"
    }

    Write-Section "Syncing workflow files into repository"
    Write-Host "Source: $SourceRoot" -ForegroundColor DarkGray
    Write-Host "Target: $TargetRoot" -ForegroundColor DarkGray

    $allSourceFiles = Get-ChildItem -LiteralPath $SourceRoot -Recurse -Force | Where-Object { -not $_.PSIsContainer }

    foreach ($file in $allSourceFiles) {
        $relativePath = $file.FullName.Substring($SourceRoot.Length).TrimStart('\', '/')
        $normalizedRelativePath = $relativePath -replace '\\','/'
        $destPath     = Join-Path $TargetRoot $relativePath

        $destDir = Split-Path -Parent $destPath
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }

        $sourceFileToUse = $file.FullName
        $isTempFile      = $false

        # Patch all shared workflow references (build/export/import/deploy/etc.) to the selected repository/ref.
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
                    $overwrite = Read-YesNo -Prompt "File '$relativePath' already exists and is different. Overwrite?" -DefaultNo
                    if ($overwrite) {
                        Copy-Item -LiteralPath $sourceFileToUse -Destination $destPath -Force
                    }
                    Copy-Item -LiteralPath $sourceFileToUse -Destination "$destPath.template" -Force
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
        [Parameter(Mandatory)][array]$Solutions,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $configPath = Join-Path $RepoRoot 'alm-config.psd1'

    if (-not (Test-Path $configPath)) {
        Write-Host "alm-config.psd1 not found; creating from template..." -ForegroundColor Yellow
        $templatePath = Join-Path $RepoRoot 'alm-config.psd1'

        # Write minimal alm-config.psd1
        $initial = "@{`n    solutions = @(`n    )`n}`n"
        Set-Content -LiteralPath $configPath -Value $initial -NoNewline
    }

    $configContent = Get-Content -LiteralPath $configPath -Raw

    $solutionsArray = "    solutions = @("
    if ($Solutions.Count -gt 0) {
        $solutionsArray += "`n"
        foreach ($solution in $Solutions) {
            $solutionsArray += "        @{`n"
            $solutionsArray += "            name = '$($solution.name)'`n"
            if ($solution.deployUnmanaged) {
                $solutionsArray += "            deployUnmanaged = `$true`n"
            }
            $solutionsArray += "        }`n"
        }
        $solutionsArray += "    )`n"
    }
    else {
        $solutionsArray += "`n    )`n"
    }

    $updatedContent = $configContent -replace '(?s)    solutions = @\([^)]*\)', $solutionsArray
    Set-Content -LiteralPath $configPath -Value $updatedContent -NoNewline
    Write-Host "Updated alm-config.psd1 with $($Solutions.Count) solution(s)."
}

#endregion

# ─────────────────────────────────────────────────────────────
#  MAIN SETUP FLOW
# ─────────────────────────────────────────────────────────────

Write-Section "Authenticating with GitHub"

Write-Host "Checking GitHub CLI authentication status..." -ForegroundColor Yellow
$ghStatus = & gh auth status --hostname github.com 2>&1
$hasExistingGitHubLogin = ($LASTEXITCODE -eq 0)

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

    $ghChoice = Select-FromMenu -Title "GitHub authentication" -Items $ghMenuItems
    if ($null -eq $ghChoice) {
        throw "No GitHub authentication option selected."
    }

    if ($ghChoice -eq 0) {
        Write-Host "Using existing GitHub login." -ForegroundColor Green
        Write-Host ($ghStatus -join "`n") -ForegroundColor DarkGray
    }
    else {
        Write-Host "Signing in with a different GitHub account..." -ForegroundColor Yellow
        & gh auth logout --hostname github.com --yes 2>&1 | Out-Host
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
Write-Host "Logged in as: $script:ghUser" -ForegroundColor Green

Write-Section "Authenticating with Azure"

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

    $azureAuthChoice = Select-FromMenu -Title "Azure authentication" -Items $azureAuthMenuItems
    if ($null -eq $azureAuthChoice) {
        throw "No Azure authentication option selected."
    }

    if ($azureAuthChoice -lt $cachedAzureAccounts.Count) {
        $preferredAzureUsername = $cachedAzureAccounts[$azureAuthChoice]
        Write-Host "Using cached Azure login: $preferredAzureUsername" -ForegroundColor Green
    }
    else {
        $forceAzureInteractive = $true
        Read-Host "Press Enter to open browser for Azure authentication..."
    }
}
else {
    Write-Host "No cached Azure login detected. Browser sign-in is required." -ForegroundColor Yellow
    Read-Host "Press Enter to open browser for Azure authentication..."
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
Write-Section "Ensuring Shared Workflow Repository"

$upstreamWorkflowRepoFullName = Resolve-GitHubRepoFullNameFromSource -Source $upstreamRepo -Fallback 'ALM4Dataverse/ALM4Dataverse'
$upstreamGitSource = Resolve-UpstreamGitRemoteSource -ConfiguredSource $upstreamRepo -GitHubFullName $upstreamWorkflowRepoFullName

Write-Host "Upstream workflow source: $upstreamWorkflowRepoFullName" -ForegroundColor DarkGray
Write-Host "Using ALM4Dataverse ref: $ALM4DataverseRef" -ForegroundColor DarkGray

$sharedWorkflowRepo = Invoke-WithErrorHandling -OperationName "Ensuring shared workflow repository fork" -ScriptBlock {
    Ensure-GitHubForkForSharedWorkflows `
        -UpstreamFullName $upstreamWorkflowRepoFullName `
        -ForkOwner $script:ghUser `
        -UpstreamGitSource $upstreamGitSource `
        -Reference $ALM4DataverseRef
}

$sharedWorkflowRepository = $sharedWorkflowRepo.nameWithOwner
$sharedWorkflowReference = 'main'
if ($sharedWorkflowRepo.defaultBranchRef -and $sharedWorkflowRepo.defaultBranchRef.name) {
    $sharedWorkflowReference = $sharedWorkflowRepo.defaultBranchRef.name
}

Write-Host "Shared workflow repository: $sharedWorkflowRepository" -ForegroundColor Green
Write-Host "Shared workflow reference (synced branch): $sharedWorkflowReference" -ForegroundColor Green

# ─────────────────────────────────────────────────────────────
Write-Section "Select GitHub Repository"

Write-Host "Fetching repositories you have write access to..." -ForegroundColor Yellow

$repos = @(Get-GitHubRepoList)
$selectedRepo = $null

$repos = @($repos | Sort-Object -Property nameWithOwner)
$repoMenuItems = @()
$repoMenuActions = @()

foreach ($repo in $repos) {
    $repoMenuItems += "Use existing repository: $($repo.nameWithOwner)"
    $repoMenuActions += @{ Type = 'UseExisting'; Repo = $repo }
}

$repoMenuItems += 'Create a new repository'
$repoMenuActions += @{ Type = 'CreateNew' }

$repoSelection = Select-FromMenu -Title "Select the repository to set up ALM4Dataverse in" -Items $repoMenuItems
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

# ─────────────────────────────────────────────────────────────
Write-Section "Cloning Repository"

$cloneRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ALM4Dataverse-GH-" + [guid]::NewGuid().ToString('n'))
New-DirectoryIfMissing -Path $cloneRoot

Invoke-WithErrorHandling -OperationName "Cloning repository" -ScriptBlock {
    Write-Host "Cloning $repoFullName to $cloneRoot..." -ForegroundColor Yellow
    & gh repo clone $repoFullName $cloneRoot -- --depth 1 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "gh repo clone failed." }
}

Push-Location $cloneRoot
try {
    # Ensure we are on the right branch
    & git checkout $defaultBranch 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        & git checkout -b $defaultBranch 2>&1 | Out-Null
    }

    # ─────────────────────────────────────────────────────────
    Write-Section "Copy Workflow Templates"

    $copyRoot = $null
    if ($PSScriptRoot) {
        $copyRoot = Join-Path $PSScriptRoot 'copy-to-your-repo'
    }

    if (-not $copyRoot -or -not (Test-Path $copyRoot)) {
        # Fetch templates from upstream
        Write-Host "Fetching workflow templates from ALM4Dataverse release..." -ForegroundColor Yellow
        $upstreamClone = Join-Path ([System.IO.Path]::GetTempPath()) ("ALM4Dataverse-Templates-" + [guid]::NewGuid().ToString('n'))
        New-DirectoryIfMissing -Path $upstreamClone

        try {
            & git clone --depth 1 --branch $ALM4DataverseRef `
                $upstreamGitSource `
                $upstreamClone 2>&1 | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "Failed to clone ALM4Dataverse templates." }
            $copyRoot = Join-Path $upstreamClone 'copy-to-your-repo'
        }
        finally {
            # We clean up $upstreamClone after usage
        }
    }

    Invoke-WithErrorHandling -OperationName "Copying workflow templates" -ScriptBlock {
        Copy-WorkflowTemplatesToRepo `
            -SourceRoot $copyRoot `
            -TargetRoot $cloneRoot `
            -Branch $defaultBranch `
            -SharedWorkflowRepository $sharedWorkflowRepository `
            -SharedWorkflowRef $sharedWorkflowReference
    } | Out-Null

    # ─────────────────────────────────────────────────────────
    Write-Section "Configure Solutions (alm-config.psd1)"

    $solutionResult = Invoke-WithErrorHandling -OperationName "Selecting solutions" -ScriptBlock {
        $existingConfigPath = Join-Path $cloneRoot 'alm-config.psd1'
        Get-DataverseSolutionsSelection -ExistingConfigPath $existingConfigPath
    }

    if ($solutionResult -and $solutionResult.Solutions.Count -gt 0) {
        Invoke-WithErrorHandling -OperationName "Updating alm-config.psd1" -ScriptBlock {
            Update-AlmConfigInRepoClone -Solutions $solutionResult.Solutions -RepoRoot $cloneRoot
        } | Out-Null
    }

    $devEnvUrl = if ($solutionResult) { $solutionResult.EnvironmentUrl } else { $null }

    # ─────────────────────────────────────────────────────────
    # Commit and push the workflow template + config changes
    & git add -A
    & git diff --cached --quiet
    $hasChanges = ($LASTEXITCODE -ne 0)

    if ($hasChanges) {
        Write-Host "Committing workflow templates and configuration..." -ForegroundColor Yellow
        & git config user.name "ALM4Dataverse Setup"
        & git config user.email "setup@alm4dataverse.local"
        & git commit -m "Add ALM4Dataverse GitHub Actions workflows"
        if ($LASTEXITCODE -ne 0) { throw "Git commit failed." }

        Write-Host "Pushing to origin/$defaultBranch..." -ForegroundColor Yellow
        & git push origin $defaultBranch 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Git push failed." }
        Write-Host "Repository updated successfully." -ForegroundColor Green
    }
    else {
        Write-Host "No changes to commit; repository already contains the required files." -ForegroundColor Green
    }
}
finally {
    Pop-Location
    try { Remove-Item -LiteralPath $cloneRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

# ─────────────────────────────────────────────────────────────
Write-Section "Configure Dev Environment GitHub Environment"

$script:cachedCredentials    = @()
$script:cachedServiceAccounts = @()

$devEnvShortName = "Dev-$defaultBranch"
Write-Host "Setting up GitHub environment '$devEnvShortName' for the DEV Dataverse environment." -ForegroundColor Green
Write-Host ""

if (-not $devEnvUrl) {
    $devEnvSelection = Select-DataverseEnvironment -Prompt "Select your DEV Dataverse environment"
    if ($devEnvSelection) {
        $devEnvUrl = $devEnvSelection.Endpoints["WebApplication"]
    }
}

if ($devEnvUrl) {
    Invoke-WithErrorHandling -OperationName "Setting up DEV GitHub environment" -ScriptBlock {
        [void](Ensure-GitHubEnvironment -Owner $repoOwner -Repo $repoName -EnvironmentName $devEnvShortName)

        $devCreds = Get-GitHubCredentialsForEnvironment `
            -ExistingCredentials $script:cachedCredentials `
            -TenantId $TenantId `
            -RepoName $repoName `
            -EnvironmentName $devEnvShortName

        $script:cachedCredentials += $devCreds

        # Configure WIF federated credential if using WIF
        if ($devCreds.AuthType -eq 'WIF' -and $devCreds.ApplicationObjectId) {
            $credName = ConvertTo-UrlSafeName -Name "gha-$repoName-env-$devEnvShortName"
            [void](Add-EntraIdFederatedCredential `
                -ApplicationObjectId $devCreds.ApplicationObjectId `
                -TenantId $TenantId `
                -Subject "repo:$repoFullName`:environment:$devEnvShortName" `
                -CredentialName $credName)
        }

        # Set GitHub environment variables/secrets (non-sensitive values as variables)
        Set-GitHubEnvironmentVariable -Owner $repoOwner -Repo $repoName -EnvironmentName $devEnvShortName `
            -VariableName "AZURE_CLIENT_ID" -VariableValue $devCreds.ApplicationId
        Set-GitHubEnvironmentVariable -Owner $repoOwner -Repo $repoName -EnvironmentName $devEnvShortName `
            -VariableName "AZURE_TENANT_ID" -VariableValue $devCreds.TenantId
        
        if ($devCreds.AuthType -eq 'Secret' -and $devCreds.ClientSecret) {
            Set-GitHubEnvironmentSecret -Owner $repoOwner -Repo $repoName -EnvironmentName $devEnvShortName `
                -SecretName "AZURE_CLIENT_SECRET" -SecretValue $devCreds.ClientSecret
        }

        Set-GitHubEnvironmentVariable -Owner $repoOwner -Repo $repoName -EnvironmentName $devEnvShortName `
            -VariableName "DATAVERSE_URL" -VariableValue $devEnvUrl

        # Service account
        $devServiceAccountUPN = Get-DataverseServiceAccountUPN `
            -ExistingServiceAccounts $script:cachedServiceAccounts `
            -EnvironmentName $devEnvShortName

        $script:cachedServiceAccounts += $devServiceAccountUPN

        Set-GitHubEnvironmentVariable -Owner $repoOwner -Repo $repoName -EnvironmentName $devEnvShortName `
            -VariableName "DATAVERSESERVICEACCOUNTUPN" -VariableValue $devServiceAccountUPN

        # Create Dataverse app user
        Ensure-DataverseApplicationUser -EnvironmentUrl $devEnvUrl -ApplicationId $devCreds.ApplicationId -TenantId $TenantId
        Ensure-DataverseServiceAccountUser -EnvironmentUrl $devEnvUrl -ServiceAccountUPN $devServiceAccountUPN -TenantId $TenantId
    } | Out-Null
}

# ─────────────────────────────────────────────────────────────
Write-Section "Configure Deployment Environments"

Write-Host "Select the Dataverse environments to deploy to (e.g. TEST, UAT, PROD)." -ForegroundColor Green
Write-Host "For each environment you will be prompted to configure credentials." -ForegroundColor Green
Write-Host ""

$deploymentEnvironments = Get-DeploymentEnvironmentsSelection -ExcludeUrl $devEnvUrl

if ($deploymentEnvironments.Count -eq 0) {
    Write-Host "No deployment environments selected. You can run this script again to add them later." -ForegroundColor Yellow
}
else {
    foreach ($env in $deploymentEnvironments) {
        Write-Section "Setting up environment: $($env.ShortName)"
        Write-Host "Dataverse URL: $($env.Url)" -ForegroundColor DarkGray
        Write-Host ""

        Invoke-WithErrorHandling -OperationName "Setting up environment $($env.ShortName)" -AllowSkip -ScriptBlock {
            [void](Ensure-GitHubEnvironment -Owner $repoOwner -Repo $repoName -EnvironmentName $env.ShortName)

            $creds = Get-GitHubCredentialsForEnvironment `
                -ExistingCredentials $script:cachedCredentials `
                -TenantId $TenantId `
                -RepoName $repoName `
                -EnvironmentName $env.ShortName

            $script:cachedCredentials += $creds

            # Configure WIF federated credential if using WIF
            if ($creds.AuthType -eq 'WIF' -and $creds.ApplicationObjectId) {
                $credName = ConvertTo-UrlSafeName -Name "gha-$repoName-env-$($env.ShortName)"
                [void](Add-EntraIdFederatedCredential `
                    -ApplicationObjectId $creds.ApplicationObjectId `
                    -TenantId $TenantId `
                    -Subject "repo:$repoFullName`:environment:$($env.ShortName)" `
                    -CredentialName $credName)
            }

            # Set GitHub environment variables/secrets (non-sensitive values as variables)
            Set-GitHubEnvironmentVariable -Owner $repoOwner -Repo $repoName -EnvironmentName $env.ShortName `
                -VariableName "AZURE_CLIENT_ID" -VariableValue $creds.ApplicationId
            Set-GitHubEnvironmentVariable -Owner $repoOwner -Repo $repoName -EnvironmentName $env.ShortName `
                -VariableName "AZURE_TENANT_ID" -VariableValue $creds.TenantId

            if ($creds.AuthType -eq 'Secret' -and $creds.ClientSecret) {
                Set-GitHubEnvironmentSecret -Owner $repoOwner -Repo $repoName -EnvironmentName $env.ShortName `
                    -SecretName "AZURE_CLIENT_SECRET" -SecretValue $creds.ClientSecret
            }

            Set-GitHubEnvironmentVariable -Owner $repoOwner -Repo $repoName -EnvironmentName $env.ShortName `
                -VariableName "DATAVERSE_URL" -VariableValue $env.Url

            # Service account
            $serviceAccountUPN = Get-DataverseServiceAccountUPN `
                -ExistingServiceAccounts $script:cachedServiceAccounts `
                -EnvironmentName $env.ShortName

            $script:cachedServiceAccounts += $serviceAccountUPN

            Set-GitHubEnvironmentVariable -Owner $repoOwner -Repo $repoName -EnvironmentName $env.ShortName `
                -VariableName "DATAVERSESERVICEACCOUNTUPN" -VariableValue $serviceAccountUPN

            # Create Dataverse app user
            Ensure-DataverseApplicationUser -EnvironmentUrl $env.Url -ApplicationId $creds.ApplicationId -TenantId $TenantId
            Ensure-DataverseServiceAccountUser -EnvironmentUrl $env.Url -ServiceAccountUPN $serviceAccountUPN -TenantId $TenantId
        } | Out-Null
    }
}

# ─────────────────────────────────────────────────────────────
Clear-Host
Write-Host "Setup completed successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "Access your GitHub repository at" -ForegroundColor Green
Write-Host "https://github.com/$repoFullName/actions" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Green
Write-Host "https://github.com/ALM4Dataverse/ALM4Dataverse/tree/$ALM4DataverseRef#getting-started" -ForegroundColor Green
