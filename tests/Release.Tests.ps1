BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repoRoot 'pipelines/scripts/common.ps1')
}

Describe 'Release packaging' {
    It 'generates standalone installers with valid syntax and no unresolved placeholders' {
        $releaseDirectory = Join-Path $TestDrive 'release'
        & (Join-Path $repoRoot 'prepare-release.ps1') -TagName v0.0.0-test -OutputDir $releaseDirectory | Out-Null
        foreach ($name in @('setup-azdo.ps1', 'setup-github.ps1')) {
            $generatedPath = Join-Path $releaseDirectory $name
            $content = Get-Content -LiteralPath $generatedPath -Raw
            $content | Should -Not -Match '__ALM4DATAVERSE_REF__|__RNWOOD_DATAVERSE_VERSION__|__UPSTREAM_REPO__|__SETUP_COMMON_LIB__'
            $tokens = $null
            $parseErrors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($generatedPath, [ref]$tokens, [ref]$parseErrors)
            @($parseErrors).Count | Should -Be 0
        }
    }
}
