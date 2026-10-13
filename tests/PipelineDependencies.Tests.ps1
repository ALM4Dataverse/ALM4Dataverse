BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repoRoot 'pipelines/scripts/common.ps1')
    function dotnet {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        param($Verb, $Operation, $PackageName)
    }
}

Describe 'Dependency installation' {
    BeforeEach {
        $script:savedEnvironment = @{
            PATH = $env:PATH
            GITHUB_PATH = $env:GITHUB_PATH
            TF_BUILD = $env:TF_BUILD
        }
        $script:savedExitCode = $global:LASTEXITCODE
        $script:dependencyDirectory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:dependencyDirectory -Force | Out-Null
        $env:GITHUB_PATH = Join-Path $script:dependencyDirectory 'github-path.txt'
        $env:TF_BUILD = 'True'
        Mock Install-Module { [pscustomobject]@{ Version = '3.0.4-preview.1' } }
        Mock Get-InstalledModule { [pscustomobject]@{ InstalledLocation = (Join-Path $TestDrive 'mock-module') } }
        Mock Import-Module {} -ParameterFilter { $Name -like '*mock-module*' }
        Mock Get-Module {
            [pscustomobject]@{ Version = [version]'3.0.4'; Prerelease = 'preview.1' }
        } -ParameterFilter { $Name -eq 'Rnwood.Dataverse.Data.PowerShell' }
        Mock Get-Command { [pscustomobject]@{ Source = 'dotnet' } } -ParameterFilter { $Name -eq 'dotnet' }
        Mock Test-Path { $true } -ParameterFilter { $Path -match '[\\/]\.alm4dataverse[\\/]tools' }
        Mock dotnet { $global:LASTEXITCODE = 0; 'microsoft.powerapps.cli.tool 2.7.4 pac' }
        Push-Location $script:dependencyDirectory
    }

    AfterEach {
        Pop-Location
        foreach ($name in $script:savedEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $script:savedEnvironment[$name])
        }
        $global:LASTEXITCODE = $script:savedExitCode
    }

    It 'accepts selector <Selector> when the resolved version meets the minimum' -ForEach @(
        @{ Selector = '' }
        @{ Selector = 'prerelease' }
        @{ Selector = '3.0.4-preview.1' }
    ) {
        Set-Content -LiteralPath 'alm-config.psd1' -Value "@{ scriptDependencies = @{ 'Rnwood.Dataverse.Data.PowerShell' = '$Selector' } }"
        { & (Join-Path $repoRoot 'pipelines/scripts/installdependencies.ps1') } | Should -Not -Throw
        Should -Invoke Get-InstalledModule -Times 1 -Exactly -ParameterFilter {
            $RequiredVersion -eq '3.0.4-preview.1' -and $AllowPrerelease
        }
        Should -Invoke dotnet -Times 1 -Exactly -ParameterFilter { $Operation -eq 'update' }
        (Get-Content -LiteralPath $env:GITHUB_PATH -Raw).Trim() | Should -Be (Join-Path $HOME '.alm4dataverse/tools')
    }

    It 'rejects a resolved version below the default minimum even for floating selectors' {
        Mock Install-Module { [pscustomobject]@{ Version = '1.0.0' } }
        Set-Content -LiteralPath 'alm-config.psd1' -Value "@{ scriptDependencies = @{ 'Rnwood.Dataverse.Data.PowerShell' = '' } }"
        { & (Join-Path $repoRoot 'pipelines/scripts/installdependencies.ps1') } | Should -Throw '*less than the default minimum*'
        Should -Invoke Get-InstalledModule -Times 0 -Exactly
    }

    It 'uses pinned lock-file module and CLI selectors' {
        Set-Content -LiteralPath 'alm-config.psd1' -Value '@{ pacCliVersion = "2.7.4" }'
        @{ scriptDependencies = @{ 'Rnwood.Dataverse.Data.PowerShell' = '3.0.4-preview.1' }; pacCliVersion = 'prerelease' } |
            ConvertTo-Json | Set-Content -LiteralPath 'scriptDependencies.lock.json'
        & (Join-Path $repoRoot 'pipelines/scripts/installdependencies.ps1')
        Should -Invoke Install-Module -Times 1 -Exactly -ParameterFilter { $RequiredVersion -eq '3.0.4-preview.1' -and $AllowPrerelease }
    }

    It 'accepts PAC selector <Selector>' -ForEach @(
        @{ Selector = '' }
        @{ Selector = 'prerelease' }
        @{ Selector = '2.7.4-preview.1' }
    ) {
        Set-Content -LiteralPath 'alm-config.psd1' -Value "@{ pacCliVersion = '$Selector' }"
        { & (Join-Path $repoRoot 'pipelines/scripts/installdependencies.ps1') } | Should -Not -Throw
    }

    It 'rejects invalid CLI versions before calling dotnet' {
        Set-Content -LiteralPath 'alm-config.psd1' -Value '@{ pacCliVersion = "invalid" }'
        { & (Join-Path $repoRoot 'pipelines/scripts/installdependencies.ps1') } | Should -Throw '*pacCliVersion*invalid*'
        Should -Invoke dotnet -Times 0 -Exactly
    }

    It 'fails when dotnet is unavailable' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'dotnet' }
        Set-Content -LiteralPath 'alm-config.psd1' -Value '@{}'
        { & (Join-Path $repoRoot 'pipelines/scripts/installdependencies.ps1') } | Should -Throw '*dotnet command not found*'
    }

    It 'fails when the installed CLI version cannot be resolved' {
        Mock dotnet { $global:LASTEXITCODE = 0; 'No matching package' }
        Set-Content -LiteralPath 'alm-config.psd1' -Value '@{}'
        { & (Join-Path $repoRoot 'pipelines/scripts/installdependencies.ps1') } | Should -Throw '*installed package version could not be resolved*'
    }

    It 'fails when the installed PowerShell module cannot be located' {
        Mock Get-InstalledModule { $null }
        Set-Content -LiteralPath 'alm-config.psd1' -Value '@{}'
        { & (Join-Path $repoRoot 'pipelines/scripts/installdependencies.ps1') } | Should -Throw '*Failed to find installed module*'
    }
}
