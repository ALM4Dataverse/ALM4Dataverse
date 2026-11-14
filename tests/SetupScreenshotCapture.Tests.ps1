class SetupScreenshotFakePtyOptions {
    [string]$Command
    [object]$Arguments
    [string]$WorkingDirectory
    [object]$Environment
    [int]$Columns
    [int]$Rows
    [string]$ConPtyLibraryPath
}

class SetupScreenshotFakeTerminalControl {
    [SetupScreenshotFakePtyOptions]$Options
    [object]$StartupInput

    [void]Start([SetupScreenshotFakePtyOptions]$Options, [object]$StartupInput) {
        $this.Options = $Options
        $this.StartupInput = $StartupInput
    }
}

BeforeAll {
    $repositoryRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repositoryRoot 'tools/SetupScreenshotCapture/Capture-SetupScreenshots.ps1')
}

Describe 'Setup screenshot capture infrastructure' {
    It 'defines all documented setup scenes and waits for visible content' {
        $scenes = @(Get-CaptureScene)

        $scenes.Count | Should -Be 32
        foreach ($scene in $scenes) {
            $scene.Name | Should -Not -BeNullOrEmpty
            $scene.Provider | Should -BeIn @('common', 'github', 'azdo')
            $scene.ExpectedText | Should -Not -BeNullOrEmpty
            $scene.Rows | Should -BeGreaterThan 0
        }
        $scenes.Name | Should -Contain 'branch-strategy'
        $scenes.Name | Should -Contain 'branch-mapping'
        $scenes.Name | Should -Contain 'azdo-deployment-environment-plan'
        $scenes.Name | Should -Contain 'environment-detail-menu'
        $scenes.Name | Should -Contain 'github-menu-new-repository'
        $scenes.Name | Should -Contain 'github-menu-existing-repository'
        $scenes.Name | Should -Contain 'github-menu-unavailable-shared-repository'
        $scenes.Name | Should -Contain 'azdo-menu-new-repository'
        $scenes.Name | Should -Contain 'azdo-menu-existing-repository'
        $scenes.Name | Should -Contain 'azdo-menu-unavailable-shared-repository'
        $scenes.Name | Should -Contain 'setup-mode-choice'
        $scenes.Name | Should -Contain 'github-build-validation'
        $scenes.Name | Should -Contain 'azdo-build-validation'
        ($scenes | Where-Object Name -eq 'github-menu-new-repository').ExpectedText |
            Should -Be 'main (no envs)'
        ($scenes | Where-Object Name -eq 'azdo-menu-new-repository').ExpectedText |
            Should -Be 'main (no envs)'
        ($scenes | Where-Object Name -eq 'github-menu-existing-repository').ExpectedText |
            Should -Be 'main (PROD)'
        ($scenes | Where-Object Name -eq 'azdo-menu-existing-repository').ExpectedText |
            Should -Be 'main (PROD)'
        ($scenes | Where-Object Name -eq 'github-menu-unavailable-shared-repository').ExpectedText |
            Should -Be 'Unavailable:'
        ($scenes | Where-Object Name -eq 'azdo-menu-unavailable-shared-repository').ExpectedText |
            Should -Be 'Unavailable:'
    }

    It 'resolves a scene case-insensitively and rejects an unknown scene' {
        (Resolve-CaptureScene -SceneName 'BRANCH-STRATEGY').Name | Should -Be 'branch-strategy'
        { Resolve-CaptureScene -SceneName 'not-a-scene' } | Should -Throw '*Unknown screenshot scene*'
    }

    It 'uses an explicit monospaced font for each supported platform' {
        Get-CaptureFontFamily -Platform 'Windows' | Should -Be 'Consolas'
        Get-CaptureFontFamily -Platform 'Linux' | Should -Be 'Noto Sans Mono'
        Get-CaptureFontFamily -Platform 'macOS' | Should -Be 'Menlo'
    }

    It 'uses platform-specific package caches' {
        (Get-CaptureCacheRoot -Platform 'Linux') |
            Should -Be (Join-Path $HOME '.cache/alm4dataverse/setup-screenshot-capture')
        (Split-Path (Get-CaptureCacheRoot -Platform 'Windows') -Leaf) |
            Should -Be 'SetupScreenshotCapture'
    }

    It 'selects native NuGet dependencies for each supported platform' {
        $windowsPackages = @(Get-CapturePackageSpecification -Platform 'Windows')
        $linuxPackages = @(Get-CapturePackageSpecification -Platform 'Linux')
        $macPackages = @(Get-CapturePackageSpecification -Platform 'macOS')

        $windowsPackages.Id | Should -Contain 'HarfBuzzSharp.NativeAssets.Win32'
        $windowsPackages.Id | Should -Contain 'SkiaSharp.NativeAssets.Win32'
        $linuxPackages.Id | Should -Contain 'HarfBuzzSharp.NativeAssets.Linux'
        $linuxPackages.Id | Should -Contain 'SkiaSharp.NativeAssets.Linux'
        $macPackages.Id | Should -Contain 'HarfBuzzSharp.NativeAssets.macOS'
        $macPackages.Id | Should -Contain 'SkiaSharp.NativeAssets.macOS'
    }

    It 'selects one executable when PowerShell is discoverable in several PATH locations' {
        Mock Get-Command {
            @(
                [pscustomobject]@{ Source = '/first/pwsh'; Name = 'pwsh'; CommandType = 'Application' },
                [pscustomobject]@{ Source = '/second/pwsh'; Name = 'pwsh'; CommandType = 'Application' }
            )
        } -ParameterFilter { $Name -eq 'pwsh' }

        Get-CapturePowerShellExecutable | Should -Be '/first/pwsh'
    }

    It 'starts the selected PowerShell executable with the generated harness in a PTY' {
        Mock Get-CaptureType { [SetupScreenshotFakePtyOptions] } -ParameterFilter {
            $TypeName -eq 'Terminal.Pty.PtyOptions'
        }
        $terminal = [SetupScreenshotFakeTerminalControl]::new()
        $scene = (Resolve-CaptureScene -SceneName 'branch-strategy')[0]

        Connect-CaptureTerminal -Terminal $terminal -Scene $scene -RepositoryRoot $repositoryRoot

        $terminal.Options.Command | Should -Be (Get-CapturePowerShellExecutable)
        $terminal.Options.Arguments | Should -Contain '-Command'
        $terminal.Options.Arguments[-1] | Should -Match 'Select-BranchEnvironmentMapping'
        $terminal.Options.WorkingDirectory | Should -Be $repositoryRoot
        $terminal.Options.Environment['TERM'] | Should -Be 'xterm-256color'
        $terminal.StartupInput | Should -BeNullOrEmpty
    }

    It 'escapes repository paths as PowerShell string literals' {
        ConvertTo-PowerShellLiteral -Value "C:\setup's files" | Should -Be "'C:\setup''s files'"
    }

    It 'parses the generated setup harness' {
        $harness = Get-CaptureHarness -RepositoryRoot "C:\repo\quoted's path" -Provider 'github' -SceneName 'branch-strategy'
        $tokens = $null
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseInput($harness, [ref]$tokens, [ref]$parseErrors) | Out-Null

        $parseErrors.Count | Should -Be 0
        $harness.Contains("C:\repo\quoted''s path") | Should -BeTrue
        $harness.Contains("'branch-strategy'") | Should -BeTrue
        $harness | Should -Match 'docs/setup/github-setup.md'

        $azdoHarness = Get-CaptureHarness -RepositoryRoot 'C:\repo' -Provider 'azdo' -SceneName 'branch-strategy'
        $azdoHarness | Should -Match 'docs/setup/azdo-automated-setup.md'
    }

    It 'finds packages already available in the global NuGet cache' {
        $globalPackageRoot = Join-Path $TestDrive 'global-packages'
        $packageDirectory = Join-Path $globalPackageRoot 'sample.package/1.2.3'
        New-Item -Path $packageDirectory -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $packageDirectory 'Sample.Package.nuspec') -Value '<package />'

        Get-NuGetPackageDirectory `
            -Id 'Sample.Package' `
            -Version '1.2.3' `
            -PackageCacheRoot (Join-Path $TestDrive 'download-cache') `
            -GlobalPackageRoot $globalPackageRoot |
            Should -Be $packageDirectory
    }

    It 'uses and falls back from the NuGet global package override' {
        $originalPackageRoot = $env:NUGET_PACKAGES
        try {
            $env:NUGET_PACKAGES = $TestDrive
            Get-CaptureGlobalNuGetPackagesRoot | Should -Be $TestDrive

            Remove-Item Env:NUGET_PACKAGES -ErrorAction SilentlyContinue
            Get-CaptureGlobalNuGetPackagesRoot | Should -Be (Join-Path $HOME '.nuget/packages')
        }
        finally {
            if ($null -eq $originalPackageRoot) {
                Remove-Item Env:NUGET_PACKAGES -ErrorAction SilentlyContinue
            }
            else {
                $env:NUGET_PACKAGES = $originalPackageRoot
            }
        }
    }

    It 'reports NuGet download failures without hiding the package identity' {
        Mock Invoke-WebRequest { throw 'Reserved test download failure' }

        {
            Get-NuGetPackageDirectory `
                -Id 'Missing.Package' `
                -Version '1.0.0' `
                -PackageCacheRoot (Join-Path $TestDrive 'package-download-failure') `
                -GlobalPackageRoot (Join-Path $TestDrive 'missing-global-cache')
        } | Should -Throw "*Could not download NuGet package 'Missing.Package' version '1.0.0'*"
    }

    It 'prefers the newest compatible managed package asset' {
        $packageDirectory = Join-Path $TestDrive 'managed-package'
        New-Item -Path (Join-Path $packageDirectory 'lib/netstandard2.0') -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $packageDirectory 'lib/net8.0') -ItemType Directory -Force | Out-Null

        Get-CaptureManagedAssetDirectory -PackageDirectory $packageDirectory |
            Should -Be (Join-Path $packageDirectory 'lib/net8.0')
    }

    It 'reports packages without managed libraries' {
        {
            Get-CaptureManagedAssetDirectory -PackageDirectory (Join-Path $TestDrive 'empty-managed-package')
        } | Should -Throw '*no compatible managed library assets*'
    }

    It 'selects platform-native assets and reports missing package assets' {
        $linuxPackageDirectory = Join-Path $TestDrive 'linux-native'
        New-Item -Path (Join-Path $linuxPackageDirectory 'runtimes/linux-x64/native') -ItemType Directory -Force | Out-Null
        Get-CaptureNativeAssetDirectory -PackageDirectory $linuxPackageDirectory -Platform 'Linux' -Architecture 'x64' |
            Should -Be (Join-Path $linuxPackageDirectory 'runtimes/linux-x64/native')

        { Get-CaptureNativeAssetDirectory -PackageDirectory $linuxPackageDirectory -Platform 'Windows' -Architecture 'x64' } |
            Should -Throw '*no native assets*'
    }

    It 'enforces the PowerShell and .NET versions required by the terminal package' {
        { Assert-CaptureRuntimePrerequisite -PowerShellVersion '7.5' -FrameworkDescription '.NET 9.0.0' } |
            Should -Throw '*requires PowerShell 7.6*'
        { Assert-CaptureRuntimePrerequisite -PowerShellVersion '7.6' -FrameworkDescription '.NET 9.0.0' } |
            Should -Throw '*requires .NET 10*'
        { Assert-CaptureRuntimePrerequisite -PowerShellVersion '7.6' -FrameworkDescription '.NET 10.0.0' } |
            Should -Not -Throw
    }

    It 'copies managed and native NuGet assets into the runtime directory' {
        $managedPackageDirectory = Join-Path $TestDrive 'packages/Demo.Managed/1.0.0'
        $nativePackageDirectory = Join-Path $TestDrive 'packages/Demo.Native/1.0.0'
        New-Item -Path (Join-Path $managedPackageDirectory 'lib/net10.0') -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $nativePackageDirectory 'runtimes/linux-x64/native') -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $managedPackageDirectory 'lib/net10.0/Demo.Managed.dll') -Value 'managed'
        Set-Content -LiteralPath (Join-Path $nativePackageDirectory 'runtimes/linux-x64/native/libDemoNative.so') -Value 'native'
        $script:fixturePackageDirectories = @{
            'Demo.Managed' = $managedPackageDirectory
            'Demo.Native' = $nativePackageDirectory
        }
        Mock Get-CapturePackageSpecification {
            @(
                [pscustomobject]@{ Id = 'Demo.Managed'; Version = '1.0.0'; Kind = 'Managed' },
                [pscustomobject]@{ Id = 'Demo.Native'; Version = '1.0.0'; Kind = 'Native' }
            )
        }
        Mock Get-NuGetPackageDirectory {
            param($Id)
            return $script:fixturePackageDirectories[$Id]
        }

        $runtimeDirectory = Join-Path $TestDrive 'runtime/linux/x64'
        $runtime = Install-CaptureRuntimeAsset `
            -CacheRoot (Join-Path $TestDrive 'cache') `
            -RuntimeDirectory $runtimeDirectory `
            -Platform 'Linux' `
            -Architecture 'x64' `
            -GlobalPackageRoot (Join-Path $TestDrive 'empty-global-cache')

        $runtime.ManagedAssemblyPaths | Should -Contain (Join-Path $runtimeDirectory 'Demo.Managed.dll')
        Test-Path -LiteralPath (Join-Path $runtimeDirectory 'libDemoNative.so') | Should -BeTrue
        $runtime.ConPtyLibraryPath | Should -BeNullOrEmpty
    }

    It 'lays out the matching ConPTY host files on Windows' {
        $ptyPackageDirectory = Join-Path $TestDrive 'packages/Terminal.Pty/0.4.5'
        $nativePackageDirectory = Join-Path $TestDrive 'packages/Demo.Native/1.0.0'
        New-Item -Path (Join-Path $ptyPackageDirectory 'lib/net10.0') -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $ptyPackageDirectory 'buildTransitive/conpty/x64') -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $nativePackageDirectory 'runtimes/win-x64/native') -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $ptyPackageDirectory 'lib/net10.0/Terminal.Pty.dll') -Value 'managed'
        Set-Content -LiteralPath (Join-Path $ptyPackageDirectory 'buildTransitive/conpty/x64/conpty.dll') -Value 'native'
        Set-Content -LiteralPath (Join-Path $ptyPackageDirectory 'buildTransitive/conpty/x64/OpenConsole.exe') -Value 'host'
        Set-Content -LiteralPath (Join-Path $nativePackageDirectory 'runtimes/win-x64/native/libDemoNative.dll') -Value 'native'
        $script:fixturePackageDirectories = @{
            'Terminal.Pty' = $ptyPackageDirectory
            'Demo.Native' = $nativePackageDirectory
        }
        Mock Get-CapturePackageSpecification {
            @(
                [pscustomobject]@{ Id = 'Terminal.Pty'; Version = '0.4.5'; Kind = 'Managed' },
                [pscustomobject]@{ Id = 'Demo.Native'; Version = '1.0.0'; Kind = 'Native' }
            )
        }
        Mock Get-NuGetPackageDirectory {
            param($Id)
            return $script:fixturePackageDirectories[$Id]
        }

        $runtimeDirectory = Join-Path $TestDrive 'runtime/windows/x64'
        $runtime = Install-CaptureRuntimeAsset `
            -CacheRoot (Join-Path $TestDrive 'cache') `
            -RuntimeDirectory $runtimeDirectory `
            -Platform 'Windows' `
            -Architecture 'x64' `
            -GlobalPackageRoot (Join-Path $TestDrive 'empty-global-cache')

        $runtime.ConPtyLibraryPath | Should -Be (Join-Path $runtimeDirectory 'conpty/x64/conpty.dll')
        Test-Path -LiteralPath $runtime.ConPtyLibraryPath | Should -BeTrue
        Test-Path -LiteralPath (Join-Path (Split-Path $runtime.ConPtyLibraryPath) 'OpenConsole.exe') | Should -BeTrue
    }

    It 'waits for terminal output and returns the visible screen' {
        $terminal = [pscustomobject]@{}
        $terminal | Add-Member -MemberType ScriptMethod -Name ReadScreenText -Value { @('Menu', 'Choose an environment') }
        Mock Invoke-CaptureDispatcherQueue {}

        Wait-ForTerminalText -Terminal $terminal -ExpectedText 'Choose an environment' -TimeoutSeconds 1 |
            Should -Match 'Choose an environment'
    }

    It 'filters terminal environment variables and provides color support' {
        $variableName = 'ALM4DATAVERSE_CAPTURE_TEST_VALUE'
        $previousValue = [System.Environment]::GetEnvironmentVariable($variableName)
        try {
            [System.Environment]::SetEnvironmentVariable($variableName, 'reserved example')
            $environment = Get-CaptureTerminalEnvironment

            $environment['TERM'] | Should -Be 'xterm-256color'
            $environment['COLORTERM'] | Should -Be 'truecolor'
            $environment.ContainsKey($variableName) | Should -BeFalse
        }
        finally {
            [System.Environment]::SetEnvironmentVariable($variableName, $previousValue)
        }
    }

    It 'resolves types from loaded assemblies and reports missing types' {
        (Get-CaptureType -TypeName 'System.String') | Should -Be ([string])
        { Get-CaptureType -TypeName 'Missing.CaptureType' } | Should -Throw '*was not loaded*'
    }

    It 'sends scene interactions and saves one rendered frame' {
        $terminal = [pscustomobject]@{ SentText = [System.Collections.Generic.List[string]]::new() }
        $terminal | Add-Member -MemberType ScriptMethod -Name SendText -Value {
            param($Value)
            $this.SentText.Add($Value)
            return $true
        }
        $terminal | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
        $window = [pscustomobject]@{}
        $window | Add-Member -MemberType ScriptMethod -Name Close -Value {}
        $script:fakeCaptureWindow = [pscustomobject]@{ Terminal = $terminal; Window = $window }
        Mock Open-CaptureTerminalWindow { $script:fakeCaptureWindow }
        Mock Connect-CaptureTerminal {}
        Mock Wait-ForTerminalText { "ALM4Dataverse Setup - $ExpectedText`nvisible terminal screen" }
        Mock Invoke-CaptureDispatcherQueue {}
        Mock Invoke-CaptureRenderTick {}
        Mock Save-CaptureFrame {}
        Mock Start-Sleep {}

        $scene = Resolve-CaptureScene -SceneName 'branch-name'
        Invoke-CaptureScene `
            -Scene $scene[0] `
            -RepositoryRoot $repositoryRoot `
            -OutputPath (Join-Path $TestDrive 'branch-name.png') `
            -FontFamilyName 'Noto Sans Mono'

        $terminal.SentText.Count | Should -Be 1
        $terminal.SentText[0] | Should -Be "`r"
        Should -Invoke Save-CaptureFrame -Times 1
        Should -Invoke Connect-CaptureTerminal -Times 1
        Should -Invoke Wait-ForTerminalText -Times 1 -Exactly -ParameterFilter {
            $ExpectedText -eq 'ALM4Dataverse Setup -'
        }
    }

    It 'captures Azure DevOps deployment selection and target-name prompts' {
        $selectionInteractions = @((Get-CaptureScene | Where-Object Name -eq 'azdo-deployment-environment-selection').Interactions)
        $selectionInteractions.Count | Should -Be 2
        $selectionInteractions[0].WaitForText | Should -Be 'Add an environment'
        $selectionInteractions[1].WaitForText | Should -Be 'Dataverse environment'

        $shortNameScene = Get-CaptureScene | Where-Object Name -eq 'azdo-deployment-short-name'
        $shortNameScene.ExpectedText | Should -Be 'Enter a short name for this environment'
        @($shortNameScene.Interactions).Count | Should -Be 0
    }

    It 'runs scene listing without installing or loading the capture runtime' {
        $listedScenes = @(& (Join-Path $repositoryRoot 'tools/SetupScreenshotCapture/Capture-SetupScreenshots.ps1') -ListScenes)

        $listedScenes.Count | Should -Be 32
        $listedScenes | Should -Contain 'branch-mapping'
        $listedScenes | Should -Contain 'environment-detail-menu'
        $listedScenes | Should -Contain 'setup-mode-choice'
        $listedScenes | Should -Contain 'github-menu-new-repository'
        $listedScenes | Should -Contain 'azdo-menu-existing-repository'
        $listedScenes | Should -Contain 'github-menu-unavailable-shared-repository'
        $listedScenes | Should -Contain 'azdo-menu-unavailable-shared-repository'
        $listedScenes | Should -Contain 'github-build-validation'
        $listedScenes | Should -Contain 'azdo-build-validation'
        $listedScenes | Should -Contain 'github-setup-change-review'
        $listedScenes | Should -Contain 'azdo-setup-change-review'
        $listedScenes | Should -Contain 'setup-change-side-by-side-diff'
    }
}
