function Get-GitHubExistingEnvironmentSelectionSummary {
    # Display metadata only, never the stored client secret. Partial discovery
    # records return null when neither credential nor service-account text is available.
    [CmdletBinding()]
    param(
        [Parameter()][object]$ExistingEnvironment
    )

    if (-not $ExistingEnvironment) {
        return $null
    }

    $summaryParts = @()
    if ($ExistingEnvironment.PSObject.Properties.Name -contains 'Credentials' -and $ExistingEnvironment.Credentials) {
        $summaryParts += (Get-CredentialSummaryText -Credentials $ExistingEnvironment.Credentials)
    }
    if ($ExistingEnvironment.PSObject.Properties.Name -contains 'ServiceAccountUPN' -and -not [string]::IsNullOrWhiteSpace($ExistingEnvironment.ServiceAccountUPN)) {
        $summaryParts += "Service account: $($ExistingEnvironment.ServiceAccountUPN)"
    }

    if ($summaryParts.Count -eq 0) {
        return $null
    }

    return ($summaryParts -join ' | ')
}

function Get-DataverseEnvironmentCatalog {
    <#
    .SYNOPSIS
        Returns the script-scoped Dataverse discovery cache, optionally refreshing it.
    .DESCRIPTION
        Uses the enclosing TenantId to acquire a Global Discovery token before calling
        the discovery cmdlet. Its token callback runs on a worker task and only returns
        the acquired token. ForceRefresh bypasses the cache; ShowStatus affects
        presentation only. A fresh empty result throws; failures propagate.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject], [object[]])]
    param(
        [Parameter()][switch]$ForceRefresh,
        [Parameter()][switch]$ShowStatus
    )

    $hasCachedCatalog = ($null -ne (Get-Variable -Name 'dataverseEnvironmentCatalog' -Scope Script -ErrorAction SilentlyContinue)) -and $null -ne $script:dataverseEnvironmentCatalog
    if (-not $ForceRefresh -and $hasCachedCatalog) {
        return @($script:dataverseEnvironmentCatalog)
    }

    $discoveryResource = 'https://globaldisco.crm.dynamics.com'
    if ($ShowStatus) {
        Write-Host 'Authenticating to retrieve Dataverse environments...' -ForegroundColor DarkGray
    }

    $discoveryAccessToken = Get-SetupAccessToken -ResourceUrl $discoveryResource -TenantId $TenantId
    $accessTokenProvider = {
        param($resource)
        if (-not [string]::IsNullOrWhiteSpace($resource)) {
            try {
                $resourceAuthority = ([System.Uri]$resource).GetLeftPart([System.UriPartial]::Authority)
            }
            catch {
                throw 'Dataverse environment discovery requested an invalid authentication resource.'
            }

            if ($resourceAuthority -ne $discoveryResource) {
                throw 'Dataverse environment discovery requested a token for an unexpected resource.'
            }
        }

        return $discoveryAccessToken
    }.GetNewClosure()

    $fetchCatalog = {
        @(Get-DataverseEnvironment -AccessToken $accessTokenProvider)
    }

    if ($ShowStatus) {
        $script:dataverseEnvironmentCatalog = @(Invoke-WithSpectreStatus -Status 'Retrieving Dataverse environments...' -ScriptBlock $fetchCatalog)
    }
    else {
        $script:dataverseEnvironmentCatalog = @(& $fetchCatalog)
    }

    if (-not $script:dataverseEnvironmentCatalog -or $script:dataverseEnvironmentCatalog.Count -eq 0) {
        throw 'No Dataverse environments found. Ensure the account has access to at least one environment.'
    }

    return @($script:dataverseEnvironmentCatalog)
}

function Select-DataverseEnvironment {
    <#
    .SYNOPSIS
        Selects a discovered environment with normalized preferred/excluded URL handling.
    .DESCRIPTION
        Exclusion applies before preference. The preferred shortcut returns an
        environment-shaped object with UseExistingConfiguration true; ordinary rows
        return discovery objects. KeepPreferredInList retains an ordinary row too,
        allowing reconfiguration of the same target. Menu cancellation returns null;
        no selectable environments throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter()][string]$ExcludeUrl,
        [Parameter()][string]$PreferredUrl,
        [Parameter()][string]$PreferredSelectionSummary,
        [Parameter()][switch]$KeepPreferredInList,
        [Parameter()][string[]]$PromptGuidanceLines,
        [Parameter()][string]$PromptGuidanceDocRelativePath,
        [Parameter()][string]$PromptGuidanceRef
    )

    Write-Host ""

    $environments = @(Get-DataverseEnvironmentCatalog -ShowStatus)

    $normalizedExcludeUrl = ConvertTo-NormalizedEnvironmentUrl -Url $ExcludeUrl
    $normalizedPreferredUrl = ConvertTo-NormalizedEnvironmentUrl -Url $PreferredUrl

    if (-not [string]::IsNullOrWhiteSpace($ExcludeUrl)) {
        $environments = @($environments | Where-Object {
            (ConvertTo-NormalizedEnvironmentUrl -Url $_.Endpoints["WebApplication"]) -ne $normalizedExcludeUrl
        })
    }

    if ($environments.Count -eq 0) {
        throw "No selectable Dataverse environments found (all were excluded)."
    }

    $menuItems = @()
    $menuActions = @()

    if (-not [string]::IsNullOrWhiteSpace($normalizedPreferredUrl)) {
        $preferredEnvironment = $environments | Where-Object {
            (ConvertTo-NormalizedEnvironmentUrl -Url $_.Endpoints['WebApplication']) -eq $normalizedPreferredUrl
        } | Select-Object -First 1

        if ($preferredEnvironment) {
            $preferredMenuItem = "Use existing environment: $($preferredEnvironment.FriendlyName) ($($preferredEnvironment.Endpoints['WebApplication']))"
            if (-not [string]::IsNullOrWhiteSpace($PreferredSelectionSummary)) {
                $preferredMenuItem += " | $PreferredSelectionSummary"
            }

            $menuItems += $preferredMenuItem
            $menuActions += [pscustomobject]@{
                Environment = [pscustomobject]@{
                    FriendlyName             = $preferredEnvironment.FriendlyName
                    UniqueName               = $preferredEnvironment.UniqueName
                    Endpoints                = $preferredEnvironment.Endpoints
                    UseExistingConfiguration = $true
                }
            }

            if (-not $KeepPreferredInList) {
                $environments = @($environments | Where-Object {
                    (ConvertTo-NormalizedEnvironmentUrl -Url $_.Endpoints['WebApplication']) -ne $normalizedPreferredUrl
                })
            }
        }
    }

    foreach ($environment in $environments) {
        $menuItems += "$($environment.FriendlyName) ($($environment.Endpoints['WebApplication']))"
        $menuActions += [pscustomobject]@{ Environment = $environment }
    }

    $index = Select-FromMenu `
        -Title $Prompt `
        -Items $menuItems `
        -PromptGuidanceLines $PromptGuidanceLines `
        -PromptGuidanceDocRelativePath $PromptGuidanceDocRelativePath `
        -PromptGuidanceRef $PromptGuidanceRef
    if ($null -eq $index) { return $null }

    return $menuActions[$index].Environment
}

function Initialize-DataverseApplicationUser {
    <#
    .SYNOPSIS
        Ensures an application user and its root-business-unit System Administrator role.
    .DESCRIPTION
        Connects using delegated authentication for TenantId, finds the root business
        unit and its named role, then creates only missing user/role associations.
        Existing users are not moved between business units. Missing connection,
        business unit or role throws; these writes have no ShouldProcess guard here.
    #>
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

    $rootBu = Get-DataverseRecord -Connection $conn -TableName "businessunit" -FilterValues @{ parentbusinessunitid = $null } -Columns "businessunitid" | Select-Object -First 1
    if (-not $rootBu) { throw "Could not find root business unit." }
    $rootBuId = $rootBu.businessunitid

    $roleName = "System Administrator"
    $role = Get-DataverseRecord -Connection $conn -TableName "role" -FilterValues @{ name = $roleName; businessunitid = $rootBuId } -Columns "roleid" | Select-Object -First 1
    if (-not $role) { throw "Could not find '$roleName' role in root business unit." }
    $roleId = $role.roleid

    $user = Get-DataverseRecord -Connection $conn -TableName "systemuser" -FilterValues @{ applicationid = $ApplicationId } -Columns "systemuserid" | Select-Object -First 1
    $userId = $null

    if ($user) {
        Write-Host "User already exists. ID: $($user.systemuserid)"
        $userId = $user.systemuserid
    }
    else {
        Write-Host "Creating application user..."
        $userAttributes = @{
            "applicationid"  = $ApplicationId
            "businessunitid" = $rootBuId
        }
        $createdUser = $userAttributes | Set-DataverseRecord -Connection $conn -TableName "systemuser" -CreateOnly -PassThru
        $userId = $createdUser.Id
        Write-Host "User created. ID: $userId"
    }

    # Role IDs are business-unit-specific; use the role resolved from the root BU
    # rather than an arbitrary same-name role elsewhere in the organization.
    $existingAssociation = Get-DataverseRecord -Connection $conn -TableName "systemuserroles" -FilterValues @{ systemuserid = $userId; roleid = $roleId } -Top 1
    if (-not $existingAssociation) {
        Write-Host "Associating user with '$roleName' role..."
        @{
            systemuserid = $userId
            roleid       = $roleId
        } | Set-DataverseRecord -Connection $conn -TableName "systemuserroles" -CreateOnly
        Write-Host "Association successful."
    }
    else {
        Write-Host "User is already associated with '$roleName' role."
    }
}

function Initialize-DataverseServiceAccountUser {
    <#
    .SYNOPSIS
        Ensures a service-account system user and root-BU System Administrator association.
    .DESCRIPTION
        Looks up by domainname, creates a missing user in the root business unit, and
        adds the named role only if not already associated. Does not validate or
        assign licensing. Connection, lookup and write failures propagate; mutations
        are not guarded by ShouldProcess within this helper.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EnvironmentUrl,
        [Parameter(Mandatory)][string]$ServiceAccountUPN,
        [Parameter(Mandatory)][string]$TenantId
    )

    Write-Host "Ensuring service account '$ServiceAccountUPN' has System Administrator role in '$EnvironmentUrl'..." -ForegroundColor DarkGray

    $accessTokenCallback = Get-SetupAccessTokenCallback -ResourceUrl $EnvironmentUrl -TenantId $TenantId
    $conn = Get-DataverseConnection -Url $EnvironmentUrl -AccessToken $accessTokenCallback

    if (-not $conn) { throw "Failed to connect to Dataverse." }

    $rootBu = Get-DataverseRecord -Connection $conn -TableName "businessunit" -FilterValues @{ parentbusinessunitid = $null } -Columns "businessunitid" | Select-Object -First 1
    if (-not $rootBu) { throw "Could not find root business unit." }
    $rootBuId = $rootBu.businessunitid

    $roleName = "System Administrator"
    $role = Get-DataverseRecord -Connection $conn -TableName "role" -FilterValues @{ name = $roleName; businessunitid = $rootBuId } -Columns "roleid" | Select-Object -First 1
    if (-not $role) { throw "Could not find '$roleName' role in root business unit." }
    $roleId = $role.roleid

    $user = Get-DataverseRecord -Connection $conn -TableName "systemuser" -FilterValues @{ domainname = $ServiceAccountUPN } -Columns "systemuserid","fullname" | Select-Object -First 1
    $userId = $null

    if ($user) {
        $userId = $user.systemuserid
        Write-Host "Found service account: $($user.fullname) (ID: $userId)"
    }
    else {
        Write-Host "Service account '$ServiceAccountUPN' not found. Creating..." -ForegroundColor Yellow
        $userAttributes = @{
            "domainname"           = $ServiceAccountUPN
            "businessunitid"       = $rootBuId
            "internalemailaddress" = $ServiceAccountUPN
            "firstname"            = "Service"
            "lastname"             = "Account"
        }
        $createdUser = $userAttributes | Set-DataverseRecord -Connection $conn -TableName "systemuser" -CreateOnly -PassThru
        $userId = $createdUser.Id
        Write-Host "Service account created. ID: $userId"
    }

    $existingAssociation = Get-DataverseRecord -Connection $conn -TableName "systemuserroles" -FilterValues @{ systemuserid = $userId; roleid = $roleId } -Top 1
    if (-not $existingAssociation) {
        Write-Host "Associating service account with '$roleName' role..."
        @{
            systemuserid = $userId
            roleid       = $roleId
        } | Set-DataverseRecord -Connection $conn -TableName "systemuserroles" -CreateOnly
        Write-Host "Association successful."
    }
    else {
        Write-Host "Service account is already associated with '$roleName' role."
    }
}

function Get-DataverseServiceAccountUPN {
    <#
    .SYNOPSIS
        Selects an existing/cached service account or prompts for a UPN-shaped string.
    .DESCRIPTION
        Returns the selected UPN without resolving the user or checking licensing.
        Only manual input receives format validation. Cancelling the menu throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][array]$ExistingServiceAccounts,
        [Parameter()][string]$EnvironmentName,
        [Parameter()][string]$ExistingValue
    )

    $menuItems  = @()
    $menuActions = @()

    if (-not [string]::IsNullOrWhiteSpace($ExistingValue)) {
        $menuItems  += "Use existing: $ExistingValue"
        $menuActions += @{ Type = 'Existing'; UPN = $ExistingValue }
    }

    $menuItems  += "Enter a new service account UPN"
    $menuActions += @{ Type = 'Manual' }

    foreach ($sa in $ExistingServiceAccounts) {
        if ($sa -ne $ExistingValue) {
            $menuItems  += "Reuse: $sa"
            $menuActions += @{ Type = 'Cached'; UPN = $sa }
        }
    }

    $selection = Select-FromMenu `
        -Title "Select Dataverse Service Account for '$EnvironmentName'" `
        -Items $menuItems `
        -PromptGuidanceLines @(
            'The service account owns flow activation and needs a license plus the System Administrator role.',
            'Keep it separate from a personal admin account so automation ownership stays stable.',
            "Choose the service account UPN that should own flow activation and runtime ownership in '$EnvironmentName'.",
            'Reusing an existing service account keeps ownership consistent; entering a new one changes who owns activated processes.'
        ) `
        -PromptGuidanceDocRelativePath 'docs/config/github-secrets.md' `
        -PromptGuidanceRef $ALM4DataverseRef
    if ($null -eq $selection) { throw "No service account selected." }

    $action = $menuActions[$selection]

    if ($action.Type -in @('Cached', 'Existing')) {
        return $action.UPN
    }
    else { # Manual
        Write-Host ""
        Write-Host "IMPORTANT: The service account must be licensed with an appropriate D365/PowerApps/etc licence." -ForegroundColor Yellow
        Write-Host ""

        while ($true) {
            $upn = Read-TextWithDefault -Prompt 'Service Account UPN (for example: serviceaccount@contoso.com)'
            if ([string]::IsNullOrWhiteSpace($upn)) {
                Write-Warning "Service Account UPN cannot be empty."
                continue
            }
            if ($upn -match '^[^@]+@[^@]+\.[^@]+$') {
                return $upn
            }
            else {
                Write-Warning "The UPN does not appear to be in a valid format."
            }
        }
    }
}

function Get-DataverseSolutionsSelection {
    <#
    .SYNOPSIS
        Discovers and orders user-created unmanaged solutions from a selected DEV environment.
    .DESCRIPTION
        ExistingConfigPath preselects still-available names in configured order.
        Returns Solutions entries with name/deployUnmanaged=false, EnvironmentUrl and
        ReuseExistingConfiguration; normal selections also include EnvironmentFriendlyName.
        No eligible solutions returns an empty list, not a cancelled selection.
        Uses the enclosing TenantId; environment cancellation or connection failure throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][string]$ExistingConfigPath,
        [Parameter()][string]$ExistingEnvironmentUrl,
        [Parameter()][object]$ExistingEnvironmentConfiguration
    )

    $existingEnvironmentSummary = Get-GitHubExistingEnvironmentSelectionSummary -ExistingEnvironment $ExistingEnvironmentConfiguration
    $selectedEnv = Select-DataverseEnvironment `
        -Prompt "Select your DEV environment" `
        -PreferredUrl $ExistingEnvironmentUrl `
        -PreferredSelectionSummary $existingEnvironmentSummary `
        -PromptGuidanceLines @(
            'Choose the DEV environment that contains the unmanaged solutions to export and build from source control.',
            'Use the environment that reflects the customization baseline your team wants to manage.',
            'Solutions are later stored in dependency order in alm-config.psd1.',
            'Choose the DEV Dataverse environment used to discover unmanaged solutions for alm-config.psd1.',
            'Pick the environment that currently reflects the source-controlled customization baseline.'
        ) `
        -PromptGuidanceDocRelativePath 'docs/config/alm-config.md' `
        -PromptGuidanceRef $ALM4DataverseRef
    if (-not $selectedEnv) { throw "No environment selected." }

    $devEnvUrl = ConvertTo-NormalizedEnvironmentUrl -Url $selectedEnv.Endpoints["WebApplication"]
    $normalizedExistingEnvironmentUrl = ConvertTo-NormalizedEnvironmentUrl -Url $ExistingEnvironmentUrl
    $reuseExistingConfiguration = (
        ($selectedEnv.PSObject.Properties.Name -contains 'UseExistingConfiguration' -and $selectedEnv.UseExistingConfiguration) -or
        (
            -not [string]::IsNullOrWhiteSpace($normalizedExistingEnvironmentUrl) -and
            $devEnvUrl -ieq $normalizedExistingEnvironmentUrl
        )
    )

    Write-Host "Selected: $($selectedEnv.FriendlyName) ($devEnvUrl)" -ForegroundColor Cyan

    Write-Host 'Authenticating to the selected DEV environment...' -ForegroundColor DarkGray
    $devAccessTokenCallback = Get-SetupAccessTokenCallback -ResourceUrl $devEnvUrl -TenantId $TenantId
    $connection = Invoke-WithSpectreStatus -Status 'Connecting to the selected DEV environment...' -ScriptBlock {
        Get-DataverseConnection -Url $devEnvUrl -AccessToken $devAccessTokenCallback
    }

    if (-not $connection) { throw "Failed to connect to Dataverse environment." }

    Write-Host "Connected to: $($connection.ConnectedOrgFriendlyName)"

    $allSolutions = Invoke-WithSpectreStatus -Status 'Retrieving unmanaged solutions from Dataverse...' -ScriptBlock {
        Get-DataverseRecord -Connection $connection -TableName 'solution' -Columns @('solutionid','uniquename','friendlyname','version','ismanaged') -FilterValues @{
            'isvisible' = $true
            'ismanaged' = $false
        }
    }

    if (-not $allSolutions -or $allSolutions.Count -eq 0) {
        Write-Host "No unmanaged solutions found in the environment." -ForegroundColor Yellow
        return [pscustomobject]@{ Solutions = @(); EnvironmentUrl = $devEnvUrl; ReuseExistingConfiguration = $reuseExistingConfiguration }
    }

    $userSolutions = @($allSolutions | Where-Object {
        $_.uniquename -notmatch '^(Default|Active|Basic|msdyn_|ms|MicrosoftFlow|PowerPlatform)' -and
        $_.uniquename -ne 'System'
    } | Sort-Object friendlyname)

    if ($userSolutions.Count -eq 0) {
        Write-Host "No user-created solutions found." -ForegroundColor Yellow
        return [pscustomobject]@{ Solutions = @(); EnvironmentUrl = $devEnvUrl; ReuseExistingConfiguration = $reuseExistingConfiguration }
    }

    # Pre-populate from existing alm-config.psd1 if available
    $selectedSolutions = @()
    if ($ExistingConfigPath -and (Test-Path -LiteralPath $ExistingConfigPath)) {
        try {
            $existingConfig = Import-PowerShellDataFile -Path $ExistingConfigPath
            if ($existingConfig.solutions) {
                foreach ($existing in $existingConfig.solutions) {
                    $match = $userSolutions | Where-Object { $_.uniquename -eq $existing.name } | Select-Object -First 1
                    if ($match) { $selectedSolutions += $match }
                }
                if ($selectedSolutions.Count -gt 0) {
                    Write-Host "Pre-selected $($selectedSolutions.Count) solution(s) from existing configuration." -ForegroundColor Green
                    Start-Sleep -Seconds 2
                }
            }
        }
        catch { Write-Verbose 'Could not preselect solutions from the existing configuration; continuing with manual selection.' }
    }

    $selectedSolutions = @(Select-OrderedSolution -AvailableSolutions $userSolutions -InitiallySelectedSolutions $selectedSolutions)

    # Convert to alm-config.psd1 format
    $configSolutions = @()
    foreach ($sol in $selectedSolutions) {
        $configSolutions += @{ name = $sol.uniquename; deployUnmanaged = $false }
    }

    return [pscustomobject]@{ Solutions = $configSolutions; EnvironmentUrl = $devEnvUrl; EnvironmentFriendlyName = $selectedEnv.FriendlyName; ReuseExistingConfiguration = $reuseExistingConfiguration }
}

function Get-GitHubEnvironmentConfiguration {
    <#
    .SYNOPSIS
        Collects a normalized environment record with selected credentials and service account.
    .DESCRIPTION
        Returns ShortName, FriendlyName (falling back to EnvironmentName), Url,
        Credentials and ServiceAccountUPN. Does not apply GitHub/Dataverse environment
        settings, but credential selection may already create an app or rotate a secret.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][string]$EnvironmentUrl,
        [Parameter()][string]$FriendlyName,
        [Parameter()][array]$ExistingCredentials,
        [Parameter()][array]$ExistingServiceAccounts,
        [Parameter()][string]$TenantId,
        [Parameter()][string]$RepoName,
        [Parameter()][object]$ExistingCredential,
        [Parameter()][string]$ExistingServiceAccountUPN
    )

    $creds = Get-GitHubCredentialsForEnvironment `
        -ExistingCredentials $ExistingCredentials `
        -TenantId $TenantId `
        -RepoName $RepoName `
        -EnvironmentName $EnvironmentName `
        -ExistingCredential $ExistingCredential

    $serviceAccountUPN = Get-DataverseServiceAccountUPN `
        -ExistingServiceAccounts $ExistingServiceAccounts `
        -EnvironmentName $EnvironmentName `
        -ExistingValue $ExistingServiceAccountUPN

    return [pscustomobject]@{
        ShortName        = $EnvironmentName
        FriendlyName     = $(if ([string]::IsNullOrWhiteSpace($FriendlyName)) { $EnvironmentName } else { $FriendlyName })
        Url              = (ConvertTo-NormalizedEnvironmentUrl -Url $EnvironmentUrl)
        Credentials      = $creds
        ServiceAccountUPN = $serviceAccountUPN
    }
}

function Invoke-GitHubEnvironmentConfigurationWizard {
    <#
    .SYNOPSIS
        Edits a GitHub Dataverse target through the shared detail menu.
    .DESCRIPTION
        Dataverse selection, editable target names, credentials, service-account
        ownership, and an optional BUILD baseline are separate sequential steps.
        Changing the Dataverse environment invalidates credentials and ownership
        selected for a different URL.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'DataverseEnvironmentPrompt', Justification = 'Captured by the nested Dataverse-selection callback.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ExcludedUrl', Justification = 'Captured by the nested Dataverse-selection callback.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'PreferredSelectionSummary', Justification = 'Captured by the nested Dataverse-selection callback.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ExistingCredentials', Justification = 'Captured by the nested credential callback.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ExistingServiceAccounts', Justification = 'Captured by the nested service-account callback.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'TenantId', Justification = 'Captured by nested configuration callbacks.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'RepoName', Justification = 'Captured by the nested credential callback.')]
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
        [Parameter()][AllowEmptyString()][string]$PreferredSelectionSummary = '',
        [Parameter()][array]$ExistingCredentials,
        [Parameter()][array]$ExistingServiceAccounts,
        [Parameter()][string]$TenantId,
        [Parameter()][string]$RepoName,
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
            -PreferredSelectionSummary $PreferredSelectionSummary `
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
        Get-GitHubCredentialsForEnvironment `
            -ExistingCredentials $ExistingCredentials `
            -TenantId $TenantId `
            -RepoName $RepoName `
            -EnvironmentName $environmentState.ShortName `
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
        ConfigurationPending = $false
    }
    if ($SelectBaselineAction) {
        $result | Add-Member -NotePropertyName BaselineRelease -NotePropertyValue ([string]$environmentConfiguration.BaselineRelease)
    }

    return $result
}

function Set-GitHubEnvironmentConfiguration {
    <#
    .SYNOPSIS
        Applies one environment's trust, GitHub credentials and Dataverse user permissions.
    .DESCRIPTION
        After ShouldProcess, configures WIF when an application-object ID is available,
        writes either environment variables or repository variables, then ensures
        both Dataverse identities. UseImmutableWifSubject must match GitHub's effective
        setting. Missing secret values preserve existing secrets rather than clearing
        them. Repository-variable mode can still create an environment for a secret.
        Writes are ordered but not transactional; a later failure leaves earlier changes.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][object]$EnvironmentConfiguration,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$RepoOwner,
        [Parameter(Mandatory)][string]$RepoName,
        [Parameter(Mandatory)][string]$RepoFullName,
        [Parameter(Mandatory)][long]$RepoOwnerId,
        [Parameter(Mandatory)][long]$RepoId,
        [Parameter(Mandatory)][bool]$UseImmutableWifSubject,
        [Parameter()][bool]$UseGitHubEnvironments = $true,
        [Parameter()][bool]$UseRepositoryVariablePrefix = $true,
        [Parameter()][bool]$EnableApprovals = $false,
        [Parameter()][array]$RequiredReviewerIds = @()
    )

    if (-not $PSCmdlet.ShouldProcess("$RepoOwner/$RepoName", 'Configure GitHub deployment environment')) { return }

    $creds = $EnvironmentConfiguration.Credentials
    $serviceAccountUPN = $EnvironmentConfiguration.ServiceAccountUPN

    if ($creds.AuthType -eq 'WIF' -and $creds.ApplicationObjectId) {
        $credName = ConvertTo-UrlSafeName -Name "gha-$RepoName-env-$($EnvironmentConfiguration.ShortName)"
        $wifSubject = New-GitHubEnvironmentWifSubject `
            -RepoOwner $RepoOwner `
            -RepoName $RepoName `
            -RepoFullName $RepoFullName `
            -RepoOwnerId $RepoOwnerId `
            -RepoId $RepoId `
            -EnvironmentName $EnvironmentConfiguration.ShortName `
            -UseImmutableSubject $UseImmutableWifSubject
        [void](Add-EntraIdFederatedCredential `
            -ApplicationObjectId $creds.ApplicationObjectId `
            -TenantId $TenantId `
            -Subject $wifSubject `
            -CredentialName $credName)
    }

    if ($UseGitHubEnvironments) {
        [void](Initialize-GitHubEnvironment `
            -Owner $RepoOwner `
            -Repo $RepoName `
            -EnvironmentName $EnvironmentConfiguration.ShortName `
            -EnableApprovals:$EnableApprovals `
            -RequiredReviewerIds $RequiredReviewerIds)

        Set-GitHubEnvironmentVariable -Owner $RepoOwner -Repo $RepoName -EnvironmentName $EnvironmentConfiguration.ShortName `
            -VariableName 'AZURE_CLIENT_ID' -VariableValue $creds.ApplicationId
        Set-GitHubEnvironmentVariable -Owner $RepoOwner -Repo $RepoName -EnvironmentName $EnvironmentConfiguration.ShortName `
            -VariableName 'AZURE_TENANT_ID' -VariableValue $creds.TenantId

        if ($creds.AuthType -eq 'Secret' -and $creds.ClientSecret) {
            Set-GitHubEnvironmentSecret -Owner $RepoOwner -Repo $RepoName -EnvironmentName $EnvironmentConfiguration.ShortName `
                -SecretName 'AZURE_CLIENT_SECRET' -SecretValue $creds.ClientSecret
        }

        Set-GitHubEnvironmentVariable -Owner $RepoOwner -Repo $RepoName -EnvironmentName $EnvironmentConfiguration.ShortName `
            -VariableName 'DATAVERSE_URL' -VariableValue $EnvironmentConfiguration.Url

        Set-GitHubEnvironmentVariable -Owner $RepoOwner -Repo $RepoName -EnvironmentName $EnvironmentConfiguration.ShortName `
            -VariableName 'DATAVERSESERVICEACCOUNTUPN' -VariableValue $serviceAccountUPN
    }
    else {
        Set-GitHubPrefixedEnvironmentCredential `
            -Owner $RepoOwner `
            -Repo $RepoName `
            -EnvironmentName $EnvironmentConfiguration.ShortName `
            -Credentials $creds `
            -DataverseUrl $EnvironmentConfiguration.Url `
            -ServiceAccountUPN $serviceAccountUPN `
            -UseEnvironmentPrefix $UseRepositoryVariablePrefix
    }

    Initialize-DataverseApplicationUser -EnvironmentUrl $EnvironmentConfiguration.Url -ApplicationId $creds.ApplicationId -TenantId $TenantId
    Initialize-DataverseServiceAccountUser -EnvironmentUrl $EnvironmentConfiguration.Url -ServiceAccountUPN $serviceAccountUPN -TenantId $TenantId
}

function Get-SecretJsonInputBlock {
    <#
    .SYNOPSIS
        Locates secrets-json inputs without evaluating their GitHub expressions.
    .DESCRIPTION
        Returns zero-based inclusive StartLine/EndLine, KeyIndent and the nearest
        preceding environment-name. Block scalars end at the next nonblank line of
        equal/lower indentation. This recognizes generated workflow layout, not
        arbitrary YAML structure; no matching inputs produces no records.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines)

    $blocks = New-Object System.Collections.Generic.List[object]
    for ($lineIndex = 0; $lineIndex -lt $Lines.Count; $lineIndex++) {
        $keyMatch = [regex]::Match($Lines[$lineIndex], '^(?<indent>[\t ]*)secrets-json:(?<tail>.*)$')
        if (-not $keyMatch.Success) {
            continue
        }

        $keyIndent = $keyMatch.Groups['indent'].Value.Length
        $endLine = $lineIndex
        $tail = $keyMatch.Groups['tail'].Value
        $isBlockScalar = [string]::IsNullOrWhiteSpace($tail) -or $tail -match '^\s*[>|](?:[1-9])?[-+]?\s*(?:#.*)?$'
        if ($isBlockScalar) {
            for ($candidateIndex = $lineIndex + 1; $candidateIndex -lt $Lines.Count; $candidateIndex++) {
                if ([string]::IsNullOrWhiteSpace($Lines[$candidateIndex])) {
                    $endLine = $candidateIndex
                    continue
                }

                $contentIndent = [regex]::Match($Lines[$candidateIndex], '^[\t ]*').Length
                if ($contentIndent -le $keyIndent) {
                    break
                }

                $endLine = $candidateIndex
            }
        }

        $environmentName = ''
        for ($previousIndex = $lineIndex - 1; $previousIndex -ge 0; $previousIndex--) {
            $environmentMatch = [regex]::Match($Lines[$previousIndex], '^[\t ]*environment-name:[\t ]*(?<value>.*?)[\t ]*(?:#.*)?$')
            if ($environmentMatch.Success) {
                $environmentName = $environmentMatch.Groups['value'].Value.Trim().Trim("'").Trim('"')
                break
            }
        }

        $blocks.Add([pscustomobject]@{
            StartLine       = $lineIndex
            EndLine         = $endLine
            KeyIndent       = $keyIndent
            EnvironmentName = $environmentName
        })
        $lineIndex = $endLine
    }

    return $blocks.ToArray()
}

function Merge-SecretJsonInput {
    <#
    .SYNOPSIS
        Carries existing secrets-json inputs into regenerated workflow text.
    .DESCRIPTION
        Matches environment names first, then eligible positional fallbacks. Keeps
        expression-bearing text rather than parsing JSON, adjusts indentation and
        normalizes newlines to the current platform. Unmatched generated blocks stay
        unchanged; no existing/generated blocks returns normalized GeneratedContent.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExistingContent,
        [Parameter(Mandatory)][string]$GeneratedContent
    )

    $GeneratedContent = [regex]::Replace($GeneratedContent, "`r`n|`n|`r", [Environment]::NewLine)
    if ([string]::IsNullOrEmpty($ExistingContent)) {
        return $GeneratedContent
    }

    $existingLines = [regex]::Split($ExistingContent, "`r`n|`n|`r")
    $generatedLines = [regex]::Split($GeneratedContent, "`r`n|`n|`r")
    $existingBlocks = @(Get-SecretJsonInputBlock -Lines $existingLines)
    $generatedBlocks = @(Get-SecretJsonInputBlock -Lines $generatedLines)
    if ($existingBlocks.Count -eq 0 -or $generatedBlocks.Count -eq 0) {
        return $GeneratedContent
    }

    $replacements = New-Object System.Collections.Generic.List[object]
    for ($blockIndex = 0; $blockIndex -lt $generatedBlocks.Count; $blockIndex++) {
        $generatedBlock = $generatedBlocks[$blockIndex]
        $existingBlock = $null

        if (-not [string]::IsNullOrWhiteSpace($generatedBlock.EnvironmentName)) {
            foreach ($candidate in $existingBlocks) {
                if ($candidate.EnvironmentName -ieq $generatedBlock.EnvironmentName) {
                    $existingBlock = $candidate
                    break
                }
            }
        }

        if ($null -eq $existingBlock -and $existingBlocks.Count -eq $generatedBlocks.Count) {
            $existingBlock = $existingBlocks[$blockIndex]
        }
        elseif ($null -eq $existingBlock -and [string]::IsNullOrWhiteSpace($generatedBlock.EnvironmentName) -and $blockIndex -lt $existingBlocks.Count) {
            $existingBlock = $existingBlocks[$blockIndex]
        }

        if ($null -eq $existingBlock) {
            continue
        }

        $generatedKeyMatch = [regex]::Match($generatedLines[$generatedBlock.StartLine], '^(?<indent>[\t ]*)(?<key>secrets-json:)(?<tail>.*)$')
        $existingKeyMatch = [regex]::Match($existingLines[$existingBlock.StartLine], '^(?<indent>[\t ]*)(?<key>secrets-json:)(?<tail>.*)$')
        $replacementLines = New-Object System.Collections.Generic.List[string]
        $replacementLines.Add($generatedKeyMatch.Groups['indent'].Value + $generatedKeyMatch.Groups['key'].Value + $existingKeyMatch.Groups['tail'].Value)

        for ($oldLineIndex = $existingBlock.StartLine + 1; $oldLineIndex -le $existingBlock.EndLine; $oldLineIndex++) {
            $oldLine = $existingLines[$oldLineIndex]
            if ([string]::IsNullOrWhiteSpace($oldLine)) {
                $replacementLines.Add('')
                continue
            }

            $oldIndent = [regex]::Match($oldLine, '^[\t ]*').Length
            $relativeIndent = [Math]::Max(0, $oldIndent - $existingBlock.KeyIndent)
            $replacementLines.Add($generatedKeyMatch.Groups['indent'].Value + (' ' * $relativeIndent) + $oldLine.Substring($oldIndent))
        }

        $replacements.Add([pscustomobject]@{
            StartLine = $generatedBlock.StartLine
            EndLine   = $generatedBlock.EndLine
            Lines     = $replacementLines.ToArray()
        })
    }

    # Replace from the bottom so a changed block length cannot invalidate the
    # zero-based locations of blocks that still need to be replaced.
    foreach ($replacement in ($replacements | Sort-Object -Property StartLine -Descending)) {
        $beforeLines = @()
        $afterLines = @()
        if ($replacement.StartLine -gt 0) {
            $beforeLines = @($generatedLines[0..($replacement.StartLine - 1)])
        }
        if ($replacement.EndLine + 1 -lt $generatedLines.Count) {
            $afterLines = @($generatedLines[($replacement.EndLine + 1)..($generatedLines.Count - 1)])
        }

        $generatedLines = @($beforeLines) + @($replacement.Lines) + @($afterLines)
    }

    $newline = if ($GeneratedContent.Contains("`r`n")) { "`r`n" } else { "`n" }
    return ($generatedLines -join $newline)
}
