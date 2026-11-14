function Set-AzDoEnvironmentConfiguration {
    <#
    .SYNOPSIS
    Applies selected credentials, Dataverse roles, variable-group checks and pipeline access.
    .NOTES
    DEV authorizes EXPORT; other roles use DeployPipeline (BUILD is passed there for
    validation). Existing-connection markers skip endpoint recreation and federation.
    WIF issuer/subject must come from Azure DevOps before adding the Entra credential;
    missing federation metadata warns for manual completion.
    All groups get locking; only non-DEV/non-BUILD targets request deployment approval.
    Example CR/EV variables are scaffolds, not discovered connection IDs or values.
    Honors ShouldProcess at entry; provisioning is not transactional.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][object]$EnvironmentConfiguration,
        [Parameter(Mandatory)][string]$OrganizationName,
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter()][object]$ExportPipeline,
        [Parameter()][object]$DeployPipeline
    )

    if (-not $PSCmdlet.ShouldProcess("$OrganizationName/$ProjectName", 'Configure Azure DevOps deployment environment')) { return }

    $creds = $EnvironmentConfiguration.Credentials
    $serviceAccountUPN = $EnvironmentConfiguration.ServiceAccountUPN
    $isDevelopmentEnvironment = $false
    if ($EnvironmentConfiguration.PSObject.Properties.Name -contains 'IsDevelopmentEnvironment') {
        $isDevelopmentEnvironment = [bool]$EnvironmentConfiguration.IsDevelopmentEnvironment
    }
    $isBuildValidationEnvironment = $false
    if ($EnvironmentConfiguration.PSObject.Properties.Name -contains 'IsBuildValidationEnvironment') {
        $isBuildValidationEnvironment = [bool]$EnvironmentConfiguration.IsBuildValidationEnvironment
    }

    $pipelineForPermissions = if ($isDevelopmentEnvironment) { $ExportPipeline } else { $DeployPipeline }

    $endpoint = $null
    if (-not $creds.IsExistingServiceConnection) {
        $endpointParams = @{
            ProjectName         = $ProjectName
            ServiceEndpointName = $EnvironmentConfiguration.ShortName
            EnvironmentUrl      = $EnvironmentConfiguration.Url
            ApplicationId       = $creds.ApplicationId
            TenantId            = $creds.TenantId
        }

        if ($creds.AuthType -eq 'WIF') {
            $endpointParams.AuthType = 'WIF'
        }
        else {
            $endpointParams.ClientSecret = $creds.ClientSecret
            $endpointParams.AuthType = 'Secret'
        }

        $endpoint = Initialize-AzDoServiceEndpoint @endpointParams

        if ($creds.AuthType -eq 'WIF') {
            $wifIssuer = $endpoint.authorization.parameters.workloadIdentityFederationIssuer
            $wifSubject = $endpoint.authorization.parameters.workloadIdentityFederationSubject
            if ($wifIssuer -and $wifSubject) {
                $appObjectId = $creds.ApplicationObjectId
                if (-not $appObjectId) {
                    $graphToken = Get-AuthToken -ResourceUrl 'https://graph.microsoft.com' -TenantId $creds.TenantId
                    $gHeaders = @{ Authorization = "Bearer $($graphToken.AccessToken)" }
                    $gUri = "https://graph.microsoft.com/v1.0/applications?`$filter=appId eq '$($creds.ApplicationId)'&`$select=id,appId"
                    $gResult = Invoke-RestMethod -Uri $gUri -Headers $gHeaders -Method Get
                    if ($gResult.value.Count -gt 0) { $appObjectId = $gResult.value[0].id }
                }
                if ($appObjectId) {
                    $safeOrgName = ConvertTo-UrlSafeName -Name $OrganizationName
                    $safeProjectName = ConvertTo-UrlSafeName -Name $ProjectName
                    $safeSCName = ConvertTo-UrlSafeName -Name $EnvironmentConfiguration.ShortName
                    [void](Add-EntraIdFederatedCredential `
                        -ApplicationObjectId $appObjectId `
                        -TenantId $creds.TenantId `
                        -Issuer $wifIssuer `
                        -Subject $wifSubject `
                        -CredentialName "AzDO-$safeOrgName-$safeProjectName-$safeSCName")
                }
                else {
                    Write-Warning 'Could not determine Application Object ID. Federated credential not added - add it manually in Entra ID.'
                }
            }
            else {
                Write-Warning 'Service connection does not expose WIF issuer/subject properties. Federated credential not added - add it manually in Entra ID.'
            }
        }
    }
    else {
        $endpoints = @(Get-VSTeamServiceEndpoint -ProjectName $ProjectName -ErrorAction SilentlyContinue)
        $endpoint = $endpoints | Where-Object { $_.name -eq $EnvironmentConfiguration.ShortName } | Select-Object -First 1
    }

    if ($endpoint -and $endpoint.id -and $pipelineForPermissions) {
        Initialize-AzDoPipelinePermission -Organization $OrganizationName -Project $ProjectName -ResourceType 'endpoint' -ResourceId $endpoint.id -PipelineId $pipelineForPermissions.id
    }

    if (-not $isDevelopmentEnvironment) {
        $azDoEnv = Initialize-AzDoEnvironment -Organization $OrganizationName -Project $ProjectName -EnvironmentName $EnvironmentConfiguration.ShortName -Description "Deployment environment for $($EnvironmentConfiguration.ShortName)"
        if ($azDoEnv -and $DeployPipeline) {
            Initialize-AzDoPipelinePermission -Organization $OrganizationName -Project $ProjectName -ResourceType 'environment' -ResourceId $azDoEnv.id -PipelineId $DeployPipeline.id
        }
    }

    Initialize-DataverseApplicationUser -EnvironmentUrl $EnvironmentConfiguration.Url -ApplicationId $creds.ApplicationId -TenantId $creds.TenantId
    Initialize-DataverseServiceAccountUser -EnvironmentUrl $EnvironmentConfiguration.Url -ServiceAccountUPN $serviceAccountUPN -TenantId $creds.TenantId

    $groupName = "Environment-$($EnvironmentConfiguration.ShortName)"
    $variables = @{
        'DATAVERSECONNREF_example_uniquename' = 'connectionid'
        'DATAVERSEENVVAR_example_uniquename'  = 'value'
        'DataverseServiceAccountUPN' = $serviceAccountUPN
    }

    $varGroup = Initialize-AzDoVariableGroup `
        -Organization $OrganizationName `
        -Project $ProjectName `
        -GroupName $groupName `
        -Variables $variables `
        -RequireDeploymentApproval (-not $isDevelopmentEnvironment -and -not $isBuildValidationEnvironment)

    if ($varGroup -and $varGroup.id -and $pipelineForPermissions) {
        Initialize-AzDoPipelinePermission -Organization $OrganizationName -Project $ProjectName -ResourceType 'variablegroup' -ResourceId $varGroup.id -PipelineId $pipelineForPermissions.id
    }
}

function Get-AzDoSetupArtifactsPreview {
    <#
    .SYNOPSIS
    Generates Azure DevOps setup files and returns repository changes for review.
    .DESCRIPTION
    Uses the same artifact generator as publication inside an isolated temporary tree.
    The selected repository is never modified.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$CopyRoot,
        [Parameter(Mandatory)][object]$MainRepo,
        [Parameter(Mandatory)][string]$SharedRepositoryName,
        [Parameter(Mandatory)][string]$SharedRepositoryRef,
        [Parameter(Mandatory)][bool]$UseAlm4DataverseExtension,
        [Parameter(Mandatory)][array]$BranchStates,
        [Parameter()][System.Collections.IDictionary]$ProviderOptions = @{},
        [Parameter()][AllowNull()][object]$SolutionData
    )

    $settings = Get-AlmSetupConfiguration `
        -Provider azDO `
        -Repository $SharedRepositoryName `
        -Ref $SharedRepositoryRef `
        -BranchStates $BranchStates `
        -ProviderOptions $ProviderOptions
    $buildValidationEnvironments = Get-AlmSetupBuildValidationEnvironmentMap -BranchStates $BranchStates
    $solutions = if ($SolutionData) { @($SolutionData.Solutions) } else { $null }
    $previewRelativePaths = @(Get-ChildItem -LiteralPath $CopyRoot -Force -ErrorAction Stop | ForEach-Object { [string]$_.Name })
    if ('alm-config.psd1' -notin $previewRelativePaths) {
        $previewRelativePaths += 'alm-config.psd1'
    }
    $previewRoot = New-SetupPreviewRoot -BaseRoot $RepoRoot -RelativePaths $previewRelativePaths

    try {
        foreach ($branchState in $BranchStates) {
            Invoke-AzDoSetupArtifactGeneration `
                -RepoRoot $previewRoot `
                -CopyRoot $CopyRoot `
                -MainRepo $MainRepo `
                -SharedRepositoryName $SharedRepositoryName `
                -SharedRepositoryRef $SharedRepositoryRef `
                -Branch ([string]$branchState.BranchName) `
                -UseAlm4DataverseExtension $UseAlm4DataverseExtension `
                -Solutions $solutions `
                -DeploymentEnvironments @($branchState.DeploymentEnvironments) `
                -BuildValidationEnabled ($buildValidationEnvironments.Count -gt 0) `
                -BuildValidationEnvironments $buildValidationEnvironments `
                -SetupSettings $settings
        }

        $configPath = Join-Path $previewRoot 'alm-config.psd1'
        if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
            throw 'The generated alm-config.psd1 preview was not created.'
        }

        $pipelineRoot = Join-Path $previewRoot 'pipelines'
        if (-not (Test-Path -LiteralPath $pipelineRoot -PathType Container)) {
            throw 'The generated Azure DevOps pipeline preview directory was not created.'
        }

        return [pscustomobject]@{
            FileChanges = @(Get-SetupRepositoryFileChange -RepositoryRoot $RepoRoot -PreviewRoot $previewRoot -RelativePaths $previewRelativePaths)
        }
    }
    finally {
        Remove-Item -LiteralPath $previewRoot -Recurse -Force -ErrorAction Stop
    }
}

function Invoke-AzDoBranchAwareSetupApply {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'MainRepoWorkingRoot', Justification = 'Captured by the nested branch publication script block.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'MainRepo', Justification = 'Captured by the nested branch publication script block.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'DefaultBranch', Justification = 'Captured by the nested branch publication script block.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'AccessToken', Justification = 'Captured by the nested branch publication script block.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'CopyRoot', Justification = 'Captured by the nested branch publication script block.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'UseAlm4DataverseExtension', Justification = 'Captured by the nested branch publication script block.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MainRepoWorkingRoot,
        [Parameter(Mandatory)][object]$MainRepo,
        [Parameter(Mandatory)][string]$DefaultBranch,
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][string]$CopyRoot,
        [Parameter(Mandatory)][string]$SharedRepositoryName,
        [Parameter(Mandatory)][string]$SharedRepositoryRef,
        [Parameter(Mandatory)][bool]$UseAlm4DataverseExtension,
        [Parameter(Mandatory)][object]$WizardState,
        [Parameter()][System.Collections.IDictionary]$ProviderOptions = @{}
    )

    $branchStates = @($WizardState.BranchStates)
    $buildValidationEnvironments = Get-AlmSetupBuildValidationEnvironmentMap -BranchStates $branchStates
    $buildValidationEnabled = $buildValidationEnvironments.Count -gt 0
    $buildValidationEnvironmentName = if ($buildValidationEnvironments.Count -eq 1) {
        [string]@($buildValidationEnvironments.Values)[0]
    }
    else {
        ''
    }
    $setupSettings = Get-AlmSetupConfiguration `
        -Provider azDO `
        -Repository $SharedRepositoryName `
        -Ref $SharedRepositoryRef `
        -BranchStates $branchStates `
        -ProviderOptions $ProviderOptions
    $solutions = if ($WizardState.SolutionData) { @($WizardState.SolutionData.Solutions) } else { $null }
    $publishResults = @()

    foreach ($branchState in $branchStates) {
        if (-not $branchState.PublishPlan) {
            throw "No repository publish plan was recorded for branch '$($branchState.BranchName)'. Revisit Configure branches before applying."
        }

        $branchName = [string]$branchState.BranchName
        $publishResult = Invoke-WithErrorHandling `
            -OperationName "Publishing repository changes for branch '$branchName'" `
            -StatusMessage "Publishing repository changes for branch '$branchName'..." `
            -CaptureOutputInPanel `
            -ScriptBlock {
                Publish-AzDoBranchSetupChange `
                    -RepoRoot $MainRepoWorkingRoot `
                    -ConfiguredBranch $branchName `
                    -PublishPlan $branchState.PublishPlan `
                    -DefaultBranch $DefaultBranch `
                    -AccessToken $AccessToken `
                    -Repository $MainRepo `
                    -CopyRoot $CopyRoot `
                    -SharedRepositoryName $SharedRepositoryName `
                    -SharedRepositoryRef $SharedRepositoryRef `
                    -UseAlm4DataverseExtension $UseAlm4DataverseExtension `
                    -Solutions $solutions `
                    -DeploymentEnvironments @($branchState.DeploymentEnvironments) `
                    -BuildValidationEnabled $buildValidationEnabled `
                    -BuildValidationEnvironmentName $buildValidationEnvironmentName `
                    -BuildValidationEnvironments $buildValidationEnvironments `
                    -SetupSettings $setupSettings
            }
        $publishResults += $publishResult
    }

    $enabledBuildBranches = @($branchStates | Where-Object { $_.BuildValidationEnabled -and $_.BuildValidationEnvironmentConfiguration })
    return [pscustomobject]@{
        BranchStates                              = $branchStates
        SolutionData                              = $WizardState.SolutionData
        SolutionSourceBranch                      = $WizardState.SolutionSourceBranch
        BuildValidationEnabled                    = $buildValidationEnabled
        BuildValidationEnvironmentName            = $buildValidationEnvironmentName
        BuildValidationBaselineRelease            = $(if ($enabledBuildBranches.Count -eq 1) { [string]$enabledBuildBranches[0].BuildValidationBaselineRelease } else { '' })
        BuildValidationEnvironmentConfiguration   = $(if ($enabledBuildBranches.Count -eq 1) { $enabledBuildBranches[0].BuildValidationEnvironmentConfiguration } else { $null })
        BuildValidationEnvironmentConfigurations   = @($enabledBuildBranches | ForEach-Object { $_.BuildValidationEnvironmentConfiguration })
        PublishResults                            = @($publishResults)
    }
}

function Get-AzDoSetupResourceChange {
    <#
    .SYNOPSIS
    Describes Azure DevOps and Dataverse changes deferred until setup is applied.
    .DESCRIPTION
    The plan contains resource names and settings only; credential values are omitted.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$BranchStates,
        [Parameter(Mandatory)][object]$SelectedProject,
        [Parameter(Mandatory)][object]$MainRepo,
        [Parameter(Mandatory)][string]$SharedRepositoryName
    )

    $changes = [System.Collections.Generic.List[object]]::new()
    $yamlFiles = @(
        'pipelines/BUILD.yml',
        'pipelines/EXPORT.yml',
        'pipelines/IMPORT.yml'
    )
    $yamlFiles += @($BranchStates |
        Where-Object { @($_.DeploymentEnvironments).Count -gt 0 } |
        ForEach-Object { "pipelines/DEPLOY-$($_.BranchName).yml" })
    $pipelineNames = @($yamlFiles | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) } | Select-Object -Unique)

    $projectRepositoryTarget = "$($SelectedProject.Name)/$($MainRepo.Name)"
    $changes.Add([pscustomobject]@{
            Action   = 'Create or retarget'
            Resource = 'Azure DevOps YAML pipelines'
            Target   = $projectRepositoryTarget
            Details  = "Register $($pipelineNames -join ', ') from the generated YAML files."
        })
    $changes.Add([pscustomobject]@{
            Action   = 'Ensure'
            Resource = 'Azure DevOps Build Service permission'
            Target   = $projectRepositoryTarget
            Details  = "Grant the project's Build Service Contribute permission on the main repository."
        })
    $changes.Add([pscustomobject]@{
            Action   = 'Authorize'
            Resource = 'Azure DevOps pipeline repository permissions'
            Target   = "$($MainRepo.Name) and $SharedRepositoryName"
            Details  = "Allow the generated pipelines ($($pipelineNames -join ', ')) to access both repositories."
        })

    $environmentTargets = [System.Collections.Generic.List[object]]::new()
    foreach ($branchState in $BranchStates) {
        if ($branchState.DevEnvironmentConfiguration) {
            $environmentTargets.Add([pscustomobject]@{
                    Role                     = 'DEV'
                    EnvironmentConfiguration = $branchState.DevEnvironmentConfiguration
                    PipelineName             = 'EXPORT'
                    IsDevelopmentEnvironment = $true
                    IsBuildValidationEnvironment = $false
                    RequireDeploymentApproval = $false
                })
        }

        if ($branchState.BuildValidationEnabled -and $branchState.BuildValidationEnvironmentConfiguration) {
            $environmentTargets.Add([pscustomobject]@{
                    Role                     = 'BUILD validation'
                    EnvironmentConfiguration = $branchState.BuildValidationEnvironmentConfiguration
                    PipelineName             = 'BUILD'
                    IsDevelopmentEnvironment = $false
                    IsBuildValidationEnvironment = $true
                    RequireDeploymentApproval = $false
                })
        }

        foreach ($environment in @($branchState.DeploymentEnvironments)) {
            $environmentTargets.Add([pscustomobject]@{
                    Role                     = 'Deployment'
                    EnvironmentConfiguration = $environment
                    PipelineName             = "DEPLOY-$($branchState.BranchName)"
                    IsDevelopmentEnvironment = $false
                    IsBuildValidationEnvironment = $false
                    RequireDeploymentApproval = $true
                })
        }
    }

    foreach ($environmentTarget in $environmentTargets) {
        $environment = $environmentTarget.EnvironmentConfiguration
        $environmentName = [string]$environment.ShortName
        $credentials = Get-OptionalObjectPropertyValue -InputObject $environment -PropertyName 'Credentials'
        if (-not $credentials) {
            throw "No credentials were captured for Azure DevOps environment '$environmentName'."
        }

        $isExistingServiceConnection = [bool](Get-OptionalObjectPropertyValue -InputObject $credentials -PropertyName 'IsExistingServiceConnection')
        $authType = [string](Get-OptionalObjectPropertyValue -InputObject $credentials -PropertyName 'AuthType')
        if ($isExistingServiceConnection) {
            $connectionDetails = 'Reuse the selected existing service connection; do not replace its credentials.'
            $connectionAction = 'Reuse'
        }
        else {
            $connectionDetails = "Create or reconcile the Power Platform service connection using $authType authentication."
            if ($authType -eq 'Secret') {
                $connectionDetails += ' The client-secret value is hidden.'
            }
            $connectionAction = 'Create or reconcile'
        }
        $connectionDetails += " Authorize pipeline '$($environmentTarget.PipelineName)' to use it when that pipeline exists."
        $changes.Add([pscustomobject]@{
                Action   = $connectionAction
                Resource = 'Azure DevOps service connection'
                Target   = "$($SelectedProject.Name)/$environmentName"
                Details  = $connectionDetails
            })

        if (-not $isExistingServiceConnection -and $authType -eq 'WIF') {
            $changes.Add([pscustomobject]@{
                    Action   = 'Create or update'
                    Resource = 'Entra federated identity credential'
                    Target   = "$($SelectedProject.Name)/$environmentName"
                    Details  = 'Use the issuer and subject returned by the Azure DevOps workload-identity service connection.'
                })
        }

        if (-not $environmentTarget.IsDevelopmentEnvironment) {
            $changes.Add([pscustomobject]@{
                    Action   = 'Ensure'
                    Resource = 'Azure DevOps environment'
                    Target   = "$($SelectedProject.Name)/$environmentName"
                    Details  = "Create the environment if missing and authorize pipeline '$($environmentTarget.PipelineName)' when available."
                })
        }

        $variableGroupName = "Environment-$environmentName"
        $variableGroupDetails = 'Create the variable group if missing with the scaffold connection/environment variables and service-account UPN; existing variable values are not overwritten. Ensure an exclusive lock and authorize the relevant pipeline.'
        if ($environmentTarget.RequireDeploymentApproval) {
            $variableGroupDetails += ' Ensure the deployment-approver team and approval check.'
        }
        else {
            $variableGroupDetails += ' Existing approval checks are retained; do not add a new deployment-approval check.'
        }
        $changes.Add([pscustomobject]@{
                Action   = 'Ensure'
                Resource = 'Azure DevOps variable group and checks'
                Target   = "$($SelectedProject.Name)/$variableGroupName"
                Details  = $variableGroupDetails
            })
        $changes.Add([pscustomobject]@{
                Action   = 'Ensure'
                Resource = 'Dataverse application and service-account users'
                Target   = $environmentName
                Details  = 'Ensure both configured users have the System Administrator role.'
            })
    }

    return @($changes.ToArray())
}

function Invoke-AzDoSetupPostApply {
    <#
    .SYNOPSIS
    Registers pipelines, grants resource permissions, and applies environment settings.
    .DESCRIPTION
    Runs as part of the guided Apply action so non-skipped failures return to the menu.
    Existing pipeline and environment helpers reconcile resources when Apply is retried.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'SharedRepository', Justification = 'Captured by nested pipeline-permission callbacks.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'OrganizationName', Justification = 'Captured by nested pipeline-permission and environment callbacks.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$SetupResult,
        [Parameter(Mandatory)][object]$SelectedProject,
        [Parameter(Mandatory)][object]$MainRepo,
        [Parameter(Mandatory)][object]$SharedRepository,
        [Parameter(Mandatory)][string]$OrganizationName
    )

    $branchStates = @($SetupResult.BranchStates)
    $buildValidationEnabled = @($branchStates | Where-Object { $_.BuildValidationEnabled }).Count -gt 0
    $script:yamlFiles = @(
        'pipelines/BUILD.yml',
        'pipelines/EXPORT.yml',
        'pipelines/IMPORT.yml'
    )
    $script:yamlFiles += @($branchStates | Where-Object { @($_.DeploymentEnvironments).Count -gt 0 } | ForEach-Object { "pipelines/DEPLOY-$($_.BranchName).yml" })

    Write-Section -Message 'Ensuring Build Service has Contribute on main repo'
    Invoke-WithErrorHandling `
        -OperationName 'Setting Up Build Service Permissions' `
        -StatusMessage 'Granting build service permissions for the main repository...' `
        -CaptureOutputInPanel `
        -ScriptBlock {
            Initialize-AzDoBuildServiceRepositoryPermission `
                -ProjectName $SelectedProject.Name `
                -ProjectId $SelectedProject.Id `
                -RepositoryId $MainRepo.Id
        } | Out-Null

    Invoke-WithErrorHandling `
        -OperationName 'Creating Pipeline Definitions' `
        -StatusMessage 'Creating Azure DevOps pipeline definitions...' `
        -CaptureOutputInPanel `
        -ScriptBlock {
            Initialize-AzDoMainRepositoryPipeline `
                -Project $SelectedProject.Name `
                -Repository $MainRepo `
                -YamlFiles $script:yamlFiles `
                -FolderPath "\$($MainRepo.Name)"
        } | Out-Null

    Write-Section -Message 'Authorizing pipelines for repositories'
    Invoke-WithErrorHandling `
        -OperationName 'Authorizing Pipelines for Repositories' `
        -AllowSkip `
        -StatusMessage 'Authorizing pipelines to access the required repositories...' `
        -CaptureOutputInPanel `
        -ScriptBlock {
            $pipelineNames = @($script:yamlFiles | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) } | Select-Object -Unique)
            $allPipelines = Get-VSTeamBuildDefinition -ProjectName $SelectedProject.Name
            $pipelineFolder = "\$($MainRepo.Name)"

            foreach ($name in $pipelineNames) {
                $pipeline = $allPipelines | Where-Object { $_.name -eq $name -and $_.path -eq $pipelineFolder } | Select-Object -First 1
                if ($pipeline) {
                    $mainRepoResourceId = "$($SelectedProject.Id).$($MainRepo.Id)"
                    Initialize-AzDoPipelinePermission -Organization $OrganizationName -Project $SelectedProject.Name -ResourceType 'repository' -ResourceId $mainRepoResourceId -PipelineId $pipeline.id

                    $sharedRepoResourceId = "$($SelectedProject.Id).$($SharedRepository.Id)"
                    Initialize-AzDoPipelinePermission -Organization $OrganizationName -Project $SelectedProject.Name -ResourceType 'repository' -ResourceId $sharedRepoResourceId -PipelineId $pipeline.id
                }
            }
        } | Out-Null

    $pipelineFolder = "\$($MainRepo.Name)"
    $allPipelines = Get-VSTeamBuildDefinition -ProjectName $SelectedProject.Name
    $buildPipeline = $allPipelines | Where-Object { $_.name -eq 'BUILD' -and $_.path -eq $pipelineFolder } | Select-Object -First 1
    $exportPipeline = $allPipelines | Where-Object { $_.name -eq 'EXPORT' -and $_.path -eq $pipelineFolder } | Select-Object -First 1
    $deployPipelinesByBranch = @{}
    foreach ($branchState in $branchStates) {
        $deployPipelineName = "DEPLOY-$($branchState.BranchName)"
        $deployPipeline = $allPipelines | Where-Object { $_.name -eq $deployPipelineName -and $_.path -eq $pipelineFolder } | Select-Object -First 1
        if ($deployPipeline) {
            $deployPipelinesByBranch[$branchState.BranchName] = $deployPipeline
        }
        elseif (@($branchState.DeploymentEnvironments).Count -gt 0) {
            Write-Warning "$deployPipelineName pipeline not found. Skipping some deployment authorizations for branch '$($branchState.BranchName)'."
        }
    }

    if (-not $exportPipeline) { Write-Warning 'EXPORT pipeline not found. Skipping some DEV authorizations.' }
    if ($buildValidationEnabled -and -not $buildPipeline) { Write-Warning 'BUILD pipeline not found. Skipping some BUILD validation authorizations.' }

    Write-Section -Message 'Configure DEV environments'
    $devBranchStates = @($branchStates | Where-Object { $_.DevEnvironmentConfiguration })
    if ($devBranchStates.Count -eq 0) {
        [Spectre.Console.AnsiConsole]::MarkupLine('[yellow]No DEV environment configuration was captured in the wizard, so this step will be skipped.[/]')
    }
    else {
        foreach ($branchState in $devBranchStates) {
            $deployPipeline = if ($deployPipelinesByBranch.ContainsKey($branchState.BranchName)) { $deployPipelinesByBranch[$branchState.BranchName] } else { $null }
            Invoke-WithErrorHandling `
                -OperationName "Applying DEV environment configuration for branch '$($branchState.BranchName)'" `
                -AllowSkip `
                -StatusMessage "Applying DEV environment configuration for branch '$($branchState.BranchName)'..." `
                -CaptureOutputInPanel `
                -ScriptBlock {
                    Set-AzDoEnvironmentConfiguration `
                        -EnvironmentConfiguration $branchState.DevEnvironmentConfiguration `
                        -OrganizationName $OrganizationName `
                        -ProjectName $SelectedProject.Name `
                        -ExportPipeline $exportPipeline `
                        -DeployPipeline $deployPipeline
                } | Out-Null
        }
    }

    Write-Section -Message 'Configure branch BUILD validation environments'
    $enabledBuildBranchStates = @($branchStates | Where-Object { $_.BuildValidationEnabled })
    $buildBranchesWithoutEnvironment = @($enabledBuildBranchStates | Where-Object { -not $_.BuildValidationEnvironmentConfiguration })
    if ($buildBranchesWithoutEnvironment.Count -gt 0) {
        $branchNames = @($buildBranchesWithoutEnvironment | ForEach-Object { [string]$_.BranchName }) -join ', '
        throw "BUILD validation is enabled for branch(es) '$branchNames', but no environment configuration was returned."
    }
    if ($enabledBuildBranchStates.Count -eq 0) {
        [Spectre.Console.AnsiConsole]::MarkupLine('[yellow]BUILD validation is disabled for every branch, so BUILD environment configuration will be skipped.[/]')
    }
    elseif (-not $buildPipeline) {
        [Spectre.Console.AnsiConsole]::MarkupLine('[yellow]BUILD pipeline was not found, so BUILD validation environment configuration could not be applied.[/]')
    }
    else {
        $configuredBuildEnvironmentNames = @()
        foreach ($branchState in $enabledBuildBranchStates) {
            $environmentConfiguration = $branchState.BuildValidationEnvironmentConfiguration
            $environmentName = [string]$environmentConfiguration.ShortName
            if ($configuredBuildEnvironmentNames -contains $environmentName) {
                continue
            }
            $configuredBuildEnvironmentNames += $environmentName

            Invoke-WithErrorHandling `
                -OperationName "Applying BUILD validation environment configuration for branch '$($branchState.BranchName)'" `
                -AllowSkip `
                -StatusMessage "Applying BUILD validation environment '$environmentName'..." `
                -CaptureOutputInPanel `
                -ScriptBlock {
                    Set-AzDoEnvironmentConfiguration `
                        -EnvironmentConfiguration $environmentConfiguration `
                        -OrganizationName $OrganizationName `
                        -ProjectName $SelectedProject.Name `
                        -ExportPipeline $null `
                        -DeployPipeline $buildPipeline
                } | Out-Null
        }
    }

    Write-Section -Message 'Configure deployment environments'
    $deploymentBranchStates = @($branchStates | Where-Object { @($_.DeploymentEnvironments).Count -gt 0 })
    if ($deploymentBranchStates.Count -eq 0) {
        [Spectre.Console.AnsiConsole]::MarkupLine('[yellow]No deployment environments were configured in the wizard, so this step will be skipped.[/]')
    }
    else {
        foreach ($branchState in $deploymentBranchStates) {
            $deployPipeline = if ($deployPipelinesByBranch.ContainsKey($branchState.BranchName)) { $deployPipelinesByBranch[$branchState.BranchName] } else { $null }
            foreach ($deploymentEnvironment in @($branchState.DeploymentEnvironments)) {
                Write-Section -Message "Applying environment configuration for '$($deploymentEnvironment.ShortName)' on branch '$($branchState.BranchName)'"
                Invoke-WithErrorHandling `
                    -OperationName "Applying environment configuration for '$($deploymentEnvironment.ShortName)' on branch '$($branchState.BranchName)'" `
                    -AllowSkip `
                    -StatusMessage "Applying configuration for '$($deploymentEnvironment.ShortName)' on branch '$($branchState.BranchName)'..." `
                    -CaptureOutputInPanel `
                    -ScriptBlock {
                        Set-AzDoEnvironmentConfiguration `
                            -EnvironmentConfiguration $deploymentEnvironment `
                            -OrganizationName $OrganizationName `
                            -ProjectName $SelectedProject.Name `
                            -ExportPipeline $exportPipeline `
                            -DeployPipeline $deployPipeline
                    } | Out-Null
            }
        }
    }
}
