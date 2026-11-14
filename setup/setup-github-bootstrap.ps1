$setupGitHubBootstrapManifest = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'setup-sources.psd1')

foreach ($relativePath in $setupGitHubBootstrapManifest.GitHubBootstrap) {
    . (Join-Path $PSScriptRoot $relativePath)
}
