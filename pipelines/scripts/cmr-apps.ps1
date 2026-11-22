$script:CmrArtifactManifestFileName = 'cmr-app.json'
$script:CmrMinimumNodeVersion = [version]'24.11.0'
$script:CmrResolvedCliVersions = @{}

function Assert-CmrCliVersionSpecifier {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$VersionSpecifier)

    $trimmedSpecifier = $VersionSpecifier.Trim()
    if ($trimmedSpecifier -in @('', 'latest', 'prerelease') -or
        $trimmedSpecifier -match '^\d+\.\d+\.\d+(?:-[0-9A-Za-z][0-9A-Za-z\.-]*)?$') {
        return
    }

    throw "cmrCliVersion '$VersionSpecifier' is invalid. Use '', 'latest', 'prerelease', or an exact npm version such as '1.0.1'."
}

function Resolve-CmrCliVersion {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$VersionSpecifier,
        [Parameter(Mandatory)][string]$NodeVersion
    )

    Assert-CmrCliVersionSpecifier -VersionSpecifier $VersionSpecifier
    $trimmedSpecifier = $VersionSpecifier.Trim()
    if ($trimmedSpecifier -match '^\d+\.\d+\.\d+(?:-[0-9A-Za-z][0-9A-Za-z\.-]*)?$') {
        return $trimmedSpecifier
    }
    if ($script:CmrResolvedCliVersions.ContainsKey($trimmedSpecifier)) {
        return [string]$script:CmrResolvedCliVersions[$trimmedSpecifier]
    }

    $runtime = Get-CmrNodeRuntime -VersionSpecifier $NodeVersion
    if ($trimmedSpecifier -in @('', 'latest')) {
        $output = @(Invoke-CheckedNativeCommand -Command $runtime.NpmPath -Arguments @('view', '@microsoft/cmr-cli', 'version', '--json'))
        $resolvedVersion = ($output -join '').Trim().Trim('"')
    }
    else {
        $output = @(Invoke-CheckedNativeCommand -Command $runtime.NpmPath -Arguments @('view', '@microsoft/cmr-cli', 'versions', '--json'))
        try {
            $versions = @((($output -join "`n") | ConvertFrom-Json -ErrorAction Stop) | ForEach-Object { [string]$_ })
        }
        catch {
            throw "Could not parse versions returned by npm for @microsoft/cmr-cli. $($_.Exception.Message)"
        }
        $prereleaseVersions = @(
            foreach ($version in $versions) {
                if ($version -match '^\d+\.\d+\.\d+-[0-9A-Za-z][0-9A-Za-z\.-]*$') {
                    [pscustomobject]@{ Version = $version; SemanticVersion = [semver]$version }
                }
            }
        )
        $latestPrerelease = $prereleaseVersions | Sort-Object SemanticVersion -Descending | Select-Object -First 1
        $resolvedVersion = if ($latestPrerelease) { [string]$latestPrerelease.Version } else { '' }
    }

    if ($resolvedVersion -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z][0-9A-Za-z\.-]*)?$') {
        if ($trimmedSpecifier -eq 'prerelease') {
            throw 'No prerelease version of @microsoft/cmr-cli was found on the configured npm registry.'
        }
        throw "npm returned invalid latest @microsoft/cmr-cli version '$resolvedVersion'."
    }

    $script:CmrResolvedCliVersions[$trimmedSpecifier] = $resolvedVersion
    return $resolvedVersion
}

function Get-CmrAppEntry {
    <#
    .SYNOPSIS
        Resolves configured CMR app IDs to their derived repository paths and deployment modes.
    #>
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Config,

        [Parameter(Mandatory)]
        [string]$BaseDirectory,

        [switch]$AllowMissingProject
    )

    $configuredApps = $Config['cmrApps']
    if ($null -eq $configuredApps) {
        return
    }
    if ($configuredApps -is [string]) {
        $configuredApps = @($configuredApps)
    }
    if ($configuredApps -isnot [array]) {
        throw 'cmrApps must be an array of app IDs or app configuration hashtables.'
    }

    $basePath = [System.IO.Path]::GetFullPath($BaseDirectory)
    if (-not (Test-Path -LiteralPath $basePath -PathType Container)) {
        throw "CMR app base directory was not found: $basePath"
    }

    $seenAppIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $seenTargetNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($configuredApp in $configuredApps) {
        if ($configuredApp -is [string]) {
            $appSettings = @{ appId = $configuredApp }
        }
        elseif ($configuredApp -is [System.Collections.IDictionary]) {
            $appSettings = $configuredApp
        }
        else {
            throw 'Each cmrApps entry must be an app ID string or a hashtable.'
        }

        $appId = [string]$appSettings['appId']
        $parsedAppId = [guid]::Empty
        if (-not [guid]::TryParse($appId, [ref]$parsedAppId) -or $parsedAppId -eq [guid]::Empty) {
            throw 'Each cmrApps entry must contain a non-zero appId GUID.'
        }
        $appId = $parsedAppId.ToString()
        if (-not $seenAppIds.Add($appId)) {
            throw "Duplicate CMR appId '$appId'."
        }

        $relativePath = Join-Path 'cmr-apps' $appId
        $appPath = [System.IO.Path]::GetFullPath((Join-Path $basePath $relativePath))
        $null = Assert-CodeAppPathHasNoReparsePoint -BaseDirectory $basePath -Path $appPath
        if (Test-Path -LiteralPath $appPath -PathType Leaf) {
            throw "CMR app path '$relativePath' is a file; it must be a directory."
        }
        if (-not $AllowMissingProject -and -not (Test-Path -LiteralPath $appPath -PathType Container)) {
            throw "CMR app project '$relativePath' was not found."
        }

        $targetDisplayName = [string]$appSettings['targetDisplayName']
        if (-not [string]::IsNullOrWhiteSpace($targetDisplayName)) {
            $targetDisplayName = $targetDisplayName.Trim()
            if (-not $seenTargetNames.Add($targetDisplayName)) {
                throw "Duplicate CMR targetDisplayName '$targetDisplayName'."
            }
        }

        $deploymentMode = [string]$appSettings['deploymentMode']
        if ([string]::IsNullOrWhiteSpace($deploymentMode)) {
            $deploymentMode = 'artifact'
        }
        $deploymentMode = $deploymentMode.Trim().ToLowerInvariant()
        if ($deploymentMode -notin @('artifact', 'source')) {
            throw "cmrApps deploymentMode '$deploymentMode' is invalid; use 'artifact' or 'source'."
        }

        $entries.Add([pscustomobject]@{
            RelativePath = [System.IO.Path]::GetRelativePath($basePath, $appPath)
            AppPath = $appPath
            ConfiguredAppId = $appId
            TargetDisplayName = $targetDisplayName
            DeploymentMode = $deploymentMode
        })
    }

    if ($entries.Count -eq 0) {
        return
    }

    return ,$entries.ToArray()
}

function Get-CmrDataSourcePlan {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$AppConfig
    )

    $connectionReferences = $AppConfig['connectionReferences']
    if ($null -eq $connectionReferences) {
        return ,@()
    }
    if ($connectionReferences -isnot [System.Collections.IDictionary]) {
        throw 'CMR connectionReferences must be a hashtable.'
    }

    $plans = [System.Collections.Generic.List[object]]::new()
    foreach ($reference in $connectionReferences.Values) {
        $connectorPath = [string]$reference['id']
        if ($connectorPath -notmatch '/apis/([^/]+)$') {
            throw 'A CMR connection reference has an invalid connector identifier.'
        }
        $connectorId = $Matches[1]
        if ($connectorId -ne 'shared_commondataserviceforapps') {
            throw "CMR connector '$connectorId' is not supported for automated environment provisioning; use Dataverse table data sources."
        }

        $tables = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $dataSets = $reference['dataSets']
        if ($dataSets -is [System.Collections.IDictionary]) {
            foreach ($dataSet in $dataSets.Values) {
                $dataSources = $dataSet['dataSources']
                if ($dataSources -is [System.Collections.IDictionary]) {
                    foreach ($tableName in $dataSources.Keys) {
                        if (-not [string]::IsNullOrWhiteSpace([string]$tableName)) {
                            $null = $tables.Add([string]$tableName)
                        }
                    }
                }
            }
        }
        if ($tables.Count -eq 0) {
            throw "CMR connector '$connectorId' has no Dataverse table metadata to provision."
        }

        $plans.Add([pscustomobject]@{
            ConnectorId = $connectorId
            Tables = @($tables | Sort-Object)
        })
    }

    return ,$plans.ToArray()
}

function Get-CmrAppDefinition {
    <#
    .SYNOPSIS
        Reads and validates the managed source project configuration for one app.
    #>
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Entry
    )

    $configPath = Join-Path $Entry.AppPath 'ms.config.json'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "CMR app project '$($Entry.RelativePath)' must contain ms.config.json."
    }

    try {
        $appConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -AsHashtable
    }
    catch {
        throw "CMR app project '$($Entry.RelativePath)' has invalid ms.config.json. $($_.Exception.Message)"
    }
    if ($appConfig -isnot [System.Collections.IDictionary]) {
        throw "CMR app project '$($Entry.RelativePath)' ms.config.json must contain a JSON object."
    }

    $appId = [string]$appConfig['appId']
    $environmentId = [string]$appConfig['environmentId']
    $parsedAppId = [guid]::Empty
    $parsedEnvironmentId = [guid]::Empty
    if (-not [guid]::TryParse($appId, [ref]$parsedAppId) -or $parsedAppId -eq [guid]::Empty) {
        throw "CMR app project '$($Entry.RelativePath)' has no valid appId."
    }
    if (-not [guid]::TryParse($environmentId, [ref]$parsedEnvironmentId) -or $parsedEnvironmentId -eq [guid]::Empty) {
        throw "CMR app project '$($Entry.RelativePath)' has no valid environmentId."
    }
    if ([string]$appConfig['repoType'] -ne 'native') {
        throw "CMR app project '$($Entry.RelativePath)' must use a platform-managed Git repository (repoType 'native')."
    }
    if ($Entry.ConfiguredAppId -and $Entry.ConfiguredAppId -ne $parsedAppId.ToString()) {
        throw "cmrApps appId does not match the app configured at '$($Entry.RelativePath)'."
    }

    $displayName = [string]$appConfig['appDisplayName']
    if ([string]::IsNullOrWhiteSpace($displayName)) {
        throw "CMR app project '$($Entry.RelativePath)' has no appDisplayName."
    }
    $buildPath = if ([string]::IsNullOrWhiteSpace([string]$appConfig['buildPath'])) { 'dist' } else { [string]$appConfig['buildPath'] }
    $buildCommand = if ([string]::IsNullOrWhiteSpace([string]$appConfig['buildCommand'])) { 'npm run build' } else { [string]$appConfig['buildCommand'] }
    $buildEntryPoint = if ([string]::IsNullOrWhiteSpace([string]$appConfig['buildEntryPoint'])) { 'index.html' } else { [string]$appConfig['buildEntryPoint'] }
    $buildRoot = Get-CodeAppBuildRoot -CodeAppPath $Entry.AppPath -BuildPath $buildPath -AllowMissing
    $targetDisplayName = if ([string]::IsNullOrWhiteSpace($Entry.TargetDisplayName)) {
        "$displayName (ALM4Dataverse)"
    }
    else {
        $Entry.TargetDisplayName
    }

    [pscustomobject]@{
        RelativePath = $Entry.RelativePath
        AppPath = $Entry.AppPath
        AppId = $parsedAppId.ToString()
        EnvironmentId = $parsedEnvironmentId.ToString()
        DeploymentMode = $Entry.DeploymentMode
        DisplayName = $displayName
        TargetDisplayName = $targetDisplayName
        BuildPath = $buildPath
        BuildRoot = $buildRoot
        BuildCommand = $buildCommand
        BuildEntryPoint = $buildEntryPoint
        Cloud = if ([string]::IsNullOrWhiteSpace([string]$appConfig['cloud'])) { 'public' } else { [string]$appConfig['cloud'] }
        Version = [string]$appConfig['version']
        Schema = [string]$appConfig['$schema']
        DataSources = @(Get-CmrDataSourcePlan -AppConfig $appConfig)
    }
}

function Get-CmrNodeRuntime {
    param(
        [Parameter(Mandatory)]
        [string]$VersionSpecifier
    )

    $specifier = $VersionSpecifier.Trim() -replace '^v', ''
    if ($specifier -notmatch '^(\d+|\d+\.\d+\.\d+)$') {
        throw "cmrNodeVersion '$VersionSpecifier' is invalid. Use a major version or an exact three-part version."
    }

    $candidates = [System.Collections.Generic.List[string]]::new()
    foreach ($command in (Get-Command node -All -ErrorAction SilentlyContinue)) {
        if ($command.CommandType -eq 'Application' -and -not [string]::IsNullOrWhiteSpace([string]$command.Source)) {
            $candidates.Add([string]$command.Source)
        }
    }

    $nodeRoot = Join-Path $HOME '.alm4dataverse/tools/node'
    if (Test-Path -LiteralPath $nodeRoot -PathType Container) {
        foreach ($directory in (Get-ChildItem -LiteralPath $nodeRoot -Directory)) {
            $candidate = Join-Path $directory.FullName $(if ($IsWindows) { 'node.exe' } else { 'bin/node' })
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $candidates.Add($candidate)
            }
        }
    }

    $pathSeparator = [System.IO.Path]::PathSeparator
    foreach ($directory in ($env:PATH -split [regex]::Escape([string]$pathSeparator))) {
        if ([string]::IsNullOrWhiteSpace($directory)) {
            continue
        }
        $candidate = Join-Path $directory $(if ($IsWindows) { 'node.exe' } else { 'node' })
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $candidates.Add($candidate)
        }
    }

    foreach ($nodePath in ($candidates | Select-Object -Unique)) {
        $versionOutput = @(& $nodePath --version 2>&1)
        if ($LASTEXITCODE -ne 0 -or $versionOutput.Count -ne 1 -or $versionOutput[0] -notmatch '^v(\d+\.\d+\.\d+)$') {
            continue
        }
        $version = [version]$Matches[1]
        $versionMatches = if ($specifier -match '^\d+$') {
            $version.Major -eq [int]$specifier
        }
        else {
            $version -eq [version]$specifier
        }
        if (-not $versionMatches -or $version -lt $script:CmrMinimumNodeVersion) {
            continue
        }

        $nodeDirectory = Split-Path -Parent $nodePath
        $npmPath = Join-Path $nodeDirectory $(if ($IsWindows) { 'npm.cmd' } else { 'npm' })
        if (-not (Test-Path -LiteralPath $npmPath -PathType Leaf)) {
            continue
        }
        return [pscustomobject]@{
            NodePath = $nodePath
            NodeDirectory = $nodeDirectory
            NpmPath = $npmPath
            Version = $version
        }
    }

    throw "Node.js satisfying cmrNodeVersion '$VersionSpecifier' and minimum version $($script:CmrMinimumNodeVersion) was not found. Run installdependencies.ps1."
}

function ConvertFrom-CmrCliOutput {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Output,

        [Parameter(Mandatory)]
        [string]$Operation
    )

    if ([string]::IsNullOrWhiteSpace($Output)) {
        throw "CMR CLI operation '$Operation' returned no output."
    }

    $lines = @($Output -split "`r?`n")
    for ($startIndex = $lines.Count - 1; $startIndex -ge 0; $startIndex--) {
        if ($lines[$startIndex].TrimStart() -notlike '{*') {
            continue
        }
        $candidate = $lines[$startIndex..($lines.Count - 1)] -join "`n"
        try {
            $result = ConvertFrom-Json -InputObject $candidate -AsHashtable -ErrorAction Stop
            if ($result -is [System.Collections.IDictionary]) {
                return $result
            }
        }
        catch {
            continue
        }
    }

    throw "CMR CLI operation '$Operation' did not return valid JSON."
}

function ConvertTo-CmrSafeMessage {
    param([string]$Message)

    $safeMessage = [string]$Message
    $safeMessage = $safeMessage -replace '(?i)\b[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\b', '<GUID>'
    $safeMessage = $safeMessage -replace '(?i)(bearer\s+)[^\s,;"]+', '$1<redacted>'
    $safeMessage = $safeMessage -replace 'https?://\S+', '<URL>'
    return $safeMessage
}

function Assert-CmrManagedGitUrl {
    param([Parameter(Mandatory)][string]$Url)

    $uri = $null
    if (-not [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or
        $uri.UserInfo -or
        $uri.Query -or
        $uri.Fragment -or
        -not $uri.Host.EndsWith('.environment.api.powerplatform.com', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'CMR app info returned an unsupported platform-managed Git URL.'
    }
}

function Invoke-CmrCli {
    <#
    .SYNOPSIS
        Runs the pinned CMR CLI with service-principal authentication for API operations.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$CliVersion,

        [Parameter(Mandatory)]
        [string]$NodeVersion,

        [string]$GitAuthorizationUrl
    )

    if (-not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
        throw "CMR CLI working directory was not found: $WorkingDirectory"
    }

    $clientId = [System.Environment]::GetEnvironmentVariable('AZURE_CLIENT_ID')
    $tenantId = [System.Environment]::GetEnvironmentVariable('AZURE_TENANT_ID')
    $clientSecret = [System.Environment]::GetEnvironmentVariable('AZURE_CLIENT_SECRET')
    $isLocalPack = $Arguments.Count -ge 2 -and
        $Arguments[0] -eq 'app' -and
        $Arguments[1] -eq 'pack' -and
        [string]::IsNullOrWhiteSpace($GitAuthorizationUrl)
    $localPackWithoutCredentials = $isLocalPack -and [string]::IsNullOrWhiteSpace($clientSecret)
    if (-not $localPackWithoutCredentials -and
        ([string]::IsNullOrWhiteSpace($clientId) -or [string]::IsNullOrWhiteSpace($tenantId))) {
        throw 'AZURE_CLIENT_ID and AZURE_TENANT_ID are required for CMR pipeline authentication.'
    }
    if (-not $localPackWithoutCredentials -and [string]::IsNullOrWhiteSpace($clientSecret)) {
        throw 'CMR API operations require AZURE_CLIENT_SECRET for the CLI service-principal mode. Public-cloud tests rejected both workload-identity and client-secret app-only access with HTTP 403; client-secret "ms app deploy" was rejected at uploadBuild with a user-delegated credential message. The action metadata currently limits supported end-to-end flow to the test cloud, which has not been tested against a reachable test-cloud environment. Local "ms app pack" can run without credentials.'
    }

    $resolvedCliVersion = Resolve-CmrCliVersion -VersionSpecifier $CliVersion -NodeVersion $NodeVersion
    $runtime = Get-CmrNodeRuntime -VersionSpecifier $NodeVersion
    $environmentNames = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @(
        'PATH',
        'MS_CLI_USE_SP_AUTH',
        'MS_CLI_SP_CLIENT_ID',
        'MS_CLI_SP_CLIENT_SECRET',
        'MS_CLI_SP_TENANT_ID',
        'MS_CLI_USE_HTTP_FORWARD',
        'MS_CLI_HTTP_FORWARD_URL',
        'MS_CLI_HTTP_FORWARD_AUTH_TOKEN',
        'MS_CLI_HTTP_FORWARD_TENANT_ID',
        'MS_CLI_REMOTE_TELEMETRY',
        'MS_CLI_CONSOLE_TELEMETRY',
        'CI',
        'GIT_CONFIG_COUNT',
        'GCM_CREDENTIAL_STORE'
    )) {
        $environmentNames.Add($name)
    }
    $previousEnvironment = @{}
    foreach ($name in $environmentNames) {
        $previousEnvironment[$name] = [System.Environment]::GetEnvironmentVariable($name, 'Process')
    }

    $gitConfigKeyName = $null
    $gitConfigValueName = $null
    $oldErrorActionPreference = $ErrorActionPreference
    $output = @()
    $exitCode = 0
    try {
        $pathSeparator = [System.IO.Path]::PathSeparator
        $env:PATH = "$($runtime.NodeDirectory)$pathSeparator$env:PATH"
        $env:MS_CLI_REMOTE_TELEMETRY = 'false'
        $env:MS_CLI_CONSOLE_TELEMETRY = 'false'
        $env:GCM_CREDENTIAL_STORE = 'cache'

        $accessToken = $null
        if ($localPackWithoutCredentials) {
            # The CLI treats CI=true as an implicit service-principal requirement, even for local packing.
            $env:CI = $null
            $env:MS_CLI_USE_SP_AUTH = $null
            $env:MS_CLI_SP_CLIENT_ID = $null
            $env:MS_CLI_SP_CLIENT_SECRET = $null
            $env:MS_CLI_SP_TENANT_ID = $null
        }
        else {
            $env:MS_CLI_USE_SP_AUTH = 'true'
            $env:MS_CLI_SP_CLIENT_ID = $clientId
            $env:MS_CLI_SP_CLIENT_SECRET = $clientSecret
            $env:MS_CLI_SP_TENANT_ID = $tenantId
        }
        $env:MS_CLI_USE_HTTP_FORWARD = $null
        $env:MS_CLI_HTTP_FORWARD_URL = $null
        $env:MS_CLI_HTTP_FORWARD_AUTH_TOKEN = $null
        $env:MS_CLI_HTTP_FORWARD_TENANT_ID = $null

        if (-not [string]::IsNullOrWhiteSpace($GitAuthorizationUrl)) {
            Assert-CmrManagedGitUrl -Url $GitAuthorizationUrl
            if ([string]::IsNullOrWhiteSpace($accessToken)) {
                $accessToken = Get-PowerPlatformApiAccessToken
            }
            $existingCount = 0
            if (-not [string]::IsNullOrWhiteSpace($env:GIT_CONFIG_COUNT) -and
                -not [int]::TryParse($env:GIT_CONFIG_COUNT, [ref]$existingCount)) {
                throw 'GIT_CONFIG_COUNT is invalid; cannot add the CMR managed Git authorization header.'
            }
            $gitConfigKeyName = "GIT_CONFIG_KEY_$existingCount"
            $gitConfigValueName = "GIT_CONFIG_VALUE_$existingCount"
            $environmentNames.Add($gitConfigKeyName)
            $environmentNames.Add($gitConfigValueName)
            $previousEnvironment[$gitConfigKeyName] = [System.Environment]::GetEnvironmentVariable($gitConfigKeyName, 'Process')
            $previousEnvironment[$gitConfigValueName] = [System.Environment]::GetEnvironmentVariable($gitConfigValueName, 'Process')
            $env:GIT_CONFIG_COUNT = [string]($existingCount + 1)
            [System.Environment]::SetEnvironmentVariable($gitConfigKeyName, "http.$GitAuthorizationUrl.extraheader", 'Process')
            [System.Environment]::SetEnvironmentVariable($gitConfigValueName, "AUTHORIZATION: bearer $accessToken", 'Process')
        }

        Push-Location -LiteralPath $WorkingDirectory
        try {
            $npm = Get-Command npm -ErrorAction Stop
            $commandArguments = @('exec', '--yes', '--package', "@microsoft/cmr-cli@$resolvedCliVersion", '--', 'ms') + $Arguments
            $ErrorActionPreference = 'Continue'
            $output = @(& $npm.Source @commandArguments 2>&1)
            $exitCode = $LASTEXITCODE
        }
        finally {
            Pop-Location
        }
    }
    finally {
        $ErrorActionPreference = $oldErrorActionPreference
        foreach ($name in $environmentNames) {
            [System.Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
        }
    }

    $outputText = ($output | ForEach-Object { [string]$_ }) -join "`n"
    if ($exitCode -ne 0) {
        $safeOutput = ConvertTo-CmrSafeMessage -Message $outputText
        throw "CMR CLI command '$($Arguments[0])' failed with exit code $exitCode. $safeOutput"
    }
    return $outputText
}

function Invoke-CmrGitCommand {
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [string]$GitAuthorizationUrl,

        [string]$AccessToken
    )

    $git = Get-Command git -ErrorAction Stop
    $gitArguments = @('-C', $WorkingDirectory) + $Arguments
    $authorizationKeyName = $null
    $authorizationValueName = $null
    $previousValues = @{}
    $exitCode = 0
    $output = @()
    $oldErrorActionPreference = $ErrorActionPreference

    if (-not [string]::IsNullOrWhiteSpace($GitAuthorizationUrl)) {
        Assert-CmrManagedGitUrl -Url $GitAuthorizationUrl
        if ([string]::IsNullOrWhiteSpace($AccessToken)) {
            throw 'An access token is required when pushing to a CMR managed Git repository.'
        }
        $existingCount = 0
        if (-not [string]::IsNullOrWhiteSpace($env:GIT_CONFIG_COUNT) -and
            -not [int]::TryParse($env:GIT_CONFIG_COUNT, [ref]$existingCount)) {
            throw 'GIT_CONFIG_COUNT is invalid; cannot add the CMR managed Git authorization header.'
        }
        $authorizationKeyName = "GIT_CONFIG_KEY_$existingCount"
        $authorizationValueName = "GIT_CONFIG_VALUE_$existingCount"
        foreach ($name in @('GIT_CONFIG_COUNT', $authorizationKeyName, $authorizationValueName)) {
            $previousValues[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        }
        [Environment]::SetEnvironmentVariable('GIT_CONFIG_COUNT', [string]($existingCount + 1), 'Process')
        [Environment]::SetEnvironmentVariable($authorizationKeyName, "http.$GitAuthorizationUrl.extraheader", 'Process')
        [Environment]::SetEnvironmentVariable($authorizationValueName, "AUTHORIZATION: bearer $AccessToken", 'Process')
    }

    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $git.Source @gitArguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldErrorActionPreference
        foreach ($name in $previousValues.Keys) {
            [Environment]::SetEnvironmentVariable($name, $previousValues[$name], 'Process')
        }
    }

    if ($exitCode -ne 0) {
        $safeOutput = ConvertTo-CmrSafeMessage -Message (($output | ForEach-Object { [string]$_ }) -join "`n")
        throw "CMR Git command '$($Arguments[0])' failed with exit code $exitCode. $safeOutput"
    }
    return @($output | ForEach-Object { [string]$_ })
}

function Resolve-CmrEnvironmentId {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$EnvironmentContext
    )

    if (-not [string]::IsNullOrWhiteSpace([string]$EnvironmentContext['EnvironmentId'])) {
        return [string]$EnvironmentContext['EnvironmentId']
    }
    if ([string]::IsNullOrWhiteSpace($env:DATAVERSE_URL)) {
        throw 'DATAVERSE_URL is required to resolve the target CMR environment.'
    }

    $whoAmI = Get-DataverseWhoAmI
    $organizationId = [string]$whoAmI.OrganizationId
    if ([string]::IsNullOrWhiteSpace($organizationId)) {
        throw 'Dataverse WhoAmI returned no organization ID; cannot resolve the CMR environment.'
    }
    $accessToken = Get-PowerPlatformApiAccessToken
    $EnvironmentContext['EnvironmentId'] = Resolve-PowerPlatformEnvironmentId -OrganizationId $organizationId -AccessToken $accessToken
    return [string]$EnvironmentContext['EnvironmentId']
}

function Get-CmrPlatformManagedRepoType {
    param([string]$RepoType)

    $normalized = ($RepoType -replace '[^a-z]', '').ToLowerInvariant()
    return $normalized -in @('native', 'platformmanagedgitrepository')
}

function Get-CmrNoRepositoryType {
    param([string]$RepoType)

    $normalized = ($RepoType -replace '[^a-z]', '').ToLowerInvariant()
    return $normalized -in @('none', 'externallyprovidedbuild', 'externallyprovidedbuildnosource')
}

function Export-CmrApp {
    <#
    .SYNOPSIS
        Synchronizes configured platform-managed CMR projects into the source tree.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Config,

        [Parameter(Mandatory)]
        [string]$SourceDirectory
    )

    $entries = @(Get-CmrAppEntry -Config $Config -BaseDirectory $SourceDirectory -AllowMissingProject)
    if ($entries.Count -eq 0) {
        return
    }
    $Config['cmrCliVersion'] = Resolve-CmrCliVersion -VersionSpecifier ([string]$Config.cmrCliVersion) -NodeVersion ([string]$Config.cmrNodeVersion)
    $environmentContext = @{}
    $targetNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($entry in $entries) {
        $localConfigPath = Join-Path $entry.AppPath 'ms.config.json'
        $sourceAppId = $entry.ConfiguredAppId
        $sourceEnvironmentId = ''
        if (Test-Path -LiteralPath $entry.AppPath -PathType Container) {
            if (Test-Path -LiteralPath $localConfigPath -PathType Leaf) {
                $localDefinition = Get-CmrAppDefinition -Entry $entry
                $sourceAppId = $localDefinition.AppId
                $sourceEnvironmentId = $localDefinition.EnvironmentId
            }
            elseif (@(Get-ChildItem -LiteralPath $entry.AppPath -Force).Count -gt 0) {
                throw "CMR app path '$($entry.RelativePath)' contains files but no ms.config.json."
            }
        }
        if ([string]::IsNullOrWhiteSpace($sourceAppId)) {
            throw "CMR app path '$($entry.RelativePath)' must contain ms.config.json or configure appId for its initial export."
        }
        if ([string]::IsNullOrWhiteSpace($sourceEnvironmentId)) {
            $sourceEnvironmentId = Resolve-CmrEnvironmentId -EnvironmentContext $environmentContext
        }

        $infoOutput = Invoke-CmrCli `
            -Arguments @('app', 'info', '--app', $sourceAppId, '--environment-id', $sourceEnvironmentId, '--non-interactive', '--json') `
            -WorkingDirectory $SourceDirectory `
            -CliVersion ([string]$Config.cmrCliVersion) `
            -NodeVersion ([string]$Config.cmrNodeVersion)
        $appInfo = ConvertFrom-CmrCliOutput -Output $infoOutput -Operation 'app info'
        if (-not (Get-CmrPlatformManagedRepoType -RepoType ([string]$appInfo['repoType']))) {
            throw "CMR app '$($entry.RelativePath)' is not bound to a platform-managed Git repository."
        }

        $targetDisplayName = if ([string]::IsNullOrWhiteSpace($entry.TargetDisplayName)) {
            "$([string]$appInfo['displayName']) (ALM4Dataverse)"
        }
        else {
            $entry.TargetDisplayName
        }
        if ([string]::IsNullOrWhiteSpace($targetDisplayName) -or -not $targetNames.Add($targetDisplayName)) {
            throw "CMR apps must have unique non-empty target display names; '$targetDisplayName' is duplicated or empty."
        }

        $cloneUrl = [string]$appInfo['cloneUrl']
        Assert-CmrManagedGitUrl -Url $cloneUrl
        $parentDirectory = Split-Path -Parent $entry.AppPath
        New-Item -ItemType Directory -Path $parentDirectory -Force | Out-Null
        $stagingPath = Join-Path $parentDirectory ".cmr-export-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $stagingPath | Out-Null
        $backupPath = $null
        try {
            $null = Invoke-CmrCli `
                -Arguments @('app', 'clone', $stagingPath, '--app', $sourceAppId, '--environment-id', $sourceEnvironmentId, '--non-interactive', '--json') `
                -WorkingDirectory $SourceDirectory `
                -CliVersion ([string]$Config.cmrCliVersion) `
                -NodeVersion ([string]$Config.cmrNodeVersion) `
                -GitAuthorizationUrl $cloneUrl

            $clonedConfigPath = Join-Path $stagingPath 'ms.config.json'
            if (-not (Test-Path -LiteralPath $clonedConfigPath -PathType Leaf)) {
                throw "CMR CLI did not create ms.config.json while exporting '$($entry.RelativePath)'."
            }
            $clonedConfig = Get-Content -LiteralPath $clonedConfigPath -Raw | ConvertFrom-Json -AsHashtable
            if ([string]$clonedConfig['appId'] -ne $sourceAppId -or [string]$clonedConfig['repoType'] -ne 'native') {
                throw "CMR CLI cloned a different app or repository type for '$($entry.RelativePath)'."
            }

            $gitMetadataPath = Join-Path $stagingPath '.git'
            if (Test-Path -LiteralPath $gitMetadataPath) {
                Remove-Item -LiteralPath $gitMetadataPath -Recurse -Force
            }
            if (Test-Path -LiteralPath $entry.AppPath -PathType Container) {
                $backupPath = "$($entry.AppPath).cmr-backup-$([guid]::NewGuid().ToString('N'))"
                Move-Item -LiteralPath $entry.AppPath -Destination $backupPath
            }
            try {
                Move-Item -LiteralPath $stagingPath -Destination $entry.AppPath
            }
            catch {
                if ($backupPath -and (Test-Path -LiteralPath $backupPath -PathType Container)) {
                    Move-Item -LiteralPath $backupPath -Destination $entry.AppPath
                    $backupPath = $null
                }
                throw
            }
            if ($backupPath -and (Test-Path -LiteralPath $backupPath -PathType Container)) {
                Remove-Item -LiteralPath $backupPath -Recurse -Force
                $backupPath = $null
            }

            Write-Host "Exported CMR app source to '$($entry.RelativePath)' for target '$targetDisplayName'."
        }
        finally {
            if (Test-Path -LiteralPath $stagingPath -PathType Container) {
                Remove-Item -LiteralPath $stagingPath -Recurse -Force
            }
            if ($backupPath -and (Test-Path -LiteralPath $backupPath -PathType Container)) {
                if (-not (Test-Path -LiteralPath $entry.AppPath -PathType Container)) {
                    Move-Item -LiteralPath $backupPath -Destination $entry.AppPath
                }
                else {
                    Remove-Item -LiteralPath $backupPath -Recurse -Force
                }
            }
        }
    }
}

function Copy-CmrBuildOutput {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Definition,

        [Parameter(Mandatory)]
        [string]$ArtifactStagingDirectory
    )

    $buildRoot = Get-CodeAppBuildRoot -CodeAppPath $Definition.AppPath -BuildPath $Definition.BuildPath
    $entryPoint = [System.IO.Path]::GetFullPath((Join-Path $buildRoot $Definition.BuildEntryPoint))
    $buildPrefix = $buildRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) +
        [System.IO.Path]::DirectorySeparatorChar
    if ([System.IO.Path]::IsPathRooted($Definition.BuildEntryPoint) -or
        $Definition.BuildEntryPoint -split '[/\\]' -contains '..' -or
        -not $entryPoint.StartsWith($buildPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $entryPoint -PathType Leaf)) {
        throw "CMR app '$($Definition.RelativePath)' did not produce its configured build entry point."
    }

    $builtFiles = @(Get-ChildItem -LiteralPath $buildRoot -Recurse -Force)
    foreach ($item in $builtFiles) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "CMR app '$($Definition.RelativePath)' build output contains a linked path."
        }
    }

    $destinationRoot = Join-Path $ArtifactStagingDirectory $Definition.RelativePath
    if (Test-Path -LiteralPath $destinationRoot) {
        Remove-Item -LiteralPath $destinationRoot -Recurse -Force
    }
    $destinationBuildRoot = Join-Path $destinationRoot $Definition.BuildPath
    New-Item -ItemType Directory -Path $destinationBuildRoot -Force | Out-Null
    foreach ($item in (Get-ChildItem -LiteralPath $buildRoot -Force)) {
        Copy-Item -LiteralPath $item.FullName -Destination $destinationBuildRoot -Recurse -Force
    }

    $manifest = [ordered]@{
        schemaVersion = 1
        schema = $Definition.Schema
        targetDisplayName = $Definition.TargetDisplayName
        deploymentMode = $Definition.DeploymentMode
        buildPath = $Definition.BuildPath
        buildCommand = $Definition.BuildCommand
        buildEntryPoint = $Definition.BuildEntryPoint
        cloud = $Definition.Cloud
        version = $Definition.Version
        dataSources = @($Definition.DataSources | ForEach-Object {
                [ordered]@{
                    connectorId = $_.ConnectorId
                    tables = @($_.Tables)
                }
            })
    }
    $manifestPath = Join-Path $destinationRoot $script:CmrArtifactManifestFileName
    $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding utf8

    if ($Definition.DeploymentMode -eq 'source') {
        Copy-CmrSourceCode -Definition $Definition -DestinationRoot $destinationRoot
    }
}

function Copy-CmrSourceCode {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Definition,

        [Parameter(Mandatory)]
        [string]$DestinationRoot
    )

    $sourceRoot = Join-Path $DestinationRoot 'source'
    New-Item -ItemType Directory -Path $sourceRoot -Force | Out-Null
    $projectRoot = [System.IO.Path]::GetFullPath($Definition.AppPath)
    $buildRoot = [System.IO.Path]::GetFullPath($Definition.BuildRoot)
    $buildPrefix = $buildRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) +
        [System.IO.Path]::DirectorySeparatorChar
    $copiedFileCount = 0

    foreach ($item in (Get-ChildItem -LiteralPath $projectRoot -Recurse -Force)) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "CMR app '$($Definition.RelativePath)' source contains a linked or reparse path '$($item.FullName)'."
        }

        $relativePath = [System.IO.Path]::GetRelativePath($projectRoot, $item.FullName)
        $segments = $relativePath -split '[/\\]'
        if ($segments -contains '.git' -or $segments -contains 'node_modules') {
            continue
        }
        if ($item.PSIsContainer) {
            continue
        }
        if ($relativePath -ieq 'ms.config.json') {
            continue
        }

        $filePath = [System.IO.Path]::GetFullPath($item.FullName)
        if ($filePath.StartsWith($buildPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
            $filePath.Equals($buildRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        if (Test-CodeAppRuntimeFileName -Name ([System.IO.Path]::GetFileName($relativePath))) {
            throw "CMR app '$($Definition.RelativePath)' source contains an unsafe file '$relativePath'."
        }

        $destinationPath = Join-Path $sourceRoot $relativePath
        $destinationDirectory = Split-Path -Parent $destinationPath
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        Copy-Item -LiteralPath $item.FullName -Destination $destinationPath -Force
        $copiedFileCount++
    }

    if ($copiedFileCount -eq 0) {
        throw "CMR app '$($Definition.RelativePath)' contains no source files to stage."
    }
}

function Invoke-CmrNpmCommand {
    param(
        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory)]
        [string]$NodeVersion,

        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $runtime = Get-CmrNodeRuntime -VersionSpecifier $NodeVersion
    $oldPath = $env:PATH
    $pathSeparator = [System.IO.Path]::PathSeparator
    $env:PATH = "$($runtime.NodeDirectory)$pathSeparator$oldPath"
    Push-Location -LiteralPath $WorkingDirectory
    try {
        Invoke-CheckedNativeCommand -Command $runtime.NpmPath -Arguments $Arguments
    }
    finally {
        Pop-Location
        $env:PATH = $oldPath
    }
}

function Build-CmrApp {
    <#
    .SYNOPSIS
        Builds configured CMR apps and stages only client assets and safe metadata.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Config,

        [Parameter(Mandatory)]
        [string]$SourceDirectory,

        [Parameter(Mandatory)]
        [string]$ArtifactStagingDirectory
    )

    $entries = @(Get-CmrAppEntry -Config $Config -BaseDirectory $SourceDirectory)
    if ($entries.Count -gt 0) {
        $Config['cmrCliVersion'] = Resolve-CmrCliVersion -VersionSpecifier ([string]$Config.cmrCliVersion) -NodeVersion ([string]$Config.cmrNodeVersion)
    }
    $definitions = @($entries | ForEach-Object { Get-CmrAppDefinition -Entry $_ })
    $targetNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($definition in $definitions) {
        if (-not $targetNames.Add($definition.TargetDisplayName)) {
            throw "Duplicate CMR target display name '$($definition.TargetDisplayName)'."
        }

        $packageJsonPath = Join-Path $definition.AppPath 'package.json'
        $lockPath = Join-Path $definition.AppPath 'package-lock.json'
        $shrinkwrapPath = Join-Path $definition.AppPath 'npm-shrinkwrap.json'
        if (-not (Test-Path -LiteralPath $packageJsonPath -PathType Leaf)) {
            throw "CMR app '$($definition.RelativePath)' must contain package.json."
        }
        if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf) -and
            -not (Test-Path -LiteralPath $shrinkwrapPath -PathType Leaf)) {
            throw "CMR app '$($definition.RelativePath)' must contain package-lock.json or npm-shrinkwrap.json."
        }

        Write-Host "##[group]Building CMR app: $($definition.RelativePath)"
        Invoke-CmrNpmCommand `
            -WorkingDirectory $definition.AppPath `
            -NodeVersion ([string]$Config.cmrNodeVersion) `
            -Arguments @('ci')
        $null = Invoke-CmrCli `
            -Arguments @('app', 'pack', '--non-interactive', '--json') `
            -WorkingDirectory $definition.AppPath `
            -CliVersion ([string]$Config.cmrCliVersion) `
            -NodeVersion ([string]$Config.cmrNodeVersion)
        Copy-CmrBuildOutput -Definition $definition -ArtifactStagingDirectory $ArtifactStagingDirectory
        Write-Host "##[endgroup]"
    }
}

function Read-CmrArtifactManifest {
    param([Parameter(Mandatory)][string]$AppArtifactPath)

    $manifestPath = Join-Path $AppArtifactPath $script:CmrArtifactManifestFileName
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "CMR build metadata was not found at '$manifestPath'. Rebuild the artifact with a current ALM4Dataverse version."
    }
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
    }
    catch {
        throw "CMR build metadata at '$manifestPath' is invalid JSON. $($_.Exception.Message)"
    }
    if ($manifest -isnot [System.Collections.IDictionary] -or $manifest['schemaVersion'] -ne 1) {
        throw "CMR build metadata at '$manifestPath' has an unsupported schema. Rebuild the artifact with a current ALM4Dataverse version."
    }

    foreach ($field in @('targetDisplayName', 'buildPath', 'buildEntryPoint', 'cloud')) {
        if ([string]::IsNullOrWhiteSpace([string]$manifest[$field])) {
            throw "CMR build metadata at '$manifestPath' is missing '$field'."
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$manifest['deploymentMode'])) {
        $manifest['deploymentMode'] = 'artifact'
    }
    if ([string]$manifest['deploymentMode'] -notin @('artifact', 'source')) {
        throw "CMR build metadata at '$manifestPath' has an unsupported deploymentMode."
    }
    if ($manifest['deploymentMode'] -eq 'source' -and [string]::IsNullOrWhiteSpace([string]$manifest['buildCommand'])) {
        throw "CMR build metadata at '$manifestPath' is missing 'buildCommand' for source deployment."
    }
    if ([System.IO.Path]::IsPathRooted([string]$manifest['buildPath']) -or
        [string]$manifest['buildPath'] -split '[/\\]' -contains '..') {
        throw "CMR build metadata at '$manifestPath' has an unsafe buildPath."
    }
    if ([System.IO.Path]::IsPathRooted([string]$manifest['buildEntryPoint']) -or
        [string]$manifest['buildEntryPoint'] -split '[/\\]' -contains '..') {
        throw "CMR build metadata at '$manifestPath' has an unsafe buildEntryPoint."
    }

    $dataSources = $manifest['dataSources']
    if ($null -eq $dataSources) {
        $manifest['dataSources'] = @()
    }
    elseif ($dataSources -isnot [array]) {
        throw "CMR build metadata at '$manifestPath' has invalid dataSources."
    }
    foreach ($dataSource in $manifest['dataSources']) {
        if ($dataSource -isnot [System.Collections.IDictionary] -or
            [string]$dataSource['connectorId'] -ne 'shared_commondataserviceforapps' -or
            $dataSource['tables'] -isnot [array] -or
            @($dataSource['tables'] | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
            throw "CMR build metadata at '$manifestPath' contains an unsupported data source."
        }
    }
    return $manifest
}

function Get-CmrTargetApp {
    param(
        [Parameter(Mandatory)]
        [string]$TargetDisplayName,

        [Parameter(Mandatory)]
        [string]$DeploymentMode,

        [Parameter(Mandatory)]
        [string]$EnvironmentId,

        [Parameter(Mandatory)]
        [string]$Cloud,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory)]
        [string]$CliVersion,

        [Parameter(Mandatory)]
        [string]$NodeVersion
    )

    $listOutput = Invoke-CmrCli `
        -Arguments @('app', 'list', '--environment-id', $EnvironmentId, '--cloud', $Cloud, '--non-interactive', '--json') `
        -WorkingDirectory $WorkingDirectory `
        -CliVersion $CliVersion `
        -NodeVersion $NodeVersion
    $appList = ConvertFrom-CmrCliOutput -Output $listOutput -Operation 'app list'
    $appMatches = @($appList['items'] | Where-Object {
            [string]$_.displayName -ieq $TargetDisplayName
        })
    if ($appMatches.Count -gt 1) {
        throw "Multiple CMR apps named '$TargetDisplayName' exist in the target environment."
    }
    if ($appMatches.Count -eq 0) {
        return $null
    }

    $appId = [string]$appMatches[0].appId
    $parsedAppId = [guid]::Empty
    if (-not [guid]::TryParse($appId, [ref]$parsedAppId) -or $parsedAppId -eq [guid]::Empty) {
        throw "CMR app list returned an invalid app identifier for '$TargetDisplayName'."
    }
    $infoOutput = Invoke-CmrCli `
        -Arguments @('app', 'info', '--app', $parsedAppId.ToString(), '--environment-id', $EnvironmentId, '--cloud', $Cloud, '--non-interactive', '--json') `
        -WorkingDirectory $WorkingDirectory `
        -CliVersion $CliVersion `
        -NodeVersion $NodeVersion
    $appInfo = ConvertFrom-CmrCliOutput -Output $infoOutput -Operation 'app info'
    $targetRepoType = [string]$appInfo['repoType']
    if ($DeploymentMode -eq 'source' -and -not (Get-CmrPlatformManagedRepoType -RepoType $targetRepoType)) {
        throw "CMR target app '$TargetDisplayName' must use a platform-managed repository for source deployment."
    }
    if ($DeploymentMode -eq 'artifact' -and -not (Get-CmrNoRepositoryType -RepoType $targetRepoType)) {
        throw "CMR target app '$TargetDisplayName' must be an externally provided build app with no source repository."
    }
    if ([string]$appInfo['environmentId'] -ne $EnvironmentId) {
        throw "CMR target app '$TargetDisplayName' belongs to a different environment."
    }

    [pscustomobject]@{
        AppId = $parsedAppId.ToString()
        DisplayName = [string]$appInfo['displayName']
        RepoType = $targetRepoType
        CloneUrl = [string]$appInfo['cloneUrl']
    }
}

function Get-CmrTargetProjectConfig {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Manifest,

        [Parameter(Mandatory)]
        [string]$TargetDisplayName,

        [Parameter(Mandatory)]
        [string]$AppId,

        [Parameter(Mandatory)]
        [string]$EnvironmentId,

        [Parameter(Mandatory)]
        [string]$DeploymentMode
    )

    $projectConfig = [ordered]@{}
    if (-not [string]::IsNullOrWhiteSpace([string]$Manifest['schema'])) {
        $projectConfig['$schema'] = [string]$Manifest['schema']
    }
    $projectConfig['appDisplayName'] = $TargetDisplayName
    $projectConfig['appId'] = $AppId
    $buildCommand = if ([string]::IsNullOrWhiteSpace([string]$Manifest['buildCommand'])) { 'npm run build' } else { [string]$Manifest['buildCommand'] }
    $projectConfig['buildCommand'] = $buildCommand
    $projectConfig['buildEntryPoint'] = [string]$Manifest['buildEntryPoint']
    $projectConfig['buildPath'] = [string]$Manifest['buildPath']
    $projectConfig['cloud'] = [string]$Manifest['cloud']
    $projectConfig['environmentId'] = $EnvironmentId
    $projectConfig['repoType'] = if ($DeploymentMode -eq 'source') { 'native' } else { 'none' }
    if (-not [string]::IsNullOrWhiteSpace([string]$Manifest['version'])) {
        $projectConfig['version'] = [string]$Manifest['version']
    }
    $projectConfig['connectionReferences'] = @{}
    return $projectConfig
}

function Write-CmrArtifactZip {
    param(
        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory)]
        [string]$BuildPath,

        [Parameter(Mandatory)]
        [string]$ArchivePath
    )

    $buildRoot = Get-CodeAppBuildRoot -CodeAppPath $WorkingDirectory -BuildPath $BuildPath
    if (-not (Test-Path -LiteralPath (Join-Path $WorkingDirectory 'ms.config.json') -PathType Leaf)) {
        throw "CMR deploy project '$WorkingDirectory' has no ms.config.json."
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::Open($ArchivePath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in (Get-ChildItem -LiteralPath $buildRoot -Recurse -File -Force)) {
            if (($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'CMR deploy artifact contains a linked build output file.'
            }
            $relativePath = [System.IO.Path]::GetRelativePath($WorkingDirectory, $file.FullName).Replace('\', '/')
            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $archive,
                $file.FullName,
                $relativePath,
                [System.IO.Compression.CompressionLevel]::Optimal
            )
        }
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $archive,
            (Join-Path $WorkingDirectory 'ms.config.json'),
            'ms.config.json',
            [System.IO.Compression.CompressionLevel]::Optimal
        )
    }
    finally {
        $archive.Dispose()
    }
}

function Copy-CmrSourceArtifact {
    param(
        [Parameter(Mandatory)]
        [string]$AppArtifactPath,

        [Parameter(Mandatory)]
        [string]$TargetProjectPath
    )

    $sourceRoot = Join-Path $AppArtifactPath 'source'
    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
        throw "CMR source deployment files were not found at '$sourceRoot'. Rebuild the artifact with deploymentMode 'source'."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot 'package.json') -PathType Leaf) -or
        (-not (Test-Path -LiteralPath (Join-Path $sourceRoot 'package-lock.json') -PathType Leaf) -and
            -not (Test-Path -LiteralPath (Join-Path $sourceRoot 'npm-shrinkwrap.json') -PathType Leaf))) {
        throw "CMR source deployment artifact at '$sourceRoot' must contain package.json and a lock file."
    }

    foreach ($item in (Get-ChildItem -LiteralPath $TargetProjectPath -Force)) {
        if ($item.Name -ne '.git') {
            Remove-Item -LiteralPath $item.FullName -Recurse -Force
        }
    }

    foreach ($item in (Get-ChildItem -LiteralPath $sourceRoot -Recurse -Force)) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "CMR source deployment artifact contains a linked or reparse path '$($item.FullName)'."
        }
        if ($item.PSIsContainer) {
            continue
        }

        $relativePath = [System.IO.Path]::GetRelativePath($sourceRoot, $item.FullName)
        $excludedDirectoryNames = @($relativePath -split '[/\\]' | Where-Object { $_ -in @('.git', 'node_modules') })
        if ($relativePath -ieq 'ms.config.json' -or
            $excludedDirectoryNames.Count -gt 0 -or
            (Test-CodeAppRuntimeFileName -Name ([System.IO.Path]::GetFileName($relativePath)))) {
            throw "CMR source deployment artifact contains an excluded source file '$relativePath'. Rebuild the artifact."
        }
        $destinationPath = Join-Path $TargetProjectPath $relativePath
        $destinationDirectory = Split-Path -Parent $destinationPath
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        Copy-Item -LiteralPath $item.FullName -Destination $destinationPath -Force
    }
}

function Deploy-CmrApp {
    <#
    .SYNOPSIS
        Provisions environment-specific CMR targets and deploys their built assets.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Config,

        [Parameter(Mandatory)]
        [string]$ArtifactsPath,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$EnvironmentContext
    )

    $entries = @(Get-CmrAppEntry -Config $Config -BaseDirectory $ArtifactsPath)
    if ($entries.Count -eq 0) {
        return
    }
    $Config['cmrCliVersion'] = Resolve-CmrCliVersion -VersionSpecifier ([string]$Config.cmrCliVersion) -NodeVersion ([string]$Config.cmrNodeVersion)
    $environmentId = Resolve-CmrEnvironmentId -EnvironmentContext $EnvironmentContext
    $targetNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($entry in $entries) {
        $appArtifactPath = Assert-CodeAppPathHasNoReparsePoint -BaseDirectory $ArtifactsPath -Path $entry.AppPath
        $manifest = Read-CmrArtifactManifest -AppArtifactPath $appArtifactPath
        $targetDisplayName = if ([string]::IsNullOrWhiteSpace($entry.TargetDisplayName)) {
            [string]$manifest['targetDisplayName']
        }
        else {
            $entry.TargetDisplayName
        }
        if ($targetDisplayName -ne [string]$manifest['targetDisplayName']) {
            throw "Configured targetDisplayName for '$($entry.RelativePath)' does not match the built artifact; rebuild after changing cmrApps."
        }
        if (-not $targetNames.Add($targetDisplayName)) {
            throw "Duplicate CMR target display name '$targetDisplayName'."
        }

        $buildRoot = Get-CodeAppBuildRoot -CodeAppPath $appArtifactPath -BuildPath ([string]$manifest['buildPath'])
        $entryPoint = Join-Path $buildRoot ([string]$manifest['buildEntryPoint'])
        if (-not (Test-Path -LiteralPath $entryPoint -PathType Leaf)) {
            throw "CMR built assets for '$($entry.RelativePath)' are missing the configured entry point."
        }
        foreach ($item in (Get-ChildItem -LiteralPath $buildRoot -Recurse -Force)) {
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "CMR built assets for '$($entry.RelativePath)' contain a linked path."
            }
        }

        $workspace = Join-Path ([System.IO.Path]::GetTempPath()) "alm4d-cmr-deploy-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $workspace | Out-Null
        try {
            $targetApp = Get-CmrTargetApp `
                -TargetDisplayName $targetDisplayName `
                -DeploymentMode ([string]$manifest['deploymentMode']) `
                -EnvironmentId $environmentId `
                -Cloud ([string]$manifest['cloud']) `
                -WorkingDirectory $workspace `
                -CliVersion ([string]$Config.cmrCliVersion) `
                -NodeVersion ([string]$Config.cmrNodeVersion)

            if ($null -eq $targetApp) {
                $createOutput = Invoke-CmrCli `
                    -Arguments @(
                        'app', 'create', $workspace,
                        '--display-name', $targetDisplayName,
                        '--environment-id', $environmentId,
                        '--repo', $(if ([string]$manifest['deploymentMode'] -eq 'source') { 'native' } else { 'none' }),
                        '--build-path', [string]$manifest['buildPath'],
                        '--build-entry-point', [string]$manifest['buildEntryPoint'],
                        '--cloud', [string]$manifest['cloud'],
                        '--non-interactive', '--json'
                    ) `
                    -WorkingDirectory $workspace `
                    -CliVersion ([string]$Config.cmrCliVersion) `
                    -NodeVersion ([string]$Config.cmrNodeVersion)
                $null = ConvertFrom-CmrCliOutput -Output $createOutput -Operation 'app create'
                $targetConfigPath = Join-Path $workspace 'ms.config.json'
                if (-not (Test-Path -LiteralPath $targetConfigPath -PathType Leaf)) {
                    throw "CMR app create did not create ms.config.json for '$targetDisplayName'."
                }
                $createdConfig = Get-Content -LiteralPath $targetConfigPath -Raw | ConvertFrom-Json -AsHashtable
                $createdAppId = [string]$createdConfig['appId']
                $parsedCreatedAppId = [guid]::Empty
                $createdRepoTypeValid = if ([string]$manifest['deploymentMode'] -eq 'source') {
                    Get-CmrPlatformManagedRepoType -RepoType ([string]$createdConfig['repoType'])
                }
                else {
                    Get-CmrNoRepositoryType -RepoType ([string]$createdConfig['repoType'])
                }
                if (-not $createdRepoTypeValid -or
                    -not [guid]::TryParse($createdAppId, [ref]$parsedCreatedAppId) -or
                    $parsedCreatedAppId -eq [guid]::Empty) {
                    throw "CMR app create returned an invalid app for deploymentMode '$($manifest['deploymentMode'])' and target '$targetDisplayName'."
                }
                $targetApp = [pscustomobject]@{
                    AppId = $parsedCreatedAppId.ToString()
                    DisplayName = $targetDisplayName
                    RepoType = [string]$createdConfig['repoType']
                    CloneUrl = ''
                    Created = $true
                }
            }

            if ([string]$manifest['deploymentMode'] -eq 'source') {
                if ($targetApp.Created) {
                    $infoOutput = Invoke-CmrCli `
                        -Arguments @('app', 'info', '--app', $targetApp.AppId, '--environment-id', $environmentId, '--cloud', [string]$manifest['cloud'], '--non-interactive', '--json') `
                        -WorkingDirectory $workspace `
                        -CliVersion ([string]$Config.cmrCliVersion) `
                        -NodeVersion ([string]$Config.cmrNodeVersion)
                    $targetInfo = ConvertFrom-CmrCliOutput -Output $infoOutput -Operation 'app info'
                    $targetApp.CloneUrl = [string]$targetInfo['cloneUrl']
                }
                else {
                    $null = Invoke-CmrCli `
                        -Arguments @('app', 'clone', $workspace, '--app', $targetApp.AppId, '--environment-id', $environmentId, '--non-interactive', '--json') `
                        -WorkingDirectory $workspace `
                        -CliVersion ([string]$Config.cmrCliVersion) `
                        -NodeVersion ([string]$Config.cmrNodeVersion)
                }
                Assert-CmrManagedGitUrl -Url ([string]$targetApp.CloneUrl)
                if (-not (Test-Path -LiteralPath (Join-Path $workspace '.git'))) {
                    throw "CMR source target '$targetDisplayName' did not provide its managed Git repository."
                }
                Copy-CmrSourceArtifact -AppArtifactPath $appArtifactPath -TargetProjectPath $workspace
            }

            $projectConfig = Get-CmrTargetProjectConfig `
                -Manifest $manifest `
                -TargetDisplayName $targetDisplayName `
                -AppId $targetApp.AppId `
                -EnvironmentId $environmentId `
                -DeploymentMode ([string]$manifest['deploymentMode'])
            $targetConfigPath = Join-Path $workspace 'ms.config.json'
            $projectConfig | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $targetConfigPath -Encoding utf8

            foreach ($dataSource in $manifest['dataSources']) {
                foreach ($tableName in $dataSource['tables']) {
                    $null = Invoke-CmrCli `
                        -Arguments @(
                            'app', 'add', 'data-source',
                            '--connector', [string]$dataSource['connectorId'],
                            '--as', 'table',
                            '--table', [string]$tableName,
                            '--dataverse-environment-id', $environmentId,
                            '--cloud', [string]$manifest['cloud'],
                            '--use-sso',
                            '--non-interactive', '--json'
                        ) `
                        -WorkingDirectory $workspace `
                        -CliVersion ([string]$Config.cmrCliVersion) `
                        -NodeVersion ([string]$Config.cmrNodeVersion)
                }
            }

            if ([string]$manifest['deploymentMode'] -eq 'source') {
                $gitPath = Join-Path $workspace '.git'
                if (-not (Test-Path -LiteralPath $gitPath)) {
                    throw "CMR source target '$targetDisplayName' has no Git repository."
                }
                $null = Invoke-CmrGitCommand -WorkingDirectory $workspace -Arguments @('add', '--all')
                $gitStatus = @(Invoke-CmrGitCommand -WorkingDirectory $workspace -Arguments @('status', '--porcelain'))
                if ($gitStatus.Count -gt 0) {
                    $null = Invoke-CmrGitCommand -WorkingDirectory $workspace -Arguments @('config', 'user.name', 'ALM4Dataverse')
                    $null = Invoke-CmrGitCommand -WorkingDirectory $workspace -Arguments @('config', 'user.email', 'alm4dataverse@users.noreply.github.com')
                    $null = Invoke-CmrGitCommand -WorkingDirectory $workspace -Arguments @('commit', '-m', 'Deploy app from ALM4Dataverse')
                }
                $branchOutput = @(Invoke-CmrGitCommand -WorkingDirectory $workspace -Arguments @('branch', '--show-current'))
                $branchName = if ($branchOutput.Count -gt 0) { [string]$branchOutput[-1] } else { '' }
                if ([string]::IsNullOrWhiteSpace($branchName)) {
                    throw "CMR source target '$targetDisplayName' has no current Git branch to deploy."
                }
                $accessToken = Get-PowerPlatformApiAccessToken
                $null = Invoke-CmrGitCommand `
                    -WorkingDirectory $workspace `
                    -Arguments @('push', '--set-upstream', [string]$targetApp.CloneUrl, $branchName) `
                    -GitAuthorizationUrl ([string]$targetApp.CloneUrl) `
                    -AccessToken $accessToken
                $commitOutput = @(Invoke-CmrGitCommand -WorkingDirectory $workspace -Arguments @('rev-parse', 'HEAD'))
                $commitSha = if ($commitOutput.Count -gt 0) { [string]$commitOutput[-1].Trim() } else { '' }
                if ($commitSha -notmatch '^[0-9a-f]{40,64}$') {
                    throw "CMR source target '$targetDisplayName' returned an invalid Git commit ID."
                }
                $null = Invoke-CmrCli `
                    -Arguments @('app', 'deploy', '--commit', $commitSha, '--non-interactive', '--json') `
                    -WorkingDirectory $workspace `
                    -CliVersion ([string]$Config.cmrCliVersion) `
                    -NodeVersion ([string]$Config.cmrNodeVersion)
            }
            else {
                $workspaceBuildRoot = Join-Path $workspace ([string]$manifest['buildPath'])
                New-Item -ItemType Directory -Path $workspaceBuildRoot -Force | Out-Null
                foreach ($file in (Get-ChildItem -LiteralPath $buildRoot -Force)) {
                    Copy-Item -LiteralPath $file.FullName -Destination $workspaceBuildRoot -Recurse -Force
                }
                $archivePath = Join-Path $workspace 'cmr-deploy.zip'
                Write-CmrArtifactZip -WorkingDirectory $workspace -BuildPath ([string]$manifest['buildPath']) -ArchivePath $archivePath
                try {
                    $null = Invoke-CmrCli `
                        -Arguments @('app', 'deploy', '--artifact', $archivePath, '--non-interactive', '--json') `
                        -WorkingDirectory $workspace `
                        -CliVersion ([string]$Config.cmrCliVersion) `
                        -NodeVersion ([string]$Config.cmrNodeVersion)
                }
                catch {
                    if ($_.Exception.Message -match 'AllowExternalArtifactDeployment') {
                        throw "CMR app '$targetDisplayName' cannot be deployed because AllowExternalArtifactDeployment is disabled in the target environment. Enable that environment setting and retry."
                    }
                    throw
                }
            }
            Write-Host "Deployed CMR app '$targetDisplayName'."
        }
        finally {
            if (Test-Path -LiteralPath $workspace -PathType Container) {
                Remove-Item -LiteralPath $workspace -Recurse -Force
            }
        }
    }
}
