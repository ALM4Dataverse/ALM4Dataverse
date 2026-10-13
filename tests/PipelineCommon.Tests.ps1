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
    }
}

Describe 'Pipeline hooks' {
    It 'accepts missing, null, and empty hook configuration under strict mode' -ForEach @(
        @{ Config = @{} }
        @{ Config = @{ hooks = $null } }
        @{ Config = @{ hooks = @{} } }
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
