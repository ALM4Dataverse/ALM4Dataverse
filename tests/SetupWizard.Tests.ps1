BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repoRoot 'setup-common.ps1')
    # Standalone runs need only these no-op console members; reuse a richer fixture type
    # when SetupCommon has already loaded it because CLR types cannot be replaced in-process.
    if (-not ('Spectre.Console.AnsiConsole' -as [type])) {
        Add-Type -TypeDefinition @'
namespace Spectre.Console {
    public static class AnsiConsole {
        public static void MarkupLine(string value) {}
        public static void WriteLine() {}
    }
}
'@
    }
}

Describe '<Provider> branch-aware setup orchestration' -ForEach @(
    @{ Provider = 'GitHub'; Source = 'setup-github.ps1'; Wizard = 'Invoke-GitHubBranchAwareSetup' }
    @{ Provider = 'Azure DevOps'; Source = 'setup-azdo.ps1'; Wizard = 'Invoke-AzDoBranchAwareSetup' }
) {
    BeforeAll {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $Source), [ref]$tokens, [ref]$parseErrors)
        # Exercise orchestration functions without running installer startup and authentication.
        foreach ($definition in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
            Set-Item -Path "Function:$($definition.Name)" -Value $definition.Body.GetScriptBlock()
        }
    }

    BeforeEach {
        $script:credential = [pscustomobject]@{ ApplicationId = 'app'; TenantId = 'example.com'; AuthType = 'WIF' }
        $script:dev = [pscustomobject]@{ ShortName = 'Dev-main'; FriendlyName = 'Development'; Url = 'https://dev.example.com'; Credentials = $script:credential; ServiceAccountUPN = 'service@example.com' }
        $script:target = [pscustomobject]@{ ShortName = 'TEST'; FriendlyName = 'Test'; Url = 'https://test.example.com'; Credentials = $script:credential; ServiceAccountUPN = 'service@example.com' }
        $script:mappings = @([pscustomobject]@{
            BranchName = 'main'
            DevEnvironmentConfiguration = $script:dev
            ExistingDevEnvironment = $script:dev
            Environments = @($script:target)
            BuildValidationEnabled = $false
            BuildValidationEnvironmentName = ''
            BuildValidationBaselineRelease = ''
            BuildValidationEnvironmentConfiguration = $null
            ExistingBuildValidationEnvironment = $null
        })
        $script:existingState = [pscustomobject]@{
            DevEnvironment = $script:dev
            DeploymentEnvironments = @($script:target)
            DeploymentBranchMappings = @([pscustomobject]@{ BranchName = 'main'; Environments = @($script:target) })
            BranchStates = @([pscustomobject]@{
                BranchName = 'main'
                ExistingDevEnvironment = $script:dev
                DeploymentEnvironments = @($script:target)
                ExistingBuildValidationEnvironment = $null
                BuildValidationEnabled = $false
                BuildValidationEnvironmentName = ''
                BuildValidationBaselineRelease = ''
            })
            BuildValidationEnabled = $false
            BuildValidationEnvironmentName = ''
            ExistingBuildValidationEnvironment = $null
        }
        $script:validationEnabled = $false
        Mock Write-Section {}
        Mock Write-SetupGuidance {}
        Mock Show-KeyValueSummaryTable {}
        Mock Show-BranchEnvironmentMappingTable {}
        Mock Show-EnvironmentConfigurationTable {}
        Mock Confirm-SetupReviewAction {}
        Mock Show-SetupChangeReview {
            $script:reviewResourceChanges = @($ResourceChanges)
            $script:reviewResourceChangeNote = $ResourceChangeNote
        }
        Mock Invoke-WithErrorHandling { & $ScriptBlock }
        Mock Invoke-WithSpectreStatus { & $ScriptBlock }
        Mock Invoke-SetupWizard {
            $script:setupWizardSteps = @($Steps | ForEach-Object { $_.Name })
            foreach ($step in $Steps) {
                & $step.Action | Out-Null
            }
            & $ApplyAction
        }
        Mock Select-BranchEnvironmentMapping {
            $branchMappings = @($script:mappings)
            $script:branchEditorCallbacks = [ordered]@{
                DevEnvironment = [bool]$EditDevEnvironmentScriptBlock
                DeploymentEnvironments = [bool]$EditDeploymentEnvironmentsScriptBlock
                BuildValidation = [bool]$EditBuildValidationScriptBlock
            }
            foreach ($mapping in $branchMappings) {
                $defaultBuildValidationProperties = [ordered]@{
                    BuildValidationEnabled = $false
                    BuildValidationEnvironmentName = ''
                    BuildValidationBaselineRelease = ''
                    BuildValidationEnvironmentConfiguration = $null
                    ExistingBuildValidationEnvironment = $null
                }
                foreach ($property in $defaultBuildValidationProperties.GetEnumerator()) {
                    if ($mapping.PSObject.Properties.Name -notcontains $property.Key) {
                        $mapping | Add-Member -NotePropertyName $property.Key -NotePropertyValue $property.Value
                    }
                }

                if ($EditBuildValidationScriptBlock) {
                    $buildValidationSettings = & $EditBuildValidationScriptBlock @($branchMappings) $mapping
                    [void](Set-BranchBuildValidationMapping -BranchMapping $mapping -BuildValidationSettings $buildValidationSettings)
                }
            }
            return $branchMappings
        }
        Mock Read-YesNo { $script:validationEnabled }
        Mock Read-TextWithDefault { $DefaultValue }
        Mock Select-FromMenu { 0 }
        Mock Select-BuildValidationBaselineEnvironment { '@TEST' }
        Mock Select-DataverseEnvironment { [pscustomobject]@{ FriendlyName = 'Validation'; Endpoints = @{ WebApplication = 'https://build.example.com/' } } }
        Mock Get-BranchTargetedRepoChangePublishPlan { [pscustomobject]@{ Mode = 'Direct'; BranchName = $TargetBranch; TargetBranch = $TargetBranch } }
        Mock Get-DataverseSolutionsSelection { [pscustomobject]@{ Solutions = @([pscustomobject]@{ name = 'Example' }) } }
        $workingRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $workingRoot | Out-Null
        $script:setupWizardSteps = @()
        $script:branchEditorCallbacks = $null
        $script:reviewResourceChanges = @()
        $script:reviewResourceChangeNote = $null
        if ($Provider -eq 'GitHub') {
            Mock Get-GitHubSetupArtifactsPreview { [pscustomobject]@{ FileChanges = @() } }
            Mock Get-GitHubExistingEnvironmentState { $script:dev }
            Mock Get-GitHubEnvironmentConfiguration { [pscustomobject]@{ ShortName = $EnvironmentName; FriendlyName = $FriendlyName; Url = $EnvironmentUrl; Credentials = $script:credential; ServiceAccountUPN = 'service@example.com' } }
            Mock Publish-GitHubBranchSetupChange { [pscustomobject]@{ BranchName = $ConfiguredBranch; TargetBranch = $ConfiguredBranch; PullRequestUrl = $null; Mode = 'Direct'; HasChanges = $true } }
            $script:wizardParameters = @{
                CloneRoot = $workingRoot
                RepoOwner = 'owner'
                RepoName = 'repo'
                RepoFullName = 'owner/repo'
                RepoIdentity = [pscustomobject]@{ UseImmutableSubject = $true }
                DefaultBranch = 'main'
                TenantId = 'example.com'
                ExistingSetupState = $script:existingState
                SharedWorkflowRepository = 'owner/shared'
                SharedWorkflowReference = 'stable'
                UpstreamGitSource = $repoRoot
                ALM4DataverseRef = 'stable'
                UseGitHubEnvironments = $true
                UseRepositoryVariablePrefix = $true
                EnableEnvironmentApprovals = $false
                RequiredReviewerIds = @()
                DeploymentPromotionMode = 'manual-gate-tag'
                ProviderOptions = [ordered]@{
                    GitHubUseEnvironments = $true
                    GitHubDeploymentPromotionMode = 'manual-gate-tag'
                    GitHubUseRepositoryVariablePrefix = $true
                }
            }
        }
        else {
            Mock Get-AzDoSetupArtifactsPreview { [pscustomobject]@{ FileChanges = @() } }
            Mock Get-AzDoRepositoryExistingSetupState { $script:existingState }
            Mock Get-AzDoEnvironmentConfiguration { [pscustomobject]@{ ShortName = $EnvironmentName; FriendlyName = $FriendlyName; Url = $EnvironmentUrl; Credentials = $script:credential; ServiceAccountUPN = 'service@example.com' } }
            Mock Get-GitRepoFileContentFromRemoteBranch { '@{ solutions = @() }' }
            Mock Publish-AzDoBranchSetupChange { [pscustomobject]@{ BranchName = $ConfiguredBranch; TargetBranch = $ConfiguredBranch; PullRequestUrl = $null; Mode = 'Direct'; HasChanges = $true } }
            $script:wizardParameters = @{
                MainRepoWorkingRoot = $workingRoot
                MainRepo = [pscustomobject]@{ Name = 'repo' }
                SelectedProject = [pscustomobject]@{ Name = 'project' }
                OrganizationName = 'org'
                TenantId = 'example.com'
                DefaultBranch = 'main'
                AccessToken = 'test-token'
                CopyRoot = (Join-Path $repoRoot 'copy-to-your-repo')
                SharedRepositoryName = 'shared'
                SharedRepositoryRef = 'main'
                UseAlm4DataverseExtension = $true
                ALM4DataverseRef = 'stable'
                ProviderOptions = [ordered]@{ azDOUseAlm4DataverseExtension = $true }
            }
        }
    }

    It 'retains configured branches and uses their DEV environment for solutions' {
        $result = & $Wizard @script:wizardParameters
        $result.BranchStates.Count | Should -Be 1
        $result.BranchStates[0].DevEnvironmentConfiguration.Url | Should -Be $script:dev.Url
        $result.SolutionSourceBranch | Should -Be main
        $result.BuildValidationEnabled | Should -BeFalse
        Should -Invoke Read-YesNo -Times 1 -Exactly -ParameterFilter {
            $Prompt -eq "Enable Dataverse deployment validation during BUILD for branch 'main'?" -and $DefaultNo
        }
        Should -Invoke Get-DataverseSolutionsSelection -Times 1 -Exactly -ParameterFilter { $ExistingEnvironmentUrl -eq 'https://dev.example.com' }
        Should -Invoke Confirm-SetupReviewAction -Times 1 -Exactly
    }

    It 'combines setup review and previews after provider-specific choices' {
        $null = & $Wizard @script:wizardParameters

        $script:setupWizardSteps | Should -Contain 'Review setup changes'
        $script:setupWizardSteps | Should -Not -Contain 'Review choices'
        $script:setupWizardSteps | Should -Not -Contain 'Preview alm-config.psd1'
        $script:setupWizardSteps | Should -Not -Contain 'Preview generated workflows'
        $script:setupWizardSteps | Should -Not -Contain 'Preview generated pipelines'
        if ($Provider -eq 'GitHub') {
            [System.Array]::IndexOf($script:setupWizardSteps, 'Configure GitHub OIDC identity') |
                Should -BeLessThan ([System.Array]::IndexOf($script:setupWizardSteps, 'Review setup changes'))
        }
    }

    It 'includes deferred provider resource changes without exposing credential values' {
        $script:credential.AuthType = 'Secret'
        $script:credential | Add-Member -NotePropertyName ClientSecret -NotePropertyValue 'must-not-be-shown' -Force
        if ($Provider -eq 'GitHub') {
            $script:wizardParameters.EnableEnvironmentApprovals = $true
            $script:wizardParameters.RequiredReviewerIds = @(42)
        }

        $null = & $Wizard @script:wizardParameters
        $script:reviewResourceChanges.Count | Should -BeGreaterThan 0
        $resourceSummary = ($script:reviewResourceChanges | ForEach-Object {
                "$($_.Action) $($_.Resource) $($_.Target) $($_.Details)"
            }) -join ' '
        $resourceSummary | Should -Not -Match 'must-not-be-shown'
        $script:reviewResourceChangeNote | Should -Match 'prerequisites already created during setup are excluded'

        if ($Provider -eq 'GitHub') {
            $script:reviewResourceChanges.Resource | Should -Contain 'GitHub environment'
            $script:reviewResourceChanges.Resource | Should -Contain 'Dataverse application and service-account users'
            $resourceSummary | Should -Match 'AZURE_CLIENT_SECRET'
            $resourceSummary | Should -Match 'selected reviewer'
        }
        else {
            $script:reviewResourceChanges.Resource | Should -Contain 'Azure DevOps YAML pipelines'
            $script:reviewResourceChanges.Resource | Should -Contain 'Azure DevOps Build Service permission'
            $script:reviewResourceChanges.Resource | Should -Contain 'Azure DevOps service connection'
            $script:reviewResourceChanges.Resource | Should -Contain 'Azure DevOps variable group and checks'
        }
    }

    It 'previews committed configuration without invoking publication or provider setup' {
        $script:wizardParameters.ApplyConfig = $true
        $script:wizardParameters.PreviewOnly = $true
        $script:postApplyCalled = $false
        $script:wizardParameters.PostApplyAction = {
            $script:postApplyCalled = $true
        }

        $result = & $Wizard @script:wizardParameters

        $result.PublishResults | Should -BeNullOrEmpty
        $script:postApplyCalled | Should -BeFalse
        $script:reviewResourceChanges | Should -BeNullOrEmpty
        $script:reviewResourceChangeNote | Should -Match 'only modifies repository files'
        Should -Invoke Show-SetupChangeReview -Times 1 -Exactly -ParameterFilter { $PreviewOnly }
        Should -Invoke Confirm-SetupReviewAction -Times 0 -Exactly
        Should -Invoke Invoke-SetupWizard -Times 0 -Exactly
        if ($Provider -eq 'GitHub') {
            Should -Invoke Publish-GitHubBranchSetupChange -Times 0 -Exactly
        }
        else {
            Should -Invoke Publish-AzDoBranchSetupChange -Times 0 -Exactly
        }
    }

    It 'runs provider-specific setup as part of the final Apply action' {
        $script:postApplyCalled = $false
        $script:wizardParameters.PostApplyAction = {
            param($setupResult)
            $script:postApplyCalled = $setupResult.BranchStates.Count -gt 0
        }

        $null = & $Wizard @script:wizardParameters
        $script:postApplyCalled | Should -BeTrue
    }

    It 'applies GitHub environment settings in the retryable Apply callback' -Skip:($Provider -ne 'GitHub') {
        Mock Set-GitHubEnvironmentConfiguration {}
        $setupResult = [pscustomobject]@{
            BranchStates = @([pscustomobject]@{
                BranchName = 'main'
                DevEnvironmentConfiguration = $script:dev
                DeploymentEnvironments = @($script:target)
                BuildValidationEnabled = $false
                BuildValidationEnvironmentConfiguration = $null
            })
            UseImmutableWifSubject = $false
        }

        Invoke-GitHubSetupPostApply `
            -SetupResult $setupResult `
            -RepoIdentity ([pscustomobject]@{ UseImmutableSubject = $false }) `
            -TenantId 'example.com' `
            -RepoOwner owner `
            -RepoName repo `
            -RepoFullName owner/repo `
            -RepoOwnerId 1 `
            -RepoId 2 `
            -UseGitHubEnvironments $true `
            -UseRepositoryVariablePrefix $true `
            -EnableEnvironmentApprovals $false

        Should -Invoke Set-GitHubEnvironmentConfiguration -Times 2 -Exactly
    }

    It 'registers Azure DevOps resources in the retryable Apply callback' -Skip:($Provider -ne 'Azure DevOps') {
        Mock Initialize-AzDoBuildServiceRepositoryPermission {}
        Mock Initialize-AzDoMainRepositoryPipeline {}
        Set-Item -Path Function:Get-VSTeamBuildDefinition -Value { @() }
        Mock Get-VSTeamBuildDefinition {
            @(
                [pscustomobject]@{ name = 'BUILD'; path = '\repo'; id = 1 }
                [pscustomobject]@{ name = 'EXPORT'; path = '\repo'; id = 2 }
                [pscustomobject]@{ name = 'DEPLOY-main'; path = '\repo'; id = 3 }
            )
        }
        Mock Initialize-AzDoPipelinePermission {}
        Mock Set-AzDoEnvironmentConfiguration {}
        $setupResult = [pscustomobject]@{
            BranchStates = @([pscustomobject]@{
                BranchName = 'main'
                DevEnvironmentConfiguration = $script:dev
                DeploymentEnvironments = @($script:target)
                BuildValidationEnabled = $false
                BuildValidationEnvironmentConfiguration = $null
            })
        }

        Invoke-AzDoSetupPostApply `
            -SetupResult $setupResult `
            -SelectedProject ([pscustomobject]@{ Name = 'project'; Id = 'project-id' }) `
            -MainRepo ([pscustomobject]@{ Name = 'repo'; Id = 'main-id' }) `
            -SharedRepository ([pscustomobject]@{ Id = 'shared-id' }) `
            -OrganizationName org

        Should -Invoke Initialize-AzDoMainRepositoryPipeline -Times 1 -Exactly -ParameterFilter {
            $YamlFiles -contains 'pipelines/DEPLOY-main.yml'
        }
        Should -Invoke Set-AzDoEnvironmentConfiguration -Times 2 -Exactly
    }

    It 'configures a branch BUILD environment and a separate baseline' {
        $buildValidationEnvironment = [pscustomobject]@{
            ShortName = 'Build-main'
            FriendlyName = 'Build validation'
            Url = 'https://build.example.com'
            Credentials = $script:credential
            ServiceAccountUPN = 'service@example.com'
        }
        $script:existingState.BuildValidationEnabled = $true
        $script:existingState.BranchStates[0].BuildValidationEnabled = $true
        $script:existingState.BranchStates[0].BuildValidationEnvironmentName = 'Build-main'
        $script:existingState.BranchStates[0].ExistingBuildValidationEnvironment = $buildValidationEnvironment
        $script:mappings[0].BuildValidationEnabled = $true
        $script:mappings[0].BuildValidationEnvironmentName = 'Build-main'
        $script:mappings[0].ExistingBuildValidationEnvironment = $buildValidationEnvironment
        $script:validationEnabled = $true
        $result = & $Wizard @script:wizardParameters
        $result.BuildValidationEnabled | Should -BeTrue
        $result.BuildValidationEnvironmentConfiguration.ShortName | Should -Be 'Build-main'
        $result.BuildValidationBaselineRelease | Should -Be '@TEST'
        Should -Invoke Read-YesNo -Times 1 -Exactly
        Should -Invoke Select-BuildValidationBaselineEnvironment -Times 1 -Exactly -ParameterFilter { $ExcludedEnvironmentUrl -eq 'https://build.example.com' }
    }

    It 'rejects duplicate deployment targets before review or publishing' {
        $script:mappings += [pscustomobject]@{ BranchName = 'release'; DevEnvironmentConfiguration = $null; ExistingDevEnvironment = $null; Environments = @($script:target) }
        { & $Wizard @script:wizardParameters } | Should -Throw '*only be assigned to one branch*'
        Should -Invoke Confirm-SetupReviewAction -Times 0 -Exactly
        if ($Provider -eq 'GitHub') { Should -Invoke Publish-GitHubBranchSetupChange -Times 0 -Exactly }
    }

    It 'rejects configured branches without any environment' -Skip:($Provider -ne 'GitHub') {
        $script:mappings = @([pscustomobject]@{ BranchName = 'main'; DevEnvironmentConfiguration = $null; ExistingDevEnvironment = $null; Environments = @() })
        { & $Wizard @script:wizardParameters } | Should -Throw '*at least one mapped environment*'
        Should -Invoke Confirm-SetupReviewAction -Times 0 -Exactly
    }

    It 'skips solution discovery when only deployment targets are configured' {
        $script:mappings[0].DevEnvironmentConfiguration = $null
        $result = & $Wizard @script:wizardParameters
        $result.SolutionSourceBranch | Should -BeNullOrEmpty
        Should -Invoke Get-DataverseSolutionsSelection -Times 0 -Exactly
    }

    It 'does not publish after review is cancelled' {
        Mock Confirm-SetupReviewAction { throw 'Setup cancelled by user.' }
        { & $Wizard @script:wizardParameters } | Should -Throw '*cancelled by user*'
        if ($Provider -eq 'GitHub') { Should -Invoke Publish-GitHubBranchSetupChange -Times 0 -Exactly }
    }

    It 'runs the DEV and deployment editor callbacks with positional contracts intact' {
        Mock Read-YesNo { $Prompt -like 'Configure a DEV*' }
        Mock Select-BranchEnvironmentMapping {
            $script:branchEditorBuildValidationCalls = 0
            foreach ($mapping in $script:mappings) {
                $mapping.DevEnvironmentConfiguration = & $EditDevEnvironmentScriptBlock @($script:mappings) $mapping
                $mapping.Environments = @(& $EditDeploymentEnvironmentsScriptBlock @($script:mappings) $mapping)
                $buildValidationSettings = & $EditBuildValidationScriptBlock @($script:mappings) $mapping
                [void](Set-BranchBuildValidationMapping -BranchMapping $mapping -BuildValidationSettings $buildValidationSettings)
                $script:branchEditorBuildValidationCalls++
                $mapping
            }
        }
        if ($Provider -eq 'GitHub') {
            Mock Select-ConfiguredDeploymentEnvironment {
                $added = & $AddEnvironmentScriptBlock @()
                $edited = & $EditEnvironmentScriptBlock @($added) $added 0
                $edited
            }
            Mock Read-TextWithDefault { if ($DefaultValue) { $DefaultValue } else { 'TEST' } }
        }
        else {
            Mock Get-DataverseEnvironmentsSelection { $script:target }
        }
        $result = & $Wizard @script:wizardParameters
        $result.BranchStates[0].DevEnvironmentConfiguration.ShortName | Should -Be 'Dev-main'
        $result.BranchStates[0].DeploymentEnvironments[0].ShortName | Should -Be TEST
        $result.SolutionSourceBranch | Should -Be main
        $script:branchEditorBuildValidationCalls | Should -Be 1
    }

    It 'rejects enabled BUILD validation when no environment was selected' {
        $script:validationEnabled = $true
        Mock Select-DataverseEnvironment { $null }
        { & $Wizard @script:wizardParameters } | Should -Throw '*no Dataverse environment was selected*'
        Should -Invoke Confirm-SetupReviewAction -Times 0 -Exactly
    }

    It 'selects a solution source when multiple branches have DEV environments' {
        $script:mappings += [pscustomobject]@{ BranchName = 'release'; DevEnvironmentConfiguration = $script:dev; ExistingDevEnvironment = $script:dev; Environments = @() }
        Mock Select-FromMenu { 1 }
        $result = & $Wizard @script:wizardParameters
        $result.BranchStates.Count | Should -Be 2
        $result.SolutionSourceBranch | Should -Be release
    }

    It 'keeps per-branch environment settings inside the Configure branches step' {
        $null = & $Wizard @script:wizardParameters

        $script:setupWizardSteps | Should -Contain 'Configure branches'
        $script:setupWizardSteps | Should -Not -Contain 'Continue DEV access'
        $script:setupWizardSteps | Should -Not -Contain 'Configure DEV environments'
        $script:setupWizardSteps | Should -Not -Contain 'Configure deployment environments'
        $script:setupWizardSteps | Should -Not -Contain 'Configure BUILD validation'
        $script:branchEditorCallbacks.DevEnvironment | Should -BeTrue
        $script:branchEditorCallbacks.DeploymentEnvironments | Should -BeTrue
        $script:branchEditorCallbacks.BuildValidation | Should -BeTrue
    }

    It 'keeps default-branch workflow availability and retires removed branch deployment workflows' -Skip:($Provider -ne 'GitHub') {
        $script:existingState.DeploymentBranchMappings += [pscustomobject]@{ BranchName = 'retired'; Environments = @() }
        $script:mappings = @([pscustomobject]@{ BranchName = 'release'; DevEnvironmentConfiguration = $script:dev; ExistingDevEnvironment = $script:dev; Environments = @($script:target) })
        $script:wizardParameters.UseGitHubEnvironments = $false
        $result = & $Wizard @script:wizardParameters
        $result.BranchStates[0].BranchName | Should -Be release
        $result.PublishResults.ConfiguredBranch | Should -Be @('release', 'main', 'retired')
        Should -Invoke Publish-GitHubBranchSetupChange -Times 1 -Exactly -ParameterFilter { $ConfiguredBranch -eq 'retired' -and $SkipDeployWorkflow }
        Should -Invoke Publish-GitHubBranchSetupChange -Times 1 -Exactly -ParameterFilter { $ConfiguredBranch -eq 'main' -and @($DeployWorkflowBranchDefinitions).Count -eq 2 }
    }
}

Describe 'Provider setup artifact preview scopes' {
    BeforeAll {
        $repositoryRoot = Split-Path $PSScriptRoot -Parent
        foreach ($scriptName in @('setup-github.ps1', 'setup-azdo.ps1')) {
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repositoryRoot $scriptName), [ref]$tokens, [ref]$parseErrors)
            if ($parseErrors) {
                throw "Could not parse $scriptName`: $($parseErrors[0].Message)"
            }
            foreach ($definition in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
                Set-Item -Path "Function:$($definition.Name)" -Value $definition.Body.GetScriptBlock()
            }
        }

    }

    It 'compares the complete GitHub scaffold scope without changing the source repository' {
        $repositoryRoot = Join-Path $TestDrive 'github-preview/repository'
        $copyRoot = Join-Path $TestDrive 'github-preview/scaffold'
        foreach ($relativeDirectory in @('.github/workflows', 'pipelines', 'data')) {
            New-Item -ItemType Directory -Path (Join-Path $repositoryRoot $relativeDirectory) -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $copyRoot $relativeDirectory) -Force | Out-Null
        }
        [System.IO.File]::WriteAllText((Join-Path $repositoryRoot '.github/workflows/BUILD.yml'), 'old workflow')
        [System.IO.File]::WriteAllText((Join-Path $repositoryRoot 'pipelines/removed.yml'), 'obsolete pipeline')
        [System.IO.File]::WriteAllText((Join-Path $repositoryRoot 'data/existing.txt'), 'preserved data')
        [System.IO.File]::WriteAllText((Join-Path $repositoryRoot 'AGENTS.md'), 'old instructions')
        [System.IO.File]::WriteAllText((Join-Path $repositoryRoot 'alm-config.psd1'), 'old config')
        [System.IO.File]::WriteAllText((Join-Path $repositoryRoot 'README.md'), 'outside comparison scope')
        [System.IO.File]::WriteAllText((Join-Path $copyRoot 'AGENTS.md'), 'scaffold instructions')
        $fixture = [pscustomobject]@{
            RepositoryRoot = $repositoryRoot
            CopyRoot = $copyRoot
        }
        Mock Get-AlmSetupConfiguration { [ordered]@{} }
        Mock Get-AlmSetupBuildValidationEnvironmentMap { [ordered]@{} }
        Mock Get-GitHubSetupRemovedBranchName { @() }
        Mock Get-GitHubSetupDeployWorkflowDefinition { @() }
        Mock Invoke-GitHubSetupArtifactGeneration {
            $script:previewGeneratorSawAllRoots = @(
                (Test-Path -LiteralPath (Join-Path $RepoRoot '.github/workflows/BUILD.yml'))
                (Test-Path -LiteralPath (Join-Path $RepoRoot 'pipelines/removed.yml'))
                (Test-Path -LiteralPath (Join-Path $RepoRoot 'data/existing.txt'))
                (Test-Path -LiteralPath (Join-Path $RepoRoot 'AGENTS.md'))
                (Test-Path -LiteralPath (Join-Path $RepoRoot 'alm-config.psd1'))
            ) -notcontains $false
            [System.IO.File]::WriteAllText((Join-Path $RepoRoot '.github/workflows/BUILD.yml'), 'new workflow')
            [System.IO.File]::WriteAllText((Join-Path $RepoRoot 'data/added.txt'), 'new data')
            [System.IO.File]::WriteAllText((Join-Path $RepoRoot 'AGENTS.md'), 'new instructions')
            [System.IO.File]::WriteAllText((Join-Path $RepoRoot 'alm-config.psd1'), 'new config')
            Remove-Item -LiteralPath (Join-Path $RepoRoot 'pipelines/removed.yml') -Force
        }

        $preview = Get-GitHubSetupArtifactsPreview `
            -RepoRoot $fixture.RepositoryRoot `
            -CopyRoot $fixture.CopyRoot `
            -DefaultBranch main `
            -Repository owner/shared `
            -Ref stable `
            -PromotionMode manual-gate-tag `
            -ExistingSetupState ([pscustomobject]@{}) `
            -BranchStates @([pscustomobject]@{ BranchName = 'main'; DeploymentEnvironments = @() }) `
            -ProviderOptions ([ordered]@{}) `
            -SolutionResult $null

        $script:previewGeneratorSawAllRoots | Should -BeTrue
        ($preview.FileChanges | Where-Object Path -eq '.github/workflows/BUILD.yml').Status | Should -Be Modified
        ($preview.FileChanges | Where-Object Path -eq 'data/added.txt').Status | Should -Be Added
        ($preview.FileChanges | Where-Object Path -eq 'pipelines/removed.yml').Status | Should -Be Deleted
        ($preview.FileChanges | Where-Object Path -eq 'AGENTS.md').Status | Should -Be Modified
        ($preview.FileChanges | Where-Object Path -eq 'alm-config.psd1').Status | Should -Be Modified
        [System.IO.File]::ReadAllText((Join-Path $fixture.RepositoryRoot '.github/workflows/BUILD.yml')) | Should -Be 'old workflow'
        [System.IO.File]::ReadAllText((Join-Path $fixture.RepositoryRoot 'README.md')) | Should -Be 'outside comparison scope'
    }

    It 'compares the complete Azure DevOps scaffold scope without changing the source repository' {
        $repositoryRoot = Join-Path $TestDrive 'azdo-preview/repository'
        $copyRoot = Join-Path $TestDrive 'azdo-preview/scaffold'
        foreach ($relativeDirectory in @('.github/workflows', 'pipelines', 'data')) {
            New-Item -ItemType Directory -Path (Join-Path $repositoryRoot $relativeDirectory) -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $copyRoot $relativeDirectory) -Force | Out-Null
        }
        [System.IO.File]::WriteAllText((Join-Path $repositoryRoot '.github/workflows/BUILD.yml'), 'old workflow')
        [System.IO.File]::WriteAllText((Join-Path $repositoryRoot 'pipelines/removed.yml'), 'obsolete pipeline')
        [System.IO.File]::WriteAllText((Join-Path $repositoryRoot 'data/existing.txt'), 'preserved data')
        [System.IO.File]::WriteAllText((Join-Path $repositoryRoot 'AGENTS.md'), 'old instructions')
        [System.IO.File]::WriteAllText((Join-Path $repositoryRoot 'alm-config.psd1'), 'old config')
        [System.IO.File]::WriteAllText((Join-Path $repositoryRoot 'README.md'), 'outside comparison scope')
        [System.IO.File]::WriteAllText((Join-Path $copyRoot 'AGENTS.md'), 'scaffold instructions')
        $fixture = [pscustomobject]@{
            RepositoryRoot = $repositoryRoot
            CopyRoot = $copyRoot
        }
        Mock Get-AlmSetupConfiguration { [ordered]@{} }
        Mock Get-AlmSetupBuildValidationEnvironmentMap { [ordered]@{} }
        Mock Invoke-AzDoSetupArtifactGeneration {
            $script:previewGeneratorSawAllRoots = @(
                (Test-Path -LiteralPath (Join-Path $RepoRoot '.github/workflows/BUILD.yml'))
                (Test-Path -LiteralPath (Join-Path $RepoRoot 'pipelines/removed.yml'))
                (Test-Path -LiteralPath (Join-Path $RepoRoot 'data/existing.txt'))
                (Test-Path -LiteralPath (Join-Path $RepoRoot 'AGENTS.md'))
                (Test-Path -LiteralPath (Join-Path $RepoRoot 'alm-config.psd1'))
            ) -notcontains $false
            [System.IO.File]::WriteAllText((Join-Path $RepoRoot '.github/workflows/BUILD.yml'), 'new workflow')
            [System.IO.File]::WriteAllText((Join-Path $RepoRoot 'data/added.txt'), 'new data')
            [System.IO.File]::WriteAllText((Join-Path $RepoRoot 'AGENTS.md'), 'new instructions')
            [System.IO.File]::WriteAllText((Join-Path $RepoRoot 'alm-config.psd1'), 'new config')
            Remove-Item -LiteralPath (Join-Path $RepoRoot 'pipelines/removed.yml') -Force
            New-Item -ItemType Directory -Path (Join-Path $RepoRoot 'pipelines') -Force | Out-Null
        }

        $preview = Get-AzDoSetupArtifactsPreview `
            -RepoRoot $fixture.RepositoryRoot `
            -CopyRoot $fixture.CopyRoot `
            -MainRepo ([pscustomobject]@{ Name = 'sample-app' }) `
            -SharedRepositoryName ALM4Dataverse `
            -SharedRepositoryRef stable `
            -UseAlm4DataverseExtension $true `
            -BranchStates @([pscustomobject]@{ BranchName = 'main'; DeploymentEnvironments = @() }) `
            -ProviderOptions ([ordered]@{}) `
            -SolutionData $null

        $script:previewGeneratorSawAllRoots | Should -BeTrue
        ($preview.FileChanges | Where-Object Path -eq '.github/workflows/BUILD.yml').Status | Should -Be Modified
        ($preview.FileChanges | Where-Object Path -eq 'data/added.txt').Status | Should -Be Added
        ($preview.FileChanges | Where-Object Path -eq 'pipelines/removed.yml').Status | Should -Be Deleted
        ($preview.FileChanges | Where-Object Path -eq 'AGENTS.md').Status | Should -Be Modified
        ($preview.FileChanges | Where-Object Path -eq 'alm-config.psd1').Status | Should -Be Modified
        [System.IO.File]::ReadAllText((Join-Path $fixture.RepositoryRoot '.github/workflows/BUILD.yml')) | Should -Be 'old workflow'
        [System.IO.File]::ReadAllText((Join-Path $fixture.RepositoryRoot 'README.md')) | Should -Be 'outside comparison scope'
    }

    It 'plans GitHub repository, environment, identity, and Dataverse changes without secrets' {
        $wifCredentials = [pscustomobject]@{
            AuthType = 'WIF'
            ApplicationId = 'example-client'
            ApplicationObjectId = 'example-object'
            TenantId = 'example.invalid'
            ClientSecret = $null
        }
        $secretCredentials = [pscustomobject]@{
            AuthType = 'Secret'
            ApplicationId = 'example-client'
            ApplicationObjectId = $null
            TenantId = 'example.invalid'
            ClientSecret = 'github-preview-secret'
        }
        $branchStates = @([pscustomobject]@{
                BranchName = 'main'
                DevEnvironmentConfiguration = [pscustomobject]@{
                    ShortName = 'Dev-main'
                    Credentials = $wifCredentials
                    ServiceAccountUPN = 'automation@example.invalid'
                }
                BuildValidationEnabled = $true
                BuildValidationEnvironmentConfiguration = [pscustomobject]@{
                    ShortName = 'Build-main'
                    Credentials = $wifCredentials
                    ServiceAccountUPN = 'automation@example.invalid'
                }
                DeploymentEnvironments = @([pscustomobject]@{
                        ShortName = 'PROD'
                        Credentials = $secretCredentials
                        ServiceAccountUPN = 'automation@example.invalid'
                    })
            })

        $environmentChanges = @(Get-GitHubSetupResourceChange `
                -BranchStates $branchStates `
                -RepoIdentity ([pscustomobject]@{ UseImmutableSubject = $false }) `
                -RepoFullName owner/repo `
                -UseImmutableWifSubject $true `
                -UseGitHubEnvironments $true `
                -UseRepositoryVariablePrefix $true `
                -EnableEnvironmentApprovals $true `
                -RequiredReviewerIds @(42))

        $environmentChanges.Resource | Should -Contain 'GitHub repository OIDC setting'
        $environmentChanges.Resource | Should -Contain 'Entra federated identity credential'
        $environmentChanges.Resource | Should -Contain 'GitHub environment'
        $environmentChanges.Resource | Should -Contain 'Dataverse application and service-account users'
        ($environmentChanges | Where-Object { $_.Target -eq 'owner/repo/PROD' -and $_.Resource -eq 'GitHub environment' }).Details | Should -Match 'selected reviewer'
        ($environmentChanges | Where-Object { $_.Target -eq 'owner/repo/PROD' -and $_.Resource -eq 'GitHub environment' }).Details | Should -Match 'AZURE_CLIENT_SECRET'

        $repositoryVariableChanges = @(Get-GitHubSetupResourceChange `
                -BranchStates $branchStates `
                -RepoIdentity ([pscustomobject]@{ UseImmutableSubject = $true }) `
                -RepoFullName owner/repo `
                -UseImmutableWifSubject $true `
                -UseGitHubEnvironments $false `
                -UseRepositoryVariablePrefix $true `
                -EnableEnvironmentApprovals $false)
        $repositoryVariableChanges.Resource | Should -Contain 'GitHub repository variables'
        $repositoryVariableChanges.Resource | Should -Contain 'GitHub environment secret'
        (($environmentChanges + $repositoryVariableChanges | ConvertTo-Json -Depth 5 -Compress) -join '') |
            Should -Not -Match 'github-preview-secret'
    }

    It 'plans Azure DevOps pipelines, permissions, service connections, checks, and Dataverse roles' {
        $wifCredentials = [pscustomobject]@{
            AuthType = 'WIF'
            ApplicationId = 'example-client'
            ApplicationObjectId = 'example-object'
            TenantId = 'example.invalid'
            IsExistingServiceConnection = $false
        }
        $existingCredentials = [pscustomobject]@{
            AuthType = 'Secret'
            ApplicationId = 'example-client'
            TenantId = 'example.invalid'
            ClientSecret = 'azure-existing-secret'
            IsExistingServiceConnection = $true
        }
        $secretCredentials = [pscustomobject]@{
            AuthType = 'Secret'
            ApplicationId = 'example-client'
            TenantId = 'example.invalid'
            ClientSecret = 'azure-preview-secret'
            IsExistingServiceConnection = $false
        }
        $branchStates = @([pscustomobject]@{
                BranchName = 'main'
                DevEnvironmentConfiguration = [pscustomobject]@{
                    ShortName = 'Dev-main'
                    Credentials = $wifCredentials
                    ServiceAccountUPN = 'automation@example.invalid'
                }
                BuildValidationEnabled = $true
                BuildValidationEnvironmentConfiguration = [pscustomobject]@{
                    ShortName = 'Build-main'
                    Credentials = $existingCredentials
                    ServiceAccountUPN = 'automation@example.invalid'
                }
                DeploymentEnvironments = @([pscustomobject]@{
                        ShortName = 'PROD'
                        Credentials = $secretCredentials
                        ServiceAccountUPN = 'automation@example.invalid'
                    })
            })

        $changes = @(Get-AzDoSetupResourceChange `
                -BranchStates $branchStates `
                -SelectedProject ([pscustomobject]@{ Name = 'example-project' }) `
                -MainRepo ([pscustomobject]@{ Name = 'sample-app' }) `
                -SharedRepositoryName ALM4Dataverse)

        $changes.Resource | Should -Contain 'Azure DevOps YAML pipelines'
        $changes.Resource | Should -Contain 'Azure DevOps Build Service permission'
        $changes.Resource | Should -Contain 'Azure DevOps pipeline repository permissions'
        $changes.Resource | Should -Contain 'Entra federated identity credential'
        $changes.Resource | Should -Contain 'Azure DevOps environment'
        $changes.Resource | Should -Contain 'Azure DevOps variable group and checks'
        $changes.Resource | Should -Contain 'Dataverse application and service-account users'
        ($changes | Where-Object { $_.Resource -eq 'Azure DevOps YAML pipelines' }).Details | Should -Match 'DEPLOY-main'
        ($changes | Where-Object { $_.Target -eq 'example-project/Build-main' -and $_.Resource -eq 'Azure DevOps service connection' }).Action | Should -Be Reuse
        ($changes | Where-Object { $_.Target -eq 'example-project/Environment-Build-main' -and $_.Resource -eq 'Azure DevOps variable group and checks' }).Details |
            Should -Match 'Existing approval checks are retained'
        ($changes | Where-Object { $_.Target -eq 'example-project/Environment-PROD' -and $_.Resource -eq 'Azure DevOps variable group and checks' }).Details |
            Should -Match 'exclusive lock.*approval check'
        ($changes | ConvertTo-Json -Depth 5 -Compress) | Should -Not -Match 'azure-preview-secret|azure-existing-secret'
    }
}