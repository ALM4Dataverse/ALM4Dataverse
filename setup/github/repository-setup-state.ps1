function Get-GitHubRepoList {
    <#
    .SYNOPSIS
        Returns up to 100 repositories accessible to the authenticated GitHub account.
    .DESCRIPTION
        Includes repositories owned by the account, shared by its organizations, or
        accessible through collaborator access. Maps the REST response to
        nameWithOwner, name, owner and defaultBranchRef metadata. Does not request or
        validate write permissions. API failures throw.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject], [object[]])]
    param()

    $repos = Invoke-GhApi -Endpoint 'user/repos?affiliation=owner,collaborator,organization_member&sort=updated&per_page=100'
    if (-not $repos) {
        return @()
    }

    return @(
        foreach ($repo in @($repos)) {
            [pscustomobject]@{
                nameWithOwner = [string]$repo.full_name
                name          = [string]$repo.name
                owner         = $repo.owner
                defaultBranchRef = if ($repo.default_branch) {
                    [pscustomobject]@{ name = [string]$repo.default_branch }
                }
                else {
                    $null
                }
            }
        }
    )
}

function Invoke-GitHubCloneBaseBranchCheckout {
    <#
    .SYNOPSIS
        Checks out the selected repository's base branch in a clone.
    .DESCRIPTION
        Tries the local branch, then the fetched remote branch. When neither exists
        and the repository has no commit, points HEAD at an unborn branch with the
        requested name so setup can publish the repository's initial files. Other
        checkout failures throw.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$DefaultBranch
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $checkoutOutput = @(& git -C $RepoRoot checkout -f $DefaultBranch 2>&1)
        $checkoutExitCode = $LASTEXITCODE

        if ($checkoutExitCode -ne 0) {
            $checkoutOutput = @(& git -C $RepoRoot checkout -B $DefaultBranch "origin/$DefaultBranch" 2>&1)
            $checkoutExitCode = $LASTEXITCODE
        }

        if ($checkoutExitCode -ne 0) {
            [void](& git -C $RepoRoot rev-parse --verify HEAD 2>&1)
            $headExitCode = $LASTEXITCODE

            if ($headExitCode -ne 0) {
                $checkoutOutput = @(& git -C $RepoRoot symbolic-ref HEAD "refs/heads/$DefaultBranch" 2>&1)
                $checkoutExitCode = $LASTEXITCODE
            }
        }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($checkoutExitCode -ne 0) {
        $checkoutErrorDetails = @($checkoutOutput | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $checkoutErrorMessage = if ($checkoutErrorDetails.Count -gt 0) { $checkoutErrorDetails[-1] } else { "Exit code: $checkoutExitCode" }
        throw "Failed to check out repository base branch '$DefaultBranch'. $checkoutErrorMessage"
    }
}

function Get-GitHubRepo {
    <#
    .SYNOPSIS
        Returns repository details for a single GitHub repository.
    .DESCRIPTION
        Returns gh's nameWithOwner, name, owner and defaultBranchRef JSON object.
        Missing or inaccessible repositories cause a terminating CLI error.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $result = @(& gh repo view "$Owner/$Repo" --json nameWithOwner,name,owner,defaultBranchRef 2>&1)
        $viewExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($viewExitCode -ne 0) {
        throw "Failed to get repository '$Owner/$Repo': $($result -join "`n")"
    }
    return (@($result) -join [Environment]::NewLine) | ConvertFrom-Json
}

function Get-GitHubRepositoryIdentity {
    <#
    .SYNOPSIS
        Returns the repository IDs and OIDC subject format used by GitHub.
    .DESCRIPTION
        Requires numeric owner/repository IDs and an explicit use_immutable_subject
        setting; missing metadata throws rather than guessing an Entra trust subject.
        Returns IDs as Int64 plus the original OidcCustomization for later updates.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo
    )

    $repository = Invoke-GhApi -Endpoint "repos/$Owner/$Repo"
    if (-not $repository) {
        throw "Could not retrieve repository metadata for '$Owner/$Repo'."
    }

    $repositoryPropertyNames = @($repository.PSObject.Properties.Name)
    $ownerObject = if ($repositoryPropertyNames -contains 'owner') { $repository.owner } else { $null }
    $ownerPropertyNames = if ($ownerObject) { @($ownerObject.PSObject.Properties.Name) } else { @() }
    $ownerId = if ($ownerPropertyNames -contains 'id') { [string]$ownerObject.id } else { $null }
    $repositoryId = if ($repositoryPropertyNames -contains 'id') { [string]$repository.id } else { $null }

    if ([string]::IsNullOrWhiteSpace($ownerId) -or $ownerId -notmatch '^\d+$') {
        throw "GitHub did not return a numeric owner ID for repository '$Owner/$Repo'."
    }
    if ([string]::IsNullOrWhiteSpace($repositoryId) -or $repositoryId -notmatch '^\d+$') {
        throw "GitHub did not return a numeric repository ID for '$Owner/$Repo'."
    }

    # Existing repositories remain on the legacy subject format unless they opt in.
    # Read GitHub's effective repository setting instead of inferring the format from age.
    $oidcCustomization = Invoke-GhApi -Endpoint "repos/$Owner/$Repo/actions/oidc/customization/sub" -AllowNotFound
    $oidcCustomizationPropertyNames = if ($oidcCustomization) { @($oidcCustomization.PSObject.Properties.Name) } else { @() }
    if (-not $oidcCustomization -or $oidcCustomizationPropertyNames -notcontains 'use_immutable_subject') {
        throw "GitHub did not report the OIDC subject format for repository '$Owner/$Repo'."
    }

    return [pscustomobject]@{
        OwnerId             = [long]$ownerId
        RepositoryId        = [long]$repositoryId
        UseImmutableSubject = [bool]$oidcCustomization.use_immutable_subject
        OidcCustomization   = $oidcCustomization
    }
}

function Set-GitHubRepositoryImmutableSubject {
    <#
    .SYNOPSIS
        Enables immutable OIDC subjects without replacing the current claim-selection mode.
    .DESCRIPTION
        CurrentCustomization must include use_default and, for custom mode,
        include_claim_keys. Throws if those settings cannot be preserved or GitHub
        does not confirm the change. Returns the confirmed customization object;
        ShouldProcess can skip the mutation and return no object.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][object]$CurrentCustomization
    )

    if (-not $PSCmdlet.ShouldProcess("$Owner/$Repo", 'Enable immutable GitHub OIDC subject')) { return }

    $customizationPropertyNames = @($CurrentCustomization.PSObject.Properties.Name)
    if ($customizationPropertyNames -notcontains 'use_default') {
        throw "GitHub did not return the current OIDC customization mode for '$Owner/$Repo'."
    }

    $body = @{
        use_default           = [bool]$CurrentCustomization.use_default
        use_immutable_subject = $true
    }

    if (-not $body.use_default) {
        if ($customizationPropertyNames -notcontains 'include_claim_keys') {
            throw "Cannot preserve the existing custom OIDC claims for '$Owner/$Repo'."
        }

        $body.include_claim_keys = @($CurrentCustomization.include_claim_keys)
    }

    Write-Host "Enabling immutable GitHub OIDC subjects for '$Owner/$Repo'..." -ForegroundColor Yellow
    $updated = Invoke-GhApi `
        -Endpoint "repos/$Owner/$Repo/actions/oidc/customization/sub" `
        -Method 'PUT' `
        -Body $body

    # GitHub may return an empty 201 response; re-read the effective setting in that case.
    if (-not $updated) {
        $updated = Invoke-GhApi -Endpoint "repos/$Owner/$Repo/actions/oidc/customization/sub"
    }

    if (-not $updated -or $updated.PSObject.Properties.Name -notcontains 'use_immutable_subject' -or -not [bool]$updated.use_immutable_subject) {
        throw "GitHub did not confirm immutable OIDC subjects for '$Owner/$Repo'."
    }

    Write-Host "Immutable GitHub OIDC subjects enabled for '$Owner/$Repo'." -ForegroundColor Green
    return $updated
}

function New-GitHubEnvironmentWifSubject {
    <#
    .SYNOPSIS
        Formats the environment-scoped subject expected by the selected GitHub OIDC mode.
    .DESCRIPTION
        Immutable mode includes owner and repository numeric IDs alongside names;
        legacy mode uses RepoFullName. EnvironmentName is inserted verbatim, so the
        caller must supply the same name used by the workflow environment.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RepoOwner,
        [Parameter(Mandatory)][string]$RepoName,
        [Parameter(Mandatory)][string]$RepoFullName,
        [Parameter(Mandatory)][long]$RepoOwnerId,
        [Parameter(Mandatory)][long]$RepoId,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][bool]$UseImmutableSubject
    )

    $repositorySubject = if ($UseImmutableSubject) {
        "${RepoOwner}@${RepoOwnerId}/${RepoName}@${RepoId}"
    }
    else {
        $RepoFullName
    }

    return "repo:${repositorySubject}:environment:${EnvironmentName}"
}

function Test-GitHubEnvironmentConfigurationUsesWif {
    # Partial discovery records have no Credentials/AuthType; treat them as non-WIF
    # rather than dereferencing missing properties under StrictMode.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][object]$EnvironmentConfiguration
    )

    if ($null -eq $EnvironmentConfiguration) {
        return $false
    }

    $configurationPropertyNames = @($EnvironmentConfiguration.PSObject.Properties.Name)
    if ($configurationPropertyNames -notcontains 'Credentials' -or $null -eq $EnvironmentConfiguration.Credentials) {
        return $false
    }

    $credentialPropertyNames = @($EnvironmentConfiguration.Credentials.PSObject.Properties.Name)
    return ($credentialPropertyNames -contains 'AuthType' -and [string]$EnvironmentConfiguration.Credentials.AuthType -eq 'WIF')
}

function Initialize-GitHubSharedWorkflowAccessPolicy {
    <#
    .SYNOPSIS
        Ensures a private shared action repository has its Actions access policy configured
        to allow other repositories owned by the same user or organization to use its composite actions.
    .DESCRIPTION
        Public repositories need no update. Private repositories use organization
        or user access according to owner type, writing only when the policy differs.
        Missing repository details warn and return; other API failures propagate.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo
    )

    $repoDetails = Invoke-GhApi -Endpoint "repos/$Owner/$Repo"
    if (-not $repoDetails) {
        Write-Warning "Could not retrieve repository details for '$Owner/$Repo'; skipping Actions access policy check."
        return
    }

    if (-not $repoDetails.private) {
        Write-Host "Shared action repository '$Owner/$Repo' is public; no Actions access policy configuration required." -ForegroundColor DarkGray
        return
    }

    # Private repo: set access_level so other repos owned by the same user/org can use its composite actions.
    # See: https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository#allowing-access-to-components-in-a-private-repository
    $ownerType = $repoDetails.owner.type
    $accessLevel = if ($ownerType -eq 'Organization') { 'organization' } else { 'user' }

    $currentPolicy = Invoke-GhApi -Endpoint "repos/$Owner/$Repo/actions/permissions/access" -AllowNotFound
    if ($currentPolicy -and $currentPolicy.access_level -eq $accessLevel) {
        Write-Host "Shared action repository '$Owner/$Repo' Actions access policy is already set to '$accessLevel'." -ForegroundColor DarkGray
        return
    }

    Write-Host "Setting Actions access policy on '$Owner/$Repo' to '$accessLevel' so its composite actions are accessible from other private repositories..." -ForegroundColor Yellow
    Invoke-GhApi -Endpoint "repos/$Owner/$Repo/actions/permissions/access" -Method 'PUT' -Body @{ access_level = $accessLevel } | Out-Null
    Write-Host "Actions access policy set to '$accessLevel' on '$Owner/$Repo'." -ForegroundColor Green
}

function Get-GitHubActionsVariableValue {
    <#
    .SYNOPSIS
        Reads one Actions variable from repository scope or a named environment.
    .DESCRIPTION
        Blank EnvironmentName selects repository scope; no cross-scope fallback is
        performed here. Returns the string value, or null for a missing response/value.
        API failures other than allowed not-found errors propagate.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$VariableName,
        [Parameter()][string]$EnvironmentName
    )

    $encodedVariableName = [Uri]::EscapeDataString($VariableName)
    $endpoint = if ([string]::IsNullOrWhiteSpace($EnvironmentName)) {
        "repos/$Owner/$Repo/actions/variables/$encodedVariableName"
    }
    else {
        $encodedEnvironmentName = [Uri]::EscapeDataString($EnvironmentName)
        "repos/$Owner/$Repo/environments/$encodedEnvironmentName/variables/$encodedVariableName"
    }

    $result = Invoke-GhApi -Endpoint $endpoint -AllowNotFound
    if ($null -eq $result) {
        return $null
    }

    if ($result.PSObject.Properties.Name -contains 'value') {
        return [string]$result.value
    }

    return $null
}

function Test-GitHubActionSecretExistence {
    # Query metadata only: GitHub cannot return a secret's value. A blank environment
    # selects repository scope; not-found is false while other API failures propagate.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$SecretName,
        [Parameter()][string]$EnvironmentName
    )

    $encodedSecretName = [Uri]::EscapeDataString($SecretName)
    $endpoint = if ([string]::IsNullOrWhiteSpace($EnvironmentName)) {
        "repos/$Owner/$Repo/actions/secrets/$encodedSecretName"
    }
    else {
        $encodedEnvironmentName = [Uri]::EscapeDataString($EnvironmentName)
        "repos/$Owner/$Repo/environments/$encodedEnvironmentName/secrets/$encodedSecretName"
    }

    $result = Invoke-GhApi -Endpoint $endpoint -AllowNotFound
    return ($null -ne $result)
}

function Get-GitRepoFileContentFromRemoteBranch {
    <#
    .SYNOPSIS
        Reads committed file content, preferring origin/Branch over the local Branch.
    .DESCRIPTION
        Does not fetch or switch branches. Returns nonblank git-show output as text,
        or null when neither candidate succeeds with content.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$RelativePath
    )

    $normalizedPath = $RelativePath.Replace('\\', '/')
    $candidateRefs = @("origin/$Branch", $Branch)
    foreach ($candidateRef in $candidateRefs) {
        $content = (& git -C $RepoRoot show "${candidateRef}:${normalizedPath}" 2>$null | Out-String)
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($content)) {
            return $content
        }
    }

    return $null
}

function Get-GitHubExistingEnvironmentState {
    <#
    .SYNOPSIS
        Reconstructs reusable configuration from GitHub variable and secret metadata.
    .DESCRIPTION
        Resolves each value from environment, prefixed repository, then unprefixed
        repository scope. StorageScope reflects discovered values, not necessarily
        the source of every field. Returns null when no storage scope is detected.
        Any matching secret metadata implies Secret auth, but ClientSecret remains
        null because existing values cannot be read; otherwise an app implies WIF.
        TenantId fills a missing stored tenant and app lookup enriches the record.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter()][string]$TenantId
    )

    $environmentClientId = Get-GitHubActionsVariableValue -Owner $Owner -Repo $Repo -EnvironmentName $EnvironmentName -VariableName 'AZURE_CLIENT_ID'
    $environmentTenantId = Get-GitHubActionsVariableValue -Owner $Owner -Repo $Repo -EnvironmentName $EnvironmentName -VariableName 'AZURE_TENANT_ID'
    $environmentUrl = Get-GitHubActionsVariableValue -Owner $Owner -Repo $Repo -EnvironmentName $EnvironmentName -VariableName 'DATAVERSE_URL'
    $environmentServiceAccount = Get-GitHubActionsVariableValue -Owner $Owner -Repo $Repo -EnvironmentName $EnvironmentName -VariableName 'DATAVERSESERVICEACCOUNTUPN'
    $environmentSecretExists = Test-GitHubActionSecretExistence -Owner $Owner -Repo $Repo -EnvironmentName $EnvironmentName -SecretName 'AZURE_CLIENT_SECRET'

    $prefix = Get-GitHubEnvironmentPrefix -EnvironmentName $EnvironmentName
    $prefixedClientId = Get-GitHubActionsVariableValue -Owner $Owner -Repo $Repo -VariableName "${prefix}AZURE_CLIENT_ID"
    $prefixedTenantId = Get-GitHubActionsVariableValue -Owner $Owner -Repo $Repo -VariableName "${prefix}AZURE_TENANT_ID"
    $prefixedUrl = ConvertTo-NormalizedEnvironmentUrl -Url (Get-GitHubActionsVariableValue -Owner $Owner -Repo $Repo -VariableName "${prefix}DATAVERSE_URL")
    $prefixedServiceAccount = Get-GitHubActionsVariableValue -Owner $Owner -Repo $Repo -VariableName "${prefix}DATAVERSE_SERVICE_ACCOUNT_UPN"
    $prefixedSecretExists = Test-GitHubActionSecretExistence -Owner $Owner -Repo $Repo -SecretName "${prefix}AZURE_CLIENT_SECRET"

    $repositoryClientId = Get-GitHubActionsVariableValue -Owner $Owner -Repo $Repo -VariableName 'AZURE_CLIENT_ID'
    $repositoryTenantId = Get-GitHubActionsVariableValue -Owner $Owner -Repo $Repo -VariableName 'AZURE_TENANT_ID'
    $repositoryUrl = ConvertTo-NormalizedEnvironmentUrl -Url (Get-GitHubActionsVariableValue -Owner $Owner -Repo $Repo -VariableName 'DATAVERSE_URL')
    $repositoryServiceAccount = Get-GitHubActionsVariableValue -Owner $Owner -Repo $Repo -VariableName 'DATAVERSESERVICEACCOUNTUPN'
    if ([string]::IsNullOrWhiteSpace($repositoryServiceAccount)) {
        $repositoryServiceAccount = Get-GitHubActionsVariableValue -Owner $Owner -Repo $Repo -VariableName 'DATAVERSE_SERVICE_ACCOUNT_UPN'
    }
    $repositorySecretExists = Test-GitHubActionSecretExistence -Owner $Owner -Repo $Repo -SecretName 'AZURE_CLIENT_SECRET'

    $hasEnvironmentValues = -not [string]::IsNullOrWhiteSpace($environmentClientId) -or
        -not [string]::IsNullOrWhiteSpace($environmentUrl) -or
        -not [string]::IsNullOrWhiteSpace($environmentServiceAccount)

    $applicationId = if (-not [string]::IsNullOrWhiteSpace($environmentClientId)) { $environmentClientId } elseif (-not [string]::IsNullOrWhiteSpace($prefixedClientId)) { $prefixedClientId } else { $repositoryClientId }
    $resolvedTenantId = if (-not [string]::IsNullOrWhiteSpace($environmentTenantId)) { $environmentTenantId } elseif (-not [string]::IsNullOrWhiteSpace($prefixedTenantId)) { $prefixedTenantId } else { $repositoryTenantId }
    $environmentUrl = ConvertTo-NormalizedEnvironmentUrl -Url $(if (-not [string]::IsNullOrWhiteSpace($environmentUrl)) { $environmentUrl } elseif (-not [string]::IsNullOrWhiteSpace($prefixedUrl)) { $prefixedUrl } else { $repositoryUrl })
    $serviceAccountUPN = if (-not [string]::IsNullOrWhiteSpace($environmentServiceAccount)) { $environmentServiceAccount } elseif (-not [string]::IsNullOrWhiteSpace($prefixedServiceAccount)) { $prefixedServiceAccount } else { $repositoryServiceAccount }
    $hasExistingSecret = $environmentSecretExists -or $prefixedSecretExists -or $repositorySecretExists

    $hasPrefixedRepositoryValues = -not [string]::IsNullOrWhiteSpace($prefixedClientId) -or
        -not [string]::IsNullOrWhiteSpace($prefixedUrl) -or
        -not [string]::IsNullOrWhiteSpace($prefixedServiceAccount)
    $hasUnprefixedRepositoryValues = -not [string]::IsNullOrWhiteSpace($repositoryClientId) -or
        -not [string]::IsNullOrWhiteSpace($repositoryUrl) -or
        -not [string]::IsNullOrWhiteSpace($repositoryServiceAccount)

    $storageScope = if ($hasEnvironmentValues) {
        'Environment'
    }
    elseif ($hasPrefixedRepositoryValues -or $prefixedSecretExists) {
        'RepositoryPrefix'
    }
    elseif ($hasUnprefixedRepositoryValues -or $repositorySecretExists) {
        'RepositoryUnprefixed'
    }
    elseif ($environmentSecretExists) {
        'Environment'
    }
    else {
        $null
    }

    if (-not $storageScope) {
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($resolvedTenantId)) {
        $resolvedTenantId = $TenantId
    }

    $existingCredential = $null
    if (-not [string]::IsNullOrWhiteSpace($applicationId)) {
        $application = Resolve-EntraIdApplicationByAppId -ApplicationId $applicationId -TenantId $resolvedTenantId
        $existingCredential = [pscustomobject]@{
            Name                = $(if ($application -and -not [string]::IsNullOrWhiteSpace($application.displayName)) { $application.displayName } else { "Existing-$EnvironmentName" })
            ApplicationId       = $applicationId
            ApplicationObjectId = $(if ($application) { $application.id } else { $null })
            ClientSecret        = $null
            TenantId            = $resolvedTenantId
            AuthType            = $(if ($hasExistingSecret) { 'Secret' } else { 'WIF' })
            HasExistingSecret   = $hasExistingSecret
            IsExistingCredential = $true
        }
    }

    $friendlyName = Resolve-DataverseEnvironmentFriendlyName -EnvironmentUrl $environmentUrl -FallbackName $EnvironmentName

    return [pscustomobject]@{
        ShortName         = $EnvironmentName
        FriendlyName      = $friendlyName
        Url               = $environmentUrl
        Credentials       = $existingCredential
        ServiceAccountUPN = $serviceAccountUPN
        StorageScope      = $storageScope
    }
}

function Get-GitHubRepositoryExistingSetupState {
    <#
    .SYNOPSIS
        Builds the wizard's initial state from alm-config.psd1 and optional remote credentials.
    .DESCRIPTION
        Branch mappings and shared workflow settings come only from alm-config.psd1.
        Keeps configured stages with missing credentials as placeholder records so
        interactive setup can repair them. ApplyConfig skips remote credential lookup.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$RepoOwner,
        [Parameter(Mandatory)][string]$RepoName,
        [Parameter(Mandatory)][string]$DefaultBranch,
        [Parameter()][string]$TenantId,
        [Parameter()][switch]$SkipProviderState
    )

    $committedConfigContent = Get-GitRepoFileContentFromRemoteBranch -RepoRoot $RepoRoot -Branch $DefaultBranch -RelativePath 'alm-config.psd1'
    $existingConfiguration = ConvertFrom-AlmConfigContentForSetup -ConfigContent ([string]$committedConfigContent)
    $configuredProvider = [string](Get-OptionalObjectPropertyValue -InputObject $existingConfiguration -PropertyName 'provider')
    if (-not [string]::IsNullOrWhiteSpace($configuredProvider) -and $configuredProvider -ine 'GitHub') {
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
        $deploymentBranchMappings = @()
        $deploymentEnvironments = @()
        $storageScope = $null
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

            $devEnvironment = $null
            if (-not [string]::IsNullOrWhiteSpace($devEnvironmentName)) {
                if (-not $SkipProviderState) {
                    $devEnvironment = Get-GitHubExistingEnvironmentState -Owner $RepoOwner -Repo $RepoName -EnvironmentName $devEnvironmentName -TenantId $TenantId
                }
                if (-not $devEnvironment) {
                    $devEnvironment = [pscustomobject]@{
                        ShortName         = $devEnvironmentName
                        FriendlyName      = $devEnvironmentName
                        Url               = $null
                        Credentials       = $null
                        ServiceAccountUPN = $null
                        StorageScope      = $null
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

            $mappedDeploymentEnvironments = @()
            foreach ($environmentName in $deploymentEnvironmentNames) {
                if ($environmentName -isnot [string] -or [string]::IsNullOrWhiteSpace($environmentName)) {
                    throw "The deploymentEnvironments setting for branch '$branchName' must contain non-empty environment names."
                }

                $environmentState = $deploymentEnvironments | Where-Object { $_.ShortName -ieq $environmentName } | Select-Object -First 1
                if (-not $environmentState) {
                    if (-not $SkipProviderState) {
                        $environmentState = Get-GitHubExistingEnvironmentState -Owner $RepoOwner -Repo $RepoName -EnvironmentName $environmentName -TenantId $TenantId
                    }
                    if (-not $environmentState) {
                        $environmentState = [pscustomobject]@{
                            ShortName         = $environmentName
                            FriendlyName      = $environmentName
                            Url               = $null
                            Credentials       = $null
                            ServiceAccountUPN = $null
                            StorageScope      = $null
                        }
                    }
                    $deploymentEnvironments += $environmentState
                    if (-not $storageScope -and $environmentState.StorageScope) {
                        $storageScope = $environmentState.StorageScope
                    }
                }
                $mappedDeploymentEnvironments += $environmentState
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
            $buildValidationEnvironment = $null
            if (-not [string]::IsNullOrWhiteSpace($buildEnvironmentName)) {
                if (-not $SkipProviderState) {
                    $buildValidationEnvironment = Get-GitHubExistingEnvironmentState -Owner $RepoOwner -Repo $RepoName -EnvironmentName $buildEnvironmentName -TenantId $TenantId
                }
                if (-not $buildValidationEnvironment) {
                    $buildValidationEnvironment = [pscustomobject]@{
                        ShortName         = $buildEnvironmentName
                        FriendlyName      = $buildEnvironmentName
                        Url               = $null
                        Credentials       = $null
                        ServiceAccountUPN = $null
                        StorageScope      = $null
                    }
                }
                if (-not $storageScope -and $buildValidationEnvironment.StorageScope) {
                    $storageScope = $buildValidationEnvironment.StorageScope
                }
            }

            $branchState = [pscustomobject]@{
                BranchName                           = [string]$branchName
                ExistingDevEnvironment               = $devEnvironment
                DeploymentEnvironments               = @($mappedDeploymentEnvironments)
                ExistingBuildValidationEnvironment   = $buildValidationEnvironment
                BuildValidationEnvironmentName       = $buildEnvironmentName
                BuildValidationBaselineRelease       = $buildValidationBaselineRelease
            }
            $branchStates += $branchState
            $deploymentBranchMappings += [pscustomobject]@{
                BranchName                           = [string]$branchName
                Environments                         = @($mappedDeploymentEnvironments)
                ExistingDevEnvironment               = $devEnvironment
                ExistingBuildValidationEnvironment   = $buildValidationEnvironment
                BuildValidationEnvironmentName       = $buildEnvironmentName
                BuildValidationBaselineRelease       = $buildValidationBaselineRelease
            }
            if ($branchName -ieq $DefaultBranch) {
                $defaultBranchState = $branchState
            }
            if (-not $storageScope -and $devEnvironment -and $devEnvironment.StorageScope) {
                $storageScope = $devEnvironment.StorageScope
            }
        }

        return [pscustomobject]@{
            SharedWorkflowRepository = [string](Get-OptionalObjectPropertyValue -InputObject $existingConfiguration -PropertyName 'repository')
            SharedWorkflowReference  = [string](Get-OptionalObjectPropertyValue -InputObject $existingConfiguration -PropertyName 'ref')
            DefaultBranchBuildValidationEnabled = [bool]($defaultBranchState -and -not [string]::IsNullOrWhiteSpace($defaultBranchState.BuildValidationEnvironmentName))
            BuildValidationEnabled   = [bool](@($branchStates | Where-Object { -not [string]::IsNullOrWhiteSpace($_.BuildValidationEnvironmentName) }).Count -gt 0)
            BuildValidationEnvironmentName = $(if ($defaultBranchState) { [string]$defaultBranchState.BuildValidationEnvironmentName } else { '' })
            ExistingBuildValidationEnvironment = $(if ($defaultBranchState) { $defaultBranchState.ExistingBuildValidationEnvironment } else { $null })
            ExistingConfiguration    = $existingConfiguration
            BranchStates             = @($branchStates)
            CredentialStorageScope   = $storageScope
            DevEnvironment           = $(if ($defaultBranchState) { $defaultBranchState.ExistingDevEnvironment } else { $null })
            DeploymentEnvironments   = @($deploymentEnvironments)
            DeploymentBranchMappings = @($deploymentBranchMappings)
        }
    }

    $devEnvironment = $null
    if (-not $SkipProviderState) {
        $devEnvironment = Get-GitHubExistingEnvironmentState -Owner $RepoOwner -Repo $RepoName -EnvironmentName "Dev-$DefaultBranch" -TenantId $TenantId
    }

    return [pscustomobject]@{
        SharedWorkflowRepository = [string](Get-OptionalObjectPropertyValue -InputObject $existingConfiguration -PropertyName 'repository')
        SharedWorkflowReference  = [string](Get-OptionalObjectPropertyValue -InputObject $existingConfiguration -PropertyName 'ref')
        DefaultBranchBuildValidationEnabled = $false
        BuildValidationEnabled   = $false
        BuildValidationEnvironmentName = ''
        ExistingBuildValidationEnvironment = $null
        ExistingConfiguration    = $existingConfiguration
        CredentialStorageScope   = [string](Get-OptionalObjectPropertyValue -InputObject $devEnvironment -PropertyName 'StorageScope')
        DevEnvironment           = $devEnvironment
        DeploymentEnvironments   = @()
        DeploymentBranchMappings = @()
        BranchStates             = @()
    }
}

function Get-GitHubInitialBranchMapping {
    # Adapt config-backed branch state to the editor contract. An empty config starts
    # with DefaultBranch, and a DEV-only branch is preserved without deploy stages.
    [CmdletBinding()]
    [OutputType([pscustomobject], [object[]])]
    param(
        [Parameter(Mandatory)][object]$ExistingSetupState,
        [Parameter(Mandatory)][string]$DefaultBranch
    )

    $branchMappings = @()
    foreach ($mapping in @($ExistingSetupState.DeploymentBranchMappings)) {
        if ($null -eq $mapping -or [string]::IsNullOrWhiteSpace([string]$mapping.BranchName)) {
            continue
        }

        $mappingProperties = @($mapping.PSObject.Properties.Name)
        $validationEnvironmentName = if ($mappingProperties -contains 'BuildValidationEnvironmentName') {
            [string]$mapping.BuildValidationEnvironmentName
        }
        else {
            [string](Get-OptionalObjectPropertyValue -InputObject $ExistingSetupState -PropertyName 'BuildValidationEnvironmentName')
        }
        $validationEnvironment = if ($mappingProperties -contains 'ExistingBuildValidationEnvironment') {
            $mapping.ExistingBuildValidationEnvironment
        }
        else {
            Get-OptionalObjectPropertyValue -InputObject $ExistingSetupState -PropertyName 'ExistingBuildValidationEnvironment'
        }
        $baselineRelease = if ($mappingProperties -contains 'BuildValidationBaselineRelease') {
            [string]$mapping.BuildValidationBaselineRelease
        }
        else {
            $legacyBuildValidation = Get-OptionalObjectPropertyValue -InputObject (Get-OptionalObjectPropertyValue -InputObject $ExistingSetupState -PropertyName 'ExistingConfiguration') -PropertyName 'buildValidation'
            [string](Get-OptionalObjectPropertyValue -InputObject $legacyBuildValidation -PropertyName 'baselineRelease')
        }

        $branchMappings += [pscustomobject]@{
            BranchName                         = [string]$mapping.BranchName
            Environments                       = @($mapping.Environments | Where-Object { $null -ne $_ })
            ExistingDevEnvironment             = Get-OptionalObjectPropertyValue -InputObject $mapping -PropertyName 'ExistingDevEnvironment'
            ExistingBuildValidationEnvironment = $validationEnvironment
            BuildValidationEnvironmentName     = $validationEnvironmentName
            BuildValidationBaselineRelease     = $baselineRelease
        }
    }

    if ($branchMappings.Count -eq 0) {
        $defaultEnvironments = @($ExistingSetupState.DeploymentEnvironments | Where-Object { $null -ne $_ })
        $branchMappings = @(
            [pscustomobject]@{
                BranchName                         = $DefaultBranch
                Environments                       = $defaultEnvironments
                ExistingDevEnvironment             = $ExistingSetupState.DevEnvironment
                ExistingBuildValidationEnvironment = Get-OptionalObjectPropertyValue -InputObject $ExistingSetupState -PropertyName 'ExistingBuildValidationEnvironment'
                BuildValidationEnvironmentName     = [string](Get-OptionalObjectPropertyValue -InputObject $ExistingSetupState -PropertyName 'BuildValidationEnvironmentName')
                BuildValidationBaselineRelease     = ''
            }
        )
    }
    elseif (
        -not ($branchMappings | Where-Object { $_.BranchName -ieq $DefaultBranch }) -and
        ($ExistingSetupState.DevEnvironment -or $ExistingSetupState.ExistingBuildValidationEnvironment -or $ExistingSetupState.BuildValidationEnabled)
    ) {
        $branchMappings += [pscustomobject]@{
            BranchName                         = $DefaultBranch
            Environments                       = @()
            ExistingDevEnvironment             = $ExistingSetupState.DevEnvironment
            ExistingBuildValidationEnvironment = Get-OptionalObjectPropertyValue -InputObject $ExistingSetupState -PropertyName 'ExistingBuildValidationEnvironment'
            BuildValidationEnvironmentName     = [string](Get-OptionalObjectPropertyValue -InputObject $ExistingSetupState -PropertyName 'BuildValidationEnvironmentName')
            BuildValidationBaselineRelease     = ''
        }
    }

    return @($branchMappings | Sort-Object BranchName -Unique)
}

function New-GitHubBranchSetupState {
    # Mutable wizard record: null configuration/plan means not selected yet, while
    # an empty DeploymentEnvironments array is a valid DEV-only branch.
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

function Initialize-GitHubApplicationRepositoryContext {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'TenantId', Justification = 'Captured by the nested repository-state status callback.')]
    [CmdletBinding()]
    param(
        [Parameter()][string]$TenantId,
        [Parameter()][switch]$ApplyConfig,
        [Parameter()][switch]$ExistingSetupMode
    )

    Write-Section -Message 'Select GitHub Repository'

    $repos = @(Invoke-WithSpectreStatus -Status 'Fetching repositories you have write access to...' -ScriptBlock {
        Get-GitHubRepoList
    })
    $repos = @($repos | Sort-Object -Property nameWithOwner)
    $repoMenuItems = @()
    $repoMenuActions = @()

    if ($ApplyConfig -and $repos.Count -eq 0) {
        throw 'ApplyConfig requires an existing GitHub repository containing alm-config.psd1.'
    }
    if ($ExistingSetupMode -and $repos.Count -eq 0) {
        throw 'Existing-repository setup requires an existing GitHub repository.'
    }
    if (-not $ApplyConfig -and -not $ExistingSetupMode) {
        $repoMenuItems += 'Create a new repository'
        $repoMenuActions += @{ Type = 'CreateNew' }
    }

    foreach ($repo in $repos) {
        $repoMenuItems += "Use existing repository: $($repo.nameWithOwner)"
        $repoMenuActions += @{ Type = 'UseExisting'; Repo = $repo }
    }

    $repoSelection = Select-FromMenu -Title 'Select the repository to set up ALM4Dataverse in' -Items $repoMenuItems -PromptGuidanceLines @(
        'Choose the target repository for ALM4Dataverse shared workflows.',
        'This must be a separate repository from your main application repository.'
    ) -PromptGuidanceDocRelativePath 'docs/setup/github-setup.md' -PromptGuidanceRef $ALM4DataverseRef
    if ($null -eq $repoSelection) {
        Request-SetupWizardBack
    }

    $repoAction = $repoMenuActions[$repoSelection]
    $isNewRepository = $repoAction.Type -eq 'CreateNew'
    if ($repoAction.Type -eq 'UseExisting') {
        $selectedRepo = $repoAction.Repo
    }
    else {
        $selectedRepo = Invoke-WithErrorHandling -OperationName 'Creating GitHub repository' -ScriptBlock {
            New-GitHubRepositoryInteractive -DefaultOwner $script:ghUser
        }
    }

    $repoOwner = $selectedRepo.owner.login
    $repoName = $selectedRepo.name
    $repoFullName = $selectedRepo.nameWithOwner

    Write-Host "Selected: $repoFullName" -ForegroundColor Cyan

    $repoIdentity = Invoke-WithSpectreStatus -Status "Loading GitHub owner and repository IDs for '$repoFullName'..." -ScriptBlock {
        Get-GitHubRepositoryIdentity -Owner $repoOwner -Repo $repoName
    }
    $repoOwnerId = [long]$repoIdentity.OwnerId
    $repoId = [long]$repoIdentity.RepositoryId
    $useImmutableWifSubject = [bool]$repoIdentity.UseImmutableSubject
    $wifSubjectFormat = if ($useImmutableWifSubject) { 'immutable owner/repository ID' } else { 'legacy owner/repository name' }
    Write-Host "GitHub OIDC identity: owner ID $repoOwnerId, repository ID $repoId ($wifSubjectFormat subject format)" -ForegroundColor DarkGray

    $defaultBranch = 'main'
    if ($selectedRepo.defaultBranchRef -and $selectedRepo.defaultBranchRef.name) {
        $defaultBranch = $selectedRepo.defaultBranchRef.name
    }
    Write-Host "Default branch: $defaultBranch"

    Write-Section -Message 'Cloning Repository'
    $cloneRoot = Invoke-WithErrorHandling -OperationName 'Cloning repository' -ScriptBlock {
        $attemptCloneRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ALM4Dataverse-GH-' + [guid]::NewGuid().ToString('n'))
        Write-Host "Cloning $repoFullName to $attemptCloneRoot..." -ForegroundColor Yellow

        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $cloneOutput = @(& gh repo clone $repoFullName $attemptCloneRoot -- --depth 1 2>&1)
            $cloneExitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        if ($cloneExitCode -ne 0) {
            $cloneErrorDetails = @($cloneOutput | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $cloneErrorMessage = if ($cloneErrorDetails.Count -gt 0) { $cloneErrorDetails[-1] } else { "Exit code: $cloneExitCode" }
            throw "gh repo clone failed. $cloneErrorMessage"
        }

        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $fetchOutput = @(& git -C $attemptCloneRoot fetch origin '+refs/heads/*:refs/remotes/origin/*' --prune 2>&1)
            $fetchExitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        if ($fetchExitCode -ne 0) {
            $fetchErrorDetails = @($fetchOutput | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $fetchErrorMessage = if ($fetchErrorDetails.Count -gt 0) { $fetchErrorDetails[-1] } else { "Exit code: $fetchExitCode" }
            throw "git fetch failed while retrieving remote branches. $fetchErrorMessage"
        }

        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            [void](& git -C $attemptCloneRoot reset --hard HEAD 2>&1)
            [void](& git -C $attemptCloneRoot clean -fd 2>&1)
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        Invoke-GitHubCloneBaseBranchCheckout -RepoRoot $attemptCloneRoot -DefaultBranch $defaultBranch

        return [pscustomobject]@{
            CloneRoot = $attemptCloneRoot
        }
    } -StatusMessage 'Cloning the selected repository...' -CaptureOutputInPanel

    $cloneRoot = if ($cloneRoot -and $cloneRoot.PSObject.Properties.Name -contains 'CloneRoot') { [string]$cloneRoot.CloneRoot } else { [string]$cloneRoot }
    if ([string]::IsNullOrWhiteSpace($cloneRoot)) {
        throw 'Clone operation did not produce a working directory path.'
    }

    $existingSetupState = Invoke-WithSpectreStatus -Status 'Inspecting the existing repository configuration...' -ScriptBlock {
        Get-GitHubRepositoryExistingSetupState `
            -RepoRoot $cloneRoot `
            -RepoOwner $repoOwner `
            -RepoName $repoName `
            -DefaultBranch $defaultBranch `
            -TenantId $TenantId `
            -SkipProviderState:$ApplyConfig
    }

    return [pscustomobject]@{
        SelectedRepo = $selectedRepo
        RepoOwner = $repoOwner
        RepoName = $repoName
        RepoFullName = $repoFullName
        RepoIdentity = $repoIdentity
        RepoOwnerId = $repoOwnerId
        RepoId = $repoId
        UseImmutableWifSubject = $useImmutableWifSubject
        DefaultBranch = $defaultBranch
        CloneRoot = $cloneRoot
        ExistingSetupState = $existingSetupState
        IsNewRepository = $isNewRepository
    }
}
