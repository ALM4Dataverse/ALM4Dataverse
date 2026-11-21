$script:SetupRepositoryRoot = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { $null }
$setupCommonManifest = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'setup-sources.psd1')

foreach ($relativePath in $setupCommonManifest.Common) {
    . (Join-Path $PSScriptRoot $relativePath)
}
