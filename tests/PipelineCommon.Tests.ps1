BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repoRoot 'pipelines/scripts/common.ps1')
    function Invoke-TestPac {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        param($Area, $Operation)
    }
}

Describe 'ALM configuration loading' {
    It 'rejects a missing configuration file' {
        { Get-AlmConfig -BaseDirectory $TestDrive } | Should -Throw '*alm-config.psd1 not found*'
    }

    It 'retains defaults while merging overrides and custom keys' {
        Set-Content -LiteralPath (Join-Path $TestDrive 'alm-config.psd1') -Value "@{ custom = 42; importTimeoutSeconds = 30; solutionCheck = @{ enabled = `$true } }"
        $config = Get-AlmConfig -BaseDirectory $TestDrive
        $config.custom | Should -Be 42
        $config.importTimeoutSeconds | Should -Be 30
        $config.solutionCheck.enabled | Should -BeTrue
        $config.solutionCheck.geo | Should -Be 'Europe'
        $config.buildVersion.default | Should -Be '1.0'
        $config.buildVersion.branches | Should -BeOfType [hashtable]
    }
}

Describe 'BUILD SemVer resolution' {
    BeforeEach {
        $script:buildVersionConfig = @{
            buildVersion = @{
                default = '1.0'
                branches = @{
                    main = '2.1'
                    'release/1.x' = '1.4'
                }
            }
        }
    }

    It 'uses branch MAJOR.MINOR and emits a branch-suffixed prerelease version' {
        $version = Resolve-AlmBuildVersion -Config $script:buildVersionConfig -BranchName 'refs/heads/main' -RunNumber 42 -Provider github
        $version.Version | Should -Be '2.1.42-main'
        $version.TagName | Should -Be 'v2.1.42-main'
        $version.PSObject.Properties.Name | Should -Not -Contain 'StableVersion'
        $version.PSObject.Properties.Name | Should -Not -Contain 'StableTagName'
        $azdoVersion = Resolve-AlmBuildVersion -Config $script:buildVersionConfig -BranchName 'main' -RunNumber 42 -Provider azdo
        $azdoVersion.Version | Should -Be $version.Version
    }

    It 'maps branch MAJOR.MINOR to the solution Major.Build base' {
        $baseVersion = Resolve-AlmBranchBaseVersion -Config $script:buildVersionConfig -BranchName 'refs/heads/main'
        $baseVersion.Major | Should -Be 2
        $baseVersion.Build | Should -Be 1
        $baseVersion.MajorMinor | Should -Be '2.1'
        $baseVersion.HasBranchOverride | Should -BeTrue
    }

    It 'uses the configured default for an unlisted branch and normalizes branch separators' {
        $version = Resolve-AlmBuildVersion -Config $script:buildVersionConfig -BranchName 'feature/new-ui' -RunNumber 7 -Provider azdo
        $version.Version | Should -Be '1.0.7-feature-new-ui'
        $version.BranchName | Should -Be 'feature/new-ui'
        (Resolve-AlmBranchBaseVersion -Config $script:buildVersionConfig -BranchName 'feature/new-ui').HasBranchOverride | Should -BeFalse
        $featureVersion = Resolve-AlmBuildVersion -Config $script:buildVersionConfig -BranchName 'feat/abc' -RunNumber 8 -Provider github
        $featureVersion.Version | Should -Be '1.0.8-feat-abc'
        $numericVersion = Resolve-AlmBuildVersion -Config $script:buildVersionConfig -BranchName '01' -RunNumber 9 -Provider github
        $numericVersion.Version | Should -Be '1.0.9-b01'
    }

    It 'rejects missing, malformed, and invalid version inputs' {
        { Resolve-AlmBuildVersion -Config @{} -BranchName main -RunNumber 1 -Provider github } | Should -Throw '*buildVersion.default*'
        { Resolve-AlmBuildVersion -Config @{ buildVersion = @{ default = '01.2' } } -BranchName main -RunNumber 1 -Provider github } | Should -Throw '*Invalid MAJOR.MINOR*'
        { Resolve-AlmBranchBaseVersion -Config @{ buildVersion = @{ default = '2147483648.2' } } -BranchName main } | Should -Throw '*32-bit integer*'
        { Resolve-AlmBuildVersion -Config $script:buildVersionConfig -BranchName main -RunNumber '01' -Provider github } | Should -Throw '*SemVer PATCH*'
        { Resolve-AlmBuildVersion -Config $script:buildVersionConfig -BranchName 'refs/tags/v1.2.3' -RunNumber 1 -Provider github } | Should -Throw '*requires a branch ref*'
    }

    It 'writes build-version metadata that retains the exact source BUILD identity' {
        $metadataPath = Write-AlmBuildVersionInfo `
            -ArtifactsPath $TestDrive `
            -BuildVersion (Resolve-AlmBuildVersion -Config $script:buildVersionConfig -BranchName main -RunNumber 42 -Provider github) `
            -RunId 123456 `
            -SourceCommit ('a' * 40)
        $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
        $metadata.version | Should -Be '2.1.42-main'
        $metadata.runId | Should -Be '123456'
        $metadata.sourceCommit | Should -Be ('a' * 40)
        $metadata.PSObject.Properties.Name | Should -Not -Contain 'stableVersion'
        $metadata.PSObject.Properties.Name | Should -Not -Contain 'stableTag'
    }

    It 'uses the shared metadata writer in the GitHub BUILD action' {
        $actionPath = Join-Path $repoRoot '.github/actions/build/action.yml'
        $action = Get-Content -LiteralPath $actionPath -Raw

        $action | Should -Match '\bWrite-AlmBuildVersionInfo\b'
        $action | Should -Not -Match '\bWrite-AlmBuildVersionMetadata\b'
        (Get-Command Write-AlmBuildVersionInfo).Name | Should -Be 'Write-AlmBuildVersionInfo'
    }
}

Describe 'Pipeline hooks' {
    It 'accepts missing, null, and empty hook configuration under strict mode' -ForEach @(
        @{ Config = @{} }
        @{ Config = @{ hooks = $null } }
        @{ Config = @{ hooks = @{} } }
        @{ Config = @{ hooks = @{ preBuild = $null } } }
        @{ Config = @{ hooks = @{ preBuild = @() } } }
    ) {
        Set-StrictMode -Version Latest
        { Invoke-Hook -HookType preBuild -BaseDirectory $TestDrive -Config $Config } | Should -Not -Throw
    }

    It 'passes required and additional context to a string hook path' {
        $hookPath = Join-Path $TestDrive 'hook.ps1'
        Set-Content -LiteralPath $hookPath -Value 'param($Context); $Context'
        $config = @{ hooks = @{ preBuild = $hookPath } }
        $context = Invoke-Hook -HookType preBuild -BaseDirectory $TestDrive -Config $config -AdditionalContext @{ Extra = 42 }
        $context.HookType | Should -Be preBuild
        $context.BaseDirectory | Should -Be $TestDrive
        $context.Extra | Should -Be 42
        $context.Config | Should -Be $config
    }

    It 'rejects missing hook scripts' {
        { Invoke-Hook -HookType preBuild -BaseDirectory $TestDrive -Config @{ hooks = @{ preBuild = 'missing-hook.ps1' } } } | Should -Throw '*Hook script not found*'
    }

    It 'propagates hook failures rather than continuing' {
        $hookPath = Join-Path $TestDrive 'failure.ps1'
        Set-Content -LiteralPath $hookPath -Value "param(`$Context); throw 'Hook operation failed'"
        { Invoke-Hook -HookType preBuild -BaseDirectory $TestDrive -Config @{ hooks = @{ preBuild = @($hookPath) } } } | Should -Throw '*Hook operation failed*'
    }
}

Describe 'PAC authentication' {
    BeforeEach {
        $script:savedExitCode = $global:LASTEXITCODE
        Mock Get-Command { [pscustomobject]@{ Source = 'Invoke-TestPac' } } -ParameterFilter { $Name -eq 'pac' }
        Mock Invoke-TestPac { $global:LASTEXITCODE = 0; 'Authenticated' }
    }

    AfterEach {
        $global:LASTEXITCODE = $script:savedExitCode
    }

    It 'creates and validates an authentication profile' {
        Initialize-PacAuthentication
        Should -Invoke Invoke-TestPac -Times 1 -Exactly -ParameterFilter { $Operation -eq 'create' }
        Should -Invoke Invoke-TestPac -Times 1 -Exactly -ParameterFilter { $Operation -eq 'who' }
    }

    It 'selects an existing profile when creation fails' {
        Mock Invoke-TestPac { $global:LASTEXITCODE = 1; 'Profile exists' } -ParameterFilter { $Operation -eq 'create' }
        Initialize-PacAuthentication -Quiet
        Should -Invoke Invoke-TestPac -Times 1 -Exactly -ParameterFilter { $Operation -eq 'select' }
    }

    It 'reports creation and selection failures' {
        Mock Invoke-TestPac { $global:LASTEXITCODE = 1; 'Authentication failed' }
        { Initialize-PacAuthentication } | Should -Throw '*Failed to establish PAC authentication*'
    }

    It 'rejects a profile that fails identity validation' {
        Mock Invoke-TestPac { $global:LASTEXITCODE = 1; 'Identity failed' } -ParameterFilter { $Operation -eq 'who' }
        { Initialize-PacAuthentication } | Should -Throw '*PAC authentication validation failed*'
    }

    It 'fails clearly when PAC is unavailable' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'pac' }
        { Initialize-PacAuthentication } | Should -Throw '*pac) is not available*'
    }
}

Describe 'Checked native commands' {
    BeforeAll {
        function Invoke-TestNativeCommand {
            param([int]$ExitCode)
            $global:LASTEXITCODE = $ExitCode
            'command output'
        }
    }

    BeforeEach {
        $script:savedExitCode = $global:LASTEXITCODE
    }

    AfterEach {
        $global:LASTEXITCODE = $script:savedExitCode
    }

    It 'returns output on success' {
        Invoke-CheckedNativeCommand -Command Invoke-TestNativeCommand -Arguments 0 | Should -Be 'command output'
    }

    It 'throws on nonzero exit codes instead of reporting success' {
        { Invoke-CheckedNativeCommand -Command Invoke-TestNativeCommand -Arguments 7 } | Should -Throw '*exit code 7*'
    }

    It 'allows explicitly expected failures' {
        Invoke-CheckedNativeCommand -Command Invoke-TestNativeCommand -Arguments 7 -AllowFailure | Should -Be 'command output'
    }
}

Describe 'Configuration merging' {
    It 'preserves explicit false and zero under strict mode' {
        Set-StrictMode -Version Latest
        $merged = Merge-AlmConfigValue -DefaultValue @{ enabled = $true; count = 4 } -OverrideValue @{ enabled = $false; count = 0 }
        $merged.enabled | Should -BeFalse
        $merged.count | Should -Be 0
    }

    It 'merges nested keys and concatenates arrays' {
        $merged = Merge-AlmConfigValue -DefaultValue @{ nested = @{ first = 1 }; items = @('default') } -OverrideValue @{ nested = @{ second = 2 }; items = @('custom') }
        $merged.nested.first | Should -Be 1
        $merged.nested.second | Should -Be 2
        $merged.items | Should -Be @('default', 'custom')
    }

    It 'preserves defaults for null overrides' {
        Merge-AlmConfigValue -DefaultValue 'default' -OverrideValue $null | Should -Be 'default'
    }
}
