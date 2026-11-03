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

    It 'uses semantic-release for stable releases and publishes pushed stable tags' {
        $workflowPath = Join-Path $repoRoot '.github/workflows/stable-release.yml'
        $workflow = Get-Content -LiteralPath $workflowPath -Raw

        $workflow | Should -Match 'workflow_dispatch:'
        $workflow | Should -Match "v\[0-9\]\*\.\[0-9\]\*\.\[0-9\]\*\.\[0-9\]\*"
        $workflow | Should -Match 'codfish/semantic-release-action@v5\.0\.0'
        $workflow | Should -Match '\.github/actions/publish-release'
        $workflow | Should -Match 'move-stable: ''true'''
        $workflow | Should -Match 'working-directory: source'
        $workflow | Should -Match 'branches: \$\{\{ format'
        $workflow | Should -Match 'GIT_CONFIG_VALUE_0: /github/workspace/source'
    }

    It 'shares semantic versioning and release asset behavior across automatic and stable releases' {
        $releaseConfig = Get-Content -LiteralPath (Join-Path $repoRoot 'release.config.cjs') -Raw
        $publishAction = Get-Content -LiteralPath (Join-Path $repoRoot '.github/actions/publish-release/action.yml') -Raw
        $validationWorkflow = Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/validation.yml') -Raw

        $releaseConfig | Should -Match '@semantic-release/commit-analyzer'
        $releaseConfig | Should -Match '@semantic-release/release-notes-generator'
        $releaseConfig | Should -Match '@semantic-release/github'
        $publishAction | Should -Match 'setup-azdo\.ps1'
        $publishAction | Should -Match 'setup-github\.ps1'
        $publishAction | Should -Match 'IS_PRERELEASE'
        $validationWorkflow | Should -Match 'publish-main-prerelease:'
        $validationWorkflow | Should -Match 'needs: \[required-validation\]'
        $validationWorkflow | Should -Match 'codfish/semantic-release-action@v5\.0\.0'
        $validationWorkflow | Should -Match 'move-stable: ''false'''
    }

    It 'validates pull request titles with Conventional Commits syntax' {
        $workflowPath = Join-Path $repoRoot '.github/workflows/pr-title.yml'
        $workflow = Get-Content -LiteralPath $workflowPath -Raw

        $workflow | Should -Match 'pull_request_target:'
        $workflow | Should -Match 'synchronize'
        $workflow | Should -Match 'amannn/action-semantic-pull-request@v6'
    }
}
