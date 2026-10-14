BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repoRoot 'setup-common.ps1')
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
        foreach ($definition in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
            Set-Item -Path "Function:$($definition.Name)" -Value $definition.Body.GetScriptBlock()
        }
    }

    BeforeEach {
        $script:credential = [pscustomobject]@{ ApplicationId = 'app'; TenantId = 'example.com'; AuthType = 'WIF' }
        $script:dev = [pscustomobject]@{ ShortName = 'Dev-main'; FriendlyName = 'Development'; Url = 'https://dev.example.com'; Credentials = $script:credential; ServiceAccountUPN = 'service@example.com' }
        $script:target = [pscustomobject]@{ ShortName = 'TEST'; FriendlyName = 'Test'; Url = 'https://test.example.com'; Credentials = $script:credential; ServiceAccountUPN = 'service@example.com' }
        $script:mappings = @([pscustomobject]@{ BranchName = 'main'; DevEnvironmentConfiguration = $script:dev; ExistingDevEnvironment = $script:dev; Environments = @($script:target) })
        $script:existingState = [pscustomobject]@{
            DevEnvironment = $script:dev
            DeploymentEnvironments = @($script:target)
            DeploymentBranchMappings = @([pscustomobject]@{ BranchName = 'main'; Environments = @($script:target) })
            BranchStates = @([pscustomobject]@{ BranchName = 'main'; ExistingDevEnvironment = $script:dev; DeploymentEnvironments = @($script:target) })
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
        Mock Invoke-WithErrorHandling { & $ScriptBlock }
        Mock Invoke-WithSpectreStatus { & $ScriptBlock }
        Mock Select-BranchEnvironmentMapping { $script:mappings }
        Mock Read-YesNo { $script:validationEnabled }
        Mock Read-TextWithDefault { $DefaultValue }
        Mock Select-FromMenu { 0 }
        Mock Select-BuildValidationBaselineEnvironment { '@TEST' }
        Mock Select-DataverseEnvironment { [pscustomobject]@{ FriendlyName = 'Validation'; Endpoints = @{ WebApplication = 'https://build.example.com/' } } }
        Mock Get-BranchTargetedRepoChangePublishPlan { [pscustomobject]@{ Mode = 'Direct'; BranchName = $TargetBranch; TargetBranch = $TargetBranch } }
        Mock Get-DataverseSolutionsSelection { [pscustomobject]@{ Solutions = @([pscustomobject]@{ name = 'Example' }) } }
        $workingRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $workingRoot | Out-Null
        if ($Provider -eq 'GitHub') {
            Mock Get-GitHubExistingEnvironmentState { $script:dev }
            Mock Get-GitHubEnvironmentConfiguration { [pscustomobject]@{ ShortName = $EnvironmentName; FriendlyName = $FriendlyName; Url = $EnvironmentUrl; Credentials = $script:credential; ServiceAccountUPN = 'service@example.com' } }
            Mock Publish-GitHubBranchSetupChange { [pscustomobject]@{ BranchName = $ConfiguredBranch; TargetBranch = $ConfiguredBranch; PullRequestUrl = $null; Mode = 'Direct'; HasChanges = $true } }
            $script:wizardParameters = @{ CloneRoot = $workingRoot; RepoOwner = 'owner'; RepoName = 'repo'; RepoFullName = 'owner/repo'; DefaultBranch = 'main'; TenantId = 'example.com'; ExistingSetupState = $script:existingState; SharedWorkflowRepository = 'owner/shared'; SharedWorkflowReference = 'stable'; UpstreamGitSource = $repoRoot; ALM4DataverseRef = 'stable'; UseGitHubEnvironments = $true; DeploymentPromotionMode = 'manual-gate-tag' }
        }
        else {
            Mock Get-AzDoRepositoryExistingSetupState { $script:existingState }
            Mock Get-AzDoEnvironmentConfiguration { [pscustomobject]@{ ShortName = $EnvironmentName; FriendlyName = $FriendlyName; Url = $EnvironmentUrl; Credentials = $script:credential; ServiceAccountUPN = 'service@example.com' } }
            Mock Get-GitRepoFileContentFromRemoteBranch { '@{ solutions = @() }' }
            $script:wizardParameters = @{ MainRepoWorkingRoot = $workingRoot; MainRepo = [pscustomobject]@{ Name = 'repo' }; SelectedProject = [pscustomobject]@{ Name = 'project' }; OrganizationName = 'org'; TenantId = 'example.com'; DefaultBranch = 'main'; SharedRepositoryName = 'shared'; UseAlm4DataverseExtension = $true; ALM4DataverseRef = 'stable' }
        }
    }

    It 'retains configured branches and uses their DEV environment for solutions' {
        $result = & $Wizard @script:wizardParameters
        $result.BranchStates.Count | Should -Be 1
        $result.BranchStates[0].DevEnvironmentConfiguration.Url | Should -Be $script:dev.Url
        $result.SolutionSourceBranch | Should -Be main
        $result.BuildValidationEnabled | Should -BeFalse
        Should -Invoke Get-DataverseSolutionsSelection -Times 1 -Exactly -ParameterFilter { $ExistingEnvironmentUrl -eq 'https://dev.example.com' }
        Should -Invoke Confirm-SetupReviewAction -Times 1 -Exactly
    }

    It 'configures a shared BUILD environment and a separate baseline' {
        $script:validationEnabled = $true
        $result = & $Wizard @script:wizardParameters
        $result.BuildValidationEnabled | Should -BeTrue
        $result.BuildValidationEnvironmentConfiguration.ShortName | Should -Be Build
        $result.BuildValidationBaselineRelease | Should -Be '@TEST'
        Should -Invoke Select-BuildValidationBaselineEnvironment -Times 1 -Exactly -ParameterFilter { $ExcludedEnvironmentUrl -eq 'https://build.example.com' }
    }

    It 'rejects duplicate deployment targets before review or publishing' {
        $script:mappings += [pscustomobject]@{ BranchName = 'release'; DevEnvironmentConfiguration = $null; ExistingDevEnvironment = $null; Environments = @($script:target) }
        { & $Wizard @script:wizardParameters } | Should -Throw '*only be assigned to one branch*'
        Should -Invoke Confirm-SetupReviewAction -Times 0 -Exactly
        if ($Provider -eq 'GitHub') { Should -Invoke Publish-GitHubBranchSetupChange -Times 0 -Exactly }
    }

    It 'rejects configured branches without any environment' {
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
            foreach ($mapping in $script:mappings) {
                $mapping.DevEnvironmentConfiguration = & $EditDevEnvironmentScriptBlock @($script:mappings) $mapping
                $mapping.Environments = @(& $EditDeploymentEnvironmentsScriptBlock @($script:mappings) $mapping)
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

    It 'executes standalone environment-step contracts before branch editing' {
        Mock Invoke-SetupWizard {
            foreach ($step in @($Steps | Select-Object -Skip 1)) { & $step.Action }
            throw 'Environment step contracts completed.'
        }
        Mock Read-YesNo { $true }
        if ($Provider -eq 'GitHub') {
            Mock Read-TextWithDefault { if ([string]::IsNullOrWhiteSpace($DefaultValue)) { 'TEST' } else { $DefaultValue } }
            Mock Select-ConfiguredDeploymentEnvironment {
                $added = & $AddEnvironmentScriptBlock @()
                & $EditEnvironmentScriptBlock @($added) $added 0
            }
        }
        else {
            Mock Get-DataverseEnvironmentsSelection { $script:target }
        }
        { & $Wizard @script:wizardParameters } | Should -Throw '*Environment step contracts completed*'
        Should -Invoke Get-DataverseSolutionsSelection -Times 1 -Exactly
        Should -Invoke Select-BuildValidationBaselineEnvironment -Times 1 -Exactly
        Should -Invoke Confirm-SetupReviewAction -Times 1 -Exactly
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