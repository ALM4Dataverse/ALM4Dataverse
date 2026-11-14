function Initialize-EntraIdServicePrincipal {
    # Return the first appId match in the tenant or create its enterprise application.
    # Lookup failure warns but still attempts creation; creation failure propagates.
    param(
        [Parameter(Mandatory)][string]$ApplicationId,
        [Parameter(Mandatory)][string]$TenantId
    )

    $graphToken = Get-AuthToken -ResourceUrl "https://graph.microsoft.com" -TenantId $TenantId
    $headers = @{
        Authorization = "Bearer $($graphToken.AccessToken)"
        "Content-Type" = "application/json"
    }

    # Check if SP exists
    $uri = "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$ApplicationId'"
    try {
        $existing = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
        if ($existing.value.Count -gt 0) {
            Write-Host "Service Principal for App '$ApplicationId' already exists."
            return $existing.value[0]
        }
    }
    catch {
        Write-Warning "Failed to check for existing Service Principal: $($_.Exception.Message)"
    }

    # Create SP
    Write-Host "Creating Service Principal for App '$ApplicationId'..." -ForegroundColor Yellow
    $body = @{
        appId = $ApplicationId
    }

    try {
        $sp = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/servicePrincipals" -Headers $headers -Method Post -Body ($body | ConvertTo-Json)
        Write-Host "Created Service Principal ($($sp.id))."
        start-sleep -Seconds 10 # Wait a bit for SP to be fully available
        return $sp
    }
    catch {
        Write-Error "Failed to create Service Principal: $($_.Exception.Message)"
        throw
    }
}

function Add-EntraIdFederatedCredential {
    <#
    .SYNOPSIS
        Adds a federated identity credential to an Entra ID application for Workload Identity Federation.

    .DESCRIPTION
        Creates a federated identity credential that allows Azure DevOps to authenticate to Azure
        using Workload Identity Federation (WIF) without requiring client secrets.
        Reuses the first issuer/subject match, regardless of credential name.
        A failed lookup warns and proceeds to creation; a failed creation throws.
    .PARAMETER ApplicationObjectId
        Directory object ID of the application, not its client/application ID.
    #>
    param(
        [Parameter(Mandatory)][string]$ApplicationObjectId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$Issuer,
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$CredentialName
    )

    $graphToken = Get-AuthToken -ResourceUrl "https://graph.microsoft.com" -TenantId $TenantId
    $headers = @{
        Authorization = "Bearer $($graphToken.AccessToken)"
        "Content-Type" = "application/json"
    }

    $issuer = $Issuer
    $subject = $Subject
    $credentialName = $CredentialName

    Write-Host "Adding federated identity credential '$credentialName'..." -ForegroundColor Yellow

    # Check if credential already exists
    $listUri = "https://graph.microsoft.com/beta/applications/$ApplicationObjectId/federatedIdentityCredentials"
    try {
        $existing = Invoke-RestMethod -Uri $listUri -Headers $headers -Method Get
        $existingCred = $existing.value | Where-Object {
            $_.issuer -eq $issuer -and $_.subject -eq $subject
        } | Select-Object -First 1

        if ($existingCred) {
            Write-Host "Federated identity credential already exists for this issuer and subject."
            return $existingCred
        }
    }
    catch {
        Write-Warning "Failed to check for existing federated credentials: $($_.Exception.Message)"
    }

    # Create the federated credential
    $body = @{
        name = $credentialName
        issuer = $issuer
        subject = $subject
        audiences = @("api://AzureADTokenExchange")
        description = "Workload Identity Federation for Azure DevOps service connection"
    }

    try {
        $credential = Invoke-RestMethod -Uri $listUri -Headers $headers -Method Post -Body ($body | ConvertTo-Json)
        Write-Host "Created federated identity credential successfully."
        return $credential
    }
    catch {
        Write-Error "Failed to create federated identity credential: $($_.Exception.Message)"
        throw
    }
}

function New-EntraIdApplication {
    <#
    .SYNOPSIS
    Reuses the first display-name match or creates an application, and ensures its service principal.
    .OUTPUTS
    System.Management.Automation.PSCustomObject. Credential metadata including client ID,
    application object ID, tenant, auth type and optional plaintext ClientSecret.
    .NOTES
    WIF leaves ClientSecret null; other auth types create a new secret even for an
    existing application. WhatIf returns nothing. Graph/secret failures propagate.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter()][string]$AuthType = 'Secret'
    )

    if (-not $PSCmdlet.ShouldProcess($DisplayName, 'Create or configure Entra application')) { return }

    # Get token for Graph
    $graphToken = Get-AuthToken -ResourceUrl "https://graph.microsoft.com" -TenantId $TenantId
    $headers = @{
        Authorization = "Bearer $($graphToken.AccessToken)"
        "Content-Type" = "application/json"
    }

    # Check if app exists
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
            displayName = $DisplayName
            signInAudience = "AzureADMyOrg"
        }
        $app = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/applications" -Headers $headers -Method Post -Body ($body | ConvertTo-Json)
        Write-Host "Created App Registration '$DisplayName' ($($app.appId))."
    }

    [void](Initialize-EntraIdServicePrincipal -ApplicationId $app.appId -TenantId $TenantId)

    $result = [pscustomobject]@{
        Name = $DisplayName
        ApplicationId = $app.appId
        ApplicationObjectId = $app.id
        ClientSecret = $null
        TenantId = $TenantId
        AuthType = $AuthType
        IsExistingServiceConnection = $false
    }

    if ($AuthType -ne 'WIF') {
        # Create secret for traditional authentication
        Write-Host "Creating client secret..." -ForegroundColor Yellow
        $result.ClientSecret = New-EntraIdApplicationSecret -ApplicationObjectId $app.id -TenantId $TenantId
    }

    return $result
}

function Get-PowerPlatformSCCredential {
    <#
    .SYNOPSIS
    Interactively selects, creates or reuses deployment credentials for an environment.
    .NOTES
    Returns credential metadata, not necessarily a secret: existing endpoints can be
    represented by IsExistingServiceConnection with a null ClientSecret. Explicit
    rotation generates a secret and clears that marker. Cached objects are reused;
    an existing environment credential is copied before rotation. Disabling extension
    mode limits new/manual choices to secret auth. Cancellation throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][array]$ExistingCredentials,
        [Parameter()][string]$TenantId,
        [Parameter()][string]$ProjectName,
        [Parameter()][string]$EnvironmentName,
        [Parameter()][bool]$UseAlm4DataverseExtension = $true,
        [Parameter()][object]$ExistingCredential
    )

    # 1. Try to find existing Service Connection to see if we can reuse its App ID
    $existingEndpoint = $null
    $existingScAppId = $null
    try {
        $endpoints = @(Get-VSTeamServiceEndpoint -ProjectName $ProjectName -ErrorAction Stop)
        $existingEndpoint = $endpoints | Where-Object { $_.name -eq $EnvironmentName } | Select-Object -First 1
        if ($existingEndpoint -and $existingEndpoint.authorization -and $existingEndpoint.authorization.parameters) {
            if ($existingEndpoint.authorization.parameters.PSObject.Properties.Name -contains 'applicationId') {
                $existingScAppId = $existingEndpoint.authorization.parameters.applicationId
            }
            elseif ($existingEndpoint.authorization.parameters.PSObject.Properties.Name -contains 'serviceprincipalid') {
                $existingScAppId = $existingEndpoint.authorization.parameters.serviceprincipalid
            }
        }
    }
    catch {
        if (-not (Test-SetupResourceNotFound -ErrorRecord $_)) { throw }
        Write-Verbose 'No service connection was found; continuing credential selection.'
    }

    if (-not $ExistingCredential -and $existingEndpoint -and -not [string]::IsNullOrWhiteSpace($existingScAppId)) {
        $existingAuthType = if ($existingEndpoint.authorization -and $existingEndpoint.authorization.scheme -eq 'WorkloadIdentityFederation') { 'WIF' } else { 'Secret' }
        $existingTenantId = $TenantId
        if ($existingEndpoint.authorization -and $existingEndpoint.authorization.parameters) {
            if ($existingEndpoint.authorization.parameters.PSObject.Properties.Name -contains 'tenantId' -and -not [string]::IsNullOrWhiteSpace($existingEndpoint.authorization.parameters.tenantId)) {
                $existingTenantId = $existingEndpoint.authorization.parameters.tenantId
            }
            elseif ($existingEndpoint.authorization.parameters.PSObject.Properties.Name -contains 'tenantid' -and -not [string]::IsNullOrWhiteSpace($existingEndpoint.authorization.parameters.tenantid)) {
                $existingTenantId = $existingEndpoint.authorization.parameters.tenantid
            }
        }

        $existingApplication = Resolve-EntraIdApplicationByAppId -ApplicationId $existingScAppId -TenantId $existingTenantId
        $ExistingCredential = [pscustomobject]@{
            Name                        = $(if ($existingApplication -and -not [string]::IsNullOrWhiteSpace($existingApplication.displayName)) { $existingApplication.displayName } else { "Existing-$EnvironmentName" })
            ApplicationId               = $existingScAppId
            ApplicationObjectId         = $(if ($existingApplication) { $existingApplication.id } else { $null })
            ClientSecret                = $null
            TenantId                    = $existingTenantId
            AuthType                    = $existingAuthType
            IsExistingServiceConnection = $true
            HasExistingSecret           = ($existingAuthType -eq 'Secret')
        }
    }

    # 2. Search Entra ID for relevant applications
    $foundApps = @()
    try {
        $graphToken = Get-AuthToken -ResourceUrl "https://graph.microsoft.com" -TenantId $TenantId
        $headers = @{ Authorization = "Bearer $($graphToken.AccessToken)" }

        # If we have an existing SC App ID, ensure it's in the list
        if ($existingScAppId) {
            $alreadyFound = $foundApps | Where-Object { $_.appId -eq $existingScAppId }
            if (-not $alreadyFound) {
                $filter = "appId eq '$existingScAppId'"
                $uri = "https://graph.microsoft.com/v1.0/applications?`$filter=$filter&`$select=appId,displayName,id"
                $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
                if ($response.value) {
                    $foundApps += $response.value
                }
            }
        }
    }
    catch {
        Write-Warning "Failed to list applications from Entra ID: $($_.Exception.Message)"
    }

    $menuItems = @()
    $menuActions = @() # To track what each item does

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

    # Recommend the application already bound to the existing service connection.
    $recommendedApp = $null

    if ($existingScAppId) {
        $recommendedApp = $foundApps | Where-Object { $_.appId -eq $existingScAppId } | Select-Object -First 1
    }

    if ($UseAlm4DataverseExtension -and $recommendedApp) {
        $menuItems += "Use existing: $($recommendedApp.displayName) ($($recommendedApp.appId))"
        $menuActions += @{ Type = 'ExistingSCApp'; App = $recommendedApp }

        # Remove from foundApps to avoid duplicate listing
        $foundApps = $foundApps | Where-Object { $_.appId -ne $recommendedApp.appId }
    }

    # Standard Options
    $menuItems += "Create new App Registration (Entra ID)"
    $menuActions += @{ Type = 'CreateNew' }

    $menuItems += "Enter existing Service Principal details"
    $menuActions += @{ Type = 'Manual' }

    # Cached Credentials
    foreach ($c in $ExistingCredentials) {
        $menuItems += "Reuse: $($c.Name) ($($c.ApplicationId))"
        $menuActions += @{ Type = 'Cached'; Creds = $c }
    }


    $selection = Select-FromMenu -Title "Select Service Principal credentials for '$EnvironmentName'" -Items $menuItems -PromptGuidanceLines @(
        'Service Principal credentials authenticate the pipeline to Dataverse.',
        'Use a separate App Registration per environment and prefer Workload Identity Federation when extension mode is enabled.',
        'Select existing credentials or create new Service Principal credentials for this environment.',
        'Prefer workload identity federation when available to reduce client secret management.'
    ) -PromptGuidanceDocRelativePath 'docs/config/azdo-environment-service-connection.md' -PromptGuidanceRef $ALM4DataverseRef
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
                'Choose whether to keep the existing secret or generate a new one now.',
                'Rotate when policy requires renewal or when the existing secret is no longer trusted.'
            ) -PromptGuidanceDocRelativePath 'docs/config/azdo-environment-service-connection.md' -PromptGuidanceRef $ALM4DataverseRef
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
                $selectedCredential.IsExistingServiceConnection = $false
            }

            return $selectedCredential
        }

        return $selectedCredential
    }
    elseif ($action.Type -eq 'Cached') {
        return $action.Creds
    }
    elseif ($action.Type -eq 'CreateNew') {
        $authType = 'Secret'
        if ($UseAlm4DataverseExtension) {
            # Prompt for authentication type
            Write-Host ""
            $authTypeItems = @(
                "Workload Identity Federation (recommended, no secrets)",
                "Service Principal with Secret (traditional)"
            )
            $authTypeSelection = Select-FromMenu -Title "Select authentication type for the new service connection" -Items $authTypeItems -PromptGuidanceLines @(
                'Choose between workload identity federation and client-secret authentication.',
                'Workload identity federation is recommended when supported.'
            ) -PromptGuidanceDocRelativePath 'docs/config/azdo-environment-service-connection.md' -PromptGuidanceRef $ALM4DataverseRef
            if ($null -eq $authTypeSelection) { throw "No authentication type selected." }

            $authType = if ($authTypeSelection -eq 1) { 'Secret' } else { 'WIF' }
        }
        else {
            Write-Host "Using Service Principal with Secret authentication because ALM4Dataverse extension mode is disabled." -ForegroundColor Yellow
        }

        $appName = "$ProjectName - $EnvironmentName - deployment"

        if ($authType -eq 'WIF') {
            return New-EntraIdApplication `
                -DisplayName $appName `
                -TenantId $TenantId `
                -AuthType 'WIF'
        }
        else {
            return New-EntraIdApplication `
                -DisplayName $appName `
                -TenantId $TenantId `
                -AuthType 'Secret'
        }
    }
    elseif ($action.Type -eq 'ExistingSCApp') {
        if (-not $UseAlm4DataverseExtension) {
            throw "Reusing existing service connection credentials requires ALM4Dataverse extension mode. Enable extension mode or enter Service Principal details manually."
        }
        $app = $action.App
        Write-Host "Using existing service connection with App: $($app.displayName) ($($app.appId))" -ForegroundColor Cyan

        # Since the service connection already exists, we just return a marker object
        # The credentials are already configured in the existing service connection
        return [pscustomobject]@{
            Name = $app.displayName
            ApplicationId = $app.appId
            ApplicationObjectId = $app.id
            ClientSecret = $null
            TenantId = $TenantId
            AuthType = 'Unknown' # Existing SC, auth type already configured
            IsExistingServiceConnection = $true
        }
    }
    else { # Manual
        Write-Host "Enter Service Principal details:" -ForegroundColor Cyan
        $name = Read-TextWithDefault -Prompt 'Credential name (for reuse reference)' -AllowEmpty
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

        $authType = 'Secret'
        if ($UseAlm4DataverseExtension) {
            # Prompt for authentication type
            Write-Host ""
            $authTypeItems = @(
                "Service Principal with Secret (traditional)",
                "Workload Identity Federation (recommended, no secrets)"
            )
            $authTypeSelection = Select-FromMenu -Title "Select authentication type" -Items $authTypeItems -PromptGuidanceLines @(
                'Choose the authentication mode for the supplied Service Principal details.',
                'Use secret-based auth only when workload identity federation is not the intended option.'
            ) -PromptGuidanceDocRelativePath 'docs/config/azdo-environment-service-connection.md' -PromptGuidanceRef $ALM4DataverseRef
            if ($null -eq $authTypeSelection) { throw "No authentication type selected." }

            $authType = if ($authTypeSelection -eq 0) { 'Secret' } else { 'WIF' }
        }
        else {
            Write-Host "Using Service Principal with Secret authentication because ALM4Dataverse extension mode is disabled." -ForegroundColor Yellow
        }

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
            Name = $name
            ApplicationId = $appId
            ApplicationObjectId = $null
            ClientSecret = $secret
            TenantId = $TenantId
            AuthType = $authType
            IsExistingServiceConnection = $false
        }
    }
}

function Get-DataverseServiceAccountUPN {
    # Returns an existing/cached or manually entered ownership UPN; cancellation throws.
    # The manual check is format-only, not a directory, role or licensing verification.
    [CmdletBinding()]
    param(
        [Parameter()][array]$ExistingServiceAccounts,
        [Parameter()][string]$EnvironmentName,
        [Parameter()][string]$ExistingValue
    )

    $menuItems = @()
    $menuActions = @() # To track what each item does

    # Priority 1: Existing value from variable group (if provided)
    if (-not [string]::IsNullOrWhiteSpace($ExistingValue)) {
        $menuItems += "Use existing: $ExistingValue"
        $menuActions += @{ Type = 'Existing'; UPN = $ExistingValue }
    }

    # Standard Options
    $menuItems += "Enter a new service account UPN"
    $menuActions += @{ Type = 'Manual' }

    # Cached Service Accounts (exclude the existing value to avoid duplication)
    foreach ($sa in $ExistingServiceAccounts) {
        if ($sa -ne $ExistingValue) {
            $menuItems += "Reuse: $sa"
            $menuActions += @{ Type = 'Cached'; UPN = $sa }
        }
    }

    $selection = Select-FromMenu `
        -Title "Select Dataverse Service Account for '$EnvironmentName'" `
        -Items $menuItems `
        -PromptGuidanceLines @(
            'The service account owns flow activation and needs a license plus the System Administrator role.',
            'Keep it separate from a personal admin account so automation ownership stays stable.',
            "Choose the service account UPN that will own flow activation and runtime ownership for '$EnvironmentName'.",
            'Reusing an existing service account keeps ownership consistent across runs; entering a new one changes who owns activated processes.'
        ) `
        -PromptGuidanceDocRelativePath 'docs/config/azdo-environment-service-connection.md' `
        -PromptGuidanceRef $ALM4DataverseRef
    if ($null -eq $selection) { throw "No service account selected." }

    $action = $menuActions[$selection]

    if ($action.Type -eq 'Cached' -or $action.Type -eq 'Existing') {
        return $action.UPN
    }
    else { # Manual
        Write-Host ""
        Write-Host "IMPORTANT: The service account must be licenced with an appropriate D365/PowerApps/etc licence for your use-case." -ForegroundColor Yellow
        Write-Host ""

        while ($true) {
            $upn = Read-TextWithDefault -Prompt 'Service Account UPN (for example: serviceaccount@contoso.com)'
            if ([string]::IsNullOrWhiteSpace($upn)) {
                Write-Warning "Service Account UPN cannot be empty. Please try again."
                continue
            }
            # Basic UPN format validation
            if ($upn -match '^[^@]+@[^@]+\.[^@]+$') {
                return $upn
            }
            else {
                Write-Warning "The UPN does not appear to be in a valid UPN format. Please try again."
            }
        }
    }
}

function Get-AzDoVariableGroupByName {
    <#
    .SYNOPSIS
    Retrieves a variable group by name without applying VSTeam's user type decoration.
    .DESCRIPTION
    VSTeam 7.15.2 dereferences createdBy and modifiedBy while decorating results, but
    Azure DevOps can return either field as null. The raw request keeps the same lookup
    and error behavior without depending on optional user metadata.
    .PARAMETER ProjectName
    Azure DevOps project containing the variable group.
    .PARAMETER GroupName
    Name of the variable group to retrieve.
    .OUTPUTS
    The raw variable group object, or no output when no group matches.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$GroupName
    )

    $response = Invoke-VSTeamRequest `
        -Method GET `
        -ProjectName $ProjectName `
        -Area 'distributedtask' `
        -Resource 'variablegroups' `
        -Version '5.1-preview.1' `
        -QueryString @{ groupName = $GroupName } `
        -ErrorAction Stop

    return $response.value
}

function Initialize-AzDoVariableGroup {
    <#
    .SYNOPSIS
    Returns or creates a variable group and ensures locking plus optional deployment approval.
    .NOTES
    Variables seed new groups only; updates are handled separately. Only not-found
    lookup failures permit creation. Existing approval checks are not removed when
    RequireDeploymentApproval is false.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$GroupName,
        [Parameter(Mandatory)][hashtable]$Variables,
        [Parameter()][bool]$RequireDeploymentApproval = $true
    )

    $group = $null

    # Query the raw REST response because VSTeam's typed getter assumes user metadata is present.
    try {
        $existing = Get-AzDoVariableGroupByName -ProjectName $Project -GroupName $GroupName -ErrorAction Stop
        if ($existing) {
            Write-Host "Variable group '$GroupName' already exists (id: $($existing.id))."
            $group = $existing
        }
    }
    catch {
        if (-not (Test-SetupResourceNotFound -ErrorRecord $_)) { throw }
        Write-Verbose 'No variable group was found; continuing with creation.'
    }

    if (-not $group) {
        Write-Host "Creating variable group '$GroupName'..." -ForegroundColor Yellow

        $variablesPayload = @{}
        foreach ($k in $Variables.Keys) {
            $variablesPayload[$k] = @{ value = [string]$Variables[$k] }
        }

        $description = 'ALM4Dataverse environment variable group (created by setup-azdo.ps1)'
        $createPayload = @{
            name        = $GroupName
            description = $description
            type        = 'Vsts'
            variables   = $variablesPayload
        } | ConvertTo-Json -Depth 100

        # VSTeam's add command follows the POST with a typed GET that assumes user metadata exists.
        $created = Invoke-VSTeamRequest `
            -Method POST `
            -ProjectName $Project `
            -Area 'distributedtask' `
            -Resource 'variablegroups' `
            -Body $createPayload `
            -ContentType 'application/json' `
            -Version '5.1-preview.1' `
            -ErrorAction Stop

        if ($created -and $created.id) {
            $group = Get-AzDoVariableGroupByName -ProjectName $Project -GroupName $GroupName -ErrorAction Stop
            if (-not $group) {
                throw "Variable group '$GroupName' was created but could not be retrieved."
            }

            Write-Host "Created variable group '$GroupName' (id: $($created.id))."
        }
        else {
            throw "Azure DevOps did not return an ID when creating variable group '$GroupName'."
        }
    }

    if ($group -and $group.id) {
        Initialize-AzDoVariableGroupExclusiveLock -Organization $Organization -Project $Project -VariableGroupId $group.id -VariableGroupName $GroupName

        if ($RequireDeploymentApproval) {
            $envName = $GroupName -replace '^Environment-', ''
            $team = Initialize-AzDoDeploymentApproverTeam -ProjectName $Project -EnvironmentName $envName
            Initialize-AzDoVariableGroupApproval -Organization $Organization -Project $Project -VariableGroupId $group.id -VariableGroupName $GroupName -ApproverTeam $team

        }
    }

    return $group
}

function Update-AzDoVariableGroup {
    <#
    .SYNOPSIS
    Merges supplied string values over the existing group's values and submits an update.
    .NOTES
    Returns the pre-update group object on success, null on missing group or failure.
    Copies values only, not secret metadata; this helper is for setup's nonsecret
    environment variables. WhatIf skips lookup and mutation.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$GroupName,
        [Parameter(Mandatory)][hashtable]$Variables
    )

    if (-not $PSCmdlet.ShouldProcess("$ProjectName/$GroupName", 'Update Azure DevOps variable group')) { return }

    try {
        $group = Get-AzDoVariableGroupByName -ProjectName $ProjectName -GroupName $GroupName -ErrorAction SilentlyContinue
        if (-not $group) {
            Write-Warning "Variable group '$GroupName' not found. Cannot update."
            return $null
        }

        Write-Host "Updating variable group '$GroupName'..." -ForegroundColor DarkGray

        $variablesPayload = @{}

        # First, copy existing variables if the group has any
        if ($group.variables) {
            foreach ($key in $group.variables.PSObject.Properties.Name) {
                $variablesPayload[$key] = @{ value = $group.variables.$key.value }
            }
        }

        # Then add/update with new variables
        foreach ($k in $Variables.Keys) {
            $variablesPayload[$k] = @{ value = [string]$Variables[$k] }
        }

        $updatePayload = @{
            name        = $GroupName
            description = $group.description
            type        = 'Vsts'
            variables   = $variablesPayload
        } | ConvertTo-Json -Depth 100

        # VSTeam's update command also re-fetches and decorates the group after its PUT.
        Invoke-VSTeamRequest `
            -Method PUT `
            -ProjectName $ProjectName `
            -Area 'distributedtask' `
            -Resource 'variablegroups' `
            -Id ([string]$group.id) `
            -Body $updatePayload `
            -ContentType 'application/json' `
            -Version '5.1-preview.1' `
            -ErrorAction Stop | Out-Null

        Write-Host "Variable group '$GroupName' updated successfully."
        return $group
    }
    catch {
        Write-Warning "Failed to update variable group '$GroupName': $($_.Exception.Message)"
        return $null
    }
}

function Set-AzDoSharedRepositoryState {
    <#
    .SYNOPSIS
    Updates the selected shared repository and template source used by preview and apply.
    .DESCRIPTION
    Reuses the local scaffold when available; otherwise clones the selected repository.
    An unavailable configured repository also uses the upstream scaffold so setup can
    reach the menu and let the user select a replacement. An empty newly selected
    repository uses the upstream scaffold until its version-update step seeds it.
    Replaced temporary clones are removed after the new source is ready. Cloning and
    replacing the template source are gated by ShouldProcess.
    .PARAMETER RepositoryState
    Mutable selected repository and template-source state used by setup previews and apply.
    .PARAMETER Initialization
    Repository context returned by Initialize-AzDoProjectAndRepository.
    .PARAMETER AccessToken
    Bearer token used to authenticate shared and upstream repository clones.
    .PARAMETER UpstreamGitSource
    Git source used to seed template files when the selected repository is empty.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'AccessToken', Justification = 'Captured by the nested shared-repository clone script block.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'UpstreamGitSource', Justification = 'Captured by the nested upstream-template clone script block.')]
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$RepositoryState,
        [Parameter(Mandatory)][object]$Initialization,
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][string]$UpstreamGitSource
    )

    $selectedSharedRepository = Get-OptionalObjectPropertyValue -InputObject $Initialization -PropertyName 'SharedRepo'
    $selectedSharedRepositoryName = [string](Get-OptionalObjectPropertyValue -InputObject $Initialization -PropertyName 'SharedRepoName')
    $selectionError = [string](Get-OptionalObjectPropertyValue -InputObject $Initialization -PropertyName 'SharedRepositorySelectionError')
    if ($selectedSharedRepository -and [string]::IsNullOrWhiteSpace($selectedSharedRepositoryName)) {
        throw 'Shared repository initialization did not return a valid repository.'
    }
    if (-not $selectedSharedRepository -and [string]::IsNullOrWhiteSpace($selectionError)) {
        throw 'Shared repository initialization did not return a valid repository.'
    }
    if (-not $selectedSharedRepository -and [string]::IsNullOrWhiteSpace($selectedSharedRepositoryName)) {
        $selectedSharedRepositoryName = [string]$RepositoryState.Name
    }
    $preparationTarget = if ([string]::IsNullOrWhiteSpace($selectedSharedRepositoryName)) {
        'upstream templates'
    }
    else {
        $selectedSharedRepositoryName
    }
    if (-not $PSCmdlet.ShouldProcess($preparationTarget, 'Prepare shared-repository template source')) {
        return $RepositoryState
    }

    $newClonePath = $null
    $newCopyRoot = [string]$RepositoryState.CopyRoot
    if ([bool]$RepositoryState.UsesLocalCopyRoot) {
        if (-not (Test-Path -LiteralPath $newCopyRoot -PathType Container)) {
            throw "Local shared-repository template source was not found: $newCopyRoot"
        }
    }
    elseif (-not $selectedSharedRepository) {
        $newClonePath = Join-Path ([System.IO.Path]::GetTempPath()) ("ALM4Dataverse-UpstreamTemplates-" + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $newClonePath -Force | Out-Null
        try {
            Invoke-WithErrorHandling -OperationName 'Cloning upstream templates for shared repository selection' -StatusMessage 'Cloning upstream templates because the configured shared repository is unavailable...' -CaptureOutputInPanel -ScriptBlock {
                & git clone $UpstreamGitSource $newClonePath
                if ($LASTEXITCODE -ne 0) {
                    throw "Git clone of upstream templates failed with exit code $LASTEXITCODE"
                }
            } | Out-Null

            $newCopyRoot = Join-Path $newClonePath 'copy-to-your-repo'
            if (-not (Test-Path -LiteralPath $newCopyRoot -PathType Container)) {
                throw 'Upstream repository does not contain a copy-to-your-repo template directory.'
            }
        }
        catch {
            if ($newClonePath -and (Test-Path -LiteralPath $newClonePath)) {
                try {
                    Remove-Item -LiteralPath $newClonePath -Recurse -Force -ErrorAction Stop
                }
                catch {
                    Write-Verbose 'Could not remove the failed upstream template clone; continuing cleanup.'
                }
            }
            throw
        }
    }
    else {
        $repositoryRemoteUrl = [string](Get-OptionalObjectPropertyValue -InputObject $selectedSharedRepository -PropertyName 'remoteUrl')
        if ([string]::IsNullOrWhiteSpace($repositoryRemoteUrl)) {
            throw "Could not determine remoteUrl for repository '$selectedSharedRepositoryName'."
        }

        $newClonePath = Join-Path ([System.IO.Path]::GetTempPath()) ("ALM4Dataverse-SharedRepo-" + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $newClonePath -Force | Out-Null
        try {
            Invoke-WithErrorHandling -OperationName 'Cloning shared repository templates' -StatusMessage 'Cloning the shared repository to get template files...' -CaptureOutputInPanel -ScriptBlock {
                & git -c "http.extraheader=AUTHORIZATION: bearer $AccessToken" clone $repositoryRemoteUrl $newClonePath
                if ($LASTEXITCODE -ne 0) {
                    throw "Git clone of shared repository failed with exit code $LASTEXITCODE"
                }
            } | Out-Null

            $newCopyRoot = Join-Path $newClonePath 'copy-to-your-repo'
            if (-not (Test-Path -LiteralPath $newCopyRoot -PathType Container)) {
                $null = & git -C $newClonePath rev-parse --verify HEAD 2>$null
                $sharedRepositoryHasCommits = $LASTEXITCODE -eq 0
                if ($sharedRepositoryHasCommits) {
                    throw "Shared repository '$selectedSharedRepositoryName' does not contain a copy-to-your-repo template directory."
                }

                Remove-Item -LiteralPath $newClonePath -Recurse -Force -ErrorAction Stop
                $newClonePath = Join-Path ([System.IO.Path]::GetTempPath()) ("ALM4Dataverse-UpstreamTemplates-" + [guid]::NewGuid().ToString('n'))
                New-Item -ItemType Directory -Path $newClonePath -Force | Out-Null
                Invoke-WithErrorHandling -OperationName 'Cloning upstream templates' -StatusMessage 'Cloning upstream templates for the new shared repository...' -CaptureOutputInPanel -ScriptBlock {
                    & git clone $UpstreamGitSource $newClonePath
                    if ($LASTEXITCODE -ne 0) {
                        throw "Git clone of upstream templates failed with exit code $LASTEXITCODE"
                    }
                } | Out-Null

                $newCopyRoot = Join-Path $newClonePath 'copy-to-your-repo'
                if (-not (Test-Path -LiteralPath $newCopyRoot -PathType Container)) {
                    throw "Upstream repository does not contain a copy-to-your-repo template directory."
                }
            }
        }
        catch {
            if ($newClonePath -and (Test-Path -LiteralPath $newClonePath)) {
                try {
                    Remove-Item -LiteralPath $newClonePath -Recurse -Force -ErrorAction Stop
                }
                catch {
                    Write-Verbose 'Could not remove the failed shared repository clone; continuing cleanup.'
                }
            }
            throw
        }
    }

    $previousClonePath = [string]$RepositoryState.ClonePath
    $RepositoryState.Repository = $selectedSharedRepository
    $RepositoryState.Name = $selectedSharedRepositoryName
    $RepositoryState.Ref = [string]$Initialization.SharedRepositoryRef
    $RepositoryState.CopyRoot = $newCopyRoot
    $RepositoryState.ClonePath = $newClonePath
    if ($selectedSharedRepository) {
        $RepositoryState.ValidationError = ''
    }
    else {
        $RepositoryState.ValidationError = $selectionError
    }
    $script:repo = $selectedSharedRepository
    $script:sharedRepoName = $selectedSharedRepositoryName
    $script:sharedRepositoryRef = [string]$Initialization.SharedRepositoryRef
    $script:copyRoot = $newCopyRoot
    $script:sharedRepoClone = $newClonePath

    if (
        -not [string]::IsNullOrWhiteSpace($previousClonePath) -and
        $previousClonePath -ne $newClonePath -and
        (Test-Path -LiteralPath $previousClonePath)
    ) {
        try {
            Remove-Item -LiteralPath $previousClonePath -Recurse -Force -ErrorAction Stop
        }
        catch {
            Write-Verbose 'Could not remove the previous shared repository clone; continuing cleanup.'
        }
    }

    return $RepositoryState
}

function Initialize-AzDoAuthentication {
    [CmdletBinding()]
    param([Parameter()][string]$TenantId)

    Write-Section -Message 'Authenticating'

    Write-Host "To enable automated setup setup, we need to authenticate with the necessary services." -ForegroundColor Green
    Write-Host ""
    Write-Host "When prompted, please log in with an account that has access to:" -ForegroundColor Green
    Write-Host "- Your Azure DevOps organization/project (PROJECT administrator role for existing project, ORGANISATION OWNER role if you want to create a new project)" -ForegroundColor Green
    Write-Host "- Your Dataverse DEV environment (SYSTEM ADMINISTRATOR role)" -ForegroundColor Green
    Write-Host ""

    $adoResourceUrl = '499b84ac-1321-427f-aa17-267ca6975798'
    $cachedAzureAccounts = @(Get-AuthToken -ResourceUrl $adoResourceUrl -TenantId $TenantId -ListAccountsOnly)
    $preferredAzureUsername = $null
    $forceAzureInteractive = $false

    if ($cachedAzureAccounts.Count -gt 0) {
        $azureAuthMenuItems = @($cachedAzureAccounts | ForEach-Object { "Use existing Azure login: $_" })
        $azureAuthMenuItems += "Sign in with a different Azure account"

        $azureAuthChoice = Select-FromMenu `
            -Title "Azure authentication" `
            -Items $azureAuthMenuItems `
            -PromptGuidanceLines @(
                'Choose whether to reuse an existing Azure login context or authenticate with a different identity.',
                'Use an identity with permissions to administer Azure DevOps resources and Dataverse setup prerequisites.'
            ) `
            -PromptGuidanceDocRelativePath 'docs/setup/azdo-automated-setup.md' `
            -PromptGuidanceRef $ALM4DataverseRef
        if ($null -eq $azureAuthChoice) {
            throw "No Azure authentication option selected."
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

    $authResult = Invoke-WithErrorHandling -OperationName "Authentication" -ScriptBlock {
        $result = Get-AuthToken -ResourceUrl $adoResourceUrl -TenantId $TenantId -PreferredUsername $preferredAzureUsername -ForceInteractive:$forceAzureInteractive

        if (-not $result -or -not $result.AccessToken) {
            throw "Failed to acquire an Azure DevOps access token."
        }

        return $result
    }

    $adoAccessToken = [pscustomobject]@{ Token = $authResult.AccessToken }
    return [pscustomobject]@{
        AuthResult = $authResult
        AccessToken = $adoAccessToken
        SecureToken = ConvertTo-SecureString -String $adoAccessToken.Token -AsPlainText -Force
    }
}