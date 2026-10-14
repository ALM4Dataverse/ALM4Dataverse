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

    if (-not $Config.ContainsKey('buildVersion') -or $Config.buildVersion -isnot [hashtable]) {
        throw "BUILD version configuration is missing. Add buildVersion.default and buildVersion.branches to alm-config.psd1."
    }

    $versionConfig = $Config.buildVersion
    if (-not $versionConfig.ContainsKey('default')) {
        throw "BUILD version configuration is missing buildVersion.default in alm-config.psd1."
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
    if ($versionConfig.ContainsKey('branches')) {
        if ($versionConfig.branches -isnot [hashtable]) {
            throw 'buildVersion.branches must be a hashtable of full branch names to MAJOR.MINOR values.'
        }

        foreach ($configuredBranch in $versionConfig.branches.Keys) {
            if ([string]$configuredBranch -ceq $branch) {
                $majorMinor = [string]$versionConfig.branches[$configuredBranch]
                break
            }
        }
    }

    if ($majorMinor -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
        throw "Invalid MAJOR.MINOR value '$majorMinor' for branch '$branch'. Use two non-negative SemVer integers, for example '1.4'."
    }
    if ($RunNumber -notmatch '^(0|[1-9][0-9]*)$') {
        throw "CI run number '$RunNumber' cannot be used as a SemVer PATCH value."
    }

    $branchIdentifier = $branch.ToLowerInvariant() -replace '[^a-z0-9-]+', '-'
    $branchIdentifier = $branchIdentifier -replace '-{2,}', '-'
    $branchIdentifier = $branchIdentifier.Trim('-')
    if ([string]::IsNullOrWhiteSpace($branchIdentifier)) {
        throw "Source branch '$branch' cannot be converted to a SemVer prerelease identifier."
    }

    $stableVersion = "$majorMinor.$RunNumber"
    $version = "$stableVersion-$Provider.branch-$branchIdentifier"
    return [pscustomobject]@{
        Version       = $version
        TagName       = "v$version"
        StableVersion = $stableVersion
        StableTagName = "v$stableVersion"
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
        stableVersion = $BuildVersion.StableVersion
        stableTag      = $BuildVersion.StableTagName
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
