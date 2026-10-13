<#
.SYNOPSIS
    Resolves GitHub Actions dependency cache keys from ALM configuration.
.DESCRIPTION
    Reads alm-config.psd1 (merged with defaults) and optional scriptDependencies.lock.json
    and produces deterministic cache keys from requested dependency version
    specifiers.

    Caching is based on the requested specifiers (including floating values like
    '' / latest and 'prerelease').

    Output variables are written to GITHUB_OUTPUT:
    - module_cache_enabled (true/false)
    - module_cache_key
    - pac_cache_enabled (true/false)
    - pac_cache_key
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$BaseDirectory = '.',

    [Parameter(Mandatory = $false)]
    [string]$AlmScriptsRoot = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'

function ConvertTo-VersionSpecifier {
    param(
        [Parameter(Mandatory = $false)]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return 'latest'
    }

    return $Value.Trim().ToLowerInvariant()
}

function Get-HashHex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $hashBytes = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return [System.Convert]::ToHexString($hashBytes).ToLowerInvariant()
}

function Write-StepOutput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
        Write-Host "$Name=$Value"
        return
    }

    "$Name=$Value" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}

$commonScriptPath = Join-Path $AlmScriptsRoot 'common.ps1'
if (-not (Test-Path $commonScriptPath)) {
    throw "common.ps1 not found at '$commonScriptPath'."
}

$resolvedBaseDirectory = $BaseDirectory
if (-not (Test-Path $resolvedBaseDirectory)) {
    throw "Base directory '$BaseDirectory' does not exist."
}

$resolvedBaseDirectory = (Resolve-Path $resolvedBaseDirectory | Select-Object -ExpandProperty Path)

. $commonScriptPath

$config = Get-AlmConfig -BaseDirectory $resolvedBaseDirectory

$lockPath = Join-Path $resolvedBaseDirectory 'scriptDependencies.lock.json'
if (Test-Path $lockPath) {
    $lockData = Get-Content $lockPath -Raw | ConvertFrom-Json -AsHashtable
    if ($lockData.ContainsKey('scriptDependencies')) {
        $config.scriptDependencies = $lockData.scriptDependencies
    }
    if ($lockData.ContainsKey('pacCliVersion')) {
        $config.pacCliVersion = $lockData.pacCliVersion
    }

    Write-Host "Resolved cache versions from lock file '$lockPath'."
}
else {
    Write-Host "Resolved cache versions from alm-config.psd1/defaults (no lock file found)."
}

$moduleSpecs = @{}
if ($config.scriptDependencies -is [hashtable]) {
    foreach ($name in ($config.scriptDependencies.Keys | Sort-Object)) {
        $moduleSpecs[$name] = ConvertTo-VersionSpecifier -Value ([string]$config.scriptDependencies[$name])
    }
}

$moduleCacheEnabled = $moduleSpecs.Count -gt 0

$moduleCacheKey = ''
$runnerOs = if ([string]::IsNullOrWhiteSpace($env:RUNNER_OS)) { 'unknown' } else { $env:RUNNER_OS }
if ($moduleCacheEnabled) {
    $moduleStamp = ($moduleSpecs.GetEnumerator() |
        Sort-Object -Property Key |
        ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';'

    $moduleCacheKey = "alm4dataverse-$runnerOs-psmodules-$(Get-HashHex -Value $moduleStamp)"
    Write-Host "Module cache enabled with key: $moduleCacheKey"
}
else {
    Write-Host "Module cache disabled (no modules configured)."
}

$pacVersion = ''
if ($config.ContainsKey('pacCliVersion') -and $null -ne $config.pacCliVersion) {
    $pacVersion = [string]$config.pacCliVersion
}

$pacSpec = ConvertTo-VersionSpecifier -Value $pacVersion
$pacCacheEnabled = $true
$pacCacheKey = ''
if ($pacCacheEnabled) {
    $pacStamp = "Microsoft.PowerApps.CLI.Tool=$pacSpec"
    $pacCacheKey = "alm4dataverse-$runnerOs-paccli-$(Get-HashHex -Value $pacStamp)"
    Write-Host "PAC CLI cache enabled with key: $pacCacheKey"
}
else {
    Write-Host "PAC CLI cache disabled."
}

Write-StepOutput -Name 'module_cache_enabled' -Value ($moduleCacheEnabled.ToString().ToLowerInvariant())
Write-StepOutput -Name 'module_cache_key' -Value $moduleCacheKey
Write-StepOutput -Name 'pac_cache_enabled' -Value ($pacCacheEnabled.ToString().ToLowerInvariant())
Write-StepOutput -Name 'pac_cache_key' -Value $pacCacheKey
