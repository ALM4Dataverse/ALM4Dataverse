BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repoRoot 'pipelines/scripts/common.ps1')
    function dotnet {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        param($Verb, $Operation, $PackageName)
    }
    function Get-TestNodeLink {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][string]$Target
        )

        $itemType = if ($IsWindows) { 'HardLink' } else { 'SymbolicLink' }
        New-Item -ItemType $itemType -Path $Path -Target $Target | Out-Null
    }
    function Get-TestNodeRuntime {
        $nodeCommand = Get-Command node -ErrorAction Stop
        $versionOutput = @(& $nodeCommand.Source --version 2>&1)
        if ($LASTEXITCODE -ne 0 -or $versionOutput.Count -ne 1 -or $versionOutput[0] -notmatch '^v(\d+\.\d+\.\d+)$') {
            throw 'A working Node.js command is required for dependency tests.'
        }

        [pscustomobject]@{
            Path = $nodeCommand.Source
            Version = [version]$Matches[1]
        }
    }
}

Describe 'Dependency installation' {
    BeforeEach {
        # Installation updates PATH and action path files; keep those effects local while mocks
        # prevent package installation and the fixture directory owns lock/config writes.
        $script:savedEnvironment = @{
            PATH = $env:PATH
            GITHUB_PATH = $env:GITHUB_PATH
            TF_BUILD = $env:TF_BUILD
        }
        $script:savedHome = $HOME
        $script:savedExitCode = $global:LASTEXITCODE
        $script:dependencyDirectory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:dependencyDirectory -Force | Out-Null
        $env:GITHUB_PATH = Join-Path $script:dependencyDirectory 'github-path.txt'
        $env:TF_BUILD = 'True'
        Mock Install-Module { [pscustomobject]@{ Version = '3.2.1-preview.1' } }
        Mock Get-InstalledModule { [pscustomobject]@{ InstalledLocation = (Join-Path $TestDrive 'mock-module') } }
        Mock Import-Module {} -ParameterFilter { $Name -like '*mock-module*' }
        Mock Get-Module {
            [pscustomobject]@{ Version = [version]'3.2.1'; Prerelease = 'preview.1' }
        } -ParameterFilter { $Name -eq 'Rnwood.Dataverse.Data.PowerShell' }
        Mock Get-Command { [pscustomobject]@{ Source = 'dotnet' } } -ParameterFilter { $Name -eq 'dotnet' }
        Mock Test-Path {
            param($Path, $LiteralPath)
            $testPath = if ($Path) { $Path } else { $LiteralPath }
            if ($testPath -match '[\\/]\.alm4dataverse[\\/]tools') {
                return $true
            }
            $fullPath = if ([System.IO.Path]::IsPathRooted($testPath)) {
                [System.IO.Path]::GetFullPath($testPath)
            }
            else {
                [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $testPath))
            }
            [System.IO.File]::Exists($fullPath) -or [System.IO.Directory]::Exists($fullPath)
        }
        Mock dotnet { $global:LASTEXITCODE = 0; 'microsoft.powerapps.cli.tool 2.13.1 pac' }
        Push-Location $script:dependencyDirectory
    }

    AfterEach {
        Pop-Location
        foreach ($name in $script:savedEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $script:savedEnvironment[$name])
        }
        Set-Variable -Name HOME -Value $script:savedHome -Scope Global -Force
        $global:LASTEXITCODE = $script:savedExitCode
    }

    It 'accepts selector <Selector> when the resolved version meets the minimum' -ForEach @(
        @{ Selector = '' }
        @{ Selector = 'prerelease' }
        @{ Selector = '3.2.1-preview.1' }
    ) {
        Set-Content -LiteralPath 'alm-config.psd1' -Value "@{ scriptDependencies = @{ 'Rnwood.Dataverse.Data.PowerShell' = '$Selector' } }"
        { & (Join-Path $repoRoot 'pipelines/scripts/installdependencies.ps1') } | Should -Not -Throw
        Should -Invoke Get-InstalledModule -Times 1 -Exactly -ParameterFilter {
            $RequiredVersion -eq '3.2.1-preview.1' -and $AllowPrerelease
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
        @{ scriptDependencies = @{ 'Rnwood.Dataverse.Data.PowerShell' = '3.2.1-preview.1' }; pacCliVersion = 'prerelease' } |
            ConvertTo-Json | Set-Content -LiteralPath 'scriptDependencies.lock.json'
        & (Join-Path $repoRoot 'pipelines/scripts/installdependencies.ps1')
        Should -Invoke Install-Module -Times 1 -Exactly -ParameterFilter { $RequiredVersion -eq '3.2.1-preview.1' -and $AllowPrerelease }
    }

    It 'does not resolve Node.js when no build was requested, even with code apps configured' {
        New-Item -ItemType Directory -Path (Join-Path $script:dependencyDirectory 'apps/code') -Force | Out-Null
        Set-Content -LiteralPath 'alm-config.psd1' -Value "@{ nodeVersion = 'invalid'; solutions = @(@{ name = 'Contoso'; codeApps = @('apps/code') }) }"
        Mock Invoke-WebRequest {}

        { & (Join-Path $repoRoot 'pipelines/scripts/installdependencies.ps1') } | Should -Not -Throw
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'does not resolve Node.js for BUILD when no code apps are configured' {
        Set-Content -LiteralPath 'alm-config.psd1' -Value "@{ nodeVersion = 'invalid'; solutions = @(@{ name = 'Contoso' }) }"
        Mock Invoke-WebRequest {}

        { & (Join-Path $repoRoot 'pipelines/scripts/installdependencies.ps1') -ForBuild } | Should -Not -Throw
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'validates nodeVersion only when BUILD has a configured code app' {
        New-Item -ItemType Directory -Path (Join-Path $script:dependencyDirectory 'apps/code') -Force | Out-Null
        Set-Content -LiteralPath 'alm-config.psd1' -Value "@{ nodeVersion = 'invalid'; solutions = @(@{ name = 'Contoso'; codeApps = @('apps/code') }) }"
        Mock Invoke-WebRequest {}

        { & (Join-Path $repoRoot 'pipelines/scripts/installdependencies.ps1') -ForBuild } | Should -Throw '*nodeVersion*invalid*'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'uses an installed Node version matching the configured <VersionKind>' -ForEach @(
        @{ VersionKind = 'major' }
        @{ VersionKind = 'exact version' }
    ) {
        $nodeRuntime = Get-TestNodeRuntime
        $versionSpecifier = if ($VersionKind -eq 'major') { [string]$nodeRuntime.Version.Major } else { $nodeRuntime.Version.ToString() }
        Set-Variable -Name HOME -Value $script:dependencyDirectory -Scope Global -Force
        New-Item -ItemType Directory -Path (Join-Path $script:dependencyDirectory 'apps/code') -Force | Out-Null
        Set-Content -LiteralPath 'alm-config.psd1' -Value "@{ nodeVersion = '$versionSpecifier'; solutions = @(@{ name = 'Contoso'; codeApps = @('apps/code') }) }"
        Mock Get-Command { [pscustomobject]@{ Source = $nodeRuntime.Path } } -ParameterFilter { $Name -eq 'node' }
        Mock Get-Command { [pscustomobject]@{ Source = 'npm' } } -ParameterFilter { $Name -eq 'npm' }
        Mock Invoke-WebRequest {}

        { & (Join-Path $repoRoot 'pipelines/scripts/installdependencies.ps1') -ForBuild } | Should -Not -Throw
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'uses the newest cached Node version when the existing Node command is invalid' {
        $nodeRuntime = Get-TestNodeRuntime
        $platform = if ($IsWindows) { 'win-x64' } else { 'linux-x64' }
        $cachedDirectory = Join-Path $script:dependencyDirectory ".alm4dataverse/tools/node/v$($nodeRuntime.Version)-$platform"
        $cachedNodePath = Join-Path $cachedDirectory $(if ($IsWindows) { 'node.exe' } else { 'bin/node' })
        Set-Variable -Name HOME -Value $script:dependencyDirectory -Scope Global -Force
        New-Item -ItemType Directory -Path (Join-Path $script:dependencyDirectory 'apps/code'), (Split-Path -Parent $cachedNodePath) -Force | Out-Null
        Get-TestNodeLink -Path $cachedNodePath -Target $nodeRuntime.Path
        Set-Content -LiteralPath 'alm-config.psd1' -Value "@{ nodeVersion = '$($nodeRuntime.Version.Major)'; solutions = @(@{ name = 'Contoso'; codeApps = @('apps/code') }) }"
        Mock Get-Command { [pscustomobject]@{ Source = 'pwsh' } } -ParameterFilter { $Name -eq 'node' }
        Mock Invoke-WebRequest {}

        { & (Join-Path $repoRoot 'pipelines/scripts/installdependencies.ps1') -ForBuild } | Should -Not -Throw
        (Get-Content -LiteralPath $env:GITHUB_PATH -Raw) -split "`r?`n" |
            Should -Contain (Split-Path -Parent $cachedNodePath)
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
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
