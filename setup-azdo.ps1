
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
        throw "This script appears to be running in development mode but alm-config-defaults.psd1 was not found at $configPath. Please download the released version from https://github.com/ALM4Dataverse/ALM4Dataverse/releases/latest/download/setup-azdo.ps1"
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
    'VSTeam'                           = '7.15.2'
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

Write-Section `
    -Message "Authenticating"

Write-Host "To enable automated setup setup, we need to authenticate with the necessary services." -ForegroundColor Green
Write-Host ""
Write-Host "When prompted, please log in with an account that has access to:" -ForegroundColor Green
Write-Host "- Your Azure DevOps organization/project (PROJECT administrator role for existing project, ORGANISATION OWNER role if you want to create a new project)" -ForegroundColor Green
Write-Host "- Your Dataverse DEV environment (SYSTEM ADMINISTRATOR role)" -ForegroundColor Green
Write-Host ""

# Azure DevOps resource for AAD token acquisition.
$adoResourceUrl = '499b84ac-1321-427f-aa17-267ca6975798'

$cachedAzureAccounts = @(Get-AuthToken -ResourceUrl $adoResourceUrl -TenantId $TenantId -ListAccountsOnly)
$preferredAzureUsername = $null
$forceAzureInteractive = $false

if ($cachedAzureAccounts.Count -gt 0) {
    $azureAuthMenuItems = @($cachedAzureAccounts | ForEach-Object { "Use existing Azure login: $_" })
    $azureAuthMenuItems += "Sign in with a different Azure account"

    $azureAuthChoice = Select-FromMenu `
        -Title "Azure authentication" `
        -Items $azureAuthMenuItems `
        -PromptGuidanceLines @(
            'Choose whether to reuse an existing Azure login context or authenticate with a different identity.',
            'Use an identity with permissions to administer Azure DevOps resources and Dataverse setup prerequisites.'
        ) `
        -PromptGuidanceDocRelativePath 'docs/setup/azdo-automated-setup.md' `
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

$authResult = Invoke-WithErrorHandling -OperationName "Authentication" -ScriptBlock {
    $result = Get-AuthToken -ResourceUrl $adoResourceUrl -TenantId $TenantId -PreferredUsername $preferredAzureUsername -ForceInteractive:$forceAzureInteractive
    
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

    Write-Section `
        -Message "Creating new Azure DevOps project"
    Write-Host "Project: $ProjectName" -ForegroundColor Cyan

    $processes = @(Invoke-WithSpectreStatus -Status 'Retrieving Azure DevOps process templates...' -ScriptBlock {
        Get-VSTeamProcess
    })
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
    $procIndex = Select-FromMenu -Title "Select a process (template) for the new project" -Items $processNames -PromptGuidanceLines @(
        'Choose the process template for work items, boards, and backlog behavior in the new project.',
        'Pick the template that best matches your team''s delivery process.'
    ) -PromptGuidanceDocRelativePath 'docs/setup/azdo-automated-setup.md' -PromptGuidanceRef $ALM4DataverseRef
    if ($null -ne $procIndex) {
        $selectedProcessName = $processNames[$procIndex]
    }

    $selectedProcess = $processes | Where-Object { $_.name -eq $selectedProcessName } | Select-Object -First 1
    if (-not $selectedProcess -or -not $selectedProcess.id) {
        throw "Unable to resolve selected process '$selectedProcessName'."
    }

    # Use VSTeam command to create project - it handles async operation polling automatically
    try {
        # Note: Add-VSTeamProject uses -ProjectName instead of -Name and doesn't have VersionControlSource
        $addParams = @{
            ProjectName     = $ProjectName
            ProcessTemplate = $selectedProcessName
            Visibility      = $Visibility
        }

        $created = Invoke-WithSpectreStatus -Status "Creating project '$ProjectName' using process template '$selectedProcessName'..." -ScriptBlock {
            Add-VSTeamProject @addParams
        }
        
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

function Get-AzDoSharedRepositorySyncState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRemoteUrl,
        [Parameter(Mandatory)][string]$WorkRoot,
        [Parameter(Mandatory)][string]$UpstreamGitSource,
        [Parameter(Mandatory)][string]$Reference,
        [Parameter(Mandatory)][string]$AccessToken
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'

        & git -c "http.extraheader=AUTHORIZATION: bearer $AccessToken" clone $RepositoryRemoteUrl $WorkRoot | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Git clone failed with exit code $LASTEXITCODE"
        }

        & git -C $WorkRoot remote add upstream $UpstreamGitSource | Out-Null
        & git -C $WorkRoot fetch upstream | Out-Null

        & git -C $WorkRoot ls-remote --exit-code upstream $Reference | Out-Null
        if ($LASTEXITCODE -eq 2) {
            throw "Could not resolve reference '$Reference' from upstream repository."
        }
        if ($LASTEXITCODE -ne 0) {
            throw "Git ls-remote failed with exit code $LASTEXITCODE"
        }

        $lsRemoteOutput = (& git -C $WorkRoot ls-remote upstream $Reference | Select-Object -First 1)
        if ($lsRemoteOutput -match '^([a-f0-9]+)\s+(.+)$') {
            $commitSha = $Matches[1]
            $fullRef = $Matches[2]
            if ($fullRef -match '^refs/heads/(.+)$') {
                $targetRef = "upstream/$($Matches[1])"
            }
            elseif ($fullRef -match '^refs/tags/') {
                $targetRef = $commitSha
            }
            else {
                $targetRef = $Reference
            }
        }
        else {
            $targetRef = $Reference
        }

        $localHash = (& git -C $WorkRoot rev-parse HEAD).Trim()
        $upstreamHash = (& git -C $WorkRoot rev-parse $targetRef).Trim()

        $canFastForward = $false
        $isAhead = $false
        if ($localHash -ne $upstreamHash) {
            & git -C $WorkRoot merge-base --is-ancestor HEAD $targetRef
            $canFastForward = ($LASTEXITCODE -eq 0)

            if (-not $canFastForward) {
                & git -C $WorkRoot merge-base --is-ancestor $targetRef HEAD
                $isAhead = ($LASTEXITCODE -eq 0)
            }
        }

        return [pscustomobject]@{
            UpstreamRef    = $targetRef
            LocalHash      = $localHash
            UpstreamHash   = $upstreamHash
            CanFastForward = $canFastForward
            IsAhead        = $isAhead
        }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

Write-Section `
    -Message "Select Azure DevOps organization"

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
    Write-SetupDebug -Message "Azure DevOps accounts API returned $($orgs.Count) rows for memberId '$memberId'."
    if (Test-SetupDebugEnabled) {
        for ($orgIndex = 0; $orgIndex -lt $orgs.Count; $orgIndex++) {
            $org = $orgs[$orgIndex]
            $debugName = [string]$org.accountName
            $debugId = [string]$org.accountId
            $debugUri = [string]$org.accountUri
            Write-SetupDebug -Message "  raw[$orgIndex] name='$debugName' id='$debugId' uri='$debugUri'"
        }
    }
    
    if ($orgs.Count -eq 0) {
        throw "No Azure DevOps organizations were returned for this user."
    }

    # The accounts API can occasionally return duplicate rows for the same organization.
    # De-duplicate primarily by accountId (stable), then by accountUri/accountName fallback.
    $orgByKey = @{}
    foreach ($org in $orgs) {
        if (-not $org) {
            continue
        }

        $orgKey = $null
        if ($org.PSObject.Properties.Name -contains 'accountId' -and -not [string]::IsNullOrWhiteSpace([string]$org.accountId)) {
            $orgKey = "id:$([string]$org.accountId)".ToLowerInvariant()
        }
        elseif ($org.PSObject.Properties.Name -contains 'accountUri' -and -not [string]::IsNullOrWhiteSpace([string]$org.accountUri)) {
            $orgKey = "uri:$([string]$org.accountUri)".ToLowerInvariant()
        }
        else {
            $orgKey = "name:$([string]$org.accountName)".ToLowerInvariant()
        }

        if (-not $orgByKey.ContainsKey($orgKey)) {
            $orgByKey[$orgKey] = $org
        }
    }

    $orgsSorted = @($orgByKey.Values | Sort-Object -Property accountName, accountUri)
    Write-SetupDebug -Message "Azure DevOps organizations after de-duplication: $($orgsSorted.Count) rows."
    if (Test-SetupDebugEnabled) {
        for ($orgIndex = 0; $orgIndex -lt $orgsSorted.Count; $orgIndex++) {
            $org = $orgsSorted[$orgIndex]
            Write-SetupDebug -Message "  dedup[$orgIndex] name='$([string]$org.accountName)' id='$([string]$org.accountId)' uri='$([string]$org.accountUri)'"
        }
    }

    # Keep labels concise when unique; add URI only when names collide.
    $nameCounts = @{}
    foreach ($org in $orgsSorted) {
        $nameKey = [string]$org.accountName
        if ($nameCounts.ContainsKey($nameKey)) {
            $nameCounts[$nameKey] = [int]$nameCounts[$nameKey] + 1
        }
        else {
            $nameCounts[$nameKey] = 1
        }
    }

    $orgLabels = @(
        $orgsSorted | ForEach-Object {
            $name = [string]$_.accountName
            if ($nameCounts[$name] -gt 1 -and -not [string]::IsNullOrWhiteSpace([string]$_.accountUri)) {
                "$name ($([string]$_.accountUri))"
            }
            else {
                $name
            }
        }
    )
    $orgNames = @($orgsSorted | ForEach-Object { [string]$_.accountName })
    
    return @{
        Orgs      = $orgsSorted
        OrgNames  = $orgNames
        OrgLabels = $orgLabels
    }
}

$orgsSorted = $orgData.Orgs
$orgNames = $orgData.OrgNames
$orgLabels = $orgData.OrgLabels

Write-SetupDebug -Message "Organization menu labels: $($orgLabels -join ' | ')"

$orgIndex = 0
$orgIndex = Select-FromMenu `
    -Title "Select an Azure DevOps organization" `
    -Items $orgLabels `
    -PromptGuidanceLines @(
        'Choose the Azure DevOps organization that owns the project, repositories, and pipelines for this setup.',
        'Select the organization where you have enough permissions to create and configure project resources.'
    ) `
    -PromptGuidanceDocRelativePath 'docs/setup/azdo-organisation-requirements.md' `
    -PromptGuidanceRef $ALM4DataverseRef
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

function Initialize-AzDoProjectAndRepositories {
    [CmdletBinding()]
    param()

    Write-Section `
        -Message "Select target Azure DevOps Project"

    Write-SetupGuidance -Lines @(
        "Choose the long-lived Azure DevOps project that will host your repos, pipelines, service connections, and approvals.",
        "Best practice: avoid phase-specific project names so you do not paint future-you into a corner."
    ) -DocRelativePath 'docs/setup/azdo-automated-setup.md' -Ref $ALM4DataverseRef -Header 'Project selection guidance'

    $azDevOpsAccessToken = $adoAccessToken.Token

    $projects = @(Invoke-WithSpectreStatus -Status 'Retrieving Azure DevOps projects...' -ScriptBlock {
        Get-VSTeamProject
    })
    $projectNames = @()
    if ($projects) {
        $projectNames = @($projects | ForEach-Object { $_.Name })
    }

    $menuItems = $projectNames + @('Create a new project')
    $index = Select-FromMenu `
        -Title "Select the target Azure DevOps project" `
        -Items $menuItems `
        -PromptGuidanceLines @(
            'Choose the project that should host repositories, pipeline definitions, service connections, and variable groups.',
            'Use Create a new project only when no existing project should own this ALM setup.'
        ) `
        -PromptGuidanceDocRelativePath 'docs/setup/azdo-automated-setup.md' `
        -PromptGuidanceRef $ALM4DataverseRef

    if ($null -eq $index) {
        Write-Host "No project selected." -ForegroundColor Yellow
        return $null
    }

    if ($index -eq ($menuItems.Count - 1)) {
        $name = Read-TextWithDefault -Prompt 'Enter the name for the new Azure DevOps project'

        $created = New-AzDoProject -Organization $orgName -ProjectName $name -Visibility private

        $projects = @(Invoke-WithSpectreStatus -Status 'Refreshing Azure DevOps projects...' -ScriptBlock {
            Get-VSTeamProject
        })
        $selectedProject = $null

        if ($projects) {
            $selectedProject = $projects | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        }
        if (-not $selectedProject -and $created -and $created.name) {
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

    if (Get-Command -Name Set-VSTeamDefaultProject -ErrorAction SilentlyContinue) {
        Set-VSTeamDefaultProject -Project $selectedProject.Name | Out-Null
        Write-Host "Default VSTeam project set to '$($selectedProject.Name)'."
    }

    $mainRepo = Select-AzDoMainRepository -ProjectName $selectedProject.Name

    $script:mainRepoBranch = 'main'
    if ($mainRepo.defaultBranch) {
        $script:mainRepoBranch = ConvertFrom-GitRefToBranchName -Ref $mainRepo.defaultBranch
    }

    $script:devEnvironmentShortName = "Dev-$script:mainRepoBranch"

    $mainRepoWorkingTree = New-AzDoRepoWorkingTree -TargetRepo $mainRepo -AccessToken $azDevOpsAccessToken -PreferredBranch 'main'
    $mainRepoWorkingRoot = $mainRepoWorkingTree.Path

    Write-Section `
        -Message "Ensuring Needed Extensions are Enabled"

    Write-SetupGuidance -Lines @(
        "ALM4Dataverse extension mode enables Workload Identity Federation and the ALM4Dataverse Set Connection Variables task.",
        "Disable it only if you specifically want the Power Platform Build Tools secret-based fallback path."
    ) -DocRelativePath 'docs/config/azdo-environment-service-connection.md' -Ref $ALM4DataverseRef -Header 'Extension mode guidance'

    $existingExtensionMode = Get-AzDoExtensionModeFromWorkingTree -RepoRoot $mainRepoWorkingRoot -Branch $script:mainRepoBranch
    if ($existingExtensionMode.IsConfigured -and -not $existingExtensionMode.HasConflict) {
        $script:useAlm4DataverseExtension = $existingExtensionMode.UseAlm4DataverseExtension
        $modeLabel = if ($script:useAlm4DataverseExtension) { 'enabled' } else { 'disabled' }
        $sourceSummary = @($existingExtensionMode.SourceFiles | ForEach-Object { Split-Path -Leaf $_ }) -join ', '
        if ([string]::IsNullOrWhiteSpace($sourceSummary)) {
            Write-Host "Detected existing ALM4Dataverse extension mode: $modeLabel" -ForegroundColor Cyan
        }
        else {
            Write-Host "Detected existing ALM4Dataverse extension mode: $modeLabel (from $sourceSummary)" -ForegroundColor Cyan
        }
    }
    else {
        if ($existingExtensionMode.HasConflict) {
            $sourceSummary = @($existingExtensionMode.SourceFiles | ForEach-Object { Split-Path -Leaf $_ }) -join ', '
            $conflictSuffix = if ([string]::IsNullOrWhiteSpace($sourceSummary)) { '' } else { " ($sourceSummary)" }
            Write-Warning "Existing pipeline YAML files disagree on ALM4Dataverse extension mode$conflictSuffix. Please choose the desired mode."
        }

        $script:useAlm4DataverseExtension = Read-YesNo -Prompt "Use ALM4Dataverse AzDO extension? (required for Workload Identity Federation)"
    }

    if (-not $script:useAlm4DataverseExtension) {
        Write-Host "ALM4Dataverse extension mode disabled. Setup will use the PPBT Set Connection Variables task for service-connection-based client secret auth." -ForegroundColor Yellow
    }

    $requiredExtensions = @(
        "microsoft-IsvExpTools.PowerPlatform-BuildTools"
    )

    if ($script:useAlm4DataverseExtension) {
        $requiredExtensions += "ALM4Dataverse.alm4dataverse-azdo-extensions"
    }

    foreach ($requiredExtension in $requiredExtensions) {
        $parts = $requiredExtension -split '\.'
        $publisherId = $parts[0]
        $extensionId = $parts[1..($parts.Length - 1)] -join '.'

        Invoke-WithErrorHandling -OperationName "Installing extension '$requiredExtension'" -ScriptBlock {
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

                Install-VSTeamExtension -PublisherId $publisherId -ExtensionId $extensionId

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

    $existingSharedRepoName = Get-AzDoSharedRepositoryNameFromWorkingTree -RepoRoot $mainRepoWorkingRoot -Branch $script:mainRepoBranch
    if (-not [string]::IsNullOrWhiteSpace($existingSharedRepoName)) {
        Write-Host "Existing shared repository detected from pipeline YAML: $existingSharedRepoName" -ForegroundColor DarkGray
    }

    Write-Section `
        -Message "Selecting shared Git repository"

    $repo = Select-AzDoSharedRepository -ProjectName $selectedProject.Name -PreferredRepositoryName $existingSharedRepoName -ExcludeRepositoryName $mainRepo.Name
    $sharedRepoName = $repo.Name

    try {
        [void]$Host.UI.RawUI
    }
    catch {
        throw "This script must be run in an interactive PowerShell session."
    }

    Write-Section `
        -Message "Creating/updating shared repository '$sharedRepoName'"

    $hasCommits = Test-AzDoGitRepositoryHasCommits -Organization $orgName -Project $selectedProject.Name -RepositoryId $repo.Id
    $justInitialized = $false
    if (-not $hasCommits) {
        $justInitialized = Invoke-WithErrorHandling -OperationName "Initializing Shared Repository" -ScriptBlock {
            $previousErrorActionPreference = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
            Write-Host "Repository '$sharedRepoName' has no commits. Seeding it from the upstream repo..." -ForegroundColor Yellow

            $sharedSourceUrl = $upstreamRepo
            $destUrl = $repo.remoteUrl
            if (-not $destUrl) {
                throw "Could not determine remoteUrl for repository '$sharedRepoName'."
            }

            $workRoot = Join-Path $env:TEMP ("ALM4Dataverse-Init-" + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $workRoot -Force | Out-Null

            try {
                Push-Location $workRoot

                & git init --initial-branch=main | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Git init failed with exit code $LASTEXITCODE" }

                & git remote add origin $sharedSourceUrl | Out-Null
                & git fetch origin | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Git fetch failed with exit code $LASTEXITCODE" }

                & git ls-remote --exit-code origin $ALM4DataverseRef | Out-Null
                if ($LASTEXITCODE -eq 2) {
                    throw "Could not resolve reference '$ALM4DataverseRef' from upstream repository."
                }
                if ($LASTEXITCODE -ne 0) {
                    throw "Git ls-remote failed with exit code $LASTEXITCODE"
                }

                $lsRemoteOutput = (& git ls-remote origin $ALM4DataverseRef | Select-Object -First 1)
                if ($lsRemoteOutput -match '^([a-f0-9]+)\s+(.+)$') {
                    $commitSha = $Matches[1]
                    $fullRef = $Matches[2]
                    if ($fullRef -match '^refs/heads/(.+)$') {
                        $targetRef = "origin/$($Matches[1])"
                    }
                    elseif ($fullRef -match '^refs/tags/') {
                        $targetRef = $commitSha
                    }
                    else {
                        $targetRef = $ALM4DataverseRef
                    }
                }
                else {
                    $targetRef = $ALM4DataverseRef
                }

                & git checkout -b main $targetRef | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Git checkout failed with exit code $LASTEXITCODE" }

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
            finally {
                $ErrorActionPreference = $previousErrorActionPreference
            }
        } -StatusMessage "Initializing shared repository '$sharedRepoName'..." -CaptureOutputInPanel
    }

    if (-not $justInitialized) {
        $sharedSourceUrl = $upstreamRepo
        $destUrl = $repo.remoteUrl
        if (-not $destUrl) {
            throw "Could not determine remoteUrl for repository '$sharedRepoName'."
        }

        $workRoot = Join-Path $env:TEMP ("ALM4Dataverse-Check-" + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $workRoot -Force | Out-Null

        try {
            $sharedRepoSyncState = Invoke-WithSpectreStatus -Status "Checking shared repository '$sharedRepoName' against upstream..." -ScriptBlock {
                Get-AzDoSharedRepositorySyncState -RepositoryRemoteUrl $destUrl -WorkRoot $workRoot -UpstreamGitSource $sharedSourceUrl -Reference $ALM4DataverseRef -AccessToken $azDevOpsAccessToken
            }

            if ($sharedRepoSyncState.LocalHash -eq $sharedRepoSyncState.UpstreamHash) {
                Write-Host "Shared repository is already up to date."
            }
            else {
                if ($sharedRepoSyncState.CanFastForward) {
                    if (Read-YesNo -Prompt "Updates are available from the shared repo (fast-forward). Update '$sharedRepoName'?" ) {
                        Invoke-WithErrorHandling -OperationName "Fast-forwarding shared repository '$sharedRepoName'" -StatusMessage "Fast-forwarding shared repository '$sharedRepoName'..." -CaptureOutputInPanel -ScriptBlock {
                            $previousErrorActionPreference = $ErrorActionPreference
                            try {
                                $ErrorActionPreference = 'Continue'

                                & git -C $workRoot merge --ff-only $sharedRepoSyncState.UpstreamRef
                                if ($LASTEXITCODE -ne 0) { throw 'Git merge failed' }

                                & git -C $workRoot -c "http.extraheader=AUTHORIZATION: bearer $azDevOpsAccessToken" push origin
                                if ($LASTEXITCODE -ne 0) { throw 'Git push failed' }
                            }
                            finally {
                                $ErrorActionPreference = $previousErrorActionPreference
                            }
                        } | Out-Null

                        Write-Host "Repository updated successfully."
                    }
                }
                else {
                    if ($sharedRepoSyncState.IsAhead) {
                        Write-Host "Shared repository is ahead of the shared repo."
                    }
                    else {
                        $divergedMenuItems = @(
                            "Rebase '$sharedRepoName' onto ref '$ALM4DataverseRef'",
                            "Reset '$sharedRepoName' to ref '$ALM4DataverseRef' (force push)",
                            "Leave '$sharedRepoName' unchanged"
                        )
                        $divergedSelection = Select-FromMenu `
                            -Title "The shared repo '$sharedRepoName' has diverged. Choose how to update it." `
                            -Items $divergedMenuItems `
                            -PromptGuidanceLines @(
                                "Choose how to reconcile '$sharedRepoName' with upstream ALM4Dataverse template history.",
                                'Rebase preserves local commits, reset force-aligns to upstream, and leave unchanged keeps current state.'
                            ) `
                            -PromptGuidanceDocRelativePath 'docs/setup/azdo-automated-setup.md' `
                            -PromptGuidanceRef $ALM4DataverseRef

                        switch ($divergedSelection) {
                            0 {
                                Invoke-WithErrorHandling -OperationName "Rebasing shared repository '$sharedRepoName'" -StatusMessage "Rebasing shared repository '$sharedRepoName'..." -CaptureOutputInPanel -ScriptBlock {
                                    $previousErrorActionPreference = $ErrorActionPreference
                                    try {
                                        $ErrorActionPreference = 'Continue'

                                        & git -C $workRoot rebase $sharedRepoSyncState.UpstreamRef
                                        if ($LASTEXITCODE -ne 0) { throw "Git rebase failed - this script can't handle conflicts. You need to rebase your local changes manually." }

                                        & git -C $workRoot -c "http.extraheader=AUTHORIZATION: bearer $azDevOpsAccessToken" push --force-with-lease origin
                                        if ($LASTEXITCODE -ne 0) { throw 'Git push failed' }
                                    }
                                    finally {
                                        $ErrorActionPreference = $previousErrorActionPreference
                                    }
                                } | Out-Null

                                Write-Host "Repository updated successfully."
                            }
                            1 {
                                Invoke-WithErrorHandling -OperationName "Resetting shared repository '$sharedRepoName'" -StatusMessage "Resetting shared repository '$sharedRepoName' to '$ALM4DataverseRef'..." -CaptureOutputInPanel -ScriptBlock {
                                    $previousErrorActionPreference = $ErrorActionPreference
                                    try {
                                        $ErrorActionPreference = 'Continue'

                                        & git -C $workRoot reset --hard $sharedRepoSyncState.UpstreamRef
                                        if ($LASTEXITCODE -ne 0) { throw 'Git reset failed' }

                                        & git -C $workRoot -c "http.extraheader=AUTHORIZATION: bearer $azDevOpsAccessToken" push --force-with-lease origin
                                        if ($LASTEXITCODE -ne 0) { throw 'Git push failed' }
                                    }
                                    finally {
                                        $ErrorActionPreference = $previousErrorActionPreference
                                    }
                                } | Out-Null

                                Write-Host "Repository updated successfully."
                            }
                            default {
                                Write-Host "Leaving shared repository unchanged." -ForegroundColor Yellow
                            }
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

    return [pscustomobject]@{
        SelectedProject      = $selectedProject
        MainRepo             = $mainRepo
        MainRepoWorkingTree  = $mainRepoWorkingTree
        MainRepoWorkingRoot  = $mainRepoWorkingRoot
        AzDevOpsAccessToken  = $azDevOpsAccessToken
        SharedRepo           = $repo
        SharedRepoName       = $sharedRepoName
    }
}

#endregion

#region Dataverse Environment Selection Helper

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

            $auth = Get-AuthToken -ResourceUrl $resource
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
        throw 'No Dataverse environments found for this user.'
    }

    return @($script:dataverseEnvironmentCatalog)
}

function Select-DataverseEnvironment {
    [CmdletBinding()]
    param(
        [Parameter()][string]$Prompt = "Select a Dataverse environment",
        [Parameter()][string]$ExcludeUrl,
        [Parameter()][string]$PreferredUrl,
        [Parameter()][string[]]$PromptGuidanceLines,
        [Parameter()][string]$PromptGuidanceDocRelativePath,
        [Parameter()][string]$PromptGuidanceRef
    )

    $environments = @(Get-DataverseEnvironmentCatalog -ShowStatus)

    $normalizedExcludeUrl = ConvertTo-NormalizedEnvironmentUrl -Url $ExcludeUrl
    $normalizedPreferredUrl = ConvertTo-NormalizedEnvironmentUrl -Url $PreferredUrl

    # Filter out excluded URL if provided
    if ($ExcludeUrl) {
        $environments = @($environments | Where-Object { 
            (ConvertTo-NormalizedEnvironmentUrl -Url $_.Endpoints["WebApplication"]) -ne $normalizedExcludeUrl 
        })
        if ($environments.Count -eq 0) {
            throw "No environments available after filtering."
        }
    }

    $menuItems = @()
    $menuActions = @()

    if (-not [string]::IsNullOrWhiteSpace($normalizedPreferredUrl)) {
        $preferredEnvironment = $environments | Where-Object {
            (ConvertTo-NormalizedEnvironmentUrl -Url $_.Endpoints['WebApplication']) -eq $normalizedPreferredUrl
        } | Select-Object -First 1

        if ($preferredEnvironment) {
            $menuItems += "Use existing environment: $($preferredEnvironment.FriendlyName) - $($preferredEnvironment.UniqueName) ($($preferredEnvironment.Endpoints['WebApplication']))"
            $menuActions += $preferredEnvironment

            $environments = @($environments | Where-Object {
                (ConvertTo-NormalizedEnvironmentUrl -Url $_.Endpoints['WebApplication']) -ne $normalizedPreferredUrl
            })
        }
    }

    foreach ($env in $environments) {
        $webUrl = $env.Endpoints["WebApplication"]
        $menuItems += "$($env.FriendlyName) - $($env.UniqueName) ($webUrl)"
        $menuActions += $env
    }

    # Show menu
    $selectedIndex = Select-FromMenu `
        -Title $Prompt `
        -Items $menuItems `
        -PromptGuidanceLines $PromptGuidanceLines `
        -PromptGuidanceDocRelativePath $PromptGuidanceDocRelativePath `
        -PromptGuidanceRef $PromptGuidanceRef
    if ($null -eq $selectedIndex) {
        return $null
    }

    return $menuActions[$selectedIndex]
}

function Get-OptionalObjectPropertyValue {
    [CmdletBinding()]
    param(
        [Parameter()][object]$InputObject,
        [Parameter(Mandatory)][string]$PropertyName
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [hashtable]) {
        if ($InputObject.ContainsKey($PropertyName)) {
            return $InputObject[$PropertyName]
        }

        return $null
    }

    if ($InputObject.PSObject -and $InputObject.PSObject.Properties.Name -contains $PropertyName) {
        return $InputObject.$PropertyName
    }

    return $null
}

#endregion

#region Pipeline Setup

function Select-AzDoMainRepository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter()][string]$SharedRepositoryName
    )

    Write-Section `
        -Message "Selecting main Git repository"

    $repos = @(Invoke-WithSpectreStatus -Status "Retrieving repositories in '$ProjectName'..." -ScriptBlock {
        Get-VSTeamGitRepository -ProjectName $ProjectName
    })
    # 'Main' repo is the user's application repo (not the shared ALM4Dataverse repo)
    $reposSorted = @($repos | Sort-Object -Property Name)

    $repoNames = @($reposSorted | ForEach-Object { $_.Name })
    if (-not [string]::IsNullOrWhiteSpace($SharedRepositoryName)) {
        $repoNames = @($repoNames | Where-Object { $_ -ne $SharedRepositoryName })
    }
    $menu = @('Create a new repository') + @($repoNames)

    Write-Host "Select the repository where you want to set up pipelines:" -ForegroundColor Green

    $selectedIndex = Select-FromMenu `
        -Title "Select the main repository" `
        -Items $menu `
        -PromptGuidanceLines @(
            'Choose the primary application repository where your solutions and other assets will be stored.'
        ) `
        -PromptGuidanceDocRelativePath 'docs/setup/azdo-automated-setup.md' `
        -PromptGuidanceRef $ALM4DataverseRef
    if ($null -eq $selectedIndex) {
        throw "No main repository selected."
    }

    if ($selectedIndex -eq 0) {
        $newRepoName = Read-TextWithDefault -Prompt 'Enter the name for the new main repository'
        $newRepoName = $newRepoName.Trim()
        if ([string]::IsNullOrWhiteSpace($newRepoName)) {
            throw "Repository name cannot be empty."
        }

        $created = Invoke-WithSpectreStatus -Status "Creating Git repository '$newRepoName' in project '$ProjectName'..." -ScriptBlock {
            Add-VSTeamGitRepository -ProjectName $ProjectName -Name $newRepoName
        }
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

function Get-AzDoSharedRepositoryNameFromWorkingTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch
    )

    $candidateFiles = @(
        (Join-Path $RepoRoot 'pipelines/BUILD.yml'),
        (Join-Path $RepoRoot 'pipelines/EXPORT.yml'),
        (Join-Path $RepoRoot 'pipelines/IMPORT.yml'),
        (Join-Path $RepoRoot "pipelines/DEPLOY-$Branch.yml")
    )

    foreach ($candidateFile in $candidateFiles) {
        if (-not (Test-Path -LiteralPath $candidateFile)) {
            continue
        }

        $content = Get-Content -LiteralPath $candidateFile -Raw
        $match = [regex]::Match($content, 'repository:\s*ALM4Dataverse\s+type:\s*git\s+name:\s*([^\r\n]+)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) {
            return $match.Groups[1].Value.Trim().Trim('"', "'")
        }
    }

    return $null
}

function Get-AzDoDeploymentEnvironmentNamesFromWorkingTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch
    )

    $deployPath = Join-Path $RepoRoot "pipelines/DEPLOY-$Branch.yml"
    if (-not (Test-Path -LiteralPath $deployPath)) {
        return @()
    }

    $content = Get-Content -LiteralPath $deployPath -Raw
    $envMatches = [regex]::Matches($content, '(?mi)^\s*environmentName:\s*([^\s\r\n]+)\s*$')
    $environmentNames = @()
    foreach ($envMatch in $envMatches) {
        $environmentName = $envMatch.Groups[1].Value.Trim().Trim('"', "'")
        if (-not [string]::IsNullOrWhiteSpace($environmentName) -and $environmentNames -notcontains $environmentName) {
            $environmentNames += $environmentName
        }
    }

    return @($environmentNames)
}

function Get-AzDoExtensionModeFromWorkingTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch
    )

    $candidateFiles = @(
        (Join-Path $RepoRoot 'pipelines/EXPORT.yml'),
        (Join-Path $RepoRoot 'pipelines/IMPORT.yml'),
        (Join-Path $RepoRoot "pipelines/DEPLOY-$Branch.yml")
    )

    $detectedValues = @()
    foreach ($candidateFile in $candidateFiles) {
        if (-not (Test-Path -LiteralPath $candidateFile)) {
            continue
        }

        $content = Get-Content -LiteralPath $candidateFile -Raw
        $extensionMatches = [regex]::Matches($content, '(?mi)^\s*useAlm4DataverseExtension:\s*(true|false)\s*$')
        foreach ($match in $extensionMatches) {
            $detectedValues += [pscustomobject]@{
                File  = $candidateFile
                Value = ($match.Groups[1].Value -ieq 'true')
            }
        }
    }

    if ($detectedValues.Count -eq 0) {
        return [pscustomobject]@{
            IsConfigured                = $false
            HasConflict                 = $false
            UseAlm4DataverseExtension   = $null
            SourceFiles                 = @()
        }
    }

    $distinctValues = @($detectedValues | Select-Object -ExpandProperty Value -Unique)
    return [pscustomobject]@{
        IsConfigured              = ($distinctValues.Count -eq 1)
        HasConflict               = ($distinctValues.Count -gt 1)
        UseAlm4DataverseExtension = $(if ($distinctValues.Count -eq 1) { [bool]$distinctValues[0] } else { $null })
        SourceFiles               = @($detectedValues | Select-Object -ExpandProperty File -Unique)
    }
}

function Select-AzDoSharedRepository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter()][string]$PreferredRepositoryName,
        [Parameter()][string]$ExcludeRepositoryName
    )

    Write-Section `
        -Message 'Selecting shared ALM4Dataverse repository'

    $repos = @(Invoke-WithSpectreStatus -Status "Retrieving shared repository options in '$ProjectName'..." -ScriptBlock {
        Get-VSTeamGitRepository -ProjectName $ProjectName
    })
    $reposSorted = @($repos | Sort-Object -Property Name)
    $candidateRepos = @($reposSorted | Where-Object {
        [string]::IsNullOrWhiteSpace($ExcludeRepositoryName) -or $_.Name -ne $ExcludeRepositoryName
    })

    $menuItems = @()
    $menuActions = @()

    if (-not [string]::IsNullOrWhiteSpace($PreferredRepositoryName)) {
        $preferredRepo = $candidateRepos | Where-Object { $_.Name -eq $PreferredRepositoryName } | Select-Object -First 1
        if ($preferredRepo) {
            $menuItems += "Use current shared repository: $($preferredRepo.Name)"
            $menuActions += @{ Type = 'UseExisting'; Repo = $preferredRepo }
            $candidateRepos = @($candidateRepos | Where-Object { $_.Id -ne $preferredRepo.Id })
        }
    }

    foreach ($candidateRepo in $candidateRepos) {
        $menuItems += "Use existing repository: $($candidateRepo.Name)"
        $menuActions += @{ Type = 'UseExisting'; Repo = $candidateRepo }
    }

    $defaultNewName = if ([string]::IsNullOrWhiteSpace($PreferredRepositoryName)) { 'ALM4Dataverse' } else { $PreferredRepositoryName }
    $menuItems += 'Create a new repository'
    $menuActions += @{ Type = 'CreateNew'; DefaultName = $defaultNewName }

    $selection = Select-FromMenu `
        -Title 'Select the shared repository that will host the ALM4Dataverse templates' `
        -Items $menuItems `
        -PromptGuidanceLines @(
            'Choose the shared repository that will store reusable ALM4Dataverse templates for this project.',
            'Use the existing shared repository when one is already referenced by your main repo to keep template source consistent.'
        ) `
        -PromptGuidanceDocRelativePath 'docs/setup/azdo-automated-setup.md' `
        -PromptGuidanceRef $ALM4DataverseRef
    if ($null -eq $selection) {
        throw 'No shared repository selected.'
    }

    $selectedAction = $menuActions[$selection]
    if ($selectedAction.Type -eq 'UseExisting') {
        Write-Host "Selected shared repository: $($selectedAction.Repo.Name)"
        return $selectedAction.Repo
    }

    while ($true) {
        $newRepoName = Read-TextWithDefault -Prompt 'Enter the name for the shared repository' -DefaultValue $selectedAction.DefaultName

        $newRepoName = $newRepoName.Trim()
        if ([string]::IsNullOrWhiteSpace($newRepoName)) {
            Write-Warning 'Repository name cannot be empty.'
            continue
        }

        $createdRepo = Invoke-WithSpectreStatus -Status "Creating Git repository '$newRepoName' in project '$ProjectName'..." -ScriptBlock {
            Add-VSTeamGitRepository -ProjectName $ProjectName -Name $newRepoName
        }
        if (-not $createdRepo -or -not $createdRepo.Id) {
            throw "Failed to create Git repository '$newRepoName'."
        }

        Write-Host "Created shared repository '$newRepoName'."
        return $createdRepo
    }
}

function Sync-CopyToYourRepoIntoGitRepo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)][string]$RepositoryName,
        [Parameter(Mandatory)][string]$SharedRepositoryName,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter()][bool]$UseAlm4DataverseExtension = $true
    )

    if (-not (Test-Path -LiteralPath $SourceRoot)) {
        throw "Source folder not found: $SourceRoot"
    }

    Write-Section `
        -Message "Syncing pipeline files into main repository"
    Write-Host "Source: $SourceRoot" -ForegroundColor DarkGray
    Write-Host "Target: $TargetRoot" -ForegroundColor DarkGray

    $allSourceFiles = Get-ChildItem -LiteralPath $SourceRoot -Recurse -Force | Where-Object { -not $_.PSIsContainer }

    foreach ($file in $allSourceFiles) {
        $relativePath = $file.FullName.Substring($SourceRoot.Length).TrimStart('\', '/')
        $normalizedRelativePath = $relativePath -replace '\\', '/'
        $destPath = Join-Path $TargetRoot $relativePath

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
        $isTempFile = $false

        if ($normalizedRelativePath -eq 'pipelines/DEPLOY-main.yml') {
            $destPath = Join-Path $TargetRoot "pipelines/DEPLOY-$Branch.yml"

            $content = Get-Content -LiteralPath $file.FullName -Raw
            $content = $content -replace "source: 'BUILD'", "source: '$RepositoryName\BUILD'"
            $content = $content -replace "- main", "- $Branch"
            $content = $content -replace '(?m)^(\s*name:\s*)ALM4Dataverse\s*$', "`${1}$SharedRepositoryName"
            if (-not $UseAlm4DataverseExtension) {
                $content = $content -replace '(?m)^(\s*#?\s*useAlm4DataverseExtension:\s*)true\s*$', '${1}false'
            }

            $tempFile = [System.IO.Path]::GetTempFileName()
            $content | Set-Content -LiteralPath $tempFile -NoNewline
            $sourceFileToUse = $tempFile
            $isTempFile = $true
        }
        elseif (-not $UseAlm4DataverseExtension -and $normalizedRelativePath -in @('pipelines/EXPORT.yml', 'pipelines/IMPORT.yml')) {
            $content = Get-Content -LiteralPath $file.FullName -Raw
            $content = $content -replace '(?m)^(\s*useAlm4DataverseExtension:\s*)true\s*$', '${1}false'
            $content = $content -replace '(?m)^(\s*name:\s*)ALM4Dataverse\s*$', "`${1}$SharedRepositoryName"

            $tempFile = [System.IO.Path]::GetTempFileName()
            $content | Set-Content -LiteralPath $tempFile -NoNewline
            $sourceFileToUse = $tempFile
            $isTempFile = $true
        }
        elseif ($normalizedRelativePath -eq 'pipelines/BUILD.yml') {
            $content = Get-Content -LiteralPath $file.FullName -Raw
            $content = $content -replace '(?m)^(\s*name:\s*)ALM4Dataverse\s*$', "`${1}$SharedRepositoryName"

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

    Write-Host 'Pipeline files synced into the working tree.' -ForegroundColor Green
}

function New-AzDoRepoWorkingTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$TargetRepo,
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter()][string]$PreferredBranch = 'main',
        [Parameter()][string]$WorkBranch
    )

    if (-not $TargetRepo.remoteUrl) {
        throw "Could not determine remoteUrl for repository '$($TargetRepo.Name)'."
    }

    $cloneRoot = Join-Path $env:TEMP ("ALM4Dataverse-MainRepo-" + [guid]::NewGuid().ToString('n'))
    if (Test-Path -LiteralPath $cloneRoot) {
        try { Remove-Item -LiteralPath $cloneRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }

    Write-Host "Cloning '$($TargetRepo.Name)' to a temp folder..." -ForegroundColor Yellow
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'

        $cloneOutput = @(& git -c "http.extraheader=AUTHORIZATION: bearer $AccessToken" clone $TargetRepo.remoteUrl $cloneRoot 2>&1)
        if ($LASTEXITCODE -ne 0) {
            $cloneErrorDetails = @($cloneOutput | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $cloneErrorMessage = if ($cloneErrorDetails.Count -gt 0) { $cloneErrorDetails[-1] } else { "Exit code: $LASTEXITCODE" }
            throw "Git clone failed. $cloneErrorMessage"
        }

        Push-Location $cloneRoot
        try {
            $branch = $PreferredBranch
            if ($TargetRepo.defaultBranch) {
                $branch = ConvertFrom-GitRefToBranchName -Ref $TargetRepo.defaultBranch
            }
            if ([string]::IsNullOrWhiteSpace($branch)) {
                $branch = 'main'
            }

            $hasCommits = $false
            try {
                & git rev-parse HEAD 2>$null | Out-Null
                $hasCommits = ($LASTEXITCODE -eq 0)
            }
            catch {
                $hasCommits = $false
            }

            if ($hasCommits) {
                & git checkout $branch 2>&1 | Out-Host
                if ($LASTEXITCODE -ne 0) {
                    & git checkout -b $branch 2>&1 | Out-Host
                    if ($LASTEXITCODE -ne 0) {
                        throw "Git checkout failed for branch '$branch'."
                    }
                }
            }
            else {
                & git checkout -b $branch 2>&1 | Out-Host
                if ($LASTEXITCODE -ne 0) {
                    throw "Git checkout -b failed with exit code $LASTEXITCODE"
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($WorkBranch) -and $WorkBranch -ne $branch) {
                & git checkout -B $WorkBranch 2>&1 | Out-Host
                if ($LASTEXITCODE -ne 0) {
                    throw "Git checkout failed for working branch '$WorkBranch'."
                }
            }

            return [pscustomobject]@{
                Path       = $cloneRoot
                BaseBranch = $branch
            }
        }
        finally {
            Pop-Location
        }
    }
    catch {
        try { Remove-Item -LiteralPath $cloneRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        throw
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
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
        [Parameter(Mandatory)][string]$DefinitionBranch,
        [Parameter(Mandatory)][int]$QueueId,
        [Parameter()][string]$FolderPath = '\'
    )

    $YamlPath = $YamlPath.TrimStart('/')

    $normalizedDefinitionBranch = [string]$DefinitionBranch
    if ([string]::IsNullOrWhiteSpace($normalizedDefinitionBranch)) {
        throw "DefinitionBranch cannot be empty for pipeline '$DefinitionName'."
    }

    $normalizedDefinitionBranch = $normalizedDefinitionBranch.Trim()
    if ($normalizedDefinitionBranch -match '^refs/heads/(.+)$') {
        $normalizedDefinitionBranch = [string]$Matches[1]
    }

    if ([string]::IsNullOrWhiteSpace($normalizedDefinitionBranch)) {
        throw "DefinitionBranch cannot be empty for pipeline '$DefinitionName'."
    }

    $definitionBranchRef = "refs/heads/$normalizedDefinitionBranch"

    $existing = @(Get-VSTeamBuildDefinition -ProjectName $Project) | Where-Object { $_.name -eq $DefinitionName -and $_.path -eq $FolderPath }
    $def = $existing | Select-Object -First 1

    if (-not $def) {
        Write-Host "Creating pipeline '$DefinitionName' (YAML: $YamlPath)..." -ForegroundColor Yellow

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
                defaultBranch = $definitionBranchRef
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

    if ($full.repository -and $full.repository.PSObject.Properties.Name -contains 'defaultBranch') {
        if ($full.repository.defaultBranch -ne $definitionBranchRef) {
            $needsUpdate = $true
        }
    }
    else {
        $needsUpdate = $true
    }

    if (-not $needsUpdate) {
        Write-Host "Pipeline '$DefinitionName' already exists and points at '$YamlPath'."
        return
    }

    Write-Host "Updating pipeline '$DefinitionName' to point at '$YamlPath'..." -ForegroundColor Yellow

    $def.repository.name = $Repository.Name
    $def.repository.id = $Repository.Id
    $def.repository.defaultBranch = $definitionBranchRef
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

    Write-Section `
        -Message "Ensuring Azure DevOps pipeline definitions exist"

    $queueId = Get-AzDoDefaultAgentQueueId -Organization $Organization -Project $Project
    Write-Host "Using agent queue id: $queueId" -ForegroundColor DarkGray

    $defaultBranchName = 'main'
    if ($Repository.defaultBranch) {
        $defaultBranchName = ConvertFrom-GitRefToBranchName -Ref $Repository.defaultBranch
    }

    foreach ($yaml in $YamlFiles) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($yaml)
        $definitionBranchName = $defaultBranchName
        if ($yaml -match '^pipelines/DEPLOY-(.+)\.yml$') {
            $definitionBranchName = [string]$Matches[1]
        }

        Ensure-AzDoYamlPipelineDefinition -Organization $Organization -Project $Project -Repository $Repository -DefinitionName $name -YamlPath $yaml -DefinitionBranch $definitionBranchName -QueueId $queueId -FolderPath $FolderPath
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
        $existingAuthParameters = $existing.authorization.parameters
        $existingApplicationId = $null
        if ($existingAuthParameters) {
            if ($existingAuthParameters.PSObject.Properties.Name -contains 'applicationId') {
                $existingApplicationId = $existingAuthParameters.applicationId
            }
            elseif ($existingAuthParameters.PSObject.Properties.Name -contains 'serviceprincipalid') {
                $existingApplicationId = $existingAuthParameters.serviceprincipalid
            }
        }

        $existingAuthType = 'Secret'
        if ($existing.authorization -and $existing.authorization.scheme -eq 'WorkloadIdentityFederation') {
            $existingAuthType = 'WIF'
        }

        $normalizedExistingUrl = ConvertTo-NormalizedEnvironmentUrl -Url $existing.url
        $normalizedTargetUrl = ConvertTo-NormalizedEnvironmentUrl -Url $EnvironmentUrl
        $requiresUpdate = ($normalizedExistingUrl -ne $normalizedTargetUrl) -or ($existingApplicationId -ne $ApplicationId) -or ($existingAuthType -ne $AuthType)

        if ($AuthType -eq 'Secret' -and -not [string]::IsNullOrWhiteSpace($ClientSecret)) {
            $requiresUpdate = $true
        }

        if (-not $requiresUpdate) {
            Write-Host "Service Endpoint '$ServiceEndpointName' already exists."
            return $existing
        }

        Write-Host "Service Endpoint '$ServiceEndpointName' already exists but needs to be refreshed. Recreating it..." -ForegroundColor Yellow
        Remove-VSTeamServiceEndpoint -ProjectName $ProjectName -Id $existing.id -Force | Out-Null
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
        $result.ClientSecret = New-EntraIdApplicationSecret -ApplicationObjectId $app.id -TenantId $TenantId
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
        [Parameter()][string]$OrganizationName,
        [Parameter()][bool]$UseAlm4DataverseExtension = $true,
        [Parameter()][object]$ExistingCredential
    )

    # 1. Try to find existing Service Connection to see if we can reuse its App ID
    $existingEndpoint = $null
    $existingScAppId = $null
    try {
        $endpoints = @(Get-VSTeamServiceEndpoint -ProjectName $ProjectName -ErrorAction SilentlyContinue)
        $existingEndpoint = $endpoints | Where-Object { $_.name -eq $EnvironmentName } | Select-Object -First 1
        if ($existingEndpoint -and $existingEndpoint.authorization -and $existingEndpoint.authorization.parameters) {
            if ($existingEndpoint.authorization.parameters.PSObject.Properties.Name -contains 'applicationId') {
                $existingScAppId = $existingEndpoint.authorization.parameters.applicationId
            }
            elseif ($existingEndpoint.authorization.parameters.PSObject.Properties.Name -contains 'serviceprincipalid') {
                $existingScAppId = $existingEndpoint.authorization.parameters.serviceprincipalid
            }
        }
    }
    catch {
        # Ignore errors checking for existing SC
    }

    if (-not $ExistingCredential -and $existingEndpoint -and -not [string]::IsNullOrWhiteSpace($existingScAppId)) {
        $existingAuthType = if ($existingEndpoint.authorization -and $existingEndpoint.authorization.scheme -eq 'WorkloadIdentityFederation') { 'WIF' } else { 'Secret' }
        $existingTenantId = $TenantId
        if ($existingEndpoint.authorization -and $existingEndpoint.authorization.parameters) {
            if ($existingEndpoint.authorization.parameters.PSObject.Properties.Name -contains 'tenantId' -and -not [string]::IsNullOrWhiteSpace($existingEndpoint.authorization.parameters.tenantId)) {
                $existingTenantId = $existingEndpoint.authorization.parameters.tenantId
            }
            elseif ($existingEndpoint.authorization.parameters.PSObject.Properties.Name -contains 'tenantid' -and -not [string]::IsNullOrWhiteSpace($existingEndpoint.authorization.parameters.tenantid)) {
                $existingTenantId = $existingEndpoint.authorization.parameters.tenantid
            }
        }

        $existingApplication = Resolve-EntraIdApplicationByAppId -ApplicationId $existingScAppId -TenantId $existingTenantId
        $ExistingCredential = [pscustomobject]@{
            Name                        = $(if ($existingApplication -and -not [string]::IsNullOrWhiteSpace($existingApplication.displayName)) { $existingApplication.displayName } else { "Existing-$EnvironmentName" })
            ApplicationId               = $existingScAppId
            ApplicationObjectId         = $(if ($existingApplication) { $existingApplication.id } else { $null })
            ClientSecret                = $null
            TenantId                    = $existingTenantId
            AuthType                    = $existingAuthType
            IsExistingServiceConnection = $true
            HasExistingSecret           = ($existingAuthType -eq 'Secret')
        }
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

    # Priority 1: Recommended App (Existing SC or Exact Name Match)
    $recommendedApp = $null
    
    if ($existingScAppId) {
        $recommendedApp = $foundApps | Where-Object { $_.appId -eq $existingScAppId } | Select-Object -First 1
    }
   
    if ($UseAlm4DataverseExtension -and $recommendedApp) {
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
    Write-SetupGuidance -Lines @(
        "Service Principal credentials are used to authenticate the pipeline to Dataverse.",
        "Best practice: use a separate App Registration per environment and prefer Workload Identity Federation when ALM4Dataverse extension mode stays enabled."
    ) -DocRelativePath 'docs/config/azdo-environment-service-connection.md' -Ref $ALM4DataverseRef -Header 'Service principal credential guidance'
    
    $selection = Select-FromMenu -Title "Select Service Principal credentials for '$EnvironmentName'" -Items $menuItems -PromptGuidanceLines @(
        'Select existing credentials or create new Service Principal credentials for this environment.',
        'Prefer workload identity federation when available to reduce client secret management.'
    ) -PromptGuidanceDocRelativePath 'docs/config/azdo-environment-service-connection.md' -PromptGuidanceRef $ALM4DataverseRef
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
                'Choose whether to keep the existing secret or generate a new one now.',
                'Rotate when policy requires renewal or when the existing secret is no longer trusted.'
            ) -PromptGuidanceDocRelativePath 'docs/config/azdo-environment-service-connection.md' -PromptGuidanceRef $ALM4DataverseRef
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
                $selectedCredential.IsExistingServiceConnection = $false
            }

            return $selectedCredential
        }

        return $selectedCredential
    }
    elseif ($action.Type -eq 'Cached') {
        return $action.Creds
    }
    elseif ($action.Type -eq 'CreateNew') {
        $authType = 'Secret'
        if ($UseAlm4DataverseExtension) {
            # Prompt for authentication type
            Write-Host ""
            $authTypeItems = @(
                "Workload Identity Federation (recommended, no secrets)",
                "Service Principal with Secret (traditional)"
            )
            $authTypeSelection = Select-FromMenu -Title "Select authentication type for the new service connection" -Items $authTypeItems -PromptGuidanceLines @(
                'Choose between workload identity federation and client-secret authentication.',
                'Workload identity federation is recommended when supported.'
            ) -PromptGuidanceDocRelativePath 'docs/config/azdo-environment-service-connection.md' -PromptGuidanceRef $ALM4DataverseRef
            if ($null -eq $authTypeSelection) { throw "No authentication type selected." }
            
            $authType = if ($authTypeSelection -eq 1) { 'Secret' } else { 'WIF' }
        }
        else {
            Write-Host "Using Service Principal with Secret authentication because ALM4Dataverse extension mode is disabled." -ForegroundColor Yellow
        }
        
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
        if (-not $UseAlm4DataverseExtension) {
            throw "Reusing existing service connection credentials requires ALM4Dataverse extension mode. Enable extension mode or enter Service Principal details manually."
        }
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
        $name = Read-TextWithDefault -Prompt 'Credential name (for reuse reference)' -AllowEmpty
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

        $authType = 'Secret'
        if ($UseAlm4DataverseExtension) {
            # Prompt for authentication type
            Write-Host ""
            $authTypeItems = @(
                "Service Principal with Secret (traditional)",
                "Workload Identity Federation (recommended, no secrets)"
            )
            $authTypeSelection = Select-FromMenu -Title "Select authentication type" -Items $authTypeItems -PromptGuidanceLines @(
                'Choose the authentication mode for the supplied Service Principal details.',
                'Use secret-based auth only when workload identity federation is not the intended option.'
            ) -PromptGuidanceDocRelativePath 'docs/config/azdo-environment-service-connection.md' -PromptGuidanceRef $ALM4DataverseRef
            if ($null -eq $authTypeSelection) { throw "No authentication type selected." }
            
            $authType = if ($authTypeSelection -eq 0) { 'Secret' } else { 'WIF' }
        }
        else {
            Write-Host "Using Service Principal with Secret authentication because ALM4Dataverse extension mode is disabled." -ForegroundColor Yellow
        }
        
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
    Write-SetupGuidance -Lines @(
        "Service Account credentials are used for ownership and licensing of Cloud Flows.",
        "Use a licensed user account with System Administrator role.",
        "Best practice: keep this separate from your personal admin account so automation ownership stays stable."
    ) -DocRelativePath 'docs/config/azdo-environment-service-connection.md' -Ref $ALM4DataverseRef -Header 'Service account guidance'
    
    $selection = Select-FromMenu `
        -Title "Select Dataverse Service Account for '$EnvironmentName'" `
        -Items $menuItems `
        -PromptGuidanceLines @(
            "Choose the service account UPN that will own flow activation and runtime ownership for '$EnvironmentName'.",
            'Reusing an existing service account keeps ownership consistent across runs; entering a new one changes who owns activated processes.'
        ) `
        -PromptGuidanceDocRelativePath 'docs/config/azdo-environment-service-connection.md' `
        -PromptGuidanceRef $ALM4DataverseRef
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
            $upn = Read-TextWithDefault -Prompt 'Service Account UPN (for example: serviceaccount@contoso.com)'
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
        $created = Add-VSTeamVariableGroup -ProjectName $Project -Name $GroupName -Type 'Vsts' -Variables $variablesPayload -Description 'ALM4Dataverse environment variable group (created by setup-azdo.ps1)'

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

$initialization = Initialize-AzDoProjectAndRepositories
if (-not $initialization) {
    return
}

$selectedProject = $initialization.SelectedProject
$mainRepo = $initialization.MainRepo
$mainRepoWorkingTree = $initialization.MainRepoWorkingTree
$mainRepoWorkingRoot = $initialization.MainRepoWorkingRoot
$azDevOpsAccessToken = $initialization.AzDevOpsAccessToken
$repo = $initialization.SharedRepo
$sharedRepoName = $initialization.SharedRepoName

Write-Section `
    -Message "Ensuring main repository contains pipeline YAMLs"

$credentialsCache = @()
$serviceAccountsCache = @()
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


Invoke-WithErrorHandling -OperationName "Preparing main repository working tree" -ScriptBlock {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
    $copyRoot = $null
    if ($PSScriptRoot) {
        $copyRoot = Join-Path $PSScriptRoot 'copy-to-your-repo'
    }
    else {
        $sharedRepoClone = Join-Path $env:TEMP ("ALM4Dataverse-SharedRepo-" + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $sharedRepoClone -Force | Out-Null

        try {
            Write-Host 'Cloning shared repository to get template files...' -ForegroundColor Yellow
            & git -c "http.extraheader=AUTHORIZATION: bearer $azDevOpsAccessToken" clone $repo.remoteUrl $sharedRepoClone
            if ($LASTEXITCODE -ne 0) {
                throw "Git clone of shared repository failed with exit code $LASTEXITCODE"
            }

            $copyRoot = Join-Path $sharedRepoClone 'copy-to-your-repo'
            Sync-CopyToYourRepoIntoGitRepo -SourceRoot $copyRoot -TargetRoot $mainRepoWorkingRoot -RepositoryName $mainRepo.Name -SharedRepositoryName $sharedRepoName -Branch $script:mainRepoBranch -UseAlm4DataverseExtension $script:useAlm4DataverseExtension
        }
        finally {
            if (Test-Path $sharedRepoClone) {
                Remove-Item -LiteralPath $sharedRepoClone -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        return
    }

    Sync-CopyToYourRepoIntoGitRepo -SourceRoot $copyRoot -TargetRoot $mainRepoWorkingRoot -RepositoryName $mainRepo.Name -SharedRepositoryName $sharedRepoName -Branch $script:mainRepoBranch -UseAlm4DataverseExtension $script:useAlm4DataverseExtension
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
} -StatusMessage 'Preparing the main repository working tree...' -CaptureOutputInPanel | Out-Null

#endregion

#region Dev Environment and Solutions Selection

function Get-DataverseSolutionsSelection {
    [CmdletBinding()]
    param(
        [Parameter()][string]$ExistingConfigPath,
        [Parameter()][string]$ExistingEnvironmentUrl
    )
    
    try {
        Write-Host ""
        Write-Host "When prompted, select your dataverse DEV environment containing the solution(s) you want to manage" -ForegroundColor Green
        Write-Host ""

        # Select environment using the helper function
        $selectedEnv = Select-DataverseEnvironment `
            -Prompt "Select your DEV environment" `
            -PreferredUrl $ExistingEnvironmentUrl `
            -PromptGuidanceLines @(
                'Choose the DEV Dataverse environment used to discover unmanaged solutions for alm-config.psd1.',
                'Pick the environment that represents the source-controlled customization baseline.'
            ) `
            -PromptGuidanceDocRelativePath 'docs/config/alm-config.md' `
            -PromptGuidanceRef $ALM4DataverseRef
        if (-not $selectedEnv) {
            throw "No environment selected."
        }

        $devEnvUrl = ConvertTo-NormalizedEnvironmentUrl -Url $selectedEnv.Endpoints["WebApplication"]
        Write-Host "Selected environment: $($selectedEnv.FriendlyName) ($devEnvUrl)" -ForegroundColor Cyan

        # Connect to the selected environment
        $connection = Invoke-WithSpectreStatus -Status 'Connecting to the selected DEV environment...' -ScriptBlock {
            Get-DataverseConnection -Url $devEnvUrl -AccessToken {
                param($resource)
                if (-not $resource) { $resource = 'https://globaldisco.crm.dynamics.com/' }
                try {
                    $uri = [System.Uri]$resource
                    $resource = $uri.GetLeftPart([System.UriPartial]::Authority)
                } catch {}
                $auth = Get-AuthToken -ResourceUrl $resource
                return $auth.AccessToken
            }
        }
        
        if (-not $connection) {
            throw "Failed to connect to Dataverse environment."
        }
        
        Write-Host "Connected to environment: $($connection.ConnectedOrgFriendlyName)"
        
        # Get all solutions (excluding system solutions)
        $allSolutions = Invoke-WithSpectreStatus -Status 'Retrieving unmanaged solutions from Dataverse...' -ScriptBlock {
            Get-DataverseRecord -Connection $connection -TableName 'solution' -Columns @('solutionid', 'uniquename', 'friendlyname', 'version', 'ismanaged', 'description') -FilterValues @{
                'isvisible' = $true
                'ismanaged' = $false
            }
        }
        
        if (-not $allSolutions -or $allSolutions.Count -eq 0) {
            Write-Host "No unmanaged solutions found in the environment." -ForegroundColor Yellow
            return [pscustomobject]@{ Solutions = @(); EnvironmentUrl = $devEnvUrl }
        }
        
        # Filter out system solutions and prepare for selection
        $userSolutions = $allSolutions | Where-Object { 
            $_.uniquename -notmatch '^(Default|Active|Basic|msdyn_|ms|MicrosoftFlow|PowerPlatform)' -and 
            $_.uniquename -ne 'System' 
        } | Sort-Object friendlyname
        
        if (-not $userSolutions -or $userSolutions.Count -eq 0) {
            Write-Host "No user-created solutions found in the environment." -ForegroundColor Yellow
            return [pscustomobject]@{ Solutions = @(); EnvironmentUrl = $devEnvUrl }
        }

        $selectedSolutions = @()

        if ($ExistingConfigPath -and (Test-Path -LiteralPath $ExistingConfigPath)) {
            try {
                $existingConfig = Import-PowerShellDataFile -Path $ExistingConfigPath
                foreach ($existing in @($existingConfig.solutions)) {
                    $match = $userSolutions | Where-Object { $_.uniquename -eq $existing.name } | Select-Object -First 1
                    if ($match) {
                        $selectedSolutions += $match
                    }
                }
            }
            catch {
                Write-Warning "Failed to read existing alm-config.psd1 defaults: $($_.Exception.Message)"
            }
        }

        if ($selectedSolutions.Count -gt 0) {
            Write-Host "Pre-selected $($selectedSolutions.Count) solution(s) from existing configuration." -ForegroundColor Green
            Start-Sleep -Seconds 2
        }
        

        $selectedSolutions = @(Select-OrderedSolutions -AvailableSolutions $userSolutions -InitiallySelectedSolutions $selectedSolutions)
        
        if ($selectedSolutions.Count -eq 0) {
            Write-Host "No solutions selected." -ForegroundColor Yellow
            return [pscustomobject]@{ Solutions = @(); EnvironmentUrl = $devEnvUrl; EnvironmentFriendlyName = $selectedEnv.FriendlyName }
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
        
        return [pscustomobject]@{ Solutions = $configSolutions; EnvironmentUrl = $devEnvUrl; EnvironmentFriendlyName = $selectedEnv.FriendlyName }
        
    }
    catch {
        Write-Host "Error retrieving solutions from Dataverse: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

function Update-AlmConfigInWorkingTree {
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][array]$Solutions,
        [Parameter(Mandatory)][bool]$BuildValidationEnabled,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $configPath = Join-Path $RepoRoot 'alm-config.psd1'
    $templatePath = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'copy-to-your-repo\alm-config.psd1' } else { $null }
    $solutionsChanged = $false
    if ($null -ne $Solutions) {
        $solutionsChanged = Set-AlmConfigSolutionsInFile -ConfigPath $configPath -Solutions @($Solutions) -CreateIfMissing -TemplatePath $templatePath
    }
    else {
        Write-Host 'Skipping solution list updates in alm-config.psd1 because solution selection was not run.' -ForegroundColor Yellow
    }
    $solutionCheckChanged = Set-AlmConfigSolutionCheckEnabledInFile -ConfigPath $configPath -Enabled $BuildValidationEnabled -CreateIfMissing -TemplatePath $templatePath
    $changed = ($solutionsChanged -or $solutionCheckChanged)

    if ($changed) {
        Write-Host 'Updated alm-config.psd1 in the working tree.' -ForegroundColor Green
    }
    else {
        Write-Host 'No changes to alm-config.psd1; solutions already configured.' -ForegroundColor Green
    }

    return $changed
}

function Update-AzDoBuildPipelineInWorkingTree {
        [CmdletBinding()]
        param(
                [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$SharedRepositoryName,
                [Parameter(Mandatory)][string]$BuildEnvironmentName,
                [Parameter(Mandatory)][bool]$UseAlm4DataverseExtension
        )

        $buildPipelinePath = Join-Path $RepoRoot 'pipelines/BUILD.yml'
        if (-not (Test-Path -LiteralPath $buildPipelinePath)) {
                throw "Build pipeline file not found: $buildPipelinePath"
        }

        $extensionLiteral = if ($UseAlm4DataverseExtension) { 'true' } else { 'false' }
        $escapedBuildEnvironmentName = ([string]$BuildEnvironmentName).Replace("'", "''")

        $newContent = @"
trigger:
    branches:
        include:
        - '*'  # Support any branch name

resources:
    repositories:
        - repository: ALM4Dataverse
            type: git
            name: $SharedRepositoryName

stages:
- template: pipelines/templates/build.yml@ALM4Dataverse
    parameters:
        useAlm4DataverseExtension: $extensionLiteral
        buildEnvironmentName: '$escapedBuildEnvironmentName'
"@

        Set-Content -LiteralPath $buildPipelinePath -Value $newContent.TrimStart("`r", "`n") -NoNewline
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

function Get-ExistingEnvironmentsFromWorkingTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch
    )

    return @(Get-AzDoDeploymentEnvironmentNamesFromWorkingTree -RepoRoot $RepoRoot -Branch $Branch)
}

function Get-AzDoExistingEnvironmentServiceAccountUPN {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$EnvironmentName
    )

    try {
        $existingVarGroup = Get-VSTeamVariableGroup -ProjectName $ProjectName -Name "Environment-$EnvironmentName" -ErrorAction SilentlyContinue
        if ($existingVarGroup -and $existingVarGroup.variables -and $existingVarGroup.variables.PSObject.Properties.Name -contains 'DataverseServiceAccountUPN') {
            return $existingVarGroup.variables.DataverseServiceAccountUPN.value
        }
    }
    catch {
        return $null
    }

    return $null
}

function Get-AzDoExistingEnvironmentState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter()][string]$TenantId
    )

    $serviceAccountUPN = Get-AzDoExistingEnvironmentServiceAccountUPN -ProjectName $ProjectName -EnvironmentName $EnvironmentName
    $endpoint = $null
    try {
        $endpoints = @(Get-VSTeamServiceEndpoint -ProjectName $ProjectName -ErrorAction SilentlyContinue)
        $endpoint = $endpoints | Where-Object { $_.name -eq $EnvironmentName } | Select-Object -First 1
    }
    catch {
        $endpoint = $null
    }

    $credentials = $null
    $environmentUrl = $null
    $friendlyName = $EnvironmentName
    if ($endpoint) {
        $environmentUrl = ConvertTo-NormalizedEnvironmentUrl -Url $endpoint.url
        $friendlyName = Resolve-DataverseEnvironmentFriendlyName -EnvironmentUrl $environmentUrl -FallbackName $EnvironmentName

        $applicationId = $null
        $resolvedTenantId = $TenantId
        if ($endpoint.authorization -and $endpoint.authorization.parameters) {
            if ($endpoint.authorization.parameters.PSObject.Properties.Name -contains 'applicationId') {
                $applicationId = $endpoint.authorization.parameters.applicationId
            }
            elseif ($endpoint.authorization.parameters.PSObject.Properties.Name -contains 'serviceprincipalid') {
                $applicationId = $endpoint.authorization.parameters.serviceprincipalid
            }

            if ($endpoint.authorization.parameters.PSObject.Properties.Name -contains 'tenantId' -and -not [string]::IsNullOrWhiteSpace($endpoint.authorization.parameters.tenantId)) {
                $resolvedTenantId = $endpoint.authorization.parameters.tenantId
            }
            elseif ($endpoint.authorization.parameters.PSObject.Properties.Name -contains 'tenantid' -and -not [string]::IsNullOrWhiteSpace($endpoint.authorization.parameters.tenantid)) {
                $resolvedTenantId = $endpoint.authorization.parameters.tenantid
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($applicationId)) {
            $application = Resolve-EntraIdApplicationByAppId -ApplicationId $applicationId -TenantId $resolvedTenantId
            $authType = if ($endpoint.authorization -and $endpoint.authorization.scheme -eq 'WorkloadIdentityFederation') { 'WIF' } else { 'Secret' }

            $credentials = [pscustomobject]@{
                Name                        = $(if ($application -and -not [string]::IsNullOrWhiteSpace($application.displayName)) { $application.displayName } else { "Existing-$EnvironmentName" })
                ApplicationId               = $applicationId
                ApplicationObjectId         = $(if ($application) { $application.id } else { $null })
                ClientSecret                = $null
                TenantId                    = $resolvedTenantId
                AuthType                    = $authType
                IsExistingServiceConnection = $true
                HasExistingSecret           = ($authType -eq 'Secret')
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($environmentUrl) -and -not $credentials -and [string]::IsNullOrWhiteSpace($serviceAccountUPN)) {
        return $null
    }

    return [pscustomobject]@{
        ShortName         = $EnvironmentName
        FriendlyName      = $friendlyName
        Url               = $environmentUrl
        Credentials       = $credentials
        ServiceAccountUPN = $serviceAccountUPN
    }
}

function Get-GitRepoFileContentFromRemoteBranch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$RelativePath
    )

    $normalizedPath = $RelativePath.Replace('\\', '/')
    $normalizedBranch = ConvertTo-NormalizedGitBranchName -Branch $Branch
    $candidateRefs = @("origin/$normalizedBranch", $normalizedBranch) | Select-Object -Unique
    foreach ($candidateRef in $candidateRefs) {
        & git -C $RepoRoot rev-parse --verify --quiet "${candidateRef}^{commit}" 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            continue
        }

        $content = (& git -C $RepoRoot show "${candidateRef}:${normalizedPath}" 2>$null | Out-String)
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($content)) {
            return $content
        }
    }

    return $null
}

function ConvertTo-NormalizedGitBranchName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Branch
    )

    $normalizedBranch = [string]$Branch
    while ($normalizedBranch -match '^origin/(.+)$') {
        $normalizedBranch = [string]$Matches[1]
    }

    return $normalizedBranch.Trim()
}

function Resolve-GitExistingBranchRef {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch
    )

    $normalizedBranch = ConvertTo-NormalizedGitBranchName -Branch $Branch
    if ([string]::IsNullOrWhiteSpace($normalizedBranch)) {
        return $null
    }

    $candidateRefs = @("origin/$normalizedBranch", $normalizedBranch)
    foreach ($candidateRef in $candidateRefs) {
        & git -C $RepoRoot rev-parse --verify --quiet "${candidateRef}^{commit}" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            return $candidateRef
        }
    }

    return $null
}

function Get-AzDoDeploymentEnvironmentNamesFromPipelineContent {
    [CmdletBinding()]
    param(
        [Parameter()][string]$PipelineContent
    )

    if ([string]::IsNullOrWhiteSpace($PipelineContent)) {
        return @()
    }

    $envMatches = [regex]::Matches($PipelineContent, '(?mi)^\s*environmentName:\s*([^\s\r\n]+)\s*$')
    $environmentNames = @()
    foreach ($envMatch in $envMatches) {
        $environmentName = $envMatch.Groups[1].Value.Trim().Trim('"', "'")
        if (-not [string]::IsNullOrWhiteSpace($environmentName) -and $environmentNames -notcontains $environmentName) {
            $environmentNames += $environmentName
        }
    }

    return @($environmentNames)
}

function Get-AzDoBuildEnvironmentNameFromPipelineContent {
    [CmdletBinding()]
    param(
        [Parameter()][string]$PipelineContent
    )

    if ([string]::IsNullOrWhiteSpace($PipelineContent)) {
        return $null
    }

    $match = [regex]::Match($PipelineContent, '(?mi)^\s*buildEnvironmentName\s*:\s*[''\"]?(?<name>[^''\"\r\n]*)[''\"]?\s*$')
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

function Get-AzDoBuildValidationEnabledFromRepoClone {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch
    )

    $buildPipelineContent = Get-GitRepoFileContentFromRemoteBranch -RepoRoot $RepoRoot -Branch $Branch -RelativePath 'pipelines/BUILD.yml'
    $buildEnvironmentName = Get-AzDoBuildEnvironmentNameFromPipelineContent -PipelineContent $buildPipelineContent
    $hasBuildEnvironmentAssociation = -not [string]::IsNullOrWhiteSpace($buildEnvironmentName)

    $almConfigContent = Get-GitRepoFileContentFromRemoteBranch -RepoRoot $RepoRoot -Branch $Branch -RelativePath 'alm-config.psd1'
    $solutionCheckEnabled = Get-SolutionCheckEnabledFromConfigContent -ConfigContent $almConfigContent

    return ($hasBuildEnvironmentAssociation -or $solutionCheckEnabled)
}

function Get-AzDoDeployPipelineBranchMappingsFromRepoClone {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $branchRefs = @(& git -C $RepoRoot for-each-ref --format='%(refname:short)' refs/remotes/origin 2>$null)
    $branches = @($branchRefs | ForEach-Object {
        ConvertTo-NormalizedGitBranchName -Branch ([string]$_)
    } | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and $_ -ne 'HEAD' -and $_ -ne 'origin'
    } | Select-Object -Unique)

    $mappings = @()
    foreach ($branch in $branches) {
        $branchRef = Resolve-GitExistingBranchRef -RepoRoot $RepoRoot -Branch $branch
        if ([string]::IsNullOrWhiteSpace($branchRef)) {
            continue
        }

        $pipelineFiles = @(& git -C $RepoRoot ls-tree -r --name-only $branchRef 'pipelines' 2>$null)
        foreach ($pipelineFile in $pipelineFiles) {
            if ($pipelineFile -notmatch '^pipelines/DEPLOY-(.+)\.yml$') {
                continue
            }

            $fileBranchName = [string]$Matches[1]
            $pipelineContent = Get-GitRepoFileContentFromRemoteBranch -RepoRoot $RepoRoot -Branch $branch -RelativePath $pipelineFile
            $environmentNames = Get-AzDoDeploymentEnvironmentNamesFromPipelineContent -PipelineContent $pipelineContent

            $mappings += [pscustomobject]@{
                BranchName       = $fileBranchName
                SourceBranch     = $branch
                PipelinePath     = $pipelineFile
                EnvironmentNames = @($environmentNames)
            }
        }
    }

    return @($mappings | Sort-Object BranchName -Unique)
}

function Get-AzDoRegisteredDeployPipelineBranches {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectName
    )

    $branches = @()
    $definitions = @(Get-VSTeamBuildDefinition -ProjectName $ProjectName)
    foreach ($definition in @($definitions)) {
        if ($definition.name -match '^DEPLOY-(.+)$') {
            $branchName = [string]$Matches[1]
            if (-not [string]::IsNullOrWhiteSpace($branchName) -and $branches -notcontains $branchName) {
                $branches += $branchName
            }
        }
        elseif ($definition.process -and $definition.process.PSObject.Properties.Name -contains 'yamlFilename' -and $definition.process.yamlFilename -match '^pipelines/DEPLOY-(.+)\.yml$') {
            $branchName = [string]$Matches[1]
            if (-not [string]::IsNullOrWhiteSpace($branchName) -and $branches -notcontains $branchName) {
                $branches += $branchName
            }
        }
    }

    return @($branches | Sort-Object -Unique)
}

function Get-AzDoRepositoryExistingSetupState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$DefaultBranch,
        [Parameter()][string]$TenantId
    )

    $pipelineBranchMappings = @(Get-AzDoDeployPipelineBranchMappingsFromRepoClone -RepoRoot $RepoRoot)
    $defaultBranchBuildValidationEnabled = Get-AzDoBuildValidationEnabledFromRepoClone -RepoRoot $RepoRoot -Branch $DefaultBranch
    $defaultBranchBuildPipelineContent = Get-GitRepoFileContentFromRemoteBranch -RepoRoot $RepoRoot -Branch $DefaultBranch -RelativePath 'pipelines/BUILD.yml'
    $defaultBranchBuildEnvironmentName = Get-AzDoBuildEnvironmentNameFromPipelineContent -PipelineContent $defaultBranchBuildPipelineContent
    $existingBuildValidationEnvironment = $null
    if (-not [string]::IsNullOrWhiteSpace($defaultBranchBuildEnvironmentName)) {
        $existingBuildValidationEnvironment = Get-AzDoExistingEnvironmentState -ProjectName $ProjectName -EnvironmentName $defaultBranchBuildEnvironmentName -TenantId $TenantId
    }
    $registeredBranches = @(Get-AzDoRegisteredDeployPipelineBranches -ProjectName $ProjectName)
    $branchNames = @($pipelineBranchMappings | ForEach-Object { [string]$_.BranchName }) + $registeredBranches
    if ($branchNames.Count -eq 0) {
        $branchNames = @($DefaultBranch)
    }

    $branchNames = @($branchNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique | Sort-Object)
    $branchStates = @()
    foreach ($branchName in $branchNames) {
        $existingDevEnvironment = Get-AzDoExistingEnvironmentState -ProjectName $ProjectName -EnvironmentName "Dev-$branchName" -TenantId $TenantId
        $matchingBranchMapping = $pipelineBranchMappings | Where-Object { $_.BranchName -ieq $branchName } | Select-Object -First 1
        $deploymentEnvironments = @()
        $mappedEnvironmentNames = @()

        if ($null -ne $matchingBranchMapping) {
            $mappingPropertyNames = @($matchingBranchMapping.PSObject.Properties.Name)
            if ($mappingPropertyNames -contains 'EnvironmentNames') {
                $mappedEnvironmentNames = @($matchingBranchMapping.EnvironmentNames)
            }
            elseif ($mappingPropertyNames -contains 'Environments') {
                $mappedEnvironmentNames = @($matchingBranchMapping.Environments)
            }
            elseif ($mappingPropertyNames -contains 'DeploymentEnvironments') {
                $mappedEnvironmentNames = @($matchingBranchMapping.DeploymentEnvironments)
            }
        }

        foreach ($mappedEnvironment in @($mappedEnvironmentNames)) {
            if ($null -eq $mappedEnvironment) {
                continue
            }

            $environmentName = $null
            if ($mappedEnvironment -is [string]) {
                $environmentName = [string]$mappedEnvironment
            }
            else {
                $mappedEnvironmentPropertyNames = @($mappedEnvironment.PSObject.Properties.Name)
                if ($mappedEnvironmentPropertyNames -contains 'ShortName') {
                    $environmentName = [string]$mappedEnvironment.ShortName
                }
                elseif ($mappedEnvironmentPropertyNames -contains 'EnvironmentName') {
                    $environmentName = [string]$mappedEnvironment.EnvironmentName
                }
                elseif ($mappedEnvironmentPropertyNames -contains 'Name') {
                    $environmentName = [string]$mappedEnvironment.Name
                }
                else {
                    $environmentName = [string]$mappedEnvironment
                }
            }

            if ([string]::IsNullOrWhiteSpace($environmentName)) {
                continue
            }

            $deploymentEnvironments += Get-AzDoExistingEnvironmentState -ProjectName $ProjectName -EnvironmentName $environmentName -TenantId $TenantId
        }

        $branchStates += [pscustomobject]@{
            BranchName            = $branchName
            ExistingDevEnvironment = $existingDevEnvironment
            DeploymentEnvironments = @($deploymentEnvironments | Where-Object { $null -ne $_ })
        }
    }

    return [pscustomobject]@{
        BranchStates = @($branchStates)
        BuildValidationEnabled = [bool]$defaultBranchBuildValidationEnabled
        BuildValidationEnvironmentName = $defaultBranchBuildEnvironmentName
        ExistingBuildValidationEnvironment = $existingBuildValidationEnvironment
    }
}

function Get-AzDoInitialBranchMappings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$ExistingSetupState,
        [Parameter(Mandatory)][string]$DefaultBranch
    )

    $branchMappings = @()
    foreach ($branchState in @($ExistingSetupState.BranchStates)) {
        if ($null -eq $branchState -or [string]::IsNullOrWhiteSpace([string]$branchState.BranchName)) {
            continue
        }

        $branchMappings += [pscustomobject]@{
            BranchName   = [string]$branchState.BranchName
            Environments = @($branchState.DeploymentEnvironments | Where-Object { $null -ne $_ })
        }
    }

    if ($branchMappings.Count -eq 0) {
        $branchMappings = @(
            [pscustomobject]@{
                BranchName   = $DefaultBranch
                Environments = @()
            }
        )
    }

    return @($branchMappings | Sort-Object BranchName -Unique)
}

function New-AzDoBranchSetupState {
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

function Get-AzDoEnvironmentConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][string]$EnvironmentUrl,
        [Parameter()][string]$FriendlyName,
        [Parameter()][array]$ExistingCredentials,
        [Parameter()][array]$ExistingServiceAccounts,
        [Parameter()][string]$TenantId,
        [Parameter()][string]$ProjectName,
        [Parameter()][string]$OrganizationId,
        [Parameter()][string]$OrganizationName,
        [Parameter()][bool]$UseAlm4DataverseExtension = $true,
        [Parameter()][object]$ExistingCredential,
        [Parameter()][string]$ExistingServiceAccountUPN,
        [Parameter()][bool]$IsDevelopmentEnvironment = $false
    )

    $creds = Get-PowerPlatformSCCredentials `
        -ExistingCredentials $ExistingCredentials `
        -TenantId $TenantId `
        -ProjectName $ProjectName `
        -EnvironmentName $EnvironmentName `
        -OrganizationId $OrganizationId `
        -OrganizationName $OrganizationName `
        -UseAlm4DataverseExtension $UseAlm4DataverseExtension `
        -ExistingCredential $ExistingCredential

    $serviceAccountUPN = Get-DataverseServiceAccountUPN `
        -ExistingServiceAccounts $ExistingServiceAccounts `
        -EnvironmentName $EnvironmentName `
        -ExistingValue $ExistingServiceAccountUPN

    return [pscustomobject]@{
        ShortName            = $EnvironmentName
        FriendlyName         = $(if ([string]::IsNullOrWhiteSpace($FriendlyName)) { $EnvironmentName } else { $FriendlyName })
        Url                  = (ConvertTo-NormalizedEnvironmentUrl -Url $EnvironmentUrl)
        Credentials          = $creds
        ServiceAccountUPN    = $serviceAccountUPN
        IsDevelopmentEnvironment = $IsDevelopmentEnvironment
    }
}

function Get-DataverseEnvironmentsSelection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][string]$ExcludedUrl,
        [Parameter()][string]$RepoRoot,
        [Parameter()][string]$Branch,
        [Parameter()][string]$ProjectName,
        [Parameter()][array]$InitialEnvironments,
        [Parameter()][array]$ExistingCredentials,
        [Parameter()][array]$ExistingServiceAccounts,
        [Parameter()][string]$TenantId,
        [Parameter()][string]$OrganizationId,
        [Parameter()][string]$OrganizationName,
        [Parameter()][bool]$UseAlm4DataverseExtension = $true
    )

    $selectedEnvironments = @($InitialEnvironments | Where-Object { $null -ne $_ })
    $credentialsForReuse = @($ExistingCredentials)
    $serviceAccountsForReuse = @($ExistingServiceAccounts)
    $normalizedExcludedUrl = ConvertTo-NormalizedEnvironmentUrl -Url $ExcludedUrl

    if (-not [string]::IsNullOrWhiteSpace($RepoRoot) -and -not [string]::IsNullOrWhiteSpace($Branch) -and $ProjectName) {
        $existingNames = @(Get-ExistingEnvironmentsFromWorkingTree -RepoRoot $RepoRoot -Branch $Branch)

        if ($existingNames.Count -gt 0) {
            Write-Host "Found $($existingNames.Count) environment(s) in deployment pipeline. Pre-populating the deployment environment table..." -ForegroundColor Cyan

            $selectedEnvironments += @(Invoke-WithSpectreStatus -Status 'Inspecting existing deployment environment configuration...' -ScriptBlock {
                $resolvedExistingEnvironments = @()

                foreach ($name in $existingNames) {
                    if ($selectedEnvironments | Where-Object { $_.ShortName -ieq $name }) {
                        continue
                    }

                    $existingEnvironmentState = Get-AzDoExistingEnvironmentState -ProjectName $ProjectName -EnvironmentName $name -TenantId $TenantId

                    $existingEnvironmentUrl = ConvertTo-NormalizedEnvironmentUrl -Url $existingEnvironmentState.Url
                    if ($existingEnvironmentUrl -eq $normalizedExcludedUrl) {
                        Write-Warning "Skipping existing deployment stage '$name' because it points at the selected DEV environment URL."
                        continue
                    }

                    $resolvedExistingEnvironments += [pscustomobject]@{
                        ShortName            = $name
                        FriendlyName         = $(if (-not [string]::IsNullOrWhiteSpace($existingEnvironmentState.FriendlyName)) { $existingEnvironmentState.FriendlyName } else { "$name (Existing)" })
                        Url                  = $existingEnvironmentUrl
                        Credentials          = $existingEnvironmentState.Credentials
                        ServiceAccountUPN    = $existingEnvironmentState.ServiceAccountUPN
                        IsDevelopmentEnvironment = $false
                        ConfigurationPending = (($null -eq $existingEnvironmentState.Credentials) -or [string]::IsNullOrWhiteSpace($existingEnvironmentState.ServiceAccountUPN))
                    }
                }

                return @($resolvedExistingEnvironments)
            })
        }
    }

    $resolvedHeading = if ([string]::IsNullOrWhiteSpace($Branch)) { 'Target Deployment Environments' } else { "Target Deployment Environments for branch '$Branch'" }

    $selectedEnvironments = @(Select-ConfiguredDeploymentEnvironments `
        -InitialEnvironments $selectedEnvironments `
        -Heading $resolvedHeading `
        -Title 'Manage deployment environments' `
        -GuidanceLines @(
            'Select each deployment environment together with the credential and service-account ownership that should be used there.',
            'Review URL, auth, and service-account values before continuing because setup applies them to service connections, variable groups, and DEPLOY YAML.',
            'Keep short names stable and the list in promotion order, because that order becomes the generated deployment stage sequence.'
        ) `
        -DocRelativePath 'docs/setup/azdo-manual-setup.md' `
        -Ref $ALM4DataverseRef `
        -AddEnvironmentScriptBlock {
            param($currentSelections)

            $selectedEnv = Select-DataverseEnvironment -Prompt 'Select a deployment environment' -ExcludeUrl $ExcludedUrl
            if (-not $selectedEnv) {
                return $null
            }

            $url = ConvertTo-NormalizedEnvironmentUrl -Url $selectedEnv.Endpoints['WebApplication']
            if ($currentSelections | Where-Object { $_.Url -ieq $url }) {
                Write-Host "An environment with Url '$url' is already selected." -ForegroundColor Red
                Start-Sleep -Seconds 2
                return $null
            }

            Write-Host 'Use a short deployment environment name (for example: TEST, UAT, PROD).' -ForegroundColor DarkGray
            $shortName = Read-TextWithDefault -Prompt 'Enter a short name for this environment' -DefaultValue ''
            if ($currentSelections | Where-Object { $_.ShortName -ieq $shortName }) {
                Write-Host "An environment with short name '$shortName' is already selected (case-insensitive match)." -ForegroundColor Red
                Start-Sleep -Seconds 2
                return $null
            }

            $currentCredentials = @($ExistingCredentials)
            $currentCredentials += @($currentSelections | ForEach-Object { $_.Credentials } | Where-Object { $null -ne $_ })
            $currentServiceAccounts = @($ExistingServiceAccounts)
            $currentServiceAccounts += @($currentSelections | ForEach-Object { $_.ServiceAccountUPN } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

            return Get-AzDoEnvironmentConfiguration `
                -EnvironmentName $shortName `
                -EnvironmentUrl $url `
                -FriendlyName $selectedEnv.FriendlyName `
                -ExistingCredentials $currentCredentials `
                -ExistingServiceAccounts $currentServiceAccounts `
                -TenantId $TenantId `
                -ProjectName $ProjectName `
                -OrganizationId $OrganizationId `
                -OrganizationName $OrganizationName `
                -UseAlm4DataverseExtension $UseAlm4DataverseExtension
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
            $selectedEnv = Select-DataverseEnvironment -Prompt "Select the deployment environment for '$($environmentToEdit.ShortName)'" -ExcludeUrl $ExcludedUrl -PreferredUrl $currentUrl
            if (-not $selectedEnv) {
                return $null
            }

            $url = ConvertTo-NormalizedEnvironmentUrl -Url $selectedEnv.Endpoints['WebApplication']
            if ($otherSelections | Where-Object { $_.Url -ieq $url }) {
                Write-Host "An environment with Url '$url' is already selected." -ForegroundColor Red
                Start-Sleep -Seconds 2
                return $null
            }

            Write-Host 'Use a short deployment environment name (for example: TEST, UAT, PROD).' -ForegroundColor DarkGray
            $shortName = Read-TextWithDefault -Prompt 'Enter a short name for this environment' -DefaultValue $environmentToEdit.ShortName
            if ($otherSelections | Where-Object { $_.ShortName -ieq $shortName }) {
                Write-Host "An environment with short name '$shortName' is already selected (case-insensitive match)." -ForegroundColor Red
                Start-Sleep -Seconds 2
                return $null
            }

            $currentCredentials = @($ExistingCredentials)
            $currentCredentials += @($otherSelections | ForEach-Object { $_.Credentials } | Where-Object { $null -ne $_ })
            $currentServiceAccounts = @($ExistingServiceAccounts)
            $currentServiceAccounts += @($otherSelections | ForEach-Object { $_.ServiceAccountUPN } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

            return Get-AzDoEnvironmentConfiguration `
                -EnvironmentName $shortName `
                -EnvironmentUrl $url `
                -FriendlyName $selectedEnv.FriendlyName `
                -ExistingCredentials $currentCredentials `
                -ExistingServiceAccounts $currentServiceAccounts `
                -TenantId $TenantId `
                -ProjectName $ProjectName `
                -OrganizationId $OrganizationId `
                -OrganizationName $OrganizationName `
                -UseAlm4DataverseExtension $UseAlm4DataverseExtension `
                -ExistingCredential $environmentToEdit.Credentials `
                -ExistingServiceAccountUPN $environmentToEdit.ServiceAccountUPN
        })

    $completedEnvironments = @()
    foreach ($selectedEnvironment in @($selectedEnvironments)) {
        if ([string]::IsNullOrWhiteSpace($selectedEnvironment.ShortName)) {
            continue
        }

        $resolvedEnvironmentUrl = ConvertTo-NormalizedEnvironmentUrl -Url $selectedEnvironment.Url
        $resolvedFriendlyName = if ([string]::IsNullOrWhiteSpace($selectedEnvironment.FriendlyName)) { $selectedEnvironment.ShortName } else { $selectedEnvironment.FriendlyName }

        if ([string]::IsNullOrWhiteSpace($resolvedEnvironmentUrl)) {
            Write-Warning "Environment '$($selectedEnvironment.ShortName)' was detected in the deployment pipeline but no matching Service Endpoint URL was found. You'll be asked to resolve it now."
            $resolvedEnvironment = Select-DataverseEnvironment -Prompt "Resolve the Dataverse environment for existing deployment stage '$($selectedEnvironment.ShortName)'" -ExcludeUrl $ExcludedUrl -PreferredUrl $selectedEnvironment.Url
            if (-not $resolvedEnvironment) {
                throw "No Dataverse environment selected for existing deployment stage '$($selectedEnvironment.ShortName)'."
            }

            $resolvedEnvironmentUrl = ConvertTo-NormalizedEnvironmentUrl -Url $resolvedEnvironment.Endpoints['WebApplication']
            $resolvedFriendlyName = $resolvedEnvironment.FriendlyName
        }

        if ($resolvedEnvironmentUrl -eq $normalizedExcludedUrl) {
            Write-Warning "Skipping deployment environment '$($selectedEnvironment.ShortName)' because it points at the selected DEV environment URL."
            continue
        }

        $needsConfiguration = (
            ($selectedEnvironment.PSObject.Properties.Name -contains 'ConfigurationPending' -and $selectedEnvironment.ConfigurationPending) -or
            ($null -eq $selectedEnvironment.Credentials) -or
            [string]::IsNullOrWhiteSpace($selectedEnvironment.ServiceAccountUPN)
        )

        if ($needsConfiguration) {
            Write-Host "Completing configuration for existing deployment environment '$($selectedEnvironment.ShortName)'..." -ForegroundColor Yellow
            $completedEnvironment = Get-AzDoEnvironmentConfiguration `
                -EnvironmentName $selectedEnvironment.ShortName `
                -EnvironmentUrl $resolvedEnvironmentUrl `
                -FriendlyName $resolvedFriendlyName `
                -ExistingCredentials $credentialsForReuse `
                -ExistingServiceAccounts $serviceAccountsForReuse `
                -TenantId $TenantId `
                -ProjectName $ProjectName `
                -OrganizationId $OrganizationId `
                -OrganizationName $OrganizationName `
                -UseAlm4DataverseExtension $UseAlm4DataverseExtension `
                -ExistingCredential $selectedEnvironment.Credentials `
                -ExistingServiceAccountUPN $selectedEnvironment.ServiceAccountUPN
        }
        else {
            $completedEnvironment = [pscustomobject]@{
                ShortName         = $selectedEnvironment.ShortName
                FriendlyName      = $resolvedFriendlyName
                Url               = $resolvedEnvironmentUrl
                Credentials       = $selectedEnvironment.Credentials
                ServiceAccountUPN = $selectedEnvironment.ServiceAccountUPN
                IsDevelopmentEnvironment = $false
            }
        }

        $completedEnvironments += $completedEnvironment
        if ($completedEnvironment.Credentials -and -not ($credentialsForReuse | Where-Object { $_.ApplicationId -eq $completedEnvironment.Credentials.ApplicationId -and $_.TenantId -eq $completedEnvironment.Credentials.TenantId })) {
            $credentialsForReuse += $completedEnvironment.Credentials
        }
        if (-not [string]::IsNullOrWhiteSpace($completedEnvironment.ServiceAccountUPN) -and $serviceAccountsForReuse -notcontains $completedEnvironment.ServiceAccountUPN) {
            $serviceAccountsForReuse += $completedEnvironment.ServiceAccountUPN
        }
    }

    return @($completedEnvironments)
}

function Update-DeployPipelineInWorkingTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][array]$Environments,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter()][bool]$UseAlm4DataverseExtension = $true
    )

    $deployYamlName = "DEPLOY-$Branch.yml"
    $deployYamlPath = Join-Path $RepoRoot "pipelines\$deployYamlName"

    if (-not $Environments -or $Environments.Count -eq 0) {
        if (Test-Path -LiteralPath $deployYamlPath) {
            Remove-Item -LiteralPath $deployYamlPath -Force
            Write-Host "$deployYamlName removed because branch '$Branch' has no deployment environments configured." -ForegroundColor Yellow
            return $true
        }

        Write-Host "$deployYamlName is not required because branch '$Branch' has no deployment environments configured." -ForegroundColor Yellow
        return $false
    }

    if (-not (Test-Path -LiteralPath $deployYamlPath)) {
        throw "pipelines\$deployYamlName not found"
    }

    $originalContent = Get-Content -LiteralPath $deployYamlPath -Raw
    $contentLines = Get-Content -LiteralPath $deployYamlPath
    $cleanedContent = @()
    $i = 0
    while ($i -lt $contentLines.Count) {
        $line = $contentLines[$i]
        if ($line.Trim() -eq '- template: pipelines/templates/stages/deploy-environment.yml@ALM4Dataverse') {
            $i++
            if ($i -lt $contentLines.Count -and $contentLines[$i].Trim() -eq 'parameters:') {
                $i++
                while ($i -lt $contentLines.Count -and $contentLines[$i] -match '^\s{6}\S') {
                    $i++
                }
            }
        }
        else {
            $cleanedContent += $line
            $i++
        }
    }

    $newStages = "`n"
    foreach ($env in $Environments) {
        $newStages += "  - template: pipelines/templates/stages/deploy-environment.yml@ALM4Dataverse`n"
        $newStages += "    parameters:`n"
        $newStages += "      environmentName: $($env.ShortName)`n"
        $newStages += "      useAlm4DataverseExtension: $($UseAlm4DataverseExtension.ToString().ToLowerInvariant())`n"
    }

    $updatedContent = (($cleanedContent -join [Environment]::NewLine).TrimEnd() + $newStages).TrimEnd() + [Environment]::NewLine
    if ($updatedContent -eq $originalContent) {
        Write-Host "$deployYamlName already matches the selected deployment environments." -ForegroundColor Green
        return $false
    }

    Set-Content -LiteralPath $deployYamlPath -Value $updatedContent -NoNewline
    Write-Host "$deployYamlName updated in the working tree." -ForegroundColor Green
    return $true
}

function New-AzDoPullRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryId,
        [Parameter(Mandatory)][string]$SourceBranch,
        [Parameter(Mandatory)][string]$TargetBranch,
        [Parameter(Mandatory)][string]$Title,
        [Parameter()][string]$Description
    )

    $body = @{
        sourceRefName = "refs/heads/$SourceBranch"
        targetRefName = "refs/heads/$TargetBranch"
        title         = $Title
        description   = $Description
    }

    return Invoke-VSTeamRequest -Method POST -Resource "git/repositories/$RepositoryId/pullrequests" -Body ($body | ConvertTo-Json -Depth 10) -ContentType 'application/json' -Version '7.1'
}

function Publish-AzDoRepoChanges {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][object]$PublishPlan,
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][object]$Repository
    )

    Push-Location $RepoRoot
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & git add -A
        if ($LASTEXITCODE -ne 0) {
            throw 'Git add failed.'
        }

        & git diff --cached --quiet
        $hasChanges = ($LASTEXITCODE -ne 0)
        if (-not $hasChanges) {
            Write-Host "No content changes detected, but ensuring branch '$($PublishPlan.BranchName)' exists on origin..." -ForegroundColor Yellow
            & git -c "http.extraheader=AUTHORIZATION: bearer $AccessToken" push -u origin $PublishPlan.BranchName 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw 'Git push failed.'
            }

            Write-Host 'No changes to commit; main repo already contains the required files.' -ForegroundColor Green
            return [pscustomobject]@{
                HasChanges     = $false
                BranchName     = $PublishPlan.BranchName
                TargetBranch   = $PublishPlan.TargetBranch
                PullRequestUrl = $null
                Mode           = $PublishPlan.Mode
            }
        }

        & git config user.name 'ALM4Dataverse Setup' 2>$null
        & git config user.email 'setup@alm4dataverse.local' 2>$null

        & git commit -m $PublishPlan.CommitMessage 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw 'Git commit failed.'
        }

        Write-Host "Pushing to origin/$($PublishPlan.BranchName)..." -ForegroundColor Yellow
        & git -c "http.extraheader=AUTHORIZATION: bearer $AccessToken" push -u origin $PublishPlan.BranchName 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw 'Git push failed.'
        }

        $pullRequestUrl = $null
        if ($PublishPlan.Mode -eq 'PullRequest') {
            Write-Host "Creating pull request into '$($PublishPlan.TargetBranch)'..." -ForegroundColor Yellow
            $pullRequest = New-AzDoPullRequest `
                -RepositoryId $Repository.Id `
                -SourceBranch $PublishPlan.BranchName `
                -TargetBranch $PublishPlan.TargetBranch `
                -Title $PublishPlan.PullRequestTitle `
                -Description $PublishPlan.PullRequestDescription

            if ($pullRequest -and $pullRequest._links -and $pullRequest._links.web -and $pullRequest._links.web.href) {
                $pullRequestUrl = $pullRequest._links.web.href
            }
            elseif ($pullRequest -and $pullRequest.url) {
                $pullRequestUrl = $pullRequest.url
            }
        }

        Write-Host 'Main repository updated successfully.' -ForegroundColor Green
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

function Publish-AzDoBranchSetupChanges {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ConfiguredBranch,
        [Parameter(Mandatory)][object]$PublishPlan,
        [Parameter(Mandatory)][string]$DefaultBranch,
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][object]$Repository,
        [Parameter(Mandatory)][string]$CopyRoot,
        [Parameter(Mandatory)][string]$SharedRepositoryName,
        [Parameter(Mandatory)][bool]$UseAlm4DataverseExtension,
        [Parameter()][AllowNull()][array]$Solutions,
        [Parameter()][array]$DeploymentEnvironments,
        [Parameter()][bool]$BuildValidationEnabled = $false,
        [Parameter()][string]$BuildValidationEnvironmentName = ''
    )

    Push-Location $RepoRoot
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & git -c "http.extraheader=AUTHORIZATION: bearer $AccessToken" fetch origin '+refs/heads/*:refs/remotes/origin/*' --prune 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'Failed to refresh remote branches before publishing.'
        }

        & git reset --hard HEAD 2>&1 | Out-Null
        & git clean -fd 2>&1 | Out-Null

        & git -c "http.extraheader=AUTHORIZATION: bearer $AccessToken" -c credential.interactive=never ls-remote --exit-code --heads origin $ConfiguredBranch 2>&1 | Out-Null
        $targetBranchExistsOnOrigin = ($LASTEXITCODE -eq 0)

        & git -c "http.extraheader=AUTHORIZATION: bearer $AccessToken" -c credential.interactive=never ls-remote --exit-code --heads origin $DefaultBranch 2>&1 | Out-Null
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

            & git -c "http.extraheader=AUTHORIZATION: bearer $AccessToken" push -u origin $ConfiguredBranch 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to push target branch '$ConfiguredBranch' to origin."
            }

            $targetBranchExistsOnOrigin = $true
            $seedRef = $ConfiguredBranch
        }

        & git rev-parse --verify HEAD 2>&1 | Out-Null
        $hasLocalHeadCommit = ($LASTEXITCODE -eq 0)

        if ($PublishPlan.Mode -eq 'PullRequest') {
            $workingBaseRef = if ($targetBranchExistsOnOrigin) { "origin/$ConfiguredBranch" } elseif ($seedRef) { $seedRef } else { 'HEAD' }
            & git checkout -B $PublishPlan.BranchName $workingBaseRef 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to create or switch to working branch '$($PublishPlan.BranchName)'."
            }
        }
        else {
            $directBaseRef = if ($targetBranchExistsOnOrigin) { "origin/$ConfiguredBranch" } elseif ($seedRef) { $seedRef } elseif ($hasLocalHeadCommit) { 'HEAD' } else { $null }
            if ($directBaseRef) {
                $checkoutOutput = @(& git checkout -B $ConfiguredBranch $directBaseRef 2>&1)
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to create or switch to target branch '$ConfiguredBranch' from '$directBaseRef': $($checkoutOutput -join ' ')"
                }
            }
            else {
                $checkoutOutput = @(& git checkout --orphan $ConfiguredBranch 2>&1)
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to create orphan target branch '$ConfiguredBranch': $($checkoutOutput -join ' ')"
                }
            }
        }

        Sync-CopyToYourRepoIntoGitRepo `
            -SourceRoot $CopyRoot `
            -TargetRoot $RepoRoot `
            -RepositoryName $Repository.Name `
            -SharedRepositoryName $SharedRepositoryName `
            -Branch $ConfiguredBranch `
            -UseAlm4DataverseExtension $UseAlm4DataverseExtension

        [void](Update-AlmConfigInWorkingTree -Solutions $Solutions -BuildValidationEnabled $BuildValidationEnabled -RepoRoot $RepoRoot)

        $buildEnvironmentName = if ($BuildValidationEnabled) { [string]$BuildValidationEnvironmentName } else { '' }
        Update-AzDoBuildPipelineInWorkingTree `
            -RepoRoot $RepoRoot `
            -SharedRepositoryName $SharedRepositoryName `
            -BuildEnvironmentName $buildEnvironmentName `
            -UseAlm4DataverseExtension $UseAlm4DataverseExtension

        [void](Update-DeployPipelineInWorkingTree -Environments @($DeploymentEnvironments) -RepoRoot $RepoRoot -Branch $ConfiguredBranch -UseAlm4DataverseExtension $UseAlm4DataverseExtension)

        return Publish-AzDoRepoChanges -RepoRoot $RepoRoot -PublishPlan $PublishPlan -AccessToken $AccessToken -Repository $Repository
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        Pop-Location
    }
}

function Get-AzDoPublishSummaryText {
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

function Apply-AzDoEnvironmentConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$EnvironmentConfiguration,
        [Parameter(Mandatory)][string]$OrganizationName,
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter()][object]$ExportPipeline,
        [Parameter()][object]$DeployPipeline,
        [Parameter()][bool]$UseAlm4DataverseExtension = $true
    )

    $creds = $EnvironmentConfiguration.Credentials
    $serviceAccountUPN = $EnvironmentConfiguration.ServiceAccountUPN
    $isDevelopmentEnvironment = $false
    if ($EnvironmentConfiguration.PSObject.Properties.Name -contains 'IsDevelopmentEnvironment') {
        $isDevelopmentEnvironment = [bool]$EnvironmentConfiguration.IsDevelopmentEnvironment
    }

    $pipelineForPermissions = if ($isDevelopmentEnvironment) { $ExportPipeline } else { $DeployPipeline }

    $endpoint = $null
    if (-not $creds.IsExistingServiceConnection) {
        $endpointParams = @{
            ProjectName         = $ProjectName
            ServiceEndpointName = $EnvironmentConfiguration.ShortName
            EnvironmentUrl      = $EnvironmentConfiguration.Url
            ApplicationId       = $creds.ApplicationId
            TenantId            = $creds.TenantId
        }

        if ($creds.AuthType -eq 'WIF') {
            $endpointParams.AuthType = 'WIF'
        }
        else {
            $endpointParams.ClientSecret = $creds.ClientSecret
            $endpointParams.AuthType = 'Secret'
        }

        $endpoint = Ensure-AzDoServiceEndpoint @endpointParams

        if ($creds.AuthType -eq 'WIF') {
            $wifIssuer = $endpoint.authorization.parameters.workloadIdentityFederationIssuer
            $wifSubject = $endpoint.authorization.parameters.workloadIdentityFederationSubject
            if ($wifIssuer -and $wifSubject) {
                $appObjectId = $creds.ApplicationObjectId
                if (-not $appObjectId) {
                    $graphToken = Get-AuthToken -ResourceUrl 'https://graph.microsoft.com' -TenantId $creds.TenantId
                    $gHeaders = @{ Authorization = "Bearer $($graphToken.AccessToken)" }
                    $gUri = "https://graph.microsoft.com/v1.0/applications?`$filter=appId eq '$($creds.ApplicationId)'&`$select=id,appId"
                    $gResult = Invoke-RestMethod -Uri $gUri -Headers $gHeaders -Method Get
                    if ($gResult.value.Count -gt 0) { $appObjectId = $gResult.value[0].id }
                }
                if ($appObjectId) {
                    $safeOrgName = ConvertTo-UrlSafeName -Name $OrganizationName
                    $safeProjectName = ConvertTo-UrlSafeName -Name $ProjectName
                    $safeSCName = ConvertTo-UrlSafeName -Name $EnvironmentConfiguration.ShortName
                    [void](Add-EntraIdFederatedCredential `
                        -ApplicationObjectId $appObjectId `
                        -TenantId $creds.TenantId `
                        -Issuer $wifIssuer `
                        -Subject $wifSubject `
                        -CredentialName "AzDO-$safeOrgName-$safeProjectName-$safeSCName")
                }
                else {
                    Write-Warning 'Could not determine Application Object ID. Federated credential not added - add it manually in Entra ID.'
                }
            }
            else {
                Write-Warning 'Service connection does not expose WIF issuer/subject properties. Federated credential not added - add it manually in Entra ID.'
            }
        }
    }
    else {
        $endpoints = @(Get-VSTeamServiceEndpoint -ProjectName $ProjectName -ErrorAction SilentlyContinue)
        $endpoint = $endpoints | Where-Object { $_.name -eq $EnvironmentConfiguration.ShortName } | Select-Object -First 1
    }

    if ($endpoint -and $endpoint.id -and $pipelineForPermissions) {
        Ensure-AzDoPipelinePermission -Organization $OrganizationName -Project $ProjectName -ResourceType 'endpoint' -ResourceId $endpoint.id -PipelineId $pipelineForPermissions.id
    }

    if (-not $isDevelopmentEnvironment) {
        $azDoEnv = Ensure-AzDoEnvironment -Organization $OrganizationName -Project $ProjectName -EnvironmentName $EnvironmentConfiguration.ShortName -Description "Deployment environment for $($EnvironmentConfiguration.ShortName)"
        if ($azDoEnv -and $DeployPipeline) {
            Ensure-AzDoPipelinePermission -Organization $OrganizationName -Project $ProjectName -ResourceType 'environment' -ResourceId $azDoEnv.id -PipelineId $DeployPipeline.id
        }
    }

    Ensure-DataverseApplicationUser -EnvironmentUrl $EnvironmentConfiguration.Url -ApplicationId $creds.ApplicationId -TenantId $creds.TenantId
    Ensure-DataverseServiceAccountUser -EnvironmentUrl $EnvironmentConfiguration.Url -ServiceAccountUPN $serviceAccountUPN -TenantId $creds.TenantId

    $groupName = "Environment-$($EnvironmentConfiguration.ShortName)"
    $variables = @{
        'DATAVERSECONNREF_example_uniquename' = 'connectionid'
        'DATAVERSEENVVAR_example_uniquename'  = 'value'
        'DataverseServiceAccountUPN' = $serviceAccountUPN
    }

    $varGroup = $null
    if ($isDevelopmentEnvironment) {
        $varGroup = Ensure-AzDoVariableGroupExists -Organization $OrganizationName -Project $ProjectName -ProjectId $ProjectId -GroupName $groupName -Variables $variables
    }
    else {
        $varGroup = Ensure-AzDoVariableGroupExists -Organization $OrganizationName -Project $ProjectName -ProjectId $ProjectId -GroupName $groupName -Variables $variables
    }

    if ($varGroup -and $varGroup.id -and $pipelineForPermissions) {
        Ensure-AzDoPipelinePermission -Organization $OrganizationName -Project $ProjectName -ResourceType 'variablegroup' -ResourceId $varGroup.id -PipelineId $pipelineForPermissions.id
    }
}

function Invoke-AzDoBranchAwareSetup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MainRepoWorkingRoot,
        [Parameter(Mandatory)][object]$MainRepo,
        [Parameter(Mandatory)][object]$SelectedProject,
        [Parameter(Mandatory)][string]$OrganizationId,
        [Parameter(Mandatory)][string]$OrganizationName,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$DefaultBranch,
        [Parameter(Mandatory)][string]$SharedRepositoryName,
        [Parameter(Mandatory)][bool]$UseAlm4DataverseExtension,
        [Parameter(Mandatory)][string]$ALM4DataverseRef
    )

    $credentialsCache = @()
    $serviceAccountsCache = @()

    $existingSetupState = Invoke-WithSpectreStatus -Status 'Inspecting existing Azure DevOps branch setup state...' -ScriptBlock {
        Get-AzDoRepositoryExistingSetupState -RepoRoot $MainRepoWorkingRoot -ProjectName $SelectedProject.Name -DefaultBranch $DefaultBranch -TenantId $TenantId
    }

    $initialBranchMappings = @(Get-AzDoInitialBranchMappings -ExistingSetupState $existingSetupState -DefaultBranch $DefaultBranch)
    $branchStates = @()
    foreach ($selectedBranchMapping in $initialBranchMappings) {
        $branchName = [string]$selectedBranchMapping.BranchName
        $existingBranchState = $existingSetupState.BranchStates | Where-Object { $_.BranchName -ieq $branchName } | Select-Object -First 1

        $branchStates += New-AzDoBranchSetupState `
            -BranchName $branchName `
            -ExistingDevEnvironment $existingBranchState.ExistingDevEnvironment `
            -DeploymentEnvironments @($(if ($existingBranchState) { $existingBranchState.DeploymentEnvironments } else { $selectedBranchMapping.Environments })) `
            -PublishPlan $null
    }

    $wizardState = [pscustomobject]@{
        BranchStates         = @($branchStates)
        SolutionData         = $null
        SolutionSourceBranch = $null
        BranchEnvironmentMappingCompleted = $false
        BuildValidationEnabled = [bool](Get-OptionalObjectPropertyValue -InputObject $existingSetupState -PropertyName 'BuildValidationEnabled')
        BuildValidationEnvironmentConfiguration = (Get-OptionalObjectPropertyValue -InputObject $existingSetupState -PropertyName 'ExistingBuildValidationEnvironment')
    }

    Invoke-SetupWizard -Title 'Azure DevOps ALM4Dataverse setup' -Steps @(
        [pscustomobject]@{
            Name = 'Configure branches'
            Action = {
                $existingEnvironmentConfigurations = @($existingSetupState.BranchStates | ForEach-Object { @($_.DeploymentEnvironments) } | Where-Object { $null -ne $_ })
                $currentBranchMappings = @($wizardState.BranchStates | ForEach-Object {
                    [pscustomobject]@{
                        BranchName                  = [string]$_.BranchName
                        DevEnvironmentConfiguration = $_.DevEnvironmentConfiguration
                        ExistingDevEnvironment      = $_.ExistingDevEnvironment
                        Environments                = @($_.DeploymentEnvironments)
                    }
                })

                $selectedBranchMappings = @(Select-BranchEnvironmentMappings `
                    -EnvironmentConfigurations $existingEnvironmentConfigurations `
                    -InitialBranchMappings $currentBranchMappings `
                    -Title 'Manage deployment branches' `
                    -GuidanceLines @(
                        'Start by listing the Git branches that should carry ALM4Dataverse automation. Each branch becomes its own setup track with branch-specific DEV and DEPLOY configuration.',
                        'Best practice: include only the branches that should really own a DEV environment or a DEPLOY pipeline so setup does not create noise on inactive branches.'
                    ) `
                    -DocRelativePath 'docs/setup/azdo-automated-setup.md' `
                    -Ref $ALM4DataverseRef `
                    -EditDevEnvironmentScriptBlock {
                        param($allMappings, $mappingToEdit)

                        Write-Section `
                            -Message "DEV environment for branch '$($mappingToEdit.BranchName)'"
                        $existingDevEnvironment = $mappingToEdit.ExistingDevEnvironment
                        $existingDevEnvironmentUrl = [string](Get-OptionalObjectPropertyValue -InputObject $existingDevEnvironment -PropertyName 'Url')
                        $existingDevEnvironmentFriendlyName = [string](Get-OptionalObjectPropertyValue -InputObject $existingDevEnvironment -PropertyName 'FriendlyName')
                        $existingDevEnvironmentCredential = Get-OptionalObjectPropertyValue -InputObject $existingDevEnvironment -PropertyName 'Credentials'
                        $existingDevEnvironmentServiceAccountUPN = [string](Get-OptionalObjectPropertyValue -InputObject $existingDevEnvironment -PropertyName 'ServiceAccountUPN')

                        if (-not [string]::IsNullOrWhiteSpace($existingDevEnvironmentUrl)) {
                            Write-Host "Existing DEV environment: $existingDevEnvironmentFriendlyName ($existingDevEnvironmentUrl)" -ForegroundColor DarkGray
                        }

                        $configureDevEnvironment = Read-YesNo -Prompt "Configure a DEV environment for branch '$($mappingToEdit.BranchName)'?"
                        if (-not $configureDevEnvironment) {
                            return $null
                        }

                        $selectedDevEnvironment = Select-DataverseEnvironment -Prompt "Select the DEV environment for branch '$($mappingToEdit.BranchName)'" -PreferredUrl $existingDevEnvironmentUrl
                        if (-not $selectedDevEnvironment) {
                            return $mappingToEdit.DevEnvironmentConfiguration
                        }

                        $updatedDevConfiguration = Invoke-WithErrorHandling -OperationName "Selecting DEV environment credentials for branch '$($mappingToEdit.BranchName)'" -ScriptBlock {
                            Get-AzDoEnvironmentConfiguration `
                                -EnvironmentName "Dev-$($mappingToEdit.BranchName)" `
                                -EnvironmentUrl (ConvertTo-NormalizedEnvironmentUrl -Url $selectedDevEnvironment.Endpoints['WebApplication']) `
                                -FriendlyName $selectedDevEnvironment.FriendlyName `
                                -ExistingCredentials $credentialsCache `
                                -ExistingServiceAccounts $serviceAccountsCache `
                                -TenantId $TenantId `
                                -ProjectName $SelectedProject.Name `
                                -OrganizationId $OrganizationId `
                                -OrganizationName $OrganizationName `
                                -UseAlm4DataverseExtension $UseAlm4DataverseExtension `
                                -ExistingCredential $existingDevEnvironmentCredential `
                                -ExistingServiceAccountUPN $existingDevEnvironmentServiceAccountUPN `
                                -IsDevelopmentEnvironment $true
                        }

                        if ($updatedDevConfiguration -and -not ($credentialsCache | Where-Object { $_.ApplicationId -eq $updatedDevConfiguration.Credentials.ApplicationId -and $_.TenantId -eq $updatedDevConfiguration.Credentials.TenantId })) {
                            $credentialsCache += $updatedDevConfiguration.Credentials
                        }
                        if ($updatedDevConfiguration -and $serviceAccountsCache -notcontains $updatedDevConfiguration.ServiceAccountUPN) {
                            $serviceAccountsCache += $updatedDevConfiguration.ServiceAccountUPN
                        }

                        return $updatedDevConfiguration
                    } `
                    -EditDeploymentEnvironmentsScriptBlock {
                        param($allMappings, $mappingToEdit)

                        Write-Section `
                            -Message "Deployment environments for branch '$($mappingToEdit.BranchName)'"

                        $excludedUrl = $null
                        if ($mappingToEdit.DevEnvironmentConfiguration) {
                            $excludedUrl = $mappingToEdit.DevEnvironmentConfiguration.Url
                        }
                        elseif ($mappingToEdit.ExistingDevEnvironment) {
                            $excludedUrl = [string](Get-OptionalObjectPropertyValue -InputObject $mappingToEdit.ExistingDevEnvironment -PropertyName 'Url')
                        }

                        $updatedDeploymentEnvironments = @(Invoke-WithErrorHandling -OperationName "Selecting deployment environments for branch '$($mappingToEdit.BranchName)'" -ScriptBlock {
                            Get-DataverseEnvironmentsSelection `
                                -ExcludedUrl $excludedUrl `
                                -Branch $mappingToEdit.BranchName `
                                -ProjectName $SelectedProject.Name `
                                -InitialEnvironments @($mappingToEdit.Environments) `
                                -ExistingCredentials $credentialsCache `
                                -ExistingServiceAccounts $serviceAccountsCache `
                                -TenantId $TenantId `
                                -OrganizationId $OrganizationId `
                                -OrganizationName $OrganizationName `
                                -UseAlm4DataverseExtension $UseAlm4DataverseExtension
                        })

                        foreach ($deploymentEnvironment in @($updatedDeploymentEnvironments)) {
                            if ($deploymentEnvironment.Credentials -and -not ($credentialsCache | Where-Object { $_.ApplicationId -eq $deploymentEnvironment.Credentials.ApplicationId -and $_.TenantId -eq $deploymentEnvironment.Credentials.TenantId })) {
                                $credentialsCache += $deploymentEnvironment.Credentials
                            }
                            if (-not [string]::IsNullOrWhiteSpace($deploymentEnvironment.ServiceAccountUPN) -and $serviceAccountsCache -notcontains $deploymentEnvironment.ServiceAccountUPN) {
                                $serviceAccountsCache += $deploymentEnvironment.ServiceAccountUPN
                            }
                        }

                        return @($updatedDeploymentEnvironments)
                    })

                if ($selectedBranchMappings.Count -eq 0) {
                    throw 'At least one branch must be configured for Azure DevOps setup.'
                }

                $existingStateByBranch = @{}
                foreach ($branchState in @($wizardState.BranchStates)) {
                    $existingStateByBranch[$branchState.BranchName.ToLowerInvariant()] = $branchState
                }

                $updatedBranchStates = @()
                foreach ($selectedBranchMapping in $selectedBranchMappings) {
                    $branchName = [string]$selectedBranchMapping.BranchName
                    $branchKey = $branchName.ToLowerInvariant()

                    $existingBranchState = $null
                    if ($existingStateByBranch.ContainsKey($branchKey)) {
                        $existingBranchState = $existingStateByBranch[$branchKey]
                        $existingBranchState.DevEnvironmentConfiguration = $selectedBranchMapping.DevEnvironmentConfiguration
                        $existingBranchState.DeploymentEnvironments = @($selectedBranchMapping.Environments)
                    }
                    if (-not $existingBranchState) {
                        $existingBranchState = $existingSetupState.BranchStates | Where-Object { $_.BranchName -ieq $branchName } | Select-Object -First 1
                    }

                    $publishPlan = Get-BranchTargetedRepoChangePublishPlan `
                        -ProviderName 'Azure DevOps' `
                        -RepositoryName $MainRepo.Name `
                        -TargetBranch $branchName `
                        -DefaultCommitMessage "Add ALM4Dataverse Azure DevOps pipelines for branch '$branchName'" `
                        -DefaultPullRequestTitle "Add ALM4Dataverse Azure DevOps pipelines for branch '$branchName'" `
                        -DefaultPullRequestDescription "This pull request adds or updates the ALM4Dataverse Azure DevOps pipeline YAML and repository configuration generated by setup-azdo.ps1 for branch '$branchName'." `
                        -GuidanceLines @(
                            'If branch protection or approvals apply, choose the pull-request path so the generated YAML and config changes can be reviewed before they land.',
                            'If you commit directly, the target branch is updated immediately and the matching pipeline definitions can start using that branch as soon as the push completes.'
                        ) `
                        -DocRelativePath 'docs/setup/azdo-automated-setup.md' `
                        -Ref $ALM4DataverseRef

                    $updatedBranchStates += New-AzDoBranchSetupState `
                        -BranchName $branchName `
                        -ExistingDevEnvironment $(if ($existingBranchState) { $existingBranchState.ExistingDevEnvironment } else { $null }) `
                        -DeploymentEnvironments @($(if ($existingBranchState) { $existingBranchState.DeploymentEnvironments } else { @() })) `
                        -PublishPlan $publishPlan
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
                        $existingBranchState = New-AzDoBranchSetupState -BranchName ([string]$mappedBranch.BranchName) -ExistingDevEnvironment $null -DeploymentEnvironments @() -PublishPlan $null
                    }

                    $existingBranchState.DevEnvironmentConfiguration = $mappedBranch.DevEnvironmentConfiguration
                    $existingBranchState.DeploymentEnvironments = @($mappedBranch.Environments)
                    $existingBranchState
                })

                $wizardState.BranchEnvironmentMappingCompleted = $true
            }
        },
        [pscustomobject]@{
            Name = 'Configure DEV access'
            Action = {
                if ($wizardState.BranchEnvironmentMappingCompleted) {
                    [Spectre.Console.AnsiConsole]::MarkupLine('[grey]DEV environments were already configured while defining branches.[/]')
                    return
                }

                Write-Section `
                    -Message 'Configure branch-specific DEV environments'
                Write-SetupGuidance -Lines @(
                    'Decide branch by branch whether you want a dedicated DEV environment. This is optional, but only branches with a DEV environment can be used for solution selection later.',
                    'Best practice: keep the DEV short name aligned to the branch (for example Dev-main, Dev-release) so EXPORT and BUILD stay easy to reason about.'
                ) -DocRelativePath 'docs/config/azdo-environment-service-connection.md' -Ref $ALM4DataverseRef -Header 'Branch DEV strategy guidance'

                foreach ($branchState in @($wizardState.BranchStates)) {
                    Write-Section `
                        -Message "DEV environment for branch '$($branchState.BranchName)'"

                    $existingDevEnvironment = $branchState.ExistingDevEnvironment
                    $existingDevEnvironmentUrl = [string](Get-OptionalObjectPropertyValue -InputObject $existingDevEnvironment -PropertyName 'Url')
                    $existingDevEnvironmentFriendlyName = [string](Get-OptionalObjectPropertyValue -InputObject $existingDevEnvironment -PropertyName 'FriendlyName')
                    $existingDevEnvironmentCredential = Get-OptionalObjectPropertyValue -InputObject $existingDevEnvironment -PropertyName 'Credentials'
                    $existingDevEnvironmentServiceAccountUPN = [string](Get-OptionalObjectPropertyValue -InputObject $existingDevEnvironment -PropertyName 'ServiceAccountUPN')

                    if (-not [string]::IsNullOrWhiteSpace($existingDevEnvironmentUrl)) {
                        Write-Host "Existing DEV environment: $existingDevEnvironmentFriendlyName ($existingDevEnvironmentUrl)" -ForegroundColor DarkGray
                    }

                    $configureDevEnvironment = Read-YesNo -Prompt "Configure a DEV environment for branch '$($branchState.BranchName)'?"
                    if (-not $configureDevEnvironment) {
                        $branchState.DevEnvironmentConfiguration = $null
                        continue
                    }

                    $selectedDevEnvironment = Select-DataverseEnvironment -Prompt "Select the DEV environment for branch '$($branchState.BranchName)'" -PreferredUrl $existingDevEnvironmentUrl
                    if (-not $selectedDevEnvironment) {
                        throw "No DEV environment selected for branch '$($branchState.BranchName)'."
                    }

                    $branchState.DevEnvironmentConfiguration = Invoke-WithErrorHandling -OperationName "Selecting DEV environment credentials for branch '$($branchState.BranchName)'" -ScriptBlock {
                        Get-AzDoEnvironmentConfiguration `
                            -EnvironmentName "Dev-$($branchState.BranchName)" `
                            -EnvironmentUrl (ConvertTo-NormalizedEnvironmentUrl -Url $selectedDevEnvironment.Endpoints['WebApplication']) `
                            -FriendlyName $selectedDevEnvironment.FriendlyName `
                            -ExistingCredentials $credentialsCache `
                            -ExistingServiceAccounts $serviceAccountsCache `
                            -TenantId $TenantId `
                            -ProjectName $SelectedProject.Name `
                            -OrganizationId $OrganizationId `
                            -OrganizationName $OrganizationName `
                            -UseAlm4DataverseExtension $UseAlm4DataverseExtension `
                            -ExistingCredential $existingDevEnvironmentCredential `
                            -ExistingServiceAccountUPN $existingDevEnvironmentServiceAccountUPN `
                            -IsDevelopmentEnvironment $true
                    }

                    if ($branchState.DevEnvironmentConfiguration -and -not ($credentialsCache | Where-Object { $_.ApplicationId -eq $branchState.DevEnvironmentConfiguration.Credentials.ApplicationId -and $_.TenantId -eq $branchState.DevEnvironmentConfiguration.Credentials.TenantId })) {
                        $credentialsCache += $branchState.DevEnvironmentConfiguration.Credentials
                    }
                    if ($branchState.DevEnvironmentConfiguration -and $serviceAccountsCache -notcontains $branchState.DevEnvironmentConfiguration.ServiceAccountUPN) {
                        $serviceAccountsCache += $branchState.DevEnvironmentConfiguration.ServiceAccountUPN
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

                Write-Section `
                    -Message 'Configure branch-specific deployment environments'
                Write-SetupGuidance -Lines @(
                    'Choose the deployment environments for each branch in promotion order. Setup will generate one DEPLOY YAML per configured branch.',
                    'Best practice: leave a branch empty if it should not own a DEPLOY pipeline yet. The matching DEPLOY YAML will be removed instead of left stale.'
                ) -DocRelativePath 'docs/setup/azdo-manual-setup.md' -Ref $ALM4DataverseRef -Header 'Branch deployment strategy guidance'

                foreach ($branchState in @($wizardState.BranchStates)) {
                    Write-Section `
                        -Message "Deployment environments for branch '$($branchState.BranchName)'"

                    $excludedUrl = $null
                    if ($branchState.DevEnvironmentConfiguration) {
                        $excludedUrl = $branchState.DevEnvironmentConfiguration.Url
                    }
                    elseif ($branchState.ExistingDevEnvironment) {
                        $excludedUrl = [string](Get-OptionalObjectPropertyValue -InputObject $branchState.ExistingDevEnvironment -PropertyName 'Url')
                    }

                    $branchState.DeploymentEnvironments = @(Invoke-WithErrorHandling -OperationName "Selecting deployment environments for branch '$($branchState.BranchName)'" -ScriptBlock {
                        Get-DataverseEnvironmentsSelection `
                            -ExcludedUrl $excludedUrl `
                            -Branch $branchState.BranchName `
                            -ProjectName $SelectedProject.Name `
                            -InitialEnvironments @($branchState.DeploymentEnvironments) `
                            -ExistingCredentials $credentialsCache `
                            -ExistingServiceAccounts $serviceAccountsCache `
                            -TenantId $TenantId `
                            -OrganizationId $OrganizationId `
                            -OrganizationName $OrganizationName `
                            -UseAlm4DataverseExtension $UseAlm4DataverseExtension
                    })

                    foreach ($deploymentEnvironment in @($branchState.DeploymentEnvironments)) {
                        if ($deploymentEnvironment.Credentials -and -not ($credentialsCache | Where-Object { $_.ApplicationId -eq $deploymentEnvironment.Credentials.ApplicationId -and $_.TenantId -eq $deploymentEnvironment.Credentials.TenantId })) {
                            $credentialsCache += $deploymentEnvironment.Credentials
                        }
                        if (-not [string]::IsNullOrWhiteSpace($deploymentEnvironment.ServiceAccountUPN) -and $serviceAccountsCache -notcontains $deploymentEnvironment.ServiceAccountUPN) {
                            $serviceAccountsCache += $deploymentEnvironment.ServiceAccountUPN
                        }
                    }
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
                    'When enabled, BUILD will run Dataverse connect first (same connection/auth flow as EXPORT) and then run solution validation.',
                    'This is a global setup choice: one environment configuration is used for BUILD across all configured branches.'
                ) -DocRelativePath 'docs/usage/building-releases.md' -Ref $ALM4DataverseRef -Header 'Build validation guidance'

                $enableBuildValidation = if ([bool]$wizardState.BuildValidationEnabled) {
                    Read-YesNo -Prompt 'Enable solution validation during BUILD?'
                }
                else {
                    Read-YesNo -Prompt 'Enable solution validation during BUILD?' -DefaultNo
                }

                if (-not $enableBuildValidation) {
                    $wizardState.BuildValidationEnabled = $false
                    $wizardState.BuildValidationEnvironmentConfiguration = $null
                    return
                }

                $existingBuildValidationEnvironment = $wizardState.BuildValidationEnvironmentConfiguration
                $existingBuildValidationEnvironmentUrl = [string](Get-OptionalObjectPropertyValue -InputObject $existingBuildValidationEnvironment -PropertyName 'Url')
                $existingBuildValidationEnvironmentName = [string](Get-OptionalObjectPropertyValue -InputObject $existingBuildValidationEnvironment -PropertyName 'ShortName')
                $existingBuildValidationEnvironmentFriendlyName = [string](Get-OptionalObjectPropertyValue -InputObject $existingBuildValidationEnvironment -PropertyName 'FriendlyName')
                $existingBuildValidationCredential = Get-OptionalObjectPropertyValue -InputObject $existingBuildValidationEnvironment -PropertyName 'Credentials'
                $existingBuildValidationServiceAccountUPN = [string](Get-OptionalObjectPropertyValue -InputObject $existingBuildValidationEnvironment -PropertyName 'ServiceAccountUPN')

                $selectedBuildEnvironment = Select-DataverseEnvironment -Prompt 'Select the Dataverse environment for global BUILD validation' -PreferredUrl $existingBuildValidationEnvironmentUrl
                if (-not $selectedBuildEnvironment) {
                    throw 'BUILD validation was enabled, but no Dataverse environment was selected.'
                }

                $buildValidationEnvironmentName = Read-TextWithDefault -Prompt 'Enter the Azure DevOps service connection name for BUILD validation' -DefaultValue $(if ([string]::IsNullOrWhiteSpace($existingBuildValidationEnvironmentName)) { 'Build' } else { $existingBuildValidationEnvironmentName })
                if ([string]::IsNullOrWhiteSpace($buildValidationEnvironmentName)) {
                    throw 'A service connection name is required for global BUILD validation.'
                }

                $wizardState.BuildValidationEnvironmentConfiguration = Invoke-WithErrorHandling -OperationName 'Selecting global BUILD validation environment credentials' -ScriptBlock {
                    Get-AzDoEnvironmentConfiguration `
                        -EnvironmentName $buildValidationEnvironmentName `
                        -EnvironmentUrl (ConvertTo-NormalizedEnvironmentUrl -Url $selectedBuildEnvironment.Endpoints['WebApplication']) `
                        -FriendlyName $(if ([string]::IsNullOrWhiteSpace($selectedBuildEnvironment.FriendlyName)) { $existingBuildValidationEnvironmentFriendlyName } else { $selectedBuildEnvironment.FriendlyName }) `
                        -ExistingCredentials $credentialsCache `
                        -ExistingServiceAccounts $serviceAccountsCache `
                        -TenantId $TenantId `
                        -ProjectName $SelectedProject.Name `
                        -OrganizationId $OrganizationId `
                        -OrganizationName $OrganizationName `
                        -UseAlm4DataverseExtension $UseAlm4DataverseExtension `
                        -ExistingCredential $existingBuildValidationCredential `
                        -ExistingServiceAccountUPN $existingBuildValidationServiceAccountUPN `
                        -IsDevelopmentEnvironment $false
                }

                if ($wizardState.BuildValidationEnvironmentConfiguration -and -not ($credentialsCache | Where-Object { $_.ApplicationId -eq $wizardState.BuildValidationEnvironmentConfiguration.Credentials.ApplicationId -and $_.TenantId -eq $wizardState.BuildValidationEnvironmentConfiguration.Credentials.TenantId })) {
                    $credentialsCache += $wizardState.BuildValidationEnvironmentConfiguration.Credentials
                }
                if ($wizardState.BuildValidationEnvironmentConfiguration -and $serviceAccountsCache -notcontains $wizardState.BuildValidationEnvironmentConfiguration.ServiceAccountUPN) {
                    $serviceAccountsCache += $wizardState.BuildValidationEnvironmentConfiguration.ServiceAccountUPN
                }

                $wizardState.BuildValidationEnabled = $true
            }
        },
        [pscustomobject]@{
            Name = 'Select solutions'
            Action = {
                Write-Section `
                    -Message 'Select solutions from a configured DEV branch'
                $solutionCandidateBranches = @($wizardState.BranchStates | Where-Object { $_.DevEnvironmentConfiguration })
                if ($solutionCandidateBranches.Count -eq 0) {
                    [Spectre.Console.AnsiConsole]::MarkupLine('[yellow]No branch has a DEV environment configured, so solution selection will be skipped for now.[/]')
                    $wizardState.SolutionData = $null
                    $wizardState.SolutionSourceBranch = $null
                    return
                }

                $solutionSourceBranchState = $solutionCandidateBranches[0]
                if ($solutionCandidateBranches.Count -gt 1) {
                    $branchMenuItems = @($solutionCandidateBranches | ForEach-Object {
                        $envLabel = if ($_.DevEnvironmentConfiguration -and -not [string]::IsNullOrWhiteSpace($_.DevEnvironmentConfiguration.FriendlyName)) { $_.DevEnvironmentConfiguration.FriendlyName } else { $_.DevEnvironmentConfiguration.ShortName }
                        "$($_.BranchName) - $envLabel"
                    })
                    $selectedBranchIndex = Select-FromMenu -Title 'Select the branch whose DEV environment should be used for solution selection' -Items $branchMenuItems -PromptGuidanceLines @(
                        'Choose which branch should provide the DEV environment for solution discovery.',
                        'Use the branch that best represents the solution baseline you want in source control.'
                    ) -PromptGuidanceDocRelativePath 'docs/config/alm-config.md' -PromptGuidanceRef $ALM4DataverseRef
                    if ($null -eq $selectedBranchIndex) {
                        throw 'No branch selected for solution selection.'
                    }

                    $solutionSourceBranchState = $solutionCandidateBranches[$selectedBranchIndex]
                }

                Write-SetupGuidance -Lines @(
                    "Solutions are selected last so they can be sourced from the exact DEV branch you trust for this setup run.",
                    'Best practice: pick the branch whose DEV environment currently reflects the solution set you want in source control.'
                ) -DocRelativePath 'docs/config/alm-config.md' -Ref $ALM4DataverseRef -Header 'Solution source branch guidance'

                $existingConfigTempPath = $null
                try {
                    $existingConfigContent = Get-GitRepoFileContentFromRemoteBranch -RepoRoot $MainRepoWorkingRoot -Branch $solutionSourceBranchState.BranchName -RelativePath 'alm-config.psd1'
                    if (-not [string]::IsNullOrWhiteSpace($existingConfigContent)) {
                        $existingConfigTempPath = Join-Path ([System.IO.Path]::GetTempPath()) ("alm-config-" + [guid]::NewGuid().ToString('n') + '.psd1')
                        Set-Content -LiteralPath $existingConfigTempPath -Value $existingConfigContent -NoNewline
                    }

                    $wizardState.SolutionData = Invoke-WithErrorHandling -OperationName 'Selecting Dataverse solutions' -ScriptBlock {
                        Get-DataverseSolutionsSelection -ExistingConfigPath $existingConfigTempPath -ExistingEnvironmentUrl $solutionSourceBranchState.DevEnvironmentConfiguration.Url
                    }
                }
                finally {
                    if ($existingConfigTempPath -and (Test-Path -LiteralPath $existingConfigTempPath)) {
                        Remove-Item -LiteralPath $existingConfigTempPath -Force -ErrorAction SilentlyContinue
                    }
                }

                $wizardState.SolutionSourceBranch = $solutionSourceBranchState.BranchName
            }
        },
        [pscustomobject]@{
            Name = 'Review choices'
            Action = {
                Write-Section `
                    -Message 'Review Dataverse environment configuration'

                $allConfiguredEnvironments = @()
                foreach ($branchState in @($wizardState.BranchStates)) {
                    if ($branchState.DevEnvironmentConfiguration) {
                        $allConfiguredEnvironments += $branchState.DevEnvironmentConfiguration
                    }
                    $allConfiguredEnvironments += @($branchState.DeploymentEnvironments)
                }

                Show-KeyValueSummaryTable -Heading 'Setup review' -Values ([ordered]@{
                    'Azure DevOps project' = $SelectedProject.Name
                    'Main repository'      = $MainRepo.Name
                    'Shared repository'    = $SharedRepositoryName
                    'Configured branches'  = [string]$wizardState.BranchStates.Count
                    'BUILD validation'     = $(if ($wizardState.BuildValidationEnabled) { 'Enabled' } else { 'Disabled' })
                    'BUILD validation environment' = $(if ($wizardState.BuildValidationEnvironmentConfiguration) { $wizardState.BuildValidationEnvironmentConfiguration.ShortName } else { '<none>' })
                    'Solution source branch' = $(if ([string]::IsNullOrWhiteSpace($wizardState.SolutionSourceBranch)) { '<none>' } else { $wizardState.SolutionSourceBranch })
                    'Solutions selected'   = [string]$(if ($wizardState.SolutionData) { @($wizardState.SolutionData.Solutions).Count } else { 0 })
                    'Extension mode'       = $(if ($UseAlm4DataverseExtension) { 'ALM4Dataverse extension enabled' } else { 'ALM4Dataverse extension disabled' })
                })

                Show-BranchEnvironmentMappingTable -BranchMappings @($wizardState.BranchStates | ForEach-Object {
                    [pscustomobject]@{
                        BranchName   = $_.BranchName
                        Environments = @($_.DeploymentEnvironments)
                    }
                })
                Show-EnvironmentConfigurationTable -EnvironmentConfigurations $allConfiguredEnvironments
                Confirm-SetupReviewAction
            }
        }
    )

    return [pscustomobject]@{
        BranchStates         = @($wizardState.BranchStates)
        SolutionData         = $wizardState.SolutionData
        SolutionSourceBranch = $wizardState.SolutionSourceBranch
        BuildValidationEnabled = [bool]$wizardState.BuildValidationEnabled
        BuildValidationEnvironmentConfiguration = $wizardState.BuildValidationEnvironmentConfiguration
    }
}

$azDoSetupResult = Invoke-AzDoBranchAwareSetup `
    -MainRepoWorkingRoot $mainRepoWorkingRoot `
    -MainRepo $mainRepo `
    -SelectedProject $selectedProject `
    -OrganizationId $orgId `
    -OrganizationName $orgName `
    -TenantId $adoAuthResult.TenantId `
    -DefaultBranch $script:mainRepoBranch `
    -SharedRepositoryName $sharedRepoName `
    -UseAlm4DataverseExtension $script:useAlm4DataverseExtension `
    -ALM4DataverseRef $ALM4DataverseRef

$branchStates = @($azDoSetupResult.BranchStates)
$solutionData = $azDoSetupResult.SolutionData
$solutionSourceBranch = $azDoSetupResult.SolutionSourceBranch
$buildValidationEnabled = [bool](Get-OptionalObjectPropertyValue -InputObject $azDoSetupResult -PropertyName 'BuildValidationEnabled')
$buildValidationEnvironmentConfiguration = Get-OptionalObjectPropertyValue -InputObject $azDoSetupResult -PropertyName 'BuildValidationEnvironmentConfiguration'
$solutions = if ($solutionData) { @($solutionData.Solutions) } else { @() }
$allConfiguredEnvironments = @()
foreach ($branchState in @($branchStates)) {
    if ($branchState.DevEnvironmentConfiguration) {
        $allConfiguredEnvironments += $branchState.DevEnvironmentConfiguration
    }
    $allConfiguredEnvironments += @($branchState.DeploymentEnvironments)
}

$copyRoot = $null
$sharedRepoClone = $null
if ($PSScriptRoot) {
    $copyRoot = Join-Path $PSScriptRoot 'copy-to-your-repo'
}
else {
    $sharedRepoClone = Join-Path $env:TEMP ("ALM4Dataverse-SharedRepo-" + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $sharedRepoClone -Force | Out-Null

    Invoke-WithErrorHandling -OperationName 'Cloning shared repository templates' -StatusMessage 'Cloning the shared repository to get template files...' -CaptureOutputInPanel -ScriptBlock {
        & git -c "http.extraheader=AUTHORIZATION: bearer $azDevOpsAccessToken" clone $repo.remoteUrl $sharedRepoClone
        if ($LASTEXITCODE -ne 0) {
            throw "Git clone of shared repository failed with exit code $LASTEXITCODE"
        }
    } | Out-Null

    $copyRoot = Join-Path $sharedRepoClone 'copy-to-your-repo'
}

try {
    foreach ($branchState in @($branchStates)) {
        $publishResult = Invoke-WithErrorHandling -OperationName "Publishing repository changes for branch '$($branchState.BranchName)'" -StatusMessage "Publishing repository changes for branch '$($branchState.BranchName)'..." -CaptureOutputInPanel -ScriptBlock {
            Publish-AzDoBranchSetupChanges `
                -RepoRoot $mainRepoWorkingRoot `
                -ConfiguredBranch $branchState.BranchName `
                -PublishPlan $branchState.PublishPlan `
                -DefaultBranch $script:mainRepoBranch `
                -AccessToken $azDevOpsAccessToken `
                -Repository $mainRepo `
                -CopyRoot $copyRoot `
                -SharedRepositoryName $sharedRepoName `
                -UseAlm4DataverseExtension $script:useAlm4DataverseExtension `
                -Solutions $(if ($solutionData) { @($solutions) } else { $null }) `
                -DeploymentEnvironments @($branchState.DeploymentEnvironments) `
                -BuildValidationEnabled $buildValidationEnabled `
                -BuildValidationEnvironmentName $(if ($buildValidationEnvironmentConfiguration) { [string]$buildValidationEnvironmentConfiguration.ShortName } else { '' })
        }

        $repoPublishResults += $publishResult
    }
}
finally {
    if ($sharedRepoClone -and (Test-Path -LiteralPath $sharedRepoClone)) {
        try { Remove-Item -LiteralPath $sharedRepoClone -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

$script:yamlFiles = @(
    'pipelines/BUILD.yml',
    'pipelines/EXPORT.yml',
    'pipelines/IMPORT.yml'
)
$script:yamlFiles += @($branchStates | Where-Object { @($_.DeploymentEnvironments).Count -gt 0 } | ForEach-Object { "pipelines/DEPLOY-$($_.BranchName).yml" })

Write-Section `
    -Message 'Ensuring Build Service has Contribute on main repo'
Invoke-WithErrorHandling -OperationName 'Setting Up Build Service Permissions' -StatusMessage 'Granting build service permissions for the main repository...' -CaptureOutputInPanel -ScriptBlock {
    Ensure-AzDoBuildServiceHasContributeOnRepo -Organization $orgName -ProjectName $selectedProject.Name -ProjectId $selectedProject.Id -RepositoryId $mainRepo.Id
} | Out-Null

Invoke-WithErrorHandling -OperationName 'Creating Pipeline Definitions' -StatusMessage 'Creating Azure DevOps pipeline definitions...' -CaptureOutputInPanel -ScriptBlock {
    Ensure-AzDoPipelinesForMainRepo -Organization $orgName -Project $selectedProject.Name -Repository $mainRepo -YamlFiles $script:yamlFiles -FolderPath "\$($mainRepo.Name)"
} | Out-Null

Write-Section `
    -Message 'Authorizing pipelines for repositories'
Invoke-WithErrorHandling -OperationName 'Authorizing Pipelines for Repositories' -AllowSkip -StatusMessage 'Authorizing pipelines to access the required repositories...' -CaptureOutputInPanel -ScriptBlock {
    $pipelineNames = @($script:yamlFiles | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) } | Select-Object -Unique)
    $allPipelines = Get-VSTeamBuildDefinition -ProjectName $selectedProject.Name
    $pipelineFolder = "\$($mainRepo.Name)"

    foreach ($name in $pipelineNames) {
        $pipeline = $allPipelines | Where-Object { $_.name -eq $name -and $_.path -eq $pipelineFolder } | Select-Object -First 1
        if ($pipeline) {
            $mainRepoResourceId = "$($selectedProject.Id).$($mainRepo.Id)"
            Ensure-AzDoPipelinePermission -Organization $orgName -Project $selectedProject.Name -ResourceType 'repository' -ResourceId $mainRepoResourceId -PipelineId $pipeline.id

            $sharedRepoResourceId = "$($selectedProject.Id).$($repo.Id)"
            Ensure-AzDoPipelinePermission -Organization $orgName -Project $selectedProject.Name -ResourceType 'repository' -ResourceId $sharedRepoResourceId -PipelineId $pipeline.id
        }
    }
} | Out-Null

$pipelineFolder = "\$($mainRepo.Name)"
$allPipelines = Get-VSTeamBuildDefinition -ProjectName $selectedProject.Name
$buildPipeline = $allPipelines | Where-Object { $_.name -eq 'BUILD' -and $_.path -eq $pipelineFolder } | Select-Object -First 1
$exportPipeline = $allPipelines | Where-Object { $_.name -eq 'EXPORT' -and $_.path -eq $pipelineFolder } | Select-Object -First 1
$deployPipelinesByBranch = @{}
foreach ($branchState in @($branchStates)) {
    $deployPipelineName = "DEPLOY-$($branchState.BranchName)"
    $deployPipeline = $allPipelines | Where-Object { $_.name -eq $deployPipelineName -and $_.path -eq $pipelineFolder } | Select-Object -First 1
    if ($deployPipeline) {
        $deployPipelinesByBranch[$branchState.BranchName] = $deployPipeline
    }
    elseif (@($branchState.DeploymentEnvironments).Count -gt 0) {
        Write-Warning "$deployPipelineName pipeline not found. Skipping some deployment authorizations for branch '$($branchState.BranchName)'."
    }
}

if (-not $exportPipeline) { Write-Warning 'EXPORT pipeline not found. Skipping some DEV authorizations.' }
if ($buildValidationEnabled -and -not $buildPipeline) { Write-Warning 'BUILD pipeline not found. Skipping some global BUILD validation authorizations.' }

Write-Section `
    -Message 'Configure DEV environments'

$devBranchStates = @($branchStates | Where-Object { $_.DevEnvironmentConfiguration })
if ($devBranchStates.Count -eq 0) {
    [Spectre.Console.AnsiConsole]::MarkupLine('[yellow]No DEV environment configuration was captured in the wizard, so this step will be skipped.[/]')
}
else {
    foreach ($branchState in $devBranchStates) {
        $deployPipeline = $null
        if ($deployPipelinesByBranch.ContainsKey($branchState.BranchName)) {
            $deployPipeline = $deployPipelinesByBranch[$branchState.BranchName]
        }

        Invoke-WithErrorHandling -OperationName "Applying DEV environment configuration for branch '$($branchState.BranchName)'" -AllowSkip -ScriptBlock {
            Apply-AzDoEnvironmentConfiguration `
                -EnvironmentConfiguration $branchState.DevEnvironmentConfiguration `
                -OrganizationName $orgName `
                -ProjectName $selectedProject.Name `
                -ProjectId $selectedProject.Id `
                -ExportPipeline $exportPipeline `
                -DeployPipeline $deployPipeline `
                -UseAlm4DataverseExtension $script:useAlm4DataverseExtension
        } -StatusMessage "Applying DEV environment configuration for branch '$($branchState.BranchName)'..." -CaptureOutputInPanel | Out-Null
    }
}

Write-Section `
    -Message 'Configure global BUILD validation environment'

if (-not $buildValidationEnabled -or -not $buildValidationEnvironmentConfiguration) {
    [Spectre.Console.AnsiConsole]::MarkupLine('[yellow]Global BUILD validation is disabled, so BUILD environment configuration will be skipped.[/]')
}
elseif (-not $buildPipeline) {
    [Spectre.Console.AnsiConsole]::MarkupLine('[yellow]BUILD pipeline was not found, so BUILD environment configuration could not be applied.[/]')
}
else {
    Invoke-WithErrorHandling -OperationName 'Applying global BUILD validation environment configuration' -AllowSkip -ScriptBlock {
        Apply-AzDoEnvironmentConfiguration `
            -EnvironmentConfiguration $buildValidationEnvironmentConfiguration `
            -OrganizationName $orgName `
            -ProjectName $selectedProject.Name `
            -ProjectId $selectedProject.Id `
            -ExportPipeline $null `
            -DeployPipeline $buildPipeline `
            -UseAlm4DataverseExtension $script:useAlm4DataverseExtension
    } -StatusMessage 'Applying global BUILD validation environment configuration...' -CaptureOutputInPanel | Out-Null
}

Write-Section `
    -Message 'Configure deployment environments'

$deploymentBranchStates = @($branchStates | Where-Object { @($_.DeploymentEnvironments).Count -gt 0 })
if ($deploymentBranchStates.Count -eq 0) {
    [Spectre.Console.AnsiConsole]::MarkupLine('[yellow]No deployment environments were configured in the wizard, so this step will be skipped.[/]')
}
else {
    foreach ($branchState in $deploymentBranchStates) {
        $deployPipeline = $null
        if ($deployPipelinesByBranch.ContainsKey($branchState.BranchName)) {
            $deployPipeline = $deployPipelinesByBranch[$branchState.BranchName]
        }

        foreach ($deploymentEnvironment in @($branchState.DeploymentEnvironments)) {
            Write-Section `
                -Message "Applying environment configuration for '$($deploymentEnvironment.ShortName)' on branch '$($branchState.BranchName)'"
            Invoke-WithErrorHandling -OperationName "Applying environment configuration for '$($deploymentEnvironment.ShortName)' on branch '$($branchState.BranchName)'" -AllowSkip -ScriptBlock {
                Apply-AzDoEnvironmentConfiguration `
                    -EnvironmentConfiguration $deploymentEnvironment `
                    -OrganizationName $orgName `
                    -ProjectName $selectedProject.Name `
                    -ProjectId $selectedProject.Id `
                    -ExportPipeline $exportPipeline `
                    -DeployPipeline $deployPipeline `
                    -UseAlm4DataverseExtension $script:useAlm4DataverseExtension
            } -StatusMessage "Applying configuration for environment '$($deploymentEnvironment.ShortName)' on branch '$($branchState.BranchName)'..." -CaptureOutputInPanel | Out-Null
        }
    }
}

#endregion

if ($mainRepoWorkingRoot -and (Test-Path $mainRepoWorkingRoot)) {
    try { Remove-Item -LiteralPath $mainRepoWorkingRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
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
