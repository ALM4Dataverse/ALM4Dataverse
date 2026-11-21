$setupAzDoBootstrapManifest = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'setup-sources.psd1')

foreach ($relativePath in $setupAzDoBootstrapManifest.AzDoBootstrap) {
    . (Join-Path $PSScriptRoot $relativePath)
}
