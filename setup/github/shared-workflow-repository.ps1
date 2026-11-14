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
    .PARAMETER RepositoryState
    Mutable repository/ref state shared with setup previews and publication.
    .PARAMETER Reference
    Upstream template ref used to reconcile the selected repository.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$RepositoryState,
        [Parameter(Mandatory)][string]$UpstreamFullName,
        [Parameter(Mandatory)][string]$DefaultOwner,
        [Parameter(Mandatory)][string]$UpstreamGitSource,
        [Parameter(Mandatory)][string]$Reference
    )

    $currentRepository = [string]$RepositoryState.Repository
    if ([string]::IsNullOrWhiteSpace($currentRepository)) {
        throw 'A shared workflow repository must be selected before its version can be checked.'
    }
    if (-not $PSCmdlet.ShouldProcess($currentRepository, 'Check and update shared workflow repository and Actions access policy')) {
        return $RepositoryState
    }

    $sharedWorkflowRepo = Initialize-GitHubSharedWorkflowFork `
        -UpstreamFullName $UpstreamFullName `
        -DefaultOwner $DefaultOwner `
        -UpstreamGitSource $UpstreamGitSource `
        -Reference $Reference `
        -PreferredRepositoryFullName $currentRepository `
        -UsePreferredRepository
    $selectedRepository = [string]$sharedWorkflowRepo.nameWithOwner
    if ([string]::IsNullOrWhiteSpace($selectedRepository)) {
        throw 'Shared workflow repository update did not return a valid owner/repository name.'
    }
    $selectedRepositoryParts = $selectedRepository.Split('/', 2)
    if (
        $selectedRepositoryParts.Count -ne 2 -or
        [string]::IsNullOrWhiteSpace($selectedRepositoryParts[0]) -or
        [string]::IsNullOrWhiteSpace($selectedRepositoryParts[1])
    ) {
        throw 'Shared workflow repository update did not return a valid owner/repository name.'
    }

    Invoke-WithSpectreStatus -Status "Checking Actions access policy on shared workflow repository '$selectedRepository'..." -ScriptBlock {
        Initialize-GitHubSharedWorkflowAccessPolicy -Owner $selectedRepositoryParts[0] -Repo $selectedRepositoryParts[1]
    } | Out-Null

    $RepositoryState.Repository = $selectedRepository
    return $RepositoryState
}
