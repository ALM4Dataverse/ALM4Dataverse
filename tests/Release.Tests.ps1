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
            $content | Should -Not -Match '__ALM4DATAVERSE_REF__|__ALM4DATAVERSE_VERSION__|__RNWOOD_DATAVERSE_VERSION__|__UPSTREAM_REPO__|__SETUP_COMMON_LIB__|__SETUP_AZDO_BOOTSTRAP_LIB__|__SETUP_AZDO_LIB__|__SETUP_GITHUB_BOOTSTRAP_LIB__|__SETUP_GITHUB_LIB__'
            $content | Should -Match '\$script:ALM4DataverseVersion = ''v0\.0\.0-test'''
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($generatedPath, [ref]$tokens, [ref]$parseErrors)
            @($parseErrors).Count | Should -Be 0
            $functionNames = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $false).Name)
            if ($name -eq 'setup-azdo.ps1') {
                $functionNames | Should -Contain 'Install-PortableGit'
                $functionNames | Should -Contain 'Initialize-AzDoAuthentication'
                $functionNames | Should -Contain 'Get-AzDoCallerSecretVariableBlock'
            }
            else {
                $functionNames | Should -Contain 'Install-PortableGitHubCli'
                $functionNames | Should -Contain 'Invoke-GhApi'
                $functionNames | Should -Contain 'Get-GitHubAccessibleRepository'
            }
        }

        foreach ($sandboxFile in @(
            @{ Name = 'setup-azdo.wsb'; SetupScript = 'setup-azdo.ps1' },
            @{ Name = 'setup-github.wsb'; SetupScript = 'setup-github.ps1' }
        )) {
            $generatedPath = Join-Path $releaseDirectory $sandboxFile.Name
            [xml]$sandboxConfiguration = Get-Content -LiteralPath $generatedPath -Raw
            $command = $sandboxConfiguration.Configuration.LogonCommand.Command
            $expectedUrl = "https://github.com/ALM4Dataverse/ALM4Dataverse/releases/download/v0.0.0-test/$($sandboxFile.SetupScript)"

            $command | Should -Match ([regex]::Escape($expectedUrl))
            $command | Should -Not -Match '__ALM4DATAVERSE_RELEASE_TAG__|releases/latest/download'
        }
    }

    It 'publishes shared setup assets and updates stable only for version-tag releases' {
        $workflowPath = Join-Path $repoRoot '.github/workflows/stable-release.yml'
        $workflow = Get-Content -LiteralPath $workflowPath -Raw
        $sandboxFiles = @(
            @{ Name = 'setup-azdo.wsb'; SetupScript = 'setup-azdo.ps1'; WorkflowOutput = 'SETUP_AZDO_WSB_FILE' },
            @{ Name = 'setup-github.wsb'; SetupScript = 'setup-github.ps1'; WorkflowOutput = 'SETUP_GITHUB_WSB_FILE' }
        )

        $workflow.Contains("- 'v[0-9]+.[0-9]+.[0-9]+'") | Should -BeTrue
        $workflow.Contains("- 'v[0-9]+.[0-9]+.[0-9]+.[0-9]+'") | Should -BeTrue
        $workflow | Should -Match 'prepare-release\.ps1'
        $workflow | Should -Match 'git tag -f stable'
        $workflow.Contains("name: 'setup-azdo.ps1'") | Should -BeTrue
        $workflow.Contains("name: 'setup-github.ps1'") | Should -BeTrue
        $workflow.Contains("SETUP_AZDO_WSB_FILE=release/setup-azdo.wsb") | Should -BeTrue
        $workflow.Contains("SETUP_GITHUB_WSB_FILE=release/setup-github.wsb") | Should -BeTrue

        foreach ($sandboxFile in $sandboxFiles) {
            $workflow.Contains("prepare_setup.outputs.$($sandboxFile.WorkflowOutput) }}', name: '$($sandboxFile.Name)' }") | Should -BeTrue
            $sandboxConfigurationPath = Join-Path $repoRoot $sandboxFile.Name
            [xml]$sandboxConfiguration = Get-Content -LiteralPath $sandboxConfigurationPath -Raw

            $sandboxConfiguration.Configuration.VGpu | Should -Be 'Disable'
            $sandboxConfiguration.Configuration.Networking | Should -Be 'Enable'
            $sandboxConfiguration.Configuration.ClipboardRedirection | Should -Be 'Disable'
            $sandboxConfiguration.Configuration.PrinterRedirection | Should -Be 'Disable'
            $sandboxConfiguration.Configuration.ProtectedClient | Should -Be 'Enable'
            $sandboxConfiguration.SelectNodes('/Configuration/MappedFolders').Count | Should -Be 0
            $command = $sandboxConfiguration.Configuration.LogonCommand.Command
            $command | Should -Match 'powershell\.exe'
            $command | Should -Match '-NoExit'
            $command | Should -Match '__ALM4DATAVERSE_RELEASE_TAG__'
            $command | Should -Not -Match 'releases/latest/download'
        }
    }
}
