function Invoke-AzDoBranchAwareSetup {
    <#
    .SYNOPSIS
    Runs guided branch configuration with an optional preview and repository publication.
    .PARAMETER PostApplyAction
    Runs provider-specific pipeline and environment setup after repository publication.
    Failures return to the guided menu with selections retained.
    .PARAMETER PrerequisiteSteps
    Initial guided steps displayed before branch configuration, including shared-repository
    selection and version reconciliation. Authentication and project/application-repository
    selection are completed before the menu and are not listed as rows.
    .PARAMETER SharedRepositoryState
    Mutable shared-repository name, ref, and template root used by preview and apply.
    .NOTES
    Returns BranchStates, SolutionData, SolutionSourceBranch, per-branch BUILD settings
    and publication results. Credential selection can provision Entra resources before
    preview. Requires authenticated setup context and shared UI helpers.
    Branch callbacks take allMappings then mappingToEdit positionally. Completed
    branch editing suppresses the separate DEV/deployment steps. Only DEV-configured
    branches can supply solution discovery; otherwise SolutionData stays null so
    publication preserves existing solution lists. Preview is optional, available
    after all setup steps are complete, and does not gate Apply. ApplyConfig limits
    the menu to publication planning and preview, using committed config. Publication
    is not transactional.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'allMappings', Justification = 'Required first positional argument in the nested branch-editor callback contracts.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'MainRepoWorkingRoot', Justification = 'Captured by the nested wizard actions.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'MainRepo', Justification = 'Captured by the nested wizard actions.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'SelectedProject', Justification = 'Captured by the nested wizard actions.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'OrganizationName', Justification = 'Captured by the nested wizard actions.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'TenantId', Justification = 'Captured by the nested wizard actions.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'AccessToken', Justification = 'Captured by the nested final Apply action.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'PostApplyAction', Justification = 'Invoked by the nested final Apply action.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MainRepoWorkingRoot,
        [Parameter(Mandatory)][object]$MainRepo,
        [Parameter(Mandatory)][object]$SelectedProject,
        [Parameter(Mandatory)][string]$OrganizationName,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$DefaultBranch,
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][string]$CopyRoot,
        [Parameter(Mandatory)][string]$SharedRepositoryName,
        [Parameter(Mandatory)][string]$SharedRepositoryRef,
        [Parameter(Mandatory)][bool]$UseAlm4DataverseExtension,
        [Parameter(Mandatory)][string]$ALM4DataverseRef,
        [Parameter()][System.Collections.IDictionary]$ProviderOptions = @{},
        [Parameter()][array]$PrerequisiteSteps = @(),
        [Parameter()][scriptblock]$PostApplyAction,
        [Parameter()][switch]$ApplyConfig,
        [Parameter()][switch]$IsNewRepository,
        [Parameter()][switch]$PreviewOnly,
        [Parameter()][System.Collections.IDictionary]$SharedRepositoryState
    )

    if ($null -eq $SharedRepositoryState) {
        $SharedRepositoryState = [ordered]@{
            Name = $SharedRepositoryName
            Ref = $SharedRepositoryRef
            CopyRoot = $CopyRoot
        }
    }

    $credentialsCache = @()
    $serviceAccountsCache = @()

    $existingSetupState = Invoke-WithSpectreStatus -Status 'Inspecting existing Azure DevOps branch setup state...' -ScriptBlock {
        Get-AzDoRepositoryExistingSetupState `
            -RepoRoot $MainRepoWorkingRoot `
            -ProjectName $SelectedProject.Name `
            -DefaultBranch $DefaultBranch `
            -TenantId $TenantId `
            -SkipProviderState:$ApplyConfig
    }

    $initialBranchMappings = @(Get-AzDoInitialBranchMapping -ExistingSetupState $existingSetupState -DefaultBranch $DefaultBranch)
    $branchStates = @()
    foreach ($selectedBranchMapping in $initialBranchMappings) {
        $branchName = [string]$selectedBranchMapping.BranchName
        $existingBranchState = $existingSetupState.BranchStates | Where-Object { $_.BranchName -ieq $branchName } | Select-Object -First 1
        $existingDevEnvironment = Get-OptionalObjectPropertyValue -InputObject $selectedBranchMapping -PropertyName 'ExistingDevEnvironment'
        if ($null -eq $existingDevEnvironment) {
            $existingDevEnvironment = Get-OptionalObjectPropertyValue -InputObject $existingBranchState -PropertyName 'ExistingDevEnvironment'
        }
        $deploymentEnvironments = if ($existingBranchState) {
            @($existingBranchState.DeploymentEnvironments)
        }
        else {
            @($selectedBranchMapping.Environments)
        }

        $branchState = New-AzDoBranchSetupState `
            -BranchName $branchName `
            -ExistingDevEnvironment $existingDevEnvironment `
            -DeploymentEnvironments $deploymentEnvironments `
            -PublishPlan $null `
            -ExistingBuildValidationEnvironment (Get-OptionalObjectPropertyValue -InputObject $selectedBranchMapping -PropertyName 'ExistingBuildValidationEnvironment') `
            -BuildValidationEnvironmentName ([string](Get-OptionalObjectPropertyValue -InputObject $selectedBranchMapping -PropertyName 'BuildValidationEnvironmentName')) `
            -BuildValidationBaselineRelease ([string](Get-OptionalObjectPropertyValue -InputObject $selectedBranchMapping -PropertyName 'BuildValidationBaselineRelease'))
        if ($ApplyConfig) {
            $branchState.DevEnvironmentConfiguration = $existingDevEnvironment
        }
        $branchStates += $branchState
    }

    $wizardState = [pscustomobject]@{
        BranchStates         = @($branchStates)
        SolutionData         = $null
        SolutionSourceBranch = $null
        BuildValidationEnabled = [bool](Get-OptionalObjectPropertyValue -InputObject $existingSetupState -PropertyName 'BuildValidationEnabled')
        BuildValidationBaselineRelease = ''
        BuildValidationEnvironmentConfiguration = (Get-OptionalObjectPropertyValue -InputObject $existingSetupState -PropertyName 'ExistingBuildValidationEnvironment')
    }

    $ProviderOptions['azDOUseAlm4DataverseExtension'] = $UseAlm4DataverseExtension
    $branchSetupSteps = @(
        [pscustomobject]@{
            Name = 'Configure branches, dev and deployment envs'
            HelpDocRelativePath = 'docs/setup/azdo-automated-setup.md'
            SubItems = {
                Get-SetupBranchMenuItem -BranchStates @($wizardState.BranchStates)
            }
            Action = {
                param($menuTarget)
                $initialEditTarget = $menuTarget

                $existingEnvironmentConfigurations = @($existingSetupState.BranchStates | ForEach-Object { @($_.DeploymentEnvironments) } | Where-Object { $null -ne $_ })
                $currentBranchMappings = @($wizardState.BranchStates | ForEach-Object {
                    [pscustomobject]@{
                        BranchName                  = [string]$_.BranchName
                        DevEnvironmentConfiguration = $_.DevEnvironmentConfiguration
                        ExistingDevEnvironment      = $_.ExistingDevEnvironment
                        Environments                = @($_.DeploymentEnvironments)
                        BuildValidationEnabled = [bool]$_.BuildValidationEnabled
                        BuildValidationEnvironmentName = [string]$_.BuildValidationEnvironmentName
                        BuildValidationBaselineRelease = [string]$_.BuildValidationBaselineRelease
                        BuildValidationEnvironmentConfiguration = $_.BuildValidationEnvironmentConfiguration
                        ExistingBuildValidationEnvironment = $_.ExistingBuildValidationEnvironment
                    }
                })

                $selectedBranchMappings = @(Select-BranchEnvironmentMapping `
                    -EnvironmentConfigurations $existingEnvironmentConfigurations `
                    -InitialBranchMappings $currentBranchMappings `
                    -Title 'Manage deployment branches' `
                    -DocRelativePath 'docs/setup/azdo-automated-setup.md' `
                    -Ref $ALM4DataverseRef `
                    -InitialEditTarget $initialEditTarget `
                    -IsNewRepository:$IsNewRepository `
                    -EditDevEnvironmentScriptBlock {
                        param($allMappings, $mappingToEdit, $environmentNameToEdit)

                        Write-Section `
                            -Message "DEV environment for branch '$($mappingToEdit.BranchName)'"
                        $existingDevEnvironment = $mappingToEdit.ExistingDevEnvironment
                        $currentDevConfiguration = $mappingToEdit.DevEnvironmentConfiguration
                        $initialConfiguration = if ($currentDevConfiguration) { $currentDevConfiguration } else { $existingDevEnvironment }

                        if ($initialConfiguration) {
                            $existingDevEnvironmentUrl = [string](Get-OptionalObjectPropertyValue -InputObject $initialConfiguration -PropertyName 'Url')
                            $existingDevEnvironmentFriendlyName = [string](Get-OptionalObjectPropertyValue -InputObject $initialConfiguration -PropertyName 'FriendlyName')
                            if (-not [string]::IsNullOrWhiteSpace($existingDevEnvironmentUrl)) {
                                Write-Host "Existing DEV environment: $existingDevEnvironmentFriendlyName ($existingDevEnvironmentUrl)" -ForegroundColor DarkGray
                            }
                        }

                        if ([string]::IsNullOrWhiteSpace($environmentNameToEdit)) {
                            $configureDevEnvironment = Read-YesNo -Prompt "Configure a DEV environment for branch '$($mappingToEdit.BranchName)'?"
                            if (-not $configureDevEnvironment) {
                                return $null
                            }
                        }

                        $updatedDevConfiguration = Invoke-WithErrorHandling -OperationName "Configuring DEV environment for branch '$($mappingToEdit.BranchName)'" -ScriptBlock {
                            Invoke-AzDoEnvironmentConfigurationWizard `
                                -Title "Configure DEV environment for branch '$($mappingToEdit.BranchName)'" `
                                -DataverseEnvironmentPrompt "Select the DEV environment for branch '$($mappingToEdit.BranchName)'" `
                                -InitialConfiguration $initialConfiguration `
                                -InitialTargetName "Dev-$($mappingToEdit.BranchName)" `
                                -TargetNameStepName 'Target name' `
                                -TargetNameIsFixed `
                                -ExistingCredentials $credentialsCache `
                                -ExistingServiceAccounts $serviceAccountsCache `
                                -TenantId $TenantId `
                                -ProjectName $SelectedProject.Name `
                                -UseAlm4DataverseExtension $UseAlm4DataverseExtension `
                                -IsDevelopmentEnvironment $true `
                                -PromptGuidanceLines @(
                                    'Choose the branch-specific Dataverse environment used for development and solution discovery.',
                                    'Credentials and service-account ownership are configured in separate steps.'
                                ) `
                                -PromptGuidanceDocRelativePath 'docs/setup/azdo-automated-setup.md' `
                                -PromptGuidanceRef $ALM4DataverseRef `
                                -HelpDocRelativePath 'docs/setup/azdo-automated-setup.md' `
                                -HelpRef $ALM4DataverseRef
                        }

                        if ($null -eq $updatedDevConfiguration) {
                            return $mappingToEdit.DevEnvironmentConfiguration
                        }
                        if ($updatedDevConfiguration.Credentials -and -not ($credentialsCache | Where-Object { $_.ApplicationId -eq $updatedDevConfiguration.Credentials.ApplicationId -and $_.TenantId -eq $updatedDevConfiguration.Credentials.TenantId })) {
                            $credentialsCache += $updatedDevConfiguration.Credentials
                        }
                        if (-not [string]::IsNullOrWhiteSpace($updatedDevConfiguration.ServiceAccountUPN) -and $serviceAccountsCache -notcontains $updatedDevConfiguration.ServiceAccountUPN) {
                            $serviceAccountsCache += $updatedDevConfiguration.ServiceAccountUPN
                        }

                        return $updatedDevConfiguration
                    } `
                    -EditDeploymentEnvironmentsScriptBlock {
                        param($allMappings, $mappingToEdit, $environmentNameToEdit)
                        $initialEditEnvironmentName = $environmentNameToEdit

                        Write-Section `
                            -Message "Deployment environments for branch '$($mappingToEdit.BranchName)'"

                        $excludedUrl = $null
                        if ($mappingToEdit.DevEnvironmentConfiguration) {
                            $excludedUrl = $mappingToEdit.DevEnvironmentConfiguration.Url
                        }
                        elseif ($mappingToEdit.ExistingDevEnvironment) {
                            $excludedUrl = [string](Get-OptionalObjectPropertyValue -InputObject $mappingToEdit.ExistingDevEnvironment -PropertyName 'Url')
                        }

                        $updatedDeploymentEnvironments = @(Invoke-WithErrorHandling -OperationName "Selecting deployment environments for branch '$($mappingToEdit.BranchName)'" -ScriptBlock {
                            Get-DataverseEnvironmentsSelection `
                                -ExcludedUrl $excludedUrl `
                                -Branch $mappingToEdit.BranchName `
                                -ProjectName $SelectedProject.Name `
                                -InitialEnvironments @($mappingToEdit.Environments) `
                                -InitialEditEnvironmentName $initialEditEnvironmentName `
                                -ExistingCredentials $credentialsCache `
                                -ExistingServiceAccounts $serviceAccountsCache `
                                -TenantId $TenantId `
                                -UseAlm4DataverseExtension $UseAlm4DataverseExtension
                        })

                        foreach ($deploymentEnvironment in @($updatedDeploymentEnvironments)) {
                            if ($deploymentEnvironment.Credentials -and -not ($credentialsCache | Where-Object { $_.ApplicationId -eq $deploymentEnvironment.Credentials.ApplicationId -and $_.TenantId -eq $deploymentEnvironment.Credentials.TenantId })) {
                                $credentialsCache += $deploymentEnvironment.Credentials
                            }
                            if (-not [string]::IsNullOrWhiteSpace($deploymentEnvironment.ServiceAccountUPN) -and $serviceAccountsCache -notcontains $deploymentEnvironment.ServiceAccountUPN) {
                                $serviceAccountsCache += $deploymentEnvironment.ServiceAccountUPN
                            }
                        }

                        return @($updatedDeploymentEnvironments)
                    } `
                    -EditBuildValidationScriptBlock {
                        param($allMappings, $mappingToEdit, $environmentNameToEdit)

                        $branchName = [string]$mappingToEdit.BranchName
                        Write-Section -Message "BUILD validation for branch '$branchName'"
                        $buildValidationGuidanceLines = @(
                            'BUILD validation is configured independently for each branch.',
                            'A branch can deploy its generated artifacts to a validation environment and optionally use a separate deployment environment as its baseline source.'
                        )

                        $existingBuildValidationEnvironment = if ($mappingToEdit.BuildValidationEnvironmentConfiguration) {
                            $mappingToEdit.BuildValidationEnvironmentConfiguration
                        }
                        else {
                            $mappingToEdit.ExistingBuildValidationEnvironment
                        }
                        $existingBuildValidationEnvironmentName = [string](Get-OptionalObjectPropertyValue -InputObject $existingBuildValidationEnvironment -PropertyName 'ShortName')
                        if ([string]::IsNullOrWhiteSpace($existingBuildValidationEnvironmentName)) {
                            $existingBuildValidationEnvironmentName = [string]$mappingToEdit.BuildValidationEnvironmentName
                        }

                        if ([string]::IsNullOrWhiteSpace($environmentNameToEdit)) {
                            $enableBuildValidation = if ([bool]$mappingToEdit.BuildValidationEnabled) {
                                Read-YesNo `
                                    -Prompt "Enable Dataverse deployment validation during BUILD for branch '$branchName'?" `
                                    -PromptGuidanceLines $buildValidationGuidanceLines `
                                    -PromptGuidanceDocRelativePath 'docs/usage/building-releases.md' `
                                    -PromptGuidanceRef $ALM4DataverseRef
                            }
                            else {
                                Read-YesNo `
                                    -Prompt "Enable Dataverse deployment validation during BUILD for branch '$branchName'?" `
                                    -PromptGuidanceLines $buildValidationGuidanceLines `
                                    -PromptGuidanceDocRelativePath 'docs/usage/building-releases.md' `
                                    -PromptGuidanceRef $ALM4DataverseRef `
                                    -DefaultNo
                            }
                            if (-not $enableBuildValidation) {
                                return [pscustomobject]@{
                                    BuildValidationEnabled = $false
                                    BuildValidationEnvironmentName = ''
                                    BuildValidationBaselineRelease = ''
                                    BuildValidationEnvironmentConfiguration = $null
                                    ExistingBuildValidationEnvironment = $mappingToEdit.ExistingBuildValidationEnvironment
                                }
                            }
                        }

                        $selectTargetName = {
                            param($environmentState)
                            $environmentName = Read-TextWithDefault `
                                -Prompt "Enter the Azure DevOps service connection name for BUILD validation on branch '$branchName'" `
                                -DefaultValue $environmentState.ShortName `
                                -PromptGuidanceLines @(
                                    'This service connection supplies credentials for BUILD-time deployment validation.',
                                    'Use a stable name; the suggested default is branch-specific.'
                                ) `
                                -PromptGuidanceDocRelativePath 'docs/config/azdo-environment-service-connection.md' `
                                -PromptGuidanceRef $ALM4DataverseRef
                            if ([string]::IsNullOrWhiteSpace($environmentName)) {
                                [Spectre.Console.AnsiConsole]::MarkupLine('[red]A service connection name is required for BUILD validation.[/]')
                                Request-SetupWizardBack
                            }
                            return $environmentName.Trim()
                        }.GetNewClosure()
                        $selectBaseline = {
                            param($environmentState)
                            $baselineEnvironments = @($allMappings | ForEach-Object { @($_.Environments) })
                            Select-BuildValidationBaselineEnvironment `
                                -DeploymentEnvironments $baselineEnvironments `
                                -ExcludedEnvironmentName ([string]$environmentState.ShortName) `
                                -ExcludedEnvironmentUrl ([string]$environmentState.Url)
                        }.GetNewClosure()
                        $buildValidationConfiguration = Invoke-WithErrorHandling -OperationName "Configuring BUILD validation for branch '$branchName'" -ScriptBlock {
                            Invoke-AzDoEnvironmentConfigurationWizard `
                                -Title "Configure BUILD validation for branch '$branchName'" `
                                -DataverseEnvironmentPrompt "Select the Dataverse environment for BUILD validation on branch '$branchName'" `
                                -InitialConfiguration $existingBuildValidationEnvironment `
                                -InitialTargetName $(if ([string]::IsNullOrWhiteSpace($existingBuildValidationEnvironmentName)) { "Build-$branchName" } else { $existingBuildValidationEnvironmentName }) `
                                -TargetNameStepName 'Service connection name' `
                                -SelectTargetNameAction $selectTargetName `
                                -SelectBaselineAction $selectBaseline `
                                -InitialBaselineRelease ([string]$mappingToEdit.BuildValidationBaselineRelease) `
                                -BaselineConfigured:([bool]$mappingToEdit.BuildValidationEnabled) `
                                -ExistingCredentials $credentialsCache `
                                -ExistingServiceAccounts $serviceAccountsCache `
                                -TenantId $TenantId `
                                -ProjectName $SelectedProject.Name `
                                -UseAlm4DataverseExtension $UseAlm4DataverseExtension `
                                -IsDevelopmentEnvironment $false `
                                -IsBuildValidationEnvironment $true `
                                -PromptGuidanceLines @(
                                    'Choose the Dataverse environment that BUILD should validate deployments against.',
                                    'A separate deployment environment can be selected as the baseline source.'
                                ) `
                                -PromptGuidanceDocRelativePath 'docs/usage/building-releases.md' `
                                -PromptGuidanceRef $ALM4DataverseRef `
                                -HelpDocRelativePath 'docs/setup/azdo-automated-setup.md' `
                                -HelpRef $ALM4DataverseRef
                        }
                        if ($null -eq $buildValidationConfiguration) {
                            if ([bool]$mappingToEdit.BuildValidationEnabled) {
                                return [pscustomobject]@{
                                    BuildValidationEnabled = $true
                                    BuildValidationEnvironmentName = [string]$mappingToEdit.BuildValidationEnvironmentName
                                    BuildValidationBaselineRelease = [string]$mappingToEdit.BuildValidationBaselineRelease
                                    BuildValidationEnvironmentConfiguration = $mappingToEdit.BuildValidationEnvironmentConfiguration
                                    ExistingBuildValidationEnvironment = $mappingToEdit.ExistingBuildValidationEnvironment
                                }
                            }
                            return [pscustomobject]@{
                                BuildValidationEnabled = $false
                                BuildValidationEnvironmentName = ''
                                BuildValidationBaselineRelease = ''
                                BuildValidationEnvironmentConfiguration = $null
                                ExistingBuildValidationEnvironment = $mappingToEdit.ExistingBuildValidationEnvironment
                            }
                        }

                        if ($buildValidationConfiguration.Credentials -and -not ($credentialsCache | Where-Object { $_.ApplicationId -eq $buildValidationConfiguration.Credentials.ApplicationId -and $_.TenantId -eq $buildValidationConfiguration.Credentials.TenantId })) {
                            $credentialsCache += $buildValidationConfiguration.Credentials
                        }
                        if (-not [string]::IsNullOrWhiteSpace($buildValidationConfiguration.ServiceAccountUPN) -and $serviceAccountsCache -notcontains $buildValidationConfiguration.ServiceAccountUPN) {
                            $serviceAccountsCache += $buildValidationConfiguration.ServiceAccountUPN
                        }

                        return [pscustomobject]@{
                            BuildValidationEnabled = $true
                            BuildValidationEnvironmentName = [string]$buildValidationConfiguration.ShortName
                            BuildValidationBaselineRelease = [string]$buildValidationConfiguration.BaselineRelease
                            BuildValidationEnvironmentConfiguration = $buildValidationConfiguration
                            ExistingBuildValidationEnvironment = $mappingToEdit.ExistingBuildValidationEnvironment
                        }
                    })

                if ($selectedBranchMappings.Count -eq 0) {
                    throw 'At least one branch must be configured for Azure DevOps setup.'
                }

                $existingStateByBranch = @{}
                foreach ($branchState in @($wizardState.BranchStates)) {
                    $existingStateByBranch[$branchState.BranchName.ToLowerInvariant()] = $branchState
                }

                $updatedBranchStates = @()
                foreach ($selectedBranchMapping in $selectedBranchMappings) {
                    $branchName = [string]$selectedBranchMapping.BranchName
                    $branchKey = $branchName.ToLowerInvariant()

                    $existingBranchState = $null
                    if ($existingStateByBranch.ContainsKey($branchKey)) {
                        $existingBranchState = $existingStateByBranch[$branchKey]
                        $existingBranchState.DevEnvironmentConfiguration = $selectedBranchMapping.DevEnvironmentConfiguration
                        $existingBranchState.DeploymentEnvironments = @($selectedBranchMapping.Environments)
                    }
                    if (-not $existingBranchState) {
                        $existingBranchState = $existingSetupState.BranchStates | Where-Object { $_.BranchName -ieq $branchName } | Select-Object -First 1
                    }

                    $publishPlan = Get-BranchTargetedRepoChangePublishPlan `
                        -ProviderName 'Azure DevOps' `
                        -RepositoryName $MainRepo.Name `
                        -TargetBranch $branchName `
                        -DefaultCommitMessage "Add ALM4Dataverse Azure DevOps pipelines for branch '$branchName'" `
                        -DefaultPullRequestTitle "Add ALM4Dataverse Azure DevOps pipelines for branch '$branchName'" `
                        -DefaultPullRequestDescription "This pull request adds or updates the ALM4Dataverse Azure DevOps pipeline YAML and repository configuration generated by setup-azdo.ps1 for branch '$branchName'." `
                        -GuidanceLines @(
                            'If branch protection or approvals apply, choose the pull-request path so the generated YAML and config changes can be reviewed before they land.',
                            'If you commit directly, the target branch is updated immediately and the matching pipeline definitions can start using that branch as soon as the push completes.'
                        ) `
                        -DocRelativePath 'docs/setup/azdo-automated-setup.md' `
                        -Ref $ALM4DataverseRef

                    $updatedBranchStates += New-AzDoBranchSetupState `
                        -BranchName $branchName `
                        -ExistingDevEnvironment $(if ($existingBranchState) { $existingBranchState.ExistingDevEnvironment } else { $null }) `
                        -DeploymentEnvironments @($(if ($existingBranchState) { $existingBranchState.DeploymentEnvironments } else { @() })) `
                        -PublishPlan $publishPlan `
                        -ExistingBuildValidationEnvironment $selectedBranchMapping.ExistingBuildValidationEnvironment `
                        -BuildValidationEnvironmentName ([string]$selectedBranchMapping.BuildValidationEnvironmentName) `
                        -BuildValidationBaselineRelease ([string]$selectedBranchMapping.BuildValidationBaselineRelease)
                    $updatedBranchStates[-1].BuildValidationEnabled = [bool]$selectedBranchMapping.BuildValidationEnabled
                    $updatedBranchStates[-1].BuildValidationEnvironmentConfiguration = $selectedBranchMapping.BuildValidationEnvironmentConfiguration
                }

                $wizardState.BranchStates = @($updatedBranchStates | Sort-Object BranchName)

                $branchMappingsForValidation = @($selectedBranchMappings | ForEach-Object {
                    [pscustomobject]@{
                        BranchName   = [string]$_.BranchName
                        Environments = @($_.Environments)
                    }
                })
                if (Test-BranchEnvironmentMappingDuplicate -BranchMappings $branchMappingsForValidation) {
                    throw 'Each deployment environment can only be assigned to one branch. Resolve duplicate environment assignments before continuing.'
                }

                $wizardState.BranchStates = @($selectedBranchMappings | ForEach-Object {
                    $mappedBranch = $_
                    $existingBranchState = $updatedBranchStates | Where-Object { $_.BranchName -ieq $mappedBranch.BranchName } | Select-Object -First 1
                    if (-not $existingBranchState) {
                        $existingBranchState = New-AzDoBranchSetupState -BranchName ([string]$mappedBranch.BranchName) -ExistingDevEnvironment $null -DeploymentEnvironments @() -PublishPlan $null
                    }

                    $existingBranchState.DevEnvironmentConfiguration = $mappedBranch.DevEnvironmentConfiguration
                    $existingBranchState.DeploymentEnvironments = @($mappedBranch.Environments)
                    $existingBranchState.ExistingBuildValidationEnvironment = $mappedBranch.ExistingBuildValidationEnvironment
                    $existingBranchState.BuildValidationEnabled = [bool]$mappedBranch.BuildValidationEnabled
                    $existingBranchState.BuildValidationEnvironmentName = [string]$mappedBranch.BuildValidationEnvironmentName
                    $existingBranchState.BuildValidationBaselineRelease = [string]$mappedBranch.BuildValidationBaselineRelease
                    $existingBranchState.BuildValidationEnvironmentConfiguration = $mappedBranch.BuildValidationEnvironmentConfiguration
                    $existingBranchState
                })

                $enabledBuildBranches = @($wizardState.BranchStates | Where-Object { $_.BuildValidationEnabled })
                $wizardState.BuildValidationEnabled = ($enabledBuildBranches.Count -gt 0)
                $wizardState.BuildValidationEnvironmentConfiguration = if ($enabledBuildBranches.Count -eq 1) { $enabledBuildBranches[0].BuildValidationEnvironmentConfiguration } else { $null }
                $wizardState.BuildValidationBaselineRelease = if ($enabledBuildBranches.Count -eq 1) { [string]$enabledBuildBranches[0].BuildValidationBaselineRelease } else { '' }
            }
        },
        [pscustomobject]@{
            Name = 'Select solutions'
            HelpDocRelativePath = 'docs/config/alm-config.md'
            Summary = {
                Get-SetupSolutionMenuSummary `
                    -SolutionData $wizardState.SolutionData `
                    -SourceBranch $wizardState.SolutionSourceBranch
            }
            Action = {
                Write-Section `
                    -Message 'Select solutions from a configured DEV branch'
                $solutionCandidateBranches = @($wizardState.BranchStates | Where-Object { $_.DevEnvironmentConfiguration })
                if ($solutionCandidateBranches.Count -eq 0) {
                    [Spectre.Console.AnsiConsole]::MarkupLine('[yellow]No branch has a DEV environment configured, so solution selection will be skipped for now.[/]')
                    $wizardState.SolutionData = $null
                    $wizardState.SolutionSourceBranch = $null
                    return
                }

                $solutionSourceBranchState = $solutionCandidateBranches[0]
                if ($solutionCandidateBranches.Count -gt 1) {
                    $branchMenuItems = @($solutionCandidateBranches | ForEach-Object {
                        $envLabel = if ($_.DevEnvironmentConfiguration -and -not [string]::IsNullOrWhiteSpace($_.DevEnvironmentConfiguration.FriendlyName)) { $_.DevEnvironmentConfiguration.FriendlyName } else { $_.DevEnvironmentConfiguration.ShortName }
                        "$($_.BranchName) - $envLabel"
                    })
                    $selectedBranchIndex = Select-FromMenu -Title 'Select the branch whose DEV environment should be used for solution selection' -Items $branchMenuItems -PromptGuidanceLines @(
                        'Choose which branch should provide the DEV environment for solution discovery.',
                        'Use the branch that best represents the solution baseline you want in source control.'
                    ) -PromptGuidanceDocRelativePath 'docs/config/alm-config.md' -PromptGuidanceRef $ALM4DataverseRef
                    if ($null -eq $selectedBranchIndex) {
                        throw 'No branch selected for solution selection.'
                    }

                    $solutionSourceBranchState = $solutionCandidateBranches[$selectedBranchIndex]
                }

                $existingConfigTempPath = $null
                try {
                    $existingConfigContent = Get-GitRepoFileContentFromRemoteBranch -RepoRoot $MainRepoWorkingRoot -Branch $solutionSourceBranchState.BranchName -RelativePath 'alm-config.psd1'
                    if (-not [string]::IsNullOrWhiteSpace($existingConfigContent)) {
                        $existingConfigTempPath = Join-Path ([System.IO.Path]::GetTempPath()) ("alm-config-" + [guid]::NewGuid().ToString('n') + '.psd1')
                        Set-Content -LiteralPath $existingConfigTempPath -Value $existingConfigContent -NoNewline
                    }

                    $wizardState.SolutionData = Invoke-WithErrorHandling -OperationName 'Selecting Dataverse solutions' -ScriptBlock {
                        Get-DataverseSolutionsSelection -ExistingConfigPath $existingConfigTempPath -ExistingEnvironmentUrl $solutionSourceBranchState.DevEnvironmentConfiguration.Url
                    }
                }
                finally {
                    if ($existingConfigTempPath -and (Test-Path -LiteralPath $existingConfigTempPath)) {
                        Remove-Item -LiteralPath $existingConfigTempPath -Force -ErrorAction SilentlyContinue
                    }
                }

                $wizardState.SolutionSourceBranch = $solutionSourceBranchState.BranchName
            }
        },
        [pscustomobject]@{
            Name = 'Preview changes'
            HelpDocRelativePath = 'docs/setup/azdo-automated-setup.md'
            Action = {
                $artifactPreview = Get-AzDoSetupArtifactsPreview `
                    -RepoRoot $MainRepoWorkingRoot `
                    -CopyRoot $SharedRepositoryState.CopyRoot `
                    -MainRepo $MainRepo `
                    -SharedRepositoryName $SharedRepositoryState.Name `
                    -SharedRepositoryRef $SharedRepositoryState.Ref `
                    -UseAlm4DataverseExtension $UseAlm4DataverseExtension `
                    -BranchStates @($wizardState.BranchStates) `
                    -ProviderOptions $ProviderOptions `
                    -SolutionData $wizardState.SolutionData

                $resourceChanges = @()
                $resourceChangeNote = if ($ApplyConfig) {
                    'ApplyConfig only modifies repository files; it does not provision Azure DevOps, Entra ID, or Dataverse resources.'
                }
                else {
                    $resourceChanges = @(Get-AzDoSetupResourceChange `
                            -BranchStates @($wizardState.BranchStates) `
                            -SelectedProject $SelectedProject `
                            -MainRepo $MainRepo `
                            -SharedRepositoryName $SharedRepositoryState.Name)
                    'Only resource changes deferred until Apply are listed; prerequisites already created during setup are excluded.'
                }

                $summaryAction = {
                    Write-Section -Message 'Review Dataverse environment configuration'
                    $allConfiguredEnvironments = @()
                    foreach ($branchState in @($wizardState.BranchStates)) {
                        if ($branchState.DevEnvironmentConfiguration) {
                            $allConfiguredEnvironments += $branchState.DevEnvironmentConfiguration
                        }
                        $allConfiguredEnvironments += @($branchState.DeploymentEnvironments)
                        if ($branchState.BuildValidationEnabled -and $branchState.BuildValidationEnvironmentConfiguration) {
                            $allConfiguredEnvironments += $branchState.BuildValidationEnvironmentConfiguration
                        }
                    }

                    $buildValidationSummaries = @($wizardState.BranchStates | Where-Object { $_.BuildValidationEnabled } | ForEach-Object {
                        "$($_.BranchName): $($_.BuildValidationEnvironmentName)"
                    })
                    $buildBaselineSummaries = @($wizardState.BranchStates | Where-Object { $_.BuildValidationEnabled -and -not [string]::IsNullOrWhiteSpace([string]$_.BuildValidationBaselineRelease) } | ForEach-Object {
                        "$($_.BranchName): $($_.BuildValidationBaselineRelease)"
                    })
                    $fileChanges = @($artifactPreview.FileChanges)
                    Show-KeyValueSummaryTable -Heading 'Setup summary' -Values ([ordered]@{
                        'Setup type'                = $(if ($IsNewRepository) { 'Complete setup for a new repository' } else { 'Changes to existing repository setup' })
                        'Azure DevOps project'      = $SelectedProject.Name
                        'Main repository'           = $MainRepo.Name
                        'Shared repository'         = $SharedRepositoryState.Name
                        'Configured branches'       = [string]$wizardState.BranchStates.Count
                        'BUILD validation'          = $(if ($buildValidationSummaries.Count -gt 0) { $buildValidationSummaries -join '; ' } else { 'Disabled' })
                        'BUILD validation baseline' = $(if ($buildBaselineSummaries.Count -gt 0) { $buildBaselineSummaries -join '; ' } else { '<none>' })
                        'Solution source branch'    = $(if ([string]::IsNullOrWhiteSpace($wizardState.SolutionSourceBranch)) { '<none>' } else { $wizardState.SolutionSourceBranch })
                        'Solutions selected'        = [string]$(if ($wizardState.SolutionData) { @($wizardState.SolutionData.Solutions).Count } else { 0 })
                        'Extension mode'            = $(if ($UseAlm4DataverseExtension) { 'ALM4Dataverse extension enabled' } else { 'ALM4Dataverse extension disabled' })
                        'Files to add'              = [string]@($fileChanges | Where-Object { $_.Status -eq 'Added' }).Count
                        'Files to modify'           = [string]@($fileChanges | Where-Object { $_.Status -eq 'Modified' }).Count
                        'Files to delete'           = [string]@($fileChanges | Where-Object { $_.Status -eq 'Deleted' }).Count
                        'Deferred resource changes' = [string]$resourceChanges.Count
                    })

                    Show-BranchEnvironmentMappingTable -BranchMappings @($wizardState.BranchStates | ForEach-Object {
                        [pscustomobject]@{
                            BranchName   = $_.BranchName
                            Environments = @($_.DeploymentEnvironments)
                        }
                    })
                    foreach ($branchState in @($wizardState.BranchStates)) {
                        $publishSummary = if ($branchState.PublishPlan -and $branchState.PublishPlan.Mode -eq 'PullRequest') {
                            "Pull request into $($branchState.PublishPlan.TargetBranch) from $($branchState.PublishPlan.BranchName)"
                        }
                        elseif ($branchState.PublishPlan) {
                            "Direct commit to $($branchState.PublishPlan.BranchName)"
                        }
                        elseif ($PreviewOnly) {
                            '<not selected in preview-only mode>'
                        }
                        else {
                            '<not configured>'
                        }
                        Show-KeyValueSummaryTable -Heading "Branch '$($branchState.BranchName)'" -Values ([ordered]@{
                            'Publish mode'             = $publishSummary
                            'DEV environment'          = $(if ($branchState.DevEnvironmentConfiguration) { $branchState.DevEnvironmentConfiguration.ShortName } else { '<none>' })
                            'BUILD validation'         = $(if ($branchState.BuildValidationEnabled) { [string]$branchState.BuildValidationEnvironmentName } else { '<disabled>' })
                            'BUILD validation baseline' = $(if ([string]::IsNullOrWhiteSpace([string]$branchState.BuildValidationBaselineRelease)) { '<none>' } else { [string]$branchState.BuildValidationBaselineRelease })
                            'Deployment environments'  = [string]@($branchState.DeploymentEnvironments).Count
                        })
                    }
                    Show-EnvironmentConfigurationTable -EnvironmentConfigurations $allConfiguredEnvironments
                }
                Show-SetupChangeReview `
                    -FileChanges @($artifactPreview.FileChanges) `
                    -ResourceChanges $resourceChanges `
                    -ResourceChangeNote $resourceChangeNote `
                    -SummaryAction $summaryAction `
                    -PreviewOnly:$PreviewOnly
            }
        }
    )
    $previewStep = $branchSetupSteps | Where-Object { $_.Name -eq 'Preview changes' } | Select-Object -First 1
    if (-not $previewStep) {
        throw 'The setup change preview action is unavailable.'
    }
    $setupSteps = @($PrerequisiteSteps) + @($branchSetupSteps | Where-Object { $_.Name -ne 'Preview changes' })
    if ($ApplyConfig) {
        $publicationPlanStep = [pscustomobject]@{
            Name = 'Choose publication methods'
            HelpDocRelativePath = 'docs/setup/azdo-automated-setup.md'
            Summary = {
                Get-SetupPublishPlanMenuSummary -BranchStates @($wizardState.BranchStates)
            }
            Action = {
                foreach ($branchState in @($wizardState.BranchStates)) {
                    $branchName = [string]$branchState.BranchName
                    $branchState.PublishPlan = Get-BranchTargetedRepoChangePublishPlan `
                        -ProviderName 'Azure DevOps' `
                        -RepositoryName $MainRepo.Name `
                        -TargetBranch $branchName `
                        -DefaultCommitMessage "Apply alm-config.psd1 settings for branch '$branchName'" `
                        -DefaultPullRequestTitle "Apply alm-config.psd1 settings for branch '$branchName'" `
                        -DefaultPullRequestDescription "This pull request regenerates the Azure DevOps pipeline files from the committed alm-config.psd1 settings for branch '$branchName'." `
                        -GuidanceLines @(
                            "Choose how the generated pipeline files for branch '$branchName' should be published.",
                            'Use a pull request when branch protection or review is required.'
                        ) `
                        -DocRelativePath 'docs/setup/azdo-automated-setup.md' `
                        -Ref $ALM4DataverseRef
                }
            }
        }
        $setupSteps = @($PrerequisiteSteps) + @($publicationPlanStep)
    }

    if ($PreviewOnly) {
        & $previewStep.Action
        Write-Host 'Preview-only complete; no changes were published.' -ForegroundColor Cyan
        return [pscustomobject]@{
            BranchStates            = @($wizardState.BranchStates)
            SolutionData            = $wizardState.SolutionData
            SolutionSourceBranch   = $wizardState.SolutionSourceBranch
            BuildValidationEnabled = [bool](@($wizardState.BranchStates | Where-Object { $_.BuildValidationEnabled }).Count -gt 0)
            PublishResults          = @()
        }
    }

    $setupResult = Invoke-SetupWizard `
        -Title 'Azure DevOps ALM4Dataverse setup' `
        -Steps $setupSteps `
        -PreviewAction $previewStep.Action `
        -PreviewActionName $previewStep.Name `
        -HelpDocRelativePath 'docs/setup/azdo-automated-setup.md' `
        -HelpRef $ALM4DataverseRef `
        -ApplyAction {
        $applyResult = Invoke-AzDoBranchAwareSetupApply `
            -MainRepoWorkingRoot $MainRepoWorkingRoot `
            -MainRepo $MainRepo `
            -DefaultBranch $DefaultBranch `
            -AccessToken $AccessToken `
            -CopyRoot ([string]$SharedRepositoryState.CopyRoot) `
            -SharedRepositoryName ([string]$SharedRepositoryState.Name) `
            -SharedRepositoryRef ([string]$SharedRepositoryState.Ref) `
            -UseAlm4DataverseExtension $UseAlm4DataverseExtension `
            -WizardState $wizardState `
            -ProviderOptions $ProviderOptions
        if ($PostApplyAction) {
            & $PostApplyAction $applyResult
        }
        return $applyResult
    } -IsNewRepository:$IsNewRepository
    return $setupResult
}
