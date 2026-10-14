<#
.SYNOPSIS
    Checks for outdated script dependencies in alm-config-defaults.psd1
.DESCRIPTION
    Reads the scriptDependencies from alm-config-defaults.psd1 and checks
    PowerShell Gallery for newer versions. Outputs information about outdated
    dependencies for use in the next workflow step.
#>

$ErrorActionPreference = "Stop"

Write-Host "Checking for outdated dependencies..."

# Read the current dependencies from alm-config-defaults.psd1
$configPath = "alm-config-defaults.psd1"
if (-not (Test-Path $configPath)) {
    Write-Host "##[error]Config file not found: $configPath"
    exit 1
}

$config = Import-PowerShellDataFile -Path $configPath
$scriptDependencies = $config.scriptDependencies

if (-not $scriptDependencies -or $scriptDependencies.Count -eq 0) {
    Write-Host "No script dependencies found in $configPath"
    Write-Output "has_updates=false" >> $env:GITHUB_OUTPUT
    exit 0
}

Write-Host "Found $($scriptDependencies.Count) dependencies to check"

$outdatedDeps = @()

foreach ($moduleName in $scriptDependencies.Keys) {
    $currentVersion = $scriptDependencies[$moduleName]

    Write-Host "Checking $moduleName (current: $currentVersion)..."

    try {
        # Find the latest version from PowerShell Gallery
        $latestModule = Find-Module -Name $moduleName -ErrorAction Stop
        $latestVersion = $latestModule.Version.ToString()

        Write-Host "  Latest version: $latestVersion"

        # Compare versions
        if ($currentVersion -ne $latestVersion) {
            $currentVersionObj = [version]$currentVersion
            $latestVersionObj = [version]$latestVersion

            if ($latestVersionObj -gt $currentVersionObj) {
                Write-Host "  ✓ Update available: $currentVersion -> $latestVersion"
                $outdatedDeps += @{
                    name = $moduleName
                    currentVersion = $currentVersion
                    latestVersion = $latestVersion
                }
            } else {
                Write-Host "  Current version is up to date or newer"
            }
        } else {
            Write-Host "  Already at latest version"
        }
    }
    catch {
        Write-Host "##[warning]Failed to check $moduleName : $_"
    }
}

if ($outdatedDeps.Count -eq 0) {
    Write-Host "All dependencies are up to date!"
    Write-Output "has_updates=false" >> $env:GITHUB_OUTPUT
} else {
    Write-Host "`nFound $($outdatedDeps.Count) outdated dependencies"

    # Save outdated dependencies to a file for the next step
    $outdatedDeps | ConvertTo-Json | Out-File -FilePath "outdated-deps.json" -Encoding UTF8

    Write-Output "has_updates=true" >> $env:GITHUB_OUTPUT
}
