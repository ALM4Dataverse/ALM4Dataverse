function Get-AzDoInitialBranchMapping {
    # Adapt config-backed states to the branch editor's BranchName/Environments contract.
    # Null targets are removed; no usable states gives one empty DefaultBranch mapping.
    [CmdletBinding()]
    [OutputType([pscustomobject], [object[]])]
    param(
        [Parameter(Mandatory)][object]$ExistingSetupState,
        [Parameter(Mandatory)][string]$DefaultBranch
    )

    $branchMappings = @()
    $existingConfiguration = Get-OptionalObjectPropertyValue -InputObject $ExistingSetupState -PropertyName 'ExistingConfiguration'
    $legacyBuildValidation = Get-OptionalObjectPropertyValue -InputObject $existingConfiguration -PropertyName 'buildValidation'
    $legacyBaselineRelease = [string](Get-OptionalObjectPropertyValue -InputObject $legacyBuildValidation -PropertyName 'baselineRelease')
    foreach ($branchState in @($ExistingSetupState.BranchStates)) {
        if ($null -eq $branchState -or [string]::IsNullOrWhiteSpace([string]$branchState.BranchName)) {
            continue
        }

        $branchProperties = @($branchState.PSObject.Properties.Name)
        $validationEnvironmentName = if ($branchProperties -contains 'BuildValidationEnvironmentName') {
            [string]$branchState.BuildValidationEnvironmentName
        }
        else {
            [string](Get-OptionalObjectPropertyValue -InputObject $ExistingSetupState -PropertyName 'BuildValidationEnvironmentName')
        }
        $validationEnvironment = if ($branchProperties -contains 'ExistingBuildValidationEnvironment') {
            $branchState.ExistingBuildValidationEnvironment
        }
        else {
            Get-OptionalObjectPropertyValue -InputObject $ExistingSetupState -PropertyName 'ExistingBuildValidationEnvironment'
        }
        $baselineRelease = if ($branchProperties -contains 'BuildValidationBaselineRelease') {
            [string]$branchState.BuildValidationBaselineRelease
        }
        else {
            $legacyBaselineRelease
        }

        $branchMappings += [pscustomobject]@{
            BranchName                         = [string]$branchState.BranchName
            Environments                       = @($branchState.DeploymentEnvironments | Where-Object { $null -ne $_ })
            ExistingDevEnvironment             = Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'ExistingDevEnvironment'
            ExistingBuildValidationEnvironment = $validationEnvironment
            BuildValidationEnvironmentName     = $validationEnvironmentName
            BuildValidationBaselineRelease     = $baselineRelease
        }
    }

    if ($branchMappings.Count -eq 0) {
        $branchMappings = @(
            [pscustomobject]@{
                BranchName                         = $DefaultBranch
                Environments                       = @()
                ExistingDevEnvironment             = $null
                ExistingBuildValidationEnvironment = Get-OptionalObjectPropertyValue -InputObject $ExistingSetupState -PropertyName 'ExistingBuildValidationEnvironment'
                BuildValidationEnvironmentName     = [string](Get-OptionalObjectPropertyValue -InputObject $ExistingSetupState -PropertyName 'BuildValidationEnvironmentName')
                BuildValidationBaselineRelease     = $legacyBaselineRelease
            }
        )
    }

    return @($branchMappings | Sort-Object BranchName -Unique)
}

function New-AzDoBranchSetupState {
    # Keep discovery separate from later interactive DEV configuration and publication plan.
    # Drop null deployment entries but preserve the supplied environment objects and order.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BranchName,
        [Parameter()][object]$ExistingDevEnvironment,
        [Parameter()][array]$DeploymentEnvironments,
        [Parameter()][object]$PublishPlan,
        [Parameter()][object]$ExistingBuildValidationEnvironment,
        [Parameter()][AllowEmptyString()][string]$BuildValidationEnvironmentName = '',
        [Parameter()][AllowEmptyString()][string]$BuildValidationBaselineRelease = ''
    )

    $normalizedDeploymentEnvironments = @($DeploymentEnvironments | Where-Object { $null -ne $_ })

    return [pscustomobject]@{
        BranchName                  = $BranchName
        ExistingDevEnvironment      = $ExistingDevEnvironment
        DevEnvironmentConfiguration = $null
        DeploymentEnvironments      = $normalizedDeploymentEnvironments
        ExistingBuildValidationEnvironment = $ExistingBuildValidationEnvironment
        BuildValidationEnvironmentName = $BuildValidationEnvironmentName
        BuildValidationEnvironmentConfiguration = $ExistingBuildValidationEnvironment
        BuildValidationBaselineRelease = $BuildValidationBaselineRelease
        BuildValidationEnabled = -not [string]::IsNullOrWhiteSpace($BuildValidationEnvironmentName)
        PublishPlan                 = $PublishPlan
    }
}

function Get-AzDoEnvironmentConfiguration {
    # Collect credentials/ownership, normalize URL and return setup metadata with DEV/BUILD
    # role flags. This prompts (and may create credentials), but does not provision Dataverse roles.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][string]$EnvironmentUrl,
        [Parameter()][string]$FriendlyName,
        [Parameter()][array]$ExistingCredentials,
        [Parameter()][array]$ExistingServiceAccounts,
        [Parameter()][string]$TenantId,
        [Parameter()][string]$ProjectName,
        [Parameter()][bool]$UseAlm4DataverseExtension = $true,
        [Parameter()][object]$ExistingCredential,
        [Parameter()][string]$ExistingServiceAccountUPN,
        [Parameter()][bool]$IsDevelopmentEnvironment = $false,
        [Parameter()][bool]$IsBuildValidationEnvironment = $false
    )

    $creds = Get-PowerPlatformSCCredential `
        -ExistingCredentials $ExistingCredentials `
        -TenantId $TenantId `
        -ProjectName $ProjectName `
        -EnvironmentName $EnvironmentName `
        -UseAlm4DataverseExtension $UseAlm4DataverseExtension `
        -ExistingCredential $ExistingCredential

    $serviceAccountUPN = Get-DataverseServiceAccountUPN `
        -ExistingServiceAccounts $ExistingServiceAccounts `
        -EnvironmentName $EnvironmentName `
        -ExistingValue $ExistingServiceAccountUPN

    return [pscustomobject]@{
        ShortName            = $EnvironmentName
        FriendlyName         = $(if ([string]::IsNullOrWhiteSpace($FriendlyName)) { $EnvironmentName } else { $FriendlyName })
        Url                  = (ConvertTo-NormalizedEnvironmentUrl -Url $EnvironmentUrl)
        Credentials          = $creds
        ServiceAccountUPN    = $serviceAccountUPN
        IsDevelopmentEnvironment = $IsDevelopmentEnvironment
        IsBuildValidationEnvironment = $IsBuildValidationEnvironment
    }
}

function Invoke-AzDoEnvironmentConfigurationWizard {
    <#
    .SYNOPSIS
        Edits an Azure DevOps Dataverse target through the shared detail menu.
    .DESCRIPTION
        Dataverse selection, editable target names, credentials, service-account
        ownership, and an optional BUILD baseline are separate sequential steps.
        Changing the Dataverse environment invalidates credentials and ownership
        selected for a different URL.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'DataverseEnvironmentPrompt', Justification = 'Captured by the nested Dataverse-selection callback.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ExcludedUrl', Justification = 'Captured by the nested Dataverse-selection callback.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ExistingCredentials', Justification = 'Captured by the nested credential callback.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ExistingServiceAccounts', Justification = 'Captured by the nested service-account callback.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'TenantId', Justification = 'Captured by nested configuration callbacks.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ProjectName', Justification = 'Captured by nested configuration callbacks.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'UseAlm4DataverseExtension', Justification = 'Captured by the nested credential callback.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'PromptGuidanceLines', Justification = 'Captured by the nested Dataverse-selection callback.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'PromptGuidanceDocRelativePath', Justification = 'Captured by the nested Dataverse-selection callback.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'PromptGuidanceRef', Justification = 'Captured by the nested Dataverse-selection callback.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$DataverseEnvironmentPrompt,
        [Parameter()][AllowNull()][object]$InitialConfiguration,
        [Parameter()][AllowEmptyString()][string]$InitialTargetName = '',
        [Parameter()][string]$TargetNameStepName = 'Environment name',
        [Parameter()][scriptblock]$SelectTargetNameAction,
        [Parameter()][switch]$TargetNameIsFixed,
        [Parameter()][scriptblock]$SelectBaselineAction,
        [Parameter()][AllowEmptyString()][string]$InitialBaselineRelease = '',
        [Parameter()][switch]$BaselineConfigured,
        [Parameter()][AllowEmptyString()][string]$ExcludedUrl = '',
        [Parameter()][array]$ExistingCredentials,
        [Parameter()][array]$ExistingServiceAccounts,
        [Parameter()][string]$TenantId,
        [Parameter()][string]$ProjectName,
        [Parameter()][bool]$UseAlm4DataverseExtension = $true,
        [Parameter()][bool]$IsDevelopmentEnvironment = $false,
        [Parameter()][bool]$IsBuildValidationEnvironment = $false,
        [Parameter()][string[]]$PromptGuidanceLines,
        [Parameter()][string]$PromptGuidanceDocRelativePath,
        [Parameter()][string]$PromptGuidanceRef,
        [Parameter()][string]$HelpDocRelativePath,
        [Parameter()][string]$HelpRef
    )

    $selectDataverseEnvironment = {
        param($environmentState)
        $selectedEnvironment = Select-DataverseEnvironment `
            -Prompt $DataverseEnvironmentPrompt `
            -ExcludeUrl $ExcludedUrl `
            -PreferredUrl $environmentState.Url `
            -PromptGuidanceLines $PromptGuidanceLines `
            -PromptGuidanceDocRelativePath $PromptGuidanceDocRelativePath `
            -PromptGuidanceRef $PromptGuidanceRef
        if (-not $selectedEnvironment) {
            return $null
        }

        return [pscustomobject]@{
            FriendlyName = [string]$selectedEnvironment.FriendlyName
            Url = ConvertTo-NormalizedEnvironmentUrl -Url ([string]$selectedEnvironment.Endpoints['WebApplication'])
        }
    }.GetNewClosure()
    $selectCredentials = {
        param($environmentState)
        Get-PowerPlatformSCCredential `
            -ExistingCredentials $ExistingCredentials `
            -TenantId $TenantId `
            -ProjectName $ProjectName `
            -EnvironmentName $environmentState.ShortName `
            -UseAlm4DataverseExtension $UseAlm4DataverseExtension `
            -ExistingCredential $environmentState.Credentials
    }.GetNewClosure()
    $selectServiceAccount = {
        param($environmentState)
        Get-DataverseServiceAccountUPN `
            -ExistingServiceAccounts $ExistingServiceAccounts `
            -EnvironmentName $environmentState.ShortName `
            -ExistingValue $environmentState.ServiceAccountUPN
    }.GetNewClosure()

    $environmentConfiguration = Invoke-SetupEnvironmentConfigurationWizard `
        -Title $Title `
        -SelectDataverseEnvironmentAction $selectDataverseEnvironment `
        -InitialConfiguration $InitialConfiguration `
        -InitialTargetName $InitialTargetName `
        -SelectTargetNameAction $SelectTargetNameAction `
        -TargetNameStepName $TargetNameStepName `
        -TargetNameIsFixed:$TargetNameIsFixed `
        -SelectCredentialsAction $selectCredentials `
        -SelectServiceAccountAction $selectServiceAccount `
        -SelectBaselineAction $SelectBaselineAction `
        -InitialBaselineRelease $InitialBaselineRelease `
        -BaselineConfigured:$BaselineConfigured `
        -HelpDocRelativePath $HelpDocRelativePath `
        -HelpRef $HelpRef
    if ($null -eq $environmentConfiguration) {
        return $null
    }

    $resolvedFriendlyName = if ([string]::IsNullOrWhiteSpace($environmentConfiguration.FriendlyName)) {
        [string]$environmentConfiguration.ShortName
    }
    else {
        [string]$environmentConfiguration.FriendlyName
    }
    $result = [pscustomobject]@{
        ShortName = [string]$environmentConfiguration.ShortName
        FriendlyName = $resolvedFriendlyName
        Url = [string]$environmentConfiguration.Url
        Credentials = $environmentConfiguration.Credentials
        ServiceAccountUPN = [string]$environmentConfiguration.ServiceAccountUPN
        IsDevelopmentEnvironment = $IsDevelopmentEnvironment
        IsBuildValidationEnvironment = $IsBuildValidationEnvironment
        ConfigurationPending = $false
    }
    if ($SelectBaselineAction) {
        $result | Add-Member -NotePropertyName BaselineRelease -NotePropertyValue ([string]$environmentConfiguration.BaselineRelease)
    }

    return $result
}

function Get-DataverseEnvironmentsSelection {
    <#
    .SYNOPSIS
    Edits ordered deployment targets and completes missing URL, credential and ownership metadata.
    .NOTES
    InitialEnvironments and branch YAML can seed the editor. Add/edit callbacks receive
    the current selections (edit also receives the target and index); null leaves that
    action unchanged. Duplicate URL/short-name checks exclude the edited row.
    ExcludedUrl protects DEV from deployment selection, including final completion.
    Returns completed targets in promotion order; credentials/accounts become reusable
    within this selection.     Cancelling a required pre-existing environment resolution throws; cancelling a
    new or optional edit leaves the current selection unchanged.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject], [object[]])]
    param(
        [Parameter(Mandatory = $false)][string]$ExcludedUrl,
        [Parameter()][string]$RepoRoot,
        [Parameter()][string]$Branch,
        [Parameter()][string]$ProjectName,
        [Parameter()][array]$InitialEnvironments,
        [Parameter()][array]$ExistingCredentials,
        [Parameter()][array]$ExistingServiceAccounts,
        [Parameter()][string]$TenantId,
        [Parameter()][bool]$UseAlm4DataverseExtension = $true,
        [Parameter()][string]$InitialEditEnvironmentName
    )

    $selectedEnvironments = @($InitialEnvironments | Where-Object { $null -ne $_ })
    $credentialsForReuse = @($ExistingCredentials | Where-Object { $null -ne $_ })
    $serviceAccountsForReuse = @($ExistingServiceAccounts)
    $normalizedExcludedUrl = ConvertTo-NormalizedEnvironmentUrl -Url $ExcludedUrl

    if (-not [string]::IsNullOrWhiteSpace($RepoRoot) -and -not [string]::IsNullOrWhiteSpace($Branch) -and $ProjectName) {
        $existingNames = @(Get-ExistingEnvironmentsFromWorkingTree -RepoRoot $RepoRoot -Branch $Branch)

        if ($existingNames.Count -gt 0) {
            Write-Host "Found $($existingNames.Count) deployment environment(s) in alm-config.psd1. Pre-populating the deployment environment table..." -ForegroundColor Cyan

            $selectedEnvironments += @(Invoke-WithSpectreStatus -Status 'Inspecting existing deployment environment configuration...' -ScriptBlock {
                $resolvedExistingEnvironments = @()

                foreach ($name in $existingNames) {
                    if ($selectedEnvironments | Where-Object { $_.ShortName -ieq $name }) {
                        continue
                    }

                    $existingEnvironmentState = Get-AzDoExistingEnvironmentState -ProjectName $ProjectName -EnvironmentName $name -TenantId $TenantId

                    $existingEnvironmentUrl = ConvertTo-NormalizedEnvironmentUrl -Url $existingEnvironmentState.Url
                    if (-not [string]::IsNullOrWhiteSpace($normalizedExcludedUrl) -and $existingEnvironmentUrl -eq $normalizedExcludedUrl) {
                        Write-Warning "Skipping existing deployment stage '$name' because it points at the selected DEV environment URL."
                        continue
                    }

                    $resolvedExistingEnvironments += [pscustomobject]@{
                        ShortName            = $name
                        FriendlyName         = $(if (-not [string]::IsNullOrWhiteSpace($existingEnvironmentState.FriendlyName)) { $existingEnvironmentState.FriendlyName } else { "$name (Existing)" })
                        Url                  = $existingEnvironmentUrl
                        Credentials          = $existingEnvironmentState.Credentials
                        ServiceAccountUPN    = $existingEnvironmentState.ServiceAccountUPN
                        IsDevelopmentEnvironment = $false
                        ConfigurationPending = (($null -eq $existingEnvironmentState.Credentials) -or [string]::IsNullOrWhiteSpace($existingEnvironmentState.ServiceAccountUPN))
                    }
                }

                return @($resolvedExistingEnvironments)
            })
        }
    }

    $resolvedHeading = if ([string]::IsNullOrWhiteSpace($Branch)) { 'Target Deployment Environments' } else { "Target Deployment Environments for branch '$Branch'" }

    $selectedEnvironments = @(Select-ConfiguredDeploymentEnvironment `
        -InitialEnvironments $selectedEnvironments `
        -InitialEditEnvironmentName $InitialEditEnvironmentName `
        -Heading $resolvedHeading `
        -Title 'Manage deployment environments' `
        -GuidanceLines @(
            'Select each deployment environment together with the credential and service-account ownership that should be used there.',
            'Review URL, auth, and service-account values before continuing because setup applies them to service connections, variable groups, and DEPLOY YAML.',
            'Keep short names stable and the list in promotion order, because that order becomes the generated deployment stage sequence.'
        ) `
        -DocRelativePath 'docs/setup/azdo-manual-setup.md' `
        -Ref $ALM4DataverseRef `
        -AddEnvironmentScriptBlock {
            param($currentSelections)

            $currentCredentials = @($ExistingCredentials)
            $currentCredentials += @($currentSelections | ForEach-Object { $_.Credentials } | Where-Object { $null -ne $_ })
            $currentServiceAccounts = @($ExistingServiceAccounts)
            $currentServiceAccounts += @($currentSelections | ForEach-Object { $_.ServiceAccountUPN } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

            $selectTargetName = {
                param($environmentState)
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
                if ($currentSelections | Where-Object { $_.Url -ieq $environmentState.Url }) {
                    Write-Host "An environment with Url '$($environmentState.Url)' is already selected." -ForegroundColor Red
                    Request-SetupWizardBack
                }
                if ($currentSelections | Where-Object { $_.ShortName -ieq $shortName }) {
                    Write-Host "An environment with short name '$shortName' is already selected (case-insensitive match)." -ForegroundColor Red
                    Request-SetupWizardBack
                }

                return $shortName
            }.GetNewClosure()

            return Invoke-AzDoEnvironmentConfigurationWizard `
                -Title 'Configure a deployment environment' `
                -DataverseEnvironmentPrompt 'Select a deployment environment' `
                -InitialTargetName '' `
                -TargetNameStepName 'Short name' `
                -SelectTargetNameAction $selectTargetName `
                -ExistingCredentials $currentCredentials `
                -ExistingServiceAccounts $currentServiceAccounts `
                -TenantId $TenantId `
                -ProjectName $ProjectName `
                -UseAlm4DataverseExtension $UseAlm4DataverseExtension `
                -ExcludedUrl $ExcludedUrl `
                -PromptGuidanceLines @(
                    'Select the Dataverse environment that this deployment stage should target.',
                    'The branch DEV environment cannot be selected as a deployment target.'
                ) `
                -PromptGuidanceDocRelativePath 'docs/setup/azdo-automated-setup.md' `
                -PromptGuidanceRef $ALM4DataverseRef `
                -HelpDocRelativePath 'docs/setup/azdo-automated-setup.md' `
                -HelpRef $ALM4DataverseRef
        } `
        -EditEnvironmentScriptBlock {
            param($currentSelections, $environmentToEdit, $environmentIndex)

            $otherSelections = @()
            for ($selectionIndex = 0; $selectionIndex -lt $currentSelections.Count; $selectionIndex++) {
                if ($selectionIndex -ne $environmentIndex) {
                    $otherSelections += $currentSelections[$selectionIndex]
                }
            }

            $currentCredentials = @($ExistingCredentials)
            $currentCredentials += @($otherSelections | ForEach-Object { $_.Credentials } | Where-Object { $null -ne $_ })
            $currentServiceAccounts = @($ExistingServiceAccounts)
            $currentServiceAccounts += @($otherSelections | ForEach-Object { $_.ServiceAccountUPN } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

            $selectTargetName = {
                param($environmentState)
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
                if ($otherSelections | Where-Object { $_.Url -ieq $environmentState.Url }) {
                    Write-Host "An environment with Url '$($environmentState.Url)' is already selected." -ForegroundColor Red
                    Request-SetupWizardBack
                }
                if ($otherSelections | Where-Object { $_.ShortName -ieq $shortName }) {
                    Write-Host "An environment with short name '$shortName' is already selected (case-insensitive match)." -ForegroundColor Red
                    Request-SetupWizardBack
                }

                return $shortName
            }.GetNewClosure()

            return Invoke-AzDoEnvironmentConfigurationWizard `
                -Title "Configure deployment environment '$($environmentToEdit.ShortName)'" `
                -DataverseEnvironmentPrompt "Select the deployment environment for '$($environmentToEdit.ShortName)'" `
                -InitialConfiguration $environmentToEdit `
                -TargetNameStepName 'Short name' `
                -SelectTargetNameAction $selectTargetName `
                -ExistingCredentials $currentCredentials `
                -ExistingServiceAccounts $currentServiceAccounts `
                -TenantId $TenantId `
                -ProjectName $ProjectName `
                -UseAlm4DataverseExtension $UseAlm4DataverseExtension `
                -ExcludedUrl $ExcludedUrl `
                -PromptGuidanceLines @(
                    'Choose the Dataverse target for this deployment stage.',
                    'Changing the target invalidates credentials and service-account ownership selected for the previous environment.'
                ) `
                -PromptGuidanceDocRelativePath 'docs/setup/azdo-automated-setup.md' `
                -PromptGuidanceRef $ALM4DataverseRef `
                -HelpDocRelativePath 'docs/setup/azdo-automated-setup.md' `
                -HelpRef $ALM4DataverseRef
        })

    $completedEnvironments = @()
    for ($selectedEnvironmentIndex = 0; $selectedEnvironmentIndex -lt $selectedEnvironments.Count; $selectedEnvironmentIndex++) {
        $selectedEnvironment = $selectedEnvironments[$selectedEnvironmentIndex]
        if ([string]::IsNullOrWhiteSpace($selectedEnvironment.ShortName)) {
            continue
        }

        $resolvedEnvironmentUrl = ConvertTo-NormalizedEnvironmentUrl -Url $selectedEnvironment.Url
        $resolvedFriendlyName = if ([string]::IsNullOrWhiteSpace($selectedEnvironment.FriendlyName)) { $selectedEnvironment.ShortName } else { $selectedEnvironment.FriendlyName }

        $needsConfiguration = (
            ($selectedEnvironment.PSObject.Properties.Name -contains 'ConfigurationPending' -and $selectedEnvironment.ConfigurationPending) -or
            [string]::IsNullOrWhiteSpace($resolvedEnvironmentUrl) -or
            ($null -eq $selectedEnvironment.Credentials) -or
            [string]::IsNullOrWhiteSpace($selectedEnvironment.ServiceAccountUPN)
        )

        if ($needsConfiguration) {
            Write-Host "Completing configuration for existing deployment environment '$($selectedEnvironment.ShortName)'..." -ForegroundColor Yellow
            $otherSelections = @()
            for ($selectionIndex = 0; $selectionIndex -lt $selectedEnvironments.Count; $selectionIndex++) {
                if ($selectionIndex -ne $selectedEnvironmentIndex) {
                    $otherSelections += $selectedEnvironments[$selectionIndex]
                }
            }
            $selectTargetName = {
                param($environmentState)
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
                if ($otherSelections | Where-Object { $_.Url -ieq $environmentState.Url }) {
                    Write-Host "An environment with Url '$($environmentState.Url)' is already selected." -ForegroundColor Red
                    Request-SetupWizardBack
                }
                if ($otherSelections | Where-Object { $_.ShortName -ieq $shortName }) {
                    Write-Host "An environment with short name '$shortName' is already selected (case-insensitive match)." -ForegroundColor Red
                    Request-SetupWizardBack
                }

                return $shortName
            }.GetNewClosure()
            $completedEnvironment = Invoke-AzDoEnvironmentConfigurationWizard `
                -Title "Configure deployment environment '$($selectedEnvironment.ShortName)'" `
                -DataverseEnvironmentPrompt "Resolve the Dataverse environment for existing deployment stage '$($selectedEnvironment.ShortName)'" `
                -InitialConfiguration $selectedEnvironment `
                -TargetNameStepName 'Short name' `
                -SelectTargetNameAction $selectTargetName `
                -ExistingCredentials $credentialsForReuse `
                -ExistingServiceAccounts $serviceAccountsForReuse `
                -TenantId $TenantId `
                -ProjectName $ProjectName `
                -UseAlm4DataverseExtension $UseAlm4DataverseExtension `
                -ExcludedUrl $ExcludedUrl `
                -PromptGuidanceLines @(
                    'Resolve the Dataverse target for this existing deployment stage.',
                    'Complete credentials and service-account ownership before continuing.'
                ) `
                -PromptGuidanceDocRelativePath 'docs/setup/azdo-automated-setup.md' `
                -PromptGuidanceRef $ALM4DataverseRef `
                -HelpDocRelativePath 'docs/setup/azdo-automated-setup.md' `
                -HelpRef $ALM4DataverseRef
            if ($null -eq $completedEnvironment) {
                throw "Configuration for deployment environment '$($selectedEnvironment.ShortName)' is incomplete."
            }
        }
        else {
            $completedEnvironment = [pscustomobject]@{
                ShortName         = $selectedEnvironment.ShortName
                FriendlyName      = $resolvedFriendlyName
                Url               = $resolvedEnvironmentUrl
                Credentials       = $selectedEnvironment.Credentials
                ServiceAccountUPN = $selectedEnvironment.ServiceAccountUPN
                IsDevelopmentEnvironment = $false
            }
        }

        $resolvedEnvironmentUrl = ConvertTo-NormalizedEnvironmentUrl -Url $completedEnvironment.Url
        if (-not [string]::IsNullOrWhiteSpace($normalizedExcludedUrl) -and $resolvedEnvironmentUrl -eq $normalizedExcludedUrl) {
            Write-Warning "Skipping deployment environment '$($completedEnvironment.ShortName)' because it points at the selected DEV environment URL."
            continue
        }
        if ([string]::IsNullOrWhiteSpace($resolvedEnvironmentUrl) -or
            $null -eq $completedEnvironment.Credentials -or
            [string]::IsNullOrWhiteSpace($completedEnvironment.ServiceAccountUPN)) {
            throw "Deployment environment '$($completedEnvironment.ShortName)' is missing a Dataverse URL, credential, or service account."
        }

        $completedEnvironments += $completedEnvironment
        if ($completedEnvironment.Credentials -and -not ($credentialsForReuse | Where-Object { $_.ApplicationId -eq $completedEnvironment.Credentials.ApplicationId -and $_.TenantId -eq $completedEnvironment.Credentials.TenantId })) {
            $credentialsForReuse += $completedEnvironment.Credentials
        }
        if (-not [string]::IsNullOrWhiteSpace($completedEnvironment.ServiceAccountUPN) -and $serviceAccountsForReuse -notcontains $completedEnvironment.ServiceAccountUPN) {
            $serviceAccountsForReuse += $completedEnvironment.ServiceAccountUPN
        }
    }

    return @($completedEnvironments)
}
