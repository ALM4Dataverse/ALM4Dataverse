function Get-GitHubAccessibleRepository {
    <#
    .SYNOPSIS
        Returns repositories accessible to the authenticated GitHub account.
    .DESCRIPTION
        Filters the first 100 repositories owned by the user, available through
        organization membership, or accessible as a collaborator. Returns unique,
        sorted objects containing full_name only.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject], [object[]])]
    param()

    $repos = Invoke-GhApi -Endpoint 'user/repos?affiliation=owner,collaborator,organization_member&sort=updated&per_page=100'
    if (-not $repos) {
        return @()
    }

    $normalized = @()
    foreach ($repo in @($repos)) {
        $repoFullName = $null

        if ($repo.PSObject.Properties.Name -contains 'full_name' -and -not [string]::IsNullOrWhiteSpace($repo.full_name)) {
            $repoFullName = [string]$repo.full_name
        }
        elseif (
            ($repo.PSObject.Properties.Name -contains 'owner') -and $repo.owner -and
            ($repo.owner.PSObject.Properties.Name -contains 'login') -and -not [string]::IsNullOrWhiteSpace($repo.owner.login) -and
            ($repo.PSObject.Properties.Name -contains 'name') -and -not [string]::IsNullOrWhiteSpace($repo.name)
        ) {
            $repoFullName = "$($repo.owner.login)/$($repo.name)"
        }

        if ([string]::IsNullOrWhiteSpace($repoFullName)) {
            continue
        }

        $normalized += [pscustomobject]@{
            full_name = $repoFullName
        }
    }

    return @($normalized | Sort-Object -Property full_name -Unique)
}

function Resolve-GitHubRepoFullNameFromSource {
    <#
    .SYNOPSIS
        Resolves a GitHub repository full name (owner/repo) from URL, owner/repo text, or a local git repository path.
    .DESCRIPTION
        A local path is inspected through remote.origin.url without changing it.
        Returns Fallback for blank/unrecognized input or an unreadable local origin;
        this helper does not verify that the resulting repository exists.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][string]$Source,
        [Parameter()][string]$Fallback = 'ALM4Dataverse/ALM4Dataverse'
    )

    if (-not [string]::IsNullOrWhiteSpace($Source)) {
        $trimmed = $Source.Trim()

        if ($trimmed -match '^[^/\s]+/[^/\s]+$') {
            return $trimmed
        }

        if ($trimmed -match 'github\.com[:/]+([^/]+)/([^/]+?)(?:\.git)?/?$') {
            return "$($Matches[1])/$($Matches[2])"
        }

        if (Test-Path -LiteralPath $trimmed) {
            try {
                $originUrl = (& git -C $trimmed config --get remote.origin.url 2>$null).Trim()
                if (-not [string]::IsNullOrWhiteSpace($originUrl) -and $originUrl -match 'github\.com[:/]+([^/]+)/([^/]+?)(?:\.git)?/?$') {
                    return "$($Matches[1])/$($Matches[2])"
                }
            }
            catch {
                Write-Verbose 'Could not resolve the local repository origin; using the fallback repository.'
            }
        }
    }

    return $Fallback
}

function Resolve-UpstreamGitRemoteSource {
    <#
    .SYNOPSIS
        Resolves an upstream git remote source usable by `git fetch`/`git clone`.
    .DESCRIPTION
        Existing local paths and HTTP/git@ sources pass through; owner/repo expands
        to an HTTPS GitHub URL. Unrecognized input falls back to GitHubFullName.
        Resolution does not test remote connectivity.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][string]$ConfiguredSource,
        [Parameter(Mandatory)][string]$GitHubFullName
    )

    if (-not [string]::IsNullOrWhiteSpace($ConfiguredSource)) {
        $trimmed = $ConfiguredSource.Trim()

        if (Test-Path -LiteralPath $trimmed) {
            return $trimmed
        }

        if ($trimmed -match '^https?://' -or $trimmed -match '^git@') {
            return $trimmed
        }

        if ($trimmed -match '^[^/\s]+/[^/\s]+$') {
            return "https://github.com/$trimmed.git"
        }

        if ($trimmed -match 'github\.com[:/]+([^/]+)/([^/]+?)(?:\.git)?/?$') {
            return "https://github.com/$($Matches[1])/$($Matches[2]).git"
        }
    }

    return "https://github.com/$GitHubFullName.git"
}

function Resolve-GitTargetRefFromRemote {
    <#
    .SYNOPSIS
        Resolves a branch/tag/commit ref against a remote to a local git ref for checkout/merge operations.
    .DESCRIPTION
        Uses the first ls-remote match: branches become RemoteName/branch and tags
        become the returned SHA; other matches retain Ref. Throws for no match or
        failed queries. Does not fetch: callers must already have the objects locally.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RemoteName,
        [Parameter(Mandatory)][string]$Ref,
        [Parameter()][string]$RepositoryPath
    )

    $gitArgs = @()
    if (-not [string]::IsNullOrWhiteSpace($RepositoryPath)) {
        $gitArgs += @('-C', $RepositoryPath)
    }

    & git @gitArgs ls-remote --exit-code $RemoteName $Ref | Out-Null
    if ($LASTEXITCODE -eq 2) {
        throw "Could not resolve reference '$Ref' from remote '$RemoteName'."
    }
    if ($LASTEXITCODE -ne 0) {
        throw "git ls-remote failed for '$RemoteName' with exit code $LASTEXITCODE"
    }

    $lsRemoteOutput = (& git @gitArgs ls-remote $RemoteName $Ref | Select-Object -First 1)
    if (-not $lsRemoteOutput) {
        throw "Could not resolve reference '$Ref' from remote '$RemoteName'."
    }

    if ($lsRemoteOutput -match '^([a-f0-9]+)\s+(.+)$') {
        $commitSha = $Matches[1]
        $fullRef = $Matches[2]

        if ($fullRef -match '^refs/heads/(.+)$') {
            return "$RemoteName/$($Matches[1])"
        }
        elseif ($fullRef -match '^refs/tags/') {
            return $commitSha
        }
        else {
            return $Ref
        }
    }

    return $Ref
}

function Get-GitHubForkSyncState {
    <#
    .SYNOPSIS
        Clones a GitHub shared workflow repository into a temporary working tree and computes its sync state against upstream.
    .DESCRIPTION
        Deletes any existing WorkRoot, clones and checks out DefaultBranch, then
        fetches the configured upstream. Returns hashes, UpstreamRef, ancestry flags
        and an optional canonical-upstream-default match used for initial alignment.
        Canonical comparison is best-effort; required clone/fetch failures throw.
        Leaves WorkRoot for the caller to update and remove.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ForkFullName,
        [Parameter(Mandatory)][string]$WorkRoot,
        [Parameter(Mandatory)][string]$UpstreamGitSource,
        [Parameter(Mandatory)][string]$UpstreamFullName,
        [Parameter(Mandatory)][string]$Reference,
        [Parameter(Mandatory)][string]$DefaultBranch
    )

    if (Test-Path -LiteralPath $WorkRoot) {
        try {
            Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction Stop
        }
        catch {
            throw
        }
    }

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $cloneOutput = @(& gh repo clone $ForkFullName $WorkRoot 2>&1)
        $cloneExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($cloneExitCode -ne 0) {
        $cloneErrorDetails = @($cloneOutput | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $cloneErrorMessage = if ($cloneErrorDetails.Count -gt 0) { $cloneErrorDetails[-1] } else { "Exit code: $cloneExitCode" }
        throw "Failed to clone repository '$ForkFullName'. $cloneErrorMessage"
    }

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $checkoutOutput = @(& git -C $WorkRoot checkout $DefaultBranch 2>&1)
        $checkoutExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($checkoutExitCode -ne 0) {
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $checkoutOutput = @(& git -C $WorkRoot checkout -b $DefaultBranch "origin/$DefaultBranch" 2>&1)
            $checkoutExitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        if ($checkoutExitCode -ne 0) {
            $checkoutErrorDetails = @($checkoutOutput | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $checkoutErrorMessage = if ($checkoutErrorDetails.Count -gt 0) { $checkoutErrorDetails[-1] } else { "Exit code: $checkoutExitCode" }
            throw "Failed to check out repository default branch '$DefaultBranch'. $checkoutErrorMessage"
        }
    }

    & git -C $WorkRoot remote remove upstream 2>$null | Out-Null
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $addRemoteOutput = @(& git -C $WorkRoot remote add upstream $UpstreamGitSource 2>&1)
        $addRemoteExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($addRemoteExitCode -ne 0) {
        $addRemoteErrorDetails = @($addRemoteOutput | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $addRemoteErrorMessage = if ($addRemoteErrorDetails.Count -gt 0) { $addRemoteErrorDetails[-1] } else { "Exit code: $addRemoteExitCode" }
        throw "Failed to add upstream remote '$UpstreamGitSource'. $addRemoteErrorMessage"
    }

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $fetchUpstreamOutput = @(& git -C $WorkRoot fetch upstream 2>&1)
        $fetchUpstreamExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($fetchUpstreamExitCode -ne 0) {
        $fetchUpstreamErrorDetails = @($fetchUpstreamOutput | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $fetchUpstreamErrorMessage = if ($fetchUpstreamErrorDetails.Count -gt 0) { $fetchUpstreamErrorDetails[-1] } else { "Exit code: $fetchUpstreamExitCode" }
        throw "Failed to fetch upstream remote. $fetchUpstreamErrorMessage"
    }

    $upstreamRef = Resolve-GitTargetRefFromRemote -RemoteName 'upstream' -Ref $Reference -RepositoryPath $WorkRoot

    $localHash = (& git -C $WorkRoot rev-parse HEAD).Trim()
    $upstreamHash = (& git -C $WorkRoot rev-parse $upstreamRef).Trim()
    $matchesCanonicalUpstreamDefault = $false

    $canonicalUpstreamSource = Resolve-UpstreamGitRemoteSource -ConfiguredSource $UpstreamFullName -GitHubFullName $UpstreamFullName
    if (-not [string]::IsNullOrWhiteSpace($canonicalUpstreamSource)) {
        $remoteNames = @(& git -C $WorkRoot remote 2>$null)
        $hasCanonicalUpstreamRemote = (@($remoteNames | ForEach-Object { [string]$_ } | Where-Object { $_ -eq 'upstream-github' }).Count -gt 0)
        if ($hasCanonicalUpstreamRemote) {
            $previousErrorActionPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                [void](& git -C $WorkRoot remote remove upstream-github 2>&1)
            }
            finally {
                $ErrorActionPreference = $previousErrorActionPreference
            }
        }

        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            [void](& git -C $WorkRoot remote add upstream-github $canonicalUpstreamSource 2>&1)
            $addCanonicalRemoteExitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        if ($addCanonicalRemoteExitCode -eq 0) {
            $previousErrorActionPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                [void](& git -C $WorkRoot fetch upstream-github $DefaultBranch 2>&1)
                $fetchCanonicalRemoteExitCode = $LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $previousErrorActionPreference
            }

            if ($fetchCanonicalRemoteExitCode -eq 0) {
                $canonicalUpstreamHash = (& git -C $WorkRoot rev-parse "upstream-github/$DefaultBranch").Trim()
                $matchesCanonicalUpstreamDefault = ($localHash -eq $canonicalUpstreamHash)
            }
        }
    }

    $canFastForward = $false
    $isAhead = $false
    if ($localHash -ne $upstreamHash) {
        & git -C $WorkRoot merge-base --is-ancestor HEAD $upstreamRef
        $canFastForward = ($LASTEXITCODE -eq 0)

        if (-not $canFastForward) {
            & git -C $WorkRoot merge-base --is-ancestor $upstreamRef HEAD
            $isAhead = ($LASTEXITCODE -eq 0)
        }
    }

    return [pscustomobject]@{
        UpstreamRef                     = $upstreamRef
        LocalHash                       = $localHash
        UpstreamHash                    = $upstreamHash
        MatchesCanonicalUpstreamDefault = $matchesCanonicalUpstreamDefault
        CanFastForward                  = $canFastForward
        IsAhead                         = $isAhead
    }
}

function Get-GitHubAccessibleForksOfRepository {
    <#
    .SYNOPSIS
        Lists accessible repositories that are forks of the specified upstream repository.
    .DESCRIPTION
        Inspects the first 100 authenticated-user repositories across owner,
        organization-member and collaborator affiliations, resolving missing parent
        metadata with individual detail requests. Matches the immediate parent full
        name and returns one full_name object per repository, not all fork metadata.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject], [object[]])]
    param(
        [Parameter(Mandatory)][string]$UpstreamFullName
    )

    $accessibleRepos = Invoke-GhApi -Endpoint 'user/repos?affiliation=owner,collaborator,organization_member&sort=updated&per_page=100'
    if (-not $accessibleRepos) {
        return @()
    }

    $matchingForks = @()
    $matchingForkFullNames = @{}

    foreach ($repo in @($accessibleRepos)) {
        $isFork = $false
        if ($repo.PSObject.Properties.Name -contains 'fork') {
            $isFork = [bool]$repo.fork
        }
        if (-not $isFork) {
            continue
        }

        $repoFullName = $null
        if ($repo.PSObject.Properties.Name -contains 'full_name' -and -not [string]::IsNullOrWhiteSpace($repo.full_name)) {
            $repoFullName = [string]$repo.full_name
        }
        elseif (
            ($repo.PSObject.Properties.Name -contains 'owner') -and $repo.owner -and
            ($repo.owner.PSObject.Properties.Name -contains 'login') -and -not [string]::IsNullOrWhiteSpace($repo.owner.login) -and
            ($repo.PSObject.Properties.Name -contains 'name') -and -not [string]::IsNullOrWhiteSpace($repo.name)
        ) {
            $repoFullName = "$($repo.owner.login)/$($repo.name)"
        }

        if ([string]::IsNullOrWhiteSpace($repoFullName)) {
            continue
        }

        # Some API responses do not include 'parent'. Resolve using repo details when required.
        $parentFullName = $null
        if (
            ($repo.PSObject.Properties.Name -contains 'parent') -and $repo.parent -and
            ($repo.parent.PSObject.Properties.Name -contains 'full_name') -and -not [string]::IsNullOrWhiteSpace($repo.parent.full_name)
        ) {
            $parentFullName = [string]$repo.parent.full_name
        }
        else {
            $repoDetails = Invoke-GhApi -Endpoint "repos/$repoFullName" -AllowNotFound
            if (
                $repoDetails -and
                ($repoDetails.PSObject.Properties.Name -contains 'parent') -and $repoDetails.parent -and
                ($repoDetails.parent.PSObject.Properties.Name -contains 'full_name') -and -not [string]::IsNullOrWhiteSpace($repoDetails.parent.full_name)
            ) {
                $parentFullName = [string]$repoDetails.parent.full_name
            }
        }

        $normalizedRepoFullName = $repoFullName.ToLowerInvariant()
        if ($parentFullName -ieq $UpstreamFullName -and -not $matchingForkFullNames.ContainsKey($normalizedRepoFullName)) {
            $matchingForkFullNames[$normalizedRepoFullName] = $true
            $matchingForks += [pscustomobject]@{
                full_name = $repoFullName
            }
        }
    }

    return @($matchingForks)
}

function Initialize-GitHubSharedWorkflowFork {
    <#
    .SYNOPSIS
        Ensures an accessible shared workflow repository and optionally updates it from upstream.
    .DESCRIPTION
        Offers accessible repositories, public-fork creation or private-repository
        creation. The owner prompt for a new repository defaults to DefaultOwner.
        Duplicate fork entries are shown only once, matched case-insensitively by
        owner and repository name.
        Newly created repositories and canonical-default matches are force-aligned
        with lease protection to Reference; other repositories follow ancestry-based
        update prompts. SelectOnly returns repository details without checking or
        changing its version. UsePreferredRepository skips the selection prompt and
        resolves PreferredRepositoryFullName directly. This interactive operation is
        not guarded by ShouldProcess.
    .PARAMETER PreferredRepositoryFullName
        Existing repository offered first during selection, or resolved directly with
        UsePreferredRepository.
    .PARAMETER SelectOnly
        Returns the selected repository without checking or changing its version.
    .PARAMETER UsePreferredRepository
        Skips the selection menu and loads PreferredRepositoryFullName directly.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'UpstreamGitSource', Justification = 'Used by the nested repository-operation callback.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UpstreamFullName,
        [Parameter(Mandatory)][string]$DefaultOwner,
        [Parameter(Mandatory)][string]$UpstreamGitSource,
        [Parameter(Mandatory)][string]$Reference,
        [Parameter()][string]$PreferredRepositoryFullName,
        [Parameter()][switch]$SelectOnly,
        [Parameter()][switch]$UsePreferredRepository
    )

    if ($UsePreferredRepository -and [string]::IsNullOrWhiteSpace($PreferredRepositoryFullName)) {
        throw 'UsePreferredRepository requires PreferredRepositoryFullName.'
    }
    if ($UsePreferredRepository -and $PreferredRepositoryFullName -notmatch '^[^/]+/[^/]+$') {
        throw 'PreferredRepositoryFullName must use owner/repository format.'
    }

    $sharedRepositoryOptions = if ($UsePreferredRepository) {
        $null
    }
    else {
        Invoke-WithSpectreStatus -Status 'Retrieving shared workflow repository options...' -ScriptBlock {
            [pscustomobject]@{
                ExistingForks = @(Get-GitHubAccessibleForksOfRepository -UpstreamFullName $UpstreamFullName)
                AccessibleRepos = @(Get-GitHubAccessibleRepository)
            }
        }
    }

    $existingForks = @()
    $accessibleRepos = @()
    if ($sharedRepositoryOptions) {
        $existingForks = @($sharedRepositoryOptions.ExistingForks)
        $accessibleRepos = @($sharedRepositoryOptions.AccessibleRepos)
    }

    $menuItems = @()
    $menuActions = @()

    if (-not [string]::IsNullOrWhiteSpace($PreferredRepositoryFullName)) {
        $preferredRepo = $accessibleRepos | Where-Object { $_.full_name -ieq $PreferredRepositoryFullName } | Select-Object -First 1
        if ($preferredRepo) {
            $menuItems += "Use current shared workflow repository: $($preferredRepo.full_name)"
            $menuActions += @{ Type = 'UseExisting'; FullName = $preferredRepo.full_name }

            $existingForks = @($existingForks | Where-Object { $_.full_name -ine $preferredRepo.full_name })
            $accessibleRepos = @($accessibleRepos | Where-Object { $_.full_name -ine $preferredRepo.full_name })
        }
    }

    $forkFullNameMap = @{}
    foreach ($fork in $existingForks) {
        $forkFullName = [string]$fork.full_name
        if ([string]::IsNullOrWhiteSpace($forkFullName)) {
            continue
        }

        $normalizedForkFullName = $forkFullName.ToLowerInvariant()
        if ($forkFullNameMap.ContainsKey($normalizedForkFullName)) {
            continue
        }

        $forkFullNameMap[$normalizedForkFullName] = $true
        $menuItems += "Use existing fork: $forkFullName"
        $menuActions += @{ Type = 'UseExisting'; FullName = $forkFullName }
    }

    $nonForkRepos = @($accessibleRepos | Where-Object {
        $repoFullName = $_.full_name
        if ([string]::IsNullOrWhiteSpace($repoFullName)) {
            return $false
        }

        return -not $forkFullNameMap.ContainsKey($repoFullName.ToLowerInvariant())
    })

    $menuItems += 'Create a new repository'
    $menuActions += @{ Type = 'CreateNew' }

    foreach ($repo in $nonForkRepos) {
        $menuItems += "Use existing repository: $($repo.full_name)"
        $menuActions += @{ Type = 'UseExisting'; FullName = $repo.full_name }
    }



    if ($UsePreferredRepository) {
        $selectedAction = @{
            Type = 'UseExisting'
            FullName = $PreferredRepositoryFullName
        }
    }
    else {
        $selection = Select-FromMenu `
            -Title "Select shared workflow repository" `
            -Items $menuItems `
            -PromptGuidanceLines @(
                'Choose or create a repository that will host the reusable ALM4Dataverse workflow templates.'
            ) `
            -PromptGuidanceDocRelativePath 'docs/setup/github-setup.md' `
            -PromptGuidanceRef $ALM4DataverseRef
        if ($null -eq $selection) {
            throw "No shared workflow repository selected."
        }

        $selectedAction = $menuActions[$selection]
    }

    $selectedSharedRepositoryFullName = $null
    $createdNewSharedRepository = $false
    if ($selectedAction.Type -eq 'UseExisting') {
        $selectedSharedRepositoryFullName = $selectedAction.FullName
    }

    if (-not $selectedSharedRepositoryFullName) {
        $upstreamParts = $UpstreamFullName.Split('/', 2)
        $defaultRepositoryName = $upstreamParts[1]
        if (-not [string]::IsNullOrWhiteSpace($PreferredRepositoryFullName) -and $PreferredRepositoryFullName -match '^[^/]+/(.+)$') {
            $defaultRepositoryName = $Matches[1]
        }

        $repositoryOwner = Read-TextWithDefault -Prompt 'Shared workflow repository owner (user or organization)' -DefaultValue $DefaultOwner
        if ([string]::IsNullOrWhiteSpace($repositoryOwner)) {
            throw 'Shared workflow repository owner cannot be empty.'
        }

        while ($true) {
            $repositoryName = Read-TextWithDefault -Prompt 'Shared workflow repository name' -DefaultValue $defaultRepositoryName

            if ($repositoryName -match '^[A-Za-z0-9._-]+$') {
                break
            }

            Write-Warning "Repository name contains invalid characters. Use letters, numbers, dot (.), underscore (_), or hyphen (-)."
        }

        $selectedSharedRepositoryFullName = "$repositoryOwner/$repositoryName"

        $creationModeItems = @(
            'Public (fork)',
            'Private'
        )
        $creationModeSelection = Select-FromMenu -Title "How should '$selectedSharedRepositoryFullName' be created?" -Items $creationModeItems -PromptGuidanceLines @(
            'Choose whether the shared workflow repository should be public (fork style) or private.'
        ) -PromptGuidanceDocRelativePath 'docs/setup/github-setup.md' -PromptGuidanceRef $ALM4DataverseRef
        if ($null -eq $creationModeSelection) {
            throw 'No shared workflow repository type selected.'
        }

        if ($creationModeSelection -eq 0) {
            $createResult = Invoke-WithSpectreStatus -Status "Creating public fork '$selectedSharedRepositoryFullName' from '$UpstreamFullName'..." -ScriptBlock {
                $createArgs = @('repo', 'fork', $UpstreamFullName, '--clone=false', '--fork-name', $repositoryName)
                if ($repositoryOwner -ine $script:ghUser) {
                    $createArgs += @('--org', $repositoryOwner)
                }
                $createOutput = @(& gh @createArgs 2>&1)
                return [pscustomobject]@{
                    ExitCode = $LASTEXITCODE
                    Output   = $createOutput
                }
            }
        }
        else {
            $createResult = Invoke-WithSpectreStatus -Status "Creating private shared workflow repository '$selectedSharedRepositoryFullName'..." -ScriptBlock {
                $createArgs = @('repo', 'create', $selectedSharedRepositoryFullName, '--private', '--add-readme')
                $createOutput = @(& gh @createArgs 2>&1)
                return [pscustomobject]@{
                    ExitCode = $LASTEXITCODE
                    Output   = $createOutput
                }
            }
        }

        if ($createResult.ExitCode -ne 0) {
            $errText = @($createResult.Output) -join "`n"
            if ($errText -match 'already exists') {
                Write-Host "Repository '$selectedSharedRepositoryFullName' already exists; continuing." -ForegroundColor Yellow
            }
            else {
                throw "Failed to create shared workflow repository '$selectedSharedRepositoryFullName': $errText"
            }
        }
        else {
            $createdNewSharedRepository = $true
        }
    }

    $sharedRepoParts = $selectedSharedRepositoryFullName.Split('/', 2)
    $sharedRepoOwnerName = $sharedRepoParts[0]
    $sharedRepoName = $sharedRepoParts[1]
    $sharedRepo = Invoke-WithSpectreStatus -Status "Loading repository details for '$selectedSharedRepositoryFullName'..." -ScriptBlock {
        Get-GitHubRepo -Owner $sharedRepoOwnerName -Repo $sharedRepoName
    }

    $defaultBranch = 'main'
    if ($sharedRepo.defaultBranchRef -and $sharedRepo.defaultBranchRef.name) {
        $defaultBranch = $sharedRepo.defaultBranchRef.name
    }

    if ($SelectOnly) {
        return $sharedRepo
    }

    $workParent = Join-Path ([System.IO.Path]::GetTempPath()) ("ALM4Dataverse-ForkSync-" + [guid]::NewGuid().ToString('n'))
    $workRoot = Join-Path $workParent 'repo'
    New-DirectoryIfMissing -Path $workParent

    try {
        $forkSyncState = Invoke-WithSpectreStatus -Status "Checking shared workflow repository '$selectedSharedRepositoryFullName' against upstream '$UpstreamFullName'..." -ScriptBlock {
            Get-GitHubForkSyncState `
                -ForkFullName $selectedSharedRepositoryFullName `
                -WorkRoot $workRoot `
                -UpstreamGitSource $UpstreamGitSource `
                -UpstreamFullName $UpstreamFullName `
                -Reference $Reference `
                -DefaultBranch $defaultBranch
        }

        if ($forkSyncState.LocalHash -eq $forkSyncState.UpstreamHash) {
            Write-Host "Shared workflow repository is already up to date for ref '$Reference'."
        }
        else {
            # A freshly created fork starts at upstream's default, not necessarily the
            # selected release ref. Align that initial state before offering merge flows.
            if ($createdNewSharedRepository -or $forkSyncState.MatchesCanonicalUpstreamDefault) {
                Invoke-WithErrorHandling -OperationName "Aligning shared workflow repository '$selectedSharedRepositoryFullName'" -StatusMessage "Aligning shared workflow repository '$selectedSharedRepositoryFullName' to ref '$Reference'..." -CaptureOutputInPanel -ScriptBlock {
                    $previousErrorActionPreference = $ErrorActionPreference
                    try {
                        $ErrorActionPreference = 'Continue'

                        & git -C $workRoot reset --hard $forkSyncState.UpstreamRef 2>&1 | Out-Host
                        if ($LASTEXITCODE -ne 0) {
                            throw "Failed to align shared workflow repository '$selectedSharedRepositoryFullName' to ref '$Reference'."
                        }

                        & git -C $workRoot push --force-with-lease origin $defaultBranch 2>&1 | Out-Host
                        if ($LASTEXITCODE -ne 0) { throw 'Git push failed.' }
                    }
                    finally {
                        $ErrorActionPreference = $previousErrorActionPreference
                    }
                } | Out-Null

                Write-Host "Shared workflow repository aligned successfully."
                return Get-GitHubRepo -Owner $sharedRepoOwnerName -Repo $sharedRepoName
            }

            if ($forkSyncState.CanFastForward) {
                if (Read-YesNo -Prompt "Updates are available from upstream (fast-forward). Update '$selectedSharedRepositoryFullName'?" ) {
                    Invoke-WithErrorHandling -OperationName "Fast-forwarding shared workflow repository '$selectedSharedRepositoryFullName'" -StatusMessage "Fast-forwarding shared workflow repository '$selectedSharedRepositoryFullName'..." -CaptureOutputInPanel -ScriptBlock {
                        $previousErrorActionPreference = $ErrorActionPreference
                        try {
                            $ErrorActionPreference = 'Continue'

                            & git -C $workRoot merge --ff-only $forkSyncState.UpstreamRef 2>&1 | Out-Host
                            if ($LASTEXITCODE -ne 0) { throw 'Git merge failed.' }

                            & git -C $workRoot push origin $defaultBranch 2>&1 | Out-Host
                            if ($LASTEXITCODE -ne 0) { throw 'Git push failed.' }
                        }
                        finally {
                            $ErrorActionPreference = $previousErrorActionPreference
                        }
                    } | Out-Null

                    Write-Host "Shared workflow repository updated successfully."
                }
            }
            else {
                if ($forkSyncState.IsAhead) {
                    Write-Host "Shared workflow repository is ahead of upstream for ref '$Reference'." -ForegroundColor Yellow
                }
                else {
                    $divergedMenuItems = @(
                        "Rebase '$selectedSharedRepositoryFullName' onto ref '$Reference'",
                        "Reset '$selectedSharedRepositoryFullName' '$defaultBranch' to ref '$Reference' (force push)",
                        "Leave '$selectedSharedRepositoryFullName' unchanged"
                    )
                    $divergedSelection = Select-FromMenu -Title "Shared workflow repository '$selectedSharedRepositoryFullName' has diverged from upstream. Choose how to update it." -Items $divergedMenuItems -PromptGuidanceLines @(
                        'Choose how to reconcile divergence between your shared repository and upstream templates.',
                        'Rebase preserves local commits, reset force-aligns to upstream, and leave keeps the current state.'
                    ) -PromptGuidanceDocRelativePath 'docs/setup/github-setup.md' -PromptGuidanceRef $ALM4DataverseRef

                    switch ($divergedSelection) {
                        0 {
                            Invoke-WithErrorHandling -OperationName "Rebasing shared workflow repository '$selectedSharedRepositoryFullName'" -StatusMessage "Rebasing shared workflow repository '$selectedSharedRepositoryFullName' onto '$Reference'..." -CaptureOutputInPanel -ScriptBlock {
                                $previousErrorActionPreference = $ErrorActionPreference
                                try {
                                    $ErrorActionPreference = 'Continue'

                                    & git -C $workRoot rebase $forkSyncState.UpstreamRef 2>&1 | Out-Host
                                    if ($LASTEXITCODE -ne 0) {
                                        throw "Git rebase failed - resolve conflicts manually in '$selectedSharedRepositoryFullName'."
                                    }

                                    & git -C $workRoot push --force-with-lease origin $defaultBranch 2>&1 | Out-Host
                                    if ($LASTEXITCODE -ne 0) { throw 'Git push failed.' }
                                }
                                finally {
                                    $ErrorActionPreference = $previousErrorActionPreference
                                }
                            } | Out-Null

                            Write-Host "Shared workflow repository updated successfully."
                        }
                        1 {
                            Invoke-WithErrorHandling -OperationName "Resetting shared workflow repository '$selectedSharedRepositoryFullName'" -StatusMessage "Resetting shared workflow repository '$selectedSharedRepositoryFullName' to '$Reference'..." -CaptureOutputInPanel -ScriptBlock {
                                $previousErrorActionPreference = $ErrorActionPreference
                                try {
                                    $ErrorActionPreference = 'Continue'

                                    & git -C $workRoot reset --hard $forkSyncState.UpstreamRef 2>&1 | Out-Host
                                    if ($LASTEXITCODE -ne 0) {
                                        throw "Failed to reset shared workflow repository '$selectedSharedRepositoryFullName' to ref '$Reference'."
                                    }

                                    & git -C $workRoot push --force-with-lease origin $defaultBranch 2>&1 | Out-Host
                                    if ($LASTEXITCODE -ne 0) { throw 'Git push failed.' }
                                }
                                finally {
                                    $ErrorActionPreference = $previousErrorActionPreference
                                }
                            } | Out-Null

                            Write-Host "Shared workflow repository updated successfully."
                        }
                        default {
                            Write-Host "Leaving shared workflow repository unchanged." -ForegroundColor Yellow
                        }
                    }
                }
            }
        }
    }
    finally {
        try { Remove-Item -LiteralPath $workParent -Recurse -Force -ErrorAction Stop } catch { Write-Verbose 'Could not remove the shared workflow repository; continuing cleanup.' }
    }

    return Get-GitHubRepo -Owner $sharedRepoOwnerName -Repo $sharedRepoName
}

function New-GitHubRepositoryInteractive {
    <#
    .SYNOPSIS
        Interactively creates a new GitHub repository.
    .DESCRIPTION
        Prompts for owner, valid repository name and visibility, creates with a README,
        then returns Get-GitHubRepo metadata. Cancellation of visibility selection or
        CLI failure throws; declining ShouldProcess skips prompts and returns nothing.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$DefaultOwner
    )

    if (-not $PSCmdlet.ShouldProcess($DefaultOwner, 'Create GitHub repository interactively')) { return }

    Write-Host ""
    Write-Host "Create a new GitHub repository" -ForegroundColor Green
    Write-Host ""

    $owner = Read-TextWithDefault -Prompt 'Repository owner (user or organization)' -DefaultValue $DefaultOwner

    $repoName = $null
    while ($true) {
        $repoName = Read-TextWithDefault -Prompt 'New repository name'
        if ([string]::IsNullOrWhiteSpace($repoName)) {
            Write-Warning "Repository name cannot be empty."
            continue
        }

        if ($repoName -match '^[A-Za-z0-9._-]+$') {
            break
        }

        Write-Warning "Repository name contains invalid characters. Use letters, numbers, dot (.), underscore (_), or hyphen (-)."
    }

    $visibilityItems = @('Private', 'Public')
    $visibilitySelection = Select-FromMenu -Title "Select repository visibility" -Items $visibilityItems -PromptGuidanceLines @(
        'Choose whether the new repository should be private or public.',
        'Private is recommended unless you intentionally want public visibility.'
    ) -PromptGuidanceDocRelativePath 'docs/setup/github-setup.md' -PromptGuidanceRef $ALM4DataverseRef
    if ($null -eq $visibilitySelection) {
        throw "No repository visibility selected."
    }

    $visibilityFlag = if ($visibilitySelection -eq 0) { '--private' } else { '--public' }
    $repoFullName = "$owner/$repoName"

    $createResult = Invoke-WithSpectreStatus -Status "Creating repository '$repoFullName'..." -ScriptBlock {
        $createArgs = @('repo', 'create', $repoFullName, $visibilityFlag, '--add-readme')
        $output = @(& gh @createArgs 2>&1)
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = $output
        }
    }

    if ($createResult.ExitCode -ne 0) {
        throw "Failed to create repository '$repoFullName': $(@($createResult.Output) -join "`n")"
    }

    Write-Host "Created repository '$repoFullName'." -ForegroundColor Green
    return Invoke-WithSpectreStatus -Status "Loading repository details for '$repoFullName'..." -ScriptBlock {
        Get-GitHubRepo -Owner $owner -Repo $repoName
    }
}
