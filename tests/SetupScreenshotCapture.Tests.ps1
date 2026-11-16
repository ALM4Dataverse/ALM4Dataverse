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

        $scenes.Count | Should -Be 45
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
        $scenes.Name | Should -Contain 'azdo-authentication'
        $scenes.Name | Should -Contain 'azdo-project-selection'
        $scenes.Name | Should -Contain 'azdo-main-repository-selection'
        $scenes.Name | Should -Contain 'azdo-shared-repository-selection'
        $scenes.Name | Should -Contain 'azdo-extension-mode'
        $scenes.Name | Should -Contain 'azdo-shared-repository-version'
        $scenes.Name | Should -Contain 'github-authentication'
        $scenes.Name | Should -Contain 'github-application-repository'
        $scenes.Name | Should -Contain 'github-shared-workflow-repository'
        $scenes.Name | Should -Contain 'solutions-configuration'
        $scenes.Name | Should -Contain 'github-oidc-identity'
        $scenes.Name | Should -Contain 'azdo-apply-changes'
        $scenes.Name | Should -Contain 'github-apply-changes'
        $scenes.Name | Should -Contain 'github-build-validation'
        $scenes.Name | Should -Contain 'azdo-build-validation'
        ($scenes | Where-Object Name -eq 'github-menu-new-repository').ExpectedText |
            Should -Be 'main'
        ($scenes | Where-Object Name -eq 'azdo-menu-new-repository').ExpectedText |
            Should -Be 'main'
        ($scenes | Where-Object Name -eq 'github-menu-existing-repository').ExpectedText |
            Should -Be 'Deployment: PROD (main)'
        ($scenes | Where-Object Name -eq 'azdo-menu-existing-repository').ExpectedText |
            Should -Be 'Deployment: PROD (main)'
        ($scenes | Where-Object Name -eq 'github-menu-unavailable-shared-repository').ExpectedText |
            Should -Be 'Unavailable:'
        ($scenes | Where-Object Name -eq 'azdo-menu-unavailable-shared-repository').ExpectedText |
            Should -Be 'Unavailable:'
        ($scenes | Where-Object Name -eq 'setup-mode-choice').ExpectedText |
            Should -Be 'Configure an existing repository'
        ($scenes | Where-Object Name -eq 'azdo-project-selection').ExpectedText |
            Should -Be 'Example project'
        ($scenes | Where-Object Name -eq 'deployment-short-name').ExpectedText |
            Should -Be 'Enter a short name for this environment >'
        ($scenes | Where-Object Name -eq 'azdo-deployment-short-name').ExpectedText |
            Should -Be 'Enter a short name for this environment >'
        ($scenes | Where-Object Name -eq 'azdo-setup-change-review').ExpectedText |
            Should -Be 'Modified: alm-config.psd1'
        ($scenes | Where-Object Name -eq 'setup-change-side-by-side-diff').ExpectedText |
            Should -Be 'Up/Down=scroll'
    }

    It 'resolves a scene case-insensitively and rejects an unknown scene' {
        (Resolve-CaptureScene -SceneName 'BRANCH-STRATEGY').Name | Should -Be 'branch-strategy'
        { Resolve-CaptureScene -SceneName 'not-a-scene' } | Should -Throw '*Unknown screenshot scene*'
    }

    It 'defines interactive walkthrough steps in the requested setup order' {
        $steps = @(Get-CaptureWalkthroughStep)
        $availableSceneNames = @(Get-CaptureScene | ForEach-Object Name)
        $expectedSceneNames = @(
            'setup-mode-choice'
            'azdo-authentication'
            'azdo-project-selection'
            'azdo-main-repository-selection'
            'azdo-shared-repository-selection'
            'branch-strategy'
            'azdo-dev-environment-selection'
            'azdo-deployment-short-name'
            'branch-mapping'
            'azdo-authentication-type'
            'azdo-setup-change-review'
            'azdo-apply-changes'
            'github-menu-existing-repository'
        )

        $steps.Count | Should -Be $expectedSceneNames.Count
        ($steps.SceneName -join '|') | Should -Be ($expectedSceneNames -join '|')
        foreach ($step in $steps) {
            $step.SceneName | Should -BeIn $availableSceneNames
            @($step.CaptionLines).Count | Should -BeGreaterThan 0
            $step.CaptionLines | Should -Not -Contain ''
        }
        $modeChoiceStep = $steps | Where-Object SceneName -EQ 'setup-mode-choice'
        $modeChoiceStep.Interactions[0].WaitForText |
            Should -Be 'Configure an existing repository'
        $modeChoiceStep.ExpectedText | Should -Be 'v0.0.0'
        $projectSelectionStep = $steps | Where-Object SceneName -EQ 'azdo-project-selection'
        $projectSelectionStep.Interactions[0].WaitForText | Should -Be 'Example project'
        $projectSelectionStep.ExpectedText | Should -Be 'Create a new repository'
        $mainRepositoryStep = $steps | Where-Object SceneName -EQ 'azdo-main-repository-selection'
        $mainRepositoryStep.Interactions[0].WaitForText | Should -Be 'Create a new repository'
        $mainRepositoryStep.Interactions[1].WaitForText |
            Should -Be 'Enter the name for the new main repository >'
        $sharedRepositoryStep = $steps | Where-Object SceneName -EQ 'azdo-shared-repository-selection'
        $sharedRepositoryStep.Interactions[0].WaitForText |
            Should -Be 'Create a new repository'
        $sharedRepositoryStep.Interactions[0].Input |
            Should -Be "$([char]27)[B`r"
        $sharedRepositoryStep.Interactions[1].WaitForText |
            Should -Be 'Enter the name for the shared repository >'
        $sharedRepositoryStep.Interactions[2].WaitForText |
            Should -Be "Create shared repository 'ALM4Dataverse'"
        $sharedRepositoryStep.Interactions[2].Input | Should -Be "y`r"
        $mainRepositoryStep.ExpectedText |
            Should -Be "Created repository 'contoso-dataverse'."
        $mainRepositoryStep.Interactions[1].Input |
            Should -Be "contoso-dataverse`r"
        ($steps[0].CaptionLines -join ' ') | Should -Match '^Launch setup'
        ($steps[1].CaptionLines -join ' ') | Should -Match 'Azure DevOps'
        $environmentStep = $steps | Where-Object SceneName -EQ 'azdo-dev-environment-selection'
        $environmentStep.ExpectedText | Should -Be 'UAT'
        @($environmentStep.Interactions | Where-Object WaitForText -Like 'Select a deployment environment*').Count |
            Should -Be 3
        $shortNameStep = $steps | Where-Object SceneName -EQ 'azdo-deployment-short-name'
        $shortNameStep.ExpectedText | Should -Be 'Enter a short name for this environment >'
        $shortNameStep.Interactions[0].WaitForText | Should -Be 'Enter a short name for this environment >'
        $shortNameStep.Interactions[0].Input | Should -Be 'TEST'
        $authenticationStep = $steps | Where-Object SceneName -EQ 'azdo-authentication-type'
        ($authenticationStep.CaptionLines -join ' ') | Should -Match 'Workload identity federation'
        ($authenticationStep.CaptionLines -join ' ') | Should -Match 'avoids secrets'
        $reviewStep = $steps | Where-Object SceneName -EQ 'azdo-setup-change-review'
        ($reviewStep.CaptionLines -join ' ') | Should -Match 'file changes'
        $reviewStep.ExpectedText | Should -Be 'Up/Down=scroll'
        $applyStep = $steps | Where-Object SceneName -EQ 'azdo-apply-changes'
        $applyStep.ExpectedText | Should -Be 'Azure DevOps ALM4Dataverse setup menu'
        $existingMenuStep = $steps | Where-Object SceneName -EQ 'github-menu-existing-repository'
        $existingMenuStep.ExpectedText | Should -Be 'Deployment: PROD (main)'
        $reviewStep.Interactions[0].WaitForText | Should -Be 'Modified: alm-config.psd1'
        ($steps[-1].CaptionLines -join ' ') | Should -Match 'GitHub Actions'
    }

    It 'enables animation only for a full capture when it is not skipped' {
        Test-CaptureWalkthroughEnabled | Should -BeTrue
        Test-CaptureWalkthroughEnabled -SceneName 'branch-strategy' | Should -BeFalse
        Test-CaptureWalkthroughEnabled -SkipAnimation | Should -BeFalse
    }

    It 'keeps special input atomic and splits typed text into characters' {
        $arrowAndEnter = @(Get-CaptureInputAction -InputText "$([char]27)[B`r")
        $arrowAndEnter.Count | Should -Be 2
        $arrowAndEnter[0].InputText | Should -Be "$([char]27)[B"
        $arrowAndEnter[0].IsTypingCharacter | Should -BeFalse
        $arrowAndEnter[1].InputText | Should -Be "`r"
        $arrowAndEnter[1].IsTypingCharacter | Should -BeFalse

        $choice = @(Get-CaptureInputAction -InputText "y`r")
        $choice.Count | Should -Be 2
        $choice[0].InputText | Should -Be 'y'
        $choice[0].IsTypingCharacter | Should -BeTrue
        $choice[1].IsTypingCharacter | Should -BeFalse

        $repositoryNameInput = "contoso-dataverse`r"
        $repositoryName = @(Get-CaptureInputAction -InputText $repositoryNameInput)
        $repositoryName.Count | Should -Be $repositoryNameInput.Length
        ($repositoryName.InputText -join '') | Should -Be $repositoryNameInput
        @($repositoryName | Where-Object IsTypingCharacter).Count |
            Should -Be ($repositoryNameInput.Length - 1)
    }

    It 'uses an explicit monospaced font for each supported platform' {
        Get-CaptureFontFamily -Platform 'Windows' | Should -Be 'Consolas'
        Get-CaptureFontFamily -Platform 'Linux' | Should -Be 'Noto Sans Mono'
        Get-CaptureFontFamily -Platform 'macOS' | Should -Be 'Menlo'
    }

    It 'resolves ffmpeg and explains how to skip animation when it is missing' {
        Mock Get-Command {
            [pscustomobject]@{ Source = '/usr/bin/ffmpeg' }
        } -ParameterFilter { $Name -eq 'ffmpeg' }

        Get-CaptureFfmpegExecutable | Should -Be '/usr/bin/ffmpeg'

        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'ffmpeg' }
        { Get-CaptureFfmpegExecutable } | Should -Throw '*Install ffmpeg or rerun with -SkipAnimation*'
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

    It 'captures terminal checkpoints before and after scene interactions' {
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
        Mock Save-CaptureFrame {
            Set-Content -LiteralPath $OutputPath -Value 'frame'
        }
        Mock Start-Sleep {}

        $frameDirectory = Join-Path $TestDrive 'checkpoints'
        $scene = [pscustomobject]@{
            Name = 'interactive-scene'
            Provider = 'common'
            ExpectedText = 'finished'
            Rows = 32
            Interactions = @([pscustomobject]@{ WaitForText = 'ready'; Input = "g`r" })
        }
        Invoke-CaptureScene `
            -Scene $scene `
            -RepositoryRoot $repositoryRoot `
            -OutputPath (Join-Path $TestDrive 'final.png') `
            -FontFamilyName 'Noto Sans Mono' `
            -FrameOutputDirectory $frameDirectory

        $terminal.SentText | Should -Contain 'g'
        $terminal.SentText | Should -Contain "`r"
        @(Get-ChildItem -LiteralPath $frameDirectory -Filter 'checkpoint-*.png').Count | Should -Be 3
        @(Get-ChildItem -LiteralPath $frameDirectory -Filter 'checkpoint-*.keycaps.txt').Count |
            Should -Be 0
        Test-Path -LiteralPath (Join-Path $frameDirectory 'checkpoint-001.typing.txt') |
            Should -BeFalse
        Test-Path -LiteralPath (Join-Path $frameDirectory 'checkpoint-002.typing.txt') |
            Should -BeTrue
        Test-Path -LiteralPath (Join-Path $frameDirectory 'checkpoint-003.typing.txt') |
            Should -BeFalse
        Should -Invoke Save-CaptureFrame -Times 4 -Exactly
    }

    It 'builds a typing walkthrough with a translucent caption footer' {
        $repositoryRoot = Join-Path $TestDrive 'walkthrough-repository'
        $screenshotDirectory = Join-Path $repositoryRoot 'docs/setup/screenshots'
        New-Item -Path $screenshotDirectory -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repositoryRoot 'logo.png') -Value 'logo'
        $steps = @(Get-CaptureWalkthroughStep)
        foreach ($step in $steps) {
            Set-Content -LiteralPath (Join-Path $screenshotDirectory "$($step.SceneName).png") -Value 'screenshot'
        }

        $script:walkthroughProcessCalls = [System.Collections.Generic.List[object]]::new()
        $script:walkthroughCaptureCalls = [System.Collections.Generic.List[object]]::new()
        $script:walkthroughCaptionTexts = [System.Collections.Generic.List[string]]::new()
        $script:walkthroughFrameManifest = ''
        Mock Invoke-CaptureProcess {
            $script:walkthroughProcessCalls.Add([pscustomobject]@{
                Arguments = @($Arguments)
                Operation = $Operation
                WorkingDirectory = $WorkingDirectory
            })
            if ($Operation -eq 'setup walkthrough intro frame') {
                $script:walkthroughTitle = [System.IO.File]::ReadAllText(
                    (Join-Path $WorkingDirectory 'walkthrough-title.txt')
                )
                $script:walkthroughSubtitle = [System.IO.File]::ReadAllText(
                    (Join-Path $WorkingDirectory 'walkthrough-subtitle.txt')
                )
            }
            elseif ($Operation -eq 'setup walkthrough scene frame') {
                $script:walkthroughCaptionTexts.Add(
                    [System.IO.File]::ReadAllText((Join-Path $WorkingDirectory 'walkthrough-caption.txt'))
                )
            }
            elseif ($Operation -eq 'setup walkthrough GIF encoding') {
                $script:walkthroughFrameManifest = [System.IO.File]::ReadAllText(
                    (Join-Path $WorkingDirectory 'walkthrough-frames.ffconcat')
                )
            }
            Set-Content -LiteralPath $Arguments[-1] -Value 'generated image' | Out-Null
        }
        Mock Invoke-CaptureScene {
            $script:walkthroughCaptureCalls.Add([pscustomobject]@{
                Name = $Scene.Name
                ExpectedText = $Scene.ExpectedText
                InteractionCount = @($Scene.Interactions).Count
                FrameOutputDirectory = $FrameOutputDirectory
            })
            New-Item -Path $FrameOutputDirectory -ItemType Directory -Force | Out-Null
            $checkpointCount = if (@($Scene.Interactions).Count -gt 0) { 2 } else { 1 }
            for ($checkpointIndex = 1; $checkpointIndex -le $checkpointCount; $checkpointIndex++) {
                $checkpointPath = Join-Path $FrameOutputDirectory ('checkpoint-{0:D3}.png' -f $checkpointIndex)
                Set-Content -LiteralPath $checkpointPath -Value 'terminal frame'
                if ($checkpointIndex -gt 1) {
                    [System.IO.File]::WriteAllText(
                        [System.IO.Path]::ChangeExtension($checkpointPath, '.typing.txt'),
                        'typing'
                    )
                }
            }
        }

        Invoke-CaptureWalkthrough `
            -RepositoryRoot $repositoryRoot `
            -ScreenshotDirectory $screenshotDirectory `
            -FfmpegExecutable '/usr/bin/ffmpeg' `
            -FontFamilyName 'Noto Sans Mono' |
            Should -Be 'Captured docs/setup/screenshots/setup-walkthrough.gif.'

        $expectedSceneFrameCount = 0
        foreach ($step in $steps) {
            $expectedSceneFrameCount += if (@($step.Interactions).Count -gt 0) { 2 } else { 1 }
        }
        $script:walkthroughProcessCalls.Count | Should -Be ($expectedSceneFrameCount + 2)
        $script:walkthroughCaptureCalls.Count | Should -Be $steps.Count
        ($script:walkthroughCaptureCalls.Name -join '|') | Should -Be ($steps.SceneName -join '|')
        $script:walkthroughCaptureCalls |
            ForEach-Object { $_.FrameOutputDirectory | Should -Not -BeNullOrEmpty }
        $script:walkthroughProcessCalls[0].Operation | Should -Be 'setup walkthrough intro frame'
        $introArguments = $script:walkthroughProcessCalls[0].Arguments -join ' '
        $introArguments | Should -Match 'color=c=0xffffff'
        $introArguments | Should -Match 'fontcolor=0x101820'
        $introArguments | Should -Match 'fontsize=18'
        $script:walkthroughTitle | Should -Be 'ALM4Dataverse  - automated setup'
        $script:walkthroughSubtitle |
            Should -Be 'the easiest way to get powerful ALM for Dataverse/D365/Power Platform set up in minutes'
        $script:walkthroughProcessCalls[1].Arguments | Should -Contain '-vf'
        $sceneArguments = $script:walkthroughProcessCalls[1].Arguments -join ' '
        $sceneArguments | Should -Match "font='Noto Sans Mono'"
        $sceneArguments | Should -Match 'color=0xffffff'
        $sceneArguments | Should -Match 'fontcolor=0x101820'
        $sceneArguments |
            Should -Match 'drawbox=x=0:y=680:w=1200:h=200:color=0xffffff@0\.85:t=fill'
        $sceneArguments |
            Should -Match 'drawbox=x=0:y=680:w=1200:h=5:color=0x2ea96b:t=fill'
        $sceneArguments | Should -Match 'y=724:line_spacing=4'
        $sceneArguments | Should -Not -Match 'keycap'
        $captionText = $script:walkthroughCaptionTexts -join "`n"
        $captionText | Should -Match 'Workload identity federation'
        $captionText | Should -Match 'avoids secrets'
        $captionText | Should -Match 'GitHub Actions'
        $gifArguments = $script:walkthroughProcessCalls[-1].Arguments
        $gifArguments | Should -Contain 'concat'
        $gifArguments | Should -Contain 'walkthrough-frames.ffconcat'
        $script:walkthroughFrameManifest | Should -Match 'duration 6'
        $script:walkthroughFrameManifest | Should -Match 'duration 0\.166666667'
        $gifArguments | Should -Contain '-loop'
        $gifArguments | Should -Contain '0'
        Test-Path -LiteralPath (Join-Path $repositoryRoot 'docs/setup/screenshots/setup-walkthrough.gif') |
            Should -BeTrue
    }

    It 'runs capture processes and reports non-zero exit codes' {
        $powerShellExecutable = Get-CapturePowerShellExecutable
        Invoke-CaptureProcess `
            -ExecutablePath $powerShellExecutable `
            -Arguments @('-NoLogo', '-NoProfile', '-Command', 'Write-Output capture-test') `
            -WorkingDirectory $TestDrive `
            -Operation 'process test'

        {
            Invoke-CaptureProcess `
                -ExecutablePath $powerShellExecutable `
                -Arguments @('-NoLogo', '-NoProfile', '-Command', 'Write-Error capture-test; exit 7') `
                -WorkingDirectory $TestDrive `
                -Operation 'failure test'
        } | Should -Throw '*exit code 7*'
    }

    It 'captures Azure DevOps deployment selection and target-name prompts' {
        $selectionInteractions = @((Get-CaptureScene | Where-Object Name -eq 'azdo-deployment-environment-selection').Interactions)
        $selectionInteractions.Count | Should -Be 2
        $selectionInteractions[0].WaitForText | Should -Be 'Add an environment'
        $selectionInteractions[1].WaitForText | Should -Be 'Dataverse environment'

        $shortNameScene = Get-CaptureScene | Where-Object Name -eq 'azdo-deployment-short-name'
        $shortNameScene.ExpectedText | Should -Be 'Enter a short name for this environment >'
        $githubShortNameScene = Get-CaptureScene | Where-Object Name -eq 'deployment-short-name'
        $githubShortNameScene.ExpectedText | Should -Be 'Enter a short name for this environment >'
        @($shortNameScene.Interactions).Count | Should -Be 0
    }

    It 'runs scene listing without installing or loading the capture runtime' {
        $listedScenes = @(& (Join-Path $repositoryRoot 'tools/SetupScreenshotCapture/Capture-SetupScreenshots.ps1') -ListScenes)

        $listedScenes.Count | Should -Be 45
        $listedScenes | Should -Contain 'branch-mapping'
        $listedScenes | Should -Contain 'environment-detail-menu'
        $listedScenes | Should -Contain 'setup-mode-choice'
        $listedScenes | Should -Contain 'azdo-authentication'
        $listedScenes | Should -Contain 'azdo-project-selection'
        $listedScenes | Should -Contain 'azdo-main-repository-selection'
        $listedScenes | Should -Contain 'azdo-shared-repository-selection'
        $listedScenes | Should -Contain 'azdo-apply-changes'
        $listedScenes | Should -Contain 'github-menu-new-repository'
        $listedScenes | Should -Contain 'azdo-menu-existing-repository'
        $listedScenes | Should -Contain 'github-menu-unavailable-shared-repository'
        $listedScenes | Should -Contain 'azdo-menu-unavailable-shared-repository'
        $listedScenes | Should -Contain 'github-build-validation'
        $listedScenes | Should -Contain 'azdo-build-validation'
        $listedScenes | Should -Contain 'github-setup-change-review'
        $listedScenes | Should -Contain 'azdo-setup-change-review'
        $listedScenes | Should -Contain 'setup-change-side-by-side-diff'
        $listedScenes | Should -Contain 'azdo-extension-mode'
        $listedScenes | Should -Contain 'azdo-shared-repository-version'
        $listedScenes | Should -Contain 'github-authentication'
        $listedScenes | Should -Contain 'github-application-repository'
        $listedScenes | Should -Contain 'github-shared-workflow-repository'
        $listedScenes | Should -Contain 'solutions-configuration'
        $listedScenes | Should -Contain 'github-oidc-identity'
        $listedScenes | Should -Contain 'github-apply-changes'
    }
}
