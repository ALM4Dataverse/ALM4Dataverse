BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repoRoot 'setup/setup-common.ps1')
    . (Join-Path $repoRoot 'tests/helpers/SetupTestHelpers.ps1')
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
        $ast = Get-SetupProviderAst -RepositoryRoot $repoRoot -EntryPoint $Source
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
            $script:setupWizardPreviewAction = $PreviewAction
            foreach ($step in $Steps) {
                try {
                    & $step.Action | Out-Null
                }
                catch {
                    if ($ReturnToCaller -and (Test-IsSetupWizardBackException -Exception $_.Exception)) {
                        return $null
                    }
                    throw
                }
            }
            if ($PreviewAction) {
                & $PreviewAction | Out-Null
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
        Mock Invoke-SetupEnvironmentConfigurationWizard {
            $shortName = [string]$InitialTargetName
            $friendlyName = 'Test'
            $url = 'https://test.example.com'
            if ($Title -like '*BUILD validation*') {
                $friendlyName = 'Build validation'
                $url = 'https://build.example.com'
            }
            elseif ($Title -like '*DEV*') {
                $friendlyName = 'Development'
                $url = 'https://dev.example.com'
            }
            if ($InitialConfiguration) {
                if (-not [string]::IsNullOrWhiteSpace($InitialConfiguration.ShortName)) {
                    $shortName = [string]$InitialConfiguration.ShortName
                }
                if (-not [string]::IsNullOrWhiteSpace($InitialConfiguration.FriendlyName)) {
                    $friendlyName = [string]$InitialConfiguration.FriendlyName
                }
                if (-not [string]::IsNullOrWhiteSpace($InitialConfiguration.Url)) {
                    $url = [string]$InitialConfiguration.Url
                }
            }
            if ([string]::IsNullOrWhiteSpace($shortName)) {
                $shortName = if ($Title -like '*BUILD validation*') { 'Build-main' } else { 'TEST' }
            }
            $baselineRelease = [string]$InitialBaselineRelease
            if ($SelectBaselineAction) {
                $script:environmentWizardBaselineCalls++
                $baselineRelease = '@TEST'
            }

            return [pscustomobject]@{
                ShortName = $shortName
                FriendlyName = $friendlyName
                Url = $url
                Credentials = $script:credential
                ServiceAccountUPN = 'service@example.com'
                BaselineRelease = $baselineRelease
            }
        }
        Mock Get-BranchTargetedRepoChangePublishPlan { [pscustomobject]@{ Mode = 'Direct'; BranchName = $TargetBranch; TargetBranch = $TargetBranch } }
        Mock Get-DataverseSolutionsSelection { [pscustomobject]@{ Solutions = @([pscustomobject]@{ name = 'Example' }) } }
        $workingRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $workingRoot | Out-Null
        $script:setupWizardSteps = @()
        $script:branchEditorCallbacks = $null
        $script:reviewResourceChanges = @()
        $script:reviewResourceChangeNote = $null
        $script:sharedRepositoryPreview = $null
        $script:sharedRepositoryApply = $null
        $script:environmentWizardBaselineCalls = 0
        if ($Provider -eq 'GitHub') {
            Mock Get-GitHubSetupArtifactsPreview {
                $script:sharedRepositoryPreview = [pscustomobject]@{
                    Repository = $Repository
                    Ref = $Ref
                    CopyRoot = $CopyRoot
                }
                [pscustomobject]@{ FileChanges = @() }
            }
            Mock Get-GitHubExistingEnvironmentState { $script:dev }
            Mock Get-GitHubEnvironmentConfiguration { [pscustomobject]@{ ShortName = $EnvironmentName; FriendlyName = $FriendlyName; Url = $EnvironmentUrl; Credentials = $script:credential; ServiceAccountUPN = 'service@example.com' } }
            Mock Get-GitHubCredentialsForEnvironment { $script:credential }
            Mock Get-DataverseServiceAccountUPN { 'service@example.com' }
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
            Mock Get-AzDoSetupArtifactsPreview {
                $script:sharedRepositoryPreview = [pscustomobject]@{
                    Repository = $SharedRepositoryName
                    Ref = $SharedRepositoryRef
                    CopyRoot = $CopyRoot
                }
                [pscustomobject]@{ FileChanges = @() }
            }
            Mock Get-AzDoRepositoryExistingSetupState { $script:existingState }
            Mock Get-AzDoEnvironmentConfiguration { [pscustomobject]@{ ShortName = $EnvironmentName; FriendlyName = $FriendlyName; Url = $EnvironmentUrl; Credentials = $script:credential; ServiceAccountUPN = 'service@example.com' } }
            Mock Get-PowerPlatformSCCredential { $script:credential }
            Mock Get-DataverseServiceAccountUPN { 'service@example.com' }
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
        Should -Invoke Confirm-SetupReviewAction -Times 0 -Exactly
    }

    It 'keeps optional preview separate from required provider setup choices' {
        $null = & $Wizard @script:wizardParameters

        $script:setupWizardSteps | Should -Not -Contain 'Review setup changes'
        $script:setupWizardSteps | Should -Not -Contain 'Preview changes'
        $script:setupWizardSteps | Should -Not -Contain 'Review choices'
        $script:setupWizardSteps | Should -Not -Contain 'Preview alm-config.psd1'
        $script:setupWizardSteps | Should -Not -Contain 'Preview generated workflows'
        $script:setupWizardSteps | Should -Not -Contain 'Preview generated pipelines'
        $script:setupWizardPreviewAction | Should -BeOfType [scriptblock]
        if ($Provider -eq 'GitHub') {
            [System.Array]::IndexOf($script:setupWizardSteps, 'Configure GitHub OIDC identity') |
                Should -BeLessThan $script:setupWizardSteps.Count
        }
    }

    It 'uses the editable shared repository selection for artifact previews' {
        if ($Provider -eq 'GitHub') {
            $script:sharedRepositoryStateForTest = [ordered]@{
                Repository = ''
                Reference = ''
                ValidationError = 'No shared workflow repository is configured.'
            }
            $script:wizardParameters.SharedWorkflowRepository = ''
            $script:wizardParameters.SharedWorkflowReference = ''
            $script:wizardParameters.SharedWorkflowRepositoryState = $script:sharedRepositoryStateForTest
            $sharedRepositoryStep = [pscustomobject]@{
                Name = 'Select shared workflow repository'
                Action = {
                    $script:sharedRepositoryStateForTest.Repository = 'owner/selected'
                    $script:sharedRepositoryStateForTest.Reference = 'stable'
                }
            }
            $sharedRepositoryVersionStep = [pscustomobject]@{
                Name = 'Check and update shared workflow repository version'
                Action = {}
            }
            Mock Invoke-GitHubBranchAwareSetupApply {
                $script:sharedRepositoryApply = [pscustomobject]@{
                    Repository = $SharedWorkflowRepository
                    Ref = $SharedWorkflowReference
                }
                [pscustomobject]@{ BranchStates = @(); UseImmutableWifSubject = $false; PublishResults = @() }
            }
        }
        else {
            $script:sharedRepositoryStateForTest = [ordered]@{
                Name = 'initial'
                Ref = 'main'
                CopyRoot = (Join-Path $repoRoot 'copy-to-your-repo')
            }
            $script:wizardParameters.SharedRepositoryState = $script:sharedRepositoryStateForTest
            $sharedRepositoryStep = [pscustomobject]@{
                Name = 'Select shared repository'
                Action = {
                    $script:sharedRepositoryStateForTest.Name = 'selected'
                    $script:sharedRepositoryStateForTest.Ref = 'stable'
                    $script:sharedRepositoryStateForTest.CopyRoot = $script:wizardParameters.MainRepoWorkingRoot
                }
            }
            $sharedRepositoryVersionStep = [pscustomobject]@{
                Name = 'Check and update shared repository version'
                Action = {}
            }
            Mock Invoke-AzDoBranchAwareSetupApply {
                $script:sharedRepositoryApply = [pscustomobject]@{
                    Repository = $SharedRepositoryName
                    Ref = $SharedRepositoryRef
                    CopyRoot = $CopyRoot
                }
                [pscustomobject]@{ BranchStates = @(); PublishResults = @() }
            }
        }
        $script:wizardParameters.PrerequisiteSteps = @($sharedRepositoryStep, $sharedRepositoryVersionStep)

        $null = & $Wizard @script:wizardParameters

        if ($Provider -eq 'GitHub') {
            $script:setupWizardSteps[0] | Should -Be 'Select shared workflow repository'
            $script:sharedRepositoryPreview.Repository | Should -Be 'owner/selected'
            $script:sharedRepositoryPreview.Ref | Should -Be stable
            $script:sharedRepositoryApply.Repository | Should -Be 'owner/selected'
            $script:sharedRepositoryApply.Ref | Should -Be stable
            $script:setupWizardSteps | Should -Contain 'Select shared workflow repository'
            $script:setupWizardSteps | Should -Contain 'Check and update shared workflow repository version'
            [System.Array]::IndexOf($script:setupWizardSteps, 'Select shared workflow repository') |
                Should -BeLessThan ([System.Array]::IndexOf($script:setupWizardSteps, 'Check and update shared workflow repository version'))
        }
        else {
            $script:setupWizardSteps[0] | Should -Be 'Select shared repository'
            $script:sharedRepositoryPreview.Repository | Should -Be selected
            $script:sharedRepositoryPreview.Ref | Should -Be stable
            $script:sharedRepositoryApply.Repository | Should -Be selected
            $script:sharedRepositoryApply.Ref | Should -Be stable
            $script:sharedRepositoryPreview.CopyRoot | Should -Be $script:wizardParameters.MainRepoWorkingRoot
            $script:sharedRepositoryApply.CopyRoot | Should -Be $script:wizardParameters.MainRepoWorkingRoot
            $script:setupWizardSteps | Should -Contain 'Select shared repository'
            $script:setupWizardSteps | Should -Contain 'Check and update shared repository version'
            [System.Array]::IndexOf($script:setupWizardSteps, 'Select shared repository') |
                Should -BeLessThan ([System.Array]::IndexOf($script:setupWizardSteps, 'Check and update shared repository version'))
        }
    }

    It 'requires mutable state when GitHub shared workflow configuration is empty' -Skip:($Provider -ne 'GitHub') {
        $script:wizardParameters.SharedWorkflowRepository = ''
        $script:wizardParameters.SharedWorkflowReference = ''

        { & $Wizard @script:wizardParameters } |
            Should -Throw '*SharedWorkflowRepositoryState is required when the shared workflow repository or reference is empty*'
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
        $script:environmentWizardBaselineCalls | Should -Be 1
    }

    It 'rejects duplicate deployment targets before review or publishing' {
        $script:mappings += [pscustomobject]@{ BranchName = 'release'; DevEnvironmentConfiguration = $null; ExistingDevEnvironment = $null; Environments = @($script:target) }
        { & $Wizard @script:wizardParameters } | Should -Throw '*only be assigned to one branch*'
        Should -Invoke Show-SetupChangeReview -Times 0 -Exactly
        if ($Provider -eq 'GitHub') { Should -Invoke Publish-GitHubBranchSetupChange -Times 0 -Exactly }
    }

    It 'rejects configured branches without any environment' -Skip:($Provider -ne 'GitHub') {
        $script:mappings = @([pscustomobject]@{ BranchName = 'main'; DevEnvironmentConfiguration = $null; ExistingDevEnvironment = $null; Environments = @() })
        { & $Wizard @script:wizardParameters } | Should -Throw '*at least one mapped environment*'
        Should -Invoke Show-SetupChangeReview -Times 0 -Exactly
    }

    It 'skips solution discovery when only deployment targets are configured' {
        $script:mappings[0].DevEnvironmentConfiguration = $null
        $result = & $Wizard @script:wizardParameters
        $result.SolutionSourceBranch | Should -BeNullOrEmpty
        Should -Invoke Get-DataverseSolutionsSelection -Times 0 -Exactly
    }

    It 'does not apply when optional preview fails' {
        Mock Show-SetupChangeReview { throw 'Preview display failed.' }
        { & $Wizard @script:wizardParameters } | Should -Throw '*Preview display failed*'
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

    It 'applies target-name callbacks when adding and editing deployment environments' -Skip:($Provider -ne 'GitHub') {
        $script:environmentTargetNames = @()
        Mock Invoke-SetupEnvironmentConfigurationWizard {
            $targetName = if ([string]::IsNullOrWhiteSpace([string]$InitialTargetName)) { 'UAT' } else { [string]$InitialTargetName }
            if ($SelectTargetNameAction) {
                $targetName = & $SelectTargetNameAction ([pscustomobject]@{
                    ShortName = $targetName
                    Url = 'https://uat.example.com'
                })
                $script:environmentTargetNames += $targetName
            }

            return [pscustomobject]@{
                ShortName = $targetName
                FriendlyName = 'User Acceptance Testing'
                Url = 'https://uat.example.com'
                Credentials = $script:credential
                ServiceAccountUPN = 'service@example.com'
            }
        }
        Mock Select-BranchEnvironmentMapping {
            $mapping = $script:mappings[0]
            $mapping.Environments = @(& $EditDeploymentEnvironmentsScriptBlock @($script:mappings) $mapping)
            return @($mapping)
        }
        Mock Select-ConfiguredDeploymentEnvironment {
            $added = & $AddEnvironmentScriptBlock @()
            $edited = & $EditEnvironmentScriptBlock @($added, $script:target) $added 0
            return @($edited)
        }
        $previousGlobalReadTextWithDefault = Get-Item -Path 'Function:\global:Read-TextWithDefault' -ErrorAction SilentlyContinue
        Set-Item -Path 'Function:\global:Read-TextWithDefault' -Value {
            [CmdletBinding()]
            param($Prompt, $DefaultValue, $PromptGuidanceLines, $PromptGuidanceDocRelativePath, $PromptGuidanceRef)
            $null = @($Prompt, $PromptGuidanceLines, $PromptGuidanceDocRelativePath, $PromptGuidanceRef)
            if ($DefaultValue) { return $DefaultValue }
            return 'UAT'
        }

        try {
            $result = & $Wizard @script:wizardParameters
        }
        finally {
            if ($previousGlobalReadTextWithDefault) {
                Set-Item -Path 'Function:\global:Read-TextWithDefault' -Value $previousGlobalReadTextWithDefault.ScriptBlock
            }
            else {
                Remove-Item -Path 'Function:\global:Read-TextWithDefault' -ErrorAction SilentlyContinue
            }
        }

        $result.BranchStates[0].DeploymentEnvironments.Count | Should -Be 1
        $result.BranchStates[0].DeploymentEnvironments[0].ShortName | Should -Be 'UAT'
        $script:environmentTargetNames | Should -Be @('UAT', 'UAT')
    }

    It 'keeps Apply unavailable when an existing GitHub deployment environment is missing <MissingPart>' -ForEach @(
        @{ MissingPart = 'target name'; MissingField = 'ShortName' }
        @{ MissingPart = 'Dataverse environment'; MissingField = 'Url' }
        @{ MissingPart = 'credentials'; MissingField = 'Credentials' }
        @{ MissingPart = 'service account'; MissingField = 'ServiceAccountUPN' }
        @{ MissingPart = 'provider configuration'; MissingField = 'ConfigurationPending' }
    ) -Skip:($Provider -ne 'GitHub') {
        switch ($MissingField) {
            'ShortName' { $script:target.ShortName = '' }
            'Url' { $script:target.Url = '' }
            'Credentials' { $script:target.Credentials = $null }
            'ServiceAccountUPN' { $script:target.ServiceAccountUPN = '' }
            'ConfigurationPending' { $script:target | Add-Member -NotePropertyName ConfigurationPending -NotePropertyValue $true -Force }
        }
        $script:branchStepReturnedToMenu = $false
        $script:applyActionCalled = $false
        $script:branchMenuItems = @()
        $script:incompleteWarning = @()
        Mock Write-Host { $script:incompleteWarning += [string]$Object }
        Mock Invoke-SetupWizard {
            $branchStep = @($Steps | Where-Object { $_.Name -eq 'Configure branches, dev and deployment envs' })[0]
            $script:branchMenuItems = @(& $branchStep.SubItems)
            try {
                & $branchStep.Action | Out-Null
            }
            catch {
                if (Test-IsSetupWizardBackException -Exception $_.Exception) {
                    $script:branchStepReturnedToMenu = $true
                    return $null
                }
                throw
            }

            $script:applyActionCalled = $true
            & $ApplyAction
        }

        $null = & $Wizard @script:wizardParameters

        $deploymentMenuItem = @($script:branchMenuItems | Where-Object { $_.Target.Kind -eq 'DeploymentEnvironment' })
        $deploymentMenuItem.Count | Should -Be 1
        ($script:incompleteWarning -join ' ') | Should -Match ([regex]::Escape($MissingPart))
        $script:branchStepReturnedToMenu | Should -BeTrue
        $script:applyActionCalled | Should -BeFalse
        Should -Invoke Get-BranchTargetedRepoChangePublishPlan -Times 0 -Exactly
    }

    It 'leaves BUILD validation disabled when environment detail editing is cancelled' {
        $script:validationEnabled = $true
        Mock Invoke-SetupEnvironmentConfigurationWizard { $null }
        $result = & $Wizard @script:wizardParameters
        $result.BranchStates[0].BuildValidationEnabled | Should -BeFalse
        $result.BranchStates[0].BuildValidationEnvironmentConfiguration | Should -BeNullOrEmpty
    }

    It 'selects a solution source when multiple branches have DEV environments' {
        $script:mappings += [pscustomobject]@{ BranchName = 'release'; DevEnvironmentConfiguration = $script:dev; ExistingDevEnvironment = $script:dev; Environments = @() }
        Mock Select-FromMenu { 1 }
        $result = & $Wizard @script:wizardParameters
        $result.BranchStates.Count | Should -Be 2
        $result.SolutionSourceBranch | Should -Be release
    }

    It 'keeps per-branch environment settings inside the branch and environment step' {
        $null = & $Wizard @script:wizardParameters

        $script:setupWizardSteps | Should -Contain 'Configure branches, dev and deployment envs'
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
            $ast = Get-SetupProviderAst -RepositoryRoot $repositoryRoot -EntryPoint $scriptName
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