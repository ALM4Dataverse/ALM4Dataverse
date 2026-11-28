function Initialize-EntraIdServicePrincipal {
    <#
    .SYNOPSIS
        Returns the tenant's first service principal for ApplicationId, creating it if absent.
    .DESCRIPTION
        Acquires a Graph token for TenantId and uses the application's client ID,
        not its application-object ID. When CreateIfMissing is false and the
        enterprise application is absent, throws with remediation guidance instead of
        attempting a write the account is known not to be allowed to make. Graph
        failures propagate; this remote mutation has no ShouldProcess guard.
    .PARAMETER CreateIfMissing
        Creates the service principal when it is absent. False is used after setup
        detects that the signed-in user cannot create applications or service
        principals.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ApplicationId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter()][bool]$CreateIfMissing = $true
    )

    $graphToken = Get-AuthToken -ResourceUrl "https://graph.microsoft.com" -TenantId $TenantId
    $headers = @{
        Authorization  = "Bearer $($graphToken.AccessToken)"
        "Content-Type" = "application/json"
    }

    $uri = "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$ApplicationId'"
    $existing = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get

    if ($existing.value.Count -gt 0) {
        Write-Host "Service Principal for App '$ApplicationId' already exists."
        return $existing.value[0]
    }

    if (-not $CreateIfMissing) {
        throw "Service Principal for App '$ApplicationId' does not exist and the signed-in account cannot create one. Ask an Entra administrator to create the enterprise application, then run setup again."
    }

    Write-Host "Creating Service Principal for App '$ApplicationId'..." -ForegroundColor Yellow
    $body = @{ appId = $ApplicationId }
    try {
        $sp = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/servicePrincipals" -Headers $headers -Method Post -Body ($body | ConvertTo-Json)
    }
    catch {
        throw "Failed to create the service principal for App '$ApplicationId'. The signed-in account must be allowed to create applications and service principals. $($_.Exception.Message)"
    }
    Write-Host "Created Service Principal."
    return $sp
}

function Add-EntraIdFederatedCredential {
    <#
    .SYNOPSIS
        Adds a federated identity credential to an Entra ID application for Workload Identity Federation.

    .DESCRIPTION
        Reconciles the named credential through Graph beta using GitHub's issuer and
        AzureADTokenExchange audience. A same-name record is returned if current or
        patched if issuer/subject/audience differ; an empty PATCH response is re-read.
        Without a name match, an existing issuer/subject match is reused regardless
        of its name. A failed listing warns but still permits a create attempt.
        Write failures propagate; no ShouldProcess guard is provided.
    .PARAMETER ApplicationObjectId
        App registration object ID, not the client ID or enterprise application ID.
    .PARAMETER Subject
        Exact subject constructed for the repository's effective OIDC mode and environment.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ApplicationObjectId,
        [Parameter()][string]$TenantId,
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$CredentialName,
        [Parameter()][string]$Description = 'GitHub Actions WIF credential (created by setup-github.ps1)'
    )

    $graphToken = Get-AuthToken -ResourceUrl "https://graph.microsoft.com" -TenantId $TenantId
    $headers = @{
        Authorization  = "Bearer $($graphToken.AccessToken)"
        "Content-Type" = "application/json"
    }

    Write-Host "Adding federated identity credential '$CredentialName'..." -ForegroundColor Yellow

    $listUri = "https://graph.microsoft.com/beta/applications/$ApplicationObjectId/federatedIdentityCredentials"
    $issuer = 'https://token.actions.githubusercontent.com'
    $audience = 'api://AzureADTokenExchange'
    $body = @{
        name        = $CredentialName
        issuer      = $issuer
        subject     = $Subject
        audiences   = @($audience)
        description = $Description
    }

    $existing = $null
    try {
        $existing = Invoke-RestMethod -Uri $listUri -Headers $headers -Method Get
    }
    catch {
        Write-Warning "Failed to check for existing federated credentials: $($_.Exception.Message)"
    }

    $existingCredentials = if ($existing -and $existing.PSObject.Properties.Name -contains 'value') {
        @($existing.value)
    }
    else {
        @()
    }

    $match = @($existingCredentials | Where-Object { $_.name -eq $CredentialName }) | Select-Object -First 1
    if ($match) {
        $existingAudiences = @($match.audiences | ForEach-Object { [string]$_ })
        $isCurrent = (
            [string]$match.issuer -eq $issuer -and
            [string]$match.subject -eq $Subject -and
            $existingAudiences.Count -eq 1 -and
            $existingAudiences[0] -eq $audience
        )

        if ($isCurrent) {
            Write-Host "Federated credential '$CredentialName' already exists."
            return $match
        }

        if ([string]::IsNullOrWhiteSpace([string]$match.id)) {
            throw "Federated credential '$CredentialName' exists but its ID could not be determined for update."
        }

        Write-Host "Federated credential '$CredentialName' exists with outdated WIF settings; updating it..." -ForegroundColor Yellow
        $credentialUri = "$listUri/$([Uri]::EscapeDataString([string]$match.id))"
        $updateBody = @{
            issuer      = $issuer
            subject     = $Subject
            audiences   = @($audience)
            description = $Description
        }
        try {
            $updated = Invoke-RestMethod `
                -Uri $credentialUri `
                -Headers $headers `
                -Method Patch `
                -Body ($updateBody | ConvertTo-Json -Depth 10)

            Write-Host "Updated federated identity credential successfully."
            if ($updated) {
                return $updated
            }

            return Invoke-RestMethod -Uri $credentialUri -Headers $headers -Method Get
        }
        catch {
            Write-Error "Failed to update federated identity credential: $($_.Exception.Message) Ensure the signed-in account owns the App Registration or has an Entra application administrator role."
            throw
        }
    }

    $subjectMatch = @($existingCredentials | Where-Object {
        [string]$_.issuer -eq $issuer -and [string]$_.subject -eq $Subject
    }) | Select-Object -First 1
    if ($subjectMatch) {
        Write-Host "Federated credential for this issuer and subject already exists as '$($subjectMatch.name)'."
        return $subjectMatch
    }

    try {
        $result = Invoke-RestMethod -Uri $listUri -Headers $headers -Method Post -Body ($body | ConvertTo-Json)
        Write-Host "Created federated identity credential successfully."
        return $result
    }
    catch {
        Write-Error "Failed to create federated identity credential: $($_.Exception.Message) Ensure the signed-in account owns the App Registration or has an Entra application administrator role."
        throw
    }
}

function New-EntraIdApplication {
    <#
    .SYNOPSIS
        Reuses or creates a tenant app registration and ensures its service principal.
    .DESCRIPTION
        Reuses the first exact display-name query result. Returns Name, ApplicationId,
        ApplicationObjectId, TenantId, AuthType, ClientSecret and CreatedDuringSetup.
        AuthType Secret creates a fresh secret even for a reused application; other
        values leave ClientSecret null. CreatedDuringSetup is true only when this call
        created the application. ShouldProcess guards the entire operation.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter()][string]$AuthType = 'WIF'
    )

    if (-not $PSCmdlet.ShouldProcess($DisplayName, 'Create or configure Entra application')) { return }

    $graphToken = Get-AuthToken -ResourceUrl "https://graph.microsoft.com" -TenantId $TenantId
    $headers = @{
        Authorization  = "Bearer $($graphToken.AccessToken)"
        "Content-Type" = "application/json"
    }

    $filter = "displayName eq '$DisplayName'"
    $uri = "https://graph.microsoft.com/v1.0/applications?`$filter=$filter"

    $existing = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get

    $app = $null
    $createdApplication = $false
    if ($existing.value.Count -gt 0) {
        $app = $existing.value[0]
        Write-Host "Found existing App Registration '$DisplayName' ($($app.appId))."
    }
    else {
        Write-Host "Creating App Registration '$DisplayName'..." -ForegroundColor Yellow
        # Request the Dataverse delegated scope used by the deployment token; an Entra
        # administrator must still grant consent for the tenant.
        $body = @{
            displayName    = $DisplayName
            signInAudience = "AzureADMyOrg"
            requiredResourceAccess = @(
                @{
                    resourceAppId = '00000007-0000-0000-c000-000000000000'
                    resourceAccess = @(
                        @{
                            id = '78ce3f0f-a1ce-49c2-8cde-64b5c0896db4'
                            type = 'Scope'
                        }
                    )
                }
            )
        }
        $app = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/applications" -Headers $headers -Method Post -Body ($body | ConvertTo-Json -Depth 5)
        $createdApplication = $true
        Write-Host "Created App Registration '$DisplayName' ($($app.appId))."
    }

    [void](Initialize-EntraIdServicePrincipal -ApplicationId $app.appId -TenantId $TenantId)

    $result = [pscustomobject]@{
        Name                = $DisplayName
        ApplicationId       = $app.appId
        ApplicationObjectId = $app.id
        ClientSecret        = $null
        TenantId            = $TenantId
        AuthType            = $AuthType
        CreatedDuringSetup  = $createdApplication
    }

    if ($AuthType -eq 'Secret') {
        # Create secret for traditional authentication
        Write-Host "Creating client secret..." -ForegroundColor Yellow
        $result.ClientSecret = New-EntraIdApplicationSecret -ApplicationObjectId $app.id -TenantId $TenantId
    }

    return $result
}

function Get-GitHubCredentialsForEnvironment {
    <#
    .SYNOPSIS
        Interactively selects or creates Entra ID credentials for a GitHub environment.
    .DESCRIPTION
        ExistingCredential is copied before optional secret rotation, while cached
        credentials are returned as supplied. Keeping an existing secret leaves its
        unreadable value null and retains HasExistingSecret for later storage.
        Requesting rotation marks the credential for generation at Apply instead of
        writing a secret during setup. New/manual paths return app client/object IDs,
        tenant, auth type and optional secret; they can create Graph resources before
        final wizard review. Manually entered, searched and instruction-guided
        applications are validated for existence, Dataverse permission, enterprise
        application and configured secret/WIF credentials, including the exact WIF
        subject when the repository identity is known, before use. Actions that
        need Entra app-registration write access are dimmed and rejected when the
        signed-in account's detected directory access cannot perform them; unknown
        detection leaves them available. WIF is likewise dimmed when continuing an app
        without a usable WIF credential if the account definitively cannot manage it.
        Cancelled required menus throw rather than
        returning partial credentials. When the repository identity is supplied, the
        manual instructions show the exact environment WIF subject for the repository's
        current legacy or immutable OIDC mode instead of a placeholder.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][array]$ExistingCredentials,
        [Parameter()][string]$TenantId,
        [Parameter()][string]$RepoName,
        [Parameter()][string]$EnvironmentName,
        [Parameter()][object]$ExistingCredential,
        [Parameter()][AllowEmptyString()][string]$RepoOwner,
        [Parameter()][AllowEmptyString()][string]$RepoFullName,
        [Parameter()][long]$RepoOwnerId,
        [Parameter()][long]$RepoId,
        [Parameter()][bool]$UseImmutableWifSubject
    )

    $wifSubject = $null
    if (
        -not [string]::IsNullOrWhiteSpace($RepoOwner) -and
        -not [string]::IsNullOrWhiteSpace($RepoName) -and
        -not [string]::IsNullOrWhiteSpace($RepoFullName) -and
        (-not $UseImmutableWifSubject -or ($RepoOwnerId -gt 0 -and $RepoId -gt 0))
    ) {
        $wifSubject = New-GitHubEnvironmentWifSubject `
            -RepoOwner $RepoOwner `
            -RepoName $RepoName `
            -RepoFullName $RepoFullName `
            -RepoOwnerId $RepoOwnerId `
            -RepoId $RepoId `
            -EnvironmentName $EnvironmentName `
            -UseImmutableSubject $UseImmutableWifSubject
    }

    # Detection failures return null capabilities, so the menu stays available when
    # Graph cannot answer; only a definite denial dims an action.
    $entraState = Get-EntraIdApplicationManagementState -TenantId $TenantId
    $menuItems  = @()
    $menuActions = @()
    $dimMenuItems = @()

    if ($ExistingCredential -and -not [string]::IsNullOrWhiteSpace($ExistingCredential.ApplicationId)) {
        $existingLabel = "Use existing: $($ExistingCredential.Name) ($($ExistingCredential.ApplicationId))"
        if ($ExistingCredential.AuthType -eq 'Secret' -and $ExistingCredential.HasExistingSecret) {
            $existingLabel += ' [secret already configured]'
        }
        elseif ($ExistingCredential.AuthType -eq 'WIF') {
            $existingLabel += ' [workload identity federation]'
        }

        $menuItems += $existingLabel
        $menuActions += @{ Type = 'Existing'; Creds = $ExistingCredential }
    }

    $createNewLabel = "Create new App Registration (Entra ID)"
    if ($entraState.CanCreateApplications -eq $false) {
        $createNewLabel += ' [requires Entra ID permissions]'
        $dimMenuItems += $createNewLabel
    }
    $menuItems += $createNewLabel
    $menuActions += @{ Type = 'CreateNew' }

    $menuItems  += "Enter existing App Registration details"
    $menuActions += @{ Type = 'Manual' }

    $menuItems += "Create a new application manually (with instructions)"
    $menuActions += @{ Type = 'ManualWithInstructions' }

    $searchLabel = "Search for an existing application by name"
    if ((Get-OptionalObjectPropertyValue -InputObject $entraState -PropertyName 'CanReadApplications') -eq $false) {
        $searchLabel += ' [requires Entra ID permissions]'
        $dimMenuItems += $searchLabel
    }
    $menuItems += $searchLabel
    $menuActions += @{ Type = 'Search' }

    foreach ($c in $ExistingCredentials) {
        $cachedLabel = "Reuse: $($c.Name) ($($c.ApplicationId))"
        # A reused WIF credential needs a new federated identity credential for this
        # environment's subject, which requires ownership or an admin directory role.
        $cachedAuthType = [string](Get-OptionalObjectPropertyValue -InputObject $c -PropertyName 'AuthType')
        if ($cachedAuthType -eq 'WIF') {
            $cachedTenantId = [string](Get-OptionalObjectPropertyValue -InputObject $c -PropertyName 'TenantId')
            if ([string]::IsNullOrWhiteSpace($cachedTenantId)) {
                $cachedTenantId = $TenantId
            }
            $canManageCached = Test-EntraIdApplicationManagement `
                -TenantId $cachedTenantId `
                -ApplicationObjectId ([string](Get-OptionalObjectPropertyValue -InputObject $c -PropertyName 'ApplicationObjectId')) `
                -ApplicationId ([string](Get-OptionalObjectPropertyValue -InputObject $c -PropertyName 'ApplicationId')) `
                -State $(if ($cachedTenantId -ieq $TenantId) { $entraState } else { $null })
            if ($canManageCached -eq $false) {
                $cachedLabel += ' [requires Entra ID permissions]'
                $dimMenuItems += $cachedLabel
            }
        }
        $menuItems += $cachedLabel
        $menuActions += @{ Type = 'Cached'; Creds = $c }
    }

    $guidanceLines = @(
        'App Registration credentials authenticate the workflow to Dataverse.',
        'Use a separate App Registration per environment and prefer Workload Identity Federation to avoid client-secret rotation.',
        'Select existing credentials or create a new App Registration for this environment.'
    )
    if ($dimMenuItems.Count -gt 0) {
        $guidanceLines += 'Dimmed actions need Entra ID app-registration permissions that the signed-in account does not have. Ask an Entra administrator or choose another option.'
    }

    $promptNotice = $null
    while ($true) {
        $selection = $null
        while ($null -eq $selection) {
            $currentGuidanceLines = @($guidanceLines)
            if ($promptNotice) {
                $currentGuidanceLines = @($promptNotice) + $currentGuidanceLines
            }
            $selection = Select-FromMenu `
                -Title "Select App Registration credentials for '$EnvironmentName'" `
                -Items $menuItems `
                -DimItems $dimMenuItems `
                -PromptGuidanceLines $currentGuidanceLines `
                -PromptGuidanceDocRelativePath 'docs/config/github-secrets.md' `
                -PromptGuidanceRef $ALM4DataverseRef
            if ($null -eq $selection) { throw "No credential selected." }
            if ($dimMenuItems -contains $menuItems[$selection]) {
                $promptNotice = 'The selected action is unavailable because the signed-in account does not have the required Entra ID permissions. Choose another option or ask an Entra administrator.'
                $selection = $null
            }
        }

        $action = $menuActions[$selection]

        if ($action.Type -eq 'Existing') {
            $selectedCredential = $action.Creds.PSObject.Copy()

            if ($selectedCredential.AuthType -eq 'Secret' -and $selectedCredential.HasExistingSecret) {
                $credentialTenantId = [string](Get-OptionalObjectPropertyValue -InputObject $selectedCredential -PropertyName 'TenantId')
                if ([string]::IsNullOrWhiteSpace($credentialTenantId)) {
                    $credentialTenantId = $TenantId
                }
                $canRotateExistingSecret = Test-EntraIdApplicationManagement `
                    -TenantId $credentialTenantId `
                    -ApplicationObjectId ([string](Get-OptionalObjectPropertyValue -InputObject $selectedCredential -PropertyName 'ApplicationObjectId')) `
                    -ApplicationId ([string](Get-OptionalObjectPropertyValue -InputObject $selectedCredential -PropertyName 'ApplicationId')) `
                    -State $(if ($credentialTenantId -ieq $TenantId) { $entraState } else { $null })

                $secretHandlingItems = @(
                    'Keep the existing client secret',
                    'Generate a new client secret when changes are applied'
                )
                $secretDimItems = @()
                if ($canRotateExistingSecret -eq $false) {
                    $secretHandlingItems[1] += ' [requires Entra ID permissions]'
                    $secretDimItems += $secretHandlingItems[1]
                }

                $secretHandlingSelection = $null
                $secretPromptNotice = $null
                while ($null -eq $secretHandlingSelection) {
                    $secretGuidanceLines = @(
                        'Choose whether to keep the existing secret or rotate it when changes are applied.',
                        'Rotation is deferred until Apply so the preview can list it before any credential changes.',
                        'Rotate when policy requires periodic renewal or the current secret is no longer trusted.'
                    )
                    if ($secretDimItems.Count -gt 0) {
                        $secretGuidanceLines += 'Rotation is unavailable because the signed-in account cannot manage credentials on this App Registration. Ask an Entra administrator or keep the existing secret.'
                    }
                    if ($secretPromptNotice) {
                        $secretGuidanceLines = @($secretPromptNotice) + $secretGuidanceLines
                    }
                    $secretHandlingSelection = Select-FromMenu `
                        -Title "How should setup handle the existing client secret for '$EnvironmentName'?" `
                        -Items $secretHandlingItems `
                        -DimItems $secretDimItems `
                        -PromptGuidanceLines $secretGuidanceLines `
                        -PromptGuidanceDocRelativePath 'docs/config/github-secrets.md' `
                        -PromptGuidanceRef $ALM4DataverseRef
                    if ($null -eq $secretHandlingSelection) {
                        throw 'No client secret handling option selected.'
                    }
                    if ($secretDimItems -contains $secretHandlingItems[$secretHandlingSelection]) {
                        $secretPromptNotice = 'That action is unavailable because the signed-in account cannot manage credentials on this App Registration. Choose to keep the existing secret or ask an Entra administrator.'
                        $secretHandlingSelection = $null
                    }
                }

                if ($secretHandlingSelection -eq 1) {
                    if ([string]::IsNullOrWhiteSpace($selectedCredential.ApplicationObjectId)) {
                        $resolvedApplication = Resolve-EntraIdApplicationByAppId -ApplicationId $selectedCredential.ApplicationId -TenantId $selectedCredential.TenantId
                        if ($resolvedApplication) {
                            $selectedCredential.ApplicationObjectId = $resolvedApplication.id
                            if ([string]::IsNullOrWhiteSpace($selectedCredential.Name) -and -not [string]::IsNullOrWhiteSpace($resolvedApplication.displayName)) {
                                $selectedCredential.Name = $resolvedApplication.displayName
                            }
                        }
                    }

                    if ([string]::IsNullOrWhiteSpace($selectedCredential.ApplicationObjectId)) {
                        throw "Cannot generate a new client secret for '$($selectedCredential.ApplicationId)' because the App Registration object id could not be resolved."
                    }

                    # Defer the write to Apply so preview can list it and the user can
                    # still change their mind before any credential is rotated.
                    $selectedCredential | Add-Member -NotePropertyName RotateSecret -NotePropertyValue $true -Force
                    Write-Host 'A new client secret will be generated when changes are applied.' -ForegroundColor Yellow
                }
                else {
                    # Revisiting the step copies the previous credential, so clear any
                    # rotation request the user has now declined.
                    $selectedCredential | Add-Member -NotePropertyName RotateSecret -NotePropertyValue $false -Force
                }

                return $selectedCredential
            }

            return $selectedCredential
        }
        elseif ($action.Type -eq 'Cached') {
            return $action.Creds
        }
        elseif ($action.Type -eq 'CreateNew') {
            # Prompt for authentication type
            Write-Host ""
            $authTypeItems = @(
                "Workload Identity Federation (recommended, no secrets)",
                "Service Principal with Secret (traditional)"
            )
            $authTypeSelection = Select-FromMenu -Title "Select authentication type for the new App Registration" -Items $authTypeItems -PromptGuidanceLines @(
                'Choose between workload identity federation and client-secret authentication.',
                'Workload identity federation is recommended when supported because it removes shared secret management.'
            ) -PromptGuidanceDocRelativePath 'docs/config/github-secrets.md' -PromptGuidanceRef $ALM4DataverseRef
            if ($null -eq $authTypeSelection) { throw "No authentication type selected." }

            $authType = if ($authTypeSelection -eq 0) { 'WIF' } else { 'Secret' }

            $appName = "$RepoName - $EnvironmentName - deployment"

            return New-EntraIdApplication -DisplayName $appName -TenantId $TenantId -AuthType $authType
        }
        elseif ($action.Type -eq 'Manual') {
            Write-Host "Enter App Registration details:" -ForegroundColor Cyan
            $name = Read-TextWithDefault -Prompt 'Friendly name (for reuse reference)' -AllowEmpty
            if ([string]::IsNullOrWhiteSpace($name)) { $name = "Credential-" + (Get-Date -Format "HHmm") }

            $credential = Read-SetupEntraIdApplicationCredential `
                -TenantId $TenantId `
                -ProviderName 'GitHub' `
                -Name $name `
                -ApplicationManagementState $entraState `
                -WorkloadIdentityFederationSubject $wifSubject `
                -PromptGuidanceDocRelativePath 'docs/config/github-secrets.md' `
                -PromptGuidanceRef $ALM4DataverseRef

            $validation = Get-OptionalObjectPropertyValue -InputObject $credential -PropertyName 'Validation'
            $hasServicePrincipal = Get-OptionalObjectPropertyValue -InputObject $validation -PropertyName 'HasServicePrincipal'
            $createServicePrincipal = -not ($hasServicePrincipal -eq $false -and $entraState.CanCreateApplications -eq $false)
            [void](Initialize-EntraIdServicePrincipal `
                -ApplicationId ([string](Get-OptionalObjectPropertyValue -InputObject $credential -PropertyName 'ApplicationId')) `
                -TenantId $TenantId `
                -CreateIfMissing:$createServicePrincipal)
            return $credential
        }
        elseif ($action.Type -eq 'ManualWithInstructions') {
            Write-Host "Create a new application manually (with instructions)" -ForegroundColor Cyan
            $credential = Read-SetupEntraIdApplicationCredential `
                -TenantId $TenantId `
                -ProviderName 'GitHub' `
                -ShowCreationInstructions `
                -ApplicationManagementState $entraState `
                -WorkloadIdentityFederationSubject $wifSubject `
                -PromptGuidanceDocRelativePath 'docs/config/github-secrets.md' `
                -PromptGuidanceRef $ALM4DataverseRef

            $validation = Get-OptionalObjectPropertyValue -InputObject $credential -PropertyName 'Validation'
            $hasServicePrincipal = Get-OptionalObjectPropertyValue -InputObject $validation -PropertyName 'HasServicePrincipal'
            $createServicePrincipal = -not ($hasServicePrincipal -eq $false -and $entraState.CanCreateApplications -eq $false)
            [void](Initialize-EntraIdServicePrincipal `
                -ApplicationId ([string](Get-OptionalObjectPropertyValue -InputObject $credential -PropertyName 'ApplicationId')) `
                -TenantId $TenantId `
                -CreateIfMissing:$createServicePrincipal)
            return $credential
        }
        elseif ($action.Type -eq 'Search') {
            $searchedApplication = Select-EntraIdApplicationBySearch `
                -TenantId $TenantId `
                -PromptGuidanceDocRelativePath 'docs/config/github-secrets.md' `
                -PromptGuidanceRef $ALM4DataverseRef
            if ($null -eq $searchedApplication) {
                $promptNotice = 'No application was selected from search. Choose another credential option or search again.'
                continue
            }

            $credential = Read-SetupEntraIdApplicationCredential `
                -TenantId $TenantId `
                -ProviderName 'GitHub' `
                -ApplicationId ([string]$searchedApplication.appId) `
                -ApplicationManagementState $entraState `
                -WorkloadIdentityFederationSubject $wifSubject `
                -PromptGuidanceDocRelativePath 'docs/config/github-secrets.md' `
                -PromptGuidanceRef $ALM4DataverseRef

            $validation = Get-OptionalObjectPropertyValue -InputObject $credential -PropertyName 'Validation'
            $hasServicePrincipal = Get-OptionalObjectPropertyValue -InputObject $validation -PropertyName 'HasServicePrincipal'
            $createServicePrincipal = -not ($hasServicePrincipal -eq $false -and $entraState.CanCreateApplications -eq $false)
            [void](Initialize-EntraIdServicePrincipal `
                -ApplicationId ([string](Get-OptionalObjectPropertyValue -InputObject $credential -PropertyName 'ApplicationId')) `
                -TenantId $TenantId `
                -CreateIfMissing:$createServicePrincipal)
            return $credential
        }
    }
}

function Get-GitHubCredentialSecretForApply {
    <#
    .SYNOPSIS
        Returns the client-secret value to store, performing a deferred rotation first.
    .DESCRIPTION
        Returns an already-supplied ClientSecret unchanged. When environment
        configuration only requested rotation (RotateSecret), creates the new secret
        now, during Apply, and returns it. Returns null when neither applies so callers
        can leave an existing stored secret untouched.
    .PARAMETER Credentials
        Environment credential metadata captured by Get-GitHubCredentialsForEnvironment.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][object]$Credentials
    )

    $clientSecret = [string](Get-OptionalObjectPropertyValue -InputObject $Credentials -PropertyName 'ClientSecret')
    if (-not [string]::IsNullOrWhiteSpace($clientSecret)) {
        return $clientSecret
    }
    if (-not [bool](Get-OptionalObjectPropertyValue -InputObject $Credentials -PropertyName 'RotateSecret')) {
        return $null
    }

    $applicationObjectId = [string](Get-OptionalObjectPropertyValue -InputObject $Credentials -PropertyName 'ApplicationObjectId')
    $tenantId = [string](Get-OptionalObjectPropertyValue -InputObject $Credentials -PropertyName 'TenantId')
    if ([string]::IsNullOrWhiteSpace($applicationObjectId) -or [string]::IsNullOrWhiteSpace($tenantId)) {
        throw 'Deferred client-secret rotation requires ApplicationObjectId and TenantId.'
    }

    Write-Host 'Generating the client secret requested during setup...' -ForegroundColor Yellow
    return (New-EntraIdApplicationSecret -ApplicationObjectId $applicationObjectId -TenantId $tenantId)
}

function Invoke-GitHubCliAuthenticationCommand {
    <#
    .SYNOPSIS
        Runs a GitHub CLI sign-in command and mirrors its output into the browser.
    .DESCRIPTION
        Browser setup has no visible terminal. The GitHub CLI prints a one-time code
        and verification URL while it waits, so output is streamed line by line and
        the sign-in lines are published to the browser banner until the command exits.
        Console runs invoke the CLI directly so its terminal handling is unchanged.
        The native exit code is returned for the caller to validate.
    .PARAMETER Arguments
        Arguments passed to gh.
    .PARAMETER Status
        Busy message shown in the browser while the command runs.
    .PARAMETER ShowDeviceMessages
        Publishes one-time-code and verification-URL lines to the browser banner.
    .OUTPUTS
        System.Int32 native command exit code.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Status,
        [Parameter()][switch]$ShowDeviceMessages
    )

    $webHost = Get-SetupWebHost
    if ($null -eq $webHost) {
        & gh @Arguments
        return [int]$LASTEXITCODE
    }

    Publish-SetupWebBusy -Message $Status
    $deviceLines = [System.Collections.Generic.List[string]]::new()
    Publish-SetupWebDeviceCode -Message ''
    try {
        & gh @Arguments 2>&1 | ForEach-Object {
            $line = [string]$_
            Write-Host $line
            if (-not $ShowDeviceMessages) {
                return
            }

            # gh may still emit terminal control sequences when output is redirected.
            $cleanLine = [regex]::Replace($line, '\x1b\[[0-9;?]*[ -/]*[@-~]', '').Trim()
            if ([string]::IsNullOrWhiteSpace($cleanLine)) {
                return
            }
            if ($cleanLine -match 'one-time code|verification code|open this url|continue in your web browser|github\.com/login/device|microsoft\.com/devicelogin|aka\.ms/devicelogin') {
                $deviceLines.Add($cleanLine)
                if ($deviceLines.Count -gt 6) {
                    $deviceLines.RemoveAt(0)
                }
                Publish-SetupWebDeviceCode -Message ($deviceLines -join [Environment]::NewLine)
            }
        }

        $exitCode = [int]$LASTEXITCODE
        return $exitCode
    }
    finally {
        Publish-SetupWebDeviceCode -Message ''
        if ($ShowDeviceMessages) {
            Publish-SetupWebBusy -Message 'Completing GitHub sign-in...'
        }
    }
}

function Get-GitHubCliScopeState {
    <#
    .SYNOPSIS
        Reads the OAuth scopes reported for the active GitHub CLI login.
    .DESCRIPTION
        Returns Known = false when the CLI does not report scopes, as with fine-grained
        personal access tokens and GitHub App installation tokens. Callers must not treat
        an unknown scope list as missing permission.
    .OUTPUTS
        PSCustomObject with Known and Scopes properties.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $statusOutput = @(& gh auth status --hostname github.com 2>&1)
    if ($LASTEXITCODE -ne 0) {
        return [pscustomobject]@{ Known = $false; Scopes = @() }
    }

    $scopeValue = ''
    $firstReportedScopeValue = ''
    $inActiveAccount = $false
    foreach ($line in $statusOutput) {
        $cleanLine = [regex]::Replace([string]$line, '\x1b\[[0-9;?]*[ -/]*[@-~]', '')
        $activeMatch = [regex]::Match($cleanLine, 'Active account:\s*(true|false)')
        if ($activeMatch.Success) {
            $inActiveAccount = $activeMatch.Groups[1].Value -eq 'true'
            continue
        }
        $scopeMatch = [regex]::Match($cleanLine, 'Token scopes:\s*(.+)$')
        if (-not $scopeMatch.Success) {
            continue
        }
        if ([string]::IsNullOrWhiteSpace($firstReportedScopeValue)) {
            $firstReportedScopeValue = $scopeMatch.Groups[1].Value.Trim()
        }
        if ($inActiveAccount) {
            $scopeValue = $scopeMatch.Groups[1].Value.Trim()
        }
    }
    if ([string]::IsNullOrWhiteSpace($scopeValue)) {
        $scopeValue = $firstReportedScopeValue
    }

    if ([string]::IsNullOrWhiteSpace($scopeValue) -or $scopeValue -ieq 'none') {
        return [pscustomobject]@{ Known = $false; Scopes = @() }
    }

    $scopes = @(
        $scopeValue.Split(',') |
            ForEach-Object { $_.Trim().Trim("'").Trim('"') } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    return [pscustomobject]@{ Known = $true; Scopes = $scopes }
}

function Initialize-GitHubCliWorkflowScope {
    <#
    .SYNOPSIS
        Ensures the GitHub CLI login can create or update workflow files.
    .DESCRIPTION
        Setup writes .github/workflows files, which GitHub rejects for OAuth logins
        without the workflow scope. New logins request it directly. For an existing
        OAuth login, this adds the scope through gh auth refresh and verifies the result.
        Fine-grained, App and externally supplied GH_TOKEN credentials do not report
        refreshable scopes, so they are left unchanged and the push error remains the
        fallback. Headless and ApplyConfig runs never start an interactive refresh.
    .PARAMETER ApplyConfig
        Skips the interactive scope check when setup is applying committed configuration.
    .PARAMETER Headless
        Skips the interactive scope check when setup cannot prompt.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][switch]$ApplyConfig,
        [Parameter()][switch]$Headless
    )

    if ($ApplyConfig -or $Headless) {
        return
    }

    # An externally supplied token cannot be refreshed by gh; leave it to the push
    # error, which names the workflow permission.
    if (-not [string]::IsNullOrWhiteSpace($env:GH_TOKEN) -or -not [string]::IsNullOrWhiteSpace($env:GH_ENTERPRISE_TOKEN)) {
        return
    }

    $scopeState = Get-GitHubCliScopeState
    if (-not $scopeState.Known -or $scopeState.Scopes -contains 'workflow') {
        return
    }

    Write-Host "The GitHub CLI login is missing the 'workflow' scope required to create or update workflow files." -ForegroundColor Yellow
    Write-Host 'Opening GitHub to add the workflow scope...' -ForegroundColor Yellow
    $refreshExitCode = Invoke-GitHubCliAuthenticationCommand `
        -Arguments @('auth', 'refresh', '--hostname', 'github.com', '--scopes', 'workflow') `
        -Status 'Adding the workflow scope to the GitHub CLI login...' `
        -ShowDeviceMessages
    if ($refreshExitCode -ne 0) {
        throw "GitHub did not grant the workflow scope. Run 'gh auth refresh -h github.com -s workflow', or sign in with a token that has the workflow scope, then rerun setup."
    }

    $scopeState = Get-GitHubCliScopeState
    if ($scopeState.Known -and $scopeState.Scopes -notcontains 'workflow') {
        throw "GitHub still reports no workflow scope. Run 'gh auth refresh -h github.com -s workflow', or sign in with a token that has the workflow scope, then rerun setup."
    }
}

function Initialize-GitHubSetupAuthentication {
    <#
    .SYNOPSIS
        Authenticates GitHub (and, outside ApplyConfig, Azure) for guided setup.
    .DESCRIPTION
        Headless mode skips the account menu and requires the GitHub CLI to already be
        authenticated, for example through a GH_TOKEN environment variable. Interactive
        setup requests the workflow scope for new logins and adds it to an existing OAuth
        login, because setup creates and updates .github/workflows files.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][string]$TenantId,
        [Parameter()][switch]$ApplyConfig,
        [Parameter()][switch]$Headless
    )

    Write-Section -Message 'Authenticating with GitHub'

    $ghStatusProbe = Invoke-WithSpectreStatus -Status 'Checking GitHub CLI authentication status...' -ScriptBlock {
        $output = @(& gh auth status --hostname github.com 2>&1)
        return [pscustomobject]@{
            Output   = $output
            ExitCode = $LASTEXITCODE
        }
    }
    $hasExistingGitHubLogin = ($ghStatusProbe.ExitCode -eq 0)

    if ($Headless) {
        if (-not $hasExistingGitHubLogin) {
            throw 'Headless apply requires the GitHub CLI to be authenticated, for example through a GH_TOKEN environment variable.'
        }
        Write-Host 'Using the authenticated GitHub CLI login.' -ForegroundColor Green
    }
    elseif ($hasExistingGitHubLogin) {
        $existingGhUser = (& gh api user --jq '.login' 2>&1 | Out-String).Trim()

        $ghMenuItems = @()
        if (-not [string]::IsNullOrWhiteSpace($existingGhUser)) {
            $ghMenuItems += "Use existing GitHub login: $existingGhUser"
        }
        else {
            $ghMenuItems += "Use existing GitHub login"
        }
        $ghMenuItems += "Sign in with a different GitHub account"

        $ghChoice = Select-FromMenu `
            -Title 'GitHub authentication' `
            -Items $ghMenuItems `
            -PromptGuidanceLines @(
                'Choose whether to continue with the currently authenticated GitHub account or switch to another one.',
                'Use the account that should own or manage workflow and repository settings for this setup.'
            ) `
            -PromptGuidanceDocRelativePath 'docs/setup/github-setup.md' `
            -PromptGuidanceRef $ALM4DataverseRef
        if ($null -eq $ghChoice) {
            throw 'No GitHub authentication option selected.'
        }

        if ($ghChoice -eq 0) {
            Write-Host 'Using existing GitHub login.' -ForegroundColor Green
        }
        else {
            Write-Host 'Signing in with a different GitHub account...' -ForegroundColor Yellow
            $null = Invoke-GitHubCliAuthenticationCommand `
                -Arguments @('auth', 'logout', '--hostname', 'github.com') `
                -Status 'Signing out of the current GitHub CLI session...'
            $loginExitCode = Invoke-GitHubCliAuthenticationCommand `
                -Arguments @('auth', 'login', '--web', '--hostname', 'github.com', '--scopes', 'workflow') `
                -Status 'Waiting for GitHub sign-in in your browser...' `
                -ShowDeviceMessages
            if ($loginExitCode -ne 0) {
                throw 'GitHub authentication failed.'
            }
        }
    }
    else {
        Write-Host 'Not logged in to GitHub. Opening browser for authentication...' -ForegroundColor Yellow
        $loginExitCode = Invoke-GitHubCliAuthenticationCommand `
            -Arguments @('auth', 'login', '--web', '--hostname', 'github.com', '--scopes', 'workflow') `
            -Status 'Waiting for GitHub sign-in in your browser...' `
            -ShowDeviceMessages
        if ($loginExitCode -ne 0) {
            throw 'GitHub authentication failed.'
        }
    }

    Initialize-GitHubCliWorkflowScope -ApplyConfig:$ApplyConfig -Headless:$Headless

    $script:ghUser = (& gh api user --jq '.login' 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        if (-not $ApplyConfig) {
            throw 'Failed to determine GitHub username.'
        }
        # An installation token supplied through GH_TOKEN can read and write the
        # repository but cannot call /user. ApplyConfig does not need the profile;
        # provider resources that use a reviewer id are skipped in this mode.
        $script:ghUser = ''
        Write-Host 'The GitHub token cannot read the user profile; continuing with repository permissions only.' -ForegroundColor DarkGray
    }

    $script:ghUserId = $null
    $ghUserIdRaw = (& gh api user --jq '.id' 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -eq 0 -and $ghUserIdRaw -match '^\d+$') {
        $script:ghUserId = [int]$ghUserIdRaw
    }

    if (-not [string]::IsNullOrWhiteSpace($script:ghUser)) {
        Write-Host "Logged in as: $script:ghUser" -ForegroundColor Green
        if ($script:ghUserId) {
            Write-Host "GitHub user id: $script:ghUserId" -ForegroundColor DarkGray
        }
    }

    $script:azureAuthResult = $null
    if (-not $ApplyConfig) {
        Write-Section -Message 'Authenticating with Azure'

        Write-Host 'To enable automated setup, we need to authenticate with Azure.' -ForegroundColor Green
        Write-Host ''
        Write-Host 'When prompted, please log in with an account that has access to:' -ForegroundColor Green
        Write-Host '- Your Entra ID tenant (to manage App Registrations)' -ForegroundColor Green
        Write-Host '- Your Dataverse DEV environment (SYSTEM ADMINISTRATOR role)' -ForegroundColor Green
        Write-Host ''

        $cachedAzureAccounts = @(Get-AuthToken -ResourceUrl 'https://graph.microsoft.com' -TenantId $TenantId -ListAccountsOnly)
        $preferredAzureUsername = $null
        $forceAzureInteractive = $false

        if ($cachedAzureAccounts.Count -gt 0) {
            $azureAuthMenuItems = @($cachedAzureAccounts | ForEach-Object { "Use existing Azure login: $_" })
            $azureAuthMenuItems += 'Sign in with a different Azure account'

            $azureAuthChoice = Select-FromMenu `
                -Title 'Azure authentication' `
                -Items $azureAuthMenuItems `
                -PromptGuidanceLines @(
                    'Choose whether to reuse an existing Azure login context or sign in with a different identity.',
                    'Select an identity that can manage app registrations and Dataverse users in the target tenant.'
                ) `
                -PromptGuidanceDocRelativePath 'docs/setup/github-setup.md' `
                -PromptGuidanceRef $ALM4DataverseRef
            if ($null -eq $azureAuthChoice) {
                throw 'No Azure authentication option selected.'
            }

            if ($azureAuthChoice -lt $cachedAzureAccounts.Count) {
                $preferredAzureUsername = $cachedAzureAccounts[$azureAuthChoice]
            }
            else {
                $forceAzureInteractive = $true
                Wait-ForUserAcknowledgement -Message 'Open the browser for Azure authentication when you are ready.' -ContinueLabel 'Open browser'
            }
        }
        else {
            Wait-ForUserAcknowledgement -Message 'Open the browser for Azure authentication when you are ready.' -ContinueLabel 'Open browser'
        }

        $script:azureAuthResult = Invoke-WithErrorHandling -OperationName 'Azure Authentication' -ScriptBlock {
            $result = Get-AuthToken -ResourceUrl 'https://graph.microsoft.com' -TenantId $TenantId -PreferredUsername $preferredAzureUsername -ForceInteractive:$forceAzureInteractive
            if (-not $result -or -not $result.AccessToken) {
                throw 'Failed to acquire an Azure access token.'
            }
            return $result
        }

        Write-Host "Authenticated as: $($script:azureAuthResult.Account.Username)" -ForegroundColor Green

        if ([string]::IsNullOrWhiteSpace($TenantId)) {
            $TenantId = $script:azureAuthResult.TenantId
            Write-Host "Using tenant: $TenantId"
        }

        Assert-ValidTenantIdentifier -TenantIdentifier $TenantId -Source 'Resolved Azure tenant ID'
    }
    else {
        $TenantId = $null
    }

    return [pscustomobject]@{
        TenantId = $TenantId
        AzureAuthResult = $script:azureAuthResult
        GitHubUser = $script:ghUser
        GitHubUserId = $script:ghUserId
    }
}