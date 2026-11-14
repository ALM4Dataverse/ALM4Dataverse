function Get-DataverseSolutionsSelection {
    <#
    .SYNOPSIS
    Selects a DEV environment and an ordered list of its visible unmanaged user solutions.
    .OUTPUTS
    System.Management.Automation.PSCustomObject. Solutions (name/deployUnmanaged entries)
    and EnvironmentUrl; EnvironmentFriendlyName is present on selection-completion paths.
    .NOTES
    Existing config seeds only solutions still discoverable. An empty selection is a
    valid empty Solutions list; environment cancellation and connection failures throw.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][string]$ExistingConfigPath,
        [Parameter()][string]$ExistingEnvironmentUrl
    )

    try {
        # Select environment using the helper function
        $selectedEnv = Select-DataverseEnvironment `
            -Prompt "Select your DEV environment" `
            -PreferredUrl $ExistingEnvironmentUrl `
            -PromptGuidanceLines @(
                'Choose the DEV Dataverse environment used to discover unmanaged solutions for alm-config.psd1.',
                'Pick the environment that represents the source-controlled customization baseline.',
                'This environment supplies the solution list used by the selected branch.',
                'Solutions are stored in dependency order in alm-config.psd1.'
            ) `
            -PromptGuidanceDocRelativePath 'docs/config/alm-config.md' `
            -PromptGuidanceRef $ALM4DataverseRef
        if (-not $selectedEnv) {
            throw "No environment selected."
        }

        $devEnvUrl = ConvertTo-NormalizedEnvironmentUrl -Url $selectedEnv.Endpoints["WebApplication"]
        Write-Host "Selected environment: $($selectedEnv.FriendlyName) ($devEnvUrl)" -ForegroundColor Cyan

        Write-Host 'Authenticating to the selected DEV environment...' -ForegroundColor DarkGray
        $devAccessTokenCallback = Get-SetupAccessTokenCallback -ResourceUrl $devEnvUrl
        # Connect to the selected environment
        $connection = Invoke-WithSpectreStatus -Status 'Connecting to the selected DEV environment...' -ScriptBlock {
            Get-DataverseConnection -Url $devEnvUrl -AccessToken $devAccessTokenCallback
        }

        if (-not $connection) {
            throw "Failed to connect to Dataverse environment."
        }

        Write-Host "Connected to environment: $($connection.ConnectedOrgFriendlyName)"

        # Get all solutions (excluding system solutions)
        $allSolutions = Invoke-WithSpectreStatus -Status 'Retrieving unmanaged solutions from Dataverse...' -ScriptBlock {
            Get-DataverseRecord -Connection $connection -TableName 'solution' -Columns @('solutionid', 'uniquename', 'friendlyname', 'version', 'ismanaged', 'description') -FilterValues @{
                'isvisible' = $true
                'ismanaged' = $false
            }
        }

        if (-not $allSolutions -or $allSolutions.Count -eq 0) {
            Write-Host "No unmanaged solutions found in the environment." -ForegroundColor Yellow
            return [pscustomobject]@{ Solutions = @(); EnvironmentUrl = $devEnvUrl }
        }

        # Filter out system solutions and prepare for selection
        $userSolutions = $allSolutions | Where-Object {
            $_.uniquename -notmatch '^(Default|Active|Basic|msdyn_|ms|MicrosoftFlow|PowerPlatform)' -and
            $_.uniquename -ne 'System'
        } | Sort-Object friendlyname

        if (-not $userSolutions -or $userSolutions.Count -eq 0) {
            Write-Host "No user-created solutions found in the environment." -ForegroundColor Yellow
            return [pscustomobject]@{ Solutions = @(); EnvironmentUrl = $devEnvUrl }
        }

        $selectedSolutions = @()

        if ($ExistingConfigPath -and (Test-Path -LiteralPath $ExistingConfigPath)) {
            try {
                $existingConfig = Import-PowerShellDataFile -Path $ExistingConfigPath
                foreach ($existing in @($existingConfig.solutions)) {
                    $match = $userSolutions | Where-Object { $_.uniquename -eq $existing.name } | Select-Object -First 1
                    if ($match) {
                        $selectedSolutions += $match
                    }
                }
            }
            catch {
                Write-Warning "Failed to read existing alm-config.psd1 defaults: $($_.Exception.Message)"
            }
        }

        if ($selectedSolutions.Count -gt 0) {
            Write-Host "Pre-selected $($selectedSolutions.Count) solution(s) from existing configuration." -ForegroundColor Green
            Start-Sleep -Seconds 2
        }


        $selectedSolutions = @(Select-OrderedSolution -AvailableSolutions $userSolutions -InitiallySelectedSolutions $selectedSolutions)

        if ($selectedSolutions.Count -eq 0) {
            Write-Host "No solutions selected." -ForegroundColor Yellow
            return [pscustomobject]@{ Solutions = @(); EnvironmentUrl = $devEnvUrl; EnvironmentFriendlyName = $selectedEnv.FriendlyName }
        }

        Write-Host "Final selection:"
        foreach ($sol in $selectedSolutions) {
            Write-Host "  - $($sol.friendlyname) ($($sol.uniquename))"
        }

        # Convert to the format needed for alm-config.psd1
        $configSolutions = @()
        foreach ($sol in $selectedSolutions) {
            $configSolutions += @{
                name            = $sol.uniquename
                deployUnmanaged = $false
            }
        }

        return [pscustomobject]@{ Solutions = $configSolutions; EnvironmentUrl = $devEnvUrl; EnvironmentFriendlyName = $selectedEnv.FriendlyName }

    }
    catch {
        Write-Host "Error retrieving solutions from Dataverse: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

function Update-AlmConfigInWorkingTree {
    # Null Solutions preserves the list (discovery skipped); an empty array clears it.
    # Checker/baseline settings are always reconciled. Returns whether any helper changed
    # the file, or false under WhatIf; shared helpers preserve unrelated configuration.
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param(
        [Parameter()][AllowNull()][array]$Solutions,
        [Parameter(Mandatory)][bool]$BuildValidationEnabled,
        [Parameter()][AllowEmptyString()][string]$BuildValidationBaselineRelease = '',
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter()][System.Collections.IDictionary]$SetupSettings
    )

    if (-not $PSCmdlet.ShouldProcess($RepoRoot, 'Update ALM configuration')) { return $false }

    $configPath = Join-Path $RepoRoot 'alm-config.psd1'
    $templatePath = if ($script:SetupRepositoryRoot) { Join-Path $script:SetupRepositoryRoot 'copy-to-your-repo\alm-config.psd1' } else { $null }
    $solutionsChanged = $false
    if ($null -ne $Solutions) {
        $solutionsChanged = Set-AlmConfigSolutionsInFile -ConfigPath $configPath -Solutions @($Solutions) -CreateIfMissing -TemplatePath $templatePath
    }
    else {
        Write-Host 'Skipping solution list updates in alm-config.psd1 because solution selection was not run.' -ForegroundColor Yellow
    }
    if ($SetupSettings) {
        [void](Set-AlmConfigSetupSettingsInFile -ConfigPath $configPath -Settings $SetupSettings -CreateIfMissing -TemplatePath $templatePath)
    }
    $solutionCheckChanged = Set-AlmConfigSolutionCheckEnabledInFile -ConfigPath $configPath -Enabled $BuildValidationEnabled -CreateIfMissing -TemplatePath $templatePath
    $effectiveBaselineRelease = if ($SetupSettings) { '' } else { $BuildValidationBaselineRelease }
    $baselineChanged = Set-AlmConfigBuildValidationBaselineReleaseInFile -ConfigPath $configPath -BaselineRelease $effectiveBaselineRelease -CreateIfMissing -TemplatePath $templatePath
    $changed = ($solutionsChanged -or $solutionCheckChanged -or $baselineChanged)

    if ($changed) {
        Write-Host 'Updated alm-config.psd1 in the working tree.' -ForegroundColor Green
    }
    else {
        Write-Host 'No changes to alm-config.psd1; solutions already configured.' -ForegroundColor Green
    }

    return $changed
}

function Update-AzDoBuildPipelineInWorkingTree {
    <#
    .SYNOPSIS
    Replaces an existing BUILD scaffold with the shared build-template invocation.
    .NOTES
    The generated CI trigger includes every branch. BuildValidationEnvironments maps
    each source branch to its validation environment; BuildEnvironmentName remains a
    compatibility input when no map is supplied. This is a whole-file replacement, not
    a merge of custom YAML, except that an existing template-level secretVariables
    parameter block is carried over unchanged.
    WhatIf skips the write.
    #>
        [CmdletBinding(SupportsShouldProcess = $true)]
        [OutputType([bool])]
        param(
                [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$SharedRepositoryName,
                [Parameter()][string]$SharedRepositoryRef = 'main',
                [Parameter(Mandatory)][AllowEmptyString()][string]$BuildEnvironmentName,
                [Parameter(Mandatory)][bool]$UseAlm4DataverseExtension,
                [Parameter()][System.Collections.IDictionary]$BuildValidationEnvironments = @{}
        )

        if (-not $PSCmdlet.ShouldProcess($RepoRoot, 'Update Azure DevOps BUILD pipeline')) { return $false }

        $buildPipelinePath = Join-Path $RepoRoot 'pipelines/BUILD.yml'
        if (-not (Test-Path -LiteralPath $buildPipelinePath)) {
                throw "Build pipeline file not found: $buildPipelinePath"
        }

        $extensionLiteral = if ($UseAlm4DataverseExtension) { 'true' } else { 'false' }
        $escapedBuildEnvironmentName = ([string]$BuildEnvironmentName).Replace("'", "''")
        $escapedSharedRepositoryRef = ([string]$SharedRepositoryRef).Replace("'", "''")
        $validationEnvironmentsJson = ConvertTo-Json -InputObject $BuildValidationEnvironments -Depth 5 -Compress

        $secretVariableBlock = Get-AzDoCallerSecretVariableBlock -Path $buildPipelinePath
        if ($secretVariableBlock) { $secretVariableBlock = [Environment]::NewLine + $secretVariableBlock }

        $newContent = @"
trigger:
  branches:
    include:
    - '*'  # Support any branch name

resources:
  repositories:
  - repository: ALM4Dataverse
    type: git
    name: $SharedRepositoryName
    ref: 'refs/heads/$escapedSharedRepositoryRef'

stages:
- template: pipelines/templates/build.yml@ALM4Dataverse
  parameters:
    useAlm4DataverseExtension: $extensionLiteral
    buildEnvironmentName: '$escapedBuildEnvironmentName'
    buildValidationEnvironments: $validationEnvironmentsJson$secretVariableBlock
"@

        Set-Content -LiteralPath $buildPipelinePath -Value $newContent.TrimStart("`r", "`n") -NoNewline
}

function Initialize-DataverseApplicationUser {
    # Ensure an app-ID systemuser and its root-business-unit System Administrator role.
    # Uses interactive tenant-scoped tokens, not the app's credentials; missing root BU,
    # role or connection throws. Existing user/role associations are retained.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EnvironmentUrl,
        [Parameter(Mandatory)][string]$ApplicationId,
        [Parameter(Mandatory)][string]$TenantId
    )

    Write-Host "Ensuring application user '$ApplicationId' exists in '$EnvironmentUrl'..." -ForegroundColor DarkGray

    $accessTokenCallback = Get-SetupAccessTokenCallback -ResourceUrl $EnvironmentUrl -TenantId $TenantId
    $conn = Get-DataverseConnection -Url $EnvironmentUrl -AccessToken $accessTokenCallback

    if (-not $conn) {
        throw "Failed to connect to Dataverse."
    }

    # 1. Get Root Business Unit
    $rootBu = Get-DataverseRecord -Connection $conn -TableName "businessunit" -FilterValues @{ parentbusinessunitid = $null } -Columns "businessunitid" | Select-Object -First 1
    if (-not $rootBu) { throw "Could not find root business unit." }
    $rootBuId = $rootBu.businessunitid

    # 2. Get System Administrator Role
    $roleName = "System Administrator"
    $role = Get-DataverseRecord -Connection $conn -TableName "role" -FilterValues @{ name = $roleName; businessunitid = $rootBuId } -Columns "roleid" | Select-Object -First 1
    if (-not $role) { throw "Could not find '$roleName' role in root business unit." }
    $roleId = $role.roleid

    # 3. Check/Create System User
    $user = Get-DataverseRecord -Connection $conn -TableName "systemuser" -FilterValues @{ applicationid = $ApplicationId } -Columns "systemuserid" | Select-Object -First 1
    $userId = $null

    if ($user) {
        Write-Host "User already exists. ID: $($user.systemuserid)"
        $userId = $user.systemuserid
    }
    else {
        Write-Host "Creating application user..."
        $userAttributes = @{
            "applicationid" = $ApplicationId
            "businessunitid" = $rootBuId
        }
        $createdUser = $userAttributes | Set-DataverseRecord -Connection $conn -TableName "systemuser" -CreateOnly -PassThru
        $userId = $createdUser.Id
        Write-Host "User created. ID: $userId"
    }

    # 4. Associate User with Role
    $existingAssociation = Get-DataverseRecord -Connection $conn -TableName "systemuserroles" -FilterValues @{ systemuserid = $userId; roleid = $roleId } -Top 1
    if (-not $existingAssociation) {
        Write-Host "Associating user with '$roleName' role..."
        @{
            systemuserid = $userId
            roleid = $roleId
        } | Set-DataverseRecord -Connection $conn -TableName "systemuserroles" -CreateOnly
        Write-Host "Association successful."
    }
    else {
        Write-Host "User is already associated with '$roleName' role."
    }
}

function Initialize-DataverseServiceAccountUser {
    # Resolve/create the UPN systemuser in the root BU and add System Administrator
    # if absent. This provisions Dataverse records/roles, not an Entra account or license.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EnvironmentUrl,
        [Parameter(Mandatory)][string]$ServiceAccountUPN,
        [Parameter(Mandatory)][string]$TenantId
    )

    Write-Host "Ensuring service account '$ServiceAccountUPN' has System Administrator role in '$EnvironmentUrl'..." -ForegroundColor DarkGray

    $accessTokenCallback = Get-SetupAccessTokenCallback -ResourceUrl $EnvironmentUrl -TenantId $TenantId
    $conn = Get-DataverseConnection -Url $EnvironmentUrl -AccessToken $accessTokenCallback

    if (-not $conn) {
        throw "Failed to connect to Dataverse."
    }

    # 1. Get Root Business Unit
    $rootBu = Get-DataverseRecord -Connection $conn -TableName "businessunit" -FilterValues @{ parentbusinessunitid = $null } -Columns "businessunitid" | Select-Object -First 1
    if (-not $rootBu) { throw "Could not find root business unit." }
    $rootBuId = $rootBu.businessunitid

    # 2. Get System Administrator Role
    $roleName = "System Administrator"
    $role = Get-DataverseRecord -Connection $conn -TableName "role" -FilterValues @{ name = $roleName; businessunitid = $rootBuId } -Columns "roleid" | Select-Object -First 1
    if (-not $role) { throw "Could not find '$roleName' role in root business unit." }
    $roleId = $role.roleid

    # 3. Find the System User by UPN
    $user = Get-DataverseRecord -Connection $conn -TableName "systemuser" -FilterValues @{
        domainname = $ServiceAccountUPN
    } -Columns "systemuserid","fullname" | Select-Object -First 1

    $userId = $null
    if ($user) {
        $userId = $user.systemuserid
        Write-Host "Found service account user: $($user.fullname) (ID: $userId)"
    }
    else {
        Write-Host "Service account user '$ServiceAccountUPN' not found. Creating..."
        $userAttributes = @{
            "domainname" = $ServiceAccountUPN
            "businessunitid" = $rootBuId
            "internalemailaddress" = $ServiceAccountUPN
            "firstname" = "Service"
            "lastname" = "Account"
        }
        $createdUser = $userAttributes | Set-DataverseRecord -Connection $conn -TableName "systemuser" -CreateOnly -PassThru
        $userId = $createdUser.Id
        Write-Host "Service account user created. ID: $userId"
    }

    # 4. Associate User with Role
    $existingAssociation = Get-DataverseRecord -Connection $conn -TableName "systemuserroles" -FilterValues @{ systemuserid = $userId; roleid = $roleId } -Top 1
    if (-not $existingAssociation) {
        Write-Host "Associating service account with '$roleName' role..."
        @{
            systemuserid = $userId
            roleid = $roleId
        } | Set-DataverseRecord -Connection $conn -TableName "systemuserroles" -CreateOnly
        Write-Host "Association successful."
    }
    else {
        Write-Host "Service account is already associated with '$roleName' role."
    }
}

function Get-ExistingEnvironmentsFromWorkingTree {
    [CmdletBinding()]
    [OutputType([string], [object[]])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch
    )

    return @(Get-AzDoDeploymentEnvironmentNamesFromWorkingTree -RepoRoot $RepoRoot -Branch $Branch)
}

function Get-AzDoExistingEnvironmentServiceAccountUPN {
    # Best-effort discovery: missing groups/variables and lookup failures all yield null.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$EnvironmentName
    )

    try {
        $existingVarGroup = Get-AzDoVariableGroupByName -ProjectName $ProjectName -GroupName "Environment-$EnvironmentName" -ErrorAction SilentlyContinue
        if ($existingVarGroup -and $existingVarGroup.variables -and $existingVarGroup.variables.PSObject.Properties.Name -contains 'DataverseServiceAccountUPN') {
            return $existingVarGroup.variables.DataverseServiceAccountUPN.value
        }
    }
    catch {
        return $null
    }

    return $null
}

function Get-AzDoExistingEnvironmentState {
    <#
    .SYNOPSIS
    Reconstructs environment URL, ownership and credential metadata from existing Azure DevOps resources.
    .NOTES
    Returns null only when URL, credentials and service-account UPN are all unavailable;
    otherwise fields can be partial. Endpoint tenant overrides the supplied hint.
    Secret values are not read: HasExistingSecret marks the configured authentication
    scheme, while ClientSecret remains null for subsequent keep-or-rotate selection.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter()][string]$TenantId
    )

    $serviceAccountUPN = Get-AzDoExistingEnvironmentServiceAccountUPN -ProjectName $ProjectName -EnvironmentName $EnvironmentName
    $endpoint = $null
    try {
        $endpoints = @(Get-VSTeamServiceEndpoint -ProjectName $ProjectName -ErrorAction SilentlyContinue)
        $endpoint = $endpoints | Where-Object { $_.name -eq $EnvironmentName } | Select-Object -First 1
    }
    catch {
        $endpoint = $null
    }

    $credentials = $null
    $environmentUrl = $null
    $friendlyName = $EnvironmentName
    if ($endpoint) {
        $environmentUrl = ConvertTo-NormalizedEnvironmentUrl -Url $endpoint.url
        $friendlyName = Resolve-DataverseEnvironmentFriendlyName -EnvironmentUrl $environmentUrl -FallbackName $EnvironmentName

        $applicationId = $null
        $resolvedTenantId = $TenantId
        if ($endpoint.authorization -and $endpoint.authorization.parameters) {
            if ($endpoint.authorization.parameters.PSObject.Properties.Name -contains 'applicationId') {
                $applicationId = $endpoint.authorization.parameters.applicationId
            }
            elseif ($endpoint.authorization.parameters.PSObject.Properties.Name -contains 'serviceprincipalid') {
                $applicationId = $endpoint.authorization.parameters.serviceprincipalid
            }

            if ($endpoint.authorization.parameters.PSObject.Properties.Name -contains 'tenantId' -and -not [string]::IsNullOrWhiteSpace($endpoint.authorization.parameters.tenantId)) {
                $resolvedTenantId = $endpoint.authorization.parameters.tenantId
            }
            elseif ($endpoint.authorization.parameters.PSObject.Properties.Name -contains 'tenantid' -and -not [string]::IsNullOrWhiteSpace($endpoint.authorization.parameters.tenantid)) {
                $resolvedTenantId = $endpoint.authorization.parameters.tenantid
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($applicationId)) {
            $application = Resolve-EntraIdApplicationByAppId -ApplicationId $applicationId -TenantId $resolvedTenantId
            $authType = if ($endpoint.authorization -and $endpoint.authorization.scheme -eq 'WorkloadIdentityFederation') { 'WIF' } else { 'Secret' }

            $credentials = [pscustomobject]@{
                Name                        = $(if ($application -and -not [string]::IsNullOrWhiteSpace($application.displayName)) { $application.displayName } else { "Existing-$EnvironmentName" })
                ApplicationId               = $applicationId
                ApplicationObjectId         = $(if ($application) { $application.id } else { $null })
                ClientSecret                = $null
                TenantId                    = $resolvedTenantId
                AuthType                    = $authType
                IsExistingServiceConnection = $true
                HasExistingSecret           = ($authType -eq 'Secret')
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($environmentUrl) -and -not $credentials -and [string]::IsNullOrWhiteSpace($serviceAccountUPN)) {
        return $null
    }

    return [pscustomobject]@{
        ShortName         = $EnvironmentName
        FriendlyName      = $friendlyName
        Url               = $environmentUrl
        Credentials       = $credentials
        ServiceAccountUPN = $serviceAccountUPN
    }
}

function Get-GitRepoFileContentFromRemoteBranch {
    # Inspect fetched origin first, then local branch without checkout or network fetch.
    # Missing refs/files and whitespace-only content share the null sentinel.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$RelativePath
    )

    $normalizedPath = $RelativePath.Replace('\\', '/')
    $normalizedBranch = ConvertTo-NormalizedGitBranchName -Branch $Branch
    $candidateRefs = @("origin/$normalizedBranch", $normalizedBranch) | Select-Object -Unique
    foreach ($candidateRef in $candidateRefs) {
        & git -C $RepoRoot rev-parse --verify --quiet "${candidateRef}^{commit}" 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            continue
        }

        $content = (& git -C $RepoRoot show "${candidateRef}:${normalizedPath}" 2>$null | Out-String)
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($content)) {
            return $content
        }
    }

    return $null
}

function ConvertTo-NormalizedGitBranchName {
    # Strip repeated origin/ tracking prefixes only; refs/heads is not normalized here.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Branch
    )

    $normalizedBranch = [string]$Branch
    while ($normalizedBranch -match '^origin/(.+)$') {
        $normalizedBranch = [string]$Matches[1]
    }

    return $normalizedBranch.Trim()
}

function Resolve-GitExistingBranchRef {
    # Return the first commit-resolving origin/local ref, or null; does not fetch.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch
    )

    $normalizedBranch = ConvertTo-NormalizedGitBranchName -Branch $Branch
    if ([string]::IsNullOrWhiteSpace($normalizedBranch)) {
        return $null
    }

    $candidateRefs = @("origin/$normalizedBranch", $normalizedBranch)
    foreach ($candidateRef in $candidateRefs) {
        & git -C $RepoRoot rev-parse --verify --quiet "${candidateRef}^{commit}" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            return $candidateRef
        }
    }

    return $null
}

function Get-AzDoRepositoryExistingSetupState {
    <#
    .SYNOPSIS
    Builds branch/environment setup defaults from alm-config.psd1 and optional remote state.
    .OUTPUTS
    System.Management.Automation.PSCustomObject. BranchStates plus default-branch BUILD
    validation flag, environment name and provider environment metadata.
    .NOTES
    Pipeline YAML and registered pipeline definitions are not configuration sources.
    ApplyConfig skips remote environment lookups.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$DefaultBranch,
        [Parameter()][string]$TenantId,
        [Parameter()][switch]$SkipProviderState
    )

    $committedConfigContent = Get-GitRepoFileContentFromRemoteBranch -RepoRoot $RepoRoot -Branch $DefaultBranch -RelativePath 'alm-config.psd1'
    $existingConfiguration = ConvertFrom-AlmConfigContentForSetup -ConfigContent ([string]$committedConfigContent)
    $configuredProvider = [string](Get-OptionalObjectPropertyValue -InputObject $existingConfiguration -PropertyName 'provider')
    if (-not [string]::IsNullOrWhiteSpace($configuredProvider) -and $configuredProvider -ine 'azDO') {
        throw "alm-config.psd1 specifies provider '$configuredProvider'; use the matching setup script."
    }

    $hasConfiguredBranches = $existingConfiguration.Contains('branches')
    if ($hasConfiguredBranches) {
        if ($existingConfiguration.branches -isnot [System.Collections.IDictionary]) {
            throw 'The branches setting in alm-config.psd1 must be a hashtable keyed by branch name.'
        }
    }

    if ($hasConfiguredBranches -and $existingConfiguration.branches.Count -gt 0) {
        $branchStates = @()
        $defaultBranchState = $null
        foreach ($branchName in @($existingConfiguration.branches.Keys | Sort-Object)) {
            $branchConfiguration = Get-AlmSetupBranchConfiguration -Config $existingConfiguration -BranchName ([string]$branchName)
            $devEnvironmentName = ''
            if ($branchConfiguration.Contains('developmentEnvironment')) {
                if ($branchConfiguration.developmentEnvironment -isnot [string]) {
                    throw "The developmentEnvironment setting for branch '$branchName' must be a string."
                }
                $devEnvironmentName = [string]$branchConfiguration.developmentEnvironment
            }

            $existingDevEnvironment = $null
            if (-not [string]::IsNullOrWhiteSpace($devEnvironmentName)) {
                if (-not $SkipProviderState) {
                    $existingDevEnvironment = Get-AzDoExistingEnvironmentState -ProjectName $ProjectName -EnvironmentName $devEnvironmentName -TenantId $TenantId
                }
                if (-not $existingDevEnvironment) {
                    $existingDevEnvironment = [pscustomobject]@{
                        ShortName         = $devEnvironmentName
                        FriendlyName      = $devEnvironmentName
                        Url               = $null
                        Credentials       = $null
                        ServiceAccountUPN = $null
                    }
                }
            }

            $deploymentEnvironmentNames = @()
            if ($branchConfiguration.Contains('deploymentEnvironments') -and $null -ne $branchConfiguration.deploymentEnvironments) {
                if ($branchConfiguration.deploymentEnvironments -isnot [array]) {
                    throw "The deploymentEnvironments setting for branch '$branchName' must be an array of environment names."
                }
                $deploymentEnvironmentNames = @($branchConfiguration.deploymentEnvironments)
            }
            $deploymentEnvironments = @()
            foreach ($environmentName in $deploymentEnvironmentNames) {
                if ($environmentName -isnot [string] -or [string]::IsNullOrWhiteSpace($environmentName)) {
                    throw "The deploymentEnvironments setting for branch '$branchName' must contain non-empty environment names."
                }
                $environmentState = $null
                if (-not $SkipProviderState) {
                    $environmentState = Get-AzDoExistingEnvironmentState -ProjectName $ProjectName -EnvironmentName $environmentName -TenantId $TenantId
                }
                if (-not $environmentState) {
                    $environmentState = [pscustomobject]@{
                        ShortName         = $environmentName
                        FriendlyName      = $environmentName
                        Url               = $null
                        Credentials       = $null
                        ServiceAccountUPN = $null
                    }
                }
                $deploymentEnvironments += $environmentState
            }

            $buildValidationConfiguration = @{}
            if ($branchConfiguration.Contains('buildValidation') -and $null -ne $branchConfiguration.buildValidation) {
                if ($branchConfiguration.buildValidation -isnot [System.Collections.IDictionary]) {
                    throw "The buildValidation setting for branch '$branchName' must be a hashtable."
                }
                $buildValidationConfiguration = $branchConfiguration.buildValidation
            }

            $buildEnvironmentName = ''
            if ($buildValidationConfiguration.Contains('environmentName')) {
                if ($buildValidationConfiguration.environmentName -isnot [string]) {
                    throw "The buildValidation.environmentName setting for branch '$branchName' must be a string."
                }
                $buildEnvironmentName = [string]$buildValidationConfiguration.environmentName
            }
            $buildValidationBaselineRelease = ''
            if ($buildValidationConfiguration.Contains('baselineRelease')) {
                $buildValidationBaselineRelease = [string]$buildValidationConfiguration.baselineRelease
            }
            $existingBuildValidationEnvironment = $null
            if (-not [string]::IsNullOrWhiteSpace($buildEnvironmentName)) {
                if (-not $SkipProviderState) {
                    $existingBuildValidationEnvironment = Get-AzDoExistingEnvironmentState -ProjectName $ProjectName -EnvironmentName $buildEnvironmentName -TenantId $TenantId
                }
                if (-not $existingBuildValidationEnvironment) {
                    $existingBuildValidationEnvironment = [pscustomobject]@{
                        ShortName         = $buildEnvironmentName
                        FriendlyName      = $buildEnvironmentName
                        Url               = $null
                        Credentials       = $null
                        ServiceAccountUPN = $null
                    }
                }
            }

            $branchState = [pscustomobject]@{
                BranchName                         = [string]$branchName
                ExistingDevEnvironment             = $existingDevEnvironment
                DeploymentEnvironments             = @($deploymentEnvironments)
                ExistingBuildValidationEnvironment = $existingBuildValidationEnvironment
                BuildValidationEnvironmentName     = $buildEnvironmentName
                BuildValidationBaselineRelease     = $buildValidationBaselineRelease
            }
            $branchStates += $branchState
            if ($branchName -ieq $DefaultBranch) {
                $defaultBranchState = $branchState
            }
        }

        return [pscustomobject]@{
            BranchStates = @($branchStates)
            BuildValidationEnabled = [bool](@($branchStates | Where-Object { -not [string]::IsNullOrWhiteSpace($_.BuildValidationEnvironmentName) }).Count -gt 0)
            BuildValidationEnvironmentName = $(if ($defaultBranchState) { [string]$defaultBranchState.BuildValidationEnvironmentName } else { '' })
            ExistingBuildValidationEnvironment = $(if ($defaultBranchState) { $defaultBranchState.ExistingBuildValidationEnvironment } else { $null })
            ExistingConfiguration = $existingConfiguration
        }
    }

    return [pscustomobject]@{
        BranchStates = @()
        BuildValidationEnabled = $false
        BuildValidationEnvironmentName = ''
        ExistingBuildValidationEnvironment = $null
        ExistingConfiguration = $existingConfiguration
    }
}
