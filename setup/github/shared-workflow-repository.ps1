function Get-GitHubSharedWorkflowRepositoryValidationState {
    <#
    .SYNOPSIS
    Checks whether the configured shared workflow repository is accessible.
    .DESCRIPTION
    Does not open the repository selector. Missing or inaccessible configuration is
    returned with a reason so the guided menu can leave selection incomplete.
    User interrupts are rethrown.
    .PARAMETER Repository
    Configured shared workflow repository in owner/repository form, if present.
    .PARAMETER Reference
    Configured workflow ref to preserve when the repository remains selected.
    .PARAMETER UpstreamFullName
    Canonical upstream repository used to resolve the configured repository.
    .PARAMETER DefaultOwner
    Default owner passed to the shared repository resolver.
    .PARAMETER UpstreamGitSource
    Git source passed to the shared repository resolver.
    .PARAMETER ALM4DataverseRef
    Upstream template ref used by the shared repository resolver.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter()][string]$Repository,
        [Parameter()][string]$Reference,
        [Parameter(Mandatory)][string]$UpstreamFullName,
        [Parameter(Mandatory)][string]$DefaultOwner,
        [Parameter(Mandatory)][string]$UpstreamGitSource,
        [Parameter(Mandatory)][string]$ALM4DataverseRef
    )

    if ([string]::IsNullOrWhiteSpace($Repository)) {
        return [ordered]@{
            Repository      = ''
            Reference       = ''
            ValidationError = 'No shared workflow repository is configured in alm-config.psd1.'
        }
    }

    try {
        $sharedWorkflowRepository = Initialize-GitHubSharedWorkflowFork `
            -UpstreamFullName $UpstreamFullName `
            -DefaultOwner $DefaultOwner `
            -UpstreamGitSource $UpstreamGitSource `
            -Reference $ALM4DataverseRef `
            -PreferredRepositoryFullName $Repository `
            -SelectOnly `
            -UsePreferredRepository
    }
    catch {
        if (Test-IsUserInterruptException -Exception $_.Exception) {
            throw
        }

        $lookupError = ([string]$_.Exception.Message -replace '\s+', ' ').Trim()
        $referenceToPreserve = if ([string]::IsNullOrWhiteSpace($Reference)) { 'main' } else { $Reference }
        return [ordered]@{
            Repository      = $Repository
            Reference       = $referenceToPreserve
            ValidationError = "Could not access configured shared workflow repository '$Repository': $lookupError"
        }
    }

    $resolvedRepository = [string]$sharedWorkflowRepository.nameWithOwner
    if ([string]::IsNullOrWhiteSpace($resolvedRepository)) {
        throw 'Configured shared workflow repository lookup returned no owner/repository name.'
    }

    $resolvedReference = $Reference
    if ([string]::IsNullOrWhiteSpace($resolvedReference)) {
        $resolvedReference = if ($sharedWorkflowRepository.defaultBranchRef -and $sharedWorkflowRepository.defaultBranchRef.name) {
            [string]$sharedWorkflowRepository.defaultBranchRef.name
        }
        else {
            'main'
        }
    }

    return [ordered]@{
        Repository      = $resolvedRepository
        Reference       = $resolvedReference
        ValidationError = ''
    }
}

function Select-GitHubSharedWorkflowRepositoryState {
    <#
    .SYNOPSIS
    Selects a shared workflow repository without checking or changing its version.
    .DESCRIPTION
    Re-selecting the current repository preserves its configured ref. A different repository
    uses its default branch, falling back to main when the provider returns no default. An
    empty current repository opens the selector without a preferred choice.
    .PARAMETER RepositoryState
    Mutable repository/ref state shared with setup previews and publication.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$RepositoryState,
        [Parameter(Mandatory)][string]$UpstreamFullName,
        [Parameter(Mandatory)][string]$DefaultOwner,
        [Parameter(Mandatory)][string]$UpstreamGitSource,
        [Parameter(Mandatory)][string]$Reference
    )

    $previousRepository = [string]$RepositoryState.Repository

    $selectedSharedWorkflowRepo = Initialize-GitHubSharedWorkflowFork `
        -UpstreamFullName $UpstreamFullName `
        -DefaultOwner $DefaultOwner `
        -UpstreamGitSource $UpstreamGitSource `
        -Reference $Reference `
        -PreferredRepositoryFullName $previousRepository `
        -SelectOnly
    $selectedRepository = [string]$selectedSharedWorkflowRepo.nameWithOwner
    if ([string]::IsNullOrWhiteSpace($selectedRepository)) {
        throw 'Shared workflow repository selection did not return a valid owner/repository name.'
    }
    $selectedRepositoryParts = $selectedRepository.Split('/', 2)
    if (
        $selectedRepositoryParts.Count -ne 2 -or
        [string]::IsNullOrWhiteSpace($selectedRepositoryParts[0]) -or
        [string]::IsNullOrWhiteSpace($selectedRepositoryParts[1])
    ) {
        throw 'Shared workflow repository selection did not return a valid owner/repository name.'
    }

    $selectedReference = 'main'
    if ($selectedSharedWorkflowRepo.defaultBranchRef -and $selectedSharedWorkflowRepo.defaultBranchRef.name) {
        $selectedReference = [string]$selectedSharedWorkflowRepo.defaultBranchRef.name
    }
    if (
        $selectedRepository -ieq $previousRepository -and
        -not [string]::IsNullOrWhiteSpace([string]$RepositoryState.Reference)
    ) {
        $selectedReference = [string]$RepositoryState.Reference
    }

    $RepositoryState.Repository = $selectedRepository
    $RepositoryState.Reference = $selectedReference
    $RepositoryState.ValidationError = ''
    return $RepositoryState
}

function Update-GitHubSharedWorkflowRepositoryState {
    <#
    .SYNOPSIS
    Checks and updates the selected shared workflow repository and its Actions access policy.
    .DESCRIPTION
    Uses the selected repository without reopening the selection menu. Its configured ref is
    preserved for generated workflows while the repository is reconciled to Reference.
    Repository reconciliation and the Actions access-policy update are gated by ShouldProcess.
    CheckOnly performs only the read-only comparison and never changes the repository;
    ContinueOnCheckError records a failed comparison on the state instead of throwing.
    .PARAMETER RepositoryState
    Mutable repository/ref state shared with setup previews and publication.
    .PARAMETER Reference
    Upstream template ref used to reconcile the selected repository.
    .PARAMETER CheckOnly
    Resolves the selected repository and compares its default branch with Reference
    without changing repository content or the Actions access policy. Records UpdateKind,
    PendingUpdate and UpdateStatus on RepositoryState so the menu and preview can disclose
    the update that Apply will perform.
    .PARAMETER UpdateStrategy
    Update to perform when not using CheckOnly. FastForward, Rebase, Reset and LeaveUnchanged
    are supported; an update is required by the current comparison when this is empty.
    .PARAMETER ContinueOnCheckError
    With CheckOnly, records a failed comparison as UpdateKind Error and returns the state.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$RepositoryState,
        [Parameter(Mandatory)][string]$UpstreamFullName,
        [Parameter(Mandatory)][string]$DefaultOwner,
        [Parameter(Mandatory)][string]$UpstreamGitSource,
        [Parameter(Mandatory)][string]$Reference,
        [Parameter()][switch]$CheckOnly,
        [Parameter()][ValidateSet('', 'None', 'Seed', 'FastForward', 'Rebase', 'Reset', 'LeaveUnchanged')][string]$UpdateStrategy = '',
        [Parameter()][switch]$ContinueOnCheckError
    )

    $currentRepository = [string]$RepositoryState.Repository
    if ([string]::IsNullOrWhiteSpace($currentRepository)) {
        $message = 'A shared workflow repository must be selected before its version can be checked.'
        if ($CheckOnly -and $ContinueOnCheckError) {
            $RepositoryState.UpdateKind = 'Error'
            $RepositoryState.PendingUpdate = $false
            $RepositoryState.UpdateStrategy = ''
            $RepositoryState.UpdateStatus = "Check failed: $message"
            $RepositoryState.Changed = $false
            return $RepositoryState
        }
        throw $message
    }
    if (-not $CheckOnly -and [string]::IsNullOrWhiteSpace($UpdateStrategy)) {
        throw 'UpdateStrategy is required when not using CheckOnly.'
    }
    if (-not $CheckOnly -and -not $PSCmdlet.ShouldProcess($currentRepository, 'Update shared workflow repository and Actions access policy')) {
        return $RepositoryState
    }

    $workParent = Join-Path ([System.IO.Path]::GetTempPath()) ("ALM4Dataverse-ForkCheck-" + [guid]::NewGuid().ToString('n'))
    $workRoot = Join-Path $workParent 'repo'
    New-DirectoryIfMissing -Path $workParent
    try {
        try {
            # Resolve without opening the selection menu. The temporary clone is
            # discarded after the comparison or reconciliation.
            $sharedWorkflowRepo = Initialize-GitHubSharedWorkflowFork `
                -UpstreamFullName $UpstreamFullName `
                -DefaultOwner $DefaultOwner `
                -UpstreamGitSource $UpstreamGitSource `
                -Reference $Reference `
                -PreferredRepositoryFullName $currentRepository `
                -SelectOnly `
                -UsePreferredRepository
            $selectedRepository = [string]$sharedWorkflowRepo.nameWithOwner
            if ([string]::IsNullOrWhiteSpace($selectedRepository)) {
                throw 'Shared workflow repository check did not return a valid owner/repository name.'
            }
            $defaultBranch = 'main'
            if ($sharedWorkflowRepo.defaultBranchRef -and $sharedWorkflowRepo.defaultBranchRef.name) {
                $defaultBranch = [string]$sharedWorkflowRepo.defaultBranchRef.name
            }

            $syncResult = Invoke-GitHubSharedWorkflowRepositorySync `
                -RepositoryFullName $selectedRepository `
                -DefaultBranch $defaultBranch `
                -WorkRoot $workRoot `
                -UpstreamFullName $UpstreamFullName `
                -UpstreamGitSource $UpstreamGitSource `
                -Reference $Reference `
                -CheckOnly:$CheckOnly `
                -UpdateStrategy $UpdateStrategy

            $RepositoryState.Repository = $selectedRepository
            $RepositoryState.UpdateKind = [string]$syncResult.UpdateKind
            $RepositoryState.PendingUpdate = [bool]$syncResult.PendingUpdate
            $RepositoryState.UpdateStatus = [string]$syncResult.UpdateStatus
            $RepositoryState.CanFastForward = [bool]$syncResult.CanFastForward
            $RepositoryState.IsAhead = [bool]$syncResult.IsAhead
            $RepositoryState.MatchesCanonicalUpstreamDefault = [bool]$syncResult.MatchesCanonicalUpstreamDefault
            $RepositoryState.Changed = [bool]$syncResult.Changed
            if ($CheckOnly) {
                $RepositoryState.UpdateStrategy = if ([bool]$syncResult.PendingUpdate) { '' } else { 'None' }
            }
        }
        catch {
            if (-not $CheckOnly -or -not $ContinueOnCheckError) {
                throw
            }

            $message = ([string]$_.Exception.Message -replace '\s+', ' ').Trim()
            $RepositoryState.UpdateKind = 'Error'
            $RepositoryState.PendingUpdate = $false
            $RepositoryState.UpdateStrategy = ''
            $RepositoryState.UpdateStatus = "Check failed: $message"
            $RepositoryState.CanFastForward = $false
            $RepositoryState.IsAhead = $false
            $RepositoryState.MatchesCanonicalUpstreamDefault = $false
            $RepositoryState.Changed = $false
            return $RepositoryState
        }
    }
    finally {
        if (Test-Path -LiteralPath $workParent) {
            try { Remove-Item -LiteralPath $workParent -Recurse -Force -ErrorAction Stop } catch { Write-Verbose 'Could not remove the shared workflow repository check clone; continuing cleanup.' }
        }
    }

    if (-not $CheckOnly) {
        $selectedRepositoryParts = ([string]$RepositoryState.Repository).Split('/', 2)
        if (
            $selectedRepositoryParts.Count -ne 2 -or
            [string]::IsNullOrWhiteSpace($selectedRepositoryParts[0]) -or
            [string]::IsNullOrWhiteSpace($selectedRepositoryParts[1])
        ) {
            throw 'Shared workflow repository update did not return a valid owner/repository name.'
        }

        Invoke-WithSpectreStatus -Status "Checking Actions access policy on shared workflow repository '$($RepositoryState.Repository)'..." -ScriptBlock {
            Initialize-GitHubSharedWorkflowAccessPolicy -Owner $selectedRepositoryParts[0] -Repo $selectedRepositoryParts[1]
        } | Out-Null
    }

    return $RepositoryState
}

function Get-GitHubSharedWorkflowRepositoryUpdateSummary {
    <#
    .SYNOPSIS
    Formats the shared workflow repository update state for the guided setup menu.
    .DESCRIPTION
    Returns a short status that distinguishes a required strategy, a selected strategy
    and a completed comparison with no action required. Errors are returned verbatim so
    the user can see why the check failed.
    .PARAMETER RepositoryState
    State recorded by Update-GitHubSharedWorkflowRepositoryState.
    .PARAMETER Reference
    Upstream template ref used in strategy descriptions.
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

    switch ($updateStrategy) {
        'FastForward' { return "Fast-forward to '$Reference' on apply" }
        'Rebase' { return "Rebase onto '$Reference' on apply" }
        'Reset' { return "Reset to '$Reference' on apply" }
        'LeaveUnchanged' { return 'Leave unchanged (no repository update on apply)' }
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
