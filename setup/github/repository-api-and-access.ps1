function Invoke-GhApi {
    <#
    .SYNOPSIS
        Calls the GitHub REST API using the gh CLI.
    .DESCRIPTION
        Sends a truthy Body as JSON on stdin. Returns parsed JSON, raw CLI output when
        parsing fails, or null for an empty response. Nonzero CLI exits throw unless
        AllowNotFound matches 404/Not Found in the captured error text.
        Temporarily permits native stderr so the exit code can be handled explicitly.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [Parameter()][string]$Method = 'GET',
        [Parameter()][object]$Body,
        [Parameter()][switch]$AllowNotFound
    )

    $ghArgs = @('api', '--method', $Method, $Endpoint)

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'

        if ($Body) {
            $json = $Body | ConvertTo-Json -Depth 10 -Compress
            $ghArgs += @('--input', '-')

            $result = @($json | & gh @ghArgs 2>&1)
        }
        else {
            $result = @(& gh @ghArgs 2>&1)
        }

        $ghExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($ghExitCode -ne 0) {
        $errText = @($result | ForEach-Object { [string]$_ }) -join "`n"
        if ($AllowNotFound -and ($errText -match '404' -or $errText -match 'Not Found')) {
            return $null
        }
        throw "gh api call failed (exit code $ghExitCode): $errText"
    }

    if ($result) {
        try {
            return (@($result) -join [Environment]::NewLine) | ConvertFrom-Json
        }
        catch {
            return $result
        }
    }
    return $null
}

function Initialize-GitHubEnvironment {
    <#
    .SYNOPSIS
        Ensures a GitHub repository environment exists and optionally configures approvals.
    .DESCRIPTION
        Always PUTs the environment, even when it already exists, and returns the API
        response. RequiredReviewerIds are user IDs; only positive IDs are submitted
        when EnableApprovals is set. Without valid IDs no reviewer body is sent.
        This helper performs remote writes without a ShouldProcess guard.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter()][int[]]$RequiredReviewerIds,
        [Parameter()][switch]$EnableApprovals
    )

    Write-Host "Ensuring GitHub environment '$EnvironmentName'..." -ForegroundColor DarkGray

    $existing = Invoke-GhApi -Endpoint "repos/$Owner/$Repo/environments/$([Uri]::EscapeDataString($EnvironmentName))" -AllowNotFound

    $body = $null
    $appliedApprovals = $false
    if ($EnableApprovals) {
        $reviewers = @()
        foreach ($reviewerId in @($RequiredReviewerIds)) {
            if ($reviewerId -gt 0) {
                $reviewers += @{ type = 'User'; id = $reviewerId }
            }
        }

        if ($reviewers.Count -gt 0) {
            $body = @{ reviewers = $reviewers }
            $appliedApprovals = $true
        }
        else {
            Write-Host "Approvals were requested but no valid reviewer IDs were supplied; configuring environment without required reviewers." -ForegroundColor Yellow
        }
    }

    $action = if ($existing) { 'Updating' } else { 'Creating' }
    Write-Host "$action environment '$EnvironmentName'..." -ForegroundColor Yellow
    if ($body) {
        $updated = Invoke-GhApi -Endpoint "repos/$Owner/$Repo/environments/$([Uri]::EscapeDataString($EnvironmentName))" -Method 'PUT' -Body $body
    }
    else {
        $updated = Invoke-GhApi -Endpoint "repos/$Owner/$Repo/environments/$([Uri]::EscapeDataString($EnvironmentName))" -Method 'PUT'
    }

    if ($appliedApprovals) {
        Write-Host "Configured environment '$EnvironmentName' with required reviewers." -ForegroundColor DarkGray
    }
    else {
        Write-Host "Configured environment '$EnvironmentName'." -ForegroundColor DarkGray
    }

    return $updated
}

function Set-GitHubEnvironmentSecret {
    <#
    .SYNOPSIS
        Sets a secret in a GitHub repository environment using the gh CLI.
    .DESCRIPTION
        Trims trailing CR/LF characters before passing the value through --body.
        Throws on a nonzero CLI exit; emits no success result. ShouldProcess guards
        this individual write, not the surrounding setup wizard.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][string]$SecretName,
        [Parameter(Mandatory)][string]$SecretValue
    )

    if (-not $PSCmdlet.ShouldProcess("$Owner/$Repo/$EnvironmentName", 'Set GitHub environment secret')) { return }

    Write-Host "Setting secret '$SecretName' in environment '$EnvironmentName'..." -ForegroundColor DarkGray

    # Avoid piping to native commands here: PowerShell appends a trailing newline
    # when sending strings over stdin, which would corrupt client secret values.
    $normalizedSecretValue = ($SecretValue -replace "[\r\n]+$", "")

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $result = @(& gh secret set $SecretName `
            --repo "$Owner/$Repo" `
            --env $EnvironmentName `
            --body $normalizedSecretValue 2>&1)
        $setExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($setExitCode -ne 0) {
        throw "Failed to set secret '$SecretName': $($result -join "`n")"
    }
    Write-Host "Set secret '$SecretName'." -ForegroundColor DarkGray
}

function Set-GitHubEnvironmentVariable {
    <#
    .SYNOPSIS
        Sets a variable in a GitHub repository environment using the gh CLI.
    .DESCRIPTION
        Passes VariableValue unchanged through --body and throws on a nonzero CLI
        exit. Emits no success result; declines the write when ShouldProcess is false.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][string]$VariableName,
        [Parameter(Mandatory)][string]$VariableValue
    )

    if (-not $PSCmdlet.ShouldProcess("$Owner/$Repo/$EnvironmentName", 'Set GitHub environment variable')) { return }

    Write-Host "Setting variable '$VariableName' in environment '$EnvironmentName'..." -ForegroundColor DarkGray

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $result = @(& gh variable set $VariableName `
            --repo "$Owner/$Repo" `
            --env $EnvironmentName `
            --body $VariableValue 2>&1)
        $setExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($setExitCode -ne 0) {
        throw "Failed to set variable '$VariableName': $($result -join "`n")"
    }
    Write-Host "Set variable '$VariableName'." -ForegroundColor DarkGray
}

function Set-GitHubRepoSecret {
    <#
    .SYNOPSIS
        Sets a repository-level secret using the gh CLI.
    .DESCRIPTION
        Removes trailing CR/LF characters, matching the environment-secret writer.
        ShouldProcess guards the write; a nonzero CLI exit throws and successful
        execution produces no result object.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$SecretName,
        [Parameter(Mandatory)][string]$SecretValue
    )

    if (-not $PSCmdlet.ShouldProcess("$Owner/$Repo", 'Set GitHub repository secret')) { return }

    Write-Host "Setting repo-level secret '$SecretName'..." -ForegroundColor DarkGray

    # Avoid piping to native commands here: PowerShell appends a trailing newline
    # when sending strings over stdin, which would corrupt client secret values.
    $normalizedSecretValue = ($SecretValue -replace "[\r\n]+$", "")

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $result = @(& gh secret set $SecretName `
            --repo "$Owner/$Repo" `
            --body $normalizedSecretValue 2>&1)
        $setExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($setExitCode -ne 0) {
        throw "Failed to set repo secret '$SecretName': $($result -join "`n")"
    }
    Write-Host "Set repo-level secret '$SecretName'." -ForegroundColor DarkGray
}

function Set-GitHubRepoVariable {
    <#
    .SYNOPSIS
        Sets a repository-level variable using the gh CLI.
    .DESCRIPTION
        Writes VariableValue unchanged after ShouldProcess approval. Native output
        is captured for failure diagnostics; successful execution emits no result.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$VariableName,
        [Parameter(Mandatory)][string]$VariableValue
    )

    if (-not $PSCmdlet.ShouldProcess("$Owner/$Repo", 'Set GitHub repository variable')) { return }

    Write-Host "Setting repo-level variable '$VariableName'..." -ForegroundColor DarkGray

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $result = @(& gh variable set $VariableName `
            --repo "$Owner/$Repo" `
            --body $VariableValue 2>&1)
        $setExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($setExitCode -ne 0) {
        throw "Failed to set repo variable '$VariableName': $($result -join "`n")"
    }
    Write-Host "Set repo-level variable '$VariableName'." -ForegroundColor DarkGray
}

function Get-GitHubEnvironmentCapability {
    <#
    .SYNOPSIS
        Detects whether GitHub environments and environment approval rules are available for a repository.
    .DESCRIPTION
        Creates a uniquely named remote environment and, when a positive reviewer
        ID is supplied, separately attempts a reviewer rule. Returns availability
        flags and a diagnostic Message rather than throwing probe failures.
        Deletion is best-effort, so a failed cleanup can leave the probe behind.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter()][int]$ApprovalReviewerId
    )

    $probeName = "alm4dataverse-setup-probe-$([guid]::NewGuid().ToString('n').Substring(0, 8))"
    $probeEndpoint = "repos/$Owner/$Repo/environments/$([Uri]::EscapeDataString($probeName))"

    $result = [ordered]@{
        EnvironmentsAvailable = $false
        ApprovalsAvailable    = $false
        Message               = ''
    }

    try {
        try {
            # Probe base environment availability without optional protection rules.
            [void](Invoke-GhApi -Endpoint $probeEndpoint -Method 'PUT')
            $result.EnvironmentsAvailable = $true
        }
        catch {
            $result.Message = "GitHub environments are not available for this repository: $($_.Exception.Message)"
        }

        if ($result.EnvironmentsAvailable) {
            if ($ApprovalReviewerId -gt 0) {
                try {
                    # Probe required-reviewer availability separately from base environments support.
                    [void](Invoke-GhApi -Endpoint $probeEndpoint -Method 'PUT' -Body @{ reviewers = @(@{ type = 'User'; id = $ApprovalReviewerId }) })
                    $result.ApprovalsAvailable = $true
                    $result.Message = 'GitHub environments and required reviewers are available.'
                }
                catch {
                    $result.Message = "GitHub environments are available, but required reviewers are not available for this repository: $($_.Exception.Message)"
                }
            }
            else {
                $result.Message = 'GitHub environments are available, but required-reviewer support could not be probed because no reviewer id was provided.'
            }
        }
    }
    finally {
        try {
            [void](Invoke-GhApi -Endpoint $probeEndpoint -Method 'DELETE' -AllowNotFound)
        }
        catch {
            Write-Verbose 'Could not remove the temporary environment probe; continuing cleanup.'
        }
    }

    return [pscustomobject]$result
}

function Get-GitHubEnvironmentPrefix {
    <#
    .SYNOPSIS
        Derives a repository-level prefix from an environment name.
    .DESCRIPTION
        Uppercases and collapses non-alphanumeric runs to underscores, strips edge
        underscores, then appends one underscore. Throws if nothing remains.
        Different environment names can normalize to the same prefix.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$EnvironmentName
    )

    $normalized = ($EnvironmentName.Trim().ToUpperInvariant() -replace '[^A-Z0-9]+', '_').Trim('_')
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        throw "Could not derive a prefix from environment name '$EnvironmentName'."
    }

    return "${normalized}_"
}

function Set-GitHubPrefixedEnvironmentCredential {
    <#
    .SYNOPSIS
        Stores non-sensitive values as repository variables and secrets in the matching environment.
    .DESCRIPTION
        UseEnvironmentPrefix controls repository variable names only. A supplied
        Secret credential is always stored as AZURE_CLIENT_SECRET in a GitHub
        environment, which this helper creates even in repository-variable mode.
        An absent ClientSecret leaves any existing secret untouched.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][object]$Credentials,
        [Parameter(Mandatory)][string]$DataverseUrl,
        [Parameter(Mandatory)][string]$ServiceAccountUPN,
        [Parameter()][bool]$UseEnvironmentPrefix = $true
    )

    if (-not $PSCmdlet.ShouldProcess("$Owner/$Repo/$EnvironmentName", 'Configure GitHub environment credentials')) { return }

    $prefix = if ($UseEnvironmentPrefix) { Get-GitHubEnvironmentPrefix -EnvironmentName $EnvironmentName } else { '' }
    $storageDescription = if ($UseEnvironmentPrefix) { "using prefix '$prefix'" } else { 'without an environment prefix' }
    Write-Host "Setting repo-level credentials for '$EnvironmentName' $storageDescription..." -ForegroundColor DarkGray

    Set-GitHubRepoVariable -Owner $Owner -Repo $Repo -VariableName "${prefix}AZURE_CLIENT_ID" -VariableValue $Credentials.ApplicationId
    Set-GitHubRepoVariable -Owner $Owner -Repo $Repo -VariableName "${prefix}AZURE_TENANT_ID" -VariableValue $Credentials.TenantId

    if ($Credentials.AuthType -eq 'Secret' -and $Credentials.ClientSecret) {
        [void](Initialize-GitHubEnvironment -Owner $Owner -Repo $Repo -EnvironmentName $EnvironmentName)
        Set-GitHubEnvironmentSecret -Owner $Owner -Repo $Repo -EnvironmentName $EnvironmentName `
            -SecretName 'AZURE_CLIENT_SECRET' -SecretValue $Credentials.ClientSecret
    }

    Set-GitHubRepoVariable -Owner $Owner -Repo $Repo -VariableName "${prefix}DATAVERSE_URL" -VariableValue $DataverseUrl
    Set-GitHubRepoVariable -Owner $Owner -Repo $Repo -VariableName "${prefix}DATAVERSE_SERVICE_ACCOUNT_UPN" -VariableValue $ServiceAccountUPN
}
