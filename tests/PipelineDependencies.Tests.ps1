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
    $script:availableNodeRuntime = Get-TestNodeRuntime
    $script:tarExecutable = if ($IsWindows) { $null } else { (Get-Command tar -CommandType Application -ErrorAction Stop).Source }
}

Describe 'Dependency installation' {
    BeforeEach {
        # Installation updates PATH and action path files; keep those effects local while mocks
        # prevent package installation and the fixture directory owns lock/config writes.
        $script:savedEnvironment = @{
            PATH = $env:PATH
            GITHUB_PATH = $env:GITHUB_PATH
            PSModulePath = $env:PSModulePath
            TF_BUILD = $env:TF_BUILD
            PAC_TEST_ARGS = $env:PAC_TEST_ARGS
            TEST_PAC_BAD_VERSION = $env:TEST_PAC_BAD_VERSION
            TEST_NODE_ARCHIVE_PATH = $env:TEST_NODE_ARCHIVE_PATH
            TEST_NODE_ARCHIVE_CHECKSUM = $env:TEST_NODE_ARCHIVE_CHECKSUM
            TEST_NODE_ARCHIVE_NAME = $env:TEST_NODE_ARCHIVE_NAME
            LOCALAPPDATA = $env:LOCALAPPDATA
            TEST_NODE_SOURCE = $env:TEST_NODE_SOURCE
            TEST_NPM_SOURCE = $env:TEST_NPM_SOURCE
        }
        $script:savedHome = $HOME
        $script:savedExitCode = $global:LASTEXITCODE
        $script:dependencyDirectory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:dependencyDirectory -Force | Out-Null
        Set-Variable -Name HOME -Value $script:dependencyDirectory -Scope Global -Force
        $env:GITHUB_PATH = Join-Path $script:dependencyDirectory 'github-path.txt'
        $env:TF_BUILD = 'True'
        $env:TEST_PAC_BAD_VERSION = 'false'
        $env:TEST_NODE_SOURCE = ''
        $env:TEST_NPM_SOURCE = ''
        $env:PAC_TEST_ARGS = Join-Path $TestDrive 'pac-arguments.txt'
        Mock Invoke-WebRequest {}
        if ($IsWindows) {
            $env:LOCALAPPDATA = Join-Path $TestDrive 'LocalAppData'
            $pacDirectory = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerAppsCLI'
            New-Item -ItemType Directory -Path $pacDirectory -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $pacDirectory 'pac.cmd') -Value @'
@echo off
if "%1"=="install" (
  if "%2"=="--help" (
    echo manage versions
    exit /b 0
  )
  echo %* > "%PAC_TEST_ARGS%"
  exit /b 0
)
if "%1"=="--version" (
  if "%TEST_PAC_BAD_VERSION%"=="true" (
    echo not a PAC version
  ) else (
    echo Version : 2.13.1
  )
  exit /b 0
)
if "%TEST_PAC_BAD_VERSION%"=="true" (
  echo not a PAC version
) else (
  echo Version : 2.13.1
)
'@
            Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
        }
        else {
            $pacDirectory = Join-Path (Join-Path $HOME '.alm4dataverse') 'tools'
            New-Item -ItemType Directory -Path $pacDirectory -Force | Out-Null
            $pacPath = Join-Path $pacDirectory 'pac'
            Set-Content -LiteralPath $pacPath -Value @'
#!/bin/sh
if [ "$1" = "--version" ]; then
  if [ "$TEST_PAC_BAD_VERSION" = "true" ]; then
    echo "not a PAC version"
  else
    echo "Version : 2.13.1"
  fi
fi
'@
            [System.IO.File]::SetUnixFileMode(
                $pacPath,
                [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite -bor [System.IO.UnixFileMode]::UserExecute
            )
        }
        Mock Install-Module { [pscustomobject]@{ Version = '3.2.1-preview.1' } }
        Mock Get-InstalledModule { [pscustomobject]@{ InstalledLocation = (Join-Path $TestDrive 'mock-module') } }
        Mock Import-Module {}
        Mock Get-Module {
            [pscustomobject]@{ Version = [version]'3.2.1'; Prerelease = 'preview.1' }
        } -ParameterFilter { $Name -eq 'Rnwood.Dataverse.Data.PowerShell' }
        Mock Get-Command {
            switch ($Name) {
                'dotnet' { return [pscustomobject]@{ Source = 'dotnet' } }
                'node' {
                    if ($env:TEST_NODE_SOURCE) {
                        return [pscustomobject]@{ Source = $env:TEST_NODE_SOURCE }
                    }
                }
                'npm' {
                    if ($env:TEST_NPM_SOURCE) {
                        return [pscustomobject]@{ Source = $env:TEST_NPM_SOURCE }
                    }
                }
                'tar' { return [pscustomobject]@{ Source = $script:tarExecutable } }
            }
            return $null
        }
        Mock Test-Path {
            param($Path, $LiteralPath)
            $testPath = if ($Path) { $Path } else { $LiteralPath }
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

    It 'installs PAC CLI on Windows with the configured MSI version' -Skip:(-not $IsWindows) {
        Set-Content -LiteralPath 'alm-config.psd1' -Value "@{ pacCliVersion = '2.13.1' }"

        $output = & (Join-Path $repoRoot 'pipelines/scripts/installdependencies.ps1') 6>&1 | Out-String

        (Get-Content -LiteralPath $env:PAC_TEST_ARGS -Raw).Trim() | Should -Be 'install 2.13.1'
        $output | Should -Match 'Installed PAC CLI version 2.13.1'
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://aka.ms/PowerAppsCLI' }
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'msiexec.exe' }
    }

    It 'adds bundled modules to PSModulePath using the platform separator' {
        $bundledModulesDirectory = Join-Path $script:dependencyDirectory 'modules'
        New-Item -ItemType Directory -Path $bundledModulesDirectory -Force | Out-Null
        Set-Content -LiteralPath 'alm-config.psd1' -Value "@{ scriptDependencies = @{ 'Rnwood.Dataverse.Data.PowerShell' = '3.2.1-preview.1' } }"

        & (Join-Path $repoRoot 'pipelines/scripts/installdependencies.ps1')

        $modulePathEntries = $env:PSModulePath -split [regex]::Escape([string][System.IO.Path]::PathSeparator)
        $modulePathEntries[0] | Should -Be $bundledModulesDirectory
        Should -Invoke Install-Module -Times 0 -Exactly
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
        if ($IsWindows) {
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'msiexec.exe' }
        }
        else {
            Should -Invoke dotnet -Times 1 -Exactly -ParameterFilter { $Operation -eq 'update' }
        }
        $expectedPacDirectory = if ($IsWindows) {
            Join-Path $env:LOCALAPPDATA 'Microsoft\PowerAppsCLI'
        }
        else {
            Join-Path $HOME '.alm4dataverse/tools'
        }
        (Get-Content -LiteralPath $env:GITHUB_PATH -Raw).Trim() | Should -Be $expectedPacDirectory
    }

    It 'rejects a resolved version below the default minimum even for floating selectors' {
        Mock Install-Module { [pscustomobject]@{ Version = '1.0.0' } }
        Set-Content -LiteralPath 'alm-config.psd1' -Value "@{ scriptDependencies = @{ 'Rnwood.Dataverse.Data.PowerShell' = '' } }"
        { & (Join-Path $repoRoot 'pipelines/scripts/installdependencies.ps1') } | Should -Throw '*less than the default minimum*'
        Should -Invoke Get-InstalledModule -Times 0 -Exactly
    }

    It 'uses pinned lock-file module and CLI selectors' {
        Set-Content -LiteralPath 'alm-config.psd1' -Value '@{ pacCliVersion = "2.7.4" }'
        @{ scriptDependencies = @{ 'Rnwood.Dataverse.Data.PowerShell' = '3.2.1-preview.1' }; pacCliVersion = '2.7.4' } |
            ConvertTo-Json | Set-Content -LiteralPath 'scriptDependencies.lock.json'
        & (Join-Path $repoRoot 'pipelines/scripts/installdependencies.ps1')
        Should -Invoke Install-Module -Times 1 -Exactly -ParameterFilter { $RequiredVersion -eq '3.2.1-preview.1' -and $AllowPrerelease }
        if ($IsWindows) {
            (Get-Content -LiteralPath $env:PAC_TEST_ARGS -Raw).Trim() | Should -Be 'install 2.7.4'
        }
    }

    It 'does not resolve Node.js when no build was requested, even with code apps configured' {
        New-Item -ItemType Directory -Path (Join-Path $script:dependencyDirectory 'apps/code') -Force | Out-Null
        Set-Content -LiteralPath 'alm-config.psd1' -Value "@{ nodeVersion = 'invalid'; solutions = @(@{ name = 'Contoso'; codeApps = @('apps/code') }) }"
        { & (Join-Path $repoRoot 'pipelines/scripts/installdependencies.ps1') } | Should -Not -Throw
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly -ParameterFilter { $Uri -like 'https://nodejs.org/*' }
    }

    It 'does not resolve Node.js for BUILD when no code apps are configured' {
        Set-Content -LiteralPath 'alm-config.psd1' -Value "@{ nodeVersion = 'invalid'; solutions = @(@{ name = 'Contoso' }) }"
        { & (Join-Path $repoRoot 'pipelines/scripts/installdependencies.ps1') -ForBuild } | Should -Not -Throw
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly -ParameterFilter { $Uri -like 'https://nodejs.org/*' }
    }

    It 'validates nodeVersion only when BUILD has a configured code app' {
        New-Item -ItemType Directory -Path (Join-Path $script:dependencyDirectory 'apps/code') -Force | Out-Null
        Set-Content -LiteralPath 'alm-config.psd1' -Value "@{ nodeVersion = 'invalid'; solutions = @(@{ name = 'Contoso'; codeApps = @('apps/code') }) }"
        { & (Join-Path $repoRoot 'pipelines/scripts/installdependencies.ps1') -ForBuild } | Should -Throw '*nodeVersion*invalid*'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly -ParameterFilter { $Uri -like 'https://nodejs.org/*' }
    }

    It 'uses an installed Node version matching the configured <VersionKind>' -ForEach @(
        @{ VersionKind = 'major' }
        @{ VersionKind = 'exact version' }
    ) {
        $nodeRuntime = $script:availableNodeRuntime
        $versionSpecifier = if ($VersionKind -eq 'major') { [string]$nodeRuntime.Version.Major } else { $nodeRuntime.Version.ToString() }
        Set-Variable -Name HOME -Value $script:dependencyDirectory -Scope Global -Force
        New-Item -ItemType Directory -Path (Join-Path $script:dependencyDirectory 'apps/code') -Force | Out-Null
        Set-Content -LiteralPath 'alm-config.psd1' -Value "@{ nodeVersion = '$versionSpecifier'; solutions = @(@{ name = 'Contoso'; codeApps = @('apps/code') }) }"
        $env:TEST_NODE_SOURCE = $nodeRuntime.Path
        $env:TEST_NPM_SOURCE = 'npm'
        { & (Join-Path $repoRoot 'pipelines/scripts/installdependencies.ps1') -ForBuild } | Should -Not -Throw
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly -ParameterFilter { $Uri -like 'https://nodejs.org/*' }
    }

    It 'uses the newest cached Node version when the existing Node command is invalid' -Skip:$IsWindows {
        $nodeRuntime = $script:availableNodeRuntime
        $platform = if ($IsWindows) { 'win-x64' } else { 'linux-x64' }
        $cachedDirectory = Join-Path $script:dependencyDirectory ".alm4dataverse/tools/node/v$($nodeRuntime.Version)-$platform"
        $cachedNodePath = Join-Path $cachedDirectory $(if ($IsWindows) { 'node.exe' } else { 'bin/node' })
        Set-Variable -Name HOME -Value $script:dependencyDirectory -Scope Global -Force
        New-Item -ItemType Directory -Path (Join-Path $script:dependencyDirectory 'apps/code'), (Split-Path -Parent $cachedNodePath) -Force | Out-Null
        Get-TestNodeLink -Path $cachedNodePath -Target $nodeRuntime.Path
        Set-Content -LiteralPath 'alm-config.psd1' -Value "@{ nodeVersion = '$($nodeRuntime.Version.Major)'; solutions = @(@{ name = 'Contoso'; codeApps = @('apps/code') }) }"
        $env:TEST_NODE_SOURCE = 'pwsh'
        { & (Join-Path $repoRoot 'pipelines/scripts/installdependencies.ps1') -ForBuild } | Should -Not -Throw
        (Get-Content -LiteralPath $env:GITHUB_PATH -Raw) -split "`r?`n" |
            Should -Contain (Split-Path -Parent $cachedNodePath)
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'downloads and installs a verified Node archive' {
        $runtimeVersion = $script:availableNodeRuntime.Version.ToString()
        $platformArchitecture = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
            'X64' { 'x64' }
            'Arm64' { 'arm64' }
            'Arm' { 'armv7l' }
            default { throw "Unsupported test architecture '$([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)'." }
        }
        $platform = "$(if ($IsWindows) { 'win' } else { 'linux' })-$platformArchitecture"
        $archiveDirectoryName = "node-v$runtimeVersion-$platform"
        $archiveExtension = if ($IsWindows) { 'zip' } else { 'tar.xz' }
        $script:nodeArchiveName = "node-v$runtimeVersion-$platform.$archiveExtension"
        $archiveSourceDirectory = Join-Path $script:dependencyDirectory 'node-archive'
        $nodeDirectory = Join-Path $archiveSourceDirectory $archiveDirectoryName
        if (-not $IsWindows) {
            $nodeDirectory = Join-Path $nodeDirectory 'bin'
        }
        New-Item -ItemType Directory -Path $nodeDirectory -Force | Out-Null
        if ($IsWindows) {
            Copy-Item -LiteralPath $script:availableNodeRuntime.Path -Destination (Join-Path $nodeDirectory 'node.exe')
            Set-Content -LiteralPath (Join-Path $nodeDirectory 'npm.cmd') -Value '@exit /b 0'
        }
        else {
            $nodeScriptPath = Join-Path $nodeDirectory 'node'
            Set-Content -LiteralPath $nodeScriptPath -Value "#!/bin/sh`necho v$runtimeVersion`n" -NoNewline
            Set-Content -LiteralPath (Join-Path $nodeDirectory 'npm') -Value "#!/bin/sh`nexit 0`n" -NoNewline
            foreach ($scriptPath in @($nodeScriptPath, (Join-Path $nodeDirectory 'npm'))) {
                [System.IO.File]::SetUnixFileMode(
                    $scriptPath,
                    [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite -bor [System.IO.UnixFileMode]::UserExecute
                )
            }
        }
        $script:nodeArchivePath = Join-Path $script:dependencyDirectory $script:nodeArchiveName
        if ($IsWindows) {
            Compress-Archive -Path (Join-Path $archiveSourceDirectory $archiveDirectoryName) -DestinationPath $script:nodeArchivePath -Force
        }
        else {
            & $script:tarExecutable -cJf $script:nodeArchivePath -C $archiveSourceDirectory $archiveDirectoryName
            if ($LASTEXITCODE -ne 0) {
                throw 'Failed to create the test Node.js archive.'
            }
        }
        $script:nodeArchiveChecksum = (Get-FileHash -LiteralPath $script:nodeArchivePath -Algorithm SHA256).Hash

        New-Item -ItemType Directory -Path (Join-Path $script:dependencyDirectory 'apps/code') -Force | Out-Null
        Set-Content -LiteralPath 'alm-config.psd1' -Value "@{ nodeVersion = '$runtimeVersion'; solutions = @(@{ name = 'Contoso'; codeApps = @('apps/code') }) }"
        $env:TEST_NODE_ARCHIVE_PATH = $script:nodeArchivePath
        $env:TEST_NODE_ARCHIVE_CHECKSUM = $script:nodeArchiveChecksum
        $env:TEST_NODE_ARCHIVE_NAME = $script:nodeArchiveName
        Mock Invoke-WebRequest {
            if ($Uri -like '*SHASUMS256.txt') {
                $checksumLine = "$env:TEST_NODE_ARCHIVE_CHECKSUM *$env:TEST_NODE_ARCHIVE_NAME"
                [System.IO.File]::WriteAllText($OutFile, $checksumLine, [System.Text.Encoding]::ASCII)
            }
            else {
                Copy-Item -LiteralPath $env:TEST_NODE_ARCHIVE_PATH -Destination $OutFile
            }
        }

        & (Join-Path $repoRoot 'pipelines/scripts/installdependencies.ps1') -ForBuild

        $installedNodeDirectory = Join-Path $HOME ".alm4dataverse/tools/node/v$runtimeVersion-$platform"
        $installedNodePath = Join-Path $installedNodeDirectory $(if ($IsWindows) { 'node.exe' } else { 'bin/node' })
        $installedVersionOutput = @(& $installedNodePath --version 2>&1)
        $installedVersionOutput | Should -Contain "v$runtimeVersion"
        $installedNpmPath = Join-Path $installedNodeDirectory $(if ($IsWindows) { 'npm.cmd' } else { 'bin/npm' })
        Test-Path -LiteralPath $installedNpmPath | Should -BeTrue
        (Get-Content -LiteralPath $env:GITHUB_PATH -Raw) -split "`r?`n" |
            Should -Contain $(if ($IsWindows) { $installedNodeDirectory } else { Join-Path $installedNodeDirectory 'bin' })
        Should -Invoke Invoke-WebRequest -Times 2 -Exactly -ParameterFilter { $Uri -like 'https://nodejs.org/*' }
    }

    It 'accepts PAC selector <Selector>' -ForEach @(
        @{ Selector = '' }
        @{ Selector = 'prerelease' }
        @{ Selector = '2.7.4-preview.1' }
    ) {
        Set-Content -LiteralPath 'alm-config.psd1' -Value "@{ pacCliVersion = '$Selector' }"
        if ($IsWindows -and $Selector -eq 'prerelease') {
            { & (Join-Path $repoRoot 'pipelines/scripts/installdependencies.ps1') } | Should -Throw '*prerelease*not supported*'
        }
        else {
            { & (Join-Path $repoRoot 'pipelines/scripts/installdependencies.ps1') } | Should -Not -Throw
        }
    }

    It 'rejects invalid CLI versions before calling dotnet' {
        Set-Content -LiteralPath 'alm-config.psd1' -Value '@{ pacCliVersion = "invalid" }'
        { & (Join-Path $repoRoot 'pipelines/scripts/installdependencies.ps1') } | Should -Throw '*pacCliVersion*invalid*'
        Should -Invoke dotnet -Times 0 -Exactly
    }

    It 'fails when dotnet is unavailable' -Skip:$IsWindows {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'dotnet' }
        Set-Content -LiteralPath 'alm-config.psd1' -Value '@{}'
        { & (Join-Path $repoRoot 'pipelines/scripts/installdependencies.ps1') } | Should -Throw '*dotnet command not found*'
    }

    It 'fails when the installed CLI version cannot be resolved' {
        Mock dotnet { $global:LASTEXITCODE = 0; 'No matching package' }
        $env:TEST_PAC_BAD_VERSION = 'true'
        Set-Content -LiteralPath 'alm-config.psd1' -Value '@{}'
        if ($IsWindows) {
            { & (Join-Path $repoRoot 'pipelines/scripts/installdependencies.ps1') } | Should -Throw '*installed version could not be resolved from pac output*'
        }
        else {
            { & (Join-Path $repoRoot 'pipelines/scripts/installdependencies.ps1') } | Should -Throw '*installed package version could not be resolved*'
        }
    }

    It 'fails when the installed PowerShell module cannot be located' {
        Mock Get-InstalledModule { $null }
        Set-Content -LiteralPath 'alm-config.psd1' -Value '@{}'
        { & (Join-Path $repoRoot 'pipelines/scripts/installdependencies.ps1') } | Should -Throw '*Failed to find installed module*'
    }
}
