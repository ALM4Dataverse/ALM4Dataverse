$setupGitHubManifest = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'setup-sources.psd1')

foreach ($relativePath in $setupGitHubManifest.GitHub) {
    . (Join-Path $PSScriptRoot $relativePath)
}
