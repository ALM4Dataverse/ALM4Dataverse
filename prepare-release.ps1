#Requires -Version 7.0

<#
.SYNOPSIS
    Prepares setup installers and provider-specific Windows Sandbox launchers for release.
    This extracts the release logic from the GitHub workflow for testability.

.DESCRIPTION
    Processes setup-azdo.ps1 and setup-github.ps1 by replacing placeholders with actual values,
    and pins each Windows Sandbox launcher to the release tag. This script can be run locally to
    test the release preparation process.

.PARAMETER TagName
    The release tag (e.g., v1.0.0)

.PARAMETER OutputDir
    Directory where the processed setup scripts and Windows Sandbox launchers will be written

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

# Define placeholders used during release preparation
$Alm4DataverseRefPlaceholder       = '__ALM4DATAVERSE_REF__'
$Alm4DataverseVersionPlaceholder   = '__ALM4DATAVERSE_VERSION__'
$Alm4DataverseReleaseTagPlaceholder = '__ALM4DATAVERSE_RELEASE_TAG__'
$RnwoodDataverseVersionPlaceholder = '__RNWOOD_DATAVERSE_VERSION__'
$UpstreamRepoPlaceholder           = '__UPSTREAM_REPO__'
$SetupCommonLibPlaceholder         = '__SETUP_COMMON_LIB__'
$SetupAzDoBootstrapLibPlaceholder  = '__SETUP_AZDO_BOOTSTRAP_LIB__'
$SetupAzDoLibPlaceholder           = '__SETUP_AZDO_LIB__'
$SetupGitHubBootstrapLibPlaceholder = '__SETUP_GITHUB_BOOTSTRAP_LIB__'
$SetupGitHubLibPlaceholder         = '__SETUP_GITHUB_LIB__'

$SetupSourceDirectory = Join-Path $ScriptDir 'setup'
$SetupSourceManifestPath = Join-Path $SetupSourceDirectory 'setup-sources.psd1'
if (-not (Test-Path -LiteralPath $SetupSourceManifestPath -PathType Leaf)) {
    Write-Host "ERROR: Setup source manifest not found: $SetupSourceManifestPath" -ForegroundColor Red
    exit 1
}

try {
    $setupSourceManifest = Import-PowerShellDataFile -LiteralPath $SetupSourceManifestPath
    foreach ($sourceGroup in @('Common', 'AzDoBootstrap', 'AzDo', 'GitHubBootstrap', 'GitHub')) {
        if (-not $setupSourceManifest.ContainsKey($sourceGroup) -or @($setupSourceManifest[$sourceGroup]).Count -eq 0) {
            throw "Setup source manifest is missing the '$sourceGroup' source list."
        }
    }
}
catch {
    Write-Host "ERROR: Could not read $SetupSourceManifestPath`: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

function Get-SetupSourceContent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$RelativePaths)

    $sourceContents = [System.Collections.Generic.List[string]]::new()
    foreach ($relativePath in $RelativePaths) {
        $sourcePath = Join-Path $SetupSourceDirectory $relativePath
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "Setup source file not found: $sourcePath"
        }
        $sourceContents.Add((Get-Content -LiteralPath $sourcePath -Raw))
    }
    return $sourceContents -join [Environment]::NewLine
}

function ConvertTo-EmbeddedSetupSource {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)

    return $Content
}

try {
    $commonLibraryContent = ConvertTo-EmbeddedSetupSource -Content (Get-SetupSourceContent -RelativePaths $setupSourceManifest.Common)
    $azdoBootstrapLibraryContent = ConvertTo-EmbeddedSetupSource -Content (Get-SetupSourceContent -RelativePaths $setupSourceManifest.AzDoBootstrap)
    $azdoLibraryContent = ConvertTo-EmbeddedSetupSource -Content (Get-SetupSourceContent -RelativePaths $setupSourceManifest.AzDo)
    $githubBootstrapLibraryContent = ConvertTo-EmbeddedSetupSource -Content (Get-SetupSourceContent -RelativePaths $setupSourceManifest.GitHubBootstrap)
    $githubLibraryContent = ConvertTo-EmbeddedSetupSource -Content (Get-SetupSourceContent -RelativePaths $setupSourceManifest.GitHub)
}
catch {
    Write-Host "ERROR: Could not assemble setup source: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

function Invoke-ProcessSetupScript {
    <#
    .SYNOPSIS
        Writes one standalone installer using the release values in script scope.
    .DESCRIPTION
        Substitutes release/version/upstream placeholders, embeds shared and provider
        source, then validates the standalone installer syntax. Exits the process on
        read/write/parse failure or a required placeholder remaining in the output;
        it does not publish the generated installer.
    .PARAMETER PlaceholdersToVerify
        Placeholders required to disappear for this provider's source template.
    .PARAMETER ProviderLibraryPlaceholder
        The provider source marker to replace in this installer template.
    .PARAMETER ProviderLibraryContent
        Ordered provider source fragments embedded at the marker.
    .PARAMETER BootstrapLibraryPlaceholder
        The provider bootstrap source marker to replace in this installer template.
    .PARAMETER BootstrapLibraryContent
        Ordered provider bootstrap source fragments embedded at the marker.
    #>
    param(
        [Parameter(Mandatory)][string]$SourceFile,
        [Parameter(Mandatory)][string]$OutputFile,
        [Parameter(Mandatory)][string]$ScriptLabel,
        [Parameter()][string[]]$PlaceholdersToVerify,
        [Parameter(Mandatory)][string]$ProviderLibraryPlaceholder,
        [Parameter(Mandatory)][string]$ProviderLibraryContent,
        [Parameter(Mandatory)][string]$BootstrapLibraryPlaceholder,
        [Parameter(Mandatory)][string]$BootstrapLibraryContent
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
    $content = $content -replace [regex]::Escape($Alm4DataverseVersionPlaceholder),   $TagName
    $content = $content -replace [regex]::Escape($RnwoodDataverseVersionPlaceholder), $DataverseVersion
    $content = $content -replace [regex]::Escape($UpstreamRepoPlaceholder),           $UpstreamRepo
    $content = $content.Replace($SetupCommonLibPlaceholder, $commonLibraryContent)
    $content = $content.Replace($BootstrapLibraryPlaceholder, $BootstrapLibraryContent)
    $content = $content.Replace($ProviderLibraryPlaceholder, $ProviderLibraryContent)

    try {
        Set-Content -Path $OutputFile -Value $content -NoNewline
    }
    catch {
        Write-Host "ERROR: Could not write $OutputFile`: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }

    Write-Host "  Processed $ScriptLabel with:" -ForegroundColor Green
    Write-Host "    ALM4DATAVERSE_REF:        $TagName"
    Write-Host "    ALM4DATAVERSE_VERSION:    $TagName"
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

    $tokens = $null
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($OutputFile, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) {
        Write-Host "ERROR: Generated installer $ScriptLabel has invalid PowerShell syntax:" -ForegroundColor Red
        foreach ($parseError in $parseErrors) {
            Write-Host ("  {0}:{1}: {2}" -f $parseError.Extent.StartLineNumber, $parseError.Extent.StartColumnNumber, $parseError.Message) -ForegroundColor Red
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
    -PlaceholdersToVerify @($Alm4DataverseRefPlaceholder, $Alm4DataverseVersionPlaceholder, $RnwoodDataverseVersionPlaceholder, $UpstreamRepoPlaceholder, $SetupCommonLibPlaceholder, $SetupAzDoBootstrapLibPlaceholder, $SetupAzDoLibPlaceholder) `
    -ProviderLibraryPlaceholder $SetupAzDoLibPlaceholder `
    -ProviderLibraryContent $azdoLibraryContent `
    -BootstrapLibraryPlaceholder $SetupAzDoBootstrapLibPlaceholder `
    -BootstrapLibraryContent $azdoBootstrapLibraryContent

# Step 3: Process setup-github.ps1
Write-Host "Step 3: Processing setup-github.ps1 ..." -ForegroundColor Yellow
Invoke-ProcessSetupScript `
    -SourceFile  (Join-Path $ScriptDir 'setup-github.ps1') `
    -OutputFile  (Join-Path $OutputDir 'setup-github.ps1') `
    -ScriptLabel 'setup-github.ps1' `
    -PlaceholdersToVerify @($Alm4DataverseRefPlaceholder, $Alm4DataverseVersionPlaceholder, $RnwoodDataverseVersionPlaceholder, $SetupCommonLibPlaceholder, $SetupGitHubBootstrapLibPlaceholder, $SetupGitHubLibPlaceholder) `
    -ProviderLibraryPlaceholder $SetupGitHubLibPlaceholder `
    -ProviderLibraryContent $githubLibraryContent `
    -BootstrapLibraryPlaceholder $SetupGitHubBootstrapLibPlaceholder `
    -BootstrapLibraryContent $githubBootstrapLibraryContent

# Step 4: Pin the Windows Sandbox launchers to this release
Write-Host "Step 4: Preparing provider-specific Windows Sandbox launchers ..." -ForegroundColor Yellow
foreach ($sandboxFile in @('setup-azdo.wsb', 'setup-github.wsb')) {
    $sourceFile = Join-Path $ScriptDir $sandboxFile
    $outputFile = Join-Path $OutputDir $sandboxFile
    if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
        Write-Host "ERROR: Sandbox configuration not found: $sourceFile" -ForegroundColor Red
        exit 1
    }

    try {
        $content = Get-Content -LiteralPath $sourceFile -Raw
        if (-not $content.Contains($Alm4DataverseReleaseTagPlaceholder)) {
            throw "Required release-tag placeholder is missing."
        }

        $content = $content.Replace($Alm4DataverseReleaseTagPlaceholder, $TagName)
        if ($content.Contains($Alm4DataverseReleaseTagPlaceholder)) {
            throw "Release-tag placeholder was not fully replaced."
        }

        $null = [xml]$content
        Set-Content -LiteralPath $outputFile -Value $content -NoNewline
    }
    catch {
        Write-Host "ERROR: Could not prepare $sandboxFile`: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }

    Write-Host "  Prepared $sandboxFile for release $TagName" -ForegroundColor Green
}

# Step 5: Display summary
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "✓ Release preparation complete" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Output files:"
Write-Host "  $(Join-Path $OutputDir 'setup-azdo.ps1')"
Write-Host "  $(Join-Path $OutputDir 'setup-github.ps1')"
Write-Host "  $(Join-Path $OutputDir 'setup-azdo.wsb')"
Write-Host "  $(Join-Path $OutputDir 'setup-github.wsb')"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Review the processed files"
Write-Host "  2. Upload to GitHub release as assets"
Write-Host ""
