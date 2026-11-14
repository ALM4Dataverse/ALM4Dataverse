$setupAzDoManifest = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'setup-sources.psd1')

foreach ($relativePath in $setupAzDoManifest.AzDo) {
    . (Join-Path $PSScriptRoot $relativePath)
}
