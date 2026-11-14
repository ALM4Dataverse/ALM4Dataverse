function Invoke-GitHubBranchAwareSetup {
    <#
    .SYNOPSIS
        Runs guided branch configuration with an optional preview and repository publication.
    .PARAMETER PostApplyAction
        Runs provider-specific settings after repository publication. Failures return
        to the guided menu so the user can retry with the current selections.
    .PARAMETER PrerequisiteSteps
        Initial guided steps displayed before branch configuration, including shared workflow
        repository selection and version reconciliation. Authentication and application-repository
        selection are completed before the menu and are not listed as rows.
    .PARAMETER SharedWorkflowRepositoryState
        Mutable shared workflow repository and ref used by preview and apply. When
        supplied, the repository and reference arguments may remain empty until the
        selection step completes. Without this state, both arguments must be nonempty.
    .DESCRIPTION
        ExistingSetupState seeds editable branch records; callbacks share wizardState
        so revisiting steps retains choices. Configuration and workflow previews use
        temporary copies. Preview is optional, available after all setup steps are
        complete, and does not gate Apply. Apply publishes configured branches, then
        runs the optional provider-setup callback before returning per-branch BUILD
        settings. In interactive setup, incomplete GitHub deployment environments keep
        the branch step incomplete until their required details are configured.
        ApplyConfig limits the menu to publication planning and preview, using committed
        config. Publication and provider configuration are not transactional.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'allMappings', Justification = 'Required first positional argument in the nested branch-editor callback contracts.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'CloneRoot', Justification = 'Captured by the nested wizard actions.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'UpstreamGitSource', Justification = 'Used by the nested template-fetch callback.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'UseGitHubEnvironments', Justification = 'Captured by the nested wizard actions.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'UseRepositoryVariablePrefix', Justification = 'Captured by the nested review action.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'EnableEnvironmentApprovals', Justification = 'Captured by the nested review action.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'RequiredReviewerIds', Justification = 'Captured by the nested review action.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'DeploymentPromotionMode', Justification = 'Captured by the nested wizard actions.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'RepoFullName', Justification = 'Captured by the nested branch publication and Apply actions.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'PostApplyAction', Justification = 'Invoked by the nested final Apply action.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CloneRoot,
        [Parameter(Mandatory)][string]$RepoOwner,
        [Parameter(Mandatory)][string]$RepoName,
        [Parameter(Mandatory)][string]$RepoFullName,
        [Parameter(Mandatory)][object]$RepoIdentity,
        [Parameter(Mandatory)][string]$DefaultBranch,
        [Parameter()][string]$TenantId,
        [Parameter(Mandatory)][object]$ExistingSetupState,
        [Parameter(Mandatory)][AllowEmptyString()][string]$SharedWorkflowRepository,
        [Parameter(Mandatory)][AllowEmptyString()][string]$SharedWorkflowReference,
        [Parameter(Mandatory)][string]$UpstreamGitSource,
        [Parameter(Mandatory)][string]$ALM4DataverseRef,
        [Parameter(Mandatory)][bool]$UseGitHubEnvironments,
        [Parameter(Mandatory)][string]$DeploymentPromotionMode,
        [Parameter()][System.Collections.IDictionary]$ProviderOptions = @{},
        [Parameter()][array]$PrerequisiteSteps = @(),
        [Parameter()][scriptblock]$PostApplyAction,
        [Parameter()][switch]$ApplyConfig,
        [Parameter()][switch]$IsNewRepository,
        [Parameter()][switch]$PreviewOnly,
        [Parameter()][bool]$UseRepositoryVariablePrefix = $true,
        [Parameter()][bool]$EnableEnvironmentApprovals = $false,
        [Parameter()][int[]]$RequiredReviewerIds = @(),
        [Parameter()][System.Collections.IDictionary]$SharedWorkflowRepositoryState
    )

    if ($null -eq $SharedWorkflowRepositoryState) {
        if (
            [string]::IsNullOrWhiteSpace($SharedWorkflowRepository) -or
            [string]::IsNullOrWhiteSpace($SharedWorkflowReference)
        ) {
            throw 'SharedWorkflowRepositoryState is required when the shared workflow repository or reference is empty.'
        }

        $SharedWorkflowRepositoryState = [ordered]@{
            Repository = $SharedWorkflowRepository
            Reference = $SharedWorkflowReference
        }
    }

    $cachedCredentials = @()
    $cachedServiceAccounts = @()
    $copyRoot = $null
    $upstreamClone = $null

    if (-not $ApplyConfig -and [string]::IsNullOrWhiteSpace($TenantId)) {
        throw 'TenantId is required when configuring GitHub provider resources.'
    }

    $initialBranchMappings = @(Get-GitHubInitialBranchMapping -ExistingSetupState $ExistingSetupState -DefaultBranch $DefaultBranch)
    $branchStates = @()
    foreach ($mapping in $initialBranchMappings) {
        $branchName = [string]$mapping.BranchName
        $existingDevEnvironment = Get-OptionalObjectPropertyValue -InputObject $mapping -PropertyName 'ExistingDevEnvironment'
        if ($null -eq $existingDevEnvironment -and -not $ApplyConfig) {
            $existingDevEnvironment = if ($branchName -ieq $DefaultBranch) {
                $ExistingSetupState.DevEnvironment
            }
            else {
                Get-GitHubExistingEnvironmentState -Owner $RepoOwner -Repo $RepoName -EnvironmentName "Dev-$branchName" -TenantId $TenantId
            }
        }

        $branchState = New-GitHubBranchSetupState `
            -BranchName $branchName `
            -ExistingDevEnvironment $existingDevEnvironment `
            -DeploymentEnvironments @($mapping.Environments) `
            -ExistingBuildValidationEnvironment (Get-OptionalObjectPropertyValue -InputObject $mapping -PropertyName 'ExistingBuildValidationEnvironment') `
            -BuildValidationEnvironmentName ([string](Get-OptionalObjectPropertyValue -InputObject $mapping -PropertyName 'BuildValidationEnvironmentName')) `
            -BuildValidationBaselineRelease ([string](Get-OptionalObjectPropertyValue -InputObject $mapping -PropertyName 'BuildValidationBaselineRelease'))
        if ($ApplyConfig) {
            $branchState.DevEnvironmentConfiguration = $existingDevEnvironment
        }
        $branchStates += $branchState
    }

    if ($script:SetupRepositoryRoot) {
        $copyRoot = Join-Path $script:SetupRepositoryRoot 'copy-to-your-repo'
    }

    if (-not $copyRoot -or -not (Test-Path -LiteralPath $copyRoot)) {
        $upstreamClone = Join-Path ([System.IO.Path]::GetTempPath()) ("ALM4Dataverse-Templates-" + [guid]::NewGuid().ToString('n'))
        New-DirectoryIfMissing -Path $upstreamClone

        Invoke-WithErrorHandling -OperationName 'Fetching workflow templates' -StatusMessage 'Fetching workflow templates from the selected ALM4Dataverse source...' -CaptureOutputInPanel -ScriptBlock {
            & git clone --depth 1 --branch $ALM4DataverseRef $UpstreamGitSource $upstreamClone 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw 'Failed to clone ALM4Dataverse templates.'
            }
        } | Out-Null

        $copyRoot = Join-Path $upstreamClone 'copy-to-your-repo'
    }

    try {
        # Keep editable choices separate from reconstructed remote state. One BUILD
        # validation environment is shared by every branch; DEV/deploy selections are not.
        $wizardState = [pscustomobject]@{
            BranchStates        = @($branchStates)
            SolutionResult      = $null
            SolutionSourceBranch = $null
            BuildValidationEnabled = [bool](Get-OptionalObjectPropertyValue -InputObject $ExistingSetupState -PropertyName 'BuildValidationEnabled')
            BuildValidationEnvironmentName = [string](Get-OptionalObjectPropertyValue -InputObject $ExistingSetupState -PropertyName 'BuildValidationEnvironmentName')
            BuildValidationBaselineRelease = ''
            BuildValidationEnvironmentConfiguration = (Get-OptionalObjectPropertyValue -InputObject $ExistingSetupState -PropertyName 'ExistingBuildValidationEnvironment')
            UseImmutableWifSubject = $(if ($ApplyConfig) { [bool]$ProviderOptions['GitHubUseImmutableWifSubject'] } else { [bool](Get-OptionalObjectPropertyValue -InputObject $RepoIdentity -PropertyName 'UseImmutableSubject') })
        }

        $branchSetupSteps = @(
            [pscustomobject]@{
                Name = 'Configure branches, dev and deployment envs'
                HelpDocRelativePath = 'docs/setup/github-setup.md'
                SubItems = {
                    Get-SetupBranchMenuItem -BranchStates @($wizardState.BranchStates)
                }
                Action = {
                    param($menuTarget)
                    $initialEditTarget = $menuTarget

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

                    $selectedBranchMappings = @(Invoke-WithErrorHandling -OperationName 'Selecting deployment branches' -ScriptBlock {
                        Select-BranchEnvironmentMapping `
                            -InitialBranchMappings $currentBranchMappings `
                            -Title 'Manage deployment branches' `
                            -DocRelativePath 'docs/setup/github-setup.md' `
                            -Ref $ALM4DataverseRef `
                            -InitialEditTarget $initialEditTarget `
                            -IsNewRepository:$IsNewRepository `
                            -EditDevEnvironmentScriptBlock {
                                param($allMappings, $mappingToEdit, $environmentNameToEdit)

                                $branchName = [string]$mappingToEdit.BranchName
                                $existingDevEnvironment = $mappingToEdit.ExistingDevEnvironment
                                $currentDevConfiguration = $mappingToEdit.DevEnvironmentConfiguration
                                $initialConfiguration = if ($currentDevConfiguration) { $currentDevConfiguration } else { $existingDevEnvironment }

                                if ($UseGitHubEnvironments) {
                                    Write-Host "Preparing GitHub environment 'Dev-$branchName' for the DEV Dataverse environment." -ForegroundColor Green
                                }
                                else {
                                    Write-Host "Preparing repo-level credentials for DEV environment 'Dev-$branchName'." -ForegroundColor Green
                                }
                                Write-Host ''

                                $existingDevEnvironmentSummary = if ($currentDevConfiguration) {
                                    Get-GitHubExistingEnvironmentSelectionSummary -ExistingEnvironment $currentDevConfiguration
                                }
                                else {
                                    Get-GitHubExistingEnvironmentSelectionSummary -ExistingEnvironment $existingDevEnvironment
                                }

                                $hasExistingDevConfiguration = ($currentDevConfiguration -or $existingDevEnvironment)
                                if ([string]::IsNullOrWhiteSpace($environmentNameToEdit)) {
                                    if ($hasExistingDevConfiguration) {
                                        $shouldConfigureDevEnvironment = Read-YesNo -Prompt "Configure a DEV Dataverse environment for branch '$branchName'?"
                                    }
                                    else {
                                        $shouldConfigureDevEnvironment = Read-YesNo -Prompt "Configure a DEV Dataverse environment for branch '$branchName'?" -DefaultNo
                                    }
                                    if (-not $shouldConfigureDevEnvironment) {
                                        return $null
                                    }
                                }

                                $updatedDevConfiguration = Invoke-GitHubEnvironmentConfigurationWizard `
                                    -Title "Configure DEV environment for branch '$branchName'" `
                                    -DataverseEnvironmentPrompt "Select the DEV Dataverse environment for branch '$branchName'" `
                                    -InitialConfiguration $initialConfiguration `
                                    -InitialTargetName "Dev-$branchName" `
                                    -TargetNameStepName 'Target name' `
                                    -TargetNameIsFixed `
                                    -PreferredSelectionSummary $existingDevEnvironmentSummary `
                                    -ExistingCredentials $cachedCredentials `
                                    -ExistingServiceAccounts $cachedServiceAccounts `
                                    -TenantId $TenantId `
                                    -RepoName $RepoName `
                                    -PromptGuidanceLines @(
                                        'Choose the branch-specific Dataverse environment used for development and solution discovery.',
                                        'Credentials and service-account ownership are configured in separate steps.'
                                    ) `
                                    -PromptGuidanceDocRelativePath 'docs/setup/github-setup.md' `
                                    -PromptGuidanceRef $ALM4DataverseRef `
                                    -HelpDocRelativePath 'docs/setup/github-setup.md' `
                                    -HelpRef $ALM4DataverseRef
                                if ($null -eq $updatedDevConfiguration) {
                                    return $currentDevConfiguration
                                }

                                if ($updatedDevConfiguration.Credentials -and -not ($cachedCredentials | Where-Object { $_.ApplicationId -eq $updatedDevConfiguration.Credentials.ApplicationId -and $_.TenantId -eq $updatedDevConfiguration.Credentials.TenantId })) {
                                    $cachedCredentials += $updatedDevConfiguration.Credentials
                                }
                                if (-not [string]::IsNullOrWhiteSpace($updatedDevConfiguration.ServiceAccountUPN) -and $cachedServiceAccounts -notcontains $updatedDevConfiguration.ServiceAccountUPN) {
                                    $cachedServiceAccounts += $updatedDevConfiguration.ServiceAccountUPN
                                }

                                return $updatedDevConfiguration
                            } `
                            -EditDeploymentEnvironmentsScriptBlock {
                                param($allMappings, $mappingToEdit, $environmentNameToEdit)

                                $branchName = [string]$mappingToEdit.BranchName
                                $excludedDevUrl = if ($mappingToEdit.DevEnvironmentConfiguration) {
                                    $mappingToEdit.DevEnvironmentConfiguration.Url
                                }
                                elseif ($mappingToEdit.ExistingDevEnvironment) {
                                    $mappingToEdit.ExistingDevEnvironment.Url
                                }
                                else {
                                    $null
                                }
                                $selectedDeploymentEnvironments = @(Select-ConfiguredDeploymentEnvironment `
                                    -InitialEnvironments @($mappingToEdit.Environments) `
                                    -InitialEditEnvironmentName $environmentNameToEdit `
                                    -Heading "Target deployment environments for branch '$branchName'" `
                                    -Title "Manage deployment environments for branch '$branchName'" `
                                    -GuidanceLines @(
                                        "Select the Dataverse targets branch '$branchName' should promote through.",
                                        'Order defines promotion flow: first environment is the first stage, and each later stage depends on the previous one.'
                                    ) `
                                    -DocRelativePath 'docs/setup/github-setup.md' `
                                    -Ref $ALM4DataverseRef `
                                    -AddEnvironmentScriptBlock {
                                        param($currentSelections)

                                        $currentCredentials = @($cachedCredentials)
                                        $currentCredentials += @($currentSelections | ForEach-Object { $_.Credentials } | Where-Object { $null -ne $_ })
                                        $currentServiceAccounts = @($cachedServiceAccounts)
                                        $currentServiceAccounts += @($currentSelections | ForEach-Object { $_.ServiceAccountUPN } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                                        $selectTargetName = {
                                            param($environmentState)
                                            if ($currentSelections | Where-Object { $_.Url -ieq $environmentState.Url }) {
                                                Write-Host 'An environment with that URL is already selected for this branch.' -ForegroundColor Red
                                                Request-SetupWizardBack
                                            }
                                            $shortName = Read-TextWithDefault `
                                                -Prompt 'Enter a short name for this environment' `
                                                -DefaultValue $environmentState.ShortName `
                                                -PromptGuidanceLines @(
                                                    'Use a concise name such as TEST, UAT, or PROD.',
                                                    'This label appears in setup summaries and must be unique within the branch.'
                                                ) `
                                                -PromptGuidanceDocRelativePath 'docs/config/alm-config.md' `
                                                -PromptGuidanceRef $ALM4DataverseRef
                                            if ([string]::IsNullOrWhiteSpace($shortName)) {
                                                [Spectre.Console.AnsiConsole]::MarkupLine('[red]An environment short name is required.[/]')
                                                Request-SetupWizardBack
                                            }
                                            if ($currentSelections | Where-Object { $_.ShortName -ieq $shortName }) {
                                                Write-Host 'An environment with that short name is already selected for this branch.' -ForegroundColor Red
                                                Request-SetupWizardBack
                                            }
                                            return $shortName.Trim()
                                        }.GetNewClosure()

                                        $environmentConfiguration = Invoke-GitHubEnvironmentConfigurationWizard `
                                            -Title "Configure deployment environment for branch '$branchName'" `
                                            -DataverseEnvironmentPrompt "Select a Dataverse environment for branch '$branchName'" `
                                            -InitialTargetName '' `
                                            -TargetNameStepName 'Short name' `
                                            -SelectTargetNameAction $selectTargetName `
                                            -ExcludedUrl $excludedDevUrl `
                                            -ExistingCredentials $currentCredentials `
                                            -ExistingServiceAccounts $currentServiceAccounts `
                                            -TenantId $TenantId `
                                            -RepoName $RepoName `
                                            -PromptGuidanceLines @(
                                                "Select the Dataverse target that branch '$branchName' should promote through.",
                                                'The branch DEV environment cannot be selected as a deployment target.'
                                            ) `
                                            -PromptGuidanceDocRelativePath 'docs/setup/github-setup.md' `
                                            -PromptGuidanceRef $ALM4DataverseRef `
                                            -HelpDocRelativePath 'docs/setup/github-setup.md' `
                                            -HelpRef $ALM4DataverseRef
                                        if ($environmentConfiguration -and $environmentConfiguration.Credentials -and -not ($cachedCredentials | Where-Object { $_.ApplicationId -eq $environmentConfiguration.Credentials.ApplicationId -and $_.TenantId -eq $environmentConfiguration.Credentials.TenantId })) {
                                            $cachedCredentials += $environmentConfiguration.Credentials
                                        }
                                        if ($environmentConfiguration -and -not [string]::IsNullOrWhiteSpace($environmentConfiguration.ServiceAccountUPN) -and $cachedServiceAccounts -notcontains $environmentConfiguration.ServiceAccountUPN) {
                                            $cachedServiceAccounts += $environmentConfiguration.ServiceAccountUPN
                                        }

                                        return $environmentConfiguration
                                    } `
                                    -EditEnvironmentScriptBlock {
                                        param($currentSelections, $environmentToEdit, $environmentIndex)

                                        $otherSelections = @()
                                        for ($selectionIndex = 0; $selectionIndex -lt $currentSelections.Count; $selectionIndex++) {
                                            if ($selectionIndex -ne $environmentIndex) {
                                                $otherSelections += $currentSelections[$selectionIndex]
                                            }
                                        }

                                        $currentCredentials = @($cachedCredentials)
                                        $currentCredentials += @($otherSelections | ForEach-Object { $_.Credentials } | Where-Object { $null -ne $_ })
                                        $currentServiceAccounts = @($cachedServiceAccounts)
                                        $currentServiceAccounts += @($otherSelections | ForEach-Object { $_.ServiceAccountUPN } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                                        $selectTargetName = {
                                            param($environmentState)
                                            if ($otherSelections | Where-Object { $_.Url -ieq $environmentState.Url }) {
                                                Write-Host 'An environment with that URL is already selected for this branch.' -ForegroundColor Red
                                                Request-SetupWizardBack
                                            }
                                            $shortName = Read-TextWithDefault `
                                                -Prompt 'Enter a short name for this environment' `
                                                -DefaultValue $environmentState.ShortName `
                                                -PromptGuidanceLines @(
                                                    'Use a concise name such as TEST, UAT, or PROD.',
                                                    'This label appears in setup summaries and must be unique within the branch.'
                                                ) `
                                                -PromptGuidanceDocRelativePath 'docs/config/alm-config.md' `
                                                -PromptGuidanceRef $ALM4DataverseRef
                                            if ([string]::IsNullOrWhiteSpace($shortName)) {
                                                [Spectre.Console.AnsiConsole]::MarkupLine('[red]An environment short name is required.[/]')
                                                Request-SetupWizardBack
                                            }
                                            if ($otherSelections | Where-Object { $_.ShortName -ieq $shortName }) {
                                                Write-Host 'An environment with that short name is already selected for this branch.' -ForegroundColor Red
                                                Request-SetupWizardBack
                                            }
                                            return $shortName.Trim()
                                        }.GetNewClosure()
                                        $environmentConfiguration = Invoke-GitHubEnvironmentConfigurationWizard `
                                            -Title "Configure deployment environment '$($environmentToEdit.ShortName)' in branch '$branchName'" `
                                            -DataverseEnvironmentPrompt "Select the Dataverse environment for '$($environmentToEdit.ShortName)' in branch '$branchName'" `
                                            -InitialConfiguration $environmentToEdit `
                                            -TargetNameStepName 'Short name' `
                                            -SelectTargetNameAction $selectTargetName `
                                            -ExcludedUrl $excludedDevUrl `
                                            -ExistingCredentials $currentCredentials `
                                            -ExistingServiceAccounts $currentServiceAccounts `
                                            -TenantId $TenantId `
                                            -RepoName $RepoName `
                                            -PromptGuidanceLines @(
                                                'Choose the Dataverse target for this deployment stage.',
                                                'Changing the target invalidates credentials and service-account ownership selected for the previous environment.'
                                            ) `
                                            -PromptGuidanceDocRelativePath 'docs/setup/github-setup.md' `
                                            -PromptGuidanceRef $ALM4DataverseRef `
                                            -HelpDocRelativePath 'docs/setup/github-setup.md' `
                                            -HelpRef $ALM4DataverseRef
                                        if ($environmentConfiguration -and $environmentConfiguration.Credentials -and -not ($cachedCredentials | Where-Object { $_.ApplicationId -eq $environmentConfiguration.Credentials.ApplicationId -and $_.TenantId -eq $environmentConfiguration.Credentials.TenantId })) {
                                            $cachedCredentials += $environmentConfiguration.Credentials
                                        }
                                        if ($environmentConfiguration -and -not [string]::IsNullOrWhiteSpace($environmentConfiguration.ServiceAccountUPN) -and $cachedServiceAccounts -notcontains $environmentConfiguration.ServiceAccountUPN) {
                                            $cachedServiceAccounts += $environmentConfiguration.ServiceAccountUPN
                                        }
                                        return $environmentConfiguration
                                    })

                                return @($selectedDeploymentEnvironments)
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

                                if ($UseGitHubEnvironments) {
                                    Write-Host "Preparing GitHub environment credentials for BUILD validation on '$branchName'." -ForegroundColor Green
                                }
                                else {
                                    Write-Host "Preparing repo-level credentials for BUILD validation on '$branchName'." -ForegroundColor Green
                                }

                                $selectTargetName = {
                                    param($environmentState)
                                    $environmentName = Read-TextWithDefault `
                                        -Prompt "Enter the GitHub environment name for BUILD validation on branch '$branchName'" `
                                        -DefaultValue $environmentState.ShortName `
                                        -PromptGuidanceLines @(
                                            'This GitHub environment stores the credentials used for BUILD-time deployment validation.',
                                            'Use a stable name; the suggested default is branch-specific.'
                                        ) `
                                        -PromptGuidanceDocRelativePath 'docs/config/github-secrets.md' `
                                        -PromptGuidanceRef $ALM4DataverseRef
                                    if ([string]::IsNullOrWhiteSpace($environmentName)) {
                                        [Spectre.Console.AnsiConsole]::MarkupLine('[red]A GitHub environment name is required for BUILD validation.[/]')
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
                                $buildValidationConfiguration = Invoke-GitHubEnvironmentConfigurationWizard `
                                    -Title "Configure BUILD validation for branch '$branchName'" `
                                    -DataverseEnvironmentPrompt "Select the Dataverse environment for BUILD validation on branch '$branchName'" `
                                    -InitialConfiguration $existingBuildValidationEnvironment `
                                    -InitialTargetName $(if ([string]::IsNullOrWhiteSpace($existingBuildValidationEnvironmentName)) { "Build-$branchName" } else { $existingBuildValidationEnvironmentName }) `
                                    -TargetNameStepName 'GitHub environment name' `
                                    -SelectTargetNameAction $selectTargetName `
                                    -SelectBaselineAction $selectBaseline `
                                    -InitialBaselineRelease ([string]$mappingToEdit.BuildValidationBaselineRelease) `
                                    -BaselineConfigured:([bool]$mappingToEdit.BuildValidationEnabled) `
                                    -ExistingCredentials $cachedCredentials `
                                    -ExistingServiceAccounts $cachedServiceAccounts `
                                    -TenantId $TenantId `
                                    -RepoName $RepoName `
                                    -PromptGuidanceLines @(
                                        'Choose the Dataverse environment that BUILD should validate deployments against.',
                                        'A separate deployment environment can be selected as the baseline source.'
                                    ) `
                                    -PromptGuidanceDocRelativePath 'docs/usage/building-releases.md' `
                                    -PromptGuidanceRef $ALM4DataverseRef `
                                    -HelpDocRelativePath 'docs/setup/github-setup.md' `
                                    -HelpRef $ALM4DataverseRef
                                if ($null -eq $buildValidationConfiguration) {
                                    if ([bool]$mappingToEdit.BuildValidationEnabled) {
                                        return [pscustomobject]@{
                                            BuildValidationEnabled = $true
                                            BuildValidationEnvironmentName = $(if ([string]::IsNullOrWhiteSpace($existingBuildValidationEnvironmentName)) { [string]$mappingToEdit.BuildValidationEnvironmentName } else { $existingBuildValidationEnvironmentName })
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

                                if ($buildValidationConfiguration.Credentials -and -not ($cachedCredentials | Where-Object { $_.ApplicationId -eq $buildValidationConfiguration.Credentials.ApplicationId -and $_.TenantId -eq $buildValidationConfiguration.Credentials.TenantId })) {
                                    $cachedCredentials += $buildValidationConfiguration.Credentials
                                }
                                if (-not [string]::IsNullOrWhiteSpace($buildValidationConfiguration.ServiceAccountUPN) -and $cachedServiceAccounts -notcontains $buildValidationConfiguration.ServiceAccountUPN) {
                                    $cachedServiceAccounts += $buildValidationConfiguration.ServiceAccountUPN
                                }

                                return [pscustomobject]@{
                                    BuildValidationEnabled = $true
                                    BuildValidationEnvironmentName = [string]$buildValidationConfiguration.ShortName
                                    BuildValidationBaselineRelease = [string]$buildValidationConfiguration.BaselineRelease
                                    BuildValidationEnvironmentConfiguration = $buildValidationConfiguration
                                    ExistingBuildValidationEnvironment = $mappingToEdit.ExistingBuildValidationEnvironment
                                }
                            }
                    })

                    $existingStateByBranch = @{}
                    foreach ($branchState in @($wizardState.BranchStates)) {
                        $existingStateByBranch[$branchState.BranchName.ToLowerInvariant()] = $branchState
                    }

                    $updatedBranchStates = @()
                    foreach ($selectedBranchMapping in $selectedBranchMappings) {
                        $branchName = [string]$selectedBranchMapping.BranchName
                        $branchKey = $branchName.ToLowerInvariant()
                        if ($existingStateByBranch.ContainsKey($branchKey)) {
                            $existingBranchState = $existingStateByBranch[$branchKey]
                            $existingBranchState.DevEnvironmentConfiguration = $selectedBranchMapping.DevEnvironmentConfiguration
                            $existingBranchState.DeploymentEnvironments = @($selectedBranchMapping.Environments)
                            $existingBranchState.ExistingBuildValidationEnvironment = $selectedBranchMapping.ExistingBuildValidationEnvironment
                            $existingBranchState.BuildValidationEnabled = [bool]$selectedBranchMapping.BuildValidationEnabled
                            $existingBranchState.BuildValidationEnvironmentName = [string]$selectedBranchMapping.BuildValidationEnvironmentName
                            $existingBranchState.BuildValidationBaselineRelease = [string]$selectedBranchMapping.BuildValidationBaselineRelease
                            $existingBranchState.BuildValidationEnvironmentConfiguration = $selectedBranchMapping.BuildValidationEnvironmentConfiguration
                            $updatedBranchStates += $existingBranchState
                            continue
                        }

                        $existingDevEnvironment = if ($branchName -ieq $DefaultBranch) {
                            $ExistingSetupState.DevEnvironment
                        }
                        else {
                            Get-GitHubExistingEnvironmentState -Owner $RepoOwner -Repo $RepoName -EnvironmentName "Dev-$branchName" -TenantId $TenantId
                        }

                        $existingBranchState = $wizardState.BranchStates | Where-Object { $_.BranchName -ieq $branchName } | Select-Object -First 1
                        $newBranchState = New-GitHubBranchSetupState `
                            -BranchName $branchName `
                            -ExistingDevEnvironment $existingDevEnvironment `
                            -DeploymentEnvironments @() `
                            -ExistingBuildValidationEnvironment (Get-OptionalObjectPropertyValue -InputObject $existingBranchState -PropertyName 'ExistingBuildValidationEnvironment') `
                            -BuildValidationEnvironmentName ([string](Get-OptionalObjectPropertyValue -InputObject $existingBranchState -PropertyName 'BuildValidationEnvironmentName')) `
                            -BuildValidationBaselineRelease ([string](Get-OptionalObjectPropertyValue -InputObject $existingBranchState -PropertyName 'BuildValidationBaselineRelease'))
                        $newBranchState.DevEnvironmentConfiguration = $selectedBranchMapping.DevEnvironmentConfiguration
                        $newBranchState.DeploymentEnvironments = @($selectedBranchMapping.Environments)
                        $newBranchState.ExistingBuildValidationEnvironment = $selectedBranchMapping.ExistingBuildValidationEnvironment
                        $newBranchState.BuildValidationEnabled = [bool]$selectedBranchMapping.BuildValidationEnabled
                        $newBranchState.BuildValidationEnvironmentName = [string]$selectedBranchMapping.BuildValidationEnvironmentName
                        $newBranchState.BuildValidationBaselineRelease = [string]$selectedBranchMapping.BuildValidationBaselineRelease
                        $newBranchState.BuildValidationEnvironmentConfiguration = $selectedBranchMapping.BuildValidationEnvironmentConfiguration
                        $updatedBranchStates += $newBranchState
                    }

                    $wizardState.BranchStates = @($updatedBranchStates | Sort-Object BranchName)

                    $branchMappingsForValidation = @($wizardState.BranchStates | ForEach-Object {
                        [pscustomobject]@{
                            BranchName   = [string]$_.BranchName
                            Environments = @($_.DeploymentEnvironments)
                        }
                    })
                    if (Test-BranchEnvironmentMappingDuplicate -BranchMappings $branchMappingsForValidation) {
                        throw 'Each deployment environment can only be assigned to one branch. Resolve duplicate environment assignments before continuing.'
                    }

                    $branchesWithNoEnvironments = @($selectedBranchMappings | Where-Object {
                        ($null -eq $_.DevEnvironmentConfiguration) -and (@($_.Environments).Count -eq 0)
                    } | ForEach-Object { $_.BranchName })
                    if ($branchesWithNoEnvironments.Count -gt 0) {
                        $branchList = ($branchesWithNoEnvironments -join ', ')
                        throw "Each configured branch must have at least one mapped environment (DEV or deployment). Remove unused branches or configure environments for: $branchList"
                    }

                    $wizardState.BranchStates = @($selectedBranchMappings | ForEach-Object {
                        $mappedBranch = $_
                        $existingBranchState = $updatedBranchStates | Where-Object { $_.BranchName -ieq $mappedBranch.BranchName } | Select-Object -First 1
                        if (-not $existingBranchState) {
                            $existingBranchState = New-GitHubBranchSetupState -BranchName ([string]$mappedBranch.BranchName) -ExistingDevEnvironment $null -DeploymentEnvironments @()
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
                    $wizardState.BuildValidationEnvironmentName = if ($enabledBuildBranches.Count -eq 1) { [string]$enabledBuildBranches[0].BuildValidationEnvironmentName } else { '' }
                    $wizardState.BuildValidationBaselineRelease = if ($enabledBuildBranches.Count -eq 1) { [string]$enabledBuildBranches[0].BuildValidationBaselineRelease } else { '' }
                    $wizardState.BuildValidationEnvironmentConfiguration = if ($enabledBuildBranches.Count -eq 1) { $enabledBuildBranches[0].BuildValidationEnvironmentConfiguration } else { $null }

                    $incompleteDeploymentEnvironments = @(
                        foreach ($branchState in @($wizardState.BranchStates)) {
                            foreach ($environmentConfiguration in @($branchState.DeploymentEnvironments)) {
                                if ($null -eq $environmentConfiguration) {
                                    continue
                                }

                                $missingParts = @()
                                if ([string]::IsNullOrWhiteSpace([string](Get-OptionalObjectPropertyValue -InputObject $environmentConfiguration -PropertyName 'ShortName'))) {
                                    $missingParts += 'target name'
                                }
                                if ([string]::IsNullOrWhiteSpace([string](Get-OptionalObjectPropertyValue -InputObject $environmentConfiguration -PropertyName 'Url'))) {
                                    $missingParts += 'Dataverse environment'
                                }
                                if ($null -eq (Get-OptionalObjectPropertyValue -InputObject $environmentConfiguration -PropertyName 'Credentials')) {
                                    $missingParts += 'credentials'
                                }
                                if ([string]::IsNullOrWhiteSpace([string](Get-OptionalObjectPropertyValue -InputObject $environmentConfiguration -PropertyName 'ServiceAccountUPN'))) {
                                    $missingParts += 'service account'
                                }
                                if (
                                    [bool](Get-OptionalObjectPropertyValue -InputObject $environmentConfiguration -PropertyName 'ConfigurationPending') -and
                                    $missingParts.Count -eq 0
                                ) {
                                    $missingParts += 'provider configuration'
                                }

                                if ($missingParts.Count -gt 0) {
                                    $environmentName = [string](Get-OptionalObjectPropertyValue -InputObject $environmentConfiguration -PropertyName 'ShortName')
                                    if ([string]::IsNullOrWhiteSpace($environmentName)) {
                                        $environmentName = [string](Get-OptionalObjectPropertyValue -InputObject $environmentConfiguration -PropertyName 'FriendlyName')
                                    }
                                    if ([string]::IsNullOrWhiteSpace($environmentName)) {
                                        $environmentName = 'unnamed environment'
                                    }
                                    [pscustomobject]@{
                                        BranchName    = [string]$branchState.BranchName
                                        EnvironmentName = $environmentName
                                        MissingParts  = @($missingParts)
                                    }
                                }
                            }
                        }
                    )

                    if ($incompleteDeploymentEnvironments.Count -gt 0) {
                        $incompleteEnvironmentSummary = @($incompleteDeploymentEnvironments | ForEach-Object {
                            "$($_.BranchName)/$($_.EnvironmentName): $($_.MissingParts -join ', ')"
                        }) -join '; '
                        Write-Host "Complete these GitHub deployment environment settings before applying changes: $incompleteEnvironmentSummary. Select each listed environment under 'Configure branches, dev and deployment envs'." -ForegroundColor Yellow
                        # Return to the navigation menu without completing this step; each environment remains directly selectable.
                        Request-SetupWizardBack
                    }

                    foreach ($branchState in @($wizardState.BranchStates)) {
                        $branchState.PublishPlan = Get-BranchTargetedRepoChangePublishPlan `
                            -ProviderName 'GitHub' `
                            -RepositoryName $RepoFullName `
                            -TargetBranch $branchState.BranchName `
                            -DefaultCommitMessage "Add ALM4Dataverse GitHub Actions workflows for branch '$($branchState.BranchName)'" `
                            -DefaultPullRequestTitle "Add ALM4Dataverse GitHub Actions workflows for branch '$($branchState.BranchName)'" `
                            -DefaultPullRequestDescription "This pull request adds or updates the ALM4Dataverse GitHub Actions workflow and repository configuration for branch '$($branchState.BranchName)'." `
                            -GuidanceLines @(
                                "Choose how the generated files for branch '$($branchState.BranchName)' should be published.",
                                'Use pull-request mode when reviews or branch protection must happen before the branch becomes active.'
                            ) `
                            -DocRelativePath 'docs/setup/github-setup.md' `
                            -Ref $ALM4DataverseRef
                    }
                }
            },
            [pscustomobject]@{
                Name = 'Configure solutions'
                HelpDocRelativePath = 'docs/config/alm-config.md'
                Summary = {
                    Get-SetupSolutionMenuSummary `
                        -SolutionData $wizardState.SolutionResult `
                        -SourceBranch $wizardState.SolutionSourceBranch
                }
                Action = {
                    Write-Section `
                        -Message 'Configure Solutions (alm-config.psd1)'

                    $candidateBranches = @($wizardState.BranchStates | Where-Object { $_.DevEnvironmentConfiguration })
                    if ($candidateBranches.Count -eq 0) {
                        [Spectre.Console.AnsiConsole]::MarkupLine('[yellow]No branch currently has a DEV environment configured, so solution selection will be skipped for now.[/]')
                        $wizardState.SolutionResult = $null
                        $wizardState.SolutionSourceBranch = $null
                        return
                    }

                    if ($candidateBranches.Count -eq 1) {
                        $sourceBranchState = $candidateBranches[0]
                    }
                    else {
                        $branchMenuItems = @($candidateBranches | ForEach-Object {
                            $friendlyName = if ($_.DevEnvironmentConfiguration -and -not [string]::IsNullOrWhiteSpace($_.DevEnvironmentConfiguration.FriendlyName)) {
                                [string]$_.DevEnvironmentConfiguration.FriendlyName
                            }
                            else {
                                [string]$_.BranchName
                            }
                            "Use branch '$($_.BranchName)' ($friendlyName) for solution discovery"
                        })
                        $branchSelection = Select-FromMenu -Title 'Select which configured branch should provide the DEV environment for solution discovery' -Items $branchMenuItems -PromptGuidanceLines @(
                            'Choose the branch whose DEV environment should be used for solution discovery.',
                            'Use the branch that currently reflects your source-controlled customization baseline.'
                        ) -PromptGuidanceDocRelativePath 'docs/config/alm-config.md' -PromptGuidanceRef $ALM4DataverseRef
                        if ($null -eq $branchSelection) {
                            throw 'No solution source branch selected.'
                        }

                        $sourceBranchState = $candidateBranches[$branchSelection]
                    }

                    $wizardState.SolutionSourceBranch = $sourceBranchState.BranchName
                    $existingConfigPath = Join-Path $CloneRoot 'alm-config.psd1'
                    $wizardState.SolutionResult = Invoke-WithErrorHandling -OperationName 'Selecting solutions' -ScriptBlock {
                        Get-DataverseSolutionsSelection `
                            -ExistingConfigPath $existingConfigPath `
                            -ExistingEnvironmentUrl $sourceBranchState.DevEnvironmentConfiguration.Url `
                            -ExistingEnvironmentConfiguration $sourceBranchState.DevEnvironmentConfiguration
                    }
                }
            },
            [pscustomobject]@{
                Name = 'Configure GitHub OIDC identity'
                HelpDocRelativePath = 'docs/config/github-secrets.md'
                Summary = {
                    $hasWifCredential = $false
                    foreach ($branchState in @($wizardState.BranchStates)) {
                        $environmentConfigurations = @($branchState.DevEnvironmentConfiguration) +
                            @($branchState.DeploymentEnvironments) +
                            @($branchState.BuildValidationEnvironmentConfiguration)
                        foreach ($environmentConfiguration in $environmentConfigurations) {
                            if (Test-GitHubEnvironmentConfigurationUsesWif -EnvironmentConfiguration $environmentConfiguration) {
                                $hasWifCredential = $true
                                break
                            }
                        }
                        if ($hasWifCredential) {
                            break
                        }
                    }

                    if (-not $hasWifCredential) {
                        'Not required'
                    }
                    elseif ($wizardState.UseImmutableWifSubject) {
                        'Immutable subjects'
                    }
                    else {
                        'Legacy subjects'
                    }
                }
                Action = {
                    $hasWifCredential = $false
                    foreach ($branchState in @($wizardState.BranchStates)) {
                        $environmentConfigurations = @($branchState.DevEnvironmentConfiguration) +
                            @($branchState.DeploymentEnvironments) +
                            @($branchState.BuildValidationEnvironmentConfiguration)
                        foreach ($environmentConfiguration in $environmentConfigurations) {
                            if (Test-GitHubEnvironmentConfigurationUsesWif -EnvironmentConfiguration $environmentConfiguration) {
                                $hasWifCredential = $true
                            }
                        }
                    }

                    $wizardState.UseImmutableWifSubject = [bool](Get-OptionalObjectPropertyValue -InputObject $RepoIdentity -PropertyName 'UseImmutableSubject')
                    if ($hasWifCredential -and -not $wizardState.UseImmutableWifSubject) {
                        $immutableSubjectChangelogUrl = 'https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens/#opt-in-for-existing-repositories'
                        $enableImmutableSubject = Read-YesNo `
                            -Prompt "Enable immutable GitHub OIDC subjects for '$RepoFullName'?" `
                            -PromptGuidanceLines @(
                                'Workload Identity Federation was selected for at least one ALM4Dataverse credential.',
                                'Recommended: immutable owner/repository IDs reduce the risk of trust being reused after a name is recycled.',
                                'Risk: other workflows or applications in this repository that trust legacy subjects may stop authenticating until their cloud credentials are updated.',
                                "Changelog: $immutableSubjectChangelogUrl"
                            ) `
                            -PromptGuidanceDocRelativePath 'docs/config/github-secrets.md' `
                            -PromptGuidanceRef $ALM4DataverseRef `
                            -DefaultNo

                        $wizardState.UseImmutableWifSubject = [bool]$enableImmutableSubject
                        if (-not $wizardState.UseImmutableWifSubject) {
                            Write-Host "Keeping legacy GitHub OIDC subjects. Federated credentials will use the existing repository format." -ForegroundColor Yellow
                        }
                    }

                    $ProviderOptions['GitHubUseImmutableWifSubject'] = [bool]$wizardState.UseImmutableWifSubject
                }
            },
            [pscustomobject]@{
                Name = 'Preview changes'
                HelpDocRelativePath = 'docs/setup/github-setup.md'
                Action = {
                    $artifactPreview = Get-GitHubSetupArtifactsPreview `
                        -RepoRoot $CloneRoot `
                        -CopyRoot $copyRoot `
                        -DefaultBranch $DefaultBranch `
                        -Repository $SharedWorkflowRepositoryState.Repository `
                        -Ref $SharedWorkflowRepositoryState.Reference `
                        -PromotionMode $DeploymentPromotionMode `
                        -ExistingSetupState $ExistingSetupState `
                        -BranchStates @($wizardState.BranchStates) `
                        -ProviderOptions $ProviderOptions `
                        -SolutionResult $wizardState.SolutionResult

                    $resourceChanges = @()
                    $resourceChangeNote = if ($ApplyConfig) {
                        'ApplyConfig only modifies repository files; it does not provision GitHub, Entra ID, or Dataverse resources.'
                    }
                    else {
                        $resourceChanges = @(Get-GitHubSetupResourceChange `
                                -BranchStates @($wizardState.BranchStates) `
                                -RepoIdentity $RepoIdentity `
                                -RepoFullName $RepoFullName `
                                -UseImmutableWifSubject $wizardState.UseImmutableWifSubject `
                                -UseGitHubEnvironments $UseGitHubEnvironments `
                                -UseRepositoryVariablePrefix $UseRepositoryVariablePrefix `
                                -EnableEnvironmentApprovals $EnableEnvironmentApprovals `
                                -RequiredReviewerIds $RequiredReviewerIds)
                        'Only resource changes deferred until Apply are listed; prerequisites already created during setup are excluded.'
                    }

                    $summaryAction = {
                        Write-Section -Message 'Review setup changes'
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

                        $branchMappingsForReview = @($wizardState.BranchStates | ForEach-Object {
                            [pscustomobject]@{
                                BranchName   = [string]$_.BranchName
                                Environments = @($_.DeploymentEnvironments)
                            }
                        })
                        $buildValidationSummaries = @($wizardState.BranchStates | Where-Object { $_.BuildValidationEnabled } | ForEach-Object {
                            "$($_.BranchName): $($_.BuildValidationEnvironmentName)"
                        })
                        $buildBaselineSummaries = @($wizardState.BranchStates | Where-Object { $_.BuildValidationEnabled -and -not [string]::IsNullOrWhiteSpace([string]$_.BuildValidationBaselineRelease) } | ForEach-Object {
                            "$($_.BranchName): $($_.BuildValidationBaselineRelease)"
                        })
                        $fileChanges = @($artifactPreview.FileChanges)
                        Show-KeyValueSummaryTable -Heading 'Setup summary' -Values ([ordered]@{
                            'Setup type'              = $(if ($IsNewRepository) { 'Complete setup for a new repository' } else { 'Changes to existing repository setup' })
                            'Repository'              = $RepoFullName
                            'Shared workflow source'  = $SharedWorkflowRepositoryState.Repository
                            'Shared workflow ref'     = $SharedWorkflowRepositoryState.Reference
                            'Credential storage'      = $(if ($UseGitHubEnvironments) { 'GitHub environments' } else { 'Repository variables + environment secrets' })
                            'Immutable OIDC subject'  = $(if ($wizardState.UseImmutableWifSubject) { 'Enabled' } else { 'Disabled' })
                            'Promotion mode'          = $DeploymentPromotionMode
                            'Configured branches'     = [string]$wizardState.BranchStates.Count
                            'BUILD validation'        = $(if ($buildValidationSummaries.Count -gt 0) { $buildValidationSummaries -join '; ' } else { 'Disabled' })
                            'BUILD validation baseline' = $(if ($buildBaselineSummaries.Count -gt 0) { $buildBaselineSummaries -join '; ' } else { '<none>' })
                            'Solution source branch'  = $(if ([string]::IsNullOrWhiteSpace($wizardState.SolutionSourceBranch)) { '<none>' } else { $wizardState.SolutionSourceBranch })
                            'Solutions selected'      = [string]$(if ($wizardState.SolutionResult) { @($wizardState.SolutionResult.Solutions).Count } else { 0 })
                            'Files to add'            = [string]@($fileChanges | Where-Object { $_.Status -eq 'Added' }).Count
                            'Files to modify'         = [string]@($fileChanges | Where-Object { $_.Status -eq 'Modified' }).Count
                            'Files to delete'         = [string]@($fileChanges | Where-Object { $_.Status -eq 'Deleted' }).Count
                            'Deferred resource changes' = [string]$resourceChanges.Count
                        })

                        Show-BranchEnvironmentMappingTable -BranchMappings $branchMappingsForReview
                        [Spectre.Console.AnsiConsole]::WriteLine()
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
                                'Deployment environments'  = [string]@($branchState.DeploymentEnvironments).Count
                                'BUILD validation'         = $(if ($branchState.BuildValidationEnabled) { [string]$branchState.BuildValidationEnvironmentName } else { '<disabled>' })
                                'BUILD validation baseline' = $(if ([string]::IsNullOrWhiteSpace([string]$branchState.BuildValidationBaselineRelease)) { '<none>' } else { [string]$branchState.BuildValidationBaselineRelease })
                            })
                        }

                        if ($allConfiguredEnvironments.Count -gt 0) {
                            Show-EnvironmentConfigurationTable -EnvironmentConfigurations $allConfiguredEnvironments
                        }
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
                HelpDocRelativePath = 'docs/setup/github-setup.md'
                Summary = {
                    Get-SetupPublishPlanMenuSummary -BranchStates @($wizardState.BranchStates)
                }
                Action = {
                    foreach ($branchState in @($wizardState.BranchStates)) {
                        $branchName = [string]$branchState.BranchName
                        $branchState.PublishPlan = Get-BranchTargetedRepoChangePublishPlan `
                            -ProviderName 'GitHub' `
                            -RepositoryName $RepoFullName `
                            -TargetBranch $branchName `
                            -DefaultCommitMessage "Apply alm-config.psd1 settings for branch '$branchName'" `
                            -DefaultPullRequestTitle "Apply alm-config.psd1 settings for branch '$branchName'" `
                            -DefaultPullRequestDescription "This pull request regenerates the GitHub workflow files from the committed alm-config.psd1 settings for branch '$branchName'." `
                            -GuidanceLines @(
                                "Choose how the generated workflow files for branch '$branchName' should be published.",
                                'Use a pull request when branch protection or review is required.'
                            ) `
                            -DocRelativePath 'docs/setup/github-setup.md' `
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
                SolutionSourceBranch   = $wizardState.SolutionSourceBranch
                BuildValidationEnabled = [bool](@($wizardState.BranchStates | Where-Object { $_.BuildValidationEnabled }).Count -gt 0)
                UseImmutableWifSubject  = [bool]$wizardState.UseImmutableWifSubject
                PublishResults          = @()
            }
        }

        $setupResult = Invoke-SetupWizard `
            -Title 'GitHub Actions ALM4Dataverse setup' `
            -Steps $setupSteps `
            -PreviewAction $previewStep.Action `
            -PreviewActionName $previewStep.Name `
            -HelpDocRelativePath 'docs/setup/github-setup.md' `
            -HelpRef $ALM4DataverseRef `
            -ApplyAction {
            $applyResult = Invoke-GitHubBranchAwareSetupApply `
                -CloneRoot $CloneRoot `
                -CopyRoot $copyRoot `
                -DefaultBranch $DefaultBranch `
                -ExistingSetupState $ExistingSetupState `
                -SharedWorkflowRepository ([string]$SharedWorkflowRepositoryState.Repository) `
                -SharedWorkflowReference ([string]$SharedWorkflowRepositoryState.Reference) `
                -ALM4DataverseRef $ALM4DataverseRef `
                -PromotionMode $DeploymentPromotionMode `
                -WizardState $wizardState `
                -ProviderOptions $ProviderOptions
            if ($PostApplyAction) {
                & $PostApplyAction $applyResult
            }
            return $applyResult
        } -IsNewRepository:$IsNewRepository
        return $setupResult
    }
    finally {
        if ($upstreamClone -and (Test-Path -LiteralPath $upstreamClone)) {
            try { Remove-Item -LiteralPath $upstreamClone -Recurse -Force -ErrorAction Stop } catch { Write-Verbose 'Could not remove the upstream repository clone; continuing cleanup.' }
        }
    }
}
