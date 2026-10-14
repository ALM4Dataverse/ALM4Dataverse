#Requires -Version 7.0

<#
.SYNOPSIS
    Prepares setup-azdo.ps1 and setup-github.ps1 for release.
    This extracts the release logic from the GitHub workflow for testability.

.DESCRIPTION
    Processes setup-azdo.ps1 and setup-github.ps1 by replacing placeholders with actual values for
    a release. This script can be run locally to test the release preparation process.

.PARAMETER TagName
    The release tag (e.g., v1.0.0)

.PARAMETER OutputDir
    Directory where the processed scripts will be written

.PARAMETER UpstreamRepo
    (Optional) URL of the upstream repository. Defaults to https://github.com/ALM4Dataverse/ALM4Dataverse.git

.EXAMPLE
    .\prepare-release.ps1 -TagName v1.2.3 -OutputDir ./release

.EXAMPLE
    .\prepare-release.ps1 -TagName v1.2.3 -OutputDir ./release -UpstreamRepo https://github.com/myorg/MyRepo.git
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$TagName,

    [Parameter(Mandatory = $true, Position = 1)]
    [string]$OutputDir,

    [Parameter(Position = 2)]
    [string]$UpstreamRepo = 'https://github.com/ALM4Dataverse/ALM4Dataverse.git'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Get the directory where this script is located
$ScriptDir = $PSScriptRoot

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Preparing setup scripts for release" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Configuration:"
Write-Host "  Tag:          $TagName"
Write-Host "  Output dir:   $OutputDir"
Write-Host "  Upstream URL: $UpstreamRepo"
Write-Host "  Script dir:   $ScriptDir"
Write-Host ""

# Step 1: Extract Rnwood.Dataverse.Data.PowerShell version from alm-config-defaults.psd1
Write-Host "Step 1: Extracting version from alm-config-defaults.psd1..." -ForegroundColor Yellow

$ConfigFile = Join-Path $ScriptDir 'alm-config-defaults.psd1'
if (-not (Test-Path $ConfigFile)) {
    Write-Host "ERROR: Config file not found: $ConfigFile" -ForegroundColor Red
    exit 1
}

# Use Import-PowerShellDataFile to reliably read the version
try {
    $config = Import-PowerShellDataFile -Path $ConfigFile

    if (-not $config.ContainsKey('scriptDependencies')) {
        throw "Config file is missing 'scriptDependencies' key"
    }

    if (-not $config.scriptDependencies.ContainsKey('Rnwood.Dataverse.Data.PowerShell')) {
        throw "Config file scriptDependencies is missing 'Rnwood.Dataverse.Data.PowerShell' key"
    }

    $DataverseVersion = $config.scriptDependencies.'Rnwood.Dataverse.Data.PowerShell'

    if ([string]::IsNullOrWhiteSpace($DataverseVersion)) {
        throw "Version string is empty or null"
    }

    Write-Host "  Found version: $DataverseVersion" -ForegroundColor Green
}
catch {
    Write-Host "ERROR: Could not extract Rnwood.Dataverse.Data.PowerShell version from config file" -ForegroundColor Red
    Write-Host "  Details: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host ""

# Define placeholders used in both setup scripts
$Alm4DataverseRefPlaceholder       = '__ALM4DATAVERSE_REF__'
$RnwoodDataverseVersionPlaceholder = '__RNWOOD_DATAVERSE_VERSION__'
$UpstreamRepoPlaceholder           = '__UPSTREAM_REPO__'
$SetupCommonLibPlaceholder         = '__SETUP_COMMON_LIB__'

$CommonLibraryFile = Join-Path $ScriptDir 'setup-common.ps1'
if (-not (Test-Path $CommonLibraryFile)) {
    Write-Host "ERROR: Common library file not found: $CommonLibraryFile" -ForegroundColor Red
    exit 1
}

try {
    $commonLibraryContent = Get-Content -Path $CommonLibraryFile -Raw
    $commonLibraryContent = ($commonLibraryContent -split "`r?`n" | ForEach-Object { "    $_" }) -join [Environment]::NewLine
}
catch {
    Write-Host "ERROR: Could not read $CommonLibraryFile`: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Create output directory
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

# Helper: process a single setup script
function Invoke-ProcessSetupScript {
    param(
        [Parameter(Mandatory)][string]$SourceFile,
        [Parameter(Mandatory)][string]$OutputFile,
        [Parameter(Mandatory)][string]$ScriptLabel,
        [Parameter()][string[]]$PlaceholdersToVerify
    )

    Write-Host "Processing $ScriptLabel..." -ForegroundColor Yellow

    if (-not (Test-Path $SourceFile)) {
        Write-Host "ERROR: Source file not found: $SourceFile" -ForegroundColor Red
        exit 1
    }

    try {
        $content = Get-Content -Path $SourceFile -Raw
    }
    catch {
        Write-Host "ERROR: Could not read $SourceFile`: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }

    # Replace all known placeholders (scripts that don't use a placeholder simply won't be affected)
    $content = $content -replace [regex]::Escape($Alm4DataverseRefPlaceholder),       $TagName
    $content = $content -replace [regex]::Escape($RnwoodDataverseVersionPlaceholder), $DataverseVersion
    $content = $content -replace [regex]::Escape($UpstreamRepoPlaceholder),           $UpstreamRepo
    $content = $content.Replace($SetupCommonLibPlaceholder, $commonLibraryContent)

    try {
        Set-Content -Path $OutputFile -Value $content -NoNewline
    }
    catch {
        Write-Host "ERROR: Could not write $OutputFile`: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }

    Write-Host "  Processed $ScriptLabel with:" -ForegroundColor Green
    Write-Host "    ALM4DATAVERSE_REF:        $TagName"
    Write-Host "    RNWOOD_DATAVERSE_VERSION: $DataverseVersion"
    Write-Host "    UPSTREAM_REPO:            $UpstreamRepo"
    Write-Host ""

    # Verify that the required placeholders were replaced
    $outContent = Get-Content -Path $OutputFile -Raw
    $remaining  = @()

    foreach ($ph in $PlaceholdersToVerify) {
        if ($outContent -match [regex]::Escape($ph)) {
            $remaining += $ph
        }
    }

    if ($remaining.Count -gt 0) {
        Write-Host "ERROR: Placeholders were not fully replaced in $ScriptLabel!" -ForegroundColor Red
        foreach ($ph in $remaining) {
            Write-Host "  - $ph" -ForegroundColor Red
        }
        exit 1
    }

    Write-Host "  ✓ All placeholders replaced in $ScriptLabel" -ForegroundColor Green
    Write-Host ""
}

# Step 2: Process setup-azdo.ps1
Write-Host "Step 2: Processing setup-azdo.ps1 ..." -ForegroundColor Yellow
Invoke-ProcessSetupScript `
    -SourceFile  (Join-Path $ScriptDir 'setup-azdo.ps1') `
    -OutputFile  (Join-Path $OutputDir 'setup-azdo.ps1') `
    -ScriptLabel 'setup-azdo.ps1' `
    -PlaceholdersToVerify @($Alm4DataverseRefPlaceholder, $RnwoodDataverseVersionPlaceholder, $UpstreamRepoPlaceholder, $SetupCommonLibPlaceholder)

# Step 3: Process setup-github.ps1
Write-Host "Step 3: Processing setup-github.ps1 ..." -ForegroundColor Yellow
Invoke-ProcessSetupScript `
    -SourceFile  (Join-Path $ScriptDir 'setup-github.ps1') `
    -OutputFile  (Join-Path $OutputDir 'setup-github.ps1') `
    -ScriptLabel 'setup-github.ps1' `
    -PlaceholdersToVerify @($Alm4DataverseRefPlaceholder, $RnwoodDataverseVersionPlaceholder, $SetupCommonLibPlaceholder)

# Step 4: Display summary
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "✓ Release preparation complete" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Output files:"
Write-Host "  $(Join-Path $OutputDir 'setup-azdo.ps1')"
Write-Host "  $(Join-Path $OutputDir 'setup-github.ps1')"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Review the processed files"
Write-Host "  2. Upload to GitHub release as assets"
Write-Host ""
