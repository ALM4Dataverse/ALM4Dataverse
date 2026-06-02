<#
.SYNOPSIS
    Common functions for pipelines scripts.
.DESCRIPTION
    This script contains common functions used across various pipeline scripts
    such as build.ps1, deploy.ps1, and export.ps1.
#>

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
        [string]$BaseDirectory = "."
    )

    $defaultConfigPath = Join-Path $PSScriptRoot ".." ".." "alm-config-defaults.psd1" | Resolve-Path | Select-Object -ExpandProperty Path
    
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

    Write-Host "##[debug]Loaded configuration: $($config | ConvertTo-Json -Depth 20)"
    
    return $config
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

function Invoke-Hooks {
    param(
        [string]$HookType,
        [string]$BaseDirectory,
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,
        [hashtable]$AdditionalContext = @{}
    )

    if ($Config.hooks -and $Config.hooks.$HookType) {
        $hooks = $Config.hooks.$HookType
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
            $almRootPath = Join-Path $PSScriptRoot ".." ".." | Resolve-Path | Select-Object -ExpandProperty Path
            $hookPath = $hook -replace '\[alm\]', $almRootPath
            
            if (Test-Path $hookPath) {

                write-host "##[debug] Executing hook script at path: $hookPath with context: $($context | ConvertTo-Json -Depth 10)"

                & $hookPath -Context $context
                if (-not $? ) {
                    throw "Hook $hook failed"
                }

            }
            else {
                Write-Host "##[error]Hook script not found: $hookPath"
                throw "Hook script not found: $hookPath"
            }
            Write-Host "##[endgroup]"
        }
    }
}
