<#
.SYNOPSIS
    Captures the current setup helper screens as PNGs and an interactive walkthrough GIF.
.PARAMETER Scene
    Captures one named scene instead of the full screenshot set. A single scene does
    not generate the walkthrough GIF.
.PARAMETER ListScenes
    Lists available scene names without loading capture dependencies.
.PARAMETER SkipAnimation
    Captures the full PNG set without generating the walkthrough GIF.
.DESCRIPTION
    Runs the real setup helper functions in a PTY-backed Terminal.Avalonia control
    and saves the rendered frames under docs/setup/screenshots. The walkthrough
    captures real terminal states around setup inputs, then creates
    setup-walkthrough.gif. Checkpoints stay on screen for six seconds, and typed
    text appears one character at a time. Captions sit over a semi-transparent
    white footer beneath a raised green divider. The tool downloads its pinned
    NuGet dependencies on first use. It requires PowerShell 7.6 or newer on .NET
    10 or newer and a platform monospaced font: Consolas on Windows, Noto Sans
    Mono on Linux, or Menlo on macOS. Full captures require ffmpeg with drawtext
    and fontconfig support; use -SkipAnimation for PNG-only captures.
.NOTES
    Provider API calls are stubbed and all displayed values are reserved examples.
    No GitHub, Azure DevOps, Entra ID, or Dataverse resources are accessed.
#>
[CmdletBinding()]
param(
    [Parameter()][string]$Scene,
    [Parameter()][switch]$ListScenes,
    [Parameter()][switch]$SkipAnimation
)

$script:CaptureTerminalWidth = 1600
$script:CaptureTerminalColumns = 100
$script:CaptureTerminalFontSize = 20
$script:CaptureScreenshotRelativePath = 'docs/setup/screenshots'
$script:CaptureWalkthroughRelativePath = 'docs/setup/screenshots/setup-walkthrough.gif'
$script:CaptureWalkthroughWidth = 1200
$script:CaptureWalkthroughHeight = 880
$script:CaptureWalkthroughContentWidth = 1160
$script:CaptureWalkthroughContentHeight = 720
$script:CaptureWalkthroughFooterHeight = 200
$script:CaptureWalkthroughOutputFrameRate = 6
$script:CaptureWalkthroughDwellSeconds = 6
$script:CaptureWalkthroughTypingFrameDurationSeconds = 1.0 / $script:CaptureWalkthroughOutputFrameRate

function Get-CapturePlatformName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][string]$Platform)

    if (-not [string]::IsNullOrWhiteSpace($Platform)) {
        return $Platform
    }

    if ($IsWindows) {
        return 'Windows'
    }
    if ($IsMacOS) {
        return 'macOS'
    }
    if ($IsLinux) {
        return 'Linux'
    }

    throw 'The screenshot capture tool supports Windows, macOS, and Linux only.'
}

function Get-CaptureFontFamily {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][string]$Platform)

    switch (Get-CapturePlatformName -Platform $Platform) {
        'Windows' { return 'Consolas' }
        'macOS' { return 'Menlo' }
        'Linux' { return 'Noto Sans Mono' }
        default { throw "No monospaced capture font is configured for '$Platform'." }
    }
}

function Get-CaptureArchitecture {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][string]$Architecture)

    if (-not [string]::IsNullOrWhiteSpace($Architecture)) {
        return $Architecture.ToLowerInvariant()
    }

    return [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
}

function Get-CapturePackageSpecification {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter()][string]$Platform)

    $platformName = Get-CapturePlatformName -Platform $Platform
    $packages = [System.Collections.Generic.List[object]]::new()
    foreach ($package in @(
        @{ Id = 'Avalonia'; Version = '12.1.2' },
        @{ Id = 'Avalonia.Fonts.Inter'; Version = '12.1.2' },
        @{ Id = 'Avalonia.HarfBuzz'; Version = '12.1.2' },
        @{ Id = 'Avalonia.Headless'; Version = '12.1.2' },
        @{ Id = 'Avalonia.Remote.Protocol'; Version = '12.1.2' },
        @{ Id = 'Avalonia.Skia'; Version = '12.1.2' },
        @{ Id = 'HarfBuzzSharp'; Version = '8.3.1.3' },
        @{ Id = 'MicroCom.Runtime'; Version = '0.11.6' },
        @{ Id = 'SkiaSharp'; Version = '3.119.4' },
        @{ Id = 'Terminal.Avalonia'; Version = '0.4.5' },
        @{ Id = 'Terminal.Emulation'; Version = '0.4.5' },
        @{ Id = 'Terminal.Pty'; Version = '0.4.5' }
    )) {
        $packages.Add([pscustomobject]@{
            Id      = $package.Id
            Version = $package.Version
            Kind    = 'Managed'
        })
    }

    $nativeAssetPlatform = switch ($platformName) {
        'Windows' { 'Win32' }
        'macOS' { 'macOS' }
        'Linux' { 'Linux' }
        default { throw "No native package set is configured for '$platformName'." }
    }
    $packages.Add([pscustomobject]@{
        Id      = "HarfBuzzSharp.NativeAssets.$nativeAssetPlatform"
        Version = '8.3.1.3'
        Kind    = 'Native'
    })
    $packages.Add([pscustomobject]@{
        Id      = "SkiaSharp.NativeAssets.$nativeAssetPlatform"
        Version = '3.119.4'
        Kind    = 'Native'
    })

    return $packages.ToArray()
}

function Get-CaptureScene {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    return @(
        [pscustomobject]@{
            Name = 'setup-mode-choice'
            Provider = 'common'
            ExpectedText = 'Configure an existing repository'
            Rows = 36
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'azdo-authentication'
            Provider = 'azdo'
            ExpectedText = 'Use existing Azure login: automation@example.invalid'
            Rows = 32
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'azdo-project-selection'
            Provider = 'azdo'
            ExpectedText = 'Example project'
            Rows = 32
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'azdo-main-repository-selection'
            Provider = 'azdo'
            ExpectedText = 'Create a new repository'
            Rows = 32
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'azdo-shared-repository-selection'
            Provider = 'azdo'
            ExpectedText = 'Create a new repository'
            Rows = 32
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'azdo-extension-mode'
            Provider = 'azdo'
            ExpectedText = '[y/n]'
            Rows = 32
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'azdo-shared-repository-version'
            Provider = 'azdo'
            ExpectedText = '[y/n]'
            Rows = 32
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'github-authentication'
            Provider = 'github'
            ExpectedText = 'Use existing GitHub login: example-user'
            Rows = 32
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'github-application-repository'
            Provider = 'github'
            ExpectedText = 'Create a new repository'
            Rows = 32
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'github-shared-workflow-repository'
            Provider = 'github'
            ExpectedText = 'Use existing fork: example-org/ALM4Dataverse'
            Rows = 32
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'azdo-apply-changes'
            Provider = 'azdo'
            ExpectedText = 'Apply changes - Ready'
            Rows = 32
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'github-apply-changes'
            Provider = 'github'
            ExpectedText = 'Apply changes - Ready'
            Rows = 32
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'github-menu-new-repository'
            Provider = 'common'
            ExpectedText = 'main'
            Rows = 44
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'github-menu-existing-repository'
            Provider = 'common'
            ExpectedText = 'Deployment: PROD (main)'
            Rows = 48
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'github-menu-unavailable-shared-repository'
            Provider = 'common'
            ExpectedText = 'Unavailable:'
            Rows = 48
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'azdo-menu-new-repository'
            Provider = 'common'
            ExpectedText = 'main'
            Rows = 44
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'azdo-menu-existing-repository'
            Provider = 'common'
            ExpectedText = 'Deployment: PROD (main)'
            Rows = 48
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'azdo-menu-unavailable-shared-repository'
            Provider = 'common'
            ExpectedText = 'Unavailable:'
            Rows = 48
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'github-build-validation'
            Provider = 'github'
            ExpectedText = 'Contoso Test'
            Rows = 32
            Interactions = @(
                [pscustomobject]@{ WaitForText = 'Choose a branching strategy'; Input = "`r" },
                [pscustomobject]@{ WaitForText = "Enable Dataverse deployment validation during BUILD for branch 'main'"; Input = "y`r" }
            )
        },
        [pscustomobject]@{
            Name = 'azdo-build-validation'
            Provider = 'azdo'
            ExpectedText = 'Contoso Test'
            Rows = 32
            Interactions = @(
                [pscustomobject]@{ WaitForText = 'Choose a branching strategy'; Input = "`r" },
                [pscustomobject]@{ WaitForText = "Enable Dataverse deployment validation during BUILD for branch 'main'"; Input = "y`r" }
            )
        },
        [pscustomobject]@{
            Name = 'branch-strategy'
            Provider = 'common'
            ExpectedText = 'main only (recommended simple option)'
            Rows = 32
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'branch-name'
            Provider = 'common'
            ExpectedText = 'Branch name'
            Rows = 32
            Interactions = @([pscustomobject]@{ WaitForText = 'Add a branch mapping'; Input = "`r" })
        },
        [pscustomobject]@{
            Name = 'github-dev-confirmation'
            Provider = 'github'
            ExpectedText = '[y/n]'
            Rows = 32
            Interactions = @([pscustomobject]@{ WaitForText = 'Choose a branching strategy'; Input = "`r" })
        },
        [pscustomobject]@{
            Name = 'github-dev-environment-selection'
            Provider = 'github'
            ExpectedText = 'Contoso Development'
            Rows = 32
            Interactions = @(
                [pscustomobject]@{ WaitForText = 'Choose a branching strategy'; Input = "`r" },
                [pscustomobject]@{ WaitForText = "Configure a DEV Dataverse environment for branch 'main'"; Input = "y`r" }
            )
        },
        [pscustomobject]@{
            Name = 'github-credentials'
            Provider = 'github'
            ExpectedText = 'Reuse: Example deployment credential'
            Rows = 32
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'github-authentication-type'
            Provider = 'github'
            ExpectedText = 'Workload Identity Federation (recommended, no secrets)'
            Rows = 32
            Interactions = @([pscustomobject]@{ WaitForText = 'Select App Registration credentials'; Input = "`r" })
        },
        [pscustomobject]@{
            Name = 'github-service-account'
            Provider = 'github'
            ExpectedText = 'Reuse: automation@example.invalid'
            Rows = 32
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'solutions-configuration'
            Provider = 'common'
            ExpectedText = 'Add a solution'
            Rows = 40
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'github-oidc-identity'
            Provider = 'github'
            ExpectedText = '[y/n]'
            Rows = 32
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'github-deployment-environment-selection'
            Provider = 'github'
            ExpectedText = 'Contoso Test'
            Rows = 32
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'deployment-short-name'
            Provider = 'github'
            ExpectedText = 'Enter a short name for this environment >'
            Rows = 32
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'environment-detail-menu'
            Provider = 'common'
            ExpectedText = 'Contoso Test'
            Rows = 32
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'deployment-environment-plan'
            Provider = 'common'
            ExpectedText = 'Contoso Test'
            Rows = 32
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'branch-mapping'
            Provider = 'common'
            ExpectedText = 'develop'
            Rows = 32
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'azdo-dev-confirmation'
            Provider = 'azdo'
            ExpectedText = '[y/n]'
            Rows = 32
            Interactions = @([pscustomobject]@{ WaitForText = 'Choose a branching strategy'; Input = "`r" })
        },
        [pscustomobject]@{
            Name = 'azdo-dev-environment-selection'
            Provider = 'azdo'
            ExpectedText = 'Contoso Development'
            Rows = 32
            Interactions = @(
                [pscustomobject]@{ WaitForText = 'Choose a branching strategy'; Input = "`r" },
                [pscustomobject]@{ WaitForText = "Configure a DEV environment for branch 'main'"; Input = "`r" }
            )
        },
        [pscustomobject]@{
            Name = 'azdo-credentials'
            Provider = 'azdo'
            ExpectedText = 'Reuse: Example deployment credential'
            Rows = 32
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'azdo-authentication-type'
            Provider = 'azdo'
            ExpectedText = 'Workload Identity Federation (recommended, no secrets)'
            Rows = 32
            Interactions = @([pscustomobject]@{ WaitForText = 'Select Service Principal credentials'; Input = "`r" })
        },
        [pscustomobject]@{
            Name = 'azdo-service-account'
            Provider = 'azdo'
            ExpectedText = 'Reuse: automation@example.invalid'
            Rows = 32
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'azdo-deployment-environment-selection'
            Provider = 'azdo'
            ExpectedText = 'Contoso Test'
            Rows = 32
            Interactions = @(
                [pscustomobject]@{ WaitForText = 'Add an environment'; Input = "`r" },
                [pscustomobject]@{ WaitForText = 'Dataverse environment'; Input = "`r" }
            )
        },
        [pscustomobject]@{
            Name = 'azdo-deployment-short-name'
            Provider = 'azdo'
            ExpectedText = 'Enter a short name for this environment >'
            Rows = 32
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'azdo-deployment-environment-plan'
            Provider = 'azdo'
            ExpectedText = 'Contoso Test'
            Rows = 32
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'github-setup-change-review'
            Provider = 'common'
            ExpectedText = 'Modified: alm-config.psd1'
            Rows = 32
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'azdo-setup-change-review'
            Provider = 'common'
            ExpectedText = 'Modified: alm-config.psd1'
            Rows = 32
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'setup-change-side-by-side-diff'
            Provider = 'common'
            HasPromptHelp = $false
            ExpectedText = 'Up/Down=scroll'
            Rows = 32
            Interactions = @()
        }
    )
}

function Resolve-CaptureScene {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter()][string]$SceneName)

    $scenes = @(Get-CaptureScene)
    if ([string]::IsNullOrWhiteSpace($SceneName)) {
        return $scenes
    }

    $selectedScenes = @($scenes | Where-Object { $_.Name -ieq $SceneName })
    if ($selectedScenes.Count -eq 0) {
        throw "Unknown screenshot scene '$SceneName'. Run with -ListScenes to see valid names."
    }

    return $selectedScenes
}

function Get-CaptureWalkthroughStep {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    $enter = "`r"
    $arrowDown = "$([char]27)[B"

    return @(
        [pscustomobject]@{
            SceneName = 'setup-mode-choice'
            ExpectedText = 'v0.0.0'
            CaptionLines = @(
                'Launch setup.'
                'Choose a new or existing application repo.'
            )
            Interactions = @(
                [pscustomobject]@{
                    WaitForText = 'Configure an existing repository'
                    Input = $enter
                }
            )
            CaptureInitialFrame = $true
            CaptureFinalFrame = $false
            HasPromptHelp = $false
        },
        [pscustomobject]@{
            SceneName = 'azdo-authentication'
            ExpectedText = 'Example organization'
            CaptionLines = @(
                'Authenticate with Azure DevOps or GitHub'
                'and Azure for Dataverse access.'
            )
            Interactions = @(
                [pscustomobject]@{
                    WaitForText = 'Use existing Azure login: automation@example.invalid'
                    Input = $enter
                }
            )
            CaptureInitialFrame = $true
            # A single mocked organization renders as a bare '[y/n]' confirmation,
            # which is not the authentication screen this step documents.
            CaptureFinalFrame = $false
        },
        [pscustomobject]@{
            SceneName = 'azdo-project-selection'
            ExpectedText = 'Create a new repository'
            CaptionLines = @(
                'Select an existing project/repo'
                'or create a new one.'
            )
            Interactions = @(
                [pscustomobject]@{
                    WaitForText = 'Example project'
                    Input = $enter
                }
            )
            CaptureInitialFrame = $true
            CaptureFinalFrame = $true
        },
        [pscustomobject]@{
            SceneName = 'azdo-main-repository-selection'
            ExpectedText = "Created repository 'contoso-dataverse'."
            CaptionLines = @(
                'Name the application repository separately'
                'from the shared ALM4Dataverse repository.'
            )
            Interactions = @(
                [pscustomobject]@{
                    WaitForText = 'Create a new repository'
                    Input = $enter
                },
                [pscustomobject]@{
                    WaitForText = 'Enter the name for the new main repository >'
                    Input = "contoso-dataverse`r"
                }
            )
            CaptureInitialFrame = $true
            CaptureFinalFrame = $true
            HasPromptHelp = $false
        },
        [pscustomobject]@{
            SceneName = 'azdo-shared-repository-selection'
            ExpectedText = "Created shared repository 'ALM4Dataverse'."
            CaptionLines = @(
                'Choose the ALM4Dataverse template repository'
                'so it can be updated independently.'
            )
            Interactions = @(
                [pscustomobject]@{
                    WaitForText = 'Create a new repository'
                    Input = "$([char]27)[B`r"
                },
                [pscustomobject]@{
                    WaitForText = 'Enter the name for the shared repository >'
                    Input = "ALM4Dataverse`r"
                },
                [pscustomobject]@{
                    WaitForText = "Create shared repository 'ALM4Dataverse'"
                    Input = "y`r"
                }
            )
            CaptureInitialFrame = $true
            CaptureFinalFrame = $true
            HasPromptHelp = $false
        },
        [pscustomobject]@{
            SceneName = 'branch-strategy'
            ExpectedText = 'develop'
            CaptionLines = @(
                'Choose a branch strategy (allows isolation of changes and pull requests)'
                'or start simple with just a main branch.'
            )
            Interactions = @(
                [pscustomobject]@{
                    WaitForText = 'Choose a branching strategy for this repository'
                    Input = $arrowDown
                    CaptureAfter = $true
                },
                [pscustomobject]@{
                    WaitForText = 'Choose a branching strategy for this repository'
                    Input = $enter
                }
            )
            CaptureInitialFrame = $true
            CaptureFinalFrame = $true
        },
        [pscustomobject]@{
            SceneName = 'azdo-dev-environment-selection'
            ExpectedText = 'UAT'
            CaptionLines = @(
                'For each branch, select the DEV'
                'environment (optional) and its deployment targets.'
            )
            Interactions = @(
                [pscustomobject]@{
                    WaitForText = 'Choose a branching strategy for this repository'
                    Input = $arrowDown
                },
                [pscustomobject]@{
                    WaitForText = 'Choose a branching strategy for this repository'
                    Input = $enter
                },
                [pscustomobject]@{
                    WaitForText = "Configure a DEV environment for branch 'main'"
                    Input = "y`r"
                    CaptureAfter = $true
                },
                [pscustomobject]@{
                    WaitForText = "Select the DEV environment for branch 'main'"
                    Input = $enter
                    CaptureAfter = $true
                },
                [pscustomobject]@{
                    WaitForText = "Select a deployment environment for branch 'main'"
                    Input = $enter
                    CaptureAfter = $true
                },
                [pscustomobject]@{
                    WaitForText = "Configure a DEV environment for branch 'develop'"
                    Input = "y`r"
                    CaptureAfter = $true
                },
                [pscustomobject]@{
                    WaitForText = "Select the DEV environment for branch 'develop'"
                    Input = $enter
                    CaptureAfter = $true
                },
                [pscustomobject]@{
                    WaitForText = "Select a deployment environment for branch 'develop'"
                    Input = $arrowDown
                    CaptureAfter = $true
                },
                [pscustomobject]@{
                    WaitForText = "Select a deployment environment for branch 'develop'"
                    Input = $enter
                }
            )
            CaptureInitialFrame = $false
            CaptureFinalFrame = $true
        },
        [pscustomobject]@{
            SceneName = 'azdo-deployment-short-name'
            ExpectedText = 'Enter a short name for this environment >'
            CaptionLines = @(
                'Give each deployment environment a concise short name.'
                'test, uat, prod etc.'
            )
            Interactions = @(
                [pscustomobject]@{
                    WaitForText = 'Enter a short name for this environment >'
                    Input = 'TEST'
                }
            )
            CaptureInitialFrame = $true
            CaptureFinalFrame = $true
        },
        [pscustomobject]@{
            SceneName = 'branch-mapping'
            ExpectedText = 'develop'
            CaptionLines = @(
                'Map each branch to the environments it can deploy to.'
            )
            Interactions = @(
                [pscustomobject]@{
                    WaitForText = 'Configure deployment branch mappings'
                    Input = $arrowDown
                },
                [pscustomobject]@{
                    WaitForText = 'Configure deployment branch mappings'
                    Input = $enter
                }
            )
            CaptureInitialFrame = $true
            CaptureFinalFrame = $true
        },
        [pscustomobject]@{
            SceneName = 'azdo-authentication-type'
            ExpectedText = 'AuthType'
            CaptionLines = @(
                'Choose authentication type for each environment.'
                'Workload identity federation avoids secrets.'
            )
            Interactions = @(
                [pscustomobject]@{
                    WaitForText = 'Select Service Principal credentials'
                    Input = $enter
                    CaptureAfter = $true
                },
                [pscustomobject]@{
                    WaitForText = 'Select authentication type for the new service connection'
                    Input = $enter
                }
            )
            CaptureInitialFrame = $true
            CaptureFinalFrame = $true
            HasPromptHelp = $false
        },
        [pscustomobject]@{
            SceneName = 'azdo-setup-change-review'
            ExpectedText = 'Up/Down=scroll'
            CaptionLines = @(
                'Preview the generated file changes'
            )
            Interactions = @(
                [pscustomobject]@{
                    WaitForText = 'Modified: alm-config.psd1'
                    Input = $arrowDown
                    CaptureAfter = $true
                },
                [pscustomobject]@{
                    WaitForText = 'Modified: pipelines/BUILD.yml'
                    Input = $enter
                }
            )
            CaptureInitialFrame = $true
            CaptureFinalFrame = $true
            HasPromptHelp = $false
        },
        [pscustomobject]@{
            SceneName = 'azdo-apply-changes'
            ExpectedText = 'Azure DevOps ALM4Dataverse setup menu'
            CaptionLines = @(
                'Apply the changes when ready.'
            )
            Interactions = @(
                [pscustomobject]@{
                    WaitForText = 'Apply changes - Ready'
                    Input = $enter
                }
            )
            CaptureInitialFrame = $true
            CaptureFinalFrame = $false
            HasPromptHelp = $false
        },
        [pscustomobject]@{
            SceneName = 'github-menu-existing-repository'
            ExpectedText = 'Deployment: PROD (main)'
            CaptionLines = @(
                'Available for both Azure DevOps and GitHub Actions!'
            )
            Interactions = @()
            CaptureInitialFrame = $false
            CaptureFinalFrame = $true
        }
    )
}

function Test-CaptureWalkthroughEnabled {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][string]$SceneName,
        [Parameter()][switch]$SkipAnimation
    )

    return [string]::IsNullOrWhiteSpace($SceneName) -and -not $SkipAnimation
}

function Get-RepositoryRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StartPath)

    $directory = Get-Item -LiteralPath $StartPath -ErrorAction Stop
    if (-not $directory.PSIsContainer) {
        $directory = $directory.Directory
    }

    while ($null -ne $directory) {
        $setupCommonPath = Join-Path $directory.FullName 'setup/setup-common.ps1'
        $setupDocsPath = Join-Path $directory.FullName 'docs/setup'
        if ((Test-Path -LiteralPath $setupCommonPath -PathType Leaf) -and
            (Test-Path -LiteralPath $setupDocsPath -PathType Container)) {
            return $directory.FullName
        }
        $directory = $directory.Parent
    }

    throw "Could not locate the repository root above '$StartPath'."
}

function ConvertTo-PowerShellLiteral {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Value)

    return "'" + $Value.Replace("'", "''") + "'"
}

function Get-CaptureHarness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][string]$SceneName
    )

    $harnessTemplate = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$repoRoot = {{REPO_ROOT}}
$provider = {{PROVIDER}}
$scene = {{SCENE}}
. (Join-Path $repoRoot 'setup/setup-common.ps1')
$script:ALM4DataverseRef = 'stable'
$script:ALM4DataverseVersion = 'v0.0.0'
$script:SetupDefaultHelpDocRelativePath = switch ($provider) {
    'github' { 'docs/setup/github-setup.md' }
    'azdo' { 'docs/setup/azdo-automated-setup.md' }
    default { 'docs/config/alm-config.md' }
}

if ($provider -ne 'common') {
    . (Join-Path $repoRoot "setup/setup-$provider.ps1")
}

function Get-VSTeamServiceEndpoint {
    [CmdletBinding()]
    param([Parameter()][string]$ProjectName)
    return @()
}

function Get-AuthToken {
    [CmdletBinding()]
    param(
        [Parameter()][string]$ResourceUrl,
        [Parameter()][string]$TenantId,
        [Parameter()][string]$PreferredUsername,
        [Parameter()][switch]$ForceInteractive,
        [Parameter()][switch]$ListAccountsOnly
    )

    if ($ListAccountsOnly) {
        return @('automation@example.invalid')
    }

    return [pscustomobject]@{
        AccessToken = 'example-access-token'
        Username = 'automation@example.invalid'
    }
}

function Invoke-RestMethod {
    [CmdletBinding()]
    param(
        [Parameter()][string]$Uri,
        [Parameter()][System.Collections.IDictionary]$Headers,
        [Parameter()][string]$Method,
        [Parameter()][string]$Body
    )

    if ($Uri.Contains('/_apis/profile/profiles/me')) {
        return [pscustomobject]@{ publicAlias = 'example-member' }
    }
    if ($Uri.Contains('/_apis/accounts?')) {
        return [pscustomobject]@{
            value = @(
                [pscustomobject]@{
                    accountName = 'Example organization'
                    accountId = 'example-organization-id'
                    accountUri = 'https://dev.azure.com/example-organization'
                }
            )
        }
    }

    return [pscustomobject]@{ value = @() }
}

function Set-VSTeamAccount {
    [CmdletBinding()]
    param(
        [Parameter()][string]$Account,
        [Parameter()][System.Security.SecureString]$SecurePersonalAccessToken,
        [Parameter()][switch]$UseBearerToken,
        [Parameter()][switch]$Force
    )
}

function Set-VSTeamDefaultProject {
    [CmdletBinding()]
    param([Parameter()][string]$Project)
}

function Get-VSTeamProject {
    [CmdletBinding()]
    param()
    return @([pscustomobject]@{ Name = 'Example project'; Id = 'example-project' })
}

function Get-VSTeamGitRepository {
    [CmdletBinding()]
    param([Parameter()][string]$ProjectName)

    if ($ProjectName -ne 'Example project') {
        return @()
    }

    if ($script:scene -in @('azdo-project-selection', 'azdo-main-repository-selection')) {
        return @(
            [pscustomobject]@{
                Id = 'example-contoso-crm-repository'
                Name = 'contoso-crm'
                defaultBranch = 'refs/heads/main'
            }
        )
    }

    if ($script:scene -eq 'azdo-shared-repository-selection') {
        return @(
            [pscustomobject]@{
                Id = 'example-alm-template-repository'
                Name = 'ALM4Dataverse-templates'
                defaultBranch = 'refs/heads/main'
            }
        )
    }

    return @()
}

function Add-VSTeamGitRepository {
    [CmdletBinding()]
    param(
        [Parameter()][string]$ProjectName,
        [Parameter()][string]$Name
    )
    return [pscustomobject]@{
        Id = 'example-created-repository'
        Name = $Name
        defaultBranch = 'refs/heads/main'
    }
}

function New-EntraIdApplication {
    [CmdletBinding()]
    param(
        [Parameter()][string]$DisplayName,
        [Parameter()][string]$TenantId,
        [Parameter()][string]$AuthType
    )
    return [pscustomobject]@{
        Name = $DisplayName
        ApplicationId = 'example-app'
        ApplicationObjectId = 'example-object'
        TenantId = $TenantId
        AuthType = $AuthType
        ClientSecret = $null
        IsExistingServiceConnection = $false
    }
}

$script:dataverseEnvironmentCatalog = @(
    [pscustomobject]@{
        FriendlyName = 'Contoso Development'
        UniqueName = 'contosodevelopment'
        Endpoints = @{ WebApplication = 'https://contoso-development.crm.dynamics.com' }
    },
    [pscustomobject]@{
        FriendlyName = 'Contoso Test'
        UniqueName = 'contosotest'
        Endpoints = @{ WebApplication = 'https://contoso-test.crm.dynamics.com' }
    },
    [pscustomobject]@{
        FriendlyName = 'Contoso UAT'
        UniqueName = 'contosouat'
        Endpoints = @{ WebApplication = 'https://contoso-uat.crm.dynamics.com' }
    },
    [pscustomobject]@{
        FriendlyName = 'Contoso Production'
        UniqueName = 'contosoproduction'
        Endpoints = @{ WebApplication = 'https://contoso-production.crm.dynamics.com' }
    }
)

$credential = [pscustomobject]@{
    Name = 'Example deployment credential'
    ApplicationId = 'example-app'
    ApplicationObjectId = $null
    TenantId = 'example.invalid'
    AuthType = 'WIF'
    ClientSecret = $null
    IsExistingServiceConnection = $false
}
$serviceAccount = 'automation@example.invalid'
$developmentEnvironment = [pscustomobject]@{
    ShortName = 'Dev-main'
    FriendlyName = 'Contoso Development'
    Url = 'https://contoso-development.crm.dynamics.com'
    Credentials = $credential
    ServiceAccountUPN = $serviceAccount
}
$testEnvironment = [pscustomobject]@{
    ShortName = 'TEST'
    FriendlyName = 'Contoso Test'
    Url = 'https://contoso-test.crm.dynamics.com'
    Credentials = $credential
    ServiceAccountUPN = $serviceAccount
}
$uatEnvironment = [pscustomobject]@{
    ShortName = 'UAT'
    FriendlyName = 'Contoso UAT'
    Url = 'https://contoso-uat.crm.dynamics.com'
    Credentials = $credential
    ServiceAccountUPN = $serviceAccount
}
$productionEnvironment = [pscustomobject]@{
    ShortName = 'PROD'
    FriendlyName = 'Contoso Production'
    Url = 'https://contoso-production.crm.dynamics.com'
    Credentials = $credential
    ServiceAccountUPN = $serviceAccount
}
$developBranchDevEnvironment = [pscustomobject]@{
    ShortName = 'Dev-develop'
    FriendlyName = $developmentEnvironment.FriendlyName
    Url = $developmentEnvironment.Url
    Credentials = $credential
    ServiceAccountUPN = $serviceAccount
}
$script:newRepositoryBranchMenuStates = @(
    [pscustomobject]@{
        BranchName = 'main'
        DeploymentEnvironments = @()
    }
)
$script:existingRepositoryBranchMenuStates = @(
    [pscustomobject]@{
        BranchName = 'main'
        DeploymentEnvironments = @($productionEnvironment)
    }
    [pscustomobject]@{
        BranchName = 'develop'
        DevEnvironmentConfiguration = $developBranchDevEnvironment
        DeploymentEnvironments = @($testEnvironment)
    }
)
$emptyMainBranch = [pscustomobject]@{
    BranchName = 'main'
    DevEnvironmentConfiguration = $null
    ExistingDevEnvironment = $null
    Environments = @()
}
$devEnvironmentEditor = {
    param($allMappings, $mapping)

    $branchName = [string]$mapping.BranchName
    Write-Section -Message "DEV environment for branch '$branchName'"
    if ($provider -eq 'github') {
        Write-Host "Preparing GitHub environment 'Dev-$branchName' for the DEV Dataverse environment." -ForegroundColor Green
        Write-Host ''
        $configurePrompt = "Configure a DEV Dataverse environment for branch '$branchName'?"
        $selectPrompt = "Select the DEV Dataverse environment for branch '$branchName'"
        $configureArguments = @{ Prompt = $configurePrompt; DefaultNo = $true }
    }
    else {
        $configurePrompt = "Configure a DEV environment for branch '$branchName'?"
        $selectPrompt = "Select the DEV environment for branch '$branchName'"
        $configureArguments = @{ Prompt = $configurePrompt }
    }

    if (-not (Read-YesNo @configureArguments)) {
        return $null
    }

    $selectedEnvironment = Select-DataverseEnvironment -Prompt $selectPrompt
    return [pscustomobject]@{
        ShortName = "Dev-$branchName"
        FriendlyName = $selectedEnvironment.FriendlyName
        Url = $selectedEnvironment.Endpoints['WebApplication']
        Credentials = $credential
        ServiceAccountUPN = $serviceAccount
    }
}.GetNewClosure()

$deploymentEnvironmentEditor = {
    param($allMappings, $mapping)

    $branchName = [string]$mapping.BranchName
    $selectedEnvironment = Select-DataverseEnvironment `
        -Prompt "Select a deployment environment for branch '$branchName'" `
        -ExcludeUrl ([string]$mapping.DevEnvironmentConfiguration.Url)
    if ($null -eq $selectedEnvironment) {
        throw "No deployment environment selected for branch '$branchName'."
    }

    $shortName = switch ([string]$selectedEnvironment.UniqueName) {
        'contosotest' { 'TEST' }
        'contosouat' { 'UAT' }
        'contosoproduction' { 'PROD' }
        default { throw "No deployment short name is configured for '$($selectedEnvironment.FriendlyName)'." }
    }
    return [pscustomobject]@{
        ShortName = $shortName
        FriendlyName = $selectedEnvironment.FriendlyName
        Url = $selectedEnvironment.Endpoints['WebApplication']
        Credentials = $credential
        ServiceAccountUPN = $serviceAccount
    }
}.GetNewClosure()

switch ($scene) {
    'setup-mode-choice' {
        Select-FromMenu `
            -Title 'New or existing repository' `
            -ShowProductBrand `
            -Items @('Set up a new application repository', 'Configure an existing repository') `
            -PromptGuidanceLines @(
                'Choose whether this run should create a new application repository or configure one that already exists.'
                ) `
            -PromptGuidanceDocRelativePath 'docs/setup/github-setup.md' `
            -PromptGuidanceRef $script:ALM4DataverseRef
    }
    'azdo-authentication' {
        $authentication = Initialize-AzDoAuthentication -TenantId 'example.invalid'
        $script:adoAccessToken = $authentication.AccessToken
        $script:secureToken = $authentication.SecureToken
        $organization = Initialize-AzDoOrganization
        $script:orgName = $organization.Name
    }
    'azdo-project-selection' {
        $script:adoAccessToken = [pscustomobject]@{ Token = 'example-access-token' }
        $script:orgName = 'Example organization'
        Initialize-AzDoProjectAndRepository -SkipSharedRepositoryVersionUpdate | Out-Null
    }
    'azdo-main-repository-selection' {
        Select-AzDoMainRepository `
            -ProjectName 'Example project' `
            -SharedRepositoryName 'ALM4Dataverse' | Out-Null
    }
    'azdo-shared-repository-selection' {
        Select-AzDoSharedRepository `
            -ProjectName 'Example project' `
            -ExcludeRepositoryName 'contoso-dataverse' | Out-Null
    }
    'azdo-extension-mode' {
        [void](Read-YesNo `
            -Prompt 'Use ALM4Dataverse AzDO extension? (required for Workload Identity Federation)' `
            -PromptGuidanceLines @(
                'The extension enables Workload Identity Federation and the ALM4Dataverse Set Connection Variables task.'
                'Disable it only to use the Power Platform Build Tools secret-based fallback path.'
            ) `
            -PromptGuidanceDocRelativePath 'docs/config/azdo-environment-service-connection.md' `
            -PromptGuidanceRef $script:ALM4DataverseRef)
    }
    'azdo-shared-repository-version' {
        [void](Read-YesNo `
            -Prompt "Check and update shared repository 'ALM4Dataverse' now, before preview?" `
            -PromptGuidanceLines @(
                'This step can create, seed, fast-forward, rebase, or reset the shared repository history immediately.'
                'Choose No to defer the update until you are ready; the preview lists the shared repository state as updated during setup.'
            ) `
            -PromptGuidanceDocRelativePath 'docs/setup/azdo-automated-setup.md' `
            -PromptGuidanceRef $script:ALM4DataverseRef)
    }
    'github-authentication' {
        Select-FromMenu `
            -Title 'GitHub authentication' `
            -Items @(
                'Use existing GitHub login: example-user'
                'Sign in with a different GitHub account'
            ) `
            -PromptGuidanceLines @(
                'Choose whether to continue with the currently authenticated GitHub account or switch to another one.'
                'Use the account that should own or manage workflow and repository settings for this setup.'
            ) `
            -PromptGuidanceDocRelativePath 'docs/setup/github-setup.md' `
            -PromptGuidanceRef $script:ALM4DataverseRef | Out-Null
    }
    'github-application-repository' {
        Select-FromMenu `
            -Title 'Select the repository to set up ALM4Dataverse in' `
            -Items @(
                'Create a new repository'
                'Use existing repository: example-org/sample-app'
                'Use existing repository: example-org/contoso-crm'
            ) `
            -PromptGuidanceLines @(
                'Choose the application repository that will store your solutions, ALM configuration, and caller workflows.'
                'You do not need a separate repository for the shared workflow templates unless you maintain a fork.'
            ) `
            -PromptGuidanceDocRelativePath 'docs/setup/github-setup.md' `
            -PromptGuidanceRef $script:ALM4DataverseRef | Out-Null
    }
    'github-shared-workflow-repository' {
        Select-FromMenu `
            -Title 'Select shared workflow repository' `
            -Items @(
                'Create a new repository'
                'Use existing fork: example-org/ALM4Dataverse'
                'Use existing repository: example-org/alm-templates'
            ) `
            -PromptGuidanceLines @(
                'Choose or create a repository that will host the reusable ALM4Dataverse workflow templates.'
            ) `
            -PromptGuidanceDocRelativePath 'docs/setup/github-setup.md' `
            -PromptGuidanceRef $script:ALM4DataverseRef | Out-Null
    }
    'azdo-apply-changes' {
        $completedSteps = @(
            [pscustomobject]@{
                Name = 'Configure branches, dev and deployment envs'
                SubItems = @(Get-SetupBranchMenuItem -BranchStates @($script:existingRepositoryBranchMenuStates))
                IsComplete = $true
                Action = {}
            }
        )
        Invoke-SetupWizard `
            -Title 'Azure DevOps ALM4Dataverse setup' `
            -Steps $completedSteps `
            -PreviewAction {} `
            -ApplyAction {} | Out-Null
    }
    'github-apply-changes' {
        $completedSteps = @(
            [pscustomobject]@{
                Name = 'Configure branches, dev and deployment envs'
                SubItems = @(Get-SetupBranchMenuItem -BranchStates @($script:existingRepositoryBranchMenuStates))
                IsComplete = $true
                Action = {}
            }
            [pscustomobject]@{
                Name = 'Configure solutions'
                Summary = 'develop: Core, Sales'
                IsComplete = $true
                Action = {}
            }
            [pscustomobject]@{
                Name = 'Configure GitHub OIDC identity'
                Summary = 'Immutable subjects'
                IsComplete = $true
                Action = {}
            }
        )
        Invoke-SetupWizard `
            -Title 'GitHub Actions ALM4Dataverse setup' `
            -Steps $completedSteps `
            -PreviewAction {} `
            -ApplyAction {} | Out-Null
    }
    'solutions-configuration' {
        $availableSolutions = @(
            [pscustomobject]@{ friendlyname = 'Contoso Core'; uniquename = 'contoso_core' }
            [pscustomobject]@{ friendlyname = 'Contoso Sales'; uniquename = 'contoso_sales' }
            [pscustomobject]@{ friendlyname = 'Contoso Service'; uniquename = 'contoso_service' }
        )
        Select-OrderedSolution `
            -AvailableSolutions $availableSolutions `
            -InitiallySelectedSolutions @($availableSolutions[0], $availableSolutions[1]) | Out-Null
    }
    'github-oidc-identity' {
        [void](Read-YesNo `
            -Prompt "Enable immutable GitHub OIDC subjects for 'example-org/sample-app'?" `
            -PromptGuidanceLines @(
                'Workload Identity Federation was selected for at least one ALM4Dataverse credential.'
                'Recommended: immutable owner/repository IDs reduce the risk of trust being reused after a name is recycled.'
                'Risk: other workflows or applications in this repository that trust legacy subjects may stop authenticating until their cloud credentials are updated.'
                'Changelog: https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens/#opt-in-for-existing-repositories'
            ) `
            -PromptGuidanceDocRelativePath 'docs/config/github-secrets.md' `
            -PromptGuidanceRef $script:ALM4DataverseRef `
            -DefaultNo)
    }
    { $_ -in @('github-menu-new-repository', 'github-menu-existing-repository', 'github-menu-unavailable-shared-repository', 'azdo-menu-new-repository', 'azdo-menu-existing-repository', 'azdo-menu-unavailable-shared-repository') } {
        $isGitHubSetup = $scene.StartsWith('github-', [StringComparison]::Ordinal)
        $isSharedRepositoryUnavailable = $scene -like '*unavailable-shared-repository'
        $isExistingRepository = $scene -like '*existing-repository' -or $isSharedRepositoryUnavailable
        $branchStepName = 'Configure branches, dev and deployment envs'
        $branchStates = if ($isExistingRepository) {
            $script:existingRepositoryBranchMenuStates
        }
        else {
            $script:newRepositoryBranchMenuStates
        }
        $setupTitle = if ($isGitHubSetup) {
            'GitHub Actions ALM4Dataverse setup'
        }
        else {
            'Azure DevOps ALM4Dataverse setup'
        }
        $stepNames = if ($isGitHubSetup) {
            @(
                $branchStepName,
                'Configure solutions',
                'Configure GitHub OIDC identity'
            )
        }
        else {
            @(
                $branchStepName,
                'Configure solutions'
            )
        }
        $branchSummaries = if ($isExistingRepository) {
            @{
                'Configure solutions' = 'develop: Core, Sales'
                'Configure GitHub OIDC identity' = 'Immutable subjects'
            }
        }
        else {
            @{}
        }
        $sharedRepositoryStep = [pscustomobject]@{
            Name = if ($isGitHubSetup) { 'Select shared workflow repository' } else { 'Select shared repository' }
            Summary = if ($isSharedRepositoryUnavailable) {
                if ($isGitHubSetup) {
                    "Unavailable: Could not access configured repository 'example-org/old-templates'."
                }
                else {
                    "Unavailable: Repository 'old-templates' was not found in project 'Example project'."
                }
            }
            elseif ($isGitHubSetup) {
                'example-org/alm-templates (stable)'
            }
            else {
                'alm-templates (stable)'
            }
            Action = {}
            IsComplete = -not $isSharedRepositoryUnavailable
        }
        $sharedRepositoryVersionStep = [pscustomobject]@{
            Name = if ($isGitHubSetup) { 'Check and update shared workflow repository version' } else { 'Check and update shared repository version' }
            Summary = 'Upstream ref: stable'
            Action = {}
            IsComplete = $false
        }
        $branchSteps = @(
            foreach ($stepName in $stepNames) {
                $stepSummary = if ($branchSummaries.ContainsKey($stepName)) {
                    $branchSummaries[$stepName]
                }
                else {
                    'Not configured'
                }
                $step = [pscustomobject]@{
                    Name = $stepName
                    Summary = $stepSummary
                    Action = {}
                }
                if ($stepName -eq $branchStepName) {
                    Add-Member `
                        -InputObject $step `
                        -NotePropertyName 'SubItems' `
                        -NotePropertyValue @(Get-SetupBranchMenuItem -BranchStates @($branchStates))
                }
                $step
            }
        )
        $setupSteps = @($sharedRepositoryStep, $sharedRepositoryVersionStep) + $branchSteps
        Invoke-SetupWizard `
            -Title $setupTitle `
            -Steps $setupSteps `
            -PreviewAction {} `
            -ApplyAction {} `
            -IsNewRepository:($scene -like '*new-repository')
    }
    { $_ -in @('github-setup-change-review', 'azdo-setup-change-review') } {
        # Build the review menu from the same file-change shape the real review uses so
        # selecting a file still opens its diff for the walkthrough capture.
        $isGitHubReview = $scene -eq 'github-setup-change-review'
        $workflowRoot = if ($isGitHubReview) { '.github/workflows' } else { 'pipelines' }
        $fileChanges = @(
            [pscustomobject]@{
                Path = 'alm-config.psd1'
                Status = 'Modified'
                BeforeContent = "provider = 'azDO'`nsolutions = @()"
                AfterContent = "provider = 'azDO'`nsolutions = @('contoso_core', 'contoso_sales')"
            }
            [pscustomobject]@{
                Path = "$workflowRoot/BUILD.yml"
                Status = 'Modified'
                BeforeContent = "resources:`n  repositories:`n  - repository: ALM4Dataverse`n    ref: 'refs/heads/stable'`nstages:`n- template: pipelines/templates/build.yml@ALM4Dataverse`n  parameters:`n    buildEnvironmentName: ''"
                AfterContent = "resources:`n  repositories:`n  - repository: ALM4Dataverse`n    ref: 'refs/heads/stable'`nstages:`n- template: pipelines/templates/build.yml@ALM4Dataverse`n  parameters:`n    buildEnvironmentName: ''`n    buildValidationEnvironments: {'main': 'Build-main'}"
            }
            [pscustomobject]@{
                Path = "$workflowRoot/DEPLOY-develop.yml"
                Status = 'Deleted'
                BeforeContent = "stages:`n- template: pipelines/templates/deploy.yml@ALM4Dataverse"
                AfterContent = ''
            }
            [pscustomobject]@{
                Path = "$workflowRoot/DEPLOY-main.yml"
                Status = 'Added'
                BeforeContent = ''
                AfterContent = "stages:`n- template: pipelines/templates/deploy.yml@ALM4Dataverse"
            }
        )
        $reviewMenuItems = @($fileChanges | ForEach-Object { "$($_.Status): $($_.Path)" })
        $reviewMenuItems += 'Done reviewing'
        $selection = Select-FromMenu `
            -Title 'Review setup changes' `
            -Items $reviewMenuItems `
            -ActionItems @('Done reviewing') `
            -ActionSectionTitle '---' `
            -PromptGuidanceLines @(
                'Each file is listed with its add, modify, or delete status.'
                'Select a file to view its diff, then choose Done reviewing to return.'
            ) `
            -PromptGuidanceDocRelativePath $(if ($isGitHubReview) { 'docs/setup/github-setup.md' } else { 'docs/setup/azdo-automated-setup.md' }) `
            -PromptGuidanceRef $script:ALM4DataverseRef
        if ($null -ne $selection -and $selection -ge 0 -and $selection -lt $fileChanges.Count) {
            Show-SetupSideBySideDiff -Title 'Repository file changes' -FileChanges @($fileChanges[$selection])
        }
    }
    'setup-change-side-by-side-diff' {
        Show-SetupSideBySideDiff -Title 'Repository file changes' -FileChanges @(
            [pscustomobject]@{
                Path = 'pipelines/BUILD.yml'
                Status = 'Modified'
                BeforeContent = "resources:`n  repositories:`n  - repository: ALM4Dataverse`n    ref: 'refs/heads/stable'`nstages:`n- template: pipelines/templates/build.yml@ALM4Dataverse`n  parameters:`n    buildEnvironmentName: ''"
                AfterContent = "resources:`n  repositories:`n  - repository: ALM4Dataverse`n    ref: 'refs/heads/stable'`nstages:`n- template: pipelines/templates/build.yml@ALM4Dataverse`n  parameters:`n    buildEnvironmentName: ''`n    buildValidationEnvironments: {'main': 'Build-main'}"
            }
        )
    }
    'branch-strategy' {
        Select-BranchEnvironmentMapping -InitialBranchMappings @($emptyMainBranch) -IsNewRepository -Ref $script:ALM4DataverseRef
    }
    'branch-name' {
        $mainBranch = [pscustomobject]@{
            BranchName = 'main'
            DevEnvironmentConfiguration = $developmentEnvironment
            ExistingDevEnvironment = $developmentEnvironment
            Environments = @($testEnvironment)
        }
        Select-BranchEnvironmentMapping `
            -EnvironmentConfigurations @($developmentEnvironment, $testEnvironment, $uatEnvironment, $productionEnvironment) `
            -InitialBranchMappings @($mainBranch) `
            -Ref $script:ALM4DataverseRef
    }
    'branch-mapping' {
        $mainBranch = [pscustomobject]@{
            BranchName = 'main'
            DevEnvironmentConfiguration = $developmentEnvironment
            ExistingDevEnvironment = $developmentEnvironment
            Environments = @($testEnvironment)
        }
        $developBranch = [pscustomobject]@{
            BranchName = 'develop'
            DevEnvironmentConfiguration = ([pscustomobject]@{
                ShortName = 'Dev-develop'
                FriendlyName = 'Contoso Development'
                Url = 'https://contoso-development.crm.dynamics.com'
                Credentials = $credential
                ServiceAccountUPN = $serviceAccount
            })
            ExistingDevEnvironment = $null
            Environments = @($uatEnvironment)
        }
        Select-BranchEnvironmentMapping `
            -EnvironmentConfigurations @($developmentEnvironment, $testEnvironment, $uatEnvironment, $productionEnvironment) `
            -InitialBranchMappings @($mainBranch, $developBranch) `
            -Ref $script:ALM4DataverseRef
    }
    { $_ -in @('github-dev-confirmation', 'github-dev-environment-selection', 'azdo-dev-confirmation') } {
        Select-BranchEnvironmentMapping `
            -InitialBranchMappings @($emptyMainBranch) `
            -IsNewRepository `
            -EditDevEnvironmentScriptBlock $devEnvironmentEditor `
            -Ref $script:ALM4DataverseRef
    }
    'azdo-dev-environment-selection' {
        Select-BranchEnvironmentMapping `
            -InitialBranchMappings @($emptyMainBranch) `
            -IsNewRepository `
            -EditDevEnvironmentScriptBlock $devEnvironmentEditor `
            -EditDeploymentEnvironmentsScriptBlock $deploymentEnvironmentEditor `
            -Ref $script:ALM4DataverseRef
    }
    { $_ -in @('github-build-validation', 'azdo-build-validation') } {
        $buildValidationEditor = {
            param($allMappings, $mapping)

            $branchName = [string]$mapping.BranchName
            Write-Section -Message "BUILD validation for branch '$branchName'"
            $enableBuildValidation = Read-YesNo `
                -Prompt "Enable Dataverse deployment validation during BUILD for branch '$branchName'?" `
                -DefaultNo
            if (-not $enableBuildValidation) {
                return [pscustomobject]@{
                    BuildValidationEnabled = $false
                    BuildValidationEnvironmentName = ''
                    BuildValidationBaselineRelease = ''
                    BuildValidationEnvironmentConfiguration = $null
                    ExistingBuildValidationEnvironment = $null
                }
            }

            $selectedEnvironment = Select-DataverseEnvironment `
                -Prompt "Select the Dataverse environment for BUILD validation on branch '$branchName'"
            return [pscustomobject]@{
                BuildValidationEnabled = $true
                BuildValidationEnvironmentName = "Build-$branchName"
                BuildValidationBaselineRelease = ''
                BuildValidationEnvironmentConfiguration = [pscustomobject]@{
                    ShortName = "Build-$branchName"
                    FriendlyName = $selectedEnvironment.FriendlyName
                    Url = $selectedEnvironment.Endpoints['WebApplication']
                    Credentials = $credential
                    ServiceAccountUPN = $serviceAccount
                }
                ExistingBuildValidationEnvironment = $null
            }
        }.GetNewClosure()

        Select-BranchEnvironmentMapping `
            -InitialBranchMappings @($emptyMainBranch) `
            -IsNewRepository `
            -EditBuildValidationScriptBlock $buildValidationEditor `
            -Ref $script:ALM4DataverseRef
    }
    'github-credentials' {
        Get-GitHubCredentialsForEnvironment `
            -ExistingCredentials @($credential) `
            -TenantId 'example.invalid' `
            -RepoName 'example-repository' `
            -EnvironmentName 'Dev-main'
    }
    'github-authentication-type' {
        Get-GitHubCredentialsForEnvironment `
            -TenantId 'example.invalid' `
            -RepoName 'example-repository' `
            -EnvironmentName 'Dev-main'
    }
    'github-service-account' {
        Get-DataverseServiceAccountUPN `
            -ExistingServiceAccounts @($serviceAccount) `
            -EnvironmentName 'Dev-main'
    }
    'github-deployment-environment-selection' {
        Select-DataverseEnvironment -Prompt "Select a Dataverse environment for branch 'main'" -ExcludeUrl $developmentEnvironment.Url
    }
    'deployment-short-name' {
        Read-TextWithDefault -Prompt 'Enter a short name for this environment' -DefaultValue ''
    }
    'environment-detail-menu' {
        $deploymentConfigurationUnderEdit = [pscustomobject]@{
            ShortName = 'TEST'
            FriendlyName = 'Contoso Test'
            Url = 'https://contoso-test.crm.dynamics.com'
            Credentials = $credential
            ServiceAccountUPN = ''
        }
        Invoke-SetupEnvironmentConfigurationWizard `
            -Title "Configure deployment environment for branch 'main'" `
            -SelectDataverseEnvironmentAction {
                [pscustomobject]@{ FriendlyName = 'Contoso Test'; Url = 'https://contoso-test.crm.dynamics.com' }
            } `
            -InitialConfiguration $deploymentConfigurationUnderEdit `
            -TargetNameStepName 'Short name' `
            -SelectTargetNameAction { 'TEST' } `
            -SelectCredentialsAction { $credential } `
            -SelectServiceAccountAction { $serviceAccount } `
            -HelpDocRelativePath 'docs/setup/github-setup.md' `
            -HelpRef $script:ALM4DataverseRef
    }
    'deployment-environment-plan' {
        Select-ConfiguredDeploymentEnvironment `
            -InitialEnvironments @($testEnvironment, $productionEnvironment) `
            -Heading "Target deployment environments for branch 'main'" `
            -Title "Manage deployment environments for branch 'main'" `
            -AddEnvironmentScriptBlock { param($currentSelections) return $null } `
            -EditEnvironmentScriptBlock { param($currentSelections, $environment, $index) return $null } `
            -Ref $script:ALM4DataverseRef
    }
    'azdo-credentials' {
        Get-PowerPlatformSCCredential `
            -ExistingCredentials @($credential) `
            -TenantId 'example.invalid' `
            -ProjectName 'Example project' `
            -EnvironmentName 'Dev-main'
    }
    'azdo-authentication-type' {
        Get-PowerPlatformSCCredential `
            -TenantId 'example.invalid' `
            -ProjectName 'Example project' `
            -EnvironmentName 'Dev-main'
    }
    'azdo-service-account' {
        Get-DataverseServiceAccountUPN `
            -ExistingServiceAccounts @($serviceAccount) `
            -EnvironmentName 'Dev-main'
    }
    'azdo-deployment-environment-selection' {
        Get-DataverseEnvironmentsSelection `
            -ExcludedUrl $developmentEnvironment.Url `
            -ProjectName 'Example project' `
            -InitialEnvironments @() `
            -TenantId 'example.invalid' `
            -UseAlm4DataverseExtension $false
    }
    'azdo-deployment-short-name' {
        Read-TextWithDefault `
            -Prompt 'Enter a short name for this environment' `
            -DefaultValue '' `
            -PromptGuidanceLines @(
                'Use a concise name such as TEST, UAT, or PROD.',
                'This label appears in setup summaries and must be unique within the branch.'
            ) `
            -PromptGuidanceDocRelativePath 'docs/config/alm-config.md' `
            -PromptGuidanceRef $script:ALM4DataverseRef
    }
    'azdo-deployment-environment-plan' {
        Select-ConfiguredDeploymentEnvironment `
            -InitialEnvironments @($testEnvironment, $productionEnvironment) `
            -Heading "Target Deployment Environments for branch 'main'" `
            -Title 'Manage deployment environments' `
            -AddEnvironmentScriptBlock { param($currentSelections) return $null } `
            -EditEnvironmentScriptBlock { param($currentSelections, $environment, $index) return $null } `
            -Ref $script:ALM4DataverseRef
    }
    default {
        throw "No setup scene is defined for '$scene'."
    }
}
'@

    return $harnessTemplate.
        Replace('{{REPO_ROOT}}', (ConvertTo-PowerShellLiteral -Value $RepositoryRoot)).
        Replace('{{PROVIDER}}', (ConvertTo-PowerShellLiteral -Value $Provider)).
        Replace('{{SCENE}}', (ConvertTo-PowerShellLiteral -Value $SceneName))
}

function Get-CaptureCacheRoot {
    [CmdletBinding()]
    param([Parameter()][string]$Platform)

    if ((Get-CapturePlatformName -Platform $Platform) -eq 'Windows') {
        $localApplicationData = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData)
        return Join-Path $localApplicationData 'ALM4Dataverse/SetupScreenshotCapture'
    }

    return Join-Path $HOME '.cache/alm4dataverse/setup-screenshot-capture'
}

function Get-CaptureGlobalNuGetPackagesRoot {
    [CmdletBinding()]
    param()

    if (-not [string]::IsNullOrWhiteSpace($env:NUGET_PACKAGES)) {
        return $env:NUGET_PACKAGES
    }

    return Join-Path $HOME '.nuget/packages'
}

function Get-CapturePowerShellExecutable {
    [CmdletBinding()]
    param()

    $powerShellCommand = Get-Command -Name 'pwsh' -CommandType Application -ErrorAction Stop |
        Select-Object -First 1
    return $powerShellCommand.Source
}

function Get-CaptureFfmpegExecutable {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $ffmpegCommand = Get-Command -Name 'ffmpeg' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $ffmpegCommand) {
        throw 'Full screenshot capture requires ffmpeg with drawtext and fontconfig support. Install ffmpeg or rerun with -SkipAnimation.'
    }

    return $ffmpegCommand.Source
}

function Assert-CaptureRuntimePrerequisite {
    [CmdletBinding()]
    param(
        [Parameter()][version]$PowerShellVersion = $PSVersionTable.PSVersion,
        [Parameter()][string]$FrameworkDescription = [System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
    )

    if ($PowerShellVersion -lt [version]'7.6') {
        throw 'Screenshot capture requires PowerShell 7.6 or newer, which runs on .NET 10 or newer.'
    }
    if ($FrameworkDescription -notmatch '^\.NET (10|11)\.') {
        throw "Screenshot capture requires .NET 10 or newer; the current runtime is '$FrameworkDescription'."
    }
}

function Get-NuGetPackageDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$PackageCacheRoot,
        [Parameter()][string]$GlobalPackageRoot = (Get-CaptureGlobalNuGetPackagesRoot)
    )

    $lowerId = $Id.ToLowerInvariant()
    $packageRelativePath = Join-Path $lowerId $Version
    foreach ($root in @($GlobalPackageRoot, $PackageCacheRoot)) {
        if ([string]::IsNullOrWhiteSpace($root)) {
            continue
        }

        $candidate = Join-Path $root $packageRelativePath
        if ((Test-Path -LiteralPath $candidate -PathType Container) -and
            @(Get-ChildItem -LiteralPath $candidate -Filter '*.nuspec' -File -ErrorAction SilentlyContinue).Count -gt 0) {
            return $candidate
        }
    }

    $packageDirectory = Join-Path $PackageCacheRoot $packageRelativePath
    $downloadDirectory = Join-Path $PackageCacheRoot 'downloads'
    [System.IO.Directory]::CreateDirectory($downloadDirectory) | Out-Null
    [System.IO.Directory]::CreateDirectory($packageDirectory) | Out-Null
    $archivePath = Join-Path $downloadDirectory "$lowerId.$Version.nupkg"
    $packageUri = "https://api.nuget.org/v3-flatcontainer/$lowerId/$Version/$lowerId.$Version.nupkg"

    try {
        Invoke-WebRequest -Uri $packageUri -OutFile $archivePath -ErrorAction Stop
    }
    catch {
        throw "Could not download NuGet package '$Id' version '$Version': $($_.Exception.Message)"
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    try {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($archivePath, $packageDirectory, $true)
    }
    catch {
        throw "Could not extract NuGet package '$Id' version '$Version': $($_.Exception.Message)"
    }

    if (@(Get-ChildItem -LiteralPath $packageDirectory -Filter '*.nuspec' -File -ErrorAction SilentlyContinue).Count -eq 0) {
        throw "NuGet package '$Id' version '$Version' did not contain a package specification."
    }

    return $packageDirectory
}

function Get-CaptureManagedAssetDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PackageDirectory)

    $libraryRoot = Join-Path $PackageDirectory 'lib'
    foreach ($framework in @('net10.0', 'net9.0', 'net8.0', 'net7.0', 'net6.0', 'netstandard2.1', 'netstandard2.0')) {
        $candidate = Join-Path $libraryRoot $framework
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            return $candidate
        }
    }

    throw "NuGet package '$PackageDirectory' has no compatible managed library assets."
}

function Get-CaptureNativeAssetDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackageDirectory,
        [Parameter(Mandatory)][string]$Platform,
        [Parameter()][string]$Architecture
    )

    $platformName = Get-CapturePlatformName -Platform $Platform
    $architectureName = Get-CaptureArchitecture -Architecture $Architecture
    $runtimeNames = switch ($platformName) {
        'Windows' { @("win-$architectureName") }
        'macOS' { @("osx-$architectureName", 'osx') }
        'Linux' {
            @(
                [System.Runtime.InteropServices.RuntimeInformation]::RuntimeIdentifier.ToLowerInvariant(),
                "linux-$architectureName",
                "linux-musl-$architectureName"
            )
        }
        default { throw "No native runtime identifiers are configured for '$platformName'." }
    }

    foreach ($runtimeName in $runtimeNames | Select-Object -Unique) {
        $candidate = Join-Path (Join-Path $PackageDirectory 'runtimes') (Join-Path $runtimeName 'native')
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            return $candidate
        }
    }

    throw "NuGet package '$PackageDirectory' has no native assets for $platformName/$architectureName."
}

function Install-CaptureRuntimeAsset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CacheRoot,
        [Parameter(Mandatory)][string]$RuntimeDirectory,
        [Parameter(Mandatory)][string]$Platform,
        [Parameter()][string]$Architecture,
        [Parameter()][string]$GlobalPackageRoot = (Get-CaptureGlobalNuGetPackagesRoot)
    )

    $platformName = Get-CapturePlatformName -Platform $Platform
    $architectureName = Get-CaptureArchitecture -Architecture $Architecture
    $packageCacheRoot = Join-Path $CacheRoot 'packages'
    [System.IO.Directory]::CreateDirectory($RuntimeDirectory) | Out-Null
    $managedAssemblyPaths = [System.Collections.Generic.List[string]]::new()

    foreach ($package in Get-CapturePackageSpecification -Platform $platformName) {
        $packageDirectory = Get-NuGetPackageDirectory `
            -Id $package.Id `
            -Version $package.Version `
            -PackageCacheRoot $packageCacheRoot `
            -GlobalPackageRoot $GlobalPackageRoot

        if ($package.Kind -eq 'Managed') {
            $assetDirectory = Get-CaptureManagedAssetDirectory -PackageDirectory $packageDirectory
            $managedAssets = @(Get-ChildItem -LiteralPath $assetDirectory -Filter '*.dll' -File)
            if ($managedAssets.Count -eq 0) {
                throw "NuGet package '$($package.Id)' has no managed DLLs in '$assetDirectory'."
            }

            foreach ($asset in $managedAssets) {
                $destination = Join-Path $RuntimeDirectory $asset.Name
                Copy-Item -LiteralPath $asset.FullName -Destination $destination -Force
                if (-not $managedAssemblyPaths.Contains($destination)) {
                    $managedAssemblyPaths.Add($destination)
                }
            }
        }
        else {
            $assetDirectory = Get-CaptureNativeAssetDirectory `
                -PackageDirectory $packageDirectory `
                -Platform $platformName `
                -Architecture $architectureName
            $nativeAssets = @(Get-ChildItem -LiteralPath $assetDirectory -File)
            if ($nativeAssets.Count -eq 0) {
                throw "NuGet package '$($package.Id)' has no native files in '$assetDirectory'."
            }

            foreach ($asset in $nativeAssets) {
                Copy-Item -LiteralPath $asset.FullName -Destination (Join-Path $RuntimeDirectory $asset.Name) -Force
            }
        }
    }

    $conPtyLibraryPath = $null
    if ($platformName -eq 'Windows') {
        $ptyPackageDirectory = Get-NuGetPackageDirectory `
            -Id 'Terminal.Pty' `
            -Version '0.4.5' `
            -PackageCacheRoot $packageCacheRoot `
            -GlobalPackageRoot $GlobalPackageRoot
        $conPtySourceDirectory = Join-Path $ptyPackageDirectory (Join-Path 'buildTransitive/conpty' $architectureName)
        foreach ($fileName in @('conpty.dll', 'OpenConsole.exe')) {
            $sourcePath = Join-Path $conPtySourceDirectory $fileName
            if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                throw "NuGet package 'Terminal.Pty' is missing '$sourcePath'."
            }
        }

        $conPtyTargetDirectory = Join-Path $RuntimeDirectory (Join-Path 'conpty' $architectureName)
        [System.IO.Directory]::CreateDirectory($conPtyTargetDirectory) | Out-Null
        Get-ChildItem -LiteralPath $conPtySourceDirectory -File | Copy-Item -Destination $conPtyTargetDirectory -Force
        $conPtyLibraryPath = Join-Path $conPtyTargetDirectory 'conpty.dll'
    }

    return [pscustomobject]@{
        RuntimeDirectory = $RuntimeDirectory
        ManagedAssemblyPaths = $managedAssemblyPaths.ToArray()
        ConPtyLibraryPath = $conPtyLibraryPath
    }
}

function Get-CaptureType {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TypeName)

    foreach ($assembly in [System.AppDomain]::CurrentDomain.GetAssemblies()) {
        $type = $assembly.GetType($TypeName, $false)
        if ($null -ne $type) {
            return $type
        }
    }

    throw "Capture dependency type '$TypeName' was not loaded."
}

function Initialize-CaptureAvaloniaRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$ManagedAssemblyPaths,
        [Parameter(Mandatory)][string]$FontFamilyName
    )

    foreach ($assemblyPath in $ManagedAssemblyPaths) {
        [System.Reflection.Assembly]::LoadFrom($assemblyPath) | Out-Null
    }

    $appBuilderType = Get-CaptureType -TypeName 'Avalonia.AppBuilder'
    $applicationType = Get-CaptureType -TypeName 'Avalonia.Application'
    $configureMethod = $appBuilderType.GetMethods([System.Reflection.BindingFlags]'Public,Static') |
        Where-Object { $_.Name -eq 'Configure' -and $_.IsGenericMethodDefinition -and $_.GetParameters().Count -eq 0 } |
        Select-Object -First 1
    if ($null -eq $configureMethod) {
        throw 'Avalonia AppBuilder did not expose a parameterless generic Configure method.'
    }

    $builder = $configureMethod.MakeGenericMethod($applicationType).Invoke($null, @())
    $skiaExtensions = Get-CaptureType -TypeName 'Avalonia.SkiaApplicationExtensions'
    $skiaMethod = $skiaExtensions.GetMethod('UseSkia', [System.Reflection.BindingFlags]'Public,Static')
    $skiaMethod.Invoke($null, @($builder)) | Out-Null

    $headlessOptionsType = Get-CaptureType -TypeName 'Avalonia.Headless.AvaloniaHeadlessPlatformOptions'
    $headlessOptions = [System.Activator]::CreateInstance($headlessOptionsType)
    $headlessOptions.ShouldRenderOnUIThread = $true
    $headlessOptions.UseHeadlessDrawing = $false
    $headlessExtensions = Get-CaptureType -TypeName 'Avalonia.Headless.AvaloniaHeadlessPlatformExtensions'
    $headlessMethod = $headlessExtensions.GetMethod('UseHeadless', [System.Reflection.BindingFlags]'Public,Static')
    $headlessMethod.Invoke($null, @($builder, $headlessOptions)) | Out-Null
    $builder.SetupWithoutStarting() | Out-Null

    $fontFamilyType = Get-CaptureType -TypeName 'Avalonia.Media.FontFamily'
    $fontFamily = [System.Activator]::CreateInstance($fontFamilyType, [object[]]@($FontFamilyName))
    $typefaceType = Get-CaptureType -TypeName 'Avalonia.Media.Typeface'
    $fontStyleType = Get-CaptureType -TypeName 'Avalonia.Media.FontStyle'
    $fontWeightType = Get-CaptureType -TypeName 'Avalonia.Media.FontWeight'
    $fontStretchType = Get-CaptureType -TypeName 'Avalonia.Media.FontStretch'
    $typefaceConstructor = $typefaceType.GetConstructor([System.Type[]]@(
        $fontFamilyType, $fontStyleType, $fontWeightType, $fontStretchType
    ))
    if ($null -eq $typefaceConstructor) {
        throw 'Avalonia did not expose the expected Typeface constructor.'
    }

    $typeface = $typefaceConstructor.Invoke([object[]]@(
        $fontFamily,
        $fontStyleType.GetField('Normal').GetValue($null),
        $fontWeightType.GetField('Normal').GetValue($null),
        $fontStretchType.GetField('Normal').GetValue($null)
    ))
    $fontManagerType = Get-CaptureType -TypeName 'Avalonia.Media.FontManager'
    $fontManager = $fontManagerType.GetProperty('Current').GetValue($null)
    $glyphTypeface = $null
    if (-not $fontManager.TryGetGlyphTypeface($typeface, [ref]$glyphTypeface) -or
        $glyphTypeface.FamilyName -ine $FontFamilyName) {
        throw "The required monospaced font '$FontFamilyName' is not available to Avalonia."
    }
}

function Invoke-CaptureDispatcherQueue {
    [CmdletBinding()]
    param()

    $dispatcherType = Get-CaptureType -TypeName 'Avalonia.Threading.Dispatcher'
    $dispatcher = $dispatcherType.GetProperty('UIThread').GetValue($null)
    $dispatcher.RunJobs()
}

function Invoke-CaptureRenderTick {
    [CmdletBinding()]
    param()

    $headlessPlatformType = Get-CaptureType -TypeName 'Avalonia.Headless.AvaloniaHeadlessPlatform'
    $headlessPlatformType.GetMethod('ForceRenderTimerTick', [System.Reflection.BindingFlags]'Public,Static').Invoke($null, @([int]3)) | Out-Null
}

function Get-CaptureTerminalEnvironment {
    [CmdletBinding()]
    param()

    $comparer = if ($IsWindows) { [System.StringComparer]::OrdinalIgnoreCase } else { [System.StringComparer]::Ordinal }
    $environment = [System.Collections.Generic.Dictionary[string, string]]::new($comparer)
    $allowedNames = @(
        'PATH', 'PSModulePath', 'HOME', 'USERPROFILE', 'SystemRoot', 'WINDIR',
        'TEMP', 'TMP', 'TMPDIR', 'APPDATA', 'LOCALAPPDATA', 'LANG', 'LC_ALL',
        'DOTNET_ROOT', 'DOTNET_ROOT_X64', 'DOTNET_MULTILEVEL_LOOKUP',
        'DOTNET_ROLL_FORWARD', 'LD_LIBRARY_PATH'
    )
    foreach ($name in $allowedNames) {
        $value = [System.Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $environment[$name] = $value
        }
    }
    $environment['TERM'] = 'xterm-256color'
    $environment['COLORTERM'] = 'truecolor'

    return $environment
}

function Open-CaptureTerminalWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Rows,
        [Parameter(Mandatory)][string]$FontFamilyName
    )

    $terminalType = Get-CaptureType -TypeName 'Terminal.Avalonia.TerminalControl'
    $terminal = [System.Activator]::CreateInstance($terminalType)
    $fontFamilyType = Get-CaptureType -TypeName 'Avalonia.Media.FontFamily'
    $terminal.FontFamily = [System.Activator]::CreateInstance($fontFamilyType, [object[]]@($FontFamilyName))
    $terminal.FontSize = $script:CaptureTerminalFontSize
    $terminal.ShowScrollbar = $false

    $windowType = Get-CaptureType -TypeName 'Avalonia.Controls.Window'
    $window = [System.Activator]::CreateInstance($windowType)
    $window.Width = $script:CaptureTerminalWidth
    $window.Height = $Rows * 20
    $window.CanResize = $false
    $window.WindowDecorations = [System.Enum]::Parse($windowType.GetProperty('WindowDecorations').PropertyType, 'None')
    $window.ShowInTaskbar = $false
    $brushesType = Get-CaptureType -TypeName 'Avalonia.Media.Brushes'
    $window.Background = $brushesType.GetProperty('Black').GetValue($null)
    $window.Content = $terminal
    $window.Show() | Out-Null
    Invoke-CaptureDispatcherQueue

    return [pscustomobject]@{
        Terminal = $terminal
        Window = $window
    }
}

function Connect-CaptureTerminal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Terminal,
        [Parameter(Mandatory)][pscustomobject]$Scene,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter()][string]$ConPtyLibraryPath
    )

    $ptyOptionsType = Get-CaptureType -TypeName 'Terminal.Pty.PtyOptions'
    $ptyOptions = [System.Activator]::CreateInstance($ptyOptionsType)
    $ptyOptions.Command = Get-CapturePowerShellExecutable
    $arguments = [System.Collections.Generic.List[string]]::new()
    [void]$arguments.Add('-NoLogo')
    [void]$arguments.Add('-NoProfile')
    [void]$arguments.Add('-Command')
    [void]$arguments.Add((Get-CaptureHarness -RepositoryRoot $RepositoryRoot -Provider $Scene.Provider -SceneName $Scene.Name))
    $ptyOptions.Arguments = $arguments
    $ptyOptions.WorkingDirectory = $RepositoryRoot
    $ptyOptions.Environment = Get-CaptureTerminalEnvironment
    $ptyOptions.Columns = $script:CaptureTerminalColumns
    $ptyOptions.Rows = $Scene.Rows
    if (-not [string]::IsNullOrWhiteSpace($ConPtyLibraryPath)) {
        $ptyOptions.ConPtyLibraryPath = $ConPtyLibraryPath
    }

    $startMethod = $Terminal.GetType().GetMethod('Start')
    $startMethod.Invoke($Terminal, [object[]]@($ptyOptions, $null)) | Out-Null
}

function Wait-ForTerminalText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Terminal,
        [Parameter(Mandatory)][string]$ExpectedText,
        [Parameter()][int]$TimeoutSeconds = 20
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $screenText = ''
    while ([DateTime]::UtcNow -lt $deadline) {
        Invoke-CaptureDispatcherQueue
        $screenText = [string]::Join([Environment]::NewLine, $Terminal.ReadScreenText())
        if ($screenText.Contains($ExpectedText, [StringComparison]::Ordinal)) {
            return $screenText
        }

        Start-Sleep -Milliseconds 25
    }

    $connectionState = "IsRunning=$($Terminal.IsRunning); HasExited=$($Terminal.HasExited); DisconnectReason='$($Terminal.DisconnectReason)'; ScreenVersion=$($Terminal.ScreenVersion)"
    throw "Timed out waiting for '$ExpectedText'. $connectionState Current terminal screen:$([Environment]::NewLine)$screenText"
}

function Save-CaptureFrame {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Window,
        [Parameter(Mandatory)][string]$OutputPath
    )

    $headlessWindowExtensions = Get-CaptureType -TypeName 'Avalonia.Headless.HeadlessWindowExtensions'
    $frameMethod = $headlessWindowExtensions.GetMethod('GetLastRenderedFrame', [System.Reflection.BindingFlags]'Public,Static')
    $frame = $frameMethod.Invoke($null, @($Window))
    if ($null -eq $frame) {
        throw 'Avalonia did not render a terminal frame.'
    }

    $pngOptionsType = Get-CaptureType -TypeName 'Avalonia.Media.Imaging.PngBitmapEncoderOptions'
    $pngOptions = $pngOptionsType.GetProperty('Default').GetValue($null)
    $frame.Save($OutputPath, $pngOptions)
}

function Invoke-CaptureProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$Operation
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $ExecutablePath
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    foreach ($argument in $Arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "Could not start the capture process for '$Operation'."
        }

        $standardOutputTask = $process.StandardOutput.ReadToEndAsync()
        $standardErrorTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $standardOutput = $standardOutputTask.GetAwaiter().GetResult()
        $standardError = $standardErrorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            $details = $standardError.Trim()
            if (-not [string]::IsNullOrWhiteSpace($standardOutput)) {
                if (-not [string]::IsNullOrWhiteSpace($details)) {
                    $details += [Environment]::NewLine
                }
                $details += $standardOutput.Trim()
            }

            throw "Capture process failed during '$Operation' with exit code $($process.ExitCode). $details"
        }
    }
    finally {
        $process.Dispose()
    }
}

function Get-CaptureInputAction {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$InputText)

    $actions = [System.Collections.Generic.List[object]]::new()

    for ($index = 0; $index -lt $InputText.Length; $index++) {
        $characterCode = [int]$InputText[$index]
        $inputAction = [string]$InputText[$index]
        $isTypingCharacter = $true

        if ($characterCode -eq 27) {
            $isTypingCharacter = $false
            if ($InputText.Length -ge ($index + 3)) {
                $arrowSequence = $InputText.Substring($index, 3)
                if ($arrowSequence -in @(
                        "$([char]27)[A",
                        "$([char]27)[B",
                        "$([char]27)[C",
                        "$([char]27)[D"
                    )) {
                    $inputAction = $arrowSequence
                    $index += 2
                }
            }
        }
        elseif ($characterCode -in @(3, 8, 9, 10, 13, 127)) {
            $isTypingCharacter = $false
            if (
                $characterCode -eq 13 -and
                ($index + 1) -lt $InputText.Length -and
                [int]$InputText[$index + 1] -eq 10
            ) {
                $inputAction += [string]$InputText[$index + 1]
                $index++
            }
        }

        $actions.Add([pscustomobject]@{
            InputText = $inputAction
            IsTypingCharacter = $isTypingCharacter
        })
    }

    return $actions.ToArray()
}

function Invoke-CaptureWalkthroughFrame {
    [CmdletBinding(DefaultParameterSetName = 'Scene')]
    param(
        [Parameter(Mandatory)][string]$FfmpegExecutable,
        [Parameter(Mandatory)][string]$FontFamilyName,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory, ParameterSetName = 'Intro')][string]$LogoPath,
        [Parameter(Mandatory, ParameterSetName = 'Intro')][string]$Title,
        [Parameter(Mandatory, ParameterSetName = 'Intro')][string]$Subtitle,
        [Parameter(Mandatory, ParameterSetName = 'Scene')][string]$SourceImagePath,
        [Parameter(Mandatory, ParameterSetName = 'Scene')][ValidateNotNullOrEmpty()][string[]]$CaptionLines
    )

    if ($PSCmdlet.ParameterSetName -eq 'Intro') {
        $titlePath = Join-Path $WorkingDirectory 'walkthrough-title.txt'
        $subtitlePath = Join-Path $WorkingDirectory 'walkthrough-subtitle.txt'
        $utf8WithoutBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($titlePath, $Title, $utf8WithoutBom)
        [System.IO.File]::WriteAllText($subtitlePath, $Subtitle, $utf8WithoutBom)

        $backgroundInput = 'color=c=0xffffff:s={0}x{1}:r=1' -f `
            $script:CaptureWalkthroughWidth, $script:CaptureWalkthroughHeight
        $filter = "[1:v]scale=760:-1[logo];[0:v][logo]overlay=(W-w)/2:240,drawbox=x=390:y=470:w=420:h=4:color=0x2ea96b:t=fill,drawtext=font='$FontFamilyName':textfile='walkthrough-title.txt':fontcolor=0x101820:fontsize=38:x=(w-text_w)/2:y=520,drawtext=font='$FontFamilyName':textfile='walkthrough-subtitle.txt':fontcolor=0x4b5563:fontsize=18:x=(w-text_w)/2:y=580[intro]"
        $arguments = @(
            '-hide_banner', '-loglevel', 'error', '-y',
            '-f', 'lavfi', '-i', $backgroundInput,
            '-i', $LogoPath,
            '-filter_complex', $filter,
            '-map', '[intro]',
            '-frames:v', '1',
            '-update', '1',
            $OutputPath
        )
        $operation = 'setup walkthrough intro frame'
    }
    else {
        $captionPath = Join-Path $WorkingDirectory 'walkthrough-caption.txt'
        [System.IO.File]::WriteAllLines(
            $captionPath,
            $CaptionLines,
            [System.Text.UTF8Encoding]::new($false)
        )

        $paddingX = [int](($script:CaptureWalkthroughWidth - $script:CaptureWalkthroughContentWidth) / 2)
        $footerDividerY = $script:CaptureWalkthroughHeight - $script:CaptureWalkthroughFooterHeight
        $captionY = $script:CaptureWalkthroughContentHeight + 4
        $filter = 'scale={0}:{1}:force_original_aspect_ratio=decrease,pad={0}:{1}:(ow-iw)/2:(oh-ih)/2:color=0xffffff,pad={2}:{3}:{4}:0:color=0xffffff,drawbox=x=0:y={6}:w={2}:h={5}:color=0xffffff@0.85:t=fill,drawbox=x=0:y={6}:w={2}:h=5:color=0x2ea96b:t=fill,drawtext=font=''{7}'':textfile=''walkthrough-caption.txt'':fontcolor=0x101820:fontsize=26:x=(w-text_w)/2:y={8}:line_spacing=4' -f `
            $script:CaptureWalkthroughContentWidth,
            $script:CaptureWalkthroughContentHeight,
            $script:CaptureWalkthroughWidth,
            $script:CaptureWalkthroughHeight,
            $paddingX,
            $script:CaptureWalkthroughFooterHeight,
            $footerDividerY,
            $FontFamilyName,
            $captionY
        $arguments = @(
            '-hide_banner', '-loglevel', 'error', '-y',
            '-i', $SourceImagePath,
            '-vf', $filter,
            '-frames:v', '1',
            '-update', '1',
            $OutputPath
        )
        $operation = 'setup walkthrough scene frame'
    }

    Invoke-CaptureProcess `
        -ExecutablePath $FfmpegExecutable `
        -Arguments $arguments `
        -WorkingDirectory $WorkingDirectory `
        -Operation $operation
    if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
        throw "FFmpeg did not create the setup walkthrough frame '$OutputPath'."
    }
}

function Invoke-CaptureWalkthrough {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$ScreenshotDirectory,
        [Parameter(Mandatory)][string]$FfmpegExecutable,
        [Parameter(Mandatory)][string]$FontFamilyName,
        [Parameter()][string]$ConPtyLibraryPath
    )

    $steps = @(Get-CaptureWalkthroughStep)
    $availableSceneNames = @(Get-CaptureScene | ForEach-Object Name)
    foreach ($step in $steps) {
        if ($step.SceneName -notin $availableSceneNames) {
            throw "Setup walkthrough references unknown screenshot scene '$($step.SceneName)'."
        }
    }

    $logoPath = Join-Path $RepositoryRoot 'logo.png'
    if (-not (Test-Path -LiteralPath $logoPath -PathType Leaf)) {
        throw "Setup walkthrough logo '$logoPath' was not found."
    }

    $temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) (
        'alm4dataverse-setup-walkthrough-' + [guid]::NewGuid().ToString('N')
    )
    [System.IO.Directory]::CreateDirectory($temporaryDirectory) | Out-Null
    try {
        $frameNumber = 0
        $frameManifestLines = [System.Collections.Generic.List[string]]::new()
        $frameManifestLines.Add('ffconcat version 1.0')
        $introFramePath = Join-Path $temporaryDirectory ('frame-{0:D3}.png' -f $frameNumber)
        Invoke-CaptureWalkthroughFrame `
            -FfmpegExecutable $FfmpegExecutable `
            -FontFamilyName $FontFamilyName `
            -WorkingDirectory $temporaryDirectory `
            -OutputPath $introFramePath `
            -LogoPath $logoPath `
            -Title 'ALM4Dataverse  - automated setup' `
            -Subtitle 'the easiest way to get powerful ALM for Dataverse/D365/Power Platform set up in minutes'
        $frameManifestLines.Add("file '$([System.IO.Path]::GetFileName($introFramePath))'")
        $frameManifestLines.Add(
            [string]::Format(
                [System.Globalization.CultureInfo]::InvariantCulture,
                'duration {0:0.#########}',
                $script:CaptureWalkthroughDwellSeconds
            )
        )

        $stepNumber = 0
        foreach ($step in $steps) {
            $stepNumber++
            $screenshotPath = Join-Path $ScreenshotDirectory "$($step.SceneName).png"
            if (-not (Test-Path -LiteralPath $screenshotPath -PathType Leaf)) {
                throw "Setup walkthrough screenshot '$screenshotPath' was not found. Run a full screenshot capture first."
            }

            $sceneDefinition = @(Resolve-CaptureScene -SceneName $step.SceneName)[0]
            $expectedText = if ($step.PSObject.Properties['ExpectedText']) {
                [string]$step.ExpectedText
            }
            else {
                [string]$sceneDefinition.ExpectedText
            }
            $interactions = if ($step.PSObject.Properties['Interactions']) {
                @($step.Interactions)
            }
            else {
                @($sceneDefinition.Interactions)
            }
            $captureInitialFrame = if ($step.PSObject.Properties['CaptureInitialFrame']) {
                [bool]$step.CaptureInitialFrame
            }
            else {
                $true
            }
            $captureFinalFrame = if ($step.PSObject.Properties['CaptureFinalFrame']) {
                [bool]$step.CaptureFinalFrame
            }
            else {
                $true
            }
            $hasPromptHelp = $true
            if ($sceneDefinition.PSObject.Properties['HasPromptHelp']) {
                $hasPromptHelp = [bool]$sceneDefinition.HasPromptHelp
            }
            if ($step.PSObject.Properties['HasPromptHelp']) {
                $hasPromptHelp = [bool]$step.HasPromptHelp
            }

            $walkthroughScene = [pscustomobject]@{
                Name = $sceneDefinition.Name
                Provider = $sceneDefinition.Provider
                ExpectedText = $expectedText
                Rows = $sceneDefinition.Rows
                Interactions = $interactions
                CaptureInitialFrame = $captureInitialFrame
                CaptureFinalFrame = $captureFinalFrame
                HasPromptHelp = $hasPromptHelp
            }
            $frameOutputDirectory = Join-Path $temporaryDirectory ('scene-{0:D3}' -f $stepNumber)
            $sceneOutputPath = Join-Path $temporaryDirectory ('scene-output-{0:D3}.png' -f $stepNumber)
            Invoke-CaptureScene `
                -Scene $walkthroughScene `
                -RepositoryRoot $RepositoryRoot `
                -OutputPath $sceneOutputPath `
                -FontFamilyName $FontFamilyName `
                -ConPtyLibraryPath $ConPtyLibraryPath `
                -FrameOutputDirectory $frameOutputDirectory

            $capturedFrames = @(
                Get-ChildItem -LiteralPath $frameOutputDirectory -Filter 'checkpoint-*.png' -File |
                    Sort-Object Name
            )
            if ($capturedFrames.Count -eq 0) {
                throw "No terminal checkpoints were captured for walkthrough scene '$($step.SceneName)'."
            }

            foreach ($capturedFrame in $capturedFrames) {
                $typingMarkerPath = [System.IO.Path]::ChangeExtension($capturedFrame.FullName, '.typing.txt')
                $isTypingFrame = Test-Path -LiteralPath $typingMarkerPath -PathType Leaf
                $frameDurationSeconds = if ($isTypingFrame) {
                    $script:CaptureWalkthroughTypingFrameDurationSeconds
                }
                else {
                    $script:CaptureWalkthroughDwellSeconds
                }

                $frameNumber++
                $framePath = Join-Path $temporaryDirectory ('frame-{0:D3}.png' -f $frameNumber)
                Invoke-CaptureWalkthroughFrame `
                    -FfmpegExecutable $FfmpegExecutable `
                    -FontFamilyName $FontFamilyName `
                    -WorkingDirectory $temporaryDirectory `
                    -OutputPath $framePath `
                    -SourceImagePath $capturedFrame.FullName `
                    -CaptionLines $step.CaptionLines
                $frameManifestLines.Add("file '$([System.IO.Path]::GetFileName($framePath))'")
                $frameManifestLines.Add(
                    [string]::Format(
                        [System.Globalization.CultureInfo]::InvariantCulture,
                        'duration {0:0.#########}',
                        $frameDurationSeconds
                    )
                )
            }
        }

        if ($frameNumber -lt 1) {
            throw 'No frames were captured for the setup walkthrough.'
        }
        $lastFramePath = Join-Path $temporaryDirectory ('frame-{0:D3}.png' -f $frameNumber)
        $frameManifestLines.Add("file '$([System.IO.Path]::GetFileName($lastFramePath))'")
        [System.IO.File]::WriteAllLines(
            (Join-Path $temporaryDirectory 'walkthrough-frames.ffconcat'),
            $frameManifestLines,
            [System.Text.UTF8Encoding]::new($false)
        )

        $temporaryGifPath = Join-Path $temporaryDirectory 'setup-walkthrough.gif'
        $paletteFilter = '[0:v]fps={0},split[palette_source][frame_source];[palette_source]palettegen=stats_mode=diff[palette];[frame_source][palette]paletteuse=dither=bayer:bayer_scale=3[gif]' -f `
            $script:CaptureWalkthroughOutputFrameRate
        $arguments = @(
            '-hide_banner', '-loglevel', 'error', '-y',
            '-f', 'concat',
            '-safe', '0',
            '-i', 'walkthrough-frames.ffconcat',
            '-filter_complex', $paletteFilter,
            '-map', '[gif]',
            '-loop', '0',
            $temporaryGifPath
        )
        Invoke-CaptureProcess `
            -ExecutablePath $FfmpegExecutable `
            -Arguments $arguments `
            -WorkingDirectory $temporaryDirectory `
            -Operation 'setup walkthrough GIF encoding'

        $temporaryGif = Get-Item -LiteralPath $temporaryGifPath -ErrorAction Stop
        if ($temporaryGif.Length -le 0) {
            throw 'FFmpeg created an empty setup walkthrough GIF.'
        }

        $outputPath = Join-Path $RepositoryRoot $script:CaptureWalkthroughRelativePath
        Move-Item -LiteralPath $temporaryGifPath -Destination $outputPath -Force
        Write-Output "Captured $([System.IO.Path]::GetRelativePath($RepositoryRoot, $outputPath))."
    }
    finally {
        if (Test-Path -LiteralPath $temporaryDirectory -PathType Container) {
            try {
                Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction Stop
            }
            catch {
                Write-Warning "Could not remove temporary walkthrough files from '$temporaryDirectory': $($_.Exception.Message)"
            }
        }
    }
}

function Save-CaptureSceneFrame {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Capture,
        [Parameter(Mandatory)][pscustomobject]$Scene,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter()][switch]$TypingFrame
    )

    Wait-ForTerminalText -Terminal $Capture.Terminal -ExpectedText 'ALM4Dataverse Setup -' | Out-Null
    if (-not ($Scene.PSObject.Properties['HasPromptHelp'] -and -not $Scene.HasPromptHelp)) {
        Wait-ForTerminalText -Terminal $Capture.Terminal -ExpectedText 'F1 for help' | Out-Null
    }
    Start-Sleep -Milliseconds 750
    Invoke-CaptureDispatcherQueue
    Invoke-CaptureRenderTick
    Invoke-CaptureDispatcherQueue
    Save-CaptureFrame -Window $Capture.Window -OutputPath $OutputPath
    if ($TypingFrame) {
        [System.IO.File]::WriteAllText(
            [System.IO.Path]::ChangeExtension($OutputPath, '.typing.txt'),
            'typing',
            [System.Text.UTF8Encoding]::new($false)
        )
    }
}

function Invoke-CaptureScene {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Scene,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string]$FontFamilyName,
        [Parameter()][string]$ConPtyLibraryPath,
        [Parameter()][string]$FrameOutputDirectory
    )

    $capture = Open-CaptureTerminalWindow -Rows $Scene.Rows -FontFamilyName $FontFamilyName
    try {
        Connect-CaptureTerminal `
            -Terminal $capture.Terminal `
            -Scene $Scene `
            -RepositoryRoot $RepositoryRoot `
            -ConPtyLibraryPath $ConPtyLibraryPath

        $captureCheckpoints = -not [string]::IsNullOrWhiteSpace($FrameOutputDirectory)
        $captureInitialFrame = $true
        $captureFinalFrame = $true
        if ($Scene.PSObject.Properties['CaptureInitialFrame']) {
            $captureInitialFrame = [bool]$Scene.CaptureInitialFrame
        }
        if ($Scene.PSObject.Properties['CaptureFinalFrame']) {
            $captureFinalFrame = [bool]$Scene.CaptureFinalFrame
        }
        $interactions = @($Scene.Interactions)
        $checkpointNumber = 0
        if ($captureCheckpoints) {
            [System.IO.Directory]::CreateDirectory($FrameOutputDirectory) | Out-Null
            if ($interactions.Count -gt 0) {
                Wait-ForTerminalText -Terminal $capture.Terminal -ExpectedText $interactions[0].WaitForText | Out-Null
                if ($captureInitialFrame) {
                    $checkpointNumber++
                    Save-CaptureSceneFrame `
                        -Capture $capture `
                        -Scene $Scene `
                        -OutputPath (Join-Path $FrameOutputDirectory ('checkpoint-{0:D3}.png' -f $checkpointNumber))
                }
            }
        }

        for ($interactionIndex = 0; $interactionIndex -lt $interactions.Count; $interactionIndex++) {
            $interaction = $interactions[$interactionIndex]
            if (-not $captureCheckpoints -or $interactionIndex -gt 0) {
                Wait-ForTerminalText -Terminal $capture.Terminal -ExpectedText $interaction.WaitForText | Out-Null
            }
            if ($captureCheckpoints) {
                $inputActions = @(Get-CaptureInputAction -InputText ([string]$interaction.Input))
                foreach ($inputAction in $inputActions) {
                    if (-not $capture.Terminal.SendText($inputAction.InputText)) {
                        throw "Could not send input to screenshot scene '$($Scene.Name)'."
                    }
                    if ($inputAction.IsTypingCharacter) {
                        Start-Sleep -Milliseconds 100
                        Invoke-CaptureDispatcherQueue
                        $checkpointNumber++
                        Save-CaptureSceneFrame `
                            -Capture $capture `
                            -Scene $Scene `
                            -OutputPath (Join-Path $FrameOutputDirectory ('checkpoint-{0:D3}.png' -f $checkpointNumber)) `
                            -TypingFrame
                    }
                }
            }
            elseif (-not $capture.Terminal.SendText($interaction.Input)) {
                throw "Could not send input to screenshot scene '$($Scene.Name)'."
            }

            if ($captureCheckpoints) {
                Start-Sleep -Milliseconds 150
                Invoke-CaptureDispatcherQueue
                $nextExpectedText = if ($interactionIndex -lt ($interactions.Count - 1)) {
                    $interactions[$interactionIndex + 1].WaitForText
                }
                else {
                    $Scene.ExpectedText
                }
                Wait-ForTerminalText -Terminal $capture.Terminal -ExpectedText $nextExpectedText | Out-Null
                if (
                    $interactionIndex -lt ($interactions.Count - 1) -and
                    $interaction.PSObject.Properties['CaptureAfter'] -and
                    $interaction.CaptureAfter
                ) {
                    $checkpointNumber++
                    Save-CaptureSceneFrame `
                        -Capture $capture `
                        -Scene $Scene `
                        -OutputPath (Join-Path $FrameOutputDirectory ('checkpoint-{0:D3}.png' -f $checkpointNumber))
                }
            }
        }

        Wait-ForTerminalText -Terminal $capture.Terminal -ExpectedText $Scene.ExpectedText | Out-Null
        if ($captureCheckpoints -and $captureFinalFrame) {
            $checkpointNumber++
            Save-CaptureSceneFrame `
                -Capture $capture `
                -Scene $Scene `
                -OutputPath (Join-Path $FrameOutputDirectory ('checkpoint-{0:D3}.png' -f $checkpointNumber))
        }
        Save-CaptureSceneFrame -Capture $capture -Scene $Scene -OutputPath $OutputPath
    }
    finally {
        $capture.Terminal.Dispose()
        $capture.Window.Close()
        Invoke-CaptureDispatcherQueue
    }
}

function Invoke-CaptureScreenshotSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][pscustomobject[]]$Scenes,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter()][string]$FfmpegExecutable
    )

    Assert-CaptureRuntimePrerequisite
    $platformName = Get-CapturePlatformName
    $architectureName = Get-CaptureArchitecture
    $fontFamilyName = Get-CaptureFontFamily -Platform $platformName
    $cacheRoot = Get-CaptureCacheRoot -Platform $platformName
    $runtimeDirectory = Join-Path $cacheRoot (Join-Path 'runtime' (Join-Path $platformName.ToLowerInvariant() $architectureName))
    $runtime = Install-CaptureRuntimeAsset `
        -CacheRoot $cacheRoot `
        -RuntimeDirectory $runtimeDirectory `
        -Platform $platformName `
        -Architecture $architectureName
    Initialize-CaptureAvaloniaRuntime -ManagedAssemblyPaths $runtime.ManagedAssemblyPaths -FontFamilyName $fontFamilyName
    [System.IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null

    foreach ($scene in $Scenes) {
        $outputPath = Join-Path $OutputDirectory "$($scene.Name).png"
        Invoke-CaptureScene `
            -Scene $scene `
            -RepositoryRoot $RepositoryRoot `
            -OutputPath $outputPath `
            -FontFamilyName $fontFamilyName `
            -ConPtyLibraryPath $runtime.ConPtyLibraryPath
        Write-Output "Captured $([System.IO.Path]::GetRelativePath($RepositoryRoot, $outputPath))."
    }

    if (-not [string]::IsNullOrWhiteSpace($FfmpegExecutable)) {
        Invoke-CaptureWalkthrough `
            -RepositoryRoot $RepositoryRoot `
            -ScreenshotDirectory $OutputDirectory `
            -FfmpegExecutable $FfmpegExecutable `
            -FontFamilyName $fontFamilyName `
            -ConPtyLibraryPath $runtime.ConPtyLibraryPath
    }
}

if ($MyInvocation.InvocationName -eq '.') {
    return
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Get-RepositoryRoot -StartPath $PSScriptRoot
$selectedScenes = @(Resolve-CaptureScene -SceneName $Scene)
if ($ListScenes) {
    $selectedScenes.Name
    return
}

$outputDirectory = Join-Path $repositoryRoot $script:CaptureScreenshotRelativePath
$ffmpegExecutable = $null
if (Test-CaptureWalkthroughEnabled -SceneName $Scene -SkipAnimation:$SkipAnimation) {
    $ffmpegExecutable = Get-CaptureFfmpegExecutable
}

Invoke-CaptureScreenshotSet `
    -RepositoryRoot $repositoryRoot `
    -Scenes $selectedScenes `
    -OutputDirectory $outputDirectory `
    -FfmpegExecutable $ffmpegExecutable
