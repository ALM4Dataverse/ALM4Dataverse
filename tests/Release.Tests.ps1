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

    It 'publishes shared setup assets and updates stable only for version-tag releases' {
        $workflowPath = Join-Path $repoRoot '.github/workflows/stable-release.yml'
        $workflow = Get-Content -LiteralPath $workflowPath -Raw

        $workflow.Contains("- 'v[0-9]+.[0-9]+.[0-9]+'") | Should -BeTrue
        $workflow.Contains("- 'v[0-9]+.[0-9]+.[0-9]+.[0-9]+'") | Should -BeTrue
        $workflow | Should -Match 'prepare-release\.ps1'
        $workflow | Should -Match 'git tag -f stable'
        $workflow.Contains("name: 'setup-azdo.ps1'") | Should -BeTrue
        $workflow.Contains("name: 'setup-github.ps1'") | Should -BeTrue
    }
}
