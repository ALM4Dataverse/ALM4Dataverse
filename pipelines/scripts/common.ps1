<#
.SYNOPSIS
    Common functions for pipelines scripts.
.DESCRIPTION
    This script contains common functions used across various pipeline scripts
    such as build.ps1, deploy.ps1, and export.ps1.
#>

function Invoke-CheckedNativeCommand {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Command,
        [string[]]$Arguments = @(),
        [switch]$AllowFailure
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $Command @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "Native command '$Command' failed with exit code $exitCode."
    }
    foreach ($entry in $output) {
        [string]$entry
    }
}

function Merge-AlmConfigValue {
    param(
        $DefaultValue,
        $OverrideValue
    )

    if ($null -eq $DefaultValue) {
        return $OverrideValue
    }

    if ($null -eq $OverrideValue) {
        return $DefaultValue
    }

    if ($DefaultValue -is [array] -and $OverrideValue -is [array]) {
        return @(@($DefaultValue) + @($OverrideValue))
    }

    if ($DefaultValue -is [hashtable] -and $OverrideValue -is [hashtable]) {
        $merged = @{}
        foreach ($key in ($DefaultValue.Keys + $OverrideValue.Keys | Select-Object -Unique)) {
            $merged[$key] = Merge-AlmConfigValue -DefaultValue $DefaultValue[$key] -OverrideValue $OverrideValue[$key]
        }

        return $merged
    }

    return $OverrideValue
}

function Get-AlmConfig {
    param(
        [string]$BaseDirectory = ".",
        [bool]$LogConfig = $true
    )

    $defaultConfigPath = Join-Path -Path $PSScriptRoot -ChildPath ".." -AdditionalChildPath "..", "alm-config-defaults.psd1" | Resolve-Path | Select-Object -ExpandProperty Path

    $config = @{}

    Write-Host "##[group] Loading default configuration from $defaultConfigPath"
    $defaultConfig = Import-PowerShellDataFile -Path $defaultConfigPath
    Write-Host "##[endgroup]"

    # Load main config and merge
    $configPath = Join-Path $BaseDirectory "alm-config.psd1"
    if (-not (Test-Path $configPath)) {
        Write-Host "##[error]Configuration file not found: $configPath"
        throw "alm-config.psd1 not found at $configPath"
    }

    $mainConfig = Import-PowerShellDataFile -Path $configPath

    # Merge configs: mainConfig overrides defaultConfig, arrays are concatenated
    foreach ($key in $mainConfig.Keys) {
        if ($defaultConfig.ContainsKey($key)) {
            $config[$key] = Merge-AlmConfigValue -DefaultValue $defaultConfig[$key] -OverrideValue $mainConfig[$key]
        }
        else {
            $config[$key] = $mainConfig[$key]
        }
    }

    # Preserve any keys from default config that are not in main config
    foreach ($key in $defaultConfig.Keys) {
        if (-not $mainConfig.ContainsKey($key)) {
            $config[$key] = $defaultConfig[$key]
        }
    }

    $config["_main"] = $mainConfig
    $config["_defaults"] = $defaultConfig

    if ($LogConfig) { Write-Host "##[debug]Loaded configuration: $($config | ConvertTo-Json -Depth 20)" }

    return $config
}

function Resolve-AlmBranchBaseVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [string]$BranchName
    )

    if (-not $Config.ContainsKey('buildVersion') -or $Config.buildVersion -isnot [hashtable]) {
        throw "BUILD version configuration is missing. Add buildVersion.default and buildVersion.branches to alm-config-defaults.psd1 or alm-config.psd1."
    }

    $versionConfig = $Config.buildVersion
    if (-not $versionConfig.ContainsKey('default')) {
        throw "BUILD version configuration is missing buildVersion.default in alm-config-defaults.psd1 or alm-config.psd1."
    }

    $branch = $BranchName.Trim()
    if ($branch -match '^refs/heads/(?<name>.+)$') {
        $branch = $Matches.name
    }
    elseif ($branch -match '^refs/') {
        throw "BUILD versioning requires a branch ref; '$BranchName' is not a refs/heads branch."
    }
    if ([string]::IsNullOrWhiteSpace($branch)) {
        throw 'BUILD versioning requires a non-empty source branch.'
    }

    $majorMinor = [string]$versionConfig.default
    $hasBranchOverride = $false
    if ($versionConfig.ContainsKey('branches')) {
        if ($versionConfig.branches -isnot [hashtable]) {
            throw 'buildVersion.branches must be a hashtable of full branch names to MAJOR.MINOR values.'
        }

        foreach ($configuredBranch in $versionConfig.branches.Keys) {
            if ([string]$configuredBranch -ceq $branch) {
                $majorMinor = [string]$versionConfig.branches[$configuredBranch]
                $hasBranchOverride = $true
                break
            }
        }
    }

    if ($majorMinor -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
        throw "Invalid MAJOR.MINOR value '$majorMinor' for branch '$branch'. Use two non-negative SemVer integers, for example '1.4'."
    }

    $versionParts = $majorMinor.Split('.')
    [int]$major = 0
    [int]$minor = 0
    if (-not [int]::TryParse($versionParts[0], [ref]$major) -or
        -not [int]::TryParse($versionParts[1], [ref]$minor)) {
        throw "Invalid MAJOR.MINOR value '$majorMinor' for branch '$branch'. Dataverse solution version components must fit in a 32-bit integer."
    }

    return [pscustomobject]@{
        Major      = $major
        Build      = $minor
        MajorMinor = $majorMinor
        BranchName = $branch
        HasBranchOverride = $hasBranchOverride
    }
}

function Invoke-AlmGitCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'Git is required to reserve Dataverse solution versions.'
    }

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& git -C $RepositoryPath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        Output   = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    }
}

function Resolve-AlmDefaultBranchName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath,

        [string]$DefaultBranchName
    )

    if (-not [string]::IsNullOrWhiteSpace($DefaultBranchName)) {
        $branch = $DefaultBranchName.Trim()
        if ($branch -match '^refs/heads/(?<name>.+)$') {
            return $Matches.name
        }
        if ($branch -match '^refs/') {
            throw "Default branch '$DefaultBranchName' is not a refs/heads branch."
        }
        return $branch
    }

    $result = Invoke-AlmGitCommand -RepositoryPath $RepositoryPath -Arguments @('ls-remote', '--symref', 'origin', 'HEAD')
    if ($result.ExitCode -ne 0) {
        throw "Could not determine the repository default branch from origin/HEAD. $($result.Output)"
    }

    $match = [regex]::Match($result.Output, '(?m)^ref:\s+refs/heads/(?<name>.+)\s+HEAD$')
    if (-not $match.Success) {
        throw "Could not determine the repository default branch from origin/HEAD. Output: $($result.Output)"
    }

    return $match.Groups['name'].Value
}

function Get-NextAlmSolutionVersion {
    [CmdletBinding()]
    [OutputType([version])]
    param(
        [Parameter(Mandatory = $true)]
        [version]$Version,

        [Parameter(Mandatory = $true)]
        [bool]$IsAdditive
    )

    $minor = $Version.Minor
    $revision = $Version.Revision
    if ($IsAdditive) {
        if ($revision -ge [int]::MaxValue) {
            throw "Cannot increment solution revision beyond $([int]::MaxValue)."
        }
        $revision++
    }
    else {
        if ($minor -ge [int]::MaxValue) {
            throw "Cannot increment solution minor beyond $([int]::MaxValue)."
        }
        $minor++
        $revision = 0
    }

    return [version]::new($Version.Major, $minor, $Version.Build, $revision)
}

function Register-AlmSolutionVersion {
    [CmdletBinding()]
    [OutputType([version])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath,

        [Parameter(Mandatory = $true)]
        [string]$SolutionName,

        [Parameter(Mandatory = $true)]
        [version]$Version,

        [Parameter(Mandatory = $true)]
        [bool]$IsAdditive,

        [ValidateRange(1, 1000)]
        [int]$MaximumAttempts = 100
    )

    $candidateVersion = $Version
    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        $tagName = "alm4dv/solution-version/$SolutionName/$candidateVersion"
        $tagRef = "refs/tags/$tagName"
        $formatResult = Invoke-AlmGitCommand -RepositoryPath $RepositoryPath -Arguments @('check-ref-format', $tagRef)
        if ($formatResult.ExitCode -ne 0) {
            throw "Solution '$SolutionName' produced an invalid reservation tag '$tagName'. $($formatResult.Output)"
        }

        $remoteTag = Invoke-AlmGitCommand -RepositoryPath $RepositoryPath -Arguments @('ls-remote', '--refs', 'origin', $tagRef)
        if ($remoteTag.ExitCode -ne 0) {
            throw "Failed to check reservation tag '$tagName' on origin. $($remoteTag.Output)"
        }
        if (-not [string]::IsNullOrWhiteSpace($remoteTag.Output)) {
            Write-Host "[$SolutionName][Version] $candidateVersion is already reserved; selecting the next version."
            $candidateVersion = Get-NextAlmSolutionVersion -Version $candidateVersion -IsAdditive $IsAdditive
            continue
        }

        $localTag = Invoke-AlmGitCommand -RepositoryPath $RepositoryPath -Arguments @('show-ref', '--verify', '--quiet', $tagRef)
        if ($localTag.ExitCode -eq 0) {
            throw "Local reservation tag '$tagName' exists but is not present on origin. Remove or reconcile that local tag before exporting."
        }
        if ($localTag.ExitCode -ne 1) {
            throw "Failed to check local reservation tag '$tagName'. $($localTag.Output)"
        }

        $createTag = Invoke-AlmGitCommand -RepositoryPath $RepositoryPath -Arguments @('tag', $tagName, 'HEAD')
        if ($createTag.ExitCode -ne 0) {
            throw "Failed to create local reservation tag '$tagName'. $($createTag.Output)"
        }

        $refSpec = "${tagRef}:$tagRef"
        $pushTag = Invoke-AlmGitCommand -RepositoryPath $RepositoryPath -Arguments @('push', 'origin', $refSpec)
        if ($pushTag.ExitCode -eq 0) {
            return $candidateVersion
        }

        $deleteTag = Invoke-AlmGitCommand -RepositoryPath $RepositoryPath -Arguments @('tag', '-d', $tagName)
        if ($deleteTag.ExitCode -ne 0) {
            throw "Failed to remove local reservation tag '$tagName' after a rejected push. Push output: $($pushTag.Output). Cleanup output: $($deleteTag.Output)"
        }

        $remoteTag = Invoke-AlmGitCommand -RepositoryPath $RepositoryPath -Arguments @('ls-remote', '--refs', 'origin', $tagRef)
        if ($remoteTag.ExitCode -ne 0) {
            throw "Failed to verify reservation tag '$tagName' after a rejected push. Push output: $($pushTag.Output). Check output: $($remoteTag.Output)"
        }
        if (-not [string]::IsNullOrWhiteSpace($remoteTag.Output)) {
            Write-Host "[$SolutionName][Version] Another export reserved $candidateVersion concurrently; selecting the next version."
            $candidateVersion = Get-NextAlmSolutionVersion -Version $candidateVersion -IsAdditive $IsAdditive
            continue
        }

        throw "Failed to push reservation tag '$tagName'. $($pushTag.Output)"
    }

    throw "Could not reserve a solution version for '$SolutionName' after $MaximumAttempts attempts."
}

function Resolve-AlmBuildVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [string]$BranchName,

        [Parameter(Mandatory = $true)]
        [string]$RunNumber,

        [Parameter(Mandatory = $true)]
        [ValidateSet('github', 'azdo')]
        [string]$Provider
    )

    $branchBaseVersion = Resolve-AlmBranchBaseVersion -Config $Config -BranchName $BranchName
    $branch = $branchBaseVersion.BranchName
    $majorMinor = $branchBaseVersion.MajorMinor

    if ($RunNumber -notmatch '^(0|[1-9][0-9]*)$') {
        throw "CI run number '$RunNumber' cannot be used as a SemVer PATCH value."
    }

    $branchIdentifier = $branch.ToLowerInvariant() -replace '[^a-z0-9-]+', '-'
    $branchIdentifier = $branchIdentifier -replace '-{2,}', '-'
    $branchIdentifier = $branchIdentifier.Trim('-')
    if ([string]::IsNullOrWhiteSpace($branchIdentifier)) {
        throw "Source branch '$branch' cannot be converted to a SemVer prerelease identifier."
    }
    if ($branchIdentifier -match '^0[0-9]+$') {
        $branchIdentifier = "b$branchIdentifier"
    }

    $version = "$majorMinor.$RunNumber-$branchIdentifier"
    return [pscustomobject]@{
        Version       = $version
        TagName       = "v$version"
        BranchName    = $branch
        Provider      = $Provider
        RunNumber     = $RunNumber
    }
}

function Write-AlmBuildVersionInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArtifactsPath,

        [Parameter(Mandatory = $true)]
        [psobject]$BuildVersion,

        [Parameter(Mandatory = $true)]
        [string]$RunId,

        [Parameter(Mandatory = $true)]
        [string]$SourceCommit
    )

    if ($RunId -notmatch '^[0-9]+$') {
        throw "Build run ID '$RunId' must contain only digits."
    }
    if ($SourceCommit -notmatch '^[0-9a-fA-F]{40}$') {
        throw "Source commit '$SourceCommit' must be a 40-character Git SHA."
    }
    if (-not (Test-Path -LiteralPath $ArtifactsPath -PathType Container)) {
        throw "Artifacts directory '$ArtifactsPath' does not exist."
    }

    $metadata = [ordered]@{
        version       = $BuildVersion.Version
        tag            = $BuildVersion.TagName
        branch         = $BuildVersion.BranchName
        provider       = $BuildVersion.Provider
        runNumber      = $BuildVersion.RunNumber
        runId          = $RunId
        sourceCommit   = $SourceCommit.ToLowerInvariant()
    }
    $metadataPath = Join-Path $ArtifactsPath 'build-version.json'
    Set-Content -LiteralPath $metadataPath -Value ($metadata | ConvertTo-Json) -Encoding utf8
    return $metadataPath
}

    function Initialize-PacAuthentication {
        param(
            [string]$ProfileName = 'ALM4Dataverse-SolutionCheck',
            [switch]$Quiet
        )

        $pacCommand = Get-Command pac -ErrorAction SilentlyContinue
        if (-not $pacCommand) {
            throw "Power Apps CLI (pac) is not available on PATH. Ensure installdependencies.ps1 has run in this job before calling scripts that require PAC authentication."
        }

        $pacPath = $pacCommand.Source

        Write-Host "##[group]Authenticating Power Apps CLI using managed identity / Azure identity context"

        $createArgs = @('auth', 'create', '--managedIdentity', '--name', $ProfileName)
        $createOutput = @(& $pacPath @createArgs 2>&1)
        $createExitCode = $LASTEXITCODE

        if ($createExitCode -ne 0) {
            $selectOutput = @(& $pacPath auth select --name $ProfileName 2>&1)
            $selectExitCode = $LASTEXITCODE

            if ($selectExitCode -ne 0) {
                $createText = ($createOutput | ForEach-Object { [string]$_ }) -join "`n"
                $selectText = ($selectOutput | ForEach-Object { [string]$_ }) -join "`n"
                throw @(
                    "Failed to establish PAC authentication using the existing Azure identity context.",
                    "Expected an existing non-interactive Azure sign-in context (for example Azure CLI, managed identity, or workload identity).",
                    "pac auth create output:",
                    $createText,
                    "pac auth select output:",
                    $selectText
                ) -join "`n"
            }
        }

        $whoOutput = @(& $pacPath auth who 2>&1)
        if ($LASTEXITCODE -ne 0) {
            $whoText = ($whoOutput | ForEach-Object { [string]$_ }) -join "`n"
            throw "PAC authentication validation failed (pac auth who).`n$whoText"
        }

        if (-not $Quiet) {
            foreach ($line in $whoOutput) {
                Write-Host $line
            }
        }

        Write-Host "##[endgroup]"
    }

function Invoke-Hook {
    param(
        [string]$HookType,
        [string]$BaseDirectory,
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,
        [hashtable]$AdditionalContext = @{},
        [bool]$LogContext = $true
    )

    if ($Config.ContainsKey('hooks') -and $Config['hooks'] -is [hashtable] -and $Config['hooks'].ContainsKey($HookType) -and $Config['hooks'][$HookType]) {
        $hooks = $Config['hooks'][$HookType]
        if ($hooks -is [string]) {
            $hooks = @($hooks)
        }
        foreach ($hook in $hooks) {
            Write-Host "##[group] Executing $HookType hook: $hook"

            # Build context hashtable with required and additional entries
            $context = @{
                HookType      = $HookType
                BaseDirectory = $BaseDirectory
                Config        = $Config
            }
            # Add any additional context entries
            foreach ($key in $AdditionalContext.Keys) {
                $context[$key] = $AdditionalContext[$key]
            }

            # Replace [alm] placeholder with the absolute path of the ALM repo root
            $almRootPath = Join-Path -Path $PSScriptRoot -ChildPath ".." -AdditionalChildPath ".." | Resolve-Path | Select-Object -ExpandProperty Path
            $hookPath = $hook -replace '\[alm\]', $almRootPath

            if (Test-Path $hookPath) {

                if ($LogContext) { write-host "##[debug] Executing hook script at path: $hookPath with context: $($context | ConvertTo-Json -Depth 10)" }

                try {
                    & $hookPath -Context $context
                    if (-not $? ) { throw "Hook $hook failed" }
                } finally {
                    Write-Host "##[endgroup]"
                }

            }
            else {
                Write-Host "##[error]Hook script not found: $hookPath"
                Write-Host "##[endgroup]"
                throw "Hook script not found: $hookPath"
            }
        }
    }
}
