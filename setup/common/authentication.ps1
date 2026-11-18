function Get-SetupMsalAssemblyPath {
    <#
    .SYNOPSIS
        Resolves the Dataverse module's runtime-compatible MSAL assemblies.
    .DESCRIPTION
        Returns Core and optional Broker paths from one module target-framework
        directory. Core editions prefer the active .NET runtime target and fall
        back to older packaged targets; Desktop uses .NET Framework assemblies.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ModuleBase
    )

    if ($PSVersionTable.PSEdition -eq 'Core') {
        $runtimeMajor = [System.Environment]::Version.Major
        $runtimeTargetFramework = if ($runtimeMajor -ge 10) {
            "net$runtimeMajor.0"
        }
        elseif ($runtimeMajor -eq 9) {
            'net9.0'
        }
        else {
            'net8.0'
        }

        $targetFrameworks = @($runtimeTargetFramework, 'net8.0', 'netcoreapp3.1') | Select-Object -Unique
    }
    else {
        $targetFrameworks = @('net462')
    }

    foreach ($targetFramework in $targetFrameworks) {
        $directory = Join-Path (Join-Path $ModuleBase 'cmdlets') $targetFramework
        $corePath = Join-Path $directory 'Microsoft.Identity.Client.dll'
        if (Test-Path -LiteralPath $corePath -PathType Leaf) {
            $brokerPath = Join-Path $directory 'Microsoft.Identity.Client.Broker.dll'
            if (-not (Test-Path -LiteralPath $brokerPath -PathType Leaf)) {
                $brokerPath = $null
            }

            return [pscustomobject]@{
                CorePath   = $corePath
                BrokerPath = $brokerPath
            }
        }
    }

    $allCoreAssemblies = Get-ChildItem -LiteralPath $ModuleBase -Recurse -File -Filter 'Microsoft.Identity.Client.dll'
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $foundCoreAssembly = $allCoreAssemblies |
            Where-Object { $_.FullName -match 'netcore|netstandard|net\d\.\d' } |
            Sort-Object FullName |
            Select-Object -First 1
    }
    else {
        $foundCoreAssembly = $allCoreAssemblies |
            Where-Object { $_.FullName -match 'net4' } |
            Sort-Object FullName |
            Select-Object -First 1
    }

    if ($foundCoreAssembly) {
        $brokerPath = Join-Path $foundCoreAssembly.DirectoryName 'Microsoft.Identity.Client.Broker.dll'
        if (-not (Test-Path -LiteralPath $brokerPath -PathType Leaf)) {
            $brokerPath = $null
        }

        return [pscustomobject]@{
            CorePath   = $foundCoreAssembly.FullName
            BrokerPath = $brokerPath
        }
    }

    return $null
}

function Get-SetupDefaultContextAssembly {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name
    )

    $assemblies = if ($PSVersionTable.PSEdition -eq 'Core') {
        [System.Runtime.Loader.AssemblyLoadContext]::Default.Assemblies
    }
    else {
        [System.AppDomain]::CurrentDomain.GetAssemblies()
    }

    return $assemblies |
        Where-Object { $_.GetName().Name -eq $Name } |
        Select-Object -First 1
}

function Get-SetupAssemblyVersion {
    param(
        [Parameter(Mandatory)][string]$Path
    )

    return [System.Reflection.AssemblyName]::GetAssemblyName($Path).Version
}

function Initialize-SetupMsalAssembly {
    <#
    .SYNOPSIS
        Loads MSAL Core and Broker together for setup authentication.
    .DESCRIPTION
        Loads matching assemblies into the PowerShell default load context so
        setup's token helper and the Dataverse binary cmdlets share type identity.
        A preloaded assembly with an incompatible version throws. If module assets
        are unavailable, MSAL Core is resolved by its assembly name.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][string]$ModuleBase
    )

    $assemblyPaths = if (-not [string]::IsNullOrWhiteSpace($ModuleBase)) {
        Get-SetupMsalAssemblyPath -ModuleBase $ModuleBase
    }
    else {
        $null
    }

    if (-not $assemblyPaths) {
        [void][System.Reflection.Assembly]::LoadWithPartialName('Microsoft.Identity.Client')
        return
    }

    $expectedCoreVersion = Get-SetupAssemblyVersion -Path $assemblyPaths.CorePath
    if ($assemblyPaths.BrokerPath) {
        $expectedBrokerVersion = Get-SetupAssemblyVersion -Path $assemblyPaths.BrokerPath
        if ($expectedBrokerVersion -ne $expectedCoreVersion) {
            throw "The Dataverse module's MSAL Core ($expectedCoreVersion) and Broker ($expectedBrokerVersion) assemblies do not match."
        }
    }

    $loadedCoreAssembly = Get-SetupDefaultContextAssembly -Name 'Microsoft.Identity.Client'
    if ($loadedCoreAssembly -and $loadedCoreAssembly.GetName().Version -ne $expectedCoreVersion) {
        throw "An incompatible Microsoft.Identity.Client version '$($loadedCoreAssembly.GetName().Version)' is already loaded. The Dataverse module requires '$expectedCoreVersion'; restart PowerShell to load a consistent MSAL pair."
    }

    $loadedBrokerAssembly = Get-SetupDefaultContextAssembly -Name 'Microsoft.Identity.Client.Broker'
    if ($loadedBrokerAssembly -and $loadedBrokerAssembly.GetName().Version -ne $expectedCoreVersion) {
        throw "An incompatible Microsoft.Identity.Client.Broker version '$($loadedBrokerAssembly.GetName().Version)' is already loaded. The Dataverse module requires '$expectedCoreVersion'; restart PowerShell to load a consistent MSAL pair."
    }

    # The binary cmdlets run in the default context; keep Core and Broker together there.
    if (-not $loadedCoreAssembly) {
        Add-Type -Path $assemblyPaths.CorePath -ErrorAction Stop | Out-Null
    }
    if ($assemblyPaths.BrokerPath -and -not $loadedBrokerAssembly) {
        Add-Type -Path $assemblyPaths.BrokerPath -ErrorAction Stop | Out-Null
    }
}

function Get-SetupHostPlatform {
    <#
    .SYNOPSIS
        Identifies the host operating system for sign-in mode selection.
    .DESCRIPTION
        Returns Windows, macOS, Linux or Unknown. Windows PowerShell predates the
        $IsWindows family, so its desktop edition is reported as Windows first;
        the automatic variables are only read on PowerShell Core.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        return 'Windows'
    }
    if ($IsWindows) {
        return 'Windows'
    }
    if ($IsMacOS) {
        return 'macOS'
    }
    if ($IsLinux) {
        return 'Linux'
    }

    return 'Unknown'
}

function Get-SetupAuthenticationMode {
    <#
    .SYNOPSIS
        Chooses browser or device-code sign-in for setup MSAL requests.
    .DESCRIPTION
        MSAL opens the system browser on Windows and macOS. On Linux it starts a
        launcher found on PATH and does not check that a browser appeared, so a
        launcher alone cannot prove that sign-in is possible. Browser sign-in is
        selected only for a graphical session, or for WSL where wslview opens the
        Windows browser. Containers, SSH sessions and CI use device code, where
        the user enters a code in a browser on any device and the token arrives
        over outbound polling instead of a local redirect.
    .OUTPUTS
        System.String
        Interactive or DeviceCode.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $platform = Get-SetupHostPlatform

    if ($platform -in @('Windows', 'macOS')) {
        return 'Interactive'
    }

    if ($platform -ne 'Linux') {
        return 'DeviceCode'
    }

    $hasGraphicalSession =
        -not [string]::IsNullOrWhiteSpace($env:DISPLAY) -or
        -not [string]::IsNullOrWhiteSpace($env:WAYLAND_DISPLAY)

    # Mirrors the launchers MSAL probes before it starts the first one found.
    foreach ($launcher in @('xdg-open', 'gnome-open', 'kfmclient', 'microsoft-edge', 'wslview')) {
        if (-not (Get-Command -Name $launcher -CommandType Application -ErrorAction SilentlyContinue)) {
            continue
        }

        if ($hasGraphicalSession -or $launcher -eq 'wslview') {
            return 'Interactive'
        }
    }

    return 'DeviceCode'
}

function Test-SetupBrowserLaunchFailure {
    <#
    .SYNOPSIS
        Reports whether an interactive MSAL failure means no browser could start.
    .DESCRIPTION
        MSAL raises linux_xdg_open_failed when a launcher exists but cannot open
        the page. PowerShell can wrap the MSAL exception, and older releases only
        provide the message, so the complete exception chain is inspected before
        deciding whether a device-code retry is safe.
    .PARAMETER ErrorRecord
        Error raised while executing the interactive MSAL request.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]$ErrorRecord
    )

    $exception = $ErrorRecord.Exception
    while ($exception) {
        if ($exception.PSObject.Properties['ErrorCode'] -and $exception.ErrorCode -eq 'linux_xdg_open_failed') {
            return $true
        }
        if ($exception.Message -match 'Unable to open a web page using xdg-open|linux_xdg_open_failed') {
            return $true
        }

        $exception = $exception.InnerException
    }

    return $false
}

function Invoke-SetupDeviceCodeAuthentication {
    <#
    .SYNOPSIS
        Acquires a setup token with the OAuth device-code flow.
    .DESCRIPTION
        MSAL prints the verification URL and user code through the callback while
        setup waits for the browser session to complete. MSAL invokes that callback
        on a thread without a PowerShell runspace, where a ScriptBlock delegate
        fails, so the callback is compiled to write the message with Console.WriteLine
        and return a completed task.
    .PARAMETER Application
        MSAL public client used for the request.
    .PARAMETER Scopes
        Resource scopes for the requested token.
    .OUTPUTS
        Microsoft.Identity.Client.AuthenticationResult
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Application,
        [Parameter(Mandatory)][string[]]$Scopes
    )

    $deviceCodeParameter = [System.Linq.Expressions.Expression]::Parameter([Microsoft.Identity.Client.DeviceCodeResult], 'deviceCodeResult')
    $deviceCodeMessage = [System.Linq.Expressions.Expression]::Property($deviceCodeParameter, 'Message')
    $writeLineMethod = [System.Console].GetMethod('WriteLine', [Type[]]@([string]))
    $deviceCodeBody = [System.Linq.Expressions.Expression]::Block(
        [System.Linq.Expressions.Expression]::Call($writeLineMethod, [System.Linq.Expressions.Expression]::Constant('')),
        [System.Linq.Expressions.Expression]::Call($writeLineMethod, $deviceCodeMessage),
        [System.Linq.Expressions.Expression]::Call($writeLineMethod, [System.Linq.Expressions.Expression]::Constant('')),
        [System.Linq.Expressions.Expression]::Constant([System.Threading.Tasks.Task]::CompletedTask)
    )
    $deviceCodeLambda = [System.Linq.Expressions.Expression]::Lambda(
        [System.Func[Microsoft.Identity.Client.DeviceCodeResult, System.Threading.Tasks.Task]],
        $deviceCodeBody,
        $deviceCodeParameter
    )
    $deviceCodeCallback = [System.Func[Microsoft.Identity.Client.DeviceCodeResult, System.Threading.Tasks.Task]]($deviceCodeLambda.Compile())

    return $Application.AcquireTokenWithDeviceCode($Scopes, $deviceCodeCallback).ExecuteAsync().GetAwaiter().GetResult()
}

function Get-AuthToken {
    <#
    .SYNOPSIS
        Acquires an MSAL user authentication result, or lists cached usernames.
    .PARAMETER ResourceUrl
        Resource authority used to form its /.default scope after trimming slashes.
    .PARAMETER TenantId
        Authority tenant for initial client construction; blank uses common.
    .PARAMETER ForceInteractive
        Skips silent acquisition and requests account selection in the interactive flow.
    .PARAMETER PreferredUsername
        Case-insensitive cached-account preference and interactive login hint, not
        an enforced identity. Missing matches fall back to the first cached account.
    .PARAMETER ListAccountsOnly
        Returns distinct nonblank cached usernames instead of an authentication result;
        still loads MSAL, constructs/reuses the client and reads the disk cache.
    .DESCRIPTION
        Loads matching MSAL Core and optional Broker assemblies into the PowerShell
        default load context from the loaded Dataverse module. Script-scoped MsalApp
        is reused: ClientId and TenantId only affect its first construction.
        Loads/saves serialized MSAL V3 bytes under local app data without additional
        encryption here; cache read/write failures warn. Silent failure falls back
        to browser or device-code sign-in as the host allows, and a browser that
        cannot open retries with device code; other sign-in errors throw. The
        normal result is MSAL AuthenticationResult, not just its access-token text.
    #>
    param(
        [Parameter(Mandatory)][string]$ResourceUrl,
        [Parameter()][string]$TenantId,
        [Parameter()][string]$ClientId = '1950a258-227b-4e31-a9cf-717495945fc2',
        [Parameter()][switch]$ForceInteractive,
        [Parameter()][string]$PreferredUsername,
        [Parameter()][switch]$ListAccountsOnly
    )

    $module = Get-Module -Name 'Rnwood.Dataverse.Data.PowerShell' | Select-Object -First 1
    if ($module) {
        Initialize-SetupMsalAssembly -ModuleBase $module.ModuleBase
    }
    else {
        Initialize-SetupMsalAssembly
    }

    if (-not ('Microsoft.Identity.Client.PublicClientApplicationBuilder' -as [type])) {
        throw 'Microsoft.Identity.Client could not be loaded for setup authentication.'
    }

    $ResourceUrl = $ResourceUrl.TrimEnd('/')
    $scopes = [string[]]@("$ResourceUrl/.default")

    $app = $null
    try {
        $app = Get-Variable -Name "MsalApp" -Scope Script -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Value
    }
    catch {
        $app = $null
    }

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
        Write-Verbose 'Silent token acquisition failed; retrying interactively.'
    }

    if (-not $authResult) {
        try {
            if ((Get-SetupAuthenticationMode) -eq 'DeviceCode') {
                Write-Host 'No browser is available on this host; setup will show a device code for sign-in.' -ForegroundColor Yellow
                $authResult = Invoke-SetupDeviceCodeAuthentication -Application $app -Scopes $scopes
            }
            else {
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
                    if (-not (Test-SetupBrowserLaunchFailure -ErrorRecord $_)) {
                        throw
                    }

                    Write-Warning 'The browser could not be opened; retrying with device-code sign-in.'
                    $authResult = Invoke-SetupDeviceCodeAuthentication -Application $app -Scopes $scopes
                }
            }
        }
        catch {
            Write-Error "Failed to acquire a sign-in token: $_"
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

function Get-SetupAccessToken {
    <#
    .SYNOPSIS
        Acquires an access token on the setup runspace for a Dataverse resource.
    .DESCRIPTION
        Normalizes ResourceUrl to its HTTP(S) authority and validates that MSAL
        returned a token. Call before invoking Dataverse cmdlets whose token
        callbacks run on worker tasks, so interactive authentication and assembly
        initialization happen on the setup runspace.
    .PARAMETER ResourceUrl
        Absolute HTTP(S) resource URL for which to acquire the token.
    .PARAMETER TenantId
        Optional tenant passed to the setup MSAL client.
    .OUTPUTS
        System.String
        The access token. Do not write it to logs or the terminal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ResourceUrl,
        [Parameter()][string]$TenantId
    )

    $resourceValue = $ResourceUrl.Trim()
    $resourceUri = $null
    if (
        -not [System.Uri]::TryCreate($resourceValue, [System.UriKind]::Absolute, [ref]$resourceUri) -or
        $resourceUri.Scheme -notin @('http', 'https')
    ) {
        throw 'A valid HTTP(S) resource URL is required for Dataverse authentication.'
    }

    $authenticationParameters = @{
        ResourceUrl = $resourceUri.GetLeftPart([System.UriPartial]::Authority)
    }
    if ($PSBoundParameters.ContainsKey('TenantId')) {
        $authenticationParameters.TenantId = $TenantId
    }

    $authentication = Get-AuthToken @authenticationParameters
    if (-not $authentication -or [string]::IsNullOrWhiteSpace($authentication.AccessToken)) {
        throw 'Authentication did not return an access token for the Dataverse resource.'
    }

    return [string]$authentication.AccessToken
}

function Get-SetupAccessTokenCallback {
    <#
    .SYNOPSIS
        Returns a worker-safe Dataverse access-token callback.
    .DESCRIPTION
        Acquires the token on the setup runspace and returns a closure that only
        returns that token. The callback validates requested resources but does
        not perform MSAL calls or refresh the token on the cmdlet's worker task.
    .PARAMETER ResourceUrl
        Absolute HTTP(S) URL for the Dataverse resource.
    .PARAMETER TenantId
        Optional tenant passed to the setup MSAL client.
    .OUTPUTS
        System.Management.Automation.ScriptBlock
        A callback returning the captured access token for the requested resource.
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param(
        [Parameter(Mandatory)][string]$ResourceUrl,
        [Parameter()][string]$TenantId
    )

    $authenticationParameters = @{ ResourceUrl = $ResourceUrl }
    if ($PSBoundParameters.ContainsKey('TenantId')) {
        $authenticationParameters.TenantId = $TenantId
    }

    $accessToken = Get-SetupAccessToken @authenticationParameters
    $expectedResourceAuthority = ([System.Uri]$ResourceUrl.Trim()).GetLeftPart([System.UriPartial]::Authority)
    $accessTokenProvider = {
        param($resource)
        if (-not [string]::IsNullOrWhiteSpace([string]$resource)) {
            $resourceUri = $null
            if (
                -not [System.Uri]::TryCreate([string]$resource, [System.UriKind]::Absolute, [ref]$resourceUri) -or
                $resourceUri.Scheme -notin @('http', 'https')
            ) {
                throw 'Dataverse authentication requested an invalid resource URL.'
            }

            $resourceAuthority = $resourceUri.GetLeftPart([System.UriPartial]::Authority)
            if ($resourceAuthority -ine $expectedResourceAuthority) {
                throw 'Dataverse authentication callback requested an unexpected resource.'
            }
        }

        return $accessToken
    }.GetNewClosure()

    return $accessTokenProvider
}

function New-EntraIdApplicationSecret {
    <#
    .SYNOPSIS
        Requests a new password credential on an Entra application object.
    .PARAMETER ApplicationObjectId
        Graph application object ID, not the client/application ID.
    .DESCRIPTION
        ShouldProcess precedes authentication and the Graph write; rejection emits
        nothing. Returns the response's plaintext secretText; existing credentials
        are not removed. Graph/authentication failures propagate. This helper-level
        guard does not make an entire setup wizard a dry run.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$ApplicationObjectId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter()][string]$DisplayName = 'ALM4Dataverse Setup'
    )

    if (-not $PSCmdlet.ShouldProcess($ApplicationObjectId, 'Create Entra application secret')) { return }

    $graphToken = Get-AuthToken -ResourceUrl 'https://graph.microsoft.com' -TenantId $TenantId
    $headers = @{
        Authorization  = "Bearer $($graphToken.AccessToken)"
        'Content-Type' = 'application/json'
    }

    $secretBody = @{
        passwordCredential = @{
            displayName = $DisplayName
        }
    }

    $secretUri = "https://graph.microsoft.com/v1.0/applications/$ApplicationObjectId/addPassword"
    $secretResponse = Invoke-RestMethod -Uri $secretUri -Headers $headers -Method Post -Body ($secretBody | ConvertTo-Json)
    return $secretResponse.secretText
}

function Resolve-DataverseEnvironmentFriendlyName {
    # Uses the provider-defined environment catalog and normalized WebApplication
    # endpoint identity. Blank URL, no match or catalog failure returns FallbackName;
    # lookup failures are informational and never block setup.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][string]$EnvironmentUrl,
        [Parameter()][string]$FallbackName
    )

    $normalizedEnvironmentUrl = ConvertTo-NormalizedEnvironmentUrl -Url $EnvironmentUrl
    if ([string]::IsNullOrWhiteSpace($normalizedEnvironmentUrl)) {
        return $FallbackName
    }

    try {
        $matchingEnvironment = Get-DataverseEnvironmentCatalog | Where-Object {
            (ConvertTo-NormalizedEnvironmentUrl -Url $_.Endpoints['WebApplication']) -eq $normalizedEnvironmentUrl
        } | Select-Object -First 1

        if ($matchingEnvironment -and -not [string]::IsNullOrWhiteSpace($matchingEnvironment.FriendlyName)) {
            return [string]$matchingEnvironment.FriendlyName
        }
    }
    catch {
        Write-Host "Could not resolve Dataverse environment name for '$normalizedEnvironmentUrl'. Falling back to '$FallbackName'." -ForegroundColor DarkGray
    }

    return $FallbackName
}

function Resolve-EntraIdApplicationByAppId {
    <#
    .SYNOPSIS
        Resolves an application/client ID to the first matching Graph application.
    .DESCRIPTION
        Blank tenant/application IDs return null. Script cache keys combine both IDs;
        successful results, missing results and REST failures (warning plus null) are
        cached for the session. Authentication occurs outside the REST catch and
        therefore propagates rather than becoming a cached miss. Returned fields
        are id, appId and displayName; no object is created.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][string]$ApplicationId,
        [Parameter()][string]$TenantId
    )

    if ([string]::IsNullOrWhiteSpace($ApplicationId) -or [string]::IsNullOrWhiteSpace($TenantId)) {
        return $null
    }

    if (-not (Get-Variable -Name 'entraApplicationCache' -Scope Script -ErrorAction SilentlyContinue)) {
        $script:entraApplicationCache = @{}
    }

    $cacheKey = "$TenantId|$ApplicationId"
    if ($script:entraApplicationCache.ContainsKey($cacheKey)) {
        return $script:entraApplicationCache[$cacheKey]
    }

    $graphToken = Get-AuthToken -ResourceUrl 'https://graph.microsoft.com' -TenantId $TenantId
    $headers = @{ Authorization = "Bearer $($graphToken.AccessToken)" }
    $uri = "https://graph.microsoft.com/v1.0/applications?`$filter=appId eq '$ApplicationId'&`$select=id,appId,displayName"

    try {
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
        $application = $response.value | Select-Object -First 1
        $script:entraApplicationCache[$cacheKey] = $application
        return $application
    }
    catch {
        Write-Warning "Failed to resolve App Registration '$ApplicationId' from Entra ID: $($_.Exception.Message)"
        $script:entraApplicationCache[$cacheKey] = $null
        return $null
    }
}
