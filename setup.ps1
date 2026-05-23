
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

# Any changes must be also reflected in the docs/manual-setup.md file.

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

function Install-PortableGit {
    param(
        [Parameter(Mandatory)][string]$Destination
    )

    $gitDir = Join-Path $Destination "Git"
    $gitExe = Join-Path $gitDir "bin\git.exe"
    
    if (Test-Path $gitExe) {
        Write-Host "Git already available at: $gitExe"
        return $gitDir
    }

    Write-Host "Downloading portable Git..." -ForegroundColor Yellow
    $gitUrl = "https://github.com/git-for-windows/git/releases/download/v2.52.0.windows.1/PortableGit-2.52.0-64-bit.7z.exe"
    $gitInstaller = Join-Path $Destination "PortableGit.exe"
    
    try {
        # PowerShell 5.1 sometimes needs TLS 1.2 explicitly.
        try {
            if ($PSVersionTable.PSVersion.Major -lt 6) {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            }
        }
        catch {
            # Non-fatal; continue.
        }

        Invoke-WebRequest -Uri $gitUrl -OutFile $gitInstaller -UseBasicParsing
        
        if (-not (Test-Path $gitInstaller)) {
            throw "Failed to download Git installer"
        }

        Write-Host "Extracting portable Git to $gitDir..." -ForegroundColor Yellow
        New-DirectoryIfMissing -Path $gitDir
        
        # The .7z.exe is a self-extracting archive
        $extractArgs = @('-o"' + $gitDir + '"', '-y')
        $process = Start-Process -FilePath $gitInstaller -ArgumentList $extractArgs -Wait -NoNewWindow -PassThru
        
        if ($process.ExitCode -ne 0) {
            throw "Git extraction failed with exit code $($process.ExitCode)"
        }

        # Clean up installer
        Remove-Item $gitInstaller -Force -ErrorAction SilentlyContinue

        if (-not (Test-Path $gitExe)) {
            throw "Git extraction completed but git.exe not found at expected location"
        }

        Write-Host "Git extracted successfully to: $gitDir"
        return $gitDir
    }
    catch {
        Write-Host "Failed to install portable Git: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
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
        throw "This script appears to be running in development mode but alm-config-defaults.psd1 was not found at $configPath. Please download the released version from https://github.com/rnwood/ALM4Dataverse/releases/latest/download/setup.ps1"
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
        $upstreamRepo = 'https://github.com/rnwood/ALM4Dataverse.git'
    }
}

$requiredModules = @{
    'VSTeam'                           = '7.15.2'
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

# Download and install portable Git
$gitInstallDir = Install-PortableGit -Destination $TempModuleRoot
$gitBinDir = Join-Path $gitInstallDir "bin"

# Add Git to PATH for this session
if (-not ($env:PATH -split ';' | Where-Object { $_ -eq $gitBinDir })) {
    $env:PATH = "$gitBinDir;$env:PATH"
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
        [Parameter()][string]$ClientId = '1950a258-227b-4e31-a9cf-717495945fc2' # Azure PowerShell Client ID
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
                # PowerShell Core
                $dllPath = Join-Path $base "cmdlets\net8.0\Microsoft.Identity.Client.dll"
                if (-not (Test-Path $dllPath)) {
                    # Fallback or check for other net core versions if net8.0 isn't there
                    $dllPath = Join-Path $base "cmdlets\netcoreapp3.1\Microsoft.Identity.Client.dll"
                }
            }
            else {
                # PowerShell Desktop
                $dllPath = Join-Path $base "cmdlets\net462\Microsoft.Identity.Client.dll"
            }

            if ($dllPath -and (Test-Path $dllPath)) {
                Write-Host "Loading MSAL from: $dllPath" -ForegroundColor DarkGray
                Add-Type -Path $dllPath
            }
            else {
                Write-Host "MSAL DLL not found at expected path: $dllPath" -ForegroundColor Red
                # Fallback to recursive search
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
    
    # Use a script-scoped variable to persist the app instance and its token cache
    # Check if variable exists in script scope
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

    $accounts = $app.GetAccountsAsync().GetAwaiter().GetResult()
    $account = $accounts | Select-Object -First 1

    $authResult = $null

    try {
        if ($account) {
            $authResult = $app.AcquireTokenSilent($scopes, $account).ExecuteAsync().GetAwaiter().GetResult()
        }
    }
    catch {
        # Silent acquisition failed, try interactive
    }

    if (-not $authResult) {
        try {
            $authResult = $app.AcquireTokenInteractive($scopes).ExecuteAsync().GetAwaiter().GetResult()
        }
        catch {
            Write-Error "Failed to acquire token interactively: $_"
            throw
        }
    }

    return $authResult
}

Write-Section "Authenticating"

Write-Host "To enable automated setup setup, we need to authenticate with the necessary services." -ForegroundColor Green
Write-Host ""
Write-Host "When prompted, please log in with an account that has access to:" -ForegroundColor Green
Write-Host "- Your Azure DevOps organization/project (PROJECT administrator role for existing project, ORGANISATION OWNER role if you want to create a new project)" -ForegroundColor Green
Write-Host "- Your Dataverse DEV environment (SYSTEM ADMINISTRATOR role)" -ForegroundColor Green
Write-Host ""
Read-Host "Press Enter to open browser for authentication..."


# Azure DevOps resource for AAD token acquisition.
$adoResourceUrl = '499b84ac-1321-427f-aa17-267ca6975798'

$authResult = Invoke-WithErrorHandling -OperationName "Authentication" -ScriptBlock {
    $result = Get-AuthToken -ResourceUrl $adoResourceUrl -TenantId $TenantId
    
    if (-not $result -or -not $result.AccessToken) {
        throw "Failed to acquire an Azure DevOps access token."
    }
    
    return $result
}

$adoAuthResult = $authResult
$adoAccessToken = [pscustomobject]@{ Token = $adoAuthResult.AccessToken }
$secureToken = ConvertTo-SecureString -String $adoAccessToken.Token -AsPlainText -Force

#endregion

#region Azure DevOps Setup

function ConvertTo-AzDoOrganizationName {
    param([Parameter(Mandatory)][string]$InputText)

    $text = $InputText.Trim()

    # Accept:
    # - myorg
    # - https://dev.azure.com/myorg
    # - https://dev.azure.com/myorg/
    # - dev.azure.com/myorg
    if ($text -match 'dev\.azure\.com/([^/]+)') {
        return $Matches[1]
    }

    # Also accept legacy Visual Studio URLs like https://myorg.visualstudio.com
    if ($text -match '^https?://([^\.]+)\.visualstudio\.com/?$') {
        return $Matches[1]
    }

    return $text
}

function New-AzDoProject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter()][string]$Visibility = 'private'
    )

    $ProjectName = $ProjectName.Trim()
    if ([string]::IsNullOrWhiteSpace($ProjectName)) {
        throw "Project name cannot be empty."
    }

    Write-Section "Creating new Azure DevOps project"
    Write-Host "Project: $ProjectName" -ForegroundColor Cyan

    $processes = @(Get-VSTeamProcess)
    if ($processes.Count -eq 0) {
        throw "Unable to list Azure DevOps processes to create a project. Verify permissions in the organization."
    }

    # Prefer Agile if present, otherwise first.
    $defaultProcess = $processes | Where-Object { $_.name -eq 'Agile' } | Select-Object -First 1
    if (-not $defaultProcess) {
        $defaultProcess = $processes | Select-Object -First 1
    }

    $processNames = @($processes | Sort-Object -Property name | ForEach-Object { $_.name })
    $selectedProcessName = $defaultProcess.name

    # Let user choose the process template.
    $procIndex = Select-FromMenu -Title "Select a process (template) for the new project" -Items $processNames
    if ($null -ne $procIndex) {
        $selectedProcessName = $processNames[$procIndex]
    }

    $selectedProcess = $processes | Where-Object { $_.name -eq $selectedProcessName } | Select-Object -First 1
    if (-not $selectedProcess -or -not $selectedProcess.id) {
        throw "Unable to resolve selected process '$selectedProcessName'."
    }

    # Use VSTeam command to create project - it handles async operation polling automatically
    Write-Host "Creating project using process template: $selectedProcessName" -ForegroundColor Yellow
    
    try {
        # Note: Add-VSTeamProject uses -ProjectName instead of -Name and doesn't have VersionControlSource
        $addParams = @{
            ProjectName     = $ProjectName
            ProcessTemplate = $selectedProcessName
            Visibility      = $Visibility
        }
        
        
        $created = Add-VSTeamProject @addParams
        
        if ($created -and $created.name) {
            Write-Host "Project '$ProjectName' created successfully."
            return $created
        }
        else {
            throw "Project creation returned no result."
        }
    }
    catch {
        Write-Host "Failed to create project '$ProjectName': $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

function Test-AzDoGitRepositoryHasCommits {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$RepositoryId
    )

    # Use VSTeam command to get commits - if repo is empty, no commits are returned
    try {
        $commits = @(Get-VSTeamGitCommit -ProjectName $Project -RepositoryId $RepositoryId -Top 1 -ErrorAction SilentlyContinue)
        return ($commits.Count -gt 0)
    }
    catch {
        # If we can't get commits, assume empty repo
        return $false
    }
}

function Start-AzDoGitRepositoryImport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$RepositoryId,
        [Parameter(Mandatory)][string]$SourceGitUrl
    )

    # Use Invoke-VSTeamRequest since VSTeam doesn't support repository import directly
    $resource = "git/repositories/$RepositoryId/importRequests"
    $body = @{
        parameters = @{
            gitSource = @{
                url = $SourceGitUrl
            }
        }
    }
    return Invoke-VSTeamRequest -Method POST -Resource $resource -Body ($body | ConvertTo-Json -Depth 10) -ContentType 'application/json' -Version '7.1-preview.1'
}

function Wait-AzDoGitRepositoryImport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$RepositoryId,
        [Parameter(Mandatory)][object]$ImportResponse,
        [Parameter()][int]$TimeoutSeconds = 600
    )

    $importId = $null
    foreach ($prop in @('importRequestId', 'id', 'ImportRequestId')) {
        if ($ImportResponse.PSObject.Properties.Name -contains $prop) {
            $importId = $ImportResponse.$prop
            if ($importId) { break }
        }
    }

    if (-not $importId) {
        throw "Unable to determine import request ID from response."
    }

    # Use Invoke-VSTeamRequest since VSTeam doesn't support repository import status directly
    $resource = "git/repositories/$RepositoryId/importRequests/$importId"
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        
        $status = Invoke-VSTeamRequest -Method GET -Resource $resource -Version '7.1-preview.1'

        if (-not $status) { continue }

        $state = $null
        foreach ($prop in @('status', 'state')) {
            if ($status.PSObject.Properties.Name -contains $prop) {
                $state = $status.$prop
                if ($state) { break }
            }
        }

        if ($state) {
            Write-Host "Import status: $state" -ForegroundColor DarkGray
        }

        if ($state -in @('completed', 'succeeded', 'success')) {
            return $status
        }
        if ($state -in @('failed', 'rejected', 'canceled', 'cancelled')) {
            $details = $status | ConvertTo-Json -Depth 20
            throw "Repository import did not succeed. Status: $state. Details: $details"
        }
    }

    throw "Timed out waiting for repository import to complete after $TimeoutSeconds seconds."
}

Write-Section "Select Azure DevOps organization"

# Use direct REST API to get organizations (VSTeam requires an org to connect to first)
$orgData = Invoke-WithErrorHandling -OperationName "Discovering Azure DevOps Organizations" -ScriptBlock {
    $headers = @{
        Authorization = "Bearer $($adoAccessToken.Token)"
    }

    # Get current user profile to obtain member ID
    $profileUrl = "https://app.vssps.visualstudio.com/_apis/profile/profiles/me?api-version=6.0"
    $profileResponse = Invoke-RestMethod -Uri $profileUrl -Method Get -Headers $headers
    
    $memberId = $profileResponse.publicAlias
    if (-not $memberId) {
        $memberId = $profileResponse.id
    }
    if (-not $memberId) {
        throw "Unable to determine memberId from profile response."
    }
   
    $accountsUrl = "https://app.vssps.visualstudio.com/_apis/accounts?memberId=$memberId&api-version=6.0"
    $accountsResponse = Invoke-RestMethod -Uri $accountsUrl -Method Get -Headers $headers
    
    $orgs = @($accountsResponse.value)
    
    if ($orgs.Count -eq 0) {
        throw "No Azure DevOps organizations were returned for this user."
    }

    $orgsSorted = $orgs | Sort-Object -Property accountName
    $orgNames = @($orgsSorted | ForEach-Object { $_.accountName })
    
    return @{
        Orgs = $orgsSorted
        OrgNames = $orgNames
    }
}

$orgsSorted = $orgData.Orgs
$orgNames = $orgData.OrgNames

$orgIndex = 0
$orgIndex = Select-FromMenu -Title "Select an Azure DevOps organization" -Items $orgNames
if ($null -eq $orgIndex) {
    Write-Host "No organization selected." -ForegroundColor Yellow
    return
}

$orgName = $orgNames[$orgIndex]
$orgId = $orgsSorted[$orgIndex].accountId
$orgUri = $orgsSorted[$orgIndex].accountUri
Write-Host "Selected organization: $orgName"
if ($orgUri) {
    Write-Host "Organization URI: $orgUri" -ForegroundColor DarkGray
}

# VSTeam expects -Account to be the org name (not the full URL).
Set-VSTeamAccount -Account $orgName -SecurePersonalAccessToken $secureToken -UseBearerToken -Force
Write-Host "VSTeam configured for organization '$orgName' using a bearer token."

Write-Section "Ensuring Needed Extensions are Enabled"

$requiredExtensions = @(
    "microsoft-IsvExpTools.PowerPlatform-BuildTools",
    "ALM4Dataverse.alm4dataverse-azdo-extensions"
)

foreach ($requiredExtension in $requiredExtensions) {
    $parts = $requiredExtension -split '\.'
    $publisherId = $parts[0]
    $extensionId = $parts[1..($parts.Length - 1)] -join '.'

    Invoke-WithErrorHandling -OperationName "Installing extension '$requiredExtension'" -ScriptBlock {
        # Check if the extension is already installed
        $installedExtensions = Get-VSTeamExtension
        $installed = $installedExtensions | Where-Object { $_.publisherId -eq $publisherId -and $_.extensionId -eq $extensionId }
        
        if ($installed) {
            Write-Host "Extension '$requiredExtension' is already installed (Version: $($installed.version))."
        }
        else {
            if (-not (Read-YesNo -Prompt "Extension '$requiredExtension' not found. Install it?")) {
                throw "Extension '$requiredExtension' is required. Setup cannot continue without it."
            }
            Write-Host "Extension '$requiredExtension' not found. Installing..." -ForegroundColor Yellow
            Write-Host "This may require organization administrative permissions." -ForegroundColor Yellow
            
            # Install the extension
            Install-VSTeamExtension -PublisherId $publisherId -ExtensionId $extensionId
            
            # Verify installation
            $installedExtensions = Get-VSTeamExtension
            $installed = $installedExtensions | Where-Object { $_.publisherId -eq $publisherId -and $_.extensionId -eq $extensionId }
            
            if ($installed) {
                Write-Host "Extension '$requiredExtension' installed successfully (Version: $($installed.version))."
            }
            else {
                Write-Host "Please install the extension manually from:" -ForegroundColor Yellow
                Write-Host "https://marketplace.visualstudio.com/acquisition?itemName=$requiredExtension" -ForegroundColor Yellow
                throw "Failed to verify extension '$requiredExtension' installation after install command completed."
            }
        }
    } | Out-Null
}

Write-Section "Select target Azure DevOps Project"

# We'll use the Azure DevOps access token that was already obtained via Get-AzAccessToken

$azDevOpsAccessToken = $adoAccessToken.Token

$projects = Get-VSTeamProject
$projectNames = @()
if ($projects) {
    $projectNames = @($projects | ForEach-Object { $_.Name })
}

$menuItems = $projectNames + @('Create a new project')
$index = Select-FromMenu -Title "Select the target Azure DevOps project" -Items $menuItems

if ($null -eq $index) {
    Write-Host "No project selected." -ForegroundColor Yellow
    return
}

if ($index -eq ($menuItems.Count - 1)) {
    # Create new project

    $name = Read-Host 'Enter the name for the new Azure DevOps project'    

    $created = New-AzDoProject -Organization $orgName -ProjectName $name -Visibility private

    # Refresh VSTeam project list
    $projects = Get-VSTeamProject
    $selectedProject = $null

    if ($projects) {
        $selectedProject = $projects | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    }
    if (-not $selectedProject -and $created -and $created.name) {
        # As a fallback, adapt REST project shape.
        $selectedProject = [pscustomobject]@{ Name = $created.name; Id = $created.id }
    }
    if (-not $selectedProject) {
        throw "Project creation completed, but the project could not be resolved for selection."
    }

    Write-Host "Created and selected project: $($selectedProject.Name)"
}
else {
    $selectedProject = $projects[$index]
    Write-Host "Selected project: $($selectedProject.Name)"
}

# Optional: set default project for subsequent VSTeam calls in this session.
if (Get-Command -Name Set-VSTeamDefaultProject -ErrorAction SilentlyContinue) {
    Set-VSTeamDefaultProject -Project $selectedProject.Name | Out-Null
    Write-Host "Default VSTeam project set to '$($selectedProject.Name)'."
}

Write-Section "Ensuring Shared Git repository"

$sharedRepoName = "ALM4Dataverse"
$existingRepos = Get-VSTeamGitRepository -ProjectName $selectedProject.Name
$repo = $existingRepos | Where-Object { $_.Name -eq $sharedRepoName } | Select-Object -First 1

if (-not $repo) {
    Write-Host "Creating Git repository '$sharedRepoName' in project '$($selectedProject.Name)'..." -ForegroundColor Yellow
    $repo = Add-VSTeamGitRepository -ProjectName $selectedProject.Name -Name $sharedRepoName
    if ($repo) {
        Write-Host "Git repository '$sharedRepoName' created successfully."
    }
    else {
        Write-Host "Failed to create Git repository '$sharedRepoName'." -ForegroundColor Red
    }
}
else {
    Write-Host "Git repository '$sharedRepoName' already exists."
}

if (-not $repo -or -not $repo.Id) {
    throw "Shared repository '$sharedRepoName' could not be created or resolved."
}

# Ensure the script is running interactively
try {
    [void]$Host.UI.RawUI
}
catch {
    throw "This script must be run in an interactive PowerShell session."
}

Write-Section "Creating/updating shared repository '$sharedRepoName'"

$hasCommits = Test-AzDoGitRepositoryHasCommits -Organization $orgName -Project $selectedProject.Name -RepositoryId $repo.Id
$justInitialized = $false
if (-not $hasCommits) {
    $justInitialized = Invoke-WithErrorHandling -OperationName "Initializing Shared Repository" -ScriptBlock {
        Write-Host "Repository '$sharedRepoName' has no commits. Seeding it from the upstream repo..." -ForegroundColor Yellow

        $sharedSourceUrl = $upstreamRepo
        $destUrl = $repo.remoteUrl
        if (-not $destUrl) {
            throw "Could not determine remoteUrl for repository '$sharedRepoName'."
        }

        # Create a temp folder for initializing the repo
        $workRoot = Join-Path $env:TEMP ("ALM4Dataverse-Init-" + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $workRoot -Force | Out-Null

        try {
            Push-Location $workRoot

            # Initialize and pull from upstream
            & git init --initial-branch=main | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Git init failed with exit code $LASTEXITCODE" }

            & git remote add origin $sharedSourceUrl | Out-Null
            & git fetch origin | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Git fetch failed with exit code $LASTEXITCODE" }

        # Determine the target ref using ls-remote to support both tags and branches
        & git ls-remote --exit-code origin $ALM4DataverseRef | Out-Null
        if ($LASTEXITCODE -eq 2) {
            throw "Could not resolve reference '$ALM4DataverseRef' from upstream repository."
        }
        if ($LASTEXITCODE -ne 0) {
            throw "Git ls-remote failed with exit code $LASTEXITCODE"
        }
        
        # Get the full ref name from ls-remote output
        $lsRemoteOutput = (& git ls-remote origin $ALM4DataverseRef | Select-Object -First 1)
        if ($lsRemoteOutput -match '^([a-f0-9]+)\s+(.+)$') {
            $commitSha = $Matches[1]
            $fullRef = $Matches[2]
            # For branches, use origin/branch-name; for tags, use the commit SHA directly
            if ($fullRef -match '^refs/heads/(.+)$') {
                $targetRef = "origin/$($Matches[1])"
            }
            elseif ($fullRef -match '^refs/tags/') {
                # Use the commit SHA directly since tags aren't automatically created locally
                $targetRef = $commitSha
            }
            else {
                $targetRef = $ALM4DataverseRef
            }
        }
        else {
            $targetRef = $ALM4DataverseRef
        }

            # Checkout the target ref as main branch
            & git checkout -b main $targetRef | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Git checkout failed with exit code $LASTEXITCODE" }

            # Push to Azure DevOps
            & git remote set-url origin $destUrl | Out-Null
            & git -c "http.extraheader=AUTHORIZATION: bearer $azDevOpsAccessToken" push -u origin main
            if ($LASTEXITCODE -ne 0) { throw "Git push failed with exit code $LASTEXITCODE" }

            Write-Host "Shared repository initialized successfully."
            return $true
        }
        finally {
            if ((Get-Location).Path -eq $workRoot) { Pop-Location }
            try { Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
}

# Check if we can fast-forward from the shared repo (skip if just initialized)
if (-not $justInitialized) {
$sharedSourceUrl = $upstreamRepo
$destUrl = $repo.remoteUrl
if (-not $destUrl) {
    throw "Could not determine remoteUrl for repository '$sharedRepoName'."
}

# Create a temp folder for checking history
$workRoot = Join-Path $env:TEMP ("ALM4Dataverse-Check-" + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $workRoot -Force | Out-Null

try {
    Write-Host "Checking shared repository status against shared repo..." -ForegroundColor DarkGray
    
    # Clone the current shared repo
    & git -c "http.extraheader=AUTHORIZATION: bearer $azDevOpsAccessToken" clone $destUrl $workRoot | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Git clone failed with exit code $LASTEXITCODE"
    }

    Push-Location $workRoot
    
    # Add upstream remote
    & git remote add upstream $sharedSourceUrl | Out-Null
    & git fetch upstream | Out-Null
    
    # Check relationship between HEAD and upstream ref using ls-remote to support both tags and branches
    & git ls-remote --exit-code upstream $ALM4DataverseRef | Out-Null
    if ($LASTEXITCODE -eq 2) {
        throw "Could not resolve reference '$ALM4DataverseRef' from upstream repository."
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Git ls-remote failed with exit code $LASTEXITCODE"
    }
    
    # Get the full ref name from ls-remote output
    $lsRemoteOutput = (& git ls-remote upstream $ALM4DataverseRef | Select-Object -First 1)
    if ($lsRemoteOutput -match '^([a-f0-9]+)\s+(.+)$') {
        $commitSha = $Matches[1]
        $fullRef = $Matches[2]
        # For branches, use upstream/branch-name; for tags, use the commit SHA directly
        if ($fullRef -match '^refs/heads/(.+)$') {
            $targetRef = "upstream/$($Matches[1])"
        }
        elseif ($fullRef -match '^refs/tags/') {
            # Use the commit SHA directly since tags aren't automatically created locally
            $targetRef = $commitSha
        }
        else {
            $targetRef = $ALM4DataverseRef
        }
    }
    else {
        $targetRef = $ALM4DataverseRef
    }
    $upstreamRef = $targetRef
    
    # Check if they are exactly the same
    $localHash = (& git rev-parse HEAD).Trim()
    $upstreamHash = (& git rev-parse $upstreamRef).Trim()
        
    if ($localHash -eq $upstreamHash) {
        Write-Host "Shared repository is already up to date."
    }
    else {
        # Check if fast-forward is possible (HEAD is ancestor of upstream)
        & git merge-base --is-ancestor HEAD $upstreamRef
        $canFastForward = ($LASTEXITCODE -eq 0)
            
        if ($canFastForward) {
            if (Read-YesNo -Prompt "Updates are available from the shared repo (fast-forward). Update '$sharedRepoName'?" ) {
                Write-Host "Fast-forwarding..." -ForegroundColor Yellow
                & git merge --ff-only $upstreamRef
                if ($LASTEXITCODE -ne 0) { throw "Git merge failed" }
                    
                & git -c "http.extraheader=AUTHORIZATION: bearer $azDevOpsAccessToken" push origin
                if ($LASTEXITCODE -ne 0) { throw "Git push failed" }
                    
                Write-Host "Repository updated successfully."
            }
        }
        else {
            # Check if local is ahead (upstream is ancestor of HEAD)
            & git merge-base --is-ancestor $upstreamRef HEAD
            $isAhead = ($LASTEXITCODE -eq 0)
                
            if ($isAhead) {
                Write-Host "Shared repository is ahead of the shared repo."
            }
            else {
                # Diverged
                if (Read-YesNo -Prompt "The shared repo '$sharedRepoName' has diverged from the shared repo with local changes. Attempt rebase to update?") {
                    Write-Host "Rebasing..." -ForegroundColor Yellow
                    & git rebase $upstreamRef
                    if ($LASTEXITCODE -ne 0) { throw "Git rebase failed - this script can't handle conflicts. You need to rebase your local changes manually." }
                        
                    Write-Host "Pushing rebased branch (force-with-lease)..." -ForegroundColor Yellow
                    & git -c "http.extraheader=AUTHORIZATION: bearer $azDevOpsAccessToken" push --force-with-lease origin
                    if ($LASTEXITCODE -ne 0) { throw "Git push failed" }
                        
                    Write-Host "Repository updated successfully."
                }
            }
        }
    }
}
catch {
    Write-Host "Failed to check or update repository: $($_.Exception.Message)" -ForegroundColor Red
    throw
}
finally {
    if ((Get-Location).Path -eq $workRoot) { Pop-Location }
    try { Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}
}
# End of fast-forward check skip

#endregion

#region Dataverse Environment Selection Helper

function Select-DataverseEnvironment {
    [CmdletBinding()]
    param(
        [Parameter()][string]$Prompt = "Select a Dataverse environment",
        [Parameter()][string]$ExcludeUrl
    )

    Write-Host "Listing Dataverse environments..." -ForegroundColor Yellow

    # Get all environments using Get-DataverseEnvironment
    $environments = @(Get-DataverseEnvironment -AccessToken { 
        param($resource)
        if (-not $resource) { $resource = 'https://globaldisco.crm.dynamics.com/' }
        try {
            $uri = [System.Uri]$resource
            $resource = $uri.GetLeftPart([System.UriPartial]::Authority)
        } catch {}
        $auth = Get-AuthToken -ResourceUrl $resource
        return $auth.AccessToken
    })

    if (-not $environments -or $environments.Count -eq 0) {
        throw "No Dataverse environments found for this user."
    }

    # Filter out excluded URL if provided
    if ($ExcludeUrl) {
        $environments = @($environments | Where-Object { 
            $_.Endpoints["WebApplication"] -ne $ExcludeUrl 
        })
        if ($environments.Count -eq 0) {
            throw "No environments available after filtering."
        }
    }

    # Build menu items
    $menuItems = @()
    foreach ($env in $environments) {
        $webUrl = $env.Endpoints["WebApplication"]
        $menuItems += "$($env.FriendlyName) - $($env.UniqueName) ($webUrl)"
    }

    # Show menu
    $selectedIndex = Select-FromMenu -Title $Prompt -Items $menuItems
    if ($null -eq $selectedIndex) {
        return $null
    }

    return $environments[$selectedIndex]
}

#endregion

#region Pipeline Setup

function Select-AzDoMainRepository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$SharedRepositoryName
    )

    Write-Section "Selecting main Git repository"

    $repos = @(Get-VSTeamGitRepository -ProjectName $ProjectName)
    # 'Main' repo is the user's application repo (not the shared ALM4Dataverse repo)
    $reposSorted = @($repos | Sort-Object -Property Name)

    $repoNames = @($reposSorted | ForEach-Object { $_.Name })
    $repoNames = @($repoNames | Where-Object { $_ -ne $SharedRepositoryName })
    $menu = @($repoNames + @('Create a new repository'))

    Write-Host "Select the repository where you want to set up pipelines:" -ForegroundColor Green

    $selectedIndex = Select-FromMenu -Title "Select the repo" -Items $menu
    if ($null -eq $selectedIndex) {
        throw "No main repository selected."
    }

    if ($selectedIndex -eq ($menu.Count - 1)) {
        $newRepoName = Read-Host "Enter the name for the new main repository"
        $newRepoName = $newRepoName.Trim()
        if ([string]::IsNullOrWhiteSpace($newRepoName)) {
            throw "Repository name cannot be empty."
        }

        Write-Host "Creating Git repository '$newRepoName' in project '$ProjectName'..." -ForegroundColor Yellow
        $created = Add-VSTeamGitRepository -ProjectName $ProjectName -Name $newRepoName
        if (-not $created -or -not $created.Id) {
            throw "Failed to create Git repository '$newRepoName'."
        }
        Write-Host "Created repository '$newRepoName'."
        return $created
    }

    $selectedName = $menu[$selectedIndex]
    $selected = $reposSorted | Where-Object { $_.Name -eq $selectedName } | Select-Object -First 1
    if (-not $selected -or -not $selected.Id) {
        throw "Failed to resolve selected repository '$selectedName'."
    }

    Write-Host "Selected main repository: $($selected.Name)"
    return $selected
}

function Sync-CopyToYourRepoIntoGitRepo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][object]$TargetRepo,
        [Parameter(Mandatory)][string]$PreferredBranch
    )

    if (-not (Test-Path -LiteralPath $SourceRoot)) {
        throw "Source folder not found: $SourceRoot"
    }

    if (-not $TargetRepo.remoteUrl) {
        throw "Could not determine remoteUrl for repository '$($TargetRepo.Name)'."
    }

    $cloneRoot = Join-Path $env:TEMP ("ALM4Dataverse-MainRepo-" + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $cloneRoot -Force | Out-Null

    Write-Host "Cloning '$($TargetRepo.Name)' to a temp folder..." -ForegroundColor Yellow
    try {
        & git -c "http.extraheader=AUTHORIZATION: bearer $azDevOpsAccessToken" clone $TargetRepo.remoteUrl $cloneRoot
        if ($LASTEXITCODE -ne 0) {
            throw "Git clone exited with code $LASTEXITCODE"
        }
    }
    catch {
        throw "Git clone failed for '$($TargetRepo.remoteUrl)': $($_.Exception.Message)"
    }

    Push-Location $cloneRoot
    try {
        $branch = $PreferredBranch

        # If the repo already has a defaultBranch, prefer it.
        if ($TargetRepo.defaultBranch) {
            $branch = ConvertFrom-GitRefToBranchName -Ref $TargetRepo.defaultBranch
        }
        if ([string]::IsNullOrWhiteSpace($branch)) {
            $branch = 'main'
        }

        # Check if repository has any commits (empty repos may not have HEAD)
        $hasCommits = $false
        try {
            & git rev-parse HEAD 2>$null
            $hasCommits = ($LASTEXITCODE -eq 0)
        }
        catch {
            $hasCommits = $false
        }

        if ($hasCommits) {
            & git -c "http.extraheader=AUTHORIZATION: bearer $azDevOpsAccessToken" fetch origin
            if ($LASTEXITCODE -ne 0) {
                throw "Git fetch failed with exit code $LASTEXITCODE"
            }
            
            # Check if branch exists
            & git show-ref --verify --quiet "refs/heads/$branch"
            if ($LASTEXITCODE -eq 0) {
                # Branch exists, check it out
                & git checkout $branch
                if ($LASTEXITCODE -ne 0) {
                    throw "Git checkout failed with exit code $LASTEXITCODE"
                }
            }
            else {
                # Branch doesn't exist locally, create it
                & git checkout -b $branch
                if ($LASTEXITCODE -ne 0) {
                    throw "Git checkout -b failed with exit code $LASTEXITCODE"
                }
            }
        }
        else {
            # Empty repo - create and checkout branch
            & git checkout -b $branch
            if ($LASTEXITCODE -ne 0) {
                throw "Git checkout -b failed with exit code $LASTEXITCODE"
            }
        }

 
        Write-Section "Syncing pipeline files into main repository"
        Write-Host "Source: $SourceRoot" -ForegroundColor DarkGray
        Write-Host "Target: $cloneRoot" -ForegroundColor DarkGray

        # Copy files with prompt for overwrite
        $allSourceFiles = Get-ChildItem -LiteralPath $SourceRoot -Recurse -Force | Where-Object { -not $_.PSIsContainer }
        
        foreach ($file in $allSourceFiles) {
            $relativePath = $file.FullName.Substring($SourceRoot.Length).TrimStart('\', '/')
            $destPath = Join-Path $cloneRoot $relativePath
            
            $destDir = Split-Path -Parent $destPath
            if (-not (Test-Path -LiteralPath $destDir)) {
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            }

            # Special handling for DEPLOY-main.yml to inject folder name and rename file
            $sourceFileToUse = $file.FullName
            $isTempFile = $false

            if ($relativePath -replace '\\', '/' -eq 'pipelines/DEPLOY-main.yml') {
                # Rename destination file based on branch
                $destPath = Join-Path $cloneRoot "pipelines/DEPLOY-$branch.yml"
                
                $content = Get-Content -LiteralPath $file.FullName -Raw
                $content = $content -replace "source: 'BUILD'", "source: '$($TargetRepo.Name)\BUILD'"
                # Update trigger branch
                $content = $content -replace "- main", "- $branch"
                
                $tempFile = [System.IO.Path]::GetTempFileName()
                $content | Set-Content -LiteralPath $tempFile -NoNewline
                $sourceFileToUse = $tempFile
                $isTempFile = $true
            }

            try {
                if (Test-Path -LiteralPath $destPath) {
                    $srcHash = Get-FileHash -LiteralPath $sourceFileToUse -Algorithm MD5
                    $dstHash = Get-FileHash -LiteralPath $destPath -Algorithm MD5
                    
                    if ($srcHash.Hash -ne $dstHash.Hash) {
                        $overwrite = Read-YesNo -Prompt "File '$relativePath' already exists and is different. Overwrite?" -DefaultNo
                        
                        if ($overwrite) {
                            Copy-Item -LiteralPath $sourceFileToUse -Destination $destPath -Force
                        }
                        
                        # Create template file with the new content
                        Copy-Item -LiteralPath $sourceFileToUse -Destination "$destPath.template" -Force
                    } else {
                        # Files match, remove template if it exists
                        if (Test-Path -LiteralPath "$destPath.template") {
                            Remove-Item -LiteralPath "$destPath.template" -Force
                        }
                    }
                } else {
                    Copy-Item -LiteralPath $sourceFileToUse -Destination $destPath -Force
                }
            }
            finally {
                if ($isTempFile -and (Test-Path -LiteralPath $sourceFileToUse)) {
                    Remove-Item -LiteralPath $sourceFileToUse -Force
                }
            }
        }
      
        

        # Check for changes
        & git add -A
        if ($LASTEXITCODE -ne 0) {
            throw "Git add failed with exit code $LASTEXITCODE"
        }
        
        # Check if there are changes to commit
        & git diff --cached --quiet
        $hasChanges = ($LASTEXITCODE -ne 0)
        
        if ($hasChanges) {
            Write-Host "Committing changes..." -ForegroundColor Yellow
            
            # Configure git user if not already configured
            & git config user.name "ALM4Dataverse Setup" 2>$null
            & git config user.email "setup@alm4dataverse.local" 2>$null
            
            & git commit -m "Add ALM4Dataverse pipelines"
            if ($LASTEXITCODE -ne 0) {
                throw "Git commit failed with exit code $LASTEXITCODE"
            }

            Write-Host "Pushing to origin/$branch..." -ForegroundColor Yellow
            & git -c "http.extraheader=AUTHORIZATION: bearer $azDevOpsAccessToken" push origin $branch
            if ($LASTEXITCODE -ne 0) {
                throw "Git push failed with exit code $LASTEXITCODE. Ensure you have permission and that authentication succeeds."
            }
            Write-Host "Main repo updated successfully."
        }
        else {
            Write-Host "No changes to commit; main repo already contains the required files."
        }
    }
    finally {
        Pop-Location
        try { Remove-Item -LiteralPath $cloneRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Get-AzDoDefaultAgentQueueId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$Project
    )

    $queues = @(Get-VSTeamQueue -ProjectName $Project)
    if ($queues.Count -eq 0) {
        throw "No agent queues found in project '$Project'."
    }

    $preferred = $queues | Where-Object { $_.name -eq 'Azure Pipelines' } | Select-Object -First 1
    if (-not $preferred) {
        $preferred = $queues | Where-Object { $_.name -eq 'Default' } | Select-Object -First 1
    }
    if (-not $preferred) {
        $preferred = $queues | Select-Object -First 1
    }

    if (-not $preferred -or -not $preferred.id) {
        throw "Unable to resolve an agent queue id."
    }

    return [int]$preferred.id
}

function Get-AzDoSecurityNamespaceByName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$Name
    )

    # Use VSTeam command to get security namespace by name
    $allNamespaces = Get-VSTeamSecurityNamespace
    $ns = $allNamespaces | Where-Object { $_.Name -eq $Name -or $_.DisplayName -eq $Name } | Select-Object -First 1
    if (-not $ns -or -not $ns.Id) {
        throw "Unable to resolve security namespace '$Name'."
    }
    return $ns
}

function Get-AzDoSecurityNamespaceActionBit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Namespace,
        [Parameter(Mandatory)][string]$ActionName
    )

    $actions = @()
    if ($Namespace -and $Namespace.actions) {
        $actions = @($Namespace.actions)
    }

    $action = $actions | Where-Object {
        ($_.name -eq $ActionName) -or ($_.displayName -eq $ActionName)
    } | Select-Object -First 1

    if (-not $action -or -not ($action.PSObject.Properties.Name -contains 'bit')) {
        throw "Unable to resolve action '$ActionName' in security namespace '$($Namespace.name)'."
    }

    return [long]$action.bit
}

function Get-AzDoBuildServiceIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter()][string]$ProjectName
    )

    # Use VSTeam command to search for Build Service identity
    $serviceIdentities = @(Get-VSTeamUser -SubjectTypes svc)
    
    $buildServicePattern = "Build:$ProjectId"
    $buildIdentity = $null
    
    foreach ($identity in $serviceIdentities) {
        if ($identity.descriptor -and $identity.descriptor.StartsWith('svc.')) {
            try {
                # Remove "svc." prefix and base64 decode
                $encodedPart = $identity.descriptor.Substring(4)
                
                # Add padding if needed for proper base64 decoding
                $padding = (4 - ($encodedPart.Length % 4)) % 4
                if ($padding -gt 0) {
                    $encodedPart += '=' * $padding
                }
                
                $decodedBytes = [Convert]::FromBase64String($encodedPart)
                $decodedString = [Text.Encoding]::UTF8.GetString($decodedBytes)
                
                # Check if decoded string ends with "Build:$ProjectId"
                if ($decodedString.EndsWith($buildServicePattern)) {
                    $buildIdentity = $identity
                    $correctDescriptor = "Microsoft.TeamFoundation.ServiceIdentity;$decodedString"
                    break
                }
            }
            catch {
                # Skip if base64 decode fails
                continue
            }
        }
    }

    if (-not $buildIdentity) {
        throw "Unable to find Build Service identity with descriptor ending 'Build:$ProjectId' for project '$ProjectName'."
    }

    if (-not $correctDescriptor) {
        throw "Build Service identity found but correct descriptor could not be constructed."
    }

    Write-Host "Found Build Service identity: $($buildIdentity.displayName)"
    return $correctDescriptor
}

function Get-AzDoAccessControlEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$NamespaceId,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Descriptor
    )

    try {
        # Use VSTeam command to get access control list
        $acls = Get-VSTeamAccessControlList -SecurityNamespaceId $NamespaceId -Token $Token -Descriptors $Descriptor
        
        if (-not $acls -or $acls.Count -eq 0) {
            return $null
        }

        $acl = $acls | Select-Object -First 1
        if (-not $acl -or -not $acl.acesDictionary) {
            return $null
        }

        # Extract the ACE for the requested descriptor
        $ace = $null
        try {
            if ($acl.acesDictionary.PSObject.Properties.Name -contains $Descriptor) {
                $ace = $acl.acesDictionary.$Descriptor
            }
            elseif ($acl.acesDictionary.ContainsKey -and $acl.acesDictionary.ContainsKey($Descriptor)) {
                $ace = $acl.acesDictionary[$Descriptor]
            }
        }
        catch {
            $ace = $null
        }

        return $ace
    }
    catch {
        # If VSTeam command fails, return null (ACE doesn't exist)
        return $null
    }
}

function Set-AzDoAccessControlEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$NamespaceId,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Descriptor,
        [Parameter(Mandatory)][long]$Allow,
        [Parameter(Mandatory)][long]$Deny
    )

    # Use VSTeam command to set access control entry
    # Note: Add-VSTeamAccessControlEntry requires a SecurityNamespace object, so we need to get it first
    $ns = Get-VSTeamSecurityNamespace -Id $NamespaceId
    Add-VSTeamAccessControlEntry -SecurityNamespace $ns -Token $Token -Descriptor $Descriptor -AllowMask $Allow -DenyMask $Deny -OverwriteMask
}

function Ensure-AzDoBuildServiceHasContributeOnRepo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$RepositoryId
    )

    # Find the Build Service identity by searching identities
    $descriptor = Get-AzDoBuildServiceIdentity -Organization $Organization -ProjectId $ProjectId -ProjectName $ProjectName
    $descriptor = $descriptor.Trim()  # Clean any whitespace
    Write-Host "Found Build Service descriptor: $descriptor" -ForegroundColor DarkGray

    $ns = Get-AzDoSecurityNamespaceByName -Organization $Organization -Name 'Git Repositories'
    $contributeBit = Get-AzDoSecurityNamespaceActionBit -Namespace $ns -ActionName 'Contribute'

    # Repo token format for Git Repositories namespace:
    #   repoV2/<projectId>/<repoId>
    $token = "repoV2/$ProjectId/$RepositoryId"

    $existing = Get-AzDoAccessControlEntry -Organization $Organization -NamespaceId $ns.Id -Token $token -Descriptor $descriptor
    $existingAllow = 0L
    $existingDeny = 0L

    if ($existing) {
        if ($existing.PSObject.Properties.Name -contains 'allow') { $existingAllow = [long]$existing.allow }
        if ($existing.PSObject.Properties.Name -contains 'deny') { $existingDeny = [long]$existing.deny }
    }

    $alreadyAllowed = (($existingAllow -band $contributeBit) -ne 0)
    $isDenied = (($existingDeny -band $contributeBit) -ne 0)

    if ($alreadyAllowed -and -not $isDenied) {
        Write-Host "Build Service already has 'Contribute' on repo."
        return
    }

    $desiredAllow = ($existingAllow -bor $contributeBit)
    $desiredDeny = ($existingDeny -band (-bnot $contributeBit))

    Write-Host "Granting Build Service 'Contribute' on repo..." -ForegroundColor Yellow
    Set-AzDoAccessControlEntry -Organization $Organization -NamespaceId $ns.Id -Token $token -Descriptor $descriptor -Allow $desiredAllow -Deny $desiredDeny | out-null
    Write-Host "Granted 'Contribute' to Build Service on repository."
}

function Ensure-AzDoYamlPipelineDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][object]$Repository,
        [Parameter(Mandatory)][string]$DefinitionName,
        [Parameter(Mandatory)][string]$YamlPath,
        [Parameter(Mandatory)][int]$QueueId,
        [Parameter()][string]$FolderPath = '\'
    )

    $YamlPath = $YamlPath.TrimStart('/')

    $existing = @(Get-VSTeamBuildDefinition -ProjectName $Project) | Where-Object { $_.name -eq $DefinitionName -and $_.path -eq $FolderPath }
    $def = $existing | Select-Object -First 1

    if (-not $def) {
        Write-Host "Creating pipeline '$DefinitionName' (YAML: $YamlPath)..." -ForegroundColor Yellow

        $repoBranch = 'refs/heads/main'
        if ($Repository.defaultBranch) {
            $repoBranch = $Repository.defaultBranch
        }

        # Use Invoke-VSTeamRequest since VSTeam build definition commands require JSON files
        $body = @{
            name        = $DefinitionName
            path        = $FolderPath
            type        = 'build'
            queueStatus = 'enabled'
            queue       = @{ id = $QueueId }
            repository  = @{
                id            = $Repository.Id
                name          = $Repository.Name
                type          = 'TfsGit'
                defaultBranch = $repoBranch
            }
            process     = @{
                type         = 2
                yamlFilename = $YamlPath
            }
            triggers    = @(
                @{
                    settingsSourceType = 2
                    triggerType        = 'continuousIntegration'
                }
            )
        }

        $resource = "build/definitions"
        [void](Invoke-VSTeamRequest -Method POST -Resource $resource -Body ($body | ConvertTo-Json -Depth 10) -ContentType 'application/json' -Version '7.1')
        Write-Host "Created pipeline '$DefinitionName'."
        return
    }

    # Ensure existing points at expected YAML + repo
    $full = Get-VSTeamBuildDefinition -ProjectName $Project -Id $def.id

    $needsUpdate = $false
    if (-not $full.process -or -not $full.process.type -or [int]$full.process.type -ne 2) {
        $needsUpdate = $true
    }
    elseif ($full.process.PSObject.Properties.Name -contains 'yamlFilename') {
        if ($full.process.yamlFilename -ne $YamlPath) { $needsUpdate = $true }
    }
    else {
        # If yamlFilename isn't present, treat as needs update.
        $needsUpdate = $true
    }

    if ($full.repository -and $full.repository.id -and ($full.repository.id -ne $Repository.Id)) {
        $needsUpdate = $true
    }

    if (-not $needsUpdate) {
        Write-Host "Pipeline '$DefinitionName' already exists and points at '$YamlPath'."
        return
    }

    Write-Host "Updating pipeline '$DefinitionName' to point at '$YamlPath'..." -ForegroundColor Yellow

    $def.repository.name = $Repository.Name
    $def.repository.id = $Repository.Id
    if ($Repository.defaultBranch) {
        $def.repository.defaultBranch = $Repository.defaultBranch
    }
    $def.process.yamlFilename = $YamlPath

    # Use Invoke-VSTeamRequest since VSTeam update commands require JSON files
    $resource = "build/definitions/$($def.id)"
    [void](Invoke-VSTeamRequest -Method PUT -Resource $resource -Body ($def | ConvertTo-Json -Depth 50) -ContentType 'application/json' -Version '7.1')
    Write-Host "Updated pipeline '$DefinitionName'."
}

function Ensure-AzDoPipelinesForMainRepo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][object]$Repository,
        [Parameter(Mandatory)][string[]]$YamlFiles,
        [Parameter()][string]$FolderPath = '\\'
    )

    Write-Section "Ensuring Azure DevOps pipeline definitions exist"

    $queueId = Get-AzDoDefaultAgentQueueId -Organization $Organization -Project $Project
    Write-Host "Using agent queue id: $queueId" -ForegroundColor DarkGray

    foreach ($yaml in $YamlFiles) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($yaml)
        Ensure-AzDoYamlPipelineDefinition -Organization $Organization -Project $Project -Repository $Repository -DefinitionName $name -YamlPath $yaml -QueueId $queueId -FolderPath $FolderPath
    }
}

function Ensure-AzDoDeploymentApproversTeam {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$EnvironmentName
    )

    $teamName = "$EnvironmentName deployment approvers"
    Write-Host "Ensuring team '$teamName' exists..." -ForegroundColor DarkGray

    $team = Get-VSTeam -ProjectName $ProjectName -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $teamName } | Select-Object -First 1
    
    if (-not $team) {
        Write-Host "Creating team '$teamName'..." -ForegroundColor Yellow
        Add-VSTeam -ProjectName $ProjectName -Name $teamName -Description "Approvers for $EnvironmentName deployment" | Out-Null
        $team = Get-VSTeam -ProjectName $ProjectName | Where-Object { $_.Name -eq $teamName } | Select-Object -First 1
    }
       
    # Add current user to the team
    
    $me = Invoke-VSTeamRequest -NoProject -Method GET -Url "https://app.vssps.visualstudio.com/_apis/profile/profiles/me" -Version "7.1"
    Write-Host "Adding current user ($($me.emailAddress)) to team '$teamName'..." -ForegroundColor Yellow
    
    $user = Get-VSTeamUser | Where-Object { $_.UniqueName -eq $me.emailAddress } | Select-Object -First 1
    $group = Get-VSTeamGroup -ProjectName $ProjectName | Where-Object { $_.DisplayName -eq $teamName } | Select-Object -First 1

    if ($user -and $group) {
        Add-VSTeamMembership -MemberDescriptor $user.Descriptor -ContainerDescriptor $group.Descriptor | Out-Null
    }
    else {
        throw "Could not resolve user or group to add membership."
    }

    
    return $team
}

function Ensure-AzDoVariableGroupApproval {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$VariableGroupId,
        [Parameter(Mandatory)][string]$VariableGroupName,
        [Parameter(Mandatory)][object]$ApproverTeam
    )

    Write-Host "Ensuring Approval check on variable group '$VariableGroupName'..." -ForegroundColor DarkGray

    # Check for existing checks
    $uri = "https://dev.azure.com/$Organization/$Project/_apis/pipelines/checks/configurations?resourceType=variablegroup&resourceId=$VariableGroupId&api-version=7.1-preview.1"
    $headers = @{ Authorization = "Bearer $($adoAccessToken.Token)" }
    
    $existingChecks = $null

    $existingChecks = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers

    
    $hasApproval = $false
    if ($existingChecks -and $existingChecks.count -gt 0) {
        foreach ($check in $existingChecks.value) {
            if ($check.resource.type -eq 'variablegroup' -and [string]$check.resource.id -eq [string]$VariableGroupId -and $check.type -and $check.type.name -eq 'Approval') {
                $hasApproval = $true
                break
            }
        }
    }

    if ($hasApproval) {
        Write-Host "Approval check already exists on variable group '$VariableGroupName'."
        return
    }

    Write-Host "Adding Approval check to variable group '$VariableGroupName'..." -ForegroundColor Yellow

    # We need the descriptor for the team. Get-VSTeamTeam doesn't return it directly.
    # We can find the group identity using Get-VSTeamGroup.
    $teamIdentity = Get-VSTeamGroup -ProjectName $Project | Where-Object { $_.principalName -eq $ApproverTeam.name -or $_.displayName -eq $ApproverTeam.name } | Select-Object -First 1
    
    if (-not $teamIdentity) {
        throw "Could not resolve identity for team '$($ApproverTeam.name)' for approval check creation."
    }

    $body = @{
        type = @{
            id = "8C6F20A7-A545-4486-9777-F762FAFE0D4D"
            name = "Approval"
        }
        settings = @{
            approvers = @(
                @{
                    id = $teamIdentity.originId
                    descriptor = $teamIdentity.descriptor
                    displayName = $teamIdentity.displayName
                }
            )
            executionOrder = 1
            minRequiredApprovers = 0
            requesterCannotBeApprover = $false
        }
        resource = @{
            type = "variablegroup"
            id = [string]$VariableGroupId
            name = $VariableGroupName
        }
        timeout = 43200
    }

    $resource = "pipelines/checks/configurations"
    [void](Invoke-VSTeamRequest -Method POST -Resource $resource -Body ($body | ConvertTo-Json -Depth 10) -ContentType 'application/json' -Version '7.1-preview.1')
    Write-Host "Approval check added."
}

function Ensure-AzDoVariableGroupExclusiveLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$VariableGroupId,
        [Parameter(Mandatory)][string]$VariableGroupName
    )

    Write-Host "Ensuring ExclusiveLock check on variable group '$VariableGroupName'..." -ForegroundColor DarkGray

    # Check for existing checks
    $uri = "https://dev.azure.com/$Organization/$Project/_apis/pipelines/checks/configurations?resourceType=variablegroup&resourceId=$VariableGroupId&api-version=7.1-preview.1"
    $headers = @{ Authorization = "Bearer $($adoAccessToken.Token)" }
    
    $existingChecks = $null
    $existingChecks = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers

    $hasExclusiveLock = $false
    if ($existingChecks -and $existingChecks.count -gt 0) {
        foreach ($check in $existingChecks.value) {
            if ($check.resource.type -eq 'variablegroup' -and [string]$check.resource.id -eq [string]$VariableGroupId -and $check.type -and $check.type.name -eq 'ExclusiveLock') {
                $hasExclusiveLock = $true
                break
            }
        }
    }

    if ($hasExclusiveLock) {
        Write-Host "ExclusiveLock check already exists on variable group '$VariableGroupName'."
        return
    }

    Write-Host "Adding ExclusiveLock check to variable group '$VariableGroupName'..." -ForegroundColor Yellow

    $body = @{
        type = @{
            id = "2EF31AD6-BAA0-403A-8B45-2CBC9B4E5563"
            name = "ExclusiveLock"
        }
        settings = @{}
        resource = @{
            type = "variablegroup"
            id = [string]$VariableGroupId
            name = $VariableGroupName
        }
        timeout = 43200
    }

    $resource = "pipelines/checks/configurations"
    [void](Invoke-VSTeamRequest -Method POST -Resource $resource -Body ($body | ConvertTo-Json -Depth 10) -ContentType 'application/json' -Version '7.1-preview.1')
    Write-Host "ExclusiveLock check added."
}

function Ensure-AzDoEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][string]$Description
    )

    Write-Host "Ensuring Environment '$EnvironmentName'..." -ForegroundColor DarkGray

    $headers = @{ Authorization = "Bearer $($adoAccessToken.Token)" }
    
    # List environments to check if it exists
    $uri = "https://dev.azure.com/$Organization/$Project/_apis/pipelines/environments?name=$EnvironmentName&api-version=7.2-preview.1"
    
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers
        $env = $response.value | Where-Object { $_.name -eq $EnvironmentName } | Select-Object -First 1
        
        if ($env) {
            Write-Host "Environment '$EnvironmentName' already exists (id: $($env.id))."
            return $env
        }

        Write-Host "Creating Environment '$EnvironmentName'..." -ForegroundColor Yellow
        
        $body = @{
            name = $EnvironmentName
            description = $Description
        }

        $createUri = "https://dev.azure.com/$Organization/$Project/_apis/pipelines/environments?api-version=7.2-preview.1"
        $created = Invoke-RestMethod -Uri $createUri -Method Post -Headers $headers -Body ($body | ConvertTo-Json) -ContentType "application/json"
        
        Write-Host "Created Environment '$EnvironmentName' (id: $($created.id))."
        return $created
    }
    catch {
        Write-Host "Failed to ensure environment: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

function Ensure-AzDoPipelinePermission {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$ResourceType, # 'endpoint' or 'variablegroup'
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)][int]$PipelineId
    )

    Write-Host "Ensuring pipeline $PipelineId has permission on $ResourceType $ResourceId..." -ForegroundColor DarkGray

    $headers = @{ Authorization = "Bearer $($adoAccessToken.Token)" }
    
    # Check existing permissions
    $uri = "https://dev.azure.com/$Organization/$Project/_apis/pipelines/pipelinePermissions/$ResourceType/$ResourceId`?api-version=7.1-preview.1"
    
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers
        
        $isAuthorized = $false
        if ($response.pipelines) {
            foreach ($p in $response.pipelines) {
                if ($p.id -eq $PipelineId -and $p.authorized -eq $true) {
                    $isAuthorized = $true
                    break
                }
            }
        }

        if ($isAuthorized) {
            Write-Host "Pipeline $PipelineId is already authorized."
            return
        }

        Write-Host "Authorizing pipeline $PipelineId..." -ForegroundColor Yellow
        
        $body = @{
            pipelines = @(
                @{
                    id = $PipelineId
                    authorized = $true
                }
            )
        }

        $patchUri = "https://dev.azure.com/$Organization/$Project/_apis/pipelines/pipelinePermissions/$ResourceType/$ResourceId`?api-version=7.1-preview.1"
        [void](Invoke-RestMethod -Uri $patchUri -Method Patch -Headers $headers -Body ($body | ConvertTo-Json) -ContentType "application/json")
        
        Write-Host "Pipeline authorized successfully."
    }
    catch {
        Write-Host "Failed to authorize pipeline: $($_.Exception.Message)" -ForegroundColor Red
        Write-Warning "Could not authorize pipeline. You may need to authorize it manually when running the pipeline."
    }
}

function Ensure-AzDoServiceEndpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$ServiceEndpointName,
        [Parameter(Mandatory)][string]$EnvironmentUrl,
        [Parameter(Mandatory)][string]$ApplicationId,
        [Parameter()][string]$ClientSecret,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter()][string]$AuthType = 'Secret'
    )

    Write-Host "Ensuring Service Endpoint '$ServiceEndpointName'..." -ForegroundColor DarkGray

    # Get-VSTeamServiceEndpoint does not support -Name, so we filter client-side
    $endpoints = @(Get-VSTeamServiceEndpoint -ProjectName $ProjectName -ErrorAction SilentlyContinue)
    $existing = $endpoints | Where-Object { $_.name -eq $ServiceEndpointName } | Select-Object -First 1
    
    if ($existing) {
        Write-Host "Service Endpoint '$ServiceEndpointName' already exists."
        return $existing
    }

    Write-Host "Creating Service Endpoint '$ServiceEndpointName'..." -ForegroundColor Yellow

    try {
        $payload = @{
            url = $EnvironmentUrl
            data = @{}
        }

        if ($AuthType -eq 'WIF') {
            # Workload Identity Federation
            $payload.authorization = @{
                parameters = @{
                    "serviceprincipalid" = $ApplicationId
                    "tenantid" = $TenantId
                }
                scheme = "WorkloadIdentityFederation"
            }
        }
        else {
            # Traditional Service Principal with Secret
            if ([string]::IsNullOrWhiteSpace($ClientSecret)) {
                throw "ClientSecret is required when AuthType is 'Secret'."
            }
            
            $payload.authorization = @{
                parameters = @{
                    "tenantId" = $TenantId
                    "applicationId" = $ApplicationId
                    "clientSecret" = $ClientSecret
                }
                scheme = "None"
            }
        }

        $response = Add-VSTeamServiceEndpoint -ProjectName $ProjectName `
            -EndpointName $ServiceEndpointName `
            -EndpointType "powerplatform-spn" `
            -Object $payload

        Write-Host "Service Endpoint '$ServiceEndpointName' created successfully."
        Start-Sleep -Seconds 5 # Wait a bit for SE to be fully available
        # Re-fetch to ensure we have all properties including WIF issuer/subject assigned by Azure DevOps
        $fetched = @(Get-VSTeamServiceEndpoint -ProjectName $ProjectName -ErrorAction SilentlyContinue) | Where-Object { $_.name -eq $ServiceEndpointName } | Select-Object -First 1
        if ($fetched) { return $fetched }
        return $response
    }
    catch {
        Write-Host "Failed to create Service Endpoint '$ServiceEndpointName': $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

function Ensure-EntraIdServicePrincipal {
    param(
        [Parameter(Mandatory)][string]$ApplicationId,
        [Parameter(Mandatory)][string]$TenantId
    )

    $graphToken = Get-AuthToken -ResourceUrl "https://graph.microsoft.com" -TenantId $TenantId
    $headers = @{
        Authorization = "Bearer $($graphToken.AccessToken)"
        "Content-Type" = "application/json"
    }

    # Check if SP exists
    $uri = "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$ApplicationId'"
    try {
        $existing = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
        if ($existing.value.Count -gt 0) {
            Write-Host "Service Principal for App '$ApplicationId' already exists."
            return $existing.value[0]
        }
    }
    catch {
        Write-Warning "Failed to check for existing Service Principal: $($_.Exception.Message)"
    }

    # Create SP
    Write-Host "Creating Service Principal for App '$ApplicationId'..." -ForegroundColor Yellow
    $body = @{
        appId = $ApplicationId
    }
    
    try {
        $sp = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/servicePrincipals" -Headers $headers -Method Post -Body ($body | ConvertTo-Json)
        Write-Host "Created Service Principal ($($sp.id))."
        start-sleep -Seconds 10 # Wait a bit for SP to be fully available
        return $sp
    }
    catch {
        Write-Error "Failed to create Service Principal: $($_.Exception.Message)"
        throw
    }
}

function Add-EntraIdFederatedCredential {
    <#
    .SYNOPSIS
        Adds a federated identity credential to an Entra ID application for Workload Identity Federation.
    
    .DESCRIPTION
        Creates a federated identity credential that allows Azure DevOps to authenticate to Azure
        using Workload Identity Federation (WIF) without requiring client secrets.
    #>
    param(
        [Parameter(Mandatory)][string]$ApplicationObjectId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$Issuer,
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$CredentialName
    )

    $graphToken = Get-AuthToken -ResourceUrl "https://graph.microsoft.com" -TenantId $TenantId
    $headers = @{
        Authorization = "Bearer $($graphToken.AccessToken)"
        "Content-Type" = "application/json"
    }

    $issuer = $Issuer
    $subject = $Subject
    $credentialName = $CredentialName

    Write-Host "Adding federated identity credential '$credentialName'..." -ForegroundColor Yellow

    # Check if credential already exists
    $listUri = "https://graph.microsoft.com/beta/applications/$ApplicationObjectId/federatedIdentityCredentials"
    try {
        $existing = Invoke-RestMethod -Uri $listUri -Headers $headers -Method Get
        $existingCred = $existing.value | Where-Object { 
            $_.issuer -eq $issuer -and $_.subject -eq $subject 
        } | Select-Object -First 1
        
        if ($existingCred) {
            Write-Host "Federated identity credential already exists for this issuer and subject."
            return $existingCred
        }
    }
    catch {
        Write-Warning "Failed to check for existing federated credentials: $($_.Exception.Message)"
    }

    # Create the federated credential
    $body = @{
        name = $credentialName
        issuer = $issuer
        subject = $subject
        audiences = @("api://AzureADTokenExchange")
        description = "Workload Identity Federation for Azure DevOps service connection"
    }

    try {
        $credential = Invoke-RestMethod -Uri $listUri -Headers $headers -Method Post -Body ($body | ConvertTo-Json)
        Write-Host "Created federated identity credential successfully."
        return $credential
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
        [Parameter()][string]$AuthType = 'Secret'
    )
    
    # Get token for Graph
    $graphToken = Get-AuthToken -ResourceUrl "https://graph.microsoft.com" -TenantId $TenantId
    $headers = @{
        Authorization = "Bearer $($graphToken.AccessToken)"
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
            displayName = $DisplayName
            signInAudience = "AzureADMyOrg"
        }
        $app = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/applications" -Headers $headers -Method Post -Body ($body | ConvertTo-Json)
        Write-Host "Created App Registration '$DisplayName' ($($app.appId))."
    }

    [void](Ensure-EntraIdServicePrincipal -ApplicationId $app.appId -TenantId $TenantId)

    $result = [pscustomobject]@{
        Name = $DisplayName
        ApplicationId = $app.appId
        ApplicationObjectId = $app.id
        ClientSecret = $null
        TenantId = $TenantId
        AuthType = $AuthType
        IsExistingServiceConnection = $false
    }

    if ($AuthType -ne 'WIF') {
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

function Get-PowerPlatformSCCredentials {
    [CmdletBinding()]
    param(
        [Parameter()][array]$ExistingCredentials,
        [Parameter()][string]$TenantId,
        [Parameter()][string]$ProjectName,
        [Parameter()][string]$EnvironmentName,
        [Parameter()][string]$OrganizationId,
        [Parameter()][string]$OrganizationName
    )

    # 1. Try to find existing Service Connection to see if we can reuse its App ID
    $existingScAppId = $null
    try {
        $endpoints = @(Get-VSTeamServiceEndpoint -ProjectName $ProjectName -ErrorAction SilentlyContinue)
        $existingEndpoint = $endpoints | Where-Object { $_.name -eq $EnvironmentName } | Select-Object -First 1
        if ($existingEndpoint -and $existingEndpoint.authorization -and $existingEndpoint.authorization.parameters) {
            $existingScAppId = $existingEndpoint.authorization.parameters.applicationId
        }
    }
    catch {
        # Ignore errors checking for existing SC
    }

    # 2. Search Entra ID for relevant applications
    $foundApps = @()
    try {
        $graphToken = Get-AuthToken -ResourceUrl "https://graph.microsoft.com" -TenantId $TenantId
        $headers = @{ Authorization = "Bearer $($graphToken.AccessToken)" }

        # If we have an existing SC App ID, ensure it's in the list
        if ($existingScAppId) {
            $alreadyFound = $foundApps | Where-Object { $_.appId -eq $existingScAppId }
            if (-not $alreadyFound) {
                $filter = "appId eq '$existingScAppId'"
                $uri = "https://graph.microsoft.com/v1.0/applications?`$filter=$filter&`$select=appId,displayName,id"
                $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
                if ($response.value) {
                    $foundApps += $response.value
                }
            }
        }
    }
    catch {
        Write-Warning "Failed to list applications from Entra ID: $($_.Exception.Message)"
    }

    # 3. Build Menu
    $menuItems = @()
    $menuActions = @() # To track what each item does

    # Priority 1: Recommended App (Existing SC or Exact Name Match)
    $recommendedApp = $null
    $exactNameMatch = "$ProjectName - $EnvironmentName - deployment"
    
    if ($existingScAppId) {
        $recommendedApp = $foundApps | Where-Object { $_.appId -eq $existingScAppId } | Select-Object -First 1
    }
   
    if ($recommendedApp) {
        $menuItems += "Use existing: $($recommendedApp.displayName) ($($recommendedApp.appId))"
        $menuActions += @{ Type = 'ExistingSCApp'; App = $recommendedApp }
        
        # Remove from foundApps to avoid duplicate listing
        $foundApps = $foundApps | Where-Object { $_.appId -ne $recommendedApp.appId }
    }

    # Standard Options
    $menuItems += "Create new App Registration (Entra ID)"
    $menuActions += @{ Type = 'CreateNew' }

    $menuItems += "Enter existing Service Principal details"
    $menuActions += @{ Type = 'Manual' }

    # Cached Credentials
    foreach ($c in $ExistingCredentials) {
        $menuItems += "Reuse: $($c.Name) ($($c.ApplicationId))"
        $menuActions += @{ Type = 'Cached'; Creds = $c }
    }
 

    # 4. Show Menu
    Write-Host ""
    Write-Host "Service Principal credentials are used to authenticate the pipeline to Dataverse." -ForegroundColor Green
    Write-Host "Learn more: https://github.com/rnwood/ALM4Dataverse/tree/$ALM4DataverseRef/docs/config/environment-service-connection.md" -ForegroundColor Green
    Write-Host ""
    
    $selection = Select-FromMenu -Title "Select Service Principal credentials for '$EnvironmentName'" -Items $menuItems
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
        $authTypeSelection = Select-FromMenu -Title "Select authentication type for the new service connection" -Items $authTypeItems
        if ($null -eq $authTypeSelection) { throw "No authentication type selected." }
        
        $authType = if ($authTypeSelection -eq 1) { 'Secret' } else { 'WIF' }
        
        $appName = "$ProjectName - $EnvironmentName - deployment"
        
        if ($authType -eq 'WIF') {
            return New-EntraIdApplication `
                -DisplayName $appName `
                -TenantId $TenantId `
                -AuthType 'WIF'
        }
        else {
            return New-EntraIdApplication `
                -DisplayName $appName `
                -TenantId $TenantId `
                -AuthType 'Secret'
        }
    }
    elseif ($action.Type -eq 'ExistingSCApp') {
        $app = $action.App
        Write-Host "Using existing service connection with App: $($app.displayName) ($($app.appId))" -ForegroundColor Cyan
     
        # Since the service connection already exists, we just return a marker object
        # The credentials are already configured in the existing service connection
        return [pscustomobject]@{
            Name = $app.displayName
            ApplicationId = $app.appId
            ApplicationObjectId = $app.id
            ClientSecret = $null
            TenantId = $TenantId
            AuthType = 'Unknown' # Existing SC, auth type already configured
            IsExistingServiceConnection = $true
        }
    }
    else { # Manual
        Write-Host "Enter Service Principal details:" -ForegroundColor Cyan
        $name = Read-Host "Credential Name (for reuse reference)"
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

        # Prompt for authentication type
        Write-Host ""
        $authTypeItems = @(
            "Service Principal with Secret (traditional)",
            "Workload Identity Federation (recommended, no secrets)"
        )
        $authTypeSelection = Select-FromMenu -Title "Select authentication type" -Items $authTypeItems
        if ($null -eq $authTypeSelection) { throw "No authentication type selected." }
        
        $authType = if ($authTypeSelection -eq 0) { 'Secret' } else { 'WIF' }
        
        $secret = $null
        if ($authType -eq 'Secret') {
            while ($true) {
                $secretSecure = Read-Host "Client Secret" -AsSecureString
                $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secretSecure)
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
            Name = $name
            ApplicationId = $appId
            ApplicationObjectId = $null
            ClientSecret = $secret
            TenantId = $TenantId
            AuthType = $authType
            IsExistingServiceConnection = $false
        }
    }
}

function Get-DataverseServiceAccountUPN {
    [CmdletBinding()]
    param(
        [Parameter()][array]$ExistingServiceAccounts,
        [Parameter()][string]$EnvironmentName,
        [Parameter()][string]$ExistingValue
    )

    # Build Menu
    $menuItems = @()
    $menuActions = @() # To track what each item does

    # Priority 1: Existing value from variable group (if provided)
    if (-not [string]::IsNullOrWhiteSpace($ExistingValue)) {
        $menuItems += "Use existing: $ExistingValue"
        $menuActions += @{ Type = 'Existing'; UPN = $ExistingValue }
    }

    # Standard Options
    $menuItems += "Enter a new service account UPN"
    $menuActions += @{ Type = 'Manual' }

    # Cached Service Accounts (exclude the existing value to avoid duplication)
    foreach ($sa in $ExistingServiceAccounts) {
        if ($sa -ne $ExistingValue) {
            $menuItems += "Reuse: $sa"
            $menuActions += @{ Type = 'Cached'; UPN = $sa }
        }
    }

    # Show Menu
    Write-Host ""
    Write-Host "Service Account credentials are used for ownership and licencing of Cloud Flows." -ForegroundColor Green
    Write-Host "This must be a licenced user account with System Administrator role." -ForegroundColor Green
    Write-Host "Learn more: https://github.com/rnwood/ALM4Dataverse/tree/$ALM4DataverseRef/docs/config/environment-service-connection.md" -ForegroundColor Green
    Write-Host ""
    
    $selection = Select-FromMenu -Title "Select Dataverse Service Account for '$EnvironmentName'" -Items $menuItems
    if ($null -eq $selection) { throw "No service account selected." }

    $action = $menuActions[$selection]

    if ($action.Type -eq 'Cached' -or $action.Type -eq 'Existing') {
        return $action.UPN
    }
    else { # Manual
        Write-Host ""
        Write-Host "IMPORTANT: The service account must be licenced with an appropriate D365/PowerApps/etc licence for your use-case." -ForegroundColor Yellow
        Write-Host ""
        
        while ($true) {
            $upn = Read-Host "Service Account UPN (e.g., serviceaccount@contoso.com)"
            if ([string]::IsNullOrWhiteSpace($upn)) {
                Write-Warning "Service Account UPN cannot be empty. Please try again."
                continue
            }
            # Basic UPN format validation
            if ($upn -match '^[^@]+@[^@]+\.[^@]+$') {
                return $upn
            }
            else {
                Write-Warning "The UPN does not appear to be in a valid UPN format. Please try again."
            }
        }
    }
}

function Ensure-AzDoVariableGroupExists {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$GroupName,
        [Parameter(Mandatory)][hashtable]$Variables
    )

    $group = $null

    # Use VSTeam command to check for existing variable groups
    try {
        $existing = Get-VSTeamVariableGroup -ProjectName $Project -Name $GroupName -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Host "Variable group '$GroupName' already exists (id: $($existing.id))."
            $group = $existing
        }
    }
    catch {
        # Group doesn't exist, continue with creation
    }

    if (-not $group) {
        Write-Host "Creating variable group '$GroupName'..." -ForegroundColor Yellow

        # Build variables payload in the format expected by Add-VSTeamVariableGroup
        $variablesPayload = @{}
        foreach ($k in $Variables.Keys) {
            $variablesPayload[$k] = @{ value = [string]$Variables[$k] }
        }

        # Use VSTeam command to create variable group
        $created = Add-VSTeamVariableGroup -ProjectName $Project -Name $GroupName -Type 'Vsts' -Variables $variablesPayload -Description 'ALM4Dataverse environment variable group (created by setup.ps1)'

        if ($created -and $created.id) {
            Write-Host "Created variable group '$GroupName' (id: $($created.id))."
            $group = $created
        }
        else {
            Write-Host "Created variable group '$GroupName'."
            $group = $created
        }
    }

    if ($group -and $group.id) {
        Ensure-AzDoVariableGroupExclusiveLock -Organization $Organization -Project $Project -VariableGroupId $group.id -VariableGroupName $GroupName

        if ($GroupName -notmatch 'Dev') {
            $envName = $GroupName -replace '^Environment-', ''
            $team = Ensure-AzDoDeploymentApproversTeam -ProjectName $Project -EnvironmentName $envName
            Ensure-AzDoVariableGroupApproval -Organization $Organization -Project $Project -VariableGroupId $group.id -VariableGroupName $GroupName -ApproverTeam $team
            
        }
    }

    return $group
}

function Update-AzDoVariableGroup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$GroupName,
        [Parameter(Mandatory)][hashtable]$Variables
    )

    try {
        $group = Get-VSTeamVariableGroup -ProjectName $ProjectName -Name $GroupName -ErrorAction SilentlyContinue
        if (-not $group) {
            Write-Warning "Variable group '$GroupName' not found. Cannot update."
            return $null
        }

        Write-Host "Updating variable group '$GroupName'..." -ForegroundColor DarkGray

        # Build variables payload in the format expected by Update-VSTeamVariableGroup
        $variablesPayload = @{}
        
        # First, copy existing variables if the group has any
        if ($group.variables) {
            foreach ($key in $group.variables.PSObject.Properties.Name) {
                $variablesPayload[$key] = @{ value = $group.variables.$key.value }
            }
        }

        # Then add/update with new variables
        foreach ($k in $Variables.Keys) {
            $variablesPayload[$k] = @{ value = [string]$Variables[$k] }
        }

        # Use VSTeam command to update variable group
        Update-VSTeamVariableGroup -ProjectName $ProjectName -Id $group.id -Name $GroupName -Type 'Vsts' -Variables $variablesPayload -Description $group.description | Out-Null

        Write-Host "Variable group '$GroupName' updated successfully."
        return $group
    }
    catch {
        Write-Warning "Failed to update variable group '$GroupName': $($_.Exception.Message)"
        return $null
    }
}

Write-Section "Ensuring main repository contains pipeline YAMLs"

Write-Section "Ensuring environment variable group"

# Create the environment variable group only if it doesn't exist.
# This seeds example values that you can later replace with your real connection reference ids / environment variable values.
Invoke-WithErrorHandling -OperationName "Creating Environment Variable Group" -ScriptBlock {
    [void](Ensure-AzDoVariableGroupExists `
            -Organization $orgName `
            -Project $selectedProject.Name `
            -ProjectId $selectedProject.Id `
            -GroupName 'Environment-Dev-main' `
            -Variables @{
            'CONNREF_example_uniquename' = 'connectionid'
            'ENVVAR_example_uniquename'  = 'value'
        })
} | Out-Null

$mainRepo = Select-AzDoMainRepository -ProjectName $selectedProject.Name -SharedRepositoryName $sharedRepoName

Invoke-WithErrorHandling -OperationName "Syncing Pipeline Files to Main Repository" -ScriptBlock {
    # Determine copy-to-your-repo folder location
    # When running from a file, use PSScriptRoot. When downloaded and run via iex, clone the shared repo.
    if ($PSScriptRoot) {
        # Running from a file - use local path
        $copyRoot = Join-Path $PSScriptRoot 'copy-to-your-repo'
        Sync-CopyToYourRepoIntoGitRepo -SourceRoot $copyRoot -TargetRepo $mainRepo -PreferredBranch 'main'
    }
    else {
        # Running via iex (no PSScriptRoot) - clone the shared repo to get copy-to-your-repo
        $sharedRepoClone = Join-Path $env:TEMP ("ALM4Dataverse-SharedRepo-" + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $sharedRepoClone -Force | Out-Null
        
        try {
            Write-Host "Cloning shared repository to get template files..." -ForegroundColor Yellow
            & git -c "http.extraheader=AUTHORIZATION: bearer $azDevOpsAccessToken" clone $repo.remoteUrl $sharedRepoClone
            if ($LASTEXITCODE -ne 0) {
                throw "Git clone of shared repository failed with exit code $LASTEXITCODE"
            }
            
            $copyRoot = Join-Path $sharedRepoClone 'copy-to-your-repo'
            Sync-CopyToYourRepoIntoGitRepo -SourceRoot $copyRoot -TargetRepo $mainRepo -PreferredBranch 'main'
        }
        finally {
            # Clean up the temporary clone
            if (Test-Path $sharedRepoClone) {
                Remove-Item -LiteralPath $sharedRepoClone -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
} | Out-Null

Invoke-WithErrorHandling -OperationName "Setting Up Build Service Permissions" -ScriptBlock {
    Write-Section "Ensuring Build Service has Contribute on main repo"
    Ensure-AzDoBuildServiceHasContributeOnRepo -Organization $orgName -ProjectName $selectedProject.Name -ProjectId $selectedProject.Id -RepositoryId $mainRepo.Id
} | Out-Null

Invoke-WithErrorHandling -OperationName "Creating Pipeline Definitions" -ScriptBlock {
    # Create/ensure actual Azure DevOps pipelines that point at the YAML files we just synced.
    $script:mainRepoBranch = 'main'
    if ($mainRepo.defaultBranch) {
        $script:mainRepoBranch = ConvertFrom-GitRefToBranchName -Ref $mainRepo.defaultBranch
    }

    $script:yamlFiles = @(
        'pipelines/BUILD.yml',
        "pipelines/DEPLOY-$script:mainRepoBranch.yml",
        'pipelines/EXPORT.yml',
        'pipelines/IMPORT.yml'
    )

    Ensure-AzDoPipelinesForMainRepo -Organization $orgName -Project $selectedProject.Name -Repository $mainRepo -YamlFiles $script:yamlFiles -FolderPath "\$($mainRepo.Name)"
} | Out-Null

Invoke-WithErrorHandling -OperationName "Authorizing Pipelines for Repositories" -AllowSkip -ScriptBlock {
    # Authorize pipelines for repositories
    Write-Section "Authorizing pipelines for repositories"
    $pipelineNames = $yamlFiles | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) }

    # Get all pipelines once to avoid multiple calls
    $allPipelines = Get-VSTeamBuildDefinition -ProjectName $selectedProject.Name
    $pipelineFolder = "\$($mainRepo.Name)"

    foreach ($name in $pipelineNames) {
        $pipeline = $allPipelines | Where-Object { $_.name -eq $name -and $_.path -eq $pipelineFolder } | Select-Object -First 1
        
        if ($pipeline) {
            # Authorize Main Repo
            $mainRepoResourceId = "$($selectedProject.Id).$($mainRepo.Id)"
            Ensure-AzDoPipelinePermission -Organization $orgName -Project $selectedProject.Name -ResourceType 'repository' -ResourceId $mainRepoResourceId -PipelineId $pipeline.id

            # Authorize Shared Repo
            $sharedRepoResourceId = "$($selectedProject.Id).$($repo.Id)"
            Ensure-AzDoPipelinePermission -Organization $orgName -Project $selectedProject.Name -ResourceType 'repository' -ResourceId $sharedRepoResourceId -PipelineId $pipeline.id
        }
    }
} | Out-Null

#endregion

#region Dev Environment and Solutions Selection

function Get-ExistingSolutionsFromRepo {
    param(
        [Parameter(Mandatory)][object]$MainRepo,
        [Parameter(Mandatory)][string]$AccessToken
    )
    
    if (-not $MainRepo.remoteUrl) { return @() }

    $cloneRoot = Join-Path $env:TEMP ("ALM4Dataverse-ConfigRead-" + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $cloneRoot -Force | Out-Null

    try {
        Write-Host "Checking existing configuration in '$($MainRepo.Name) ($($MainRepo.remoteUrl))'..." -ForegroundColor DarkGray
        cmd /c git -c "http.extraheader=AUTHORIZATION: bearer $accessToken" clone --depth 1 $MainRepo.remoteUrl $cloneRoot 2`>`&1 | out-host
        
        if ($LASTEXITCODE -ne 0) { throw "Git clone failed with exit code $LASTEXITCODE." }

        $configPath = Join-Path $cloneRoot 'alm-config.psd1'
        if (Test-Path $configPath) {
            $config = Import-PowerShellDataFile -Path $configPath
            if ($config.solutions) {
                return $config.solutions
            }
        }
        return @()
    }
    finally {
        try { Remove-Item -LiteralPath $cloneRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Get-DataverseSolutionsSelection {
    [CmdletBinding()]
    param(
        [Parameter()][object]$MainRepo
    )
    
    try {
        Write-Host ""
        Write-Host "When prompted, select your dataverse DEV environment containing the solution(s) you want to manage" -ForegroundColor Green
        Write-Host ""

        # Select environment using the helper function
        $selectedEnv = Select-DataverseEnvironment -Prompt "Select your DEV environment"
        if (-not $selectedEnv) {
            throw "No environment selected."
        }

        $devEnvUrl = $selectedEnv.Endpoints["WebApplication"]
        Write-Host "Selected environment: $($selectedEnv.FriendlyName) ($devEnvUrl)" -ForegroundColor Cyan

        # Connect to the selected environment
        $connection = Get-DataverseConnection -Url $devEnvUrl -AccessToken { 
            param($resource)
            if (-not $resource) { $resource = 'https://globaldisco.crm.dynamics.com/' }
            try {
                $uri = [System.Uri]$resource
                $resource = $uri.GetLeftPart([System.UriPartial]::Authority)
            } catch {}
            $auth = Get-AuthToken -ResourceUrl $resource
            return $auth.AccessToken
        }
        
        if (-not $connection) {
            throw "Failed to connect to Dataverse environment."
        }
        
        Write-Host "Connected to environment: $($connection.ConnectedOrgFriendlyName)"
        Write-Host "Retrieving solutions..." -ForegroundColor Yellow
        
        # Get all solutions (excluding system solutions)
        $allSolutions = Get-DataverseRecord -Connection $connection -TableName 'solution' -Columns @('solutionid', 'uniquename', 'friendlyname', 'version', 'ismanaged', 'description') -FilterValues @{
            'isvisible' = $true
            'ismanaged' = $false
        }
        
        if (-not $allSolutions -or $allSolutions.Count -eq 0) {
            Write-Host "No unmanaged solutions found in the environment." -ForegroundColor Yellow
            return @{ Solutions = @(); EnvironmentUrl = $devEnvUrl }
        }
        
        # Filter out system solutions and prepare for selection
        $userSolutions = $allSolutions | Where-Object { 
            $_.uniquename -notmatch '^(Default|Active|Basic|msdyn_|ms|MicrosoftFlow|PowerPlatform)' -and 
            $_.uniquename -ne 'System' 
        } | Sort-Object friendlyname
        
        if (-not $userSolutions -or $userSolutions.Count -eq 0) {
            Write-Host "No user-created solutions found in the environment." -ForegroundColor Yellow
            return @{ Solutions = @(); EnvironmentUrl = $devEnvUrl }
        }

        $selectedSolutions = @()

        # Pre-populate from MainRepo
    
        $existingConfig = Get-ExistingSolutionsFromRepo -MainRepo $MainRepo -AccessToken $azDevOpsAccessToken
        foreach ($existing in $existingConfig) {
            $match = $userSolutions | Where-Object { $_.uniquename -eq $existing.name } | Select-Object -First 1
            if ($match) {
                $selectedSolutions += $match    
            }
        }
        if ($selectedSolutions.Count -gt 0) {
            Write-Host "Pre-selected $($selectedSolutions.Count) solution(s) from existing configuration." -ForegroundColor Green
            Start-Sleep -Seconds 2
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
            if ($selectedSolutions.Count -gt 0) {
                $menuItems += 'Done'
            }

            $selection = Select-FromMenu -Title "Manage solutions" -Items $menuItems

            if ($null -eq $selection) { 
                if ($selectedSolutions.Count -gt 0) {
                    break
                }
                return @{ Solutions = @(); EnvironmentUrl = $devEnvUrl } 
            }

            $action = $menuItems[$selection]

            switch ($action) {
                'Add a solution' {
                    # Filter out already selected
                    $availableSolutions = $userSolutions | Where-Object { 
                        $u = $_.uniquename
                        -not ($selectedSolutions | Where-Object { $_.uniquename -eq $u })
                    }

                    if ($availableSolutions.Count -eq 0) {
                        Write-Host "All available solutions have been selected." -ForegroundColor Yellow
                        Start-Sleep -Seconds 2
                        continue
                    }

                    $solMenu = @()
                    foreach ($s in $availableSolutions) {
                        $solMenu += "$($s.friendlyname) ($($s.uniquename))"
                    }
                    $solMenu += "--- Cancel ---"

                    $solIndex = Select-FromMenu -Title "Select a solution to add" -Items $solMenu
                    
                    if ($null -ne $solIndex -and $solIndex -lt $availableSolutions.Count) {
                        $selectedSolutions += $availableSolutions[$solIndex]
                    }
                }
                'Clear list' {
                    $selectedSolutions = @()
                    Write-Host "List cleared." -ForegroundColor Yellow
                    Start-Sleep -Seconds 1
                }
                'Done' {
                    break
                }
            }
            
            if ($action -eq 'Done') { break }
        }
        
        if ($selectedSolutions.Count -eq 0) {
            Write-Host "No solutions selected." -ForegroundColor Yellow
            return @{ Solutions = @(); EnvironmentUrl = $devEnvUrl }
        }
        
        Write-Host "Final selection:"
        foreach ($sol in $selectedSolutions) {
            Write-Host "  - $($sol.friendlyname) ($($sol.uniquename))"
        }
        
        # Convert to the format needed for alm-config.psd1
        $configSolutions = @()
        foreach ($sol in $selectedSolutions) {
            $configSolutions += @{
                name            = $sol.uniquename
                deployUnmanaged = $false
            }
        }
        
        return @{ Solutions = $configSolutions; EnvironmentUrl = $devEnvUrl }
        
    }
    catch {
        Write-Host "Error retrieving solutions from Dataverse: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

function Update-AlmConfigInMainRepo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][array]$Solutions,
        [Parameter(Mandatory)][object]$MainRepo,
        [Parameter(Mandatory)][string]$AccessToken
    )
    
    if (-not $MainRepo.remoteUrl) {
        throw "Could not determine remoteUrl for repository '$($MainRepo.Name)'."
    }

    $cloneRoot = Join-Path $env:TEMP ("ALM4Dataverse-ConfigUpdate-" + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $cloneRoot -Force | Out-Null

    Write-Host "Cloning '$($MainRepo.Name)' to update alm-config.psd1..." -ForegroundColor Yellow
    try {
        & git -c "http.extraheader=AUTHORIZATION: bearer $AccessToken" clone $MainRepo.remoteUrl $cloneRoot
        if ($LASTEXITCODE -ne 0) {
            throw "Git clone exited with code $LASTEXITCODE"
        }
    }
    catch {
        throw "Git clone failed for '$($MainRepo.remoteUrl)': $($_.Exception.Message)"
    }

    Push-Location $cloneRoot
    try {
        $branch = 'main'
        if ($MainRepo.defaultBranch) {
            $branch = ConvertFrom-GitRefToBranchName -Ref $MainRepo.defaultBranch
        }

        # Checkout the correct branch
        & git checkout $branch
        if ($LASTEXITCODE -ne 0) {
            throw "Git checkout failed with exit code $LASTEXITCODE"
        }

        # Update the alm-config.psd1 file
        $configPath = Join-Path $cloneRoot 'alm-config.psd1'
        if (-not (Test-Path $configPath)) {
            Write-Host "alm-config.psd1 not found in main repository. Skipping update." -ForegroundColor Yellow
            return $false
        }

        # Read the current config file
        $configContent = Get-Content -LiteralPath $configPath -Raw
        
        # Build the solutions array string
        $solutionsArray = "    solutions = @("
        if ($Solutions.Count -gt 0) {
            $solutionsArray += "`n"
            foreach ($solution in $Solutions) {
                $solutionsArray += "        @{`n"
                $solutionsArray += "            name = '$($solution.name)'`n"
                if ($solution.deployUnmanaged) {
                    $solutionsArray += "            deployUnmanaged = `$$true`n"
                }
                $solutionsArray += "        }`n"
            }
            $solutionsArray += "    )`n"
        }
        else {
            $solutionsArray += "`n    )`n"
        }
        
        # Replace the solutions array in the config
        $updatedContent = $configContent -replace '(?s)    solutions = @\([^)]*\)', $solutionsArray
        
        # Write back to file
        Set-Content -LiteralPath $configPath -Value $updatedContent -NoNewline

        # Check for changes
        & git add alm-config.psd1
        if ($LASTEXITCODE -ne 0) {
            throw "Git add failed with exit code $LASTEXITCODE"
        }
        
        # Check if there are changes to commit
        & git diff --cached --quiet
        $hasChanges = ($LASTEXITCODE -ne 0)
        
        if ($hasChanges) {
            Write-Host "Committing alm-config.psd1 changes..." -ForegroundColor Yellow
            
            # Configure git user if not already configured
            & git config user.name "ALM4Dataverse Setup" 2>$null
            & git config user.email "setup@alm4dataverse.local" 2>$null
            
            & git commit -m "Update alm-config.psd1 with selected solutions"
            if ($LASTEXITCODE -ne 0) {
                throw "Git commit failed with exit code $LASTEXITCODE"
            }

            Write-Host "Pushing changes to origin/$branch..." -ForegroundColor Yellow
            & git -c "http.extraheader=AUTHORIZATION: bearer $AccessToken" push origin $branch
            if ($LASTEXITCODE -ne 0) {
                throw "Git push failed with exit code $LASTEXITCODE. Ensure you have permission and that authentication succeeds."
            }
            Write-Host "alm-config.psd1 updated successfully in main repository."
            return $true
        }
        else {
            Write-Host "No changes to alm-config.psd1; solutions already configured."
            return $false
        }
    }
    finally {
        Pop-Location
        try { Remove-Item -LiteralPath $cloneRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

#endregion

#region Deployment Environments Selection

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
            "applicationid" = $ApplicationId
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
            roleid = $roleId
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

    # 3. Find the System User by UPN
    $user = Get-DataverseRecord -Connection $conn -TableName "systemuser" -FilterValues @{ 
        domainname = $ServiceAccountUPN
    } -Columns "systemuserid","fullname" | Select-Object -First 1
    
    $userId = $null
    if ($user) {
        $userId = $user.systemuserid
        Write-Host "Found service account user: $($user.fullname) (ID: $userId)"
    }
    else {
        Write-Host "Service account user '$ServiceAccountUPN' not found. Creating..."
        $userAttributes = @{
            "domainname" = $ServiceAccountUPN
            "businessunitid" = $rootBuId
            "internalemailaddress" = $ServiceAccountUPN
            "firstname" = "Service"
            "lastname" = "Account"
        }
        $createdUser = $userAttributes | Set-DataverseRecord -Connection $conn -TableName "systemuser" -CreateOnly -PassThru
        $userId = $createdUser.Id
        Write-Host "Service account user created. ID: $userId"
    }

    # 4. Associate User with Role
    $existingAssociation = Get-DataverseRecord -Connection $conn -TableName "systemuserroles" -FilterValues @{ systemuserid = $userId; roleid = $roleId } -Top 1
    if (-not $existingAssociation) {
        Write-Host "Associating service account with '$roleName' role..."
        @{
            systemuserid = $userId
            roleid = $roleId
        } | Set-DataverseRecord -Connection $conn -TableName "systemuserroles" -CreateOnly
        Write-Host "Association successful."
    }
    else {
        Write-Host "Service account is already associated with '$roleName' role."
    }
}

function Get-ExistingEnvironmentsFromRepo {
    param(
        [Parameter(Mandatory)][object]$MainRepo,
        [Parameter(Mandatory)][string]$AccessToken
    )
    
    if (-not $MainRepo.remoteUrl) { return @() }

    $cloneRoot = Join-Path $env:TEMP ("ALM4Dataverse-EnvRead-" + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $cloneRoot -Force | Out-Null

    try {
        Write-Host "Checking existing environments in '$($MainRepo.Name)'..." -ForegroundColor DarkGray
        cmd /c git -c "http.extraheader=AUTHORIZATION: bearer $AccessToken" clone --depth 1 $MainRepo.remoteUrl $cloneRoot 2`>`&1 | out-host
        
        if ($LASTEXITCODE -ne 0) { return @() }

        $branch = 'main'
        if ($MainRepo.defaultBranch) {
            $branch = ConvertFrom-GitRefToBranchName -Ref $MainRepo.defaultBranch
        }
        $deployYamlName = "DEPLOY-$branch.yml"

        $deployPath = Join-Path $cloneRoot "pipelines\$deployYamlName"
        if (Test-Path $deployPath) {
            $content = Get-Content -LiteralPath $deployPath -Raw
            # Regex to find environmentName: value
            $matches = [regex]::Matches($content, 'environmentName:\s*([^\s]+)')
            $envs = @()
            foreach ($m in $matches) {
                $envs += $m.Groups[1].Value
            }
            return $envs
        }
        return @()
    }
    finally {
        try { Remove-Item -LiteralPath $cloneRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Get-DataverseEnvironmentsSelection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)][string]$ExcludedUrl,
        [Parameter()][object]$MainRepo,
        [Parameter()][string]$AccessToken,
        [Parameter()][string]$ProjectName
    )

    $selectedEnvironments = @()

    # Pre-populate from MainRepo if provided
    if ($MainRepo -and $AccessToken -and $ProjectName) {
        $existingNames = @(Get-ExistingEnvironmentsFromRepo -MainRepo $MainRepo -AccessToken $AccessToken)
        
        if ($existingNames.Count -gt 0) {
            Write-Host "Found $($existingNames.Count) environment(s) in deployment pipeline. Resolving details..." -ForegroundColor Cyan
            
            # Get Service Endpoints to resolve URLs
            $endpoints = @(Get-VSTeamServiceEndpoint -ProjectName $ProjectName -ErrorAction SilentlyContinue)
            
            # Also get all Dataverse environments for mapping
            $allDataverseEnvs = @(Get-DataverseEnvironment -AccessToken { 
                param($resource)
                if (-not $resource) { $resource = 'https://globaldisco.crm.dynamics.com/' }
                try {
                    $uri = [System.Uri]$resource
                    $resource = $uri.GetLeftPart([System.UriPartial]::Authority)
                } catch {}
                $auth = Get-AuthToken -ResourceUrl $resource
                return $auth.AccessToken
            })
            
            foreach ($name in $existingNames) {
                # Skip if we already have this environment (case-insensitive)
                if ($selectedEnvironments | Where-Object { $_.ShortName -ieq $name }) {
                    continue
                }
                
                $ep = $endpoints | Where-Object { $_.name -eq $name } | Select-Object -First 1
                if ($ep -and $ep.url) {
                    # Try to find matching Dataverse environment for FriendlyName
                    $dvEnv = $allDataverseEnvs | Where-Object { $_.Endpoints["WebApplication"] -eq $ep.url } | Select-Object -First 1
                    $friendlyName = if ($dvEnv) { $dvEnv.FriendlyName } else { "$name (Existing)" }
                    
                    $selectedEnvironments += [pscustomobject]@{
                        ShortName = $name
                        FriendlyName = $friendlyName
                        Url = $ep.url
                    }
                }
                else {
                    Write-Warning "Environment '$name' found in pipeline but no matching Service Endpoint found. Skipping pre-population."
                }
            }
        }
    }

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
        if ($selectedEnvironments.Count -gt 0) {
            $menuItems += 'Done'
        }

        $selection = Select-FromMenu -Title "Manage deployment environments" -Items $menuItems

        if ($null -eq $selection) { return $selectedEnvironments }

        $action = $menuItems[$selection]

        switch ($action) {
            'Add an environment' {
                try {
                    # Use the helper function to select an environment
                    $selectedEnv = Select-DataverseEnvironment -Prompt "Select a deployment environment" -ExcludeUrl $ExcludedUrl
                    
                    if (-not $selectedEnv) {
                        continue
                    }

                    $url = $selectedEnv.Endpoints["WebApplication"]

                    if ($selectedEnvironments | Where-Object { $_.Url -ieq $url }) {
                        Write-Host "An environment with Url '$url' is already selected." -ForegroundColor Red
                        Start-Sleep -Seconds 2
                        continue
                    }

                    Write-Host "Short environment names should often follow the pattern ENVIRONMENT-branch (e.g. TEST-main, UAT-main, PROD)" -ForegroundColor DarkGray

                    $shortName = Read-Host "Enter a short name for this environment (e.g. TEST-main, UAT-main, PROD)"
                    if ([string]::IsNullOrWhiteSpace($shortName)) {
                        Write-Host "Short name is required." -ForegroundColor Red
                        Start-Sleep -Seconds 2
                        continue
                    }
 
                    if ($selectedEnvironments | Where-Object { $_.ShortName -ieq $shortName }) {
                        Write-Host "An environment with short name '$shortName' is already selected (case-insensitive match)." -ForegroundColor Red
                        Start-Sleep -Seconds 2
                        continue
                    }

                    $envInfo = [pscustomobject]@{
                        ShortName = $shortName
                        FriendlyName = $selectedEnv.FriendlyName
                        Url = $url
                    }
                    $selectedEnvironments += $envInfo
                }
                catch {
                    Write-Host "Failed to select environment: $_" -ForegroundColor Red
                    Start-Sleep -Seconds 3
                }
            }
            'Clear list' {
                $selectedEnvironments = @()
                Write-Host "List cleared." -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
            'Done' {
                return $selectedEnvironments
            }
        }
    }
}

function Update-DeployPipelineInMainRepo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][array]$Environments,
        [Parameter(Mandatory)][object]$MainRepo,
        [Parameter(Mandatory)][string]$AccessToken
    )

    if ($Environments.Count -eq 0) { return }

    if (-not $MainRepo.remoteUrl) {
        throw "Could not determine remoteUrl for repository '$($MainRepo.Name)'."
    }

    $cloneRoot = Join-Path $env:TEMP ("ALM4Dataverse-DeployUpdate-" + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $cloneRoot -Force | Out-Null

    Write-Host "Cloning '$($MainRepo.Name)' to update deployment pipeline..." -ForegroundColor Yellow
    try {
        & git -c "http.extraheader=AUTHORIZATION: bearer $AccessToken" clone $MainRepo.remoteUrl $cloneRoot
        if ($LASTEXITCODE -ne 0) {
            throw "Git clone exited with code $LASTEXITCODE"
        }
    }
    catch {
        throw "Git clone failed for '$($MainRepo.remoteUrl)': $($_.Exception.Message)"
    }

    Push-Location $cloneRoot
    try {
        $branch = 'main'
        if ($MainRepo.defaultBranch) {
            $branch = ConvertFrom-GitRefToBranchName -Ref $MainRepo.defaultBranch
        }

        & git checkout $branch
        if ($LASTEXITCODE -ne 0) {
            throw "Git checkout failed with exit code $LASTEXITCODE"
        }

        $deployYamlName = "DEPLOY-$branch.yml"
        $deployYamlPath = Join-Path $cloneRoot "pipelines\$deployYamlName"
        if (-not (Test-Path $deployYamlPath)) {
            throw "pipelines\$deployYamlName not found"
        }

        # Remove existing environment stages
        $content = Get-Content -LiteralPath $deployYamlPath
        $cleanedContent = @()
        $i = 0
        while ($i -lt $content.Count) {
            $line = $content[$i]
            if ($line.Trim() -eq "- template: pipelines/templates/stages/deploy-environment.yml@ALM4Dataverse") {
                # Skip this line
                $i++
                # Skip parameters line if present
                if ($i -lt $content.Count -and $content[$i].Trim() -eq "parameters:") {
                    $i++
                    # Skip environmentName line if present
                    if ($i -lt $content.Count -and $content[$i].Trim().StartsWith("environmentName:")) {
                        $i++
                    }
                }
            }
            else {
                $cleanedContent += $line
                $i++
            }
        }
        
        $cleanedContent | Set-Content -LiteralPath $deployYamlPath

        $newStages = "`n"
        foreach ($env in $Environments) {
            $newStages += "  - template: pipelines/templates/stages/deploy-environment.yml@ALM4Dataverse`n"
            $newStages += "    parameters:`n"
            $newStages += "      environmentName: $($env.ShortName)`n"
        }

        Add-Content -LiteralPath $deployYamlPath -Value $newStages

        & git add "pipelines\$deployYamlName"
        
        & git diff --cached --quiet
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Committing $deployYamlName changes..." -ForegroundColor Yellow
            
            & git config user.name "ALM4Dataverse Setup" 2>$null
            & git config user.email "setup@alm4dataverse.local" 2>$null
            
            $envNames = $Environments | ForEach-Object { $_.ShortName }
            & git commit -m "Configure deployment environments: $($envNames -join ', ')"
            
            & git -c "http.extraheader=AUTHORIZATION: bearer $AccessToken" push origin $branch
            if ($LASTEXITCODE -ne 0) {
                throw "Git push failed."
            }
            Write-Host "$deployYamlName updated successfully."
        }
    }
    finally {
        Pop-Location
        try { Remove-Item -LiteralPath $cloneRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

Write-Section "Selecting Dataverse solution(s) to manage"

$solutionData = Invoke-WithErrorHandling -OperationName "Selecting Dataverse Solutions" -ScriptBlock {
    $result = Get-DataverseSolutionsSelection -MainRepo $mainRepo
    return $result
}

$solutions = $solutionData.Solutions
$devEnvUrl = $solutionData.EnvironmentUrl

if ($solutions.Count -gt 0) {
    Invoke-WithErrorHandling -OperationName "Updating alm-config.psd1 with Solutions" -AllowSkip -ScriptBlock {
        # Update alm-config.psd1 in the main repository and commit the changes
        $configUpdated = Update-AlmConfigInMainRepo -Solutions $solutions -MainRepo $mainRepo -AccessToken $azDevOpsAccessToken
        if ($configUpdated) {
            Write-Host "Updated alm-config.psd1 with $($solutions.Count) solution(s) in main repository."
        }
    } | Out-Null
}

Write-Section "Selecting Deployment Environments"

write-host "Select Dataverse environments to deploy to in the required order" -ForegroundColor Green

$environments = Invoke-WithErrorHandling -OperationName "Selecting Deployment Environments" -ScriptBlock {
    return Get-DataverseEnvironmentsSelection -ExcludedUrl $devEnvUrl -MainRepo $mainRepo -AccessToken $azDevOpsAccessToken -ProjectName $selectedProject.Name
}

if ($environments.Count -gt 0) {
    Invoke-WithErrorHandling -OperationName "Updating Deployment Pipeline" -AllowSkip -ScriptBlock {
        Update-DeployPipelineInMainRepo -Environments $environments -MainRepo $mainRepo -AccessToken $azDevOpsAccessToken
    } | Out-Null

    # Get pipeline IDs for authorization
    $pipelineFolder = "\$($mainRepo.Name)"
    $exportPipeline = Get-VSTeamBuildDefinition -ProjectName $selectedProject.Name | Where-Object { $_.name -eq 'EXPORT' -and $_.path -eq $pipelineFolder } | Select-Object -First 1
    $deployPipeline = Get-VSTeamBuildDefinition -ProjectName $selectedProject.Name | Where-Object { $_.name -eq "DEPLOY-$script:mainRepoBranch" -and $_.path -eq $pipelineFolder } | Select-Object -First 1

    if (-not $exportPipeline) { Write-Warning "EXPORT pipeline not found. Skipping authorization." }
    if (-not $deployPipeline) { Write-Warning "DEPLOY-$script:mainRepoBranch pipeline not found. Skipping authorization." }

    $credentialsCache = @()
    $serviceAccountsCache = @()

    # Add Dev environment to the list of environments to configure service connection for
    $allEnvs = @()
    $allEnvs += [pscustomobject]@{
        ShortName = "Dev-main"
        Url = $devEnvUrl
    }
    $allEnvs += $environments

    foreach ($env in $allEnvs) {
        Invoke-WithErrorHandling -OperationName "Configuring Service Connection for '$($env.ShortName)'" -ScriptBlock {
            Write-Section "Configuring Service Connection for environment '$($env.ShortName)'"
            

            $script:creds = Get-PowerPlatformSCCredentials `
            -ExistingCredentials $credentialsCache `
            -TenantId $adoAuthResult.TenantId `
            -ProjectName $selectedProject.Name `
            -EnvironmentName $env.ShortName `
            -OrganizationId $orgId `
            -OrganizationName $orgName
            if ($credentialsCache -notcontains $script:creds) {
                $script:credentialsCache += $script:creds
            }

            # Check for existing service account UPN in variable group
            $existingServiceAccountUPN = $null
            try {
                $existingVarGroup = Get-VSTeamVariableGroup -ProjectName $selectedProject.Name -Name "Environment-$($env.ShortName)" -ErrorAction SilentlyContinue
                if ($existingVarGroup -and $existingVarGroup.variables -and $existingVarGroup.variables.PSObject.Properties.Name -contains 'DataverseServiceAccountUPN') {
                    $existingServiceAccountUPN = $existingVarGroup.variables.DataverseServiceAccountUPN.value
                }
            }
            catch {
                # Ignore errors checking for existing value
            }

        # Get Service Account UPN
        Write-Host "Configuring Service Account for environment '$($env.ShortName)'..." -ForegroundColor Cyan
        $script:serviceAccountUPN = Get-DataverseServiceAccountUPN -ExistingServiceAccounts $serviceAccountsCache -EnvironmentName $env.ShortName -ExistingValue $existingServiceAccountUPN
        if ($serviceAccountsCache -notcontains $script:serviceAccountUPN) {
            $script:serviceAccountsCache += $script:serviceAccountUPN
        }
        
        $endpoint = $null
        if (-not $script:creds.IsExistingServiceConnection) {
            $endpointParams = @{
                ProjectName = $selectedProject.Name
                ServiceEndpointName = $env.ShortName
                EnvironmentUrl = $env.Url
                ApplicationId = $script:creds.ApplicationId
                TenantId = $script:creds.TenantId
            }
            
            # Add auth-specific parameters
            if ($script:creds.AuthType -eq 'WIF') {
                $endpointParams.AuthType = 'WIF'
            }
            else {
                $endpointParams.ClientSecret = $creds.ClientSecret
                $endpointParams.AuthType = 'Secret'
            }
            
            $endpoint = Ensure-AzDoServiceEndpoint @endpointParams

            # For WIF, add federated identity credential using issuer/subject from the service connection
            if ($script:creds.AuthType -eq 'WIF') {
                $wifIssuer = $endpoint.authorization.parameters.workloadIdentityFederationIssuer
                $wifSubject = $endpoint.authorization.parameters.workloadIdentityFederationSubject
                if ($wifIssuer -and $wifSubject) {
                    $appObjectId = $script:creds.ApplicationObjectId
                    if (-not $appObjectId) {
                        # Look up object ID from Graph API when not available (e.g. manually entered credentials)
                        $graphToken = Get-AuthToken -ResourceUrl "https://graph.microsoft.com" -TenantId $script:creds.TenantId
                        $gHeaders = @{ Authorization = "Bearer $($graphToken.AccessToken)" }
                        $gUri = "https://graph.microsoft.com/v1.0/applications?`$filter=appId eq '$($script:creds.ApplicationId)'&`$select=id,appId"
                        $gResult = Invoke-RestMethod -Uri $gUri -Headers $gHeaders -Method Get
                        if ($gResult.value.Count -gt 0) { $appObjectId = $gResult.value[0].id }
                    }
                    if ($appObjectId) {
                        $safeOrgName = ConvertTo-UrlSafeName -Name $orgName
                        $safeProjectName = ConvertTo-UrlSafeName -Name $selectedProject.Name
                        $safeSCName = ConvertTo-UrlSafeName -Name $env.ShortName
                        [void](Add-EntraIdFederatedCredential `
                            -ApplicationObjectId $appObjectId `
                            -TenantId $script:creds.TenantId `
                            -Issuer $wifIssuer `
                            -Subject $wifSubject `
                            -CredentialName "AzDO-$safeOrgName-$safeProjectName-$safeSCName")
                    } else {
                        Write-Warning "Could not determine Application Object ID. Federated credential not added - add it manually in Entra ID."
                    }
                } else {
                    Write-Warning "Service connection does not have WIF issuer/subject properties. Federated credential not added - add it manually in Entra ID."
                }
            }
        } else {
             # If it is existing, we need to fetch it to get the ID
             $endpoints = @(Get-VSTeamServiceEndpoint -ProjectName $selectedProject.Name -ErrorAction SilentlyContinue)
             $endpoint = $endpoints | Where-Object { $_.name -eq $env.ShortName } | Select-Object -First 1
        }

            # Authorize pipeline for Service Connection
            if ($endpoint -and $endpoint.id) {
                if ($env.ShortName -eq "Dev-main") {
                    if ($exportPipeline) {
                        Ensure-AzDoPipelinePermission -Organization $orgName -Project $selectedProject.Name -ResourceType 'endpoint' -ResourceId $endpoint.id -PipelineId $exportPipeline.id
                    }
                } else {
                    if ($deployPipeline) {
                        Ensure-AzDoPipelinePermission -Organization $orgName -Project $selectedProject.Name -ResourceType 'endpoint' -ResourceId $endpoint.id -PipelineId $deployPipeline.id
                    }
                }
            }
        } | Out-Null

        Invoke-WithErrorHandling -OperationName "Configuring Environment Resources for '$($env.ShortName)'" -ScriptBlock {
           write-section "Configuring Environment Resources for '$($env.ShortName)'"
            # Ensure Environment resource exists and authorize pipeline
            if ($env.ShortName -ne "Dev-main") {
                $azDoEnv = Ensure-AzDoEnvironment -Organization $orgName -Project $selectedProject.Name -EnvironmentName $env.ShortName -Description "Deployment environment for $($env.ShortName)"
                
                if ($azDoEnv -and $deployPipeline) {
                    Ensure-AzDoPipelinePermission -Organization $orgName -Project $selectedProject.Name -ResourceType 'environment' -ResourceId $azDoEnv.id -PipelineId $deployPipeline.id
                }
            }

            Ensure-DataverseApplicationUser `
                -EnvironmentUrl $env.Url `
                -ApplicationId $script:creds.ApplicationId `
                -TenantId $script:creds.TenantId

            # Ensure Service Account has System Administrator role
            Ensure-DataverseServiceAccountUser `
                -EnvironmentUrl $env.Url `
                -ServiceAccountUPN $script:serviceAccountUPN `
                -TenantId $script:creds.TenantId

            $varGroup = $null
            # Variable group for Dev is already created earlier, but we ensure it exists for others
            if ($env.ShortName -ne "Dev-main") {
                $varGroup = Ensure-AzDoVariableGroupExists `
                    -Organization $orgName `
                    -Project $selectedProject.Name `
                    -ProjectId $selectedProject.Id `
                    -GroupName "Environment-$($env.ShortName)" `
                    -Variables @{
                    'DATAVERSECONNREF_example_uniquename' = 'connectionid'
                    'DATAVERSEENVVAR_example_uniquename'  = 'value'
                    'DataverseServiceAccountUPN' = $script:serviceAccountUPN
                }
            } else {
                # Fetch and update Dev variable group with service account UPN
                $varGroup = Get-VSTeamVariableGroup -ProjectName $selectedProject.Name -Name "Environment-Dev-main" -ErrorAction SilentlyContinue
                if ($varGroup) {
                    Update-AzDoVariableGroup -ProjectName $selectedProject.Name -GroupName "Environment-Dev-main" -Variables @{
                        'DataverseServiceAccountUPN' = $script:serviceAccountUPN
                    } | Out-Null
                }
            }

            # Authorize pipeline for Variable Group
            if ($varGroup -and $varGroup.id) {
                 if ($env.ShortName -eq "Dev-main") {
                    if ($exportPipeline) {
                        Ensure-AzDoPipelinePermission -Organization $orgName -Project $selectedProject.Name -ResourceType 'variablegroup' -ResourceId $varGroup.id -PipelineId $exportPipeline.id
                    }
                } else {
                    if ($deployPipeline) {
                        Ensure-AzDoPipelinePermission -Organization $orgName -Project $selectedProject.Name -ResourceType 'variablegroup' -ResourceId $varGroup.id -PipelineId $deployPipeline.id
                    }
                }
            }
        } | Out-Null
    }
}

#endregion

Clear-Host
Write-Host "Setup completed successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "Access your Azure DevOps project at" -ForegroundColor Green
Write-Host "https://dev.azure.com/$orgName/$($selectedProject.Name)/_build" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Green
Write-Host "https://github.com/rnwood/ALM4Dataverse/tree/$ALM4DataverseRef#getting-started" -ForegroundColor Green
