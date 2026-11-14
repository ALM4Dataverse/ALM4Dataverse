function Initialize-EntraIdServicePrincipal {
    <#
    .SYNOPSIS
        Returns the tenant's first service principal for ApplicationId, creating it if absent.
    .DESCRIPTION
        Acquires a Graph token for TenantId and uses the application's client ID,
        not its application-object ID. Graph failures propagate; this remote mutation
        has no ShouldProcess guard.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ApplicationId,
        [Parameter(Mandatory)][string]$TenantId
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

    Write-Host "Creating Service Principal for App '$ApplicationId'..." -ForegroundColor Yellow
    $body = @{ appId = $ApplicationId }
    $sp = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/servicePrincipals" -Headers $headers -Method Post -Body ($body | ConvertTo-Json)
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
            Write-Error "Failed to update federated identity credential: $($_.Exception.Message)"
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
        Write-Error "Failed to create federated identity credential: $($_.Exception.Message)"
        throw
    }
}

function New-EntraIdApplication {
    <#
    .SYNOPSIS
        Reuses or creates a tenant app registration and ensures its service principal.
    .DESCRIPTION
        Reuses the first exact display-name query result. Returns Name, ApplicationId,
        ApplicationObjectId, TenantId, AuthType and ClientSecret. AuthType Secret
        creates a fresh secret even for a reused application; other values leave
        ClientSecret null. ShouldProcess guards the entire operation.
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
    if ($existing.value.Count -gt 0) {
        $app = $existing.value[0]
        Write-Host "Found existing App Registration '$DisplayName' ($($app.appId))."
    }
    else {
        Write-Host "Creating App Registration '$DisplayName'..." -ForegroundColor Yellow
        $body = @{
            displayName    = $DisplayName
            signInAudience = "AzureADMyOrg"
        }
        $app = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/applications" -Headers $headers -Method Post -Body ($body | ConvertTo-Json)
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
        New/manual paths return app client/object IDs, tenant, auth type and optional
        secret; they can create Graph resources before final wizard review.
        Cancelled required menus throw rather than returning partial credentials.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][array]$ExistingCredentials,
        [Parameter()][string]$TenantId,
        [Parameter()][string]$RepoName,
        [Parameter()][string]$EnvironmentName,
        [Parameter()][object]$ExistingCredential
    )

    $menuItems  = @()
    $menuActions = @()

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

    $menuItems  += "Create new App Registration (Entra ID)"
    $menuActions += @{ Type = 'CreateNew' }

    $menuItems  += "Enter existing App Registration details"
    $menuActions += @{ Type = 'Manual' }

    foreach ($c in $ExistingCredentials) {
        $menuItems  += "Reuse: $($c.Name) ($($c.ApplicationId))"
        $menuActions += @{ Type = 'Cached'; Creds = $c }
    }

    $selection = Select-FromMenu -Title "Select App Registration credentials for '$EnvironmentName'" -Items $menuItems -PromptGuidanceLines @(
        'App Registration credentials authenticate the workflow to Dataverse.',
        'Use a separate App Registration per environment and prefer Workload Identity Federation to avoid client-secret rotation.',
        'Select existing credentials or create a new App Registration for this environment.'
    ) -PromptGuidanceDocRelativePath 'docs/config/github-secrets.md' -PromptGuidanceRef $ALM4DataverseRef
    if ($null -eq $selection) { throw "No credential selected." }

    $action = $menuActions[$selection]

    if ($action.Type -eq 'Existing') {
        $selectedCredential = $action.Creds.PSObject.Copy()

        if ($selectedCredential.AuthType -eq 'Secret' -and $selectedCredential.HasExistingSecret) {
            $secretHandlingItems = @(
                'Keep the existing client secret',
                'Generate a new client secret now'
            )

            $secretHandlingSelection = Select-FromMenu -Title "How should setup handle the existing client secret for '$EnvironmentName'?" -Items $secretHandlingItems -PromptGuidanceLines @(
                'Choose whether to keep the existing secret or rotate it now.',
                'Rotate when policy requires periodic renewal or the current secret is no longer trusted.'
            ) -PromptGuidanceDocRelativePath 'docs/config/github-secrets.md' -PromptGuidanceRef $ALM4DataverseRef
            if ($null -eq $secretHandlingSelection) {
                throw 'No client secret handling option selected.'
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

                Write-Host 'Generating a new client secret...' -ForegroundColor Yellow
                $selectedCredential.ClientSecret = New-EntraIdApplicationSecret -ApplicationObjectId $selectedCredential.ApplicationObjectId -TenantId $selectedCredential.TenantId
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
    else { # Manual
        Write-Host "Enter App Registration details:" -ForegroundColor Cyan
        $name = Read-TextWithDefault -Prompt 'Friendly name (for reuse reference)' -AllowEmpty
        if ([string]::IsNullOrWhiteSpace($name)) { $name = "Credential-" + (Get-Date -Format "HHmm") }

        while ($true) {
            $appId = Read-TextWithDefault -Prompt 'Application ID (Client ID)'
            if ($appId -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
                break
            }
            else {
                Write-Warning "The Application ID must be a valid GUID. Please try again."
            }
        }

        while ($true) {
            $appObjectId = Read-TextWithDefault -Prompt 'Application object ID (from App registrations > Overview, not the enterprise app object ID)'
            if ($appObjectId -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
                break
            }
            else {
                Write-Warning "The Application Object ID must be a valid GUID. Please try again."
            }
        }

        # Prompt for authentication type
        Write-Host ""
        $authTypeItems = @(
            "Workload Identity Federation (recommended, no secrets)",
            "Service Principal with Secret (traditional)"
        )
        $authTypeSelection = Select-FromMenu -Title "Select authentication type" -Items $authTypeItems -PromptGuidanceLines @(
            'Choose the authentication mode for the provided App Registration details.',
            'Use secret-based auth only when workload identity federation is not suitable for your scenario.'
        ) -PromptGuidanceDocRelativePath 'docs/config/github-secrets.md' -PromptGuidanceRef $ALM4DataverseRef
        if ($null -eq $authTypeSelection) { throw "No authentication type selected." }

        $authType = if ($authTypeSelection -eq 0) { 'WIF' } else { 'Secret' }

        $secret = $null
        if ($authType -eq 'Secret') {
            while ($true) {
                $secret = Read-SecretText -Prompt 'Client Secret'

                if ($secret -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
                    Write-Warning "The Client Secret looks like a GUID. You should enter the Secret VALUE, not the Secret ID."
                    if (Read-YesNo -Prompt "Are you sure this is the Secret Value?" -DefaultNo) {
                        break
                    }
                } else {
                    break
                }
            }
        }

        [void](Initialize-EntraIdServicePrincipal -ApplicationId $appId -TenantId $TenantId)

        return [pscustomobject]@{
            Name                = $name
            ApplicationId       = $appId
            ApplicationObjectId = $appObjectId
            ClientSecret        = $secret
            TenantId            = $TenantId
            AuthType            = $authType
        }
    }
}

function Initialize-GitHubSetupAuthentication {
    [CmdletBinding()]
    param(
        [Parameter()][string]$TenantId,
        [Parameter()][switch]$ApplyConfig
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

    if ($hasExistingGitHubLogin) {
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
            & gh auth logout --hostname github.com 2>&1 | Out-Host
            & gh auth login --web --hostname github.com
            if ($LASTEXITCODE -ne 0) {
                throw 'GitHub authentication failed.'
            }
        }
    }
    else {
        Write-Host 'Not logged in to GitHub. Opening browser for authentication...' -ForegroundColor Yellow
        & gh auth login --web --hostname github.com
        if ($LASTEXITCODE -ne 0) {
            throw 'GitHub authentication failed.'
        }
    }

    $script:ghUser = (& gh api user --jq '.login' 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to determine GitHub username.'
    }

    $script:ghUserId = $null
    $ghUserIdRaw = (& gh api user --jq '.id' 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -eq 0 -and $ghUserIdRaw -match '^\d+$') {
        $script:ghUserId = [int]$ghUserIdRaw
    }

    Write-Host "Logged in as: $script:ghUser" -ForegroundColor Green
    if ($script:ghUserId) {
        Write-Host "GitHub user id: $script:ghUserId" -ForegroundColor DarkGray
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