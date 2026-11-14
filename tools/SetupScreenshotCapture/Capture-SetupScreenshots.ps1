<#
.SYNOPSIS
    Captures the current setup helper screens as colored PNGs.
.PARAMETER Scene
    Captures one named scene instead of the full screenshot set.
.PARAMETER ListScenes
    Lists available scene names without loading capture dependencies.
.DESCRIPTION
    Runs the real setup helper functions in a PTY-backed Terminal.Avalonia control
    and saves the rendered frames under docs/setup/screenshots. The tool downloads
    its pinned NuGet dependencies on first use. It requires PowerShell 7.6 or newer
    on .NET 10 and a platform monospaced font: Consolas on Windows, Noto Sans Mono
    on Linux, or Menlo on macOS.
.NOTES
    Provider API calls are stubbed and all displayed values are reserved examples.
    No GitHub, Azure DevOps, Entra ID, or Dataverse resources are accessed.
#>
[CmdletBinding()]
param(
    [Parameter()][string]$Scene,
    [Parameter()][switch]$ListScenes
)

$script:CaptureTerminalWidth = 1600
$script:CaptureTerminalColumns = 150
$script:CaptureTerminalFontSize = 16
$script:CaptureScreenshotRelativePath = 'docs/setup/screenshots'

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
            ExpectedText = 'v0.0.0'
            Rows = 32
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'github-menu-new-repository'
            Provider = 'common'
            ExpectedText = 'main (no envs)'
            Rows = 32
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'github-menu-existing-repository'
            Provider = 'common'
            ExpectedText = 'main (PROD)'
            Rows = 32
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'github-menu-unavailable-shared-repository'
            Provider = 'common'
            ExpectedText = 'Unavailable:'
            Rows = 32
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'azdo-menu-new-repository'
            Provider = 'common'
            ExpectedText = 'main (no envs)'
            Rows = 32
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'azdo-menu-existing-repository'
            Provider = 'common'
            ExpectedText = 'main (PROD)'
            Rows = 32
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'azdo-menu-unavailable-shared-repository'
            Provider = 'common'
            ExpectedText = 'Unavailable:'
            Rows = 32
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'github-build-validation'
            Provider = 'github'
            ExpectedText = 'Example Test'
            Rows = 32
            Interactions = @(
                [pscustomobject]@{ WaitForText = 'Choose a branching strategy'; Input = "`r" },
                [pscustomobject]@{ WaitForText = "Enable Dataverse deployment validation during BUILD for branch 'main'"; Input = "y`r" }
            )
        },
        [pscustomobject]@{
            Name = 'azdo-build-validation'
            Provider = 'azdo'
            ExpectedText = 'Example Test'
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
            ExpectedText = "Configure a DEV Dataverse environment for branch 'main'?"
            Rows = 32
            Interactions = @([pscustomobject]@{ WaitForText = 'Choose a branching strategy'; Input = "`r" })
        },
        [pscustomobject]@{
            Name = 'github-dev-environment-selection'
            Provider = 'github'
            ExpectedText = 'Example Development'
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
            Name = 'github-deployment-environment-selection'
            Provider = 'github'
            ExpectedText = 'Example Test'
            Rows = 32
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'deployment-short-name'
            Provider = 'github'
            ExpectedText = 'Enter a short name for this environment'
            Rows = 32
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'environment-detail-menu'
            Provider = 'common'
            ExpectedText = 'Example Test'
            Rows = 32
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'deployment-environment-plan'
            Provider = 'common'
            ExpectedText = 'Example Test'
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
            ExpectedText = "Configure a DEV environment for branch 'main'?"
            Rows = 32
            Interactions = @([pscustomobject]@{ WaitForText = 'Choose a branching strategy'; Input = "`r" })
        },
        [pscustomobject]@{
            Name = 'azdo-dev-environment-selection'
            Provider = 'azdo'
            ExpectedText = 'Example Development'
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
            ExpectedText = 'Example Test'
            Rows = 32
            Interactions = @(
                [pscustomobject]@{ WaitForText = 'Add an environment'; Input = "`r" },
                [pscustomobject]@{ WaitForText = 'Dataverse environment'; Input = "`r" }
            )
        },
        [pscustomobject]@{
            Name = 'azdo-deployment-short-name'
            Provider = 'azdo'
            ExpectedText = 'Enter a short name for this environment'
            Rows = 32
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'azdo-deployment-environment-plan'
            Provider = 'azdo'
            ExpectedText = 'Example Test'
            Rows = 32
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'github-setup-change-review'
            Provider = 'common'
            ExpectedText = 'View alm-config.psd1 diff'
            Rows = 50
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'azdo-setup-change-review'
            Provider = 'common'
            ExpectedText = 'View alm-config.psd1 diff'
            Rows = 50
            Interactions = @()
        },
        [pscustomobject]@{
            Name = 'setup-change-side-by-side-diff'
            Provider = 'common'
            HasPromptHelp = $false
            ExpectedText = 'Up/Down scroll'
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
        [Parameter()][string]$TenantId
    )
    return $null
}

function Invoke-RestMethod {
    [CmdletBinding()]
    param(
        [Parameter()][string]$Uri,
        [Parameter()][System.Collections.IDictionary]$Headers,
        [Parameter()][string]$Method,
        [Parameter()][string]$Body
    )
    return [pscustomobject]@{ value = @() }
}

$script:dataverseEnvironmentCatalog = @(
    [pscustomobject]@{
        FriendlyName = 'Example Development'
        UniqueName = 'exampledevelopment'
        Endpoints = @{ WebApplication = 'https://development.example.invalid' }
    },
    [pscustomobject]@{
        FriendlyName = 'Example Test'
        UniqueName = 'exampletest'
        Endpoints = @{ WebApplication = 'https://test.example.invalid' }
    },
    [pscustomobject]@{
        FriendlyName = 'Example Production'
        UniqueName = 'exampleproduction'
        Endpoints = @{ WebApplication = 'https://production.example.invalid' }
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
    FriendlyName = 'Example Development'
    Url = 'https://development.example.invalid'
    Credentials = $credential
    ServiceAccountUPN = $serviceAccount
}
$testEnvironment = [pscustomobject]@{
    ShortName = 'TEST'
    FriendlyName = 'Example Test'
    Url = 'https://test.example.invalid'
    Credentials = $credential
    ServiceAccountUPN = $serviceAccount
}
$uatEnvironment = [pscustomobject]@{
    ShortName = 'UAT'
    FriendlyName = 'Example UAT'
    Url = 'https://uat.example.invalid'
    Credentials = $credential
    ServiceAccountUPN = $serviceAccount
}
$productionEnvironment = [pscustomobject]@{
    ShortName = 'PROD'
    FriendlyName = 'Example Production'
    Url = 'https://production.example.invalid'
    Credentials = $credential
    ServiceAccountUPN = $serviceAccount
}
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

switch ($scene) {
    'setup-mode-choice' {
        Select-FromMenu `
            -Title 'Choose setup type' `
            -ShowProductBrand `
            -Items @('Set up a new application repository', 'Configure an existing repository') `
            -PromptGuidanceLines @(
                'Choose whether this run should create a new application repository or configure one that already exists.',
                'Existing-repository setup authenticates and selects its resources before opening the guided configuration menu.'
            ) `
            -PromptGuidanceDocRelativePath 'docs/setup/github-setup.md' `
            -PromptGuidanceRef $script:ALM4DataverseRef
    }
    { $_ -in @('github-menu-new-repository', 'github-menu-existing-repository', 'github-menu-unavailable-shared-repository', 'azdo-menu-new-repository', 'azdo-menu-existing-repository', 'azdo-menu-unavailable-shared-repository') } {
        $isGitHubSetup = $scene.StartsWith('github-', [StringComparison]::Ordinal)
        $isSharedRepositoryUnavailable = $scene -like '*unavailable-shared-repository'
        $isExistingRepository = $scene -like '*existing-repository' -or $isSharedRepositoryUnavailable
        $setupTitle = if ($isGitHubSetup) {
            'GitHub Actions ALM4Dataverse setup'
        }
        else {
            'Azure DevOps ALM4Dataverse setup'
        }
        $stepNames = if ($isGitHubSetup) {
            @(
                'Configure branches',
                'Select solutions',
                'Configure GitHub OIDC identity'
            )
        }
        else {
            @(
                'Configure branches',
                'Select solutions'
            )
        }
        $branchSummaries = if ($isExistingRepository) {
            @{
                'Configure branches' = 'main (PROD), develop (DEV-develop, TEST)'
                'Select solutions' = 'develop: Core, Sales'
                'Configure GitHub OIDC identity' = 'Immutable subjects'
            }
        }
        else {
            @{
                'Configure branches' = 'main (no envs)'
            }
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
                [pscustomobject]@{
                    Name = $stepName
                    Summary = $stepSummary
                    Action = {}
                }
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
        $isGitHubReview = $scene -eq 'github-setup-change-review'
        $providerLabel = if ($isGitHubReview) { 'GitHub' } else { 'Azure DevOps' }
        $configProvider = if ($isGitHubReview) { 'GitHub' } else { 'azDO' }
        $repositoryLabel = if ($isGitHubReview) { 'example-org/sample-app' } else { 'sample-app' }
        $workflowRoot = if ($isGitHubReview) { '.github/workflows' } else { 'pipelines' }
        $fileChanges = @(
            [pscustomobject]@{
                Path = 'alm-config.psd1'
                Status = 'Modified'
                BeforeContent = "provider = '$configProvider'`nbranches = @{`n    main = @{ deploymentEnvironments = @('TEST') }`n}"
                AfterContent = "provider = '$configProvider'`nbranches = @{`n    main = @{ deploymentEnvironments = @('TEST', 'PROD') }`n}"
            },
            [pscustomobject]@{
                Path = "$workflowRoot/BUILD.yml"
                Status = 'Modified'
                BeforeContent = "stages:`n- template: pipelines/templates/build.yml`n  parameters:`n    buildEnvironmentName: ''"
                AfterContent = "stages:`n- template: pipelines/templates/build.yml`n  parameters:`n    buildEnvironmentName: ''`n    buildValidationEnvironments: {'main': 'Build-main'}"
            },
            [pscustomobject]@{
                Path = "$workflowRoot/DEPLOY-main.yml"
                Status = 'Added'
                BeforeContent = $null
                AfterContent = "name: Deploy main`ntrigger: none`njobs:`n- deployment: deploy`n  environment: PROD"
            },
            [pscustomobject]@{
                Path = "$workflowRoot/DEPLOY-develop.yml"
                Status = 'Deleted'
                BeforeContent = "name: Deploy develop`ntrigger: none`njobs:`n- deployment: deploy`n  environment: TEST"
                AfterContent = $null
            }
        )
        $resourceChanges = if ($isGitHubReview) {
            @(
                [pscustomobject]@{
                    Action = 'Enable'
                    Resource = 'GitHub repository OIDC setting'
                    Target = $repositoryLabel
                    Details = 'Enable immutable subject claims while preserving the existing claim-selection mode.'
                }
                [pscustomobject]@{
                    Action = 'Create or update'
                    Resource = 'GitHub environment'
                    Target = "$repositoryLabel/PROD"
                    Details = 'Set environment variables, store AZURE_CLIENT_SECRET (value hidden), and require reviewer approval.'
                }
                [pscustomobject]@{
                    Action = 'Create or update'
                    Resource = 'Entra federated identity credential'
                    Target = "$repositoryLabel/PROD"
                    Details = 'Configure the GitHub Actions workload identity subject for this environment.'
                }
                [pscustomobject]@{
                    Action = 'Ensure'
                    Resource = 'Dataverse application and service-account users'
                    Target = 'PROD'
                    Details = 'Ensure both configured users have the System Administrator role.'
                }
            )
        }
        else {
            @(
                [pscustomobject]@{
                    Action = 'Ensure'
                    Resource = 'Azure DevOps Build Service permission'
                    Target = 'sample-project/sample-app'
                    Details = "Grant the project's Build Service Contribute permission on the main repository."
                }
                [pscustomobject]@{
                    Action = 'Create or retarget'
                    Resource = 'Azure DevOps YAML pipelines'
                    Target = 'sample-project/sample-app'
                    Details = 'Register BUILD, EXPORT, IMPORT, and DEPLOY-main from the generated YAML files.'
                }
                [pscustomobject]@{
                    Action = 'Create or reconcile'
                    Resource = 'Azure DevOps service connection'
                    Target = 'sample-project/PROD'
                    Details = 'Configure workload identity federation; credential values are not displayed.'
                }
                [pscustomobject]@{
                    Action = 'Create or update'
                    Resource = 'Entra federated identity credential'
                    Target = 'sample-project/PROD'
                    Details = 'Use the issuer and subject returned by the Azure DevOps service connection.'
                }
                [pscustomobject]@{
                    Action = 'Ensure'
                    Resource = 'Azure DevOps variable group and checks'
                    Target = 'sample-project/Environment-PROD'
                    Details = 'Seed variables if new; ensure exclusive lock, deployment approval, and pipeline access.'
                }
                [pscustomobject]@{
                    Action = 'Ensure'
                    Resource = 'Dataverse application and service-account users'
                    Target = 'PROD'
                    Details = 'Ensure both configured users have the System Administrator role.'
                }
            )
        }
        $summaryAction = {
            Show-KeyValueSummaryTable -Heading 'Setup summary' -Values ([ordered]@{
                'Setup type' = 'Changes to existing repository setup'
                'Provider' = $providerLabel
                'Repository' = $repositoryLabel
                'Configured branches' = '1'
                'BUILD validation' = 'main: Build-main'
                'Solutions selected' = '1'
                'Deferred resource changes' = [string]$resourceChanges.Count
            })
            Show-BranchEnvironmentMappingTable -BranchMappings @([pscustomobject]@{
                    BranchName = 'main'
                    Environments = @($testEnvironment, $productionEnvironment)
                })
        }.GetNewClosure()
        Show-SetupChangeReview `
            -FileChanges $fileChanges `
            -ResourceChanges $resourceChanges `
            -ResourceChangeNote 'Resources already provisioned earlier to support setup are excluded.' `
            -SummaryAction $summaryAction
    }
    'setup-change-side-by-side-diff' {
        Show-SetupSideBySideDiff -Title 'Modified: pipelines/BUILD.yml' -FileChanges @(
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
            Environments = @($testEnvironment, $productionEnvironment)
        }
        $developBranch = [pscustomobject]@{
            BranchName = 'develop'
            DevEnvironmentConfiguration = ([pscustomobject]@{
                ShortName = 'Dev-develop'
                FriendlyName = 'Example Development'
                Url = 'https://development.example.invalid'
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
    { $_ -in @('github-dev-confirmation', 'github-dev-environment-selection', 'azdo-dev-confirmation', 'azdo-dev-environment-selection') } {
        Select-BranchEnvironmentMapping `
            -InitialBranchMappings @($emptyMainBranch) `
            -IsNewRepository `
            -EditDevEnvironmentScriptBlock $devEnvironmentEditor `
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
        $incompleteDeploymentConfiguration = [pscustomobject]@{
            FriendlyName = 'Example Test'
            Url = 'https://test.example.invalid'
            Credentials = $null
            ServiceAccountUPN = ''
        }
        Invoke-SetupEnvironmentConfigurationWizard `
            -Title "Configure deployment environment for branch 'main'" `
            -SelectDataverseEnvironmentAction {
                [pscustomobject]@{ FriendlyName = 'Example Test'; Url = 'https://test.example.invalid' }
            } `
            -InitialConfiguration $incompleteDeploymentConfiguration `
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

function Assert-CaptureRuntimePrerequisite {
    [CmdletBinding()]
    param(
        [Parameter()][version]$PowerShellVersion = $PSVersionTable.PSVersion,
        [Parameter()][string]$FrameworkDescription = [System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
    )

    if ($PowerShellVersion -lt [version]'7.6') {
        throw 'Screenshot capture requires PowerShell 7.6 or newer, which runs on .NET 10.'
    }
    if ($FrameworkDescription -notmatch '^\.NET 10\.') {
        throw "Screenshot capture requires .NET 10; the current runtime is '$FrameworkDescription'."
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

function Invoke-CaptureScene {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Scene,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string]$FontFamilyName,
        [Parameter()][string]$ConPtyLibraryPath
    )

    $capture = Open-CaptureTerminalWindow -Rows $Scene.Rows -FontFamilyName $FontFamilyName
    try {
        Connect-CaptureTerminal `
            -Terminal $capture.Terminal `
            -Scene $Scene `
            -RepositoryRoot $RepositoryRoot `
            -ConPtyLibraryPath $ConPtyLibraryPath

        foreach ($interaction in $Scene.Interactions) {
            Wait-ForTerminalText -Terminal $capture.Terminal -ExpectedText $interaction.WaitForText | Out-Null
            if (-not $capture.Terminal.SendText($interaction.Input)) {
                throw "Could not send input to screenshot scene '$($Scene.Name)'."
            }
        }

        Wait-ForTerminalText -Terminal $capture.Terminal -ExpectedText $Scene.ExpectedText | Out-Null
        Wait-ForTerminalText -Terminal $capture.Terminal -ExpectedText 'ALM4Dataverse Setup -' | Out-Null
        if (-not ($Scene.PSObject.Properties['HasPromptHelp'] -and -not $Scene.HasPromptHelp)) {
            Wait-ForTerminalText -Terminal $capture.Terminal -ExpectedText 'F1=help' | Out-Null
        }
        Start-Sleep -Milliseconds 200
        Invoke-CaptureDispatcherQueue
        Invoke-CaptureRenderTick
        Invoke-CaptureDispatcherQueue
        Save-CaptureFrame -Window $capture.Window -OutputPath $OutputPath
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
        [Parameter(Mandatory)][string]$OutputDirectory
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
Invoke-CaptureScreenshotSet `
    -RepositoryRoot $repositoryRoot `
    -Scenes $selectedScenes `
    -OutputDirectory $outputDirectory
