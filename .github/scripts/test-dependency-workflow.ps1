<#
.SYNOPSIS
    Test script to verify the dependency update workflow logic
.DESCRIPTION
    This script tests the basic functionality of the dependency check script
    without requiring network access to PowerShell Gallery.
.NOTES
    Exercises local data/regex conventions, not the production workflow or GitHub
    API. Its temporary working directory is removed and the caller's restored.
#>

$ErrorActionPreference = "Stop"

Write-Host "Testing dependency update workflow logic..."

# Create a temporary test directory
$testDir = Join-Path ([System.IO.Path]::GetTempPath()) "alm-dep-test-$(Get-Date -Format 'yyyyMMddHHmmss')"
New-Item -ItemType Directory -Path $testDir -Force | Out-Null
Push-Location $testDir

try {
    Write-Host "`n1. Testing config file parsing..."

    # Create a mock config file
    $mockConfig = @'
@{
    scriptDependencies = @{
        "Rnwood.Dataverse.Data.PowerShell" = "2.17.0"
    }
}
'@

    Set-Content -Path "alm-config-defaults.psd1" -Value $mockConfig

    # Test reading the config
    $config = Import-PowerShellDataFile -Path "alm-config-defaults.psd1"

    if (-not $config.scriptDependencies) {
        throw "Failed to read scriptDependencies from config"
    }

    $moduleName = $config.scriptDependencies.Keys | Select-Object -First 1
    $currentVersion = $config.scriptDependencies[$moduleName]

    Write-Host "  ✓ Successfully parsed config file"
    Write-Host "    Found module: $moduleName version $currentVersion"

    Write-Host "`n2. Testing version comparison logic..."

    # Simulate outdated dependency data
    $outdatedDeps = @(
        @{
            name = $moduleName
            currentVersion = $currentVersion
            latestVersion = "2.18.0"
        }
    )

    $outdatedDeps | ConvertTo-Json | Out-File -FilePath "outdated-deps.json" -Encoding UTF8

    # Verify the JSON can be read back
    $readDeps = Get-Content "outdated-deps.json" -Raw | ConvertFrom-Json

    if ($readDeps.name -ne $moduleName) {
        throw "Failed to serialize/deserialize dependency data"
    }

    Write-Host "  ✓ Successfully serialized/deserialized dependency data"
    Write-Host "    $($readDeps.name): $($readDeps.currentVersion) -> $($readDeps.latestVersion)"

    Write-Host "`n3. Testing config file update logic..."

    # Test the regex pattern for updating the version
    $configContent = Get-Content "alm-config-defaults.psd1" -Raw
    $pattern = "(`"$moduleName`"|'$moduleName')\s*=\s*(`"|')$currentVersion(`"|')"
    $replacement = "`${1} = `"$($readDeps.latestVersion)`""
    $newContent = $configContent -replace $pattern, $replacement

    if ($configContent -eq $newContent) {
        throw "Regex pattern did not match and update the version"
    }

    if ($newContent -notmatch "2\.18\.0") {
        throw "Version was not updated correctly in the new content"
    }

    Write-Host "  ✓ Successfully updated version in config using regex"
    Write-Host "    Updated to version: 2.18.0"

    # Verify the updated config is still valid PowerShell data file
    Set-Content -Path "alm-config-defaults-updated.psd1" -Value $newContent -NoNewline
    $updatedConfig = Import-PowerShellDataFile -Path "alm-config-defaults-updated.psd1"

    if ($updatedConfig.scriptDependencies[$moduleName] -ne "2.18.0") {
        throw "Updated config file is not valid or version is incorrect"
    }

    Write-Host "  ✓ Updated config is valid and version is correct"

    Write-Host "`n4. Testing branch naming convention..."

    $branchName = "deps/update-$($moduleName.ToLower())-to-$($readDeps.latestVersion)"

    if ($branchName -notmatch '^deps/update-[a-z0-9\._-]+-to-[0-9\.]+$') {
        throw "Branch name does not match expected pattern"
    }

    Write-Host "  ✓ Branch name follows convention: $branchName"

    Write-Host "`n✅ All tests passed successfully!"

} finally {
    Pop-Location
    Remove-Item -Path $testDir -Recurse -Force -ErrorAction SilentlyContinue
}
