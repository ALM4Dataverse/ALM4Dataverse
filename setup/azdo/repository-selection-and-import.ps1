function Test-AzDoGitRepositoryCommit {
    # False means no commit was observed, including lookup errors; it is not proof of emptiness.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$RepositoryId
    )

    # Use VSTeam command to get commits - if repo is empty, no commits are returned
    try {
        $commits = @(Get-VSTeamGitCommit -ProjectName $Project -RepositoryId $RepositoryId -Top 1 -ErrorAction SilentlyContinue)
        return ($commits.Count -gt 0)
    }
    catch {
        # If we can't get commits, assume empty repo
        return $false
    }
}

function Start-AzDoGitRepositoryImport {
    <#
    .SYNOPSIS
    Starts an Azure DevOps server-side Git import and returns its request response.
    .NOTES
    Uses the current VSTeam context. Completion is separate: pass the response to
    Wait-AzDoGitRepositoryImport. A declined ShouldProcess returns no response.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$RepositoryId,
        [Parameter(Mandatory)][string]$SourceGitUrl
    )

    # Use Invoke-VSTeamRequest since VSTeam doesn't support repository import directly
    if (-not $PSCmdlet.ShouldProcess($RepositoryId, 'Start repository import')) { return }

    $resource = "git/repositories/$RepositoryId/importRequests"
    $body = @{
        parameters = @{
            gitSource = @{
                url = $SourceGitUrl
            }
        }
    }
    return Invoke-VSTeamRequest -Method POST -Resource $resource -Body ($body | ConvertTo-Json -Depth 10) -ContentType 'application/json' -Version '7.1-preview.1'
}

function Wait-AzDoGitRepositoryImport {
    <#
    .SYNOPSIS
    Polls an import response's request ID until success, failure or the timeout in seconds.
    .OUTPUTS
    System.Object. The successful status response.
    .NOTES
    Accepts alternate request-ID and status field names. Polls every five seconds;
    missing IDs, terminal failure states and elapsed deadlines throw.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryId,
        [Parameter(Mandatory)][object]$ImportResponse,
        [Parameter()][int]$TimeoutSeconds = 600
    )

    $importId = $null
    foreach ($prop in @('importRequestId', 'id', 'ImportRequestId')) {
        if ($ImportResponse.PSObject.Properties.Name -contains $prop) {
            $importId = $ImportResponse.$prop
            if ($importId) { break }
        }
    }

    if (-not $importId) {
        throw "Unable to determine import request ID from response."
    }

    # Use Invoke-VSTeamRequest since VSTeam doesn't support repository import status directly
    $resource = "git/repositories/$RepositoryId/importRequests/$importId"
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5

        $status = Invoke-VSTeamRequest -Method GET -Resource $resource -Version '7.1-preview.1'

        if (-not $status) { continue }

        $state = $null
        foreach ($prop in @('status', 'state')) {
            if ($status.PSObject.Properties.Name -contains $prop) {
                $state = $status.$prop
                if ($state) { break }
            }
        }

        if ($state) {
            Write-Host "Import status: $state" -ForegroundColor DarkGray
        }

        if ($state -in @('completed', 'succeeded', 'success')) {
            return $status
        }
        if ($state -in @('failed', 'rejected', 'canceled', 'cancelled')) {
            $details = $status | ConvertTo-Json -Depth 20
            throw "Repository import did not succeed. Status: $state. Details: $details"
        }
    }

    throw "Timed out waiting for repository import to complete after $TimeoutSeconds seconds."
}

function Get-AzDoSharedRepositorySyncState {
    <#
    .SYNOPSIS
    Clones into WorkRoot and compares HEAD with an upstream ref without changing the remote.
    .OUTPUTS
    System.Management.Automation.PSCustomObject. UpstreamRef, LocalHash, UpstreamHash,
    CanFastForward and IsAhead; both flags are false for equal or divergent histories.
    .NOTES
    WorkRoot must be suitable for git clone. Branch refs resolve to upstream tracking
    refs, tags to the advertised SHA. The caller owns clone cleanup; preference state is restored.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRemoteUrl,
        [Parameter(Mandatory)][string]$WorkRoot,
        [Parameter(Mandatory)][string]$UpstreamGitSource,
        [Parameter(Mandatory)][string]$Reference,
        [Parameter(Mandatory)][string]$AccessToken
    )

    # Git can write progress to stderr on success. Use exit codes for native failures
    # and restore the caller's terminating-error policy after the comparison.
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'

        & git -c "http.extraheader=AUTHORIZATION: bearer $AccessToken" clone $RepositoryRemoteUrl $WorkRoot | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Git clone failed with exit code $LASTEXITCODE"
        }

        & git -C $WorkRoot remote add upstream $UpstreamGitSource | Out-Null
        & git -C $WorkRoot fetch upstream | Out-Null

        & git -C $WorkRoot ls-remote --exit-code upstream $Reference | Out-Null
        if ($LASTEXITCODE -eq 2) {
            throw "Could not resolve reference '$Reference' from upstream repository."
        }
        if ($LASTEXITCODE -ne 0) {
            throw "Git ls-remote failed with exit code $LASTEXITCODE"
        }

        $lsRemoteOutput = (& git -C $WorkRoot ls-remote upstream $Reference | Select-Object -First 1)
        if ($lsRemoteOutput -match '^([a-f0-9]+)\s+(.+)$') {
            $commitSha = $Matches[1]
            $fullRef = $Matches[2]
            if ($fullRef -match '^refs/heads/(.+)$') {
                $targetRef = "upstream/$($Matches[1])"
            }
            elseif ($fullRef -match '^refs/tags/') {
                $targetRef = $commitSha
            }
            else {
                $targetRef = $Reference
            }
        }
        else {
            $targetRef = $Reference
        }

        $localHash = (& git -C $WorkRoot rev-parse HEAD).Trim()
        $upstreamHash = (& git -C $WorkRoot rev-parse $targetRef).Trim()

        $canFastForward = $false
        $isAhead = $false
        if ($localHash -ne $upstreamHash) {
            & git -C $WorkRoot merge-base --is-ancestor HEAD $targetRef
            $canFastForward = ($LASTEXITCODE -eq 0)

            if (-not $canFastForward) {
                & git -C $WorkRoot merge-base --is-ancestor $targetRef HEAD
                $isAhead = ($LASTEXITCODE -eq 0)
            }
        }

        return [pscustomobject]@{
            UpstreamRef    = $targetRef
            LocalHash      = $localHash
            UpstreamHash   = $upstreamHash
            CanFastForward = $canFastForward
            IsAhead        = $isAhead
        }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Initialize-AzDoSharedRepositoryFromUpstream {
    <#
    .SYNOPSIS
    Seeds an empty Azure DevOps shared repository from the configured upstream ref.
    .DESCRIPTION
    Initializes a temporary repository, resolves Reference from UpstreamGitSource,
    pushes the upstream history to the selected repository, and returns after cleanup.
    The caller has already established that the target repository has no commits.
    .PARAMETER RepositoryName
    Display name used in messages and errors.
    .PARAMETER RepositoryRemoteUrl
    Authenticated remote URL of the empty shared repository.
    .PARAMETER UpstreamGitSource
    Git source containing the ALM4Dataverse template ref.
    .PARAMETER Reference
    Branch or tag to seed into the shared repository.
    .PARAMETER AccessToken
    Bearer token used to push to RepositoryRemoteUrl.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'RepositoryRemoteUrl', Justification = 'Used by the nested repository push callback.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'UpstreamGitSource', Justification = 'Used by the nested repository seed callback.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Reference', Justification = 'Used by the nested repository seed callback.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'AccessToken', Justification = 'Used by the nested repository push callback.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryName,
        [Parameter(Mandatory)][string]$RepositoryRemoteUrl,
        [Parameter(Mandatory)][string]$UpstreamGitSource,
        [Parameter(Mandatory)][string]$Reference,
        [Parameter(Mandatory)][string]$AccessToken
    )

    Invoke-WithErrorHandling -OperationName "Initializing Shared Repository" -ScriptBlock {
        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            Write-Host "Repository '$RepositoryName' has no commits. Seeding it from the upstream repo..." -ForegroundColor Yellow

            $workRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ALM4Dataverse-Init-" + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $workRoot -Force | Out-Null

            try {
                Push-Location $workRoot

                & git init --initial-branch=main | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Git init failed with exit code $LASTEXITCODE" }

                & git remote add origin $UpstreamGitSource | Out-Null
                & git fetch origin | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Git fetch failed with exit code $LASTEXITCODE" }

                & git ls-remote --exit-code origin $Reference | Out-Null
                if ($LASTEXITCODE -eq 2) {
                    throw "Could not resolve reference '$Reference' from upstream repository."
                }
                if ($LASTEXITCODE -ne 0) {
                    throw "Git ls-remote failed with exit code $LASTEXITCODE"
                }

                $lsRemoteOutput = (& git ls-remote origin $Reference | Select-Object -First 1)
                if ($lsRemoteOutput -match '^([a-f0-9]+)\s+(.+)$') {
                    $commitSha = $Matches[1]
                    $fullRef = $Matches[2]
                    if ($fullRef -match '^refs/heads/(.+)$') {
                        $targetRef = "origin/$($Matches[1])"
                    }
                    elseif ($fullRef -match '^refs/tags/') {
                        $targetRef = $commitSha
                    }
                    else {
                        $targetRef = $Reference
                    }
                }
                else {
                    $targetRef = $Reference
                }

                & git checkout -b main $targetRef | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Git checkout failed with exit code $LASTEXITCODE" }

                & git remote set-url origin $RepositoryRemoteUrl | Out-Null
                & git -c "http.extraheader=AUTHORIZATION: bearer $AccessToken" push -u origin main
                if ($LASTEXITCODE -ne 0) { throw "Git push failed with exit code $LASTEXITCODE" }

                Write-Host "Shared repository initialized successfully."
            }
            finally {
                if ((Get-Location).Path -eq $workRoot) { Pop-Location }
                try { Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction Stop } catch { Write-Verbose 'Could not remove the temporary repository; continuing cleanup.' }
            }
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
    } -StatusMessage "Initializing shared repository '$RepositoryName'..." -CaptureOutputInPanel
}

function Get-AzDoSharedRepositoryUpdateState {
    <#
    .SYNOPSIS
    Checks the shared repository against the configured upstream ref without changing history.
    .DESCRIPTION
    An empty repository is reported as needing a seed. Otherwise the shared repository is
    cloned into a temporary work tree and compared with Reference to report up-to-date,
    fast-forward, ahead or diverged state. The temporary clone is removed before returning.
    ContinueOnError records a failed comparison as UpdateKind Error instead of throwing.
    .PARAMETER ProjectName
    Project containing the shared repository.
    .PARAMETER RepositoryId
    Identifier used to detect an empty repository.
    .PARAMETER RepositoryName
    Display name used in status text.
    .PARAMETER RepositoryRemoteUrl
    Authenticated remote URL of the shared repository.
    .PARAMETER UpstreamGitSource
    Git source containing the ALM4Dataverse template ref.
    .PARAMETER Reference
    Branch or tag to compare with.
    .PARAMETER AccessToken
    Bearer token used to clone the shared repository.
    .PARAMETER ContinueOnError
    Returns an Error result instead of throwing when the comparison fails.
    .OUTPUTS
    System.Management.Automation.PSCustomObject. UpdateKind, UpdateStatus, PendingUpdate,
    CanFastForward, IsAhead, MatchesCanonicalUpstreamDefault and Changed.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'RepositoryRemoteUrl', Justification = 'Used by the nested repository check callback.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'UpstreamGitSource', Justification = 'Used by the nested repository check callback.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'AccessToken', Justification = 'Used by the nested repository check callback.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$RepositoryId,
        [Parameter(Mandatory)][string]$RepositoryName,
        [Parameter(Mandatory)][string]$RepositoryRemoteUrl,
        [Parameter(Mandatory)][string]$UpstreamGitSource,
        [Parameter(Mandatory)][string]$Reference,
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter()][switch]$ContinueOnError
    )

    try {
        $hasCommits = Test-AzDoGitRepositoryCommit -Project $ProjectName -RepositoryId $RepositoryId
        if (-not $hasCommits) {
            return [pscustomobject]@{
                UpdateKind                      = 'Seed'
                UpdateStatus                    = "Seed from '$Reference' is required."
                PendingUpdate                   = $true
                CanFastForward                  = $false
                IsAhead                         = $false
                MatchesCanonicalUpstreamDefault = $false
                Changed                         = $false
            }
        }

        $workRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ALM4Dataverse-Check-" + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
        try {
            $syncState = Invoke-WithSpectreStatus -Status "Checking shared repository '$RepositoryName' against upstream..." -ScriptBlock {
                Get-AzDoSharedRepositorySyncState `
                    -RepositoryRemoteUrl $RepositoryRemoteUrl `
                    -WorkRoot $workRoot `
                    -UpstreamGitSource $UpstreamGitSource `
                    -Reference $Reference `
                    -AccessToken $AccessToken
            }
            return ConvertTo-AzDoSharedRepositoryUpdateState -SyncState $syncState -Reference $Reference
        }
        finally {
            if ((Get-Location).Path -eq $workRoot) { Pop-Location }
            try { Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction Stop } catch { Write-Verbose 'Could not remove the temporary repository; continuing cleanup.' }
        }
    }
    catch {
        if (-not $ContinueOnError) {
            throw
        }

        $message = ([string]$_.Exception.Message -replace '\s+', ' ').Trim()
        return [pscustomobject]@{
            UpdateKind                      = 'Error'
            UpdateStatus                    = "Check failed: $message"
            PendingUpdate                   = $false
            CanFastForward                  = $false
            IsAhead                         = $false
            MatchesCanonicalUpstreamDefault = $false
            Changed                         = $false
        }
    }
}

function ConvertTo-AzDoSharedRepositoryUpdateState {
    <#
    .SYNOPSIS
    Maps an Azure DevOps shared repository comparison to an update kind and status.
    .PARAMETER SyncState
    Result from Get-AzDoSharedRepositorySyncState.
    .PARAMETER Reference
    Upstream ref used in status text.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$SyncState,
        [Parameter(Mandatory)][string]$Reference
    )

    if ([string]$SyncState.LocalHash -eq [string]$SyncState.UpstreamHash) {
        return [pscustomobject]@{
            UpdateKind                      = 'UpToDate'
            UpdateStatus                    = "Already up to date with '$Reference'."
            PendingUpdate                   = $false
            CanFastForward                  = $false
            IsAhead                         = $false
            MatchesCanonicalUpstreamDefault = $false
            Changed                         = $false
        }
    }
    if ([bool]$SyncState.CanFastForward) {
        return [pscustomobject]@{
            UpdateKind                      = 'FastForward'
            UpdateStatus                    = "Fast-forward from '$Reference' is available."
            PendingUpdate                   = $true
            CanFastForward                  = $true
            IsAhead                         = $false
            MatchesCanonicalUpstreamDefault = $false
            Changed                         = $false
        }
    }
    if ([bool]$SyncState.IsAhead) {
        return [pscustomobject]@{
            UpdateKind                      = 'Ahead'
            UpdateStatus                    = "Ahead of '$Reference'; no update is required."
            PendingUpdate                   = $false
            CanFastForward                  = $false
            IsAhead                         = $true
            MatchesCanonicalUpstreamDefault = $false
            Changed                         = $false
        }
    }
    return [pscustomobject]@{
        UpdateKind                      = 'Diverged'
        UpdateStatus                    = "Diverged from '$Reference'; define an update strategy."
        PendingUpdate                   = $true
        CanFastForward                  = $false
        IsAhead                         = $false
        MatchesCanonicalUpstreamDefault = $false
        Changed                         = $false
    }
}

function Invoke-AzDoSharedRepositorySync {
    <#
    .SYNOPSIS
    Checks the shared repository against upstream and reconciles it using a selected strategy.
    .DESCRIPTION
    An empty repository is seeded from Reference. A non-empty repository is cloned and
    compared; FastForward, Rebase, Reset and LeaveUnchanged update the remote without
    prompts. PromptForStrategy reproduces the interactive flow used by direct
    Initialize-AzDoProjectAndRepository callers. Temporary clones are removed before returning.
    .PARAMETER ProjectName
    Project containing the shared repository.
    .PARAMETER RepositoryId
    Identifier used to detect an empty repository.
    .PARAMETER RepositoryName
    Display name used in messages and errors.
    .PARAMETER RepositoryRemoteUrl
    Authenticated remote URL of the shared repository.
    .PARAMETER UpstreamGitSource
    Git source containing the ALM4Dataverse template ref.
    .PARAMETER Reference
    Branch or tag to reconcile to.
    .PARAMETER AccessToken
    Bearer token used to clone and push the shared repository.
    .PARAMETER UpdateStrategy
    Seed, FastForward, Rebase, Reset, None or LeaveUnchanged.
    .PARAMETER PromptForStrategy
    Uses the interactive confirmation and divergence menus instead of UpdateStrategy.
    .OUTPUTS
    System.Management.Automation.PSCustomObject. UpdateKind, UpdateStatus, PendingUpdate,
    CanFastForward, IsAhead, MatchesCanonicalUpstreamDefault and Changed.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$RepositoryId,
        [Parameter(Mandatory)][string]$RepositoryName,
        [Parameter(Mandatory)][string]$RepositoryRemoteUrl,
        [Parameter(Mandatory)][string]$UpstreamGitSource,
        [Parameter(Mandatory)][string]$Reference,
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter()][ValidateSet('', 'None', 'Seed', 'FastForward', 'Rebase', 'Reset', 'LeaveUnchanged')][string]$UpdateStrategy = '',
        [Parameter()][switch]$PromptForStrategy
    )

    try {
        $hasCommits = Test-AzDoGitRepositoryCommit -Project $ProjectName -RepositoryId $RepositoryId
        if (-not $hasCommits) {
            $result = [pscustomobject]@{
                UpdateKind                      = 'Seed'
                UpdateStatus                    = "Seed from '$Reference' is required."
                PendingUpdate                   = $true
                CanFastForward                  = $false
                IsAhead                         = $false
                MatchesCanonicalUpstreamDefault = $false
                Changed                         = $false
            }
            $effectiveStrategy = if ($PromptForStrategy) { 'Seed' } else { $UpdateStrategy }
            if ([string]::IsNullOrWhiteSpace($effectiveStrategy) -or $effectiveStrategy -in @('None', 'LeaveUnchanged')) {
                return $result
            }
            if ($effectiveStrategy -ne 'Seed') {
                throw "Shared repository '$RepositoryName' is empty; choose Seed from '$Reference'."
            }

            [void](Initialize-AzDoSharedRepositoryFromUpstream `
                -RepositoryName $RepositoryName `
                -RepositoryRemoteUrl $RepositoryRemoteUrl `
                -UpstreamGitSource $UpstreamGitSource `
                -Reference $Reference `
                -AccessToken $AccessToken)
            $result.UpdateStatus = "Seeded from '$Reference'."
            $result.PendingUpdate = $false
            $result.Changed = $true
            return $result
        }

        $workRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ALM4Dataverse-Check-" + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
        try {
            $syncState = Invoke-WithSpectreStatus -Status "Checking shared repository '$RepositoryName' against upstream..." -ScriptBlock {
                Get-AzDoSharedRepositorySyncState `
                    -RepositoryRemoteUrl $RepositoryRemoteUrl `
                    -WorkRoot $workRoot `
                    -UpstreamGitSource $UpstreamGitSource `
                    -Reference $Reference `
                    -AccessToken $AccessToken
            }
            $result = ConvertTo-AzDoSharedRepositoryUpdateState -SyncState $syncState -Reference $Reference

            $effectiveStrategy = $UpdateStrategy
            if ($PromptForStrategy) {
                switch ($result.UpdateKind) {
                    'UpToDate' {
                        Write-Host "Shared repository is already up to date."
                        $effectiveStrategy = 'None'
                    }
                    'Ahead' {
                        Write-Host "Shared repository is ahead of the shared repo."
                        $effectiveStrategy = 'None'
                    }
                    'FastForward' {
                        $effectiveStrategy = if (Read-YesNo -Prompt "Updates are available from the shared repo (fast-forward). Update '$RepositoryName'?" ) {
                            'FastForward'
                        }
                        else {
                            'LeaveUnchanged'
                        }
                    }
                    'Diverged' {
                        $divergedMenuItems = @(
                            "Rebase '$RepositoryName' onto ref '$Reference'",
                            "Reset '$RepositoryName' to ref '$Reference' (force push)",
                            "Leave '$RepositoryName' unchanged"
                        )
                        $divergedSelection = Select-FromMenu `
                            -Title "The shared repo '$RepositoryName' has diverged. Choose how to update it." `
                            -Items $divergedMenuItems `
                            -PromptGuidanceLines @(
                                "Choose how to reconcile '$RepositoryName' with upstream ALM4Dataverse template history.",
                                'Rebase preserves local commits, reset force-aligns to upstream, and leave unchanged keeps current state.'
                            ) `
                            -PromptGuidanceDocRelativePath 'docs/setup/azdo-automated-setup.md' `
                            -PromptGuidanceRef $ALM4DataverseRef

                        $effectiveStrategy = switch ($divergedSelection) {
                            0 { 'Rebase' }
                            1 { 'Reset' }
                            default { 'LeaveUnchanged' }
                        }
                    }
                }
            }

            if ([string]::IsNullOrWhiteSpace($effectiveStrategy)) {
                if ($result.PendingUpdate) {
                    throw "No update strategy was selected for shared repository '$RepositoryName'."
                }
                $effectiveStrategy = 'None'
            }

            if ($effectiveStrategy -in @('None', 'LeaveUnchanged')) {
                if ($result.PendingUpdate) {
                    Write-Host "Leaving shared repository unchanged." -ForegroundColor Yellow
                }
                return $result
            }

            switch ($effectiveStrategy) {
                'FastForward' {
                    if ($result.UpdateKind -in @('UpToDate', 'Ahead')) {
                        return $result
                    }
                    if ($result.UpdateKind -ne 'FastForward') {
                        throw "Fast-forward is no longer available for shared repository '$RepositoryName'. Reopen setup and choose an update strategy again."
                    }

                    Invoke-WithErrorHandling -OperationName "Fast-forwarding shared repository '$RepositoryName'" -StatusMessage "Fast-forwarding shared repository '$RepositoryName'..." -CaptureOutputInPanel -ScriptBlock {
                        $previousErrorActionPreference = $ErrorActionPreference
                        try {
                            $ErrorActionPreference = 'Continue'

                            & git -C $workRoot merge --ff-only $syncState.UpstreamRef
                            if ($LASTEXITCODE -ne 0) { throw 'Git merge failed' }

                            & git -C $workRoot -c "http.extraheader=AUTHORIZATION: bearer $AccessToken" push origin
                            if ($LASTEXITCODE -ne 0) { throw 'Git push failed' }
                        }
                        finally {
                            $ErrorActionPreference = $previousErrorActionPreference
                        }
                    } | Out-Null
                }
                'Rebase' {
                    if ($result.UpdateKind -eq 'UpToDate') {
                        return $result
                    }
                    if ($result.UpdateKind -ne 'Diverged') {
                        throw "Rebase is not available for shared repository '$RepositoryName'. Reopen setup and choose an update strategy again."
                    }

                    Invoke-WithErrorHandling -OperationName "Rebasing shared repository '$RepositoryName'" -StatusMessage "Rebasing shared repository '$RepositoryName'..." -CaptureOutputInPanel -ScriptBlock {
                        $previousErrorActionPreference = $ErrorActionPreference
                        try {
                            $ErrorActionPreference = 'Continue'

                            & git -C $workRoot rebase $syncState.UpstreamRef
                            if ($LASTEXITCODE -ne 0) { throw "Git rebase failed - this script can't handle conflicts. You need to rebase your local changes manually." }

                            & git -C $workRoot -c "http.extraheader=AUTHORIZATION: bearer $AccessToken" push --force-with-lease origin
                            if ($LASTEXITCODE -ne 0) { throw 'Git push failed' }
                        }
                        finally {
                            $ErrorActionPreference = $previousErrorActionPreference
                        }
                    } | Out-Null
                }
                'Reset' {
                    if ($result.UpdateKind -eq 'UpToDate') {
                        return $result
                    }

                    Invoke-WithErrorHandling -OperationName "Resetting shared repository '$RepositoryName'" -StatusMessage "Resetting shared repository '$RepositoryName' to '$Reference'..." -CaptureOutputInPanel -ScriptBlock {
                        $previousErrorActionPreference = $ErrorActionPreference
                        try {
                            $ErrorActionPreference = 'Continue'

                            & git -C $workRoot reset --hard $syncState.UpstreamRef
                            if ($LASTEXITCODE -ne 0) { throw 'Git reset failed' }

                            & git -C $workRoot -c "http.extraheader=AUTHORIZATION: bearer $AccessToken" push --force-with-lease origin
                            if ($LASTEXITCODE -ne 0) { throw 'Git push failed' }
                        }
                        finally {
                            $ErrorActionPreference = $previousErrorActionPreference
                        }
                    } | Out-Null
                }
                default {
                    throw "Unsupported update strategy '$effectiveStrategy' for shared repository '$RepositoryName'."
                }
            }

            Write-Host "Repository updated successfully."
            $result.UpdateStatus = "Updated to '$Reference'."
            $result.PendingUpdate = $false
            $result.Changed = $true
            return $result
        }
        finally {
            if ((Get-Location).Path -eq $workRoot) { Pop-Location }
            try { Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction Stop } catch { Write-Verbose 'Could not remove the temporary repository; continuing cleanup.' }
        }
    }
    catch {
        Write-Host "Failed to check or update repository: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

function Get-AzDoSharedRepositoryUpdateSummary {
    <#
    .SYNOPSIS
    Formats the Azure DevOps shared repository update state for the guided setup menu.
    .DESCRIPTION
    Distinguishes a required strategy, a completed update and a comparison with no
    action required. Errors are returned verbatim so the user can see why it failed.
    .PARAMETER RepositoryState
    State recorded after an Azure DevOps shared repository check or update.
    .PARAMETER Reference
    Upstream ref used in strategy descriptions.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$RepositoryState,
        [Parameter(Mandatory)][string]$Reference
    )

    $updateKind = [string](Get-OptionalObjectPropertyValue -InputObject $RepositoryState -PropertyName 'UpdateKind')
    $updateStatus = [string](Get-OptionalObjectPropertyValue -InputObject $RepositoryState -PropertyName 'UpdateStatus')
    $pendingUpdate = [bool](Get-OptionalObjectPropertyValue -InputObject $RepositoryState -PropertyName 'PendingUpdate')
    $updateStrategy = [string](Get-OptionalObjectPropertyValue -InputObject $RepositoryState -PropertyName 'UpdateStrategy')

    if ($updateKind -eq 'Error') {
        return $updateStatus
    }

    if ([bool](Get-OptionalObjectPropertyValue -InputObject $RepositoryState -PropertyName 'VersionUpdatedDuringSetup')) {
        return $updateStatus
    }

    switch ($updateStrategy) {
        'FastForward' { return "Fast-forward to '$Reference' during setup" }
        'Rebase' { return "Rebase onto '$Reference' during setup" }
        'Reset' { return "Reset to '$Reference' during setup" }
        'Seed' { return "Seed from '$Reference' during setup" }
        'LeaveUnchanged' { return 'Leave unchanged (no repository update)' }
        'None' { return "No action needed. $updateStatus" }
    }

    if ($pendingUpdate) {
        if ([string]::IsNullOrWhiteSpace($updateStatus)) {
            return "Update strategy required against '$Reference'"
        }
        return "Update strategy required. $updateStatus"
    }

    if ([string]::IsNullOrWhiteSpace($updateStatus)) {
        return "Check against '$Reference'"
    }
    return "No action needed. $updateStatus"
}

function Initialize-AzDoProjectAndRepository {
    <#
    .SYNOPSIS
    Selects project/repositories, prepares the main clone and optionally reconciles shared template history.
    .OUTPUTS
    System.Management.Automation.PSCustomObject. SelectedProject, MainRepo, MainRepoWorkingTree,
    MainRepoWorkingRoot, AzDevOpsAccessToken, SharedRepo, SharedRepoName and
    SharedRepositorySelectionError; null on project cancellation.
    .PARAMETER SharedRepositoryOnly
    Reuses supplied project and application-repository context for shared-repository operations;
    cannot be combined with ApplyConfig.
    .PARAMETER SkipSharedRepositoryVersionUpdate
    Selects the shared repository without checking or changing its version.
    .PARAMETER DeferSharedRepositorySelection
    Checks the configured shared repository without prompting and returns an unavailable
    reason for the guided menu when it cannot be selected. Requires ExistingSetupMode and
    SkipSharedRepositoryVersionUpdate.
    .PARAMETER UsePreferredSharedRepository
    Uses the preferred shared repository without prompting; requires SharedRepositoryOnly and
    fails if that repository is no longer accessible.
    .NOTES
    Depends on authenticated script context. Sets branch, DEV-name and extension-mode
    script state, may install extensions and push shared-repository history. Rebase/reset
    require an explicit menu choice; main-clone cleanup belongs to the outer setup flow.
    ExistingSetupMode restricts project and application-repository selection to existing
    resources. SharedRepositoryOnly reuses the selected project and application repository.
    The shared-repository selection and version-update operations can be run separately.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][switch]$ApplyConfig,
        [Parameter()][switch]$ExistingSetupMode,
        [Parameter()][switch]$SharedRepositoryOnly,
        [Parameter()][switch]$SkipSharedRepositoryVersionUpdate,
        [Parameter()][switch]$DeferSharedRepositorySelection,
        [Parameter()][switch]$UsePreferredSharedRepository,
        [Parameter()][object]$SelectedProjectForSharedRepository,
        [Parameter()][object]$MainRepoForSharedRepository,
        [Parameter()][object]$MainRepoWorkingTreeForSharedRepository,
        [Parameter()][string]$MainRepoWorkingRootForSharedRepository,
        [Parameter()][string]$AccessTokenForSharedRepository,
        [Parameter()][string]$PreferredSharedRepositoryName,
        [Parameter()][string]$PreferredSharedRepositoryRef,
        [Parameter()][string]$ProjectName,
        [Parameter()][string]$RepositoryName
    )

    if (
        $DeferSharedRepositorySelection -and
        (-not $ExistingSetupMode -or $ApplyConfig -or $SharedRepositoryOnly -or -not $SkipSharedRepositoryVersionUpdate)
    ) {
        throw 'DeferSharedRepositorySelection requires existing-repository setup with shared-repository version updates skipped.'
    }

    if ($SharedRepositoryOnly) {
        if ($ApplyConfig) {
            throw 'SharedRepositoryOnly cannot be used with ApplyConfig.'
        }
        if ($UsePreferredSharedRepository -and [string]::IsNullOrWhiteSpace($PreferredSharedRepositoryName)) {
            throw 'UsePreferredSharedRepository requires PreferredSharedRepositoryName.'
        }
        if (
            $null -eq $SelectedProjectForSharedRepository -or
            $null -eq $MainRepoForSharedRepository -or
            $null -eq $MainRepoWorkingTreeForSharedRepository -or
            [string]::IsNullOrWhiteSpace($MainRepoWorkingRootForSharedRepository) -or
            [string]::IsNullOrWhiteSpace($AccessTokenForSharedRepository)
        ) {
            throw 'SharedRepositoryOnly requires the selected project, application repository, working tree, and access token.'
        }

        $selectedProject = $SelectedProjectForSharedRepository
        $mainRepo = $MainRepoForSharedRepository
        $mainRepoWorkingTree = $MainRepoWorkingTreeForSharedRepository
        $mainRepoWorkingRoot = $MainRepoWorkingRootForSharedRepository
        $azDevOpsAccessToken = $AccessTokenForSharedRepository
        $applyConfiguration = $null
    }
    else {
    if ($UsePreferredSharedRepository) {
        throw 'UsePreferredSharedRepository can only be used with SharedRepositoryOnly.'
    }

    Write-Section `
        -Message "Select target Azure DevOps Project"

    $azDevOpsAccessToken = $adoAccessToken.Token

    $projects = @(Invoke-WithSpectreStatus -Status 'Retrieving Azure DevOps projects...' -ScriptBlock {
        Get-VSTeamProject
    })
    $projectNames = @()
    if ($projects) {
        $projectNames = @($projects | ForEach-Object { $_.Name })
    }

    $existingResourcesOnly = $ApplyConfig -or $ExistingSetupMode
    if ($existingResourcesOnly -and $projectNames.Count -eq 0) {
        if ($ApplyConfig) {
            throw 'ApplyConfig requires an existing Azure DevOps project containing the application repository.'
        }
        throw 'Existing-repository setup requires an existing Azure DevOps project containing the application repository.'
    }

    $menuItems = if ($existingResourcesOnly) { $projectNames } else { $projectNames + @('Create a new project') }
    $index = $null
    if (-not [string]::IsNullOrWhiteSpace($ProjectName)) {
        # Headless project selection: the caller supplies the project so the guided
        # setup menu is skipped.
        $matchingProjectIndexes = @(0..($projectNames.Count - 1) | Where-Object { $projectNames[$_] -ieq $ProjectName })
        if ($matchingProjectIndexes.Count -eq 0) {
            throw "Project '$ProjectName' is not accessible with the authenticated account or does not exist."
        }
        $index = $matchingProjectIndexes | Select-Object -First 1
    }
    else {
        $index = Select-FromMenu `
            -Title "Select the target Azure DevOps project" `
            -Items $menuItems `
            -PromptGuidanceLines @(
                'Choose the long-lived project that will host repositories, pipelines, service connections, and approvals.',
                'Avoid phase-specific project names so the setup can grow with the team.',
                'Use Create a new project only when no existing project should own this ALM setup.'
            ) `
            -PromptGuidanceDocRelativePath 'docs/setup/azdo-automated-setup.md' `
            -PromptGuidanceRef $ALM4DataverseRef
    }

    if ($null -eq $index) {
        Write-Host "No project selected." -ForegroundColor Yellow
        return $null
    }

    function Get-AzDoSharedRepositoryRefFromWorkingTree {
        <#
        .SYNOPSIS
        Reads the shared repository ref from setup config.
        .DESCRIPTION
        Missing configuration uses the shared repository's conventional main branch.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Branch', Justification = 'Retained for existing callers; shared repository configuration is not branch-specific.')]
        [CmdletBinding()]
        [OutputType([string])]
        param(
            [Parameter(Mandatory)][string]$RepoRoot,
            [Parameter(Mandatory)][string]$Branch
        )

        $configPath = Join-Path $RepoRoot 'alm-config.psd1'
        if (Test-Path -LiteralPath $configPath -PathType Leaf) {
            $config = ConvertFrom-AlmConfigContentForSetup -ConfigContent ([System.IO.File]::ReadAllText($configPath))
            if (
                [string](Get-OptionalObjectPropertyValue -InputObject $config -PropertyName 'provider') -ieq 'azDO' -and
                $config.Contains('ref') -and
                -not [string]::IsNullOrWhiteSpace([string]$config.ref)
            ) {
                return [string]$config.ref
            }
        }

        return 'main'
    }

    $createProjectSelected = -not $ApplyConfig -and -not $ExistingSetupMode -and $index -eq ($menuItems.Count - 1)
    if ($createProjectSelected) {
        $name = Read-TextWithDefault -Prompt 'Enter the name for the new Azure DevOps project'

        $created = New-AzDoProject -Organization $orgName -ProjectName $name -Visibility private

        $projects = @(Invoke-WithSpectreStatus -Status 'Refreshing Azure DevOps projects...' -ScriptBlock {
            Get-VSTeamProject
        })
        $selectedProject = $null

        if ($projects) {
            $selectedProject = $projects | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        }
        if (-not $selectedProject -and $created -and $created.name) {
            $selectedProject = [pscustomobject]@{ Name = $created.name; Id = $created.id }
        }
        if (-not $selectedProject) {
            throw "Project creation completed, but the project could not be resolved for selection."
        }

        Write-Host "Created and selected project: $($selectedProject.Name)"
    }
    else {
        $selectedProject = $projects[$index]
        Write-Host "Selected project: $($selectedProject.Name)"
    }

    if (-not $ApplyConfig -and (Get-Command -Name Set-VSTeamDefaultProject -ErrorAction SilentlyContinue)) {
        Set-VSTeamDefaultProject -Project $selectedProject.Name | Out-Null
        Write-Host "Default VSTeam project set to '$($selectedProject.Name)'."
    }

    $mainRepo = Select-AzDoMainRepository `
        -ProjectName $selectedProject.Name `
        -ExistingOnly:$existingResourcesOnly `
        -ApplyConfig:$ApplyConfig `
        -RepositoryName $RepositoryName

    # An empty existing repository follows the new-repository flow: scaffold callers
    # and choose the shared repository now instead of expecting alm-config.psd1.
    if (-not $ApplyConfig -and [bool](Get-OptionalObjectPropertyValue -InputObject $mainRepo -PropertyName 'IsNewRepository')) {
        $DeferSharedRepositorySelection = $false
    }

    $script:mainRepoBranch = 'main'
    if ($mainRepo.defaultBranch) {
        $script:mainRepoBranch = ConvertFrom-GitRefToBranchName -Ref $mainRepo.defaultBranch
    }

    $script:devEnvironmentShortName = "Dev-$script:mainRepoBranch"

    $mainRepoWorkingTree = New-AzDoRepoWorkingTree -TargetRepo $mainRepo -AccessToken $azDevOpsAccessToken -PreferredBranch 'main'
    $mainRepoWorkingRoot = $mainRepoWorkingTree.Path

    $applyConfiguration = $null
    if ($ApplyConfig) {
        $applyConfiguration = Get-AlmConfigForSetup -ConfigPath (Join-Path $mainRepoWorkingRoot 'alm-config.psd1')
        [void](Assert-AlmSetupConfigurationForApply -Configuration $applyConfiguration -Provider azDO)
    }

    if ($ApplyConfig) {
        $script:useAlm4DataverseExtension = if ($applyConfiguration.Contains('azDOUseAlm4DataverseExtension')) {
            if ($applyConfiguration.azDOUseAlm4DataverseExtension -isnot [bool]) {
                throw 'azDOUseAlm4DataverseExtension in alm-config.psd1 must be a Boolean.'
            }
            [bool]$applyConfiguration.azDOUseAlm4DataverseExtension
        }
        else {
            $true
        }
    }
    else {
        Write-Section `
            -Message "Ensuring Needed Extensions are Enabled"

        $existingExtensionMode = Get-AzDoExtensionModeFromWorkingTree -RepoRoot $mainRepoWorkingRoot -Branch $script:mainRepoBranch
        if ($existingExtensionMode.IsConfigured -and -not $existingExtensionMode.HasConflict) {
            $script:useAlm4DataverseExtension = $existingExtensionMode.UseAlm4DataverseExtension
            Write-Host "Detected existing ALM4Dataverse extension mode in alm-config.psd1: $($script:useAlm4DataverseExtension)" -ForegroundColor Cyan
        }
        else {
            $script:useAlm4DataverseExtension = Read-YesNo `
                -Prompt "Use ALM4Dataverse AzDO extension? (required for Workload Identity Federation)" `
                -PromptGuidanceLines @(
                    'The extension enables Workload Identity Federation and the ALM4Dataverse Set Connection Variables task.',
                    'Disable it only to use the Power Platform Build Tools secret-based fallback path.'
                ) `
                -PromptGuidanceDocRelativePath 'docs/config/azdo-environment-service-connection.md' `
                -PromptGuidanceRef $ALM4DataverseRef
        }
    }

    if (-not $script:useAlm4DataverseExtension) {
        Write-Host "ALM4Dataverse extension mode disabled. Setup will use the PPBT Set Connection Variables task for service-connection-based client secret auth." -ForegroundColor Yellow
    }

    if (-not $ApplyConfig) {
        $requiredExtensions = @(
            "microsoft-IsvExpTools.PowerPlatform-BuildTools"
        )

        if ($script:useAlm4DataverseExtension) {
            $requiredExtensions += "ALM4Dataverse.alm4dataverse-azdo-extensions"
        }

        foreach ($requiredExtension in $requiredExtensions) {
            $parts = $requiredExtension -split '\.'
            $publisherId = $parts[0]
            $extensionId = $parts[1..($parts.Length - 1)] -join '.'

            Invoke-WithErrorHandling -OperationName "Installing extension '$requiredExtension'" -ScriptBlock {
                $installedExtensions = Get-VSTeamExtension
                $installed = $installedExtensions | Where-Object { $_.publisherId -eq $publisherId -and $_.extensionId -eq $extensionId }

                if ($installed) {
                    Write-Host "Extension '$requiredExtension' is already installed (Version: $($installed.version))."
                }
                else {
                    if (-not (Read-YesNo -Prompt "Extension '$requiredExtension' not found. Install it?")) {
                        throw "Extension '$requiredExtension' is required. Setup cannot continue without it."
                    }
                    Write-Host "Extension '$requiredExtension' not found. Installing..." -ForegroundColor Yellow
                    Write-Host "This may require organization administrative permissions." -ForegroundColor Yellow

                    Add-VSTeamExtension -PublisherId $publisherId -ExtensionId $extensionId

                    $installedExtensions = Get-VSTeamExtension
                    $installed = $installedExtensions | Where-Object { $_.publisherId -eq $publisherId -and $_.extensionId -eq $extensionId }

                    if ($installed) {
                        Write-Host "Extension '$requiredExtension' installed successfully (Version: $($installed.version))."
                    }
                    else {
                        Write-Host "Please install the extension manually from:" -ForegroundColor Yellow
                        Write-Host "https://marketplace.visualstudio.com/acquisition?itemName=$requiredExtension" -ForegroundColor Yellow
                        throw "Failed to verify extension '$requiredExtension' installation after install command completed."
                    }
                }
            } | Out-Null
        }
    }

    }

    $sharedRepositorySelectionError = ''
    $existingSharedRepoName = if ($SharedRepositoryOnly) {
        $PreferredSharedRepositoryName
    }
    elseif ($ApplyConfig) {
        [string]$applyConfiguration.repository
    }
    else {
        Get-AzDoSharedRepositoryNameFromWorkingTree -RepoRoot $mainRepoWorkingRoot -Branch $script:mainRepoBranch
    }
    if (-not [string]::IsNullOrWhiteSpace($existingSharedRepoName)) {
        Write-Host "Existing shared repository detected from alm-config.psd1: $existingSharedRepoName" -ForegroundColor DarkGray
    }

    Write-Section `
        -Message "Selecting shared Git repository"

    if ($ApplyConfig) {
        $repo = @(Get-VSTeamGitRepository -ProjectName $selectedProject.Name) |
            Where-Object { $_.Name -ieq $existingSharedRepoName } |
            Select-Object -First 1
        if (-not $repo -or -not $repo.Id) {
            throw "The shared repository '$existingSharedRepoName' configured in alm-config.psd1 was not found in project '$($selectedProject.Name)'."
        }
    }
    elseif ($DeferSharedRepositorySelection) {
        if ([string]::IsNullOrWhiteSpace($existingSharedRepoName)) {
            $repo = $null
            $sharedRepositorySelectionError = 'No shared repository is configured in alm-config.psd1.'
        }
        else {
            try {
                $repo = Select-AzDoSharedRepository `
                    -ProjectName $selectedProject.Name `
                    -PreferredRepositoryName $existingSharedRepoName `
                    -ExcludeRepositoryName $mainRepo.Name `
                    -ValidatePreferredOnly
            }
            catch {
                if (Test-IsUserInterruptException -Exception $_.Exception) {
                    throw
                }

                $lookupError = ([string]$_.Exception.Message -replace '\s+', ' ').Trim()
                $sharedRepositorySelectionError = "Could not verify configured shared repository '$existingSharedRepoName' in project '$($selectedProject.Name)': $lookupError"
                $repo = $null
            }
            if (-not $repo) {
                if ([string]::IsNullOrWhiteSpace($sharedRepositorySelectionError)) {
                    $sharedRepositorySelectionError = "Configured shared repository '$existingSharedRepoName' was not found or accessible in project '$($selectedProject.Name)'."
                }
            }
        }
    }
    else {
        $usePreferredIfAvailable = -not $SharedRepositoryOnly -or $UsePreferredSharedRepository
        $repo = Select-AzDoSharedRepository `
            -ProjectName $selectedProject.Name `
            -PreferredRepositoryName $existingSharedRepoName `
            -ExcludeRepositoryName $mainRepo.Name `
            -UsePreferredIfAvailable:$usePreferredIfAvailable `
            -RequirePreferred:$UsePreferredSharedRepository
    }
    $sharedRepoName = [string](Get-OptionalObjectPropertyValue -InputObject $repo -PropertyName 'Name')
    $sharedRepoDefaultBranch = [string](Get-OptionalObjectPropertyValue -InputObject $repo -PropertyName 'defaultBranch')
    $sharedRepositoryRef = if ($ApplyConfig) {
        [string]$applyConfiguration.ref
    }
    elseif ($SharedRepositoryOnly) {
        if (
            $repo.Name -ieq $PreferredSharedRepositoryName -and
            -not [string]::IsNullOrWhiteSpace($PreferredSharedRepositoryRef)
        ) {
            $PreferredSharedRepositoryRef
        }
        elseif (-not [string]::IsNullOrWhiteSpace($sharedRepoDefaultBranch)) {
            ConvertFrom-GitRefToBranchName -Ref $sharedRepoDefaultBranch
        }
        else {
            'main'
        }
    }
    else {
        if (
            -not [string]::IsNullOrWhiteSpace($existingSharedRepoName) -and
            $sharedRepoName -ieq $existingSharedRepoName
        ) {
            Get-AzDoSharedRepositoryRefFromWorkingTree -RepoRoot $mainRepoWorkingRoot -Branch $script:mainRepoBranch
        }
        elseif (-not [string]::IsNullOrWhiteSpace($sharedRepoDefaultBranch)) {
            ConvertFrom-GitRefToBranchName -Ref $sharedRepoDefaultBranch
        }
        else {
            'main'
        }
    }
    if ([string]::IsNullOrWhiteSpace($sharedRepositoryRef)) {
        $sharedRepositoryRef = 'main'
    }

    try {
        [void]$Host.UI.RawUI
    }
    catch {
        throw "This script must be run in an interactive PowerShell session."
    }

    if (-not $ApplyConfig -and -not $SkipSharedRepositoryVersionUpdate) {
        Write-Section `
            -Message "Creating/updating shared repository '$sharedRepoName'"

        $repositoryRemoteUrl = [string](Get-OptionalObjectPropertyValue -InputObject $repo -PropertyName 'remoteUrl')
        if ([string]::IsNullOrWhiteSpace($repositoryRemoteUrl)) {
            throw "Could not determine remoteUrl for repository '$sharedRepoName'."
        }

        [void](Invoke-AzDoSharedRepositorySync `
            -ProjectName $selectedProject.Name `
            -RepositoryId ([string]$repo.Id) `
            -RepositoryName $sharedRepoName `
            -RepositoryRemoteUrl $repositoryRemoteUrl `
            -UpstreamGitSource $upstreamRepo `
            -Reference $ALM4DataverseRef `
            -AccessToken $azDevOpsAccessToken `
            -PromptForStrategy)
    }

    return [pscustomobject]@{
        SelectedProject      = $selectedProject
        MainRepo             = $mainRepo
        MainRepoWorkingTree  = $mainRepoWorkingTree
        MainRepoWorkingRoot  = $mainRepoWorkingRoot
        MainRepoIsNew        = [bool](Get-OptionalObjectPropertyValue -InputObject $mainRepo -PropertyName 'IsNewRepository')
        AzDevOpsAccessToken  = $azDevOpsAccessToken
        SharedRepo           = $repo
        SharedRepoName       = $sharedRepoName
        SharedRepositoryRef  = $sharedRepositoryRef
        SharedRepositorySelectionError = $sharedRepositorySelectionError
    }
}
