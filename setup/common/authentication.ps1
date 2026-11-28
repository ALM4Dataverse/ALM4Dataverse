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
                    Publish-SetupWebBusy -Message 'Waiting for Azure sign-in in your browser...'
                    $interactiveBuilder = $app.AcquireTokenInteractive($scopes)

                    if ($ForceInteractive) {
                        $interactiveBuilder = $interactiveBuilder.WithPrompt([Microsoft.Identity.Client.Prompt]::SelectAccount)
                    }

                    if (-not [string]::IsNullOrWhiteSpace($PreferredUsername)) {
                        $interactiveBuilder = $interactiveBuilder.WithLoginHint($PreferredUsername)
                    }

                    $authResult = $interactiveBuilder.ExecuteAsync().GetAwaiter().GetResult()
                    Publish-SetupWebBusy -Message 'Completing Azure sign-in...'
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
        are not removed. Authentication failures propagate unchanged, while a Graph
        rejection adds ownership or directory-role remediation guidance. This
        helper-level guard does not make an entire setup wizard a dry run.
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
    try {
        $secretResponse = Invoke-RestMethod -Uri $secretUri -Headers $headers -Method Post -Body ($secretBody | ConvertTo-Json)
        return $secretResponse.secretText
    }
    catch {
        throw "Failed to create a client secret for Entra application '$ApplicationObjectId'. The signed-in account must own the app registration or have an Entra application administrator role. $($_.Exception.Message)"
    }
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

function Test-EntraIdPermissionDenied {
    <#
    .SYNOPSIS
        Returns whether a Microsoft Graph error represents an authorization denial.
    .DESCRIPTION
        Recognizes HTTP 401/403 responses and common permission-denied wording. Used by
        capability checks to distinguish a definite denial from a transient failure so
        setup hides only actions the account is known not to be allowed to use.
    .PARAMETER ErrorRecord
        Error caught from an Invoke-RestMethod call.
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $response = Get-OptionalObjectPropertyValue -InputObject $ErrorRecord.Exception -PropertyName 'Response'
    $statusCode = Get-OptionalObjectPropertyValue -InputObject $response -PropertyName 'StatusCode'
    if ($null -ne $statusCode) {
        return ([int]$statusCode -in @(401, 403))
    }

    return ([string]$ErrorRecord.Exception.Message -match '\b(401|403|Forbidden|Unauthorized|insufficient privileges)\b')
}

function Get-EntraIdApplicationManagementState {
    <#
    .SYNOPSIS
        Detects which Entra app-registration actions the signed-in user can perform.
    .DESCRIPTION
        Combines the tenant's 'Users can register applications' policy, the user's
        transitive directory roles and the signed-in user object ID. A role wins over
        the tenant policy. CanCreateApplications is false only when the role list and
        policy were both read and neither grants creation; CanManageAllApplications is
        false only when the role list was read without a known app-administration role.
        CanReadApplications reports whether the signed-in account can list applications
        for the search action. Null means the answer could not be determined, so callers
        must keep the action available rather than block a permitted user after a
        transient Graph failure. Unrecognized or custom directory roles also leave a
        capability unknown rather than inferring a denial. Results are cached per tenant
        for the setup session.
        This is an advisory directory-authorization pre-check, not a guarantee that a
        later Graph write succeeds for the client application's granted scopes.
    .PARAMETER TenantId
        Tenant whose app registrations will be managed.
    .PARAMETER Force
        Ignores the session cache and reads Microsoft Graph again.
    .OUTPUTS
        System.Management.Automation.PSCustomObject with TenantId, UserObjectId,
        DirectoryRoles, CanCreateApplications, CanManageAllApplications and
        CanReadApplications.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][AllowEmptyString()][AllowNull()][string]$TenantId,
        [Parameter()][switch]$Force
    )

    $emptyState = [pscustomobject]@{
        TenantId                 = $TenantId
        UserObjectId             = $null
        DirectoryRoles           = @()
        CanCreateApplications    = $null
        CanManageAllApplications = $null
        CanReadApplications      = $null
    }

    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        return $emptyState
    }

    if (-not (Get-Variable -Name 'entraIdApplicationManagementStateCache' -Scope Script -ErrorAction SilentlyContinue)) {
        $script:entraIdApplicationManagementStateCache = @{}
    }

    $cacheKey = $TenantId.ToLowerInvariant()
    if (-not $Force -and $script:entraIdApplicationManagementStateCache.ContainsKey($cacheKey)) {
        return $script:entraIdApplicationManagementStateCache[$cacheKey]
    }

    # These template IDs are language-neutral; display names are localized and unsafe
    # for authorization decisions.
    $roleDefinitions = [ordered]@{
        '62e90394-69f5-4237-9190-012177145e10' = @{ Name = 'Global Administrator'; ManagesAllApplications = $true; CreatesApplications = $true }
        '9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3' = @{ Name = 'Application Administrator'; ManagesAllApplications = $true; CreatesApplications = $true }
        '158c047a-c907-4556-b7ef-446551a6b5f7' = @{ Name = 'Cloud Application Administrator'; ManagesAllApplications = $true; CreatesApplications = $true }
        'cf1c38e5-3621-4004-a7cb-879624dced7c' = @{ Name = 'Application Developer'; ManagesAllApplications = $false; CreatesApplications = $true }
    }

    $headers = $null
    try {
        $graphToken = Get-AuthToken -ResourceUrl 'https://graph.microsoft.com' -TenantId $TenantId
        if (-not $graphToken -or [string]::IsNullOrWhiteSpace([string]$graphToken.AccessToken)) {
            throw 'No Microsoft Graph access token was returned.'
        }
        $headers = @{ Authorization = "Bearer $($graphToken.AccessToken)" }
    }
    catch {
        Write-Verbose "Could not authenticate for Entra app-registration permission detection: $($_.Exception.Message)"
        return $emptyState
    }

    $userObjectId = $null
    try {
        $me = Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/me?$select=id' -Headers $headers -Method Get
        $userObjectId = [string](Get-OptionalObjectPropertyValue -InputObject $me -PropertyName 'id')
        if ([string]::IsNullOrWhiteSpace($userObjectId)) { $userObjectId = $null }
    }
    catch {
        Write-Verbose "Could not read the signed-in Entra user: $($_.Exception.Message)"
    }

    $roleTemplateIds = @()
    $unrecognizedRoleCount = 0
    $rolesRead = $false
    try {
        $rolesResponse = Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/me/transitiveMemberOf/microsoft.graph.directoryRole?$select=displayName,roleTemplateId' -Headers $headers -Method Get
        $roleItems = @($rolesResponse.value | Where-Object { $null -ne $_ })
        $roleTemplateIds = @(
            $roleItems |
                ForEach-Object { [string](Get-OptionalObjectPropertyValue -InputObject $_ -PropertyName 'roleTemplateId') } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
        # Custom roles and built-in roles outside the known set can still grant these
        # capabilities, so they must not be treated as proof of denial.
        $unrecognizedRoleCount = @($roleItems | Where-Object {
                $templateId = [string](Get-OptionalObjectPropertyValue -InputObject $_ -PropertyName 'roleTemplateId')
                [string]::IsNullOrWhiteSpace($templateId) -or -not $roleDefinitions.Contains($templateId)
            }).Count
        $rolesRead = $true
    }
    catch {
        Write-Verbose "Could not read the signed-in user's Entra directory roles: $($_.Exception.Message)"
    }

    $allowedToCreateApps = $null
    try {
        $authorizationPolicy = Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/policies/authorizationPolicy?$select=defaultUserRolePermissions' -Headers $headers -Method Get
        $defaultUserPermissions = Get-OptionalObjectPropertyValue -InputObject $authorizationPolicy -PropertyName 'defaultUserRolePermissions'
        $allowedValue = Get-OptionalObjectPropertyValue -InputObject $defaultUserPermissions -PropertyName 'allowedToCreateApps'
        if ($null -ne $allowedValue) {
            $allowedToCreateApps = [bool]$allowedValue
        }
    }
    catch {
        Write-Verbose "Could not read the tenant's app-registration policy: $($_.Exception.Message)"
    }

    $canReadApplications = $null
    try {
        [void](Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/applications?$top=1&$select=id' -Headers $headers -Method Get)
        $canReadApplications = $true
    }
    catch {
        if (Test-EntraIdPermissionDenied -ErrorRecord $_) {
            $canReadApplications = $false
        }
        else {
            Write-Verbose "Could not check application read access: $($_.Exception.Message)"
        }
    }

    $directoryRoles = @(
        foreach ($roleTemplateId in $roleTemplateIds) {
            $definition = $roleDefinitions[[string]$roleTemplateId]
            if ($definition) { $definition.Name }
        }
    )

    $hasCreateRole = @($roleTemplateIds | Where-Object {
            $definition = $roleDefinitions[[string]$_]
            $definition -and $definition.CreatesApplications
        }).Count -gt 0
    $hasManageAllRole = @($roleTemplateIds | Where-Object {
            $definition = $roleDefinitions[[string]$_]
            $definition -and $definition.ManagesAllApplications
        }).Count -gt 0
    $hasUnrecognizedRoles = $unrecognizedRoleCount -gt 0

    $canCreateApplications = if ($hasCreateRole) {
        $true
    }
    elseif ($allowedToCreateApps -eq $true) {
        $true
    }
    elseif ($rolesRead -and -not $hasUnrecognizedRoles -and $allowedToCreateApps -eq $false) {
        $false
    }
    else {
        $null
    }

    $canManageAllApplications = if ($hasManageAllRole) {
        $true
    }
    elseif ($rolesRead -and -not $hasUnrecognizedRoles) {
        $false
    }
    else {
        $null
    }

    $result = [pscustomobject]@{
        TenantId                 = $TenantId
        UserObjectId             = $userObjectId
        DirectoryRoles           = $directoryRoles
        CanCreateApplications    = $canCreateApplications
        CanManageAllApplications = $canManageAllApplications
        CanReadApplications      = $canReadApplications
    }

    $script:entraIdApplicationManagementStateCache[$cacheKey] = $result
    return $result
}

function Test-EntraIdApplicationManagement {
    <#
    .SYNOPSIS
        Returns whether the signed-in user can change credentials on an application.
    .DESCRIPTION
        Returns true for a user whose directory role can manage every application.
        Otherwise reads the application's owners and returns true when the signed-in
        user is an owner. It returns false only when the role list and owner list were
        both read and neither grants access. Null means the application object, user
        identity, owner list or role list could not be determined. Null is not
        permission: callers keep the action available so a transient read failure does
        not block a permitted administrator. Results are cached per
        tenant and application object for the setup session. This does not evaluate the
        client application's granted Graph scopes or explicit deny assignments.
    .PARAMETER TenantId
        Tenant containing the application object.
    .PARAMETER ApplicationObjectId
        Graph application object ID, not the client/application ID.
    .PARAMETER ApplicationId
        Client application ID used to resolve ApplicationObjectId when it is blank.
    .PARAMETER State
        Previously detected Get-EntraIdApplicationManagementState result. Supplying it
        avoids repeating the tenant-level role and policy reads.
    .OUTPUTS
        System.Boolean. Null means the answer could not be determined.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][AllowEmptyString()][AllowNull()][string]$TenantId,
        [Parameter()][string]$ApplicationObjectId,
        [Parameter()][string]$ApplicationId,
        [Parameter()][object]$State
    )

    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        return $null
    }

    if ($null -eq $State) {
        $State = Get-EntraIdApplicationManagementState -TenantId $TenantId
    }
    else {
        $stateTenantId = [string](Get-OptionalObjectPropertyValue -InputObject $State -PropertyName 'TenantId')
        if (-not [string]::IsNullOrWhiteSpace($stateTenantId) -and $stateTenantId -ine $TenantId) {
            $State = Get-EntraIdApplicationManagementState -TenantId $TenantId
        }
    }

    $canManageAllApplications = Get-OptionalObjectPropertyValue -InputObject $State -PropertyName 'CanManageAllApplications'
    if ($canManageAllApplications -eq $true) {
        return $true
    }

    $userObjectId = [string](Get-OptionalObjectPropertyValue -InputObject $State -PropertyName 'UserObjectId')
    if ([string]::IsNullOrWhiteSpace($userObjectId)) {
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($ApplicationObjectId) -and -not [string]::IsNullOrWhiteSpace($ApplicationId)) {
        $application = Resolve-EntraIdApplicationByAppId -ApplicationId $ApplicationId -TenantId $TenantId
        if ($application) {
            $ApplicationObjectId = [string]$application.id
        }
    }

    if ([string]::IsNullOrWhiteSpace($ApplicationObjectId)) {
        return $null
    }

    if (-not (Get-Variable -Name 'entraIdApplicationManagementCache' -Scope Script -ErrorAction SilentlyContinue)) {
        $script:entraIdApplicationManagementCache = @{}
    }

    $cacheKey = "$($TenantId.ToLowerInvariant())|$($ApplicationObjectId.ToLowerInvariant())"
    if ($script:entraIdApplicationManagementCache.ContainsKey($cacheKey)) {
        return $script:entraIdApplicationManagementCache[$cacheKey]
    }

    $result = $null
    try {
        $graphToken = Get-AuthToken -ResourceUrl 'https://graph.microsoft.com' -TenantId $TenantId
        if (-not $graphToken -or [string]::IsNullOrWhiteSpace([string]$graphToken.AccessToken)) {
            throw 'No Microsoft Graph access token was returned.'
        }
        $headers = @{ Authorization = "Bearer $($graphToken.AccessToken)" }
        $ownersUri = "https://graph.microsoft.com/v1.0/applications/$([Uri]::EscapeDataString($ApplicationObjectId))/owners?`$select=id"
        $owners = Invoke-RestMethod -Uri $ownersUri -Headers $headers -Method Get
        $ownerObjectIds = @(
            $owners.value |
                ForEach-Object { [string](Get-OptionalObjectPropertyValue -InputObject $_ -PropertyName 'id') } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
        $result = $ownerObjectIds -contains $userObjectId
        if ($result -eq $false -and $null -eq $canManageAllApplications) {
            # The role list was unavailable, so lack of ownership alone cannot prove
            # denial; an unread administrator role could still permit the action.
            $result = $null
        }
    }
    catch {
        Write-Verbose "Could not read owners of Entra application '$ApplicationObjectId': $($_.Exception.Message)"
    }

    $script:entraIdApplicationManagementCache[$cacheKey] = $result
    return $result
}

function Test-EntraIdApplicationRegistration {
    <#
    .SYNOPSIS
        Validates whether an Entra application is ready for Dataverse setup.
    .DESCRIPTION
        Resolves an application by client ID and reads its Dataverse API permissions,
        password credentials, federated identity credentials and enterprise application.
        Returns definite setup issues separately from read failures so callers can show
        details and let the user continue or recheck. The Dataverse user_impersonation
        delegated permission is required for the deployment token. AllowedAuthTypes
        contains Secret when a non-expired password credential exists and WIF when a
        federated identity credential has the Azure AD token exchange audience. A
        credential read failure leaves that method available so callers fail open instead
        of blocking a permitted user. Results are not cached, so Recheck reads current
        configuration.
    .PARAMETER ApplicationId
        Application/client ID, not the application object ID.
    .PARAMETER TenantId
        Tenant containing the application.
    .PARAMETER ProviderName
        Provider whose federated credential issuer is accepted. When omitted, any
        issuer is accepted as long as the audience matches.
    .PARAMETER ExpectedFederatedIssuer
        Exact federated credential issuer required for this repository or service
        connection. When supplied, a credential must match this issuer instead of the
        provider's general issuer pattern. Blank keeps provider matching.
    .PARAMETER ExpectedFederatedSubject
        Exact federated credential subject required for this repository and
        environment. When supplied, a credential must match the issuer, audience and
        subject. Blank skips subject validation.
    .OUTPUTS
        System.Management.Automation.PSCustomObject with ApplicationId,
        ApplicationObjectId, DisplayName, Exists, HasServicePrincipal,
        HasDataversePermission, HasClientSecret, HasUsableClientSecret,
        HasFederatedCredential, HasUsableFederatedCredential, AllowedAuthTypes,
        Issues, IsReady, CheckFailed and CheckError.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][AllowEmptyString()][AllowNull()][string]$ApplicationId,
        [Parameter()][AllowEmptyString()][AllowNull()][string]$TenantId,
        [Parameter()][ValidateSet('GitHub', 'AzureDevOps')][string]$ProviderName,
        [Parameter()][AllowEmptyString()][string]$ExpectedFederatedIssuer,
        [Parameter()][AllowEmptyString()][string]$ExpectedFederatedSubject
    )

    $issues = [System.Collections.Generic.List[string]]::new()
    $checkErrors = [System.Collections.Generic.List[string]]::new()
    $result = [pscustomobject]@{
        ApplicationId                 = $ApplicationId
        ApplicationObjectId           = $null
        DisplayName                   = $null
        Exists                        = $null
        HasServicePrincipal           = $null
        HasDataversePermission        = $null
        HasClientSecret               = $null
        HasUsableClientSecret         = $null
        HasFederatedCredential        = $null
        HasUsableFederatedCredential  = $null
        AllowedAuthTypes              = @()
        Issues                        = @()
        IsReady                       = $false
        CheckFailed                   = $false
        CheckError                    = $null
    }

    if ([string]::IsNullOrWhiteSpace($ApplicationId) -or [string]::IsNullOrWhiteSpace($TenantId)) {
        $result.CheckFailed = $true
        $result.CheckError = 'An application client ID and tenant are required for validation.'
        return $result
    }

    try {
        $graphToken = Get-AuthToken -ResourceUrl 'https://graph.microsoft.com' -TenantId $TenantId
        if (-not $graphToken -or [string]::IsNullOrWhiteSpace([string]$graphToken.AccessToken)) {
            throw 'No Microsoft Graph access token was returned.'
        }
        $headers = @{ Authorization = "Bearer $($graphToken.AccessToken)" }
    }
    catch {
        $result.CheckFailed = $true
        $result.CheckError = "Could not authenticate to validate the application: $($_.Exception.Message)"
        return $result
    }

    $escapedApplicationId = $ApplicationId.Replace("'", "''")
    $app = $null
    try {
        $applicationUri = "https://graph.microsoft.com/v1.0/applications?`$filter=appId eq '$escapedApplicationId'&`$select=id,appId,displayName,passwordCredentials,requiredResourceAccess"
        $applicationResponse = Invoke-RestMethod -Uri $applicationUri -Headers $headers -Method Get
        $app = @($applicationResponse.value) | Select-Object -First 1
    }
    catch {
        $result.CheckFailed = $true
        $result.CheckError = "Could not read the application: $($_.Exception.Message)"
        return $result
    }

    if (-not $app) {
        $result.Exists = $false
        $result.Issues = @("No application with client ID '$ApplicationId' was found in tenant '$TenantId'.")
        return $result
    }

    $result.Exists = $true
    $result.ApplicationObjectId = [string](Get-OptionalObjectPropertyValue -InputObject $app -PropertyName 'id')
    $result.DisplayName = [string](Get-OptionalObjectPropertyValue -InputObject $app -PropertyName 'displayName')

    # The deployment identity requests Dataverse tokens, so the app must request the
    # Dataverse user_impersonation scope. Consent is granted separately in Entra.
    $dataverseResourceAppId = '00000007-0000-0000-c000-000000000000'
    $dataverseUserImpersonationScopeId = '78ce3f0f-a1ce-49c2-8cde-64b5c0896db4'
    $requiredResourceAccess = @(
        Get-OptionalObjectPropertyValue -InputObject $app -PropertyName 'requiredResourceAccess' |
            Where-Object { $null -ne $_ }
    )
    $hasDataversePermission = $false
    foreach ($resourceAccess in $requiredResourceAccess) {
        if ([string](Get-OptionalObjectPropertyValue -InputObject $resourceAccess -PropertyName 'resourceAppId') -ine $dataverseResourceAppId) {
            continue
        }
        $permissionEntries = @(
            Get-OptionalObjectPropertyValue -InputObject $resourceAccess -PropertyName 'resourceAccess' |
                Where-Object { $null -ne $_ }
        )
        $matchingPermission = @($permissionEntries | Where-Object {
                [string](Get-OptionalObjectPropertyValue -InputObject $_ -PropertyName 'id') -ieq $dataverseUserImpersonationScopeId -and
                [string](Get-OptionalObjectPropertyValue -InputObject $_ -PropertyName 'type') -ieq 'Scope'
            })
        if ($matchingPermission.Count -gt 0) {
            $hasDataversePermission = $true
            break
        }
    }
    $result.HasDataversePermission = $hasDataversePermission
    if (-not $hasDataversePermission) {
        $issues.Add('The app registration is missing the Dataverse user_impersonation permission. Add Dynamics CRM > Delegated permissions > user_impersonation under API permissions and grant admin consent.')
    }

    try {
        $servicePrincipalUri = "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$escapedApplicationId'&`$select=id,appId,displayName"
        $servicePrincipalResponse = Invoke-RestMethod -Uri $servicePrincipalUri -Headers $headers -Method Get
        $result.HasServicePrincipal = @($servicePrincipalResponse.value).Count -gt 0
        if (-not $result.HasServicePrincipal) {
            $issues.Add('The app registration has no enterprise application (service principal) in this tenant. Create it or ask an Entra administrator to create it.')
        }
    }
    catch {
        $checkErrors.Add("Could not verify the enterprise application: $($_.Exception.Message)")
        $issues.Add('The enterprise application (service principal) could not be verified.')
    }

    $passwordCredentials = @(
        Get-OptionalObjectPropertyValue -InputObject $app -PropertyName 'passwordCredentials' |
            Where-Object { $null -ne $_ }
    )
    $result.HasClientSecret = $passwordCredentials.Count -gt 0
    $now = [datetimeoffset]::UtcNow
    $expiredSecretCount = 0
    $futureSecretCount = 0
    $usableSecrets = @($passwordCredentials | Where-Object {
            $startDateTime = Get-OptionalObjectPropertyValue -InputObject $_ -PropertyName 'startDateTime'
            if ($null -ne $startDateTime) {
                $parsedStart = [datetimeoffset]::MinValue
                if (
                    [datetimeoffset]::TryParse([string]$startDateTime, [ref]$parsedStart) -and
                    $parsedStart -gt $now
                ) {
                    $futureSecretCount++
                    return $false
                }
            }

            $endDateTime = Get-OptionalObjectPropertyValue -InputObject $_ -PropertyName 'endDateTime'
            if ($null -eq $endDateTime) {
                return $true
            }
            $parsedEnd = [datetimeoffset]::MinValue
            if (-not [datetimeoffset]::TryParse([string]$endDateTime, [ref]$parsedEnd)) {
                return $true
            }
            if ($parsedEnd -le $now) {
                $expiredSecretCount++
                return $false
            }
            return $true
        })
    $result.HasUsableClientSecret = $usableSecrets.Count -gt 0
    if ($result.HasClientSecret -and -not $result.HasUsableClientSecret) {
        if ($expiredSecretCount -gt 0) {
            $issues.Add('One or more client secrets on the app registration have expired.')
        }
        if ($futureSecretCount -gt 0) {
            $issues.Add('The app registration has a client secret that is not valid yet. Wait until its start date or create another secret.')
        }
    }

    try {
        $federatedUri = "https://graph.microsoft.com/beta/applications/$([Uri]::EscapeDataString($result.ApplicationObjectId))/federatedIdentityCredentials?`$select=id,name,issuer,subject,audiences"
        $federatedResponse = Invoke-RestMethod -Uri $federatedUri -Headers $headers -Method Get
        $federatedCredentials = @($federatedResponse.value | Where-Object { $null -ne $_ })
        $result.HasFederatedCredential = $federatedCredentials.Count -gt 0
        $issuerAudienceMatches = @($federatedCredentials | Where-Object {
                $audiences = Get-OptionalObjectPropertyValue -InputObject $_ -PropertyName 'audiences'
                if ($null -eq $audiences -or @($audiences) -notcontains 'api://AzureADTokenExchange') {
                    return $false
                }
                $issuer = [string](Get-OptionalObjectPropertyValue -InputObject $_ -PropertyName 'issuer')
                if (-not [string]::IsNullOrWhiteSpace($ExpectedFederatedIssuer)) {
                    return ($issuer -ceq $ExpectedFederatedIssuer)
                }
                if ($ProviderName -eq 'GitHub') {
                    return ($issuer -ieq 'https://token.actions.githubusercontent.com')
                }
                if ($ProviderName -eq 'AzureDevOps') {
                    return ($issuer -match '^https://vstoken\.dev\.azure\.com/')
                }
                return $true
            })
        $usableFederated = @($issuerAudienceMatches | Where-Object {
                if ([string]::IsNullOrWhiteSpace($ExpectedFederatedSubject)) {
                    return $true
                }
                $subject = [string](Get-OptionalObjectPropertyValue -InputObject $_ -PropertyName 'subject')
                return ($subject -ceq $ExpectedFederatedSubject)
            })
        $result.HasUsableFederatedCredential = $usableFederated.Count -gt 0
        if ($result.HasFederatedCredential -and -not $result.HasUsableFederatedCredential) {
            $providerIssuer = if ($ProviderName -eq 'GitHub') {
                'the GitHub Actions issuer and '
            }
            elseif ($ProviderName -eq 'AzureDevOps') {
                'the Azure DevOps issuer and '
            }
            else {
                ''
            }
            if (
                -not [string]::IsNullOrWhiteSpace($ExpectedFederatedSubject) -and
                $issuerAudienceMatches.Count -gt 0
            ) {
                $subjectRemediation = if ($ProviderName -eq 'GitHub') {
                    "Update the credential subject to match the repository's current OIDC mode."
                }
                elseif ($ProviderName -eq 'AzureDevOps') {
                    'Update the credential subject to match the service connection.'
                }
                else {
                    'Update the credential subject to match the expected value.'
                }
                $issues.Add("Federated identity credentials use the expected issuer and audience but not the required subject '$ExpectedFederatedSubject'. $subjectRemediation")
            }
            else {
                $issues.Add("Federated identity credentials exist but none use $($providerIssuer)api://AzureADTokenExchange audience.")
            }
        }
    }
    catch {
        $checkErrors.Add("Could not read federated identity credentials: $($_.Exception.Message)")
        $issues.Add('Federated identity credentials could not be verified.')
    }

    $allowedAuthTypes = @()
    if ($result.HasUsableClientSecret -ne $false) {
        $allowedAuthTypes += 'Secret'
    }
    if ($result.HasUsableFederatedCredential -ne $false) {
        $allowedAuthTypes += 'WIF'
    }
    if ($result.HasClientSecret -eq $false -and $result.HasFederatedCredential -eq $false) {
        $issues.Add('The app registration has no usable client secret or federated identity credential for Dataverse authentication.')
    }

    $result.Issues = @($issues)
    $result.AllowedAuthTypes = @($allowedAuthTypes)
    $result.CheckFailed = $checkErrors.Count -gt 0
    $result.CheckError = if ($checkErrors.Count -gt 0) { $checkErrors -join ' ' } else { $null }
    $result.IsReady = (-not $result.CheckFailed) -and $result.Issues.Count -eq 0
    return $result
}

function Find-EntraIdApplicationByDisplayName {
    <#
    .SYNOPSIS
        Finds Entra applications whose display name starts with a fragment.
    .DESCRIPTION
        Uses Graph startswith filtering so a partial prefix searches the tenant without
        reading every application. Blank input returns no results. A 401/403 response
        sets PermissionDenied; other failures set Error. Results are sorted by display
        name and capped by Limit. No objects are created.
    .PARAMETER TenantId
        Tenant to search.
    .PARAMETER NameFragment
        Case-insensitive display-name prefix. Single quotes are escaped for OData.
    .PARAMETER Limit
        Maximum number of matches to return, from 1 to 100.
    .OUTPUTS
        System.Management.Automation.PSCustomObject with Applications,
        PermissionDenied and Error.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][AllowEmptyString()][AllowNull()][string]$TenantId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$NameFragment,
        [Parameter()][ValidateRange(1, 100)][int]$Limit = 25
    )

    $result = [pscustomobject]@{
        Applications     = @()
        PermissionDenied = $false
        Error            = $null
    }

    if ([string]::IsNullOrWhiteSpace($TenantId) -or [string]::IsNullOrWhiteSpace($NameFragment)) {
        return $result
    }

    try {
        $graphToken = Get-AuthToken -ResourceUrl 'https://graph.microsoft.com' -TenantId $TenantId
        if (-not $graphToken -or [string]::IsNullOrWhiteSpace([string]$graphToken.AccessToken)) {
            throw 'No Microsoft Graph access token was returned.'
        }
        $headers = @{ Authorization = "Bearer $($graphToken.AccessToken)" }
    }
    catch {
        $result.Error = "Could not authenticate to search applications: $($_.Exception.Message)"
        return $result
    }

    try {
        $escapedFragment = [Uri]::EscapeDataString($NameFragment.Replace("'", "''"))
        $uri = "https://graph.microsoft.com/v1.0/applications?`$filter=startswith(displayName,'$escapedFragment')&`$select=id,appId,displayName&`$top=$Limit"
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
        $result.Applications = @($response.value | Sort-Object -Property displayName)
        return $result
    }
    catch {
        if (Test-EntraIdPermissionDenied -ErrorRecord $_) {
            $result.PermissionDenied = $true
        }
        else {
            $result.Error = "Application search failed: $($_.Exception.Message)"
        }
        return $result
    }
}

function Get-SetupEntraIdApplicationCreationGuidance {
    <#
    .SYNOPSIS
        Returns console guidance for creating an application registration manually.
    .DESCRIPTION
        Produces provider-specific steps for creating the app, adding the Dataverse
        user_impersonation scope, choosing between workload identity federation
        (recommended) and a client secret, and configuring the chosen credential
        manually. The text is display guidance; validation checks the enterprise
        application and credentials separately.
    .PARAMETER ProviderName
        Provider whose workload identity federation subject and issuer differ.
    .PARAMETER WorkloadIdentityFederationSubject
        Exact federated credential subject for this repository and environment. When
        supplied, GitHub guidance shows it instead of a placeholder. Azure DevOps
        guidance uses the service connection values.
    .OUTPUTS
        System.Object[] of display lines.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][ValidateSet('GitHub', 'AzureDevOps')][string]$ProviderName,
        [Parameter()][AllowEmptyString()][string]$WorkloadIdentityFederationSubject
    )

    $lines = @(
        'Open Microsoft Entra admin center > App registrations > New registration and choose single-tenant access.'
        'Under API permissions, add Dynamics CRM > Delegated permissions > user_impersonation, then Grant admin consent.'
        'Choose one authentication method; workload identity federation is recommended because it avoids client secrets.'
    )
    if ($ProviderName -eq 'GitHub') {
        $subjectInstruction = if (-not [string]::IsNullOrWhiteSpace($WorkloadIdentityFederationSubject)) {
            "subject $WorkloadIdentityFederationSubject"
        }
        else {
            'the exact subject shown by setup for this repository and environment'
        }
        $lines += "For WIF, open Certificates & secrets > Federated credentials > Add credential. Choose GitHub Actions deploying Azure resources or Other issuer so the credential has issuer https://token.actions.githubusercontent.com, audience api://AzureADTokenExchange, and $subjectInstruction. Add one credential per environment, including BUILD validation."
    }
    else {
        $lines += 'For WIF, create the Power Platform service connection with WIF, then open it and copy the exact issuer and subject it displays. In Certificates & secrets > Federated credentials > Add credential > Other issuer, enter those values with audience api://AzureADTokenExchange; do not substitute an example.'
    }
    $lines += @(
        'For a client secret instead, create it under Certificates & secrets and copy the value now; Microsoft Graph never displays it later.'
        'Copy the Application (client) ID and enter it below.'
    )
    return $lines
}

function Select-EntraIdApplicationBySearch {
    <#
    .SYNOPSIS
        Prompts for a partial application name and returns a selected application.
    .DESCRIPTION
        Loops search prompts and result menus until an application is selected or the
        user cancels. Permission denial or another search failure warns and returns
        null so the caller can return to its credential menu. Results are limited and
        the menu offers search again and cancel.
    .PARAMETER TenantId
        Tenant to search.
    .PARAMETER PromptGuidanceDocRelativePath
        Documentation page available from the F1 help hint.
    .PARAMETER PromptGuidanceRef
        Documentation revision for the help hint.
    .OUTPUTS
        Selected Graph application object, or null when the user cancels or search fails.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter()][string]$PromptGuidanceDocRelativePath,
        [Parameter()][string]$PromptGuidanceRef
    )

    while ($true) {
        $nameFragment = Read-TextWithDefault `
            -Prompt 'Application display name (or prefix)' `
            -PromptGuidanceLines @(
                'Enter the beginning of the app registration display name to search this tenant.',
                'Return to the credential menu to enter the application ID directly instead.'
            ) `
            -PromptGuidanceDocRelativePath $PromptGuidanceDocRelativePath `
            -PromptGuidanceRef $PromptGuidanceRef
        if ([string]::IsNullOrWhiteSpace($nameFragment)) {
            continue
        }

        $search = Find-EntraIdApplicationByDisplayName -TenantId $TenantId -NameFragment $nameFragment
        if ($search.PermissionDenied) {
            Write-Warning 'The signed-in account cannot search applications in this tenant. Enter the application ID directly or ask an Entra administrator.'
            return $null
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$search.Error)) {
            Write-Warning $search.Error
            return $null
        }

        $applications = @($search.Applications)
        if ($applications.Count -eq 0) {
            $retryItems = @('Search again', 'Cancel search')
            $retrySelection = Select-FromMenu `
                -Title "No applications matched '$nameFragment'" `
                -Items $retryItems `
                -PromptGuidanceLines @('Try a shorter prefix or a different spelling.') `
                -PromptGuidanceDocRelativePath $PromptGuidanceDocRelativePath `
                -PromptGuidanceRef $PromptGuidanceRef
            if ($null -eq $retrySelection -or $retrySelection -eq 1) {
                return $null
            }
            continue
        }

        $items = @($applications | ForEach-Object { "$($_.displayName) ($($_.appId))" })
        $searchAgainIndex = $items.Count
        $cancelIndex = $items.Count + 1
        $items += 'Search again'
        $items += 'Cancel search'
        $selection = Select-FromMenu `
            -Title "Applications matching '$nameFragment'" `
            -Items $items `
            -PromptGuidanceLines @("Showing $($applications.Count) match(es). Select the app registration to use for this environment.") `
            -PromptGuidanceDocRelativePath $PromptGuidanceDocRelativePath `
            -PromptGuidanceRef $PromptGuidanceRef
        if ($null -eq $selection -or $selection -eq $cancelIndex) {
            return $null
        }
        if ($selection -eq $searchAgainIndex) {
            continue
        }

        return $applications[$selection]
    }
}

function Read-SetupEntraIdClientSecret {
    <#
    .SYNOPSIS
        Reads and returns a client-secret value with a GUID warning.
    .DESCRIPTION
        Re-prompts when the value still matches the secret-ID format and the user does
        not confirm that it is the secret value. Masking is display-only; the returned
        string is plaintext for later storage. Prompt failures and navigation markers
        propagate.
    .PARAMETER Prompt
        Prompt label.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][string]$Prompt = 'Client Secret',
        [Parameter()][string[]]$PromptGuidanceLines,
        [Parameter()][string]$PromptGuidanceDocRelativePath,
        [Parameter()][string]$PromptGuidanceRef
    )

    while ($true) {
        $secret = Read-SecretText `
            -Prompt $Prompt `
            -PromptGuidanceLines $PromptGuidanceLines `
            -PromptGuidanceDocRelativePath $PromptGuidanceDocRelativePath `
            -PromptGuidanceRef $PromptGuidanceRef

        if ($secret -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
            Write-Warning 'The Client Secret looks like a GUID. You should enter the Secret VALUE, not the Secret ID.'
            if (Read-YesNo -Prompt 'Are you sure this is the Secret Value?' -DefaultNo) {
                return $secret
            }
            continue
        }

        return $secret
    }
}

function Read-SetupEntraIdApplicationCredential {
    <#
    .SYNOPSIS
        Validates an existing Entra application and returns credential metadata.
    .DESCRIPTION
        Prompts for a client ID when one is not supplied, optionally showing manual
        creation guidance. Validation problems and read failures show details and offer
        continue, recheck or a different ID, so a permitted user is never silently
        blocked. Authentication choices are limited to configured methods; when the
        methods cannot be determined or none are configured, both remain available
        after the explicit continue. Secret authentication prompts for the value
        because Graph never returns existing secret values. No Graph mutation occurs
        here; Apply performs deferred writes.
    .PARAMETER TenantId
        Tenant containing the application.
    .PARAMETER ProviderName
        Provider whose authentication-type menu order is used.
    .PARAMETER ApplicationId
        Existing client ID to validate. When blank, the function prompts for one.
    .PARAMETER Name
        Friendly reuse name. Blank uses the application display name.
    .PARAMETER ShowCreationInstructions
        Shows manual application-creation guidance with the application ID prompt.
    .PARAMETER ApplicationManagementState
        Previously detected Get-EntraIdApplicationManagementState result. Used to
        decide whether WIF can be selected when doing so would require adding a
        federated credential. A definite false dims WIF; unknown remains available.
    .PARAMETER WorkloadIdentityFederationIssuer
        Exact federated credential issuer for this repository or service connection.
        Used to validate an existing credential when available.
    .PARAMETER WorkloadIdentityFederationSubject
        Exact federated credential subject for this repository and environment. Used to
        validate an existing credential and, for GitHub, in creation guidance.
    .PARAMETER DisableWorkloadIdentityFederation
        Removes WIF from the available authentication choices. Use when extension mode
        does not support WIF.
    .OUTPUTS
        System.Management.Automation.PSCustomObject with Name, ApplicationId,
        ApplicationObjectId, ClientSecret, TenantId, AuthType, RotateSecret,
        IsExistingServiceConnection and Validation.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][ValidateSet('GitHub', 'AzureDevOps')][string]$ProviderName,
        [Parameter()][AllowEmptyString()][string]$ApplicationId,
        [Parameter()][string]$Name,
        [Parameter()][switch]$ShowCreationInstructions,
        [Parameter()][object]$ApplicationManagementState,
        [Parameter()][AllowEmptyString()][string]$WorkloadIdentityFederationIssuer,
        [Parameter()][AllowEmptyString()][string]$WorkloadIdentityFederationSubject,
        [Parameter()][switch]$DisableWorkloadIdentityFederation,
        [Parameter()][string]$PromptGuidanceDocRelativePath,
        [Parameter()][string]$PromptGuidanceRef
    )

    $validation = $null
    $effectiveApplicationId = $ApplicationId
    while ($true) {
        if ([string]::IsNullOrWhiteSpace($effectiveApplicationId)) {
            $applicationIdGuidance = if ($ShowCreationInstructions) {
                Get-SetupEntraIdApplicationCreationGuidance `
                    -ProviderName $ProviderName `
                    -WorkloadIdentityFederationSubject $WorkloadIdentityFederationSubject
            }
            else {
                @('Enter the Application (client) ID from the existing app registration.')
            }

            while ($true) {
                $enteredApplicationId = Read-TextWithDefault `
                    -Prompt 'Application ID (Client ID)' `
                    -PromptGuidanceLines $applicationIdGuidance `
                    -PromptGuidanceDocRelativePath $PromptGuidanceDocRelativePath `
                    -PromptGuidanceRef $PromptGuidanceRef
                if ($enteredApplicationId -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
                    $effectiveApplicationId = $enteredApplicationId
                    break
                }
                Write-Warning 'The Application ID must be a valid GUID. Please try again.'
            }
        }

        $validation = Test-EntraIdApplicationRegistration `
            -ApplicationId $effectiveApplicationId `
            -TenantId $TenantId `
            -ProviderName $ProviderName `
            -ExpectedFederatedIssuer $WorkloadIdentityFederationIssuer `
            -ExpectedFederatedSubject $WorkloadIdentityFederationSubject
        if ($validation.IsReady) {
            Write-Host "Validated application '$($validation.DisplayName)' ($effectiveApplicationId)." -ForegroundColor Green
            break
        }

        $details = @()
        if (-not [string]::IsNullOrWhiteSpace([string]$validation.CheckError)) {
            $details += "Validation could not complete: $($validation.CheckError)"
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$validation.DisplayName)) {
            $details += "Application: $($validation.DisplayName) ($effectiveApplicationId)"
        }
        $details += @($validation.Issues)
        if (@($validation.AllowedAuthTypes).Count -gt 0) {
            $details += "Configured authentication: $(@($validation.AllowedAuthTypes) -join ', ')."
        }
        $details += 'Continue with this application, recheck after changing it in Entra, or enter a different application ID.'

        $validationChoice = Select-FromMenu `
            -Title "Application '$effectiveApplicationId' needs attention" `
            -Items @('Continue with this application', 'Recheck application setup', 'Enter a different application ID') `
            -PromptGuidanceLines $details `
            -PromptGuidanceDocRelativePath $PromptGuidanceDocRelativePath `
            -PromptGuidanceRef $PromptGuidanceRef
        if ($null -eq $validationChoice) {
            throw 'No application validation option selected.'
        }
        if ($validationChoice -eq 2) {
            $effectiveApplicationId = ''
            continue
        }
        if ($validationChoice -eq 0) {
            break
        }
    }

    $originalAuthTypes = @($validation.AllowedAuthTypes)
    $allowedAuthTypes = @($originalAuthTypes)
    if ($DisableWorkloadIdentityFederation) {
        $allowedAuthTypes = @($allowedAuthTypes | Where-Object { $_ -ne 'WIF' })
        if ($allowedAuthTypes.Count -eq 0 -and $originalAuthTypes -contains 'WIF') {
            Write-Warning 'This application is configured only for workload identity federation, but extension mode is disabled. Configure a client secret or enable extension mode.'
        }
    }
    if ($allowedAuthTypes.Count -eq 0) {
        $availableMethodsMessage = if ($DisableWorkloadIdentityFederation) {
            'Client-secret authentication remains available because you chose to continue after validation.'
        }
        else {
            'Both authentication types remain available because you chose to continue after validation.'
        }
        if ($validation.Exists -eq $true -and -not $validation.CheckFailed) {
            Write-Warning "The application has no usable client secret or federated identity credential. $availableMethodsMessage"
        }
        else {
            Write-Warning "The configured authentication methods could not be determined. $availableMethodsMessage"
        }
        $allowedAuthTypes = if ($DisableWorkloadIdentityFederation) { @('Secret') } else { @('Secret', 'WIF') }
    }

    $authType = $null
    if ($allowedAuthTypes.Count -eq 1) {
        $authType = [string]$allowedAuthTypes[0]
        $methodDescription = if ($authType -eq 'WIF') { 'workload identity federation' } else { 'a client secret' }
        Write-Host "Using $methodDescription because it is the only authentication method available for this application." -ForegroundColor Green
    }
    else {
        $wifLabel = 'Workload Identity Federation (recommended, no secrets)'
        $secretLabel = 'Service Principal with Secret (traditional)'
        $authTypeItems = if ($ProviderName -eq 'GitHub') {
            @($wifLabel, $secretLabel)
        }
        else {
            @($secretLabel, $wifLabel)
        }

        # WIF only needs a Graph write when no usable federated credential already
        # matches this application. A definite denial hides that choice; unknown stays
        # available so a transient read failure does not block a permitted user.
        $dimAuthTypeItems = @()
        if ($allowedAuthTypes -contains 'WIF' -and $validation.HasUsableFederatedCredential -eq $false) {
            $canManageApplication = Test-EntraIdApplicationManagement `
                -TenantId $TenantId `
                -ApplicationObjectId ([string]$validation.ApplicationObjectId) `
                -ApplicationId ([string]$validation.ApplicationId) `
                -State $ApplicationManagementState
            if ($canManageApplication -eq $false) {
                $wifIndex = [array]::IndexOf($authTypeItems, $wifLabel)
                $dimmedWifLabel = "$wifLabel [requires Entra ID permissions]"
                $authTypeItems[$wifIndex] = $dimmedWifLabel
                $dimAuthTypeItems += $dimmedWifLabel
            }
        }

        $authTypeSelection = $null
        $authTypePromptNotice = $null
        while ($null -eq $authTypeSelection) {
            $authTypeGuidance = @(
                'Choose the authentication mode for the validated App Registration.',
                'Methods that are not configured on the application are not offered.'
            )
            if ($dimAuthTypeItems.Count -gt 0) {
                $authTypeGuidance += 'Workload identity federation needs permission to manage credentials on this App Registration. Ask an Entra administrator or choose client-secret authentication.'
            }
            if ($authTypePromptNotice) {
                $authTypeGuidance = @($authTypePromptNotice) + $authTypeGuidance
            }
            $authTypeSelection = Select-FromMenu `
                -Title 'Select authentication type' `
                -Items $authTypeItems `
                -DimItems $dimAuthTypeItems `
                -PromptGuidanceLines $authTypeGuidance `
                -PromptGuidanceDocRelativePath $PromptGuidanceDocRelativePath `
                -PromptGuidanceRef $PromptGuidanceRef
            if ($null -eq $authTypeSelection) {
                throw 'No authentication type selected.'
            }
            if ($dimAuthTypeItems -contains $authTypeItems[$authTypeSelection]) {
                $authTypePromptNotice = 'Workload identity federation is unavailable because the signed-in account cannot manage credentials on this App Registration. Choose client-secret authentication or ask an Entra administrator.'
                $authTypeSelection = $null
            }
        }

        $authType = if ($authTypeItems[$authTypeSelection] -eq $wifLabel) { 'WIF' } else { 'Secret' }
    }

    $clientSecret = $null
    if ($authType -eq 'Secret') {
        $clientSecret = Read-SetupEntraIdClientSecret `
            -Prompt 'Client Secret' `
            -PromptGuidanceLines @(
                'Enter the client secret value for this app registration.',
                'Microsoft Graph never returns existing secret values; copy the value from the app registration or create a new secret.'
            ) `
            -PromptGuidanceDocRelativePath $PromptGuidanceDocRelativePath `
            -PromptGuidanceRef $PromptGuidanceRef
    }

    if ([string]::IsNullOrWhiteSpace($Name)) {
        $Name = if (-not [string]::IsNullOrWhiteSpace([string]$validation.DisplayName)) {
            [string]$validation.DisplayName
        }
        else {
            'Credential-' + (Get-Date -Format 'HHmm')
        }
    }

    return [pscustomobject]@{
        Name                        = $Name
        ApplicationId               = $effectiveApplicationId
        ApplicationObjectId         = $validation.ApplicationObjectId
        ClientSecret                = $clientSecret
        TenantId                    = $TenantId
        AuthType                    = $authType
        RotateSecret                = $false
        IsExistingServiceConnection = $false
        Validation                  = $validation
    }
}

function Get-AzDoAccessTokenTenantId {
    <#
    .SYNOPSIS
        Reads the tenant ID claim from a JWT access token.
    .DESCRIPTION
        Headless apply-config runs supply an Azure DevOps access token but no tenant
        parameter. Azure DevOps issues JWT tokens that carry the tenant in the 'tid'
        claim, so recover it without another interactive sign-in. Returns an empty
        string for opaque tokens or malformed payloads.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowEmptyString()][string]$AccessToken = ''
    )

    if ([string]::IsNullOrWhiteSpace($AccessToken)) { return '' }
    $segments = $AccessToken.Split('.')
    if ($segments.Count -lt 2) { return '' }

    $payload = $segments[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) {
        2 { $payload += '==' }
        3 { $payload += '=' }
    }

    try {
        $json = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($payload))
        $claims = $json | ConvertFrom-Json
        if ($claims.PSObject.Properties['tid']) { return [string]$claims.tid }
    }
    catch {
        return ''
    }

    return ''
}
