#Requires -Version 7.2

<#
.SYNOPSIS
    Platform-neutral engine behind upstream release tracking.
.DESCRIPTION
    Keeps a fork in step with its GitHub upstream repository's releases. Each eligible
    upstream release is proposed by its own pull request, from its own branch, into the
    fork's base branch. A pull request is never changed after it is opened: when a newer
    release appears, a new pull request replaces it, and the old one is closed unless people
    have worked on it (see section 9).

    The upstream is always on GitHub. The fork can be on GitHub or Azure DevOps; everything
    that differs between the two lives in an adapter file and is reached only through the
    "fork platform interface" in section 7:

      upstream-release-github.ps1        GitHub fork (gh CLI).
      upstream-release-azure-devops.ps1  Azure DevOps fork (REST API with System.AccessToken).

    This file is organised in the order a run uses it:

      1. Conventions shared by every step and both platforms.
      2. Native command helpers, including per-call git authentication.
      3. Upstream release discovery and version ordering.
      4. Tracking state: which upstream release the fork already contains.
      5. Building the update branch (baseline record, merge, conflict capture).
      6. Pull-request content shared by both platforms.
      7. Fork platform interface.
      8. Run reporting.
      9. Invoke-UpstreamReleaseTracking, which orchestrates the steps above.

    Dot-source this file; it loads both adapters, defines functions only and has no side
    effects. update-upstream-release-pr.ps1 is the executable entry point.
.NOTES
    Tokens are read from environment variables and handed to git through environment
    entries for a single call. They never appear in command lines, remote URLs, Git
    configuration files or log output.
#>

. (Join-Path $PSScriptRoot '../../pipelines/scripts/common.ps1')
. (Join-Path $PSScriptRoot 'upstream-release-github.ps1')
. (Join-Path $PSScriptRoot 'upstream-release-azure-devops.ps1')

#region 1. Conventions

function Get-UpstreamTrackingConvention {
    <#
    .SYNOPSIS
        Returns the fixed names shared by the engine, both adapters and the documentation.
    .DESCRIPTION
        Kept in one function so every step, the tests and the maintainer guide refer to the
        same values. Changing one of these is a breaking change for forks that already have
        an open tracking pull request or a committed state file.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    [pscustomobject]@{
        # Committed record of the upstream release the fork contains. See section 4.
        StateFilePath        = '.github/upstream-release.json'
        # Upstream tags are fetched outside refs/tags because forks commonly publish their
        # own tags with the same names (for example a fork release 'v1.19.5').
        UpstreamTagRefRoot   = 'refs/upstream-release-tags'
        # Each update pull request has its own branch: the prefix followed by the release tag
        # it merges (see Get-UpdateBranchName). A platform allows only one open pull request
        # per branch, and a pull request that people work on stays open beside its successor.
        UpdateBranchPrefix   = 'update/upstream-release/'
        PullRequestLabel     = 'upstream-release'
        # Identifies this automation's marker in a pull request. GitHub stores the marker in
        # a hidden comment in the description; Azure DevOps stores it as a pull-request property.
        MarkerName           = 'upstream-release-tracking'
        # Git trailers on the commits on an update branch. The first identifies this
        # automation's commits, so any other commit on the branch is someone's work. The
        # second names the baseline a branch recorded, for when the pull request's marker
        # was never stored. See section 5.
        CommitTrailer        = 'Upstream-Release-Tracking'
        BaselineTrailer      = 'Upstream-Release-Baseline'
        # Character budgets for the generated lists that grow with the size of an update.
        # With the fixed text they keep a description well inside GitHub's limit of 65,536
        # characters; the same text goes into the Azure DevOps details comment.
        ReleaseNotesBudget   = 8000
        ForkComparisonBudget = 30000
        ConflictTableBudget  = 20000
    }
}

function Get-UpdateBranchName {
    <#
    .SYNOPSIS
        Returns the name of the branch that proposes an upstream release, for example
        'update/upstream-release/v1.20.0'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Tag
    )

    return (Get-UpstreamTrackingConvention).UpdateBranchPrefix + $Tag
}

function Get-UpdateBranchTag {
    <#
    .SYNOPSIS
        Returns the release tag an update branch is named after, the reverse of Get-UpdateBranchName.
    .PARAMETER BranchName
        A branch name, with or without the 'refs/heads/' prefix.
    .OUTPUTS
        [string], or $null when the branch is not an update branch.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string]$BranchName
    )

    $prefix = (Get-UpstreamTrackingConvention).UpdateBranchPrefix
    $name = [string]$BranchName -replace '^refs/heads/', ''
    if (-not $name.StartsWith($prefix, [StringComparison]::Ordinal) -or $name.Length -eq $prefix.Length) {
        return $null
    }
    return $name.Substring($prefix.Length)
}

#endregion

#region 2. Native command helpers

function Invoke-NativeCommandWithEnvironment {
    <#
    .SYNOPSIS
        Runs a native command with extra environment variables that exist only for that call.
    .DESCRIPTION
        Sets each variable, runs the command through Invoke-CheckedNativeCommand and then
        restores the previous values (or removes variables that did not exist), even when
        the command fails. Values that are null or empty are skipped rather than set, so a
        caller can pass an optional token without branching.

        On failure the error includes the command's output, because git and gh explain
        what went wrong only on stderr. Neither tool prints the credentials passed here.
    .OUTPUTS
        The command's combined stdout/stderr lines as strings.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Command,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [System.Collections.IDictionary]$Environment = @{},

        [switch]$AllowFailure
    )

    $previousValues = @{}
    foreach ($name in $Environment.Keys) {
        if ([string]::IsNullOrEmpty([string]$Environment[$name])) {
            continue
        }
        $previousValues[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, [string]$Environment[$name])
    }

    try {
        $output = @(Invoke-CheckedNativeCommand -Command $Command -Arguments $Arguments -AllowFailure)
    }
    finally {
        foreach ($name in $previousValues.Keys) {
            # Setting null removes a variable that did not exist before this call.
            [Environment]::SetEnvironmentVariable($name, $previousValues[$name])
        }
    }

    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
        throw "'$Command $($Arguments[0])' failed with exit code ${LASTEXITCODE}:`n$($output -join "`n")"
    }
    return $output
}

function Invoke-Git {
    <#
    .SYNOPSIS
        Runs a local git command and returns its output lines.
    .PARAMETER AllowFailure
        Returns output instead of throwing; the caller must inspect $LASTEXITCODE.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [switch]$AllowFailure
    )

    Invoke-NativeCommandWithEnvironment -Command git -Arguments $Arguments -AllowFailure:$AllowFailure
}

function Invoke-GitWithFileInput {
    <#
    .SYNOPSIS
        Runs a local git command that reads one of its inputs from a temporary file.
    .DESCRIPTION
        A merge with many conflicts produces path lists and commit messages larger than a
        command line may be (32 KB in total on Windows, 128 KB per argument on Linux). Git
        can read those from a file instead, through options such as --file and
        --pathspec-from-file, so the text is written to a file that is deleted afterwards.
    .PARAMETER FileOption
        The git option that names the file; '=<path>' is appended to it.
    .PARAMETER Content
        The text git reads, written as UTF-8 without a byte order mark.
    .EXAMPLE
        Invoke-GitWithFileInput -Arguments @('commit', '--no-edit') -FileOption '--file' -Content $message
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$FileOption,

        [Parameter(Mandatory)]
        [string]$Content
    )

    $inputFile = New-TemporaryFile
    try {
        [IO.File]::WriteAllText($inputFile.FullName, $Content, [Text.UTF8Encoding]::new($false))
        Invoke-Git -Arguments ($Arguments + "$FileOption=$($inputFile.FullName)")
    }
    finally {
        Remove-Item -LiteralPath $inputFile.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-AuthenticatedGit {
    <#
    .SYNOPSIS
        Runs a networked git command (fetch or push) against one remote with one credential.
    .DESCRIPTION
        The credential is sent as an HTTP Authorization header supplied through git's
        GIT_CONFIG_COUNT/GIT_CONFIG_KEY_n/GIT_CONFIG_VALUE_n environment entries. That keeps
        it out of the process command line and the remote URL, and limits it to this one
        call. Because each call contacts exactly one remote, the fork credential is never
        sent to the upstream and vice versa.

        Without an Authorization value the command runs anonymously, which is what a public
        upstream needs.
    .PARAMETER Authorization
        Header value without the 'AUTHORIZATION:' prefix, as returned by
        Get-ForkGitAuthorization or Get-UpstreamGitAuthorization.
    .NOTES
        Assumes no Authorization header is persisted in Git configuration, because git sends
        every configured extra header and two Authorization headers fail authentication.
        Remove-PersistedGitAuthorization guarantees that before the first network call.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [string]$Authorization,

        [switch]$AllowFailure
    )

    $environment = @{}
    if (-not [string]::IsNullOrEmpty($Authorization)) {
        $environment = @{
            GIT_CONFIG_COUNT   = '1'
            GIT_CONFIG_KEY_0   = 'http.extraheader'
            GIT_CONFIG_VALUE_0 = "AUTHORIZATION: $Authorization"
        }
    }

    Invoke-NativeCommandWithEnvironment -Command git -Arguments $Arguments -Environment $environment -AllowFailure:$AllowFailure
}

function Remove-PersistedGitAuthorization {
    <#
    .SYNOPSIS
        Removes Authorization headers that a checkout step persisted in the local Git configuration.
    .DESCRIPTION
        actions/checkout and the Azure Pipelines checkout task can persist the job token as
        an http.<url>.extraheader entry. It would be sent alongside the header that
        Invoke-AuthenticatedGit supplies, so it is removed before the first network call.
        Both pipelines also check out without persisting credentials; this is a safeguard.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $headerKeys = Invoke-Git -Arguments @('config', '--local', '--name-only', '--get-regexp', '^http\..*extraheader$') -AllowFailure
    # Exit code 1 means no matching key, which is the expected case.
    if ($LASTEXITCODE -ne 0) {
        return
    }
    foreach ($key in $headerKeys | Sort-Object -Unique) {
        if ($PSCmdlet.ShouldProcess($key, 'Remove persisted Git header')) {
            Invoke-Git -Arguments @('config', '--local', '--unset-all', $key) | Out-Null
        }
    }
}

#endregion

#region 3. Upstream release discovery and version ordering

function Get-UpstreamApiToken {
    <#
    .SYNOPSIS
        Returns the token used to read the upstream repository through the GitHub API.
    .DESCRIPTION
        UPSTREAM_READ_TOKEN is required for a private upstream. For a public upstream it is
        optional; a GitHub fork then falls back to its own token, because anonymous requests
        share a small per-IP rate limit on hosted runners. An Azure DevOps fork has no
        GitHub token of its own, so it reads a public upstream anonymously.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Fork
    )

    if (-not [string]::IsNullOrEmpty($env:UPSTREAM_READ_TOKEN)) {
        return $env:UPSTREAM_READ_TOKEN
    }
    if ($Fork.Platform -eq 'GitHub') {
        return $env:GH_TOKEN
    }
    return $null
}

function Get-UpstreamGitAuthorization {
    <#
    .SYNOPSIS
        Returns the git Authorization header value for fetching from the upstream, or $null.
    .DESCRIPTION
        Only UPSTREAM_READ_TOKEN is used. A public upstream is fetched anonymously, so a
        fork's own token is never sent to another repository's Git endpoint.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ([string]::IsNullOrEmpty($env:UPSTREAM_READ_TOKEN)) {
        return $null
    }
    return ConvertTo-GitHubBasicAuthorization -Token $env:UPSTREAM_READ_TOKEN
}

function Invoke-UpstreamGitHubApi {
    <#
    .SYNOPSIS
        Calls a GET endpoint of the GitHub REST API and returns every item across all pages.
    .DESCRIPTION
        Uses Invoke-RestMethod rather than gh so that it works on Azure Pipelines agents,
        which have no authenticated gh. Pages are followed through the Link header.
    .PARAMETER Path
        API path relative to https://api.github.com/, including any query string.
    .PARAMETER Token
        Optional bearer token. Without it the request is anonymous.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$Token
    )

    $headers = @{
        Accept                 = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    if (-not [string]::IsNullOrEmpty($Token)) {
        $headers.Authorization = "Bearer $Token"
    }

    # Each page arrives as one array; the inner loop flattens the pages into one stream of items.
    foreach ($page in Invoke-RestMethod -Uri "https://api.github.com/$Path" -Headers $headers -FollowRelLink) {
        foreach ($item in $page) {
            $item
        }
    }
}

function ConvertTo-UpstreamReleaseVersion {
    <#
    .SYNOPSIS
        Parses a release tag into a value that can be ordered against other release tags.
    .DESCRIPTION
        Accepts two to four numeric parts with an optional leading 'v', an optional SemVer
        pre-release label after a hyphen, and optional build metadata after '+'.
        Examples: 'v1.20.1', '1.19.5.1', 'v1.21.0-beta.2'. Missing numeric parts are treated
        as zero, so 'v1.20' and 'v1.20.0' are the same version.
    .OUTPUTS
        [pscustomobject] with Version ([version], always four parts) and PreReleaseLabel
        (empty for stable versions), or $null when the tag does not match the pattern.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Tag
    )

    $pattern = '^v?(?<numbers>\d+(\.\d+){1,3})(-(?<label>[0-9A-Za-z.-]+))?(\+[0-9A-Za-z.-]+)?$'
    $match = [regex]::Match($Tag, $pattern)
    if (-not $match.Success) {
        return $null
    }

    $numbers = [int[]]$match.Groups['numbers'].Value.Split('.')
    $paddedNumbers = @($numbers) + @(0, 0, 0) | Select-Object -First 4

    [pscustomobject]@{
        Version         = [version]::new($paddedNumbers[0], $paddedNumbers[1], $paddedNumbers[2], $paddedNumbers[3])
        PreReleaseLabel = $match.Groups['label'].Value
    }
}

function Compare-PreReleaseLabel {
    <#
    .SYNOPSIS
        Orders two non-empty SemVer pre-release labels, such as 'beta.2' and 'beta.10'.
    .DESCRIPTION
        Implements SemVer 2.0.0 rule 11.4: dot-separated identifiers are compared left to
        right; numeric identifiers compare numerically and rank below alphanumeric ones;
        alphanumeric identifiers compare in ordinal (ASCII) order; when every shared
        identifier is equal, the label with fewer identifiers ranks lower.
    .OUTPUTS
        [int] that is negative, zero or positive, like IComparer.Compare.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string]$Left,

        [Parameter(Mandatory)]
        [string]$Right
    )

    $leftIdentifiers = $Left.Split('.')
    $rightIdentifiers = $Right.Split('.')
    $sharedCount = [Math]::Min($leftIdentifiers.Count, $rightIdentifiers.Count)

    for ($index = 0; $index -lt $sharedCount; $index++) {
        $leftIdentifier = $leftIdentifiers[$index]
        $rightIdentifier = $rightIdentifiers[$index]
        $leftIsNumeric = $leftIdentifier -match '^\d+$'
        $rightIsNumeric = $rightIdentifier -match '^\d+$'

        if ($leftIsNumeric -and $rightIsNumeric) {
            $order = ([bigint]$leftIdentifier).CompareTo([bigint]$rightIdentifier)
        }
        elseif ($leftIsNumeric) {
            return -1
        }
        elseif ($rightIsNumeric) {
            return 1
        }
        else {
            $order = [string]::CompareOrdinal($leftIdentifier, $rightIdentifier)
        }

        if ($order -ne 0) {
            return [Math]::Sign($order)
        }
    }

    return $leftIdentifiers.Count.CompareTo($rightIdentifiers.Count)
}

function Compare-UpstreamRelease {
    <#
    .SYNOPSIS
        Orders two release objects produced by New-UpstreamReleaseRecord.
    .DESCRIPTION
        Compares numeric versions first. For equal numbers a stable release ranks above any
        pre-release, and two pre-releases are ordered by Compare-PreReleaseLabel. Ordering
        uses the tag, not the publication date, so a maintenance release such as v1.19.6
        published after v1.20.0 still ranks below it.
    .OUTPUTS
        [int] that is negative, zero or positive, like IComparer.Compare.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Left,

        [Parameter(Mandatory)]
        [pscustomobject]$Right
    )

    $versionOrder = $Left.Version.CompareTo($Right.Version)
    if ($versionOrder -ne 0) {
        return [Math]::Sign($versionOrder)
    }

    $leftIsStable = [string]::IsNullOrEmpty($Left.PreReleaseLabel)
    $rightIsStable = [string]::IsNullOrEmpty($Right.PreReleaseLabel)
    if ($leftIsStable -and $rightIsStable) {
        return 0
    }
    if ($leftIsStable) {
        return 1
    }
    if ($rightIsStable) {
        return -1
    }

    return Compare-PreReleaseLabel -Left $Left.PreReleaseLabel -Right $Right.PreReleaseLabel
}

function New-UpstreamReleaseRecord {
    <#
    .SYNOPSIS
        Builds the release object every other function works with.
    .DESCRIPTION
        Pure object construction; it changes no state, so it does not support ShouldProcess.
    .PARAMETER IsPrerelease
        GitHub's prerelease flag. A tag with a pre-release label is always treated as a
        prerelease, even if the GitHub flag was not set, so that a mislabelled release
        cannot be picked up when prereleases are excluded.
    .OUTPUTS
        [pscustomobject] with Tag, Version, PreReleaseLabel, IsPrerelease and NotesUrl, or
        $null when the tag cannot be parsed by ConvertTo-UpstreamReleaseVersion.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs an in-memory object only.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$UpstreamRepository,

        [Parameter(Mandatory)]
        [string]$Tag,

        [bool]$IsPrerelease = $false
    )

    $parsed = ConvertTo-UpstreamReleaseVersion -Tag $Tag
    if ($null -eq $parsed) {
        return $null
    }

    [pscustomobject]@{
        Tag             = $Tag
        Version         = $parsed.Version
        PreReleaseLabel = $parsed.PreReleaseLabel
        IsPrerelease    = $IsPrerelease -or -not [string]::IsNullOrEmpty($parsed.PreReleaseLabel)
        NotesUrl        = 'https://github.com/{0}/releases/tag/{1}' -f $UpstreamRepository, [uri]::EscapeDataString($Tag)
    }
}

function Get-UpstreamRelease {
    <#
    .SYNOPSIS
        Lists the upstream repository's published releases, oldest first.
    .DESCRIPTION
        Draft releases are excluded: they are not published and their tags may not exist.
        Releases whose tags cannot be ordered are skipped with a warning rather than failing
        the run, so one unusual tag does not block tracking.
    .PARAMETER Token
        Token able to read the upstream repository, from Get-UpstreamApiToken.
    .OUTPUTS
        Release objects from New-UpstreamReleaseRecord, sorted with Compare-UpstreamRelease.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string]$UpstreamRepository,

        [string]$Token
    )

    try {
        $published = @(Invoke-UpstreamGitHubApi -Path "repos/$UpstreamRepository/releases?per_page=100" -Token $Token)
    }
    catch {
        throw ("Could not list the releases of '$UpstreamRepository'. A private upstream needs the UPSTREAM_READ_TOKEN " +
            "secret (or, on GitHub, a GitHub App with UPSTREAM_REPOSITORY_PRIVATE). $($_.Exception.Message)")
    }

    $releases = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($item in $published | Where-Object { -not $_.draft }) {
        $release = New-UpstreamReleaseRecord -UpstreamRepository $UpstreamRepository -Tag $item.tag_name -IsPrerelease ([bool]$item.prerelease)
        if ($null -eq $release) {
            Write-Warning "Skipping upstream release '$($item.tag_name)': its tag is not a recognised version."
            continue
        }
        $releases.Add($release)
    }

    $releases.Sort([Comparison[pscustomobject]] { param($left, $right) Compare-UpstreamRelease -Left $left -Right $right })
    # The comma stops PowerShell from unrolling the array, so callers always receive an array.
    return , $releases.ToArray()
}

function Select-TargetUpstreamRelease {
    <#
    .SYNOPSIS
        Chooses the upstream release the update pull request should merge.
    .DESCRIPTION
        A requested tag always wins, including a prerelease when prereleases are otherwise
        excluded, because a maintainer asked for it explicitly. Otherwise the highest-ordered
        release is chosen, considering prereleases only when IncludePrereleases is set.
    .OUTPUTS
        One release object, or $null when no release is eligible.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Releases,

        [string]$RequestedTag,

        [switch]$IncludePrereleases
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedTag)) {
        $requested = $Releases | Where-Object Tag -CEQ $RequestedTag | Select-Object -First 1
        if ($null -eq $requested) {
            throw "Requested upstream release '$RequestedTag' was not found among the upstream's published releases."
        }
        return $requested
    }

    $eligible = @($Releases | Where-Object { $IncludePrereleases -or -not $_.IsPrerelease })
    if ($eligible.Count -eq 0) {
        return $null
    }

    # Get-UpstreamRelease returns releases oldest first.
    return $eligible[-1]
}

function Get-UpstreamReleaseRange {
    <#
    .SYNOPSIS
        Returns the releases after Current up to and including Target, oldest first.
    .DESCRIPTION
        Used to link every set of release notes the update covers. Intermediate prereleases
        are left out unless IncludePrereleases is set; the target itself is always included.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Releases,

        [Parameter(Mandatory)]
        [pscustomobject]$Current,

        [Parameter(Mandatory)]
        [pscustomobject]$Target,

        [switch]$IncludePrereleases
    )

    $inRange = foreach ($release in $Releases) {
        $isAfterCurrent = (Compare-UpstreamRelease -Left $release -Right $Current) -gt 0
        $isUpToTarget = (Compare-UpstreamRelease -Left $release -Right $Target) -le 0
        $isTarget = $release.Tag -ceq $Target.Tag
        if ($isAfterCurrent -and $isUpToTarget -and ($isTarget -or $IncludePrereleases -or -not $release.IsPrerelease)) {
            $release
        }
    }

    return , @($inRange)
}

#endregion

#region 4. Tracking state

<#
    Why a committed state file instead of relying on Git history alone:
    a fork that squash-merges its update pull requests never has the upstream tag commit in
    its history, so "the newest upstream tag that is an ancestor of main" cannot identify
    the release the fork contains. The state file survives any merge method. Git history is
    still used as a fallback, which covers forks that always merge with merge commits.
#>

function Read-UpstreamTrackingState {
    <#
    .SYNOPSIS
        Reads the committed state file from a Git ref without checking it out.
    .DESCRIPTION
        A state file that names a different upstream repository is ignored, because a fork
        of a fork inherits its parent's state file through the merge.
    .OUTPUTS
        [pscustomobject] with upstreamRepository, tag and commit, or $null when the file is
        missing, unreadable or describes a different upstream.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Ref,

        [Parameter(Mandatory)]
        [string]$UpstreamRepository
    )

    $statePath = (Get-UpstreamTrackingConvention).StateFilePath
    $content = Invoke-Git -Arguments @('show', "${Ref}:$statePath") -AllowFailure
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    try {
        $state = ($content -join "`n") | ConvertFrom-Json
    }
    catch {
        Write-Warning "Ignoring '$statePath' on '$Ref': it is not valid JSON."
        return $null
    }

    $describesThisUpstream = $state.PSObject.Properties['upstreamRepository'] -and
        $state.PSObject.Properties['tag'] -and
        [string]$state.upstreamRepository -eq $UpstreamRepository
    if (-not $describesThisUpstream) {
        return $null
    }

    return $state
}

function Write-UpstreamTrackingState {
    <#
    .SYNOPSIS
        Writes the state file into the working tree and stages it.
    .DESCRIPTION
        Overwrites any existing content, which also resolves a merge conflict on the file
        itself: the record must always describe this fork's merge, never the upstream's.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$UpstreamRepository,

        [Parameter(Mandatory)]
        [pscustomobject]$Release,

        [Parameter(Mandatory)]
        [string]$Commit
    )

    $statePath = (Get-UpstreamTrackingConvention).StateFilePath
    $state = [ordered]@{
        upstreamRepository = $UpstreamRepository
        tag                = $Release.Tag
        commit             = $Commit
    }

    $directory = Split-Path -Parent $statePath
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }
    # LF line endings and a trailing newline keep the file stable across platforms.
    $json = ($state | ConvertTo-Json) -replace "`r`n", "`n"
    [IO.File]::WriteAllText((Join-Path (Get-Location).Path $statePath), "$json`n")

    Invoke-Git -Arguments @('add', '--', $statePath) | Out-Null
}

function Get-UpstreamTagRef {
    <#
    .SYNOPSIS
        Returns the local ref under which an upstream tag was fetched.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Tag
    )

    return '{0}/{1}' -f (Get-UpstreamTrackingConvention).UpstreamTagRefRoot, $Tag
}

function Resolve-UpstreamTagCommit {
    <#
    .SYNOPSIS
        Returns the commit SHA an upstream tag points to, or $null when it was not fetched.
    .DESCRIPTION
        Peels annotated tags to their commit.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Tag
    )

    $commit = Invoke-Git -Arguments @('rev-parse', '--verify', '--quiet', "$(Get-UpstreamTagRef -Tag $Tag)^{commit}") -AllowFailure
    if ($LASTEXITCODE -ne 0) {
        return $null
    }
    return [string]($commit | Select-Object -First 1)
}

function Test-GitAncestor {
    <#
    .SYNOPSIS
        Returns whether Ancestor is reachable from Descendant.
    .DESCRIPTION
        Wraps 'git merge-base --is-ancestor', whose exit code 1 means "not an ancestor".
        Any other non-zero exit code is a real error and is thrown.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Ancestor,

        [Parameter(Mandatory)]
        [string]$Descendant
    )

    Invoke-Git -Arguments @('merge-base', '--is-ancestor', $Ancestor, $Descendant) -AllowFailure | Out-Null
    switch ($LASTEXITCODE) {
        0 { return $true }
        1 { return $false }
        default { throw "Could not compare '$Ancestor' with '$Descendant' (git exit code $LASTEXITCODE)." }
    }
}

function Format-UnknownCurrentReleaseMessage {
    <#
    .SYNOPSIS
        Builds the error shown when no source names the upstream release the fork contains.
    .DESCRIPTION
        The message says what was checked, why each check found nothing, and exactly how to
        fix it on the fork's platform, so a maintainer can act on it from the run log alone.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$UpstreamRepository,

        [Parameter(Mandatory)]
        [pscustomobject]$Fork,

        [Parameter(Mandatory)]
        [string]$BaseBranch,

        [Parameter(Mandatory)]
        [string]$BaseRef,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Releases
    )

    $statePath = (Get-UpstreamTrackingConvention).StateFilePath
    Invoke-Git -Arguments @('cat-file', '-e', "${BaseRef}:$statePath") -AllowFailure | Out-Null
    $stateFinding = if ($LASTEXITCODE -eq 0) {
        "present, but it is not valid JSON or describes a different upstream than '$UpstreamRepository'"
    }
    else {
        'not found'
    }

    # Releases are sorted oldest first; the newest few are the likely answers.
    $recentTags = @($Releases | Select-Object -Last 5 | ForEach-Object Tag)
    [array]::Reverse($recentTags)
    $recentReleases = if ($recentTags.Count -gt 0) { $recentTags -join ', ' } else { 'none published' }

    $newline = [Environment]::NewLine
    return @(
        "Cannot tell which upstream release '$BaseBranch' already contains, so there is no baseline to merge the next release onto."
        ''
        'Checked:'
        "  - $statePath on '$BaseBranch': $stateFinding."
        "  - Upstream release tags in the history of '$BaseBranch': none of the $($Releases.Count) releases of '$UpstreamRepository' is there."
        '    This is expected when update pull requests are squash-merged.'
        ''
        'To fix this, once:'
        "  1. Find the newest upstream release '$BaseBranch' contains, for example from the last update merged into it."
        "     Recent upstream releases: $recentReleases."
        "  2. $(Get-ForkCurrentTagInstruction -Fork $Fork)"
        "     When running the script directly, pass -CurrentTag instead."
        "The update pull request adds $statePath; once it is merged, later runs read the release from that file."
    ) -join $newline
}

function Resolve-CurrentUpstreamRelease {
    <#
    .SYNOPSIS
        Works out which upstream release the fork's base branch already contains.
    .DESCRIPTION
        Sources, in order of precedence:
          1. CurrentTagOverride, the 'current-tag' run input. Needed once when neither source
             below names the release, typically for a fork that squash-merges its updates.
          2. The committed state file on the base branch.
          3. The newest upstream release whose tag commit is in the base branch's history,
             which finds the release when updates are merged with merge commits.
          4. PendingBaselineTag, the baseline recorded by an open update pull request, in its
             marker or on its branch. It lets the automation propose a newer release while a
             pull request created with CurrentTagOverride is still waiting to be merged and
             the base branch still cannot name its release. It also wins over an older
             release found in history, which in a fork that squash-merges its updates is
             only the last release merged with a merge commit.
        When none of them answers, the error explains how to supply CurrentTagOverride, unless
        AllowUnknown is set.
        The release need not still be published (it may have been deleted upstream), but its
        tag must exist so the merge can use it as a baseline.
    .PARAMETER BaseBranch
        Name of the base branch, used in messages.
    .PARAMETER BaseRef
        Local ref of the fetched base branch, used for Git commands.
    .PARAMETER AllowUnknown
        Returns $null instead of throwing when no source names the release, so the caller can
        first check whether there is anything to do (Format-UnknownCurrentReleaseMessage).
    .OUTPUTS
        A release object with added Commit and Source properties. Source is 'Override',
        'StateFile', 'History' or 'PendingBaseline'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$UpstreamRepository,

        [Parameter(Mandatory)]
        [pscustomobject]$Fork,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Releases,

        [Parameter(Mandatory)]
        [string]$BaseBranch,

        [Parameter(Mandatory)]
        [string]$BaseRef,

        [string]$CurrentTagOverride,

        [string]$PendingBaselineTag,

        [switch]$AllowUnknown
    )

    $statePath = (Get-UpstreamTrackingConvention).StateFilePath
    $currentTag = $null
    # SourceKind is returned to the caller; SourceText names the source in the messages below
    # so that a bad value can be traced back to where it came from.
    $sourceKind = $null
    $sourceText = $null
    if (-not [string]::IsNullOrWhiteSpace($CurrentTagOverride)) {
        $currentTag = $CurrentTagOverride.Trim()
        $sourceKind = 'Override'
        $sourceText = 'the CurrentTag run input'
    }
    else {
        $state = Read-UpstreamTrackingState -Ref $BaseRef -UpstreamRepository $UpstreamRepository
        if ($null -ne $state) {
            $currentTag = [string]$state.tag
            $sourceKind = 'StateFile'
            $sourceText = "$statePath on '$BaseBranch'"
        }
    }

    if ($null -eq $currentTag) {
        for ($index = $Releases.Count - 1; $index -ge 0; $index--) {
            $commit = Resolve-UpstreamTagCommit -Tag $Releases[$index].Tag
            if ($null -ne $commit -and (Test-GitAncestor -Ancestor $commit -Descendant $BaseRef)) {
                $currentTag = $Releases[$index].Tag
                $sourceKind = 'History'
                $sourceText = "the history of '$BaseBranch'"
                break
            }
        }
    }

    # A pending baseline newer than the release found in history can only have come from a
    # maintainer's CurrentTagOverride, so it is the better answer.
    $pendingIsNewer = $false
    if (-not [string]::IsNullOrWhiteSpace($PendingBaselineTag) -and $sourceKind -eq 'History') {
        $pendingRelease = New-UpstreamReleaseRecord -UpstreamRepository $UpstreamRepository -Tag $PendingBaselineTag
        $historyRelease = New-UpstreamReleaseRecord -UpstreamRepository $UpstreamRepository -Tag $currentTag
        $pendingIsNewer = $null -ne $pendingRelease -and (Compare-UpstreamRelease -Left $pendingRelease -Right $historyRelease) -gt 0
    }
    if (($null -eq $currentTag -or $pendingIsNewer) -and -not [string]::IsNullOrWhiteSpace($PendingBaselineTag)) {
        $currentTag = $PendingBaselineTag
        $sourceKind = 'PendingBaseline'
        $sourceText = 'the baseline recorded by an open update pull request'
    }

    if ($null -eq $currentTag) {
        if ($AllowUnknown) {
            return $null
        }
        throw (Format-UnknownCurrentReleaseMessage -UpstreamRepository $UpstreamRepository -Fork $Fork `
                -BaseBranch $BaseBranch -BaseRef $BaseRef -Releases $Releases)
    }
    Write-Host "Current upstream release '$currentTag' taken from $sourceText."

    $publishedRelease = $Releases | Where-Object Tag -CEQ $currentTag | Select-Object -First 1
    $release = if ($null -ne $publishedRelease) {
        $publishedRelease
    }
    else {
        New-UpstreamReleaseRecord -UpstreamRepository $UpstreamRepository -Tag $currentTag
    }
    if ($null -eq $release) {
        throw "Current upstream tag '$currentTag', from $sourceText, is not a version such as 'v1.2.3'. Correct it and run again."
    }

    $commit = Resolve-UpstreamTagCommit -Tag $currentTag
    if ($null -eq $commit) {
        throw "Current upstream tag '$currentTag', from $sourceText, does not exist in '$UpstreamRepository'. Tags are case-sensitive; correct it and run again."
    }

    return $release | Select-Object *, @{ Name = 'Commit'; Expression = { $commit } }, @{ Name = 'Source'; Expression = { $sourceKind } }
}

#endregion

#region 5. Building the update branch

<#
    An update branch is built once, from the base branch, by the run that opens its pull
    request, and the automation never changes it afterwards.

    Every commit this automation creates ends with an 'Upstream-Release-Tracking: <tag>' Git
    trailer, so people reading the history can tell which commits it made. Whether people
    changed the branch is not judged from trailers, which an amended commit keeps, but from
    the head commit recorded in the pull request's marker (see
    Get-UpstreamPullRequestEngagement).

    The commit that records a baseline also carries 'Upstream-Release-Baseline: <tag>'. A
    pull request created with the CurrentTag input otherwise keeps its baseline only in its
    marker, and a run that failed before storing the marker would leave later runs unable to
    work out the release the fork contains.
#>

function Test-ConflictMarkerPresent {
    <#
    .SYNOPSIS
        Returns whether a working-tree file still contains a committed conflict marker.
    .OUTPUTS
        [bool]; $false for a missing file.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    return (Test-Path -LiteralPath $Path -PathType Leaf) -and
        [bool](Select-String -LiteralPath $Path -Pattern '^<<<<<<< ' -Quiet)
}

function New-MergeConflictRecord {
    <#
    .SYNOPSIS
        Describes one conflicted path for reviewers, from its 'git status' code.
    .DESCRIPTION
        In this merge "ours" is the fork and "theirs" is the upstream release, which the
        descriptions spell out. A both-modified file without conflict markers is a binary
        conflict: git keeps the fork's version and cannot insert markers into it. Must run
        while the merge result is checked out, because that check reads the working tree.
    .OUTPUTS
        [pscustomobject] with Code, Path, Description and Resolution, or $null for a status
        code that is not a conflict.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs an in-memory object only.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Code,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $editMarkers = 'Edit the file and remove the conflict markers.'
    $outcomes = @{
        UU = @{ Description = 'Changed in the fork and upstream'; Resolution = $editMarkers }
        AA = @{ Description = 'Added in the fork and upstream'; Resolution = $editMarkers }
        AU = @{ Description = 'Added in the fork, conflicting upstream'; Resolution = $editMarkers }
        UA = @{ Description = 'Added upstream, conflicting in the fork'; Resolution = $editMarkers }
        UD = @{ Description = 'Deleted upstream, changed in the fork'; Resolution = "The fork's version was kept. Delete the file if the upstream deletion should win." }
        DU = @{ Description = 'Deleted in the fork, changed upstream'; Resolution = "Upstream's version was restored. Delete the file again if the fork's deletion should win." }
        DD = @{ Description = 'Deleted in the fork and upstream'; Resolution = 'Check where the file was renamed to on each side.' }
    }
    if (-not $outcomes.ContainsKey($Code)) {
        return $null
    }

    $outcome = $outcomes[$Code]
    $isBinaryConflict = $Code -in 'UU', 'AA' -and (Test-Path -LiteralPath $Path -PathType Leaf) -and
        -not (Test-ConflictMarkerPresent -Path $Path)
    if ($isBinaryConflict) {
        $sides = if ($Code -eq 'AA') { 'added' } else { 'changed' }
        $outcome = @{ Description = "Binary file $sides in the fork and upstream"; Resolution = "The fork's version was kept. Replace it with upstream's version if that should win." }
    }

    [pscustomobject]@{
        Code        = $Code
        Path        = $Path
        Description = $outcome.Description
        Resolution  = $outcome.Resolution
    }
}

function Get-MergeConflict {
    <#
    .SYNOPSIS
        Lists the unmerged paths of an in-progress merge, with what happened on each side.
    .OUTPUTS
        [pscustomobject] per path from New-MergeConflictRecord, sorted by path.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    # -z separates entries with NUL and never quotes or escapes paths.
    $statusEntries = (Invoke-Git -Arguments @('status', '--porcelain=v1', '-z', '--untracked-files=no')) -join "`n" -split "`0"
    $conflicts = foreach ($entry in $statusEntries) {
        if ($entry.Length -ge 4) {
            New-MergeConflictRecord -Code $entry.Substring(0, 2) -Path $entry.Substring(3)
        }
    }

    return , @($conflicts | Where-Object { $null -ne $_ } | Sort-Object Path)
}

function Test-GitMergeInProgress {
    <#
    .SYNOPSIS
        Returns whether a merge started with --no-commit is waiting to be committed.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    Invoke-Git -Arguments @('rev-parse', '--quiet', '--verify', 'MERGE_HEAD') -AllowFailure | Out-Null
    return $LASTEXITCODE -eq 0
}

function Test-GitStagedChange {
    <#
    .SYNOPSIS
        Returns whether the index differs from HEAD.
    .DESCRIPTION
        Wraps 'git diff --cached --quiet', whose exit code 1 means "there are differences".
        Any other non-zero exit code is a real error and is thrown.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    Invoke-Git -Arguments @('diff', '--cached', '--quiet') -AllowFailure | Out-Null
    switch ($LASTEXITCODE) {
        0 { return $false }
        1 { return $true }
        default { throw "Could not compare the index with HEAD (git exit code $LASTEXITCODE)." }
    }
}

function Invoke-UpstreamMerge {
    <#
    .SYNOPSIS
        Creates the update commit on the currently checked-out branch.
    .DESCRIPTION
        1. Records BaselineRelease as merged, if git history does not already show it.
           Forks that squash-merge their update pull requests never contain the
           upstream tag commit, so git would otherwise pick an ancient merge base and report
           conflicts in every file both sides have touched since. A merge with the 'ours'
           strategy changes no files; it only tells git that the fork already contains that
           release, so the next merge sees just the upstream changes since then.
        2. Merges the target release without committing.
        3. Rewrites the state file, which also settles any conflict on that file.
        4. Commits, with the trailers described at the top of this section. Unresolved
           conflicts are committed with their markers, and listed in the commit message, so
           they can be resolved in the pull request; it is then opened as a draft.
        When BaselineRelease and TargetRelease are the same, the result only records that
        release: a baseline merge (if needed) and the state file.
    .PARAMETER BaselineRelease
        The upstream release the base branch already contains. Needs a Commit property, as
        added by Resolve-CurrentUpstreamRelease.
    .OUTPUTS
        [pscustomobject] with Conflicts (from Get-MergeConflict), BaselineRecorded ([bool])
        and BaselineTag.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$UpstreamRepository,

        [Parameter(Mandatory)]
        [pscustomobject]$BaselineRelease,

        [Parameter(Mandatory)]
        [pscustomobject]$TargetRelease
    )

    $convention = Get-UpstreamTrackingConvention

    $baselineRecorded = $false
    if (-not (Test-GitAncestor -Ancestor $BaselineRelease.Commit -Descendant 'HEAD')) {
        Write-Host "Recording upstream $($BaselineRelease.Tag) as already merged (no file changes)."
        # Unrelated histories are allowed for forks that began as a copy rather than a fork.
        Invoke-Git -Arguments @(
            'merge', '--no-ff', '--strategy=ours', '--allow-unrelated-histories',
            '-m', "Record $UpstreamRepository $($BaselineRelease.Tag) as the merged upstream baseline",
            '-m', "$($convention.CommitTrailer): $($BaselineRelease.Tag)`n$($convention.BaselineTrailer): $($BaselineRelease.Tag)",
            (Get-UpstreamTagRef -Tag $BaselineRelease.Tag)
        ) | Out-Null
        $baselineRecorded = $true
    }

    Write-Host "Merging upstream $($TargetRelease.Tag)."
    $targetCommit = Resolve-UpstreamTagCommit -Tag $TargetRelease.Tag
    Invoke-Git -Arguments @('merge', '--no-ff', '--no-commit', (Get-UpstreamTagRef -Tag $TargetRelease.Tag)) -AllowFailure | Out-Null
    $mergeExitCode = $LASTEXITCODE

    $allConflicts = Get-MergeConflict
    if ($mergeExitCode -ne 0 -and $allConflicts.Count -eq 0) {
        throw "Merging upstream $($TargetRelease.Tag) failed for a reason other than conflicts (git exit code $mergeExitCode)."
    }
    # Write-UpstreamTrackingState settles the state file, so it is not reported to reviewers.
    $conflicts = @($allConflicts | Where-Object Path -NE $convention.StateFilePath)

    Write-UpstreamTrackingState -UpstreamRepository $UpstreamRepository -Release $TargetRelease -Commit $targetCommit

    # Without MERGE_HEAD the branch already contained the target ("Already up to date").
    $mergeInProgress = Test-GitMergeInProgress
    if (-not $mergeInProgress -and -not (Test-GitStagedChange)) {
        # Unreachable through Invoke-UpstreamReleaseTracking, which stops when the base
        # branch already contains and records the target; guarded so it fails clearly.
        throw "The branch already contains upstream $($TargetRelease.Tag) and records it in $($convention.StateFilePath); there is nothing to propose."
    }

    $paragraphs = [System.Collections.Generic.List[string]]::new()
    if ($mergeInProgress) {
        $paragraphs.Add("Merge $UpstreamRepository $($TargetRelease.Tag)")
    }
    else {
        $paragraphs.Add("Record $UpstreamRepository $($TargetRelease.Tag) in $($convention.StateFilePath)")
    }
    if ($conflicts.Count -gt 0) {
        # Staging a conflicted path marks it resolved with its current content, markers included.
        Invoke-GitWithFileInput -Arguments @('add', '--all', '--pathspec-file-nul') -FileOption '--pathspec-from-file' `
            -Content (@($conflicts.Path) -join "`0") | Out-Null
        $paragraphs.Add("Unresolved conflicts are committed with conflict markers:`n" + (($conflicts | ForEach-Object { "- $($_.Path)" }) -join "`n"))
    }
    # Git reads trailers from the last paragraph only.
    $paragraphs.Add("$($convention.CommitTrailer): $($TargetRelease.Tag)")

    # The conflict list can be too long for the command line, so the message goes in a file.
    Invoke-GitWithFileInput -Arguments @('commit', '--no-edit') -FileOption '--file' -Content ($paragraphs -join "`n`n") | Out-Null

    [pscustomobject]@{
        Conflicts        = $conflicts
        BaselineRecorded = $baselineRecorded
        BaselineTag      = $BaselineRelease.Tag
    }
}

function Get-UpdateBranchCommit {
    <#
    .SYNOPSIS
        Lists the commits on an update branch's first-parent line that the base branch lacks.
    .DESCRIPTION
        Only the first-parent line is read: the upstream commits a merge brings in are not
        commits made on the branch. The baseline trailer described at the top of this
        section is read from each commit.
    .OUTPUTS
        [pscustomobject] per commit, newest first, with Sha and BaselineTag (the baseline it
        recorded, or $null).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$BaseRef,

        [Parameter(Mandatory)]
        [string]$Head
    )

    $convention = Get-UpstreamTrackingConvention
    $baselinePattern = "(?m)^$([regex]::Escape($convention.BaselineTrailer)): (?<tag>\S+)"

    # Unit and record separators cannot occur in a commit message written by git tooling.
    $log = (Invoke-Git -Arguments @('log', '--first-parent', '--format=%H%x1f%B%x1e', "$BaseRef..$Head")) -join "`n"
    $commits = foreach ($record in $log -split "`u{1e}") {
        $fields = $record.Trim() -split "`u{1f}", 2
        if ($fields.Count -lt 2) {
            continue
        }
        $baselineMatch = [regex]::Match($fields[1], $baselinePattern)
        [pscustomobject]@{
            Sha         = $fields[0]
            BaselineTag = if ($baselineMatch.Success) { $baselineMatch.Groups['tag'].Value } else { $null }
        }
    }

    return $commits
}

function Get-ForkDifference {
    <#
    .SYNOPSIS
        Lists every file in which Ref differs from the exact upstream release.
    .DESCRIPTION
        This is the mechanical inventory for the pull request's Fork comparison section.
        The state file is excluded because it exists only in the fork by design. Renames are
        reported as an add and a delete so each path is classified on its own.
    .OUTPUTS
        [pscustomobject] per file with Status ('A', 'M' or 'D') and Path, sorted by path.
        A type change (for example a file replaced by a symbolic link) is reported as 'M'.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string]$UpstreamTag,

        [string]$Ref = 'HEAD'
    )

    $statePath = (Get-UpstreamTrackingConvention).StateFilePath
    $diffLines = Invoke-Git -Arguments @('diff', '--name-status', '--no-renames', (Get-UpstreamTagRef -Tag $UpstreamTag), $Ref)
    $differences = foreach ($line in $diffLines) {
        # The pattern also skips any warning git writes to stderr, which is merged into the output.
        if ($line -notmatch "^(?<status>[ADMT])`t(?<path>.+)$" -or $Matches.path -eq $statePath) {
            continue
        }
        $status = if ($Matches.status -eq 'T') { 'M' } else { $Matches.status }
        [pscustomobject]@{ Status = $status; Path = $Matches.path }
    }

    return , @($differences | Sort-Object Path)
}

#endregion

#region 6. Pull-request content

function ConvertTo-UpstreamTrackingMarker {
    <#
    .SYNOPSIS
        Serialises the marker that lets later runs recognise this automation's pull request.
    .DESCRIPTION
        Each adapter decides where the marker is stored, and stores it last, so a pull request
        with a marker was published completely.
    .PARAMETER Baseline
        The release the base branch contained when the pull request was built. A later run
        uses it when the base branch alone cannot name its release (see
        Resolve-CurrentUpstreamRelease).
    .PARAMETER ContentHash
        Get-PullRequestTextHash of the title and description as published, so a later run
        can tell whether people have edited them.
    .PARAMETER Head
        The commit the update branch pointed to when the pull request was published, so a
        later run can tell whether people have pushed to it, even an amended commit.
    .PARAMETER SupersededBy
        Set when the automation closes the pull request because a pull request for this newer
        release replaced it, so the closure is not taken for a maintainer declining the release.
    .OUTPUTS
        Compact JSON such as {"baseline":"v1.20.0","contentHash":"9F86D0...","head":"1A2B3C..."}.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Baseline,

        [Parameter(Mandatory)]
        [string]$ContentHash,

        [Parameter(Mandatory)]
        [string]$Head,

        [string]$SupersededBy
    )

    $marker = [ordered]@{ baseline = $Baseline; contentHash = $ContentHash; head = $Head }
    if (-not [string]::IsNullOrEmpty($SupersededBy)) {
        $marker.supersededBy = $SupersededBy
    }
    return $marker | ConvertTo-Json -Compress
}

function ConvertFrom-UpstreamTrackingMarker {
    <#
    .SYNOPSIS
        Parses marker JSON written by ConvertTo-UpstreamTrackingMarker.
    .OUTPUTS
        [pscustomobject] with baseline, contentHash, head and supersededBy (an empty string
        when it was not set), or $null when the JSON is missing, malformed or lacks baseline,
        contentHash or head (for example after a person edited it).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Json
    )

    if ([string]::IsNullOrWhiteSpace($Json)) {
        return $null
    }
    try {
        $marker = $Json | ConvertFrom-Json
    }
    catch {
        return $null
    }
    if (-not ($marker -is [pscustomobject])) {
        return $null
    }
    foreach ($required in 'baseline', 'contentHash', 'head') {
        if ($null -eq $marker.PSObject.Properties[$required]) {
            return $null
        }
    }
    $supersededBy = $marker.PSObject.Properties['supersededBy']
    return [pscustomobject]@{
        baseline     = [string]$marker.baseline
        contentHash  = [string]$marker.contentHash
        head         = [string]$marker.head
        supersededBy = if ($null -ne $supersededBy) { [string]$supersededBy.Value } else { '' }
    }
}

function Get-PullRequestTextHash {
    <#
    .SYNOPSIS
        Fingerprints a pull request's title and description, to detect edits made by people.
    .DESCRIPTION
        Line endings and surrounding white space are normalised first, because the
        platforms and their web editors do not preserve them exactly.
    .OUTPUTS
        [string] SHA-256 as upper-case hexadecimal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Title,

        [AllowEmptyString()]
        [AllowNull()]
        [string]$Description
    )

    $normalise = { param($Text) ([string]$Text -replace '\r\n?', "`n").Trim() }
    $text = (& $normalise $Title) + "`n" + (& $normalise $Description)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text)))
}

function Format-Quantity {
    <#
    .SYNOPSIS
        Formats a count with the singular or plural noun, for example '1 file' or '3 files'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [int]$Count,

        [Parameter(Mandatory)]
        [string]$Singular,

        [string]$Plural = "${Singular}s"
    )

    $noun = if ($Count -eq 1) { $Singular } else { $Plural }
    return "$Count $noun"
}

function Measure-LinesWithinBudget {
    <#
    .SYNOPSIS
        Counts how many leading lines fit in a character budget, line breaks included.
    .DESCRIPTION
        Used for the generated lists in a description, which grow with the size of an
        update, so that a large update still produces a description the platform accepts.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Lines,

        [Parameter(Mandatory)]
        [int]$Budget
    )

    $used = 0
    $count = 0
    foreach ($line in $Lines) {
        $used += $line.Length + 1
        if ($used -gt $Budget) {
            break
        }
        $count++
    }
    return $count
}

function Format-ReleaseNoteList {
    <#
    .SYNOPSIS
        Renders links to the notes of each release in an update, oldest first.
    .DESCRIPTION
        When the list exceeds the ReleaseNotesBudget convention, the newest releases are
        listed and a final line links to the upstream's releases page for the rest.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$UpstreamRepository,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Releases
    )

    $lines = @($Releases | ForEach-Object {
            $kind = if ($_.IsPrerelease) { ' (prerelease)' } else { '' }
            "- [$($_.Tag)]($($_.NotesUrl))$kind"
        })

    # Counted from the newest release, which matters most to reviewers.
    [array]::Reverse($lines)
    $listedCount = Measure-LinesWithinBudget -Lines $lines -Budget (Get-UpstreamTrackingConvention).ReleaseNotesBudget
    $listed = @($lines | Select-Object -First $listedCount)
    [array]::Reverse($listed)

    if ($listedCount -lt $lines.Count) {
        $listed = @("- $(Format-Quantity -Count ($lines.Count - $listedCount) -Singular 'earlier release') not listed; see [all releases](https://github.com/$UpstreamRepository/releases).") + $listed
    }
    return $listed -join "`n"
}

function Format-ForkDifferenceInventory {
    <#
    .SYNOPSIS
        Renders fork differences as collapsible Markdown groups, one per top-level folder.
    .DESCRIPTION
        Files at the repository root form their own group. Output stops before it exceeds
        the ForkComparisonBudget convention, with a note on how to list the rest.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Differences,

        [Parameter(Mandatory)]
        [string]$UpstreamTag,

        [Parameter(Mandatory)]
        [string]$BranchName
    )

    if ($Differences.Count -eq 0) {
        return "The fork is identical to upstream ``$UpstreamTag``."
    }

    # Room kept for the closing tags of the group being written and for the overflow note.
    $reserved = 500
    $budget = (Get-UpstreamTrackingConvention).ForkComparisonBudget - $reserved

    $statusText = @{ A = 'Only in the fork'; M = 'Changed in the fork'; D = 'Removed in the fork' }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Compared with the exact upstream ``$UpstreamTag`` tag, $(Format-Quantity -Count $Differences.Count -Singular 'file') differ:")
    $length = $lines[0].Length

    $listedCount = 0
    $isFull = $false
    $groups = $Differences | Group-Object { if ($_.Path.Contains('/')) { $_.Path.Split('/')[0] + '/' } else { '(repository root)' } }
    foreach ($group in $groups) {
        $opening = @('', "<details><summary><code>$($group.Name)</code> - $(Format-Quantity -Count $group.Count -Singular 'file')</summary>", '')
        $openingLength = ($opening | Measure-Object -Property Length -Sum).Sum + $opening.Count
        if ($length + $openingLength -gt $budget) {
            break
        }
        $lines.AddRange([string[]]$opening)
        $length += $openingLength

        foreach ($difference in $group.Group) {
            $line = "- $($statusText[$difference.Status]): ``$($difference.Path)``"
            if ($length + $line.Length + 1 -gt $budget) {
                $isFull = $true
                break
            }
            $lines.Add($line)
            $length += $line.Length + 1
            $listedCount++
        }
        $lines.Add('')
        $lines.Add('</details>')
        if ($isFull) {
            break
        }
    }

    if ($listedCount -lt $Differences.Count) {
        $lines.Add('')
        $lines.Add("$($Differences.Count - $listedCount) more files are not listed. Run ``git diff --name-status $UpstreamTag origin/$BranchName`` after fetching the upstream tag to see them all.")
    }

    return $lines -join "`n"
}

function Format-CopilotPrompt {
    <#
    .SYNOPSIS
        Renders a prompt for GitHub Copilot as a fenced text block.
    .DESCRIPTION
        A fenced block keeps the prompt's own Markdown, such as inline code, from rendering,
        and GitHub offers a copy button on it. The prompt keeps its line breaks so it
        can be read without scrolling; Copilot reads the pasted lines as one request.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string[]]$Lines
    )

    return "``````text`n$($Lines -join "`n")`n``````"
}

function Format-ConflictTable {
    <#
    .SYNOPSIS
        Renders unresolved conflicts as a Markdown table.
    .DESCRIPTION
        Files are not linked: both platforms list a pull request's files and open them in
        their own web editors. Rows stop before the table exceeds the ConflictTableBudget
        convention, with a note on where every conflict is named.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject[]]$Conflicts
    )

    $rows = foreach ($conflict in $Conflicts) {
        "| ``$($conflict.Path)`` | $($conflict.Description) | $($conflict.Resolution) |"
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('| File | What happened | How to resolve |')
    $lines.Add('| --- | --- | --- |')
    # Room kept for the table header and the overflow note.
    $listedCount = Measure-LinesWithinBudget -Lines @($rows) -Budget ((Get-UpstreamTrackingConvention).ConflictTableBudget - 500)
    $lines.AddRange([string[]]@($rows | Select-Object -First $listedCount))

    if ($listedCount -lt $Conflicts.Count) {
        $lines.Add('')
        $lines.Add("$(Format-Quantity -Count ($Conflicts.Count - $listedCount) -Singular 'more conflicted file') not listed. " +
            'The message of the merge commit on this branch names every conflicted file.')
    }
    return $lines -join "`n"
}

function Get-UpstreamPullRequestContent {
    <#
    .SYNOPSIS
        Builds the pull-request title and description sections shared by both platforms.
    .DESCRIPTION
        Follows the pull-request rules in AGENTS.md: End-user changes, Fork comparison,
        Implementation details and Validation. Sections that need human judgement contain
        placeholders; the Fork comparison section is pre-filled with the mechanical file
        inventory. The audit and any conflicts each come with a prompt that people can give
        GitHub Copilot to do that work on a checkout of the update branch.

        When CurrentRelease and TargetRelease are the same, the pull request only records
        that release in the state file, and the text says so.

        Sections are returned separately because the platforms place them differently: a
        GitHub description holds all of them, while an Azure DevOps description is limited to
        4,000 characters, so the long sections go into a comment there. The generated lists
        are kept within the budgets in Get-UpstreamTrackingConvention.
    .PARAMETER Conflicts
        The conflicts the merge committed (Invoke-UpstreamMerge).
    .PARAMETER BranchName
        The update branch, named in the instructions for listing every fork difference.
    .OUTPUTS
        [pscustomobject] with Title, EndUserChanges, ForkComparison, Conflicts (empty when there
        are none), Implementation, Validation, ConflictCount, DifferenceCount, and the
        TargetTag and BaselineTag from which the adapter builds the marker.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$UpstreamRepository,

        [Parameter(Mandatory)]
        [string]$BaseBranch,

        [Parameter(Mandatory)]
        [string]$BranchName,

        [Parameter(Mandatory)]
        [pscustomobject]$CurrentRelease,

        [Parameter(Mandatory)]
        [pscustomobject]$TargetRelease,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$IncludedReleases,

        [Parameter(Mandatory)]
        [pscustomobject]$MergeResult,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Conflicts,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$ForkDifferences
    )

    $statePath = (Get-UpstreamTrackingConvention).StateFilePath
    $repositoryName = $UpstreamRepository.Split('/')[1]
    $isRecordOnly = $CurrentRelease.Tag -ceq $TargetRelease.Tag

    if ($isRecordOnly) {
        $title = "Record $repositoryName $($TargetRelease.Tag) as the merged upstream release"
        $endUserChanges = @"
## End-user changes

None. ``$BaseBranch`` already contains upstream [$($TargetRelease.Tag)]($($TargetRelease.NotesUrl)); this pull request only records that in ``$statePath`` so that later runs can find the next release without help.
"@
    }
    else {
        $title = "Update $repositoryName from $($CurrentRelease.Tag) to $($TargetRelease.Tag)"
        $endUserChanges = @"
## End-user changes

GitHub release changes from [$($CurrentRelease.Tag)]($($CurrentRelease.NotesUrl)) to [$($TargetRelease.Tag)]($($TargetRelease.NotesUrl)):

- _To do: summarise the release-level user impact from the release notes below._

Release notes included in this update:

$(Format-ReleaseNoteList -UpstreamRepository $UpstreamRepository -Releases $IncludedReleases)
"@
    }

    # Each pending task carries a prompt that people can give GitHub Copilot as it is. The
    # prompts name everything Copilot needs, because it sees the checkout, not this text.
    $upstreamTagFetch = "git fetch --no-tags https://github.com/$UpstreamRepository.git refs/tags/$($TargetRelease.Tag)"
    $forkComparisonPrompt = Format-CopilotPrompt -Lines @(
        "Compare this branch with upstream $UpstreamRepository $($TargetRelease.Tag). Fetch the release with"
        "``$upstreamTagFetch``"
        'and list the differences with `git diff --name-status FETCH_HEAD HEAD`. Classify every'
        'difference as described in the Fork Difference Audit section of AGENTS.md, and write the'
        'result in Markdown as the "Fork comparison" section of the pull request description.'
    )
    $forkComparison = @"
## Fork comparison

> [!NOTE]
> Audit pending. Classify every difference below as described in the Fork Difference Audit
> section of AGENTS.md, then replace this note with the result. GitHub Copilot can do this
> for you: on a checkout of ``$BranchName``, give it this prompt in agent mode in VS Code or
> in Copilot CLI.

$forkComparisonPrompt

$(Format-ForkDifferenceInventory -Differences $ForkDifferences -UpstreamTag $TargetRelease.Tag -BranchName $BranchName)
"@

    $conflictSection = ''
    if ($Conflicts.Count -gt 0) {
        $conflictPrompt = Format-CopilotPrompt -Lines @(
            "This branch merges upstream $UpstreamRepository $($TargetRelease.Tag) into $BaseBranch, and the merge"
            'commit contains conflict markers. Find every file that still has them with'
            '`git grep -l -E "^(<<<<<<<|>>>>>>>) "` and resolve each one: keep the upstream change and'
            "re-apply the fork's behaviour on top of it, through configuration or hooks where possible."
            'Explain each resolution, then run the checks in the Checks section of AGENTS.md.'
        )
        $conflictSection = @"
## Unresolved conflicts

> [!IMPORTANT]
> This draft pull request contains committed conflict markers. Resolve each file below, then
> mark the pull request ready for review. GitHub Copilot can help: on a checkout of
> ``$BranchName``, give it this prompt in agent mode in VS Code or in Copilot CLI, and review
> its changes before you push them.

$conflictPrompt

$(Format-ConflictTable -Conflicts $Conflicts)
"@
    }

    $implementation = [System.Collections.Generic.List[string]]::new()
    if (-not $isRecordOnly) {
        $implementation.Add("- Merged upstream ``$UpstreamRepository`` tag ``$($TargetRelease.Tag)`` into ``$BaseBranch`` with a merge commit.")
    }
    if ($MergeResult.BaselineRecorded) {
        $implementation.Add("- Recorded ``$($MergeResult.BaselineTag)`` as the already-merged upstream baseline. That commit changes no files; it lets git merge only the upstream changes since ``$($MergeResult.BaselineTag)``.")
    }
    $implementation.Add("- Updated ``$statePath`` to record ``$($TargetRelease.Tag)``.")

    [pscustomobject]@{
        Title           = $title
        EndUserChanges  = $endUserChanges
        ForkComparison  = $forkComparison
        Conflicts       = $conflictSection
        Implementation  = "## Implementation details`n`n$($implementation -join "`n")"
        Validation      = "## Validation`n`n- _To do: record the results of ``./scripts/Test-PowerShell.ps1``, ``./.github/scripts/test-documentation.ps1`` and ``git diff --check``._"
        ConflictCount   = $Conflicts.Count
        DifferenceCount = $ForkDifferences.Count
        TargetTag       = $TargetRelease.Tag
        BaselineTag     = $CurrentRelease.Tag
    }
}

#endregion

#region 7. Fork platform interface

<#
    The engine reaches the fork's hosting platform only through the functions in this region.
    Each one dispatches on $Fork.Platform to the adapter function of the same purpose, so the
    complete contract an adapter must fulfil is visible here in one place.

    $Fork is created by New-GitHubForkContext or New-AzureDevOpsForkContext and always has
    Platform and DisplayName properties; the rest is adapter-specific.

    Pull-request objects returned by Find-ForkPullRequest are normalised to:
      Number       [int]
      Url          [string]  web URL
      BranchName   [string]  the update branch, without refs/heads/
      Tag          [string]  the release the branch name proposes (Get-UpdateBranchTag)
      IsMerged     [bool]    only meaningful for closed pull requests
      Marker       [pscustomobject] from ConvertFrom-UpstreamTrackingMarker, or $null
      Title        [string]
      Description  [string]  as people see it, without the marker; open pull requests only
#>

function Get-ForkGitAuthorization {
    <#
    .SYNOPSIS
        Returns the git Authorization header value for fetching from and pushing to the fork.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Fork
    )

    switch ($Fork.Platform) {
        'GitHub' { return Get-GitHubGitAuthorization }
        'AzureDevOps' { return Get-AzureDevOpsGitAuthorization }
        default { throw "Unknown fork platform '$($Fork.Platform)'." }
    }
}

function Find-ForkPullRequest {
    <#
    .SYNOPSIS
        Finds update pull requests from the fork's own update branches into the base branch.
    .PARAMETER BaseBranch
        Only the pull requests into this branch. Without it, pull requests into any branch,
        for example one retargeted by a person or opened before the base branch was changed.
    .PARAMETER State
        'open' for the pull requests in progress; 'closed' (merged or not) to detect declined releases.
    .PARAMETER Tag
        Only the pull requests from this release's update branch. Without it, every pull
        request from a branch under the UpdateBranchPrefix convention.
    .OUTPUTS
        Normalised pull-request objects, newest first; see the comment at the top of this region.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Fork,

        [string]$BaseBranch,

        [Parameter(Mandatory)]
        [ValidateSet('open', 'closed')]
        [string]$State,

        [string]$Tag
    )

    switch ($Fork.Platform) {
        'GitHub' { return Find-GitHubPullRequest -Fork $Fork -BaseBranch $BaseBranch -State $State -Tag $Tag }
        'AzureDevOps' { return Find-AzureDevOpsPullRequest -Fork $Fork -BaseBranch $BaseBranch -State $State -Tag $Tag }
        default { throw "Unknown fork platform '$($Fork.Platform)'." }
    }
}

function Test-ForkPullRequestActivity {
    <#
    .SYNOPSIS
        Tells whether people have commented on or reviewed a pull request.
    .DESCRIPTION
        Activity by bots (for example an automated reviewer) and by this automation does not
        count. Commits and edits are checked by the engine; see
        Get-UpstreamPullRequestEngagement.
    .OUTPUTS
        [string] describing the activity found, such as 'it has a review', or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Fork,

        [Parameter(Mandatory)]
        [pscustomobject]$PullRequest
    )

    switch ($Fork.Platform) {
        'GitHub' { return Test-GitHubPullRequestActivity -Fork $Fork -PullRequest $PullRequest }
        'AzureDevOps' { return Test-AzureDevOpsPullRequestActivity -Fork $Fork -PullRequest $PullRequest }
        default { throw "Unknown fork platform '$($Fork.Platform)'." }
    }
}

function Add-ForkPullRequestComment {
    <#
    .SYNOPSIS
        Posts a Markdown comment on a pull request.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Fork,

        [Parameter(Mandatory)]
        [pscustomobject]$PullRequest,

        [Parameter(Mandatory)]
        [string]$Comment
    )

    switch ($Fork.Platform) {
        'GitHub' { Add-GitHubPullRequestComment -Fork $Fork -PullRequest $PullRequest -Comment $Comment }
        'AzureDevOps' { Add-AzureDevOpsPullRequestComment -Fork $Fork -PullRequest $PullRequest -Comment $Comment }
        default { throw "Unknown fork platform '$($Fork.Platform)'." }
    }
}

function Get-ForkPullRequestComment {
    <#
    .SYNOPSIS
        Returns the text of every comment on a pull request, whoever wrote it.
    .DESCRIPTION
        Lets the engine tell whether it already posted a comment, so that a run repeating
        the work of a failed one does not post it twice.
    .OUTPUTS
        [string] per comment.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Fork,

        [Parameter(Mandatory)]
        [pscustomobject]$PullRequest
    )

    switch ($Fork.Platform) {
        'GitHub' { return Get-GitHubPullRequestComment -Fork $Fork -PullRequest $PullRequest }
        'AzureDevOps' { return Get-AzureDevOpsPullRequestComment -Fork $Fork -PullRequest $PullRequest }
        default { throw "Unknown fork platform '$($Fork.Platform)'." }
    }
}

function Set-ForkPullRequestMarker {
    <#
    .SYNOPSIS
        Replaces the marker of an open pull request, leaving everything people see unchanged.
    .DESCRIPTION
        Used to record supersededBy before a replaced pull request is closed, and to restore
        the previous marker when it must stay open after all.
    .PARAMETER PullRequest
        A normalised pull-request object read from Find-ForkPullRequest just before, because
        an adapter that keeps the marker in the description (GitHub) writes Description back.
    .PARAMETER Marker
        Marker JSON (ConvertTo-UpstreamTrackingMarker).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Fork,

        [Parameter(Mandatory)]
        [pscustomobject]$PullRequest,

        [Parameter(Mandatory)]
        [string]$Marker
    )

    if (-not $PSCmdlet.ShouldProcess($PullRequest.Url, 'Set upstream tracking marker')) {
        return
    }
    switch ($Fork.Platform) {
        'GitHub' { Set-GitHubPullRequestMarker -Fork $Fork -PullRequest $PullRequest -Marker $Marker }
        'AzureDevOps' { Set-AzureDevOpsPullRequestMarker -Fork $Fork -PullRequestId $PullRequest.Number -Marker $Marker }
        default { throw "Unknown fork platform '$($Fork.Platform)'." }
    }
}

function Close-ForkPullRequest {
    <#
    .SYNOPSIS
        Posts Comment on a replaced pull request, then closes (abandons) it without merging.
    .DESCRIPTION
        The engine has already recorded the replacement in the marker and deleted the branch
        (see Close-UntouchedUpstreamPullRequest). Deleting the branch can make the platform
        close the pull request itself, as GitHub does, so an adapter must still post Comment
        and must not fail when the pull request is already closed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Fork,

        [Parameter(Mandatory)]
        [pscustomobject]$PullRequest,

        [Parameter(Mandatory)]
        [string]$Comment
    )

    if (-not $PSCmdlet.ShouldProcess($PullRequest.Url, 'Close replaced pull request')) {
        return
    }
    switch ($Fork.Platform) {
        'GitHub' { Close-GitHubPullRequest -Fork $Fork -PullRequest $PullRequest -Comment $Comment }
        'AzureDevOps' { Close-AzureDevOpsPullRequest -Fork $Fork -PullRequest $PullRequest -Comment $Comment }
        default { throw "Unknown fork platform '$($Fork.Platform)'." }
    }
}

function Assert-ForkPushAllowed {
    <#
    .SYNOPSIS
        Throws, with setup guidance, when the fork's credential cannot push the given changes.
    .DESCRIPTION
        Runs before pushing so that a predictable rejection becomes an actionable message.
    .PARAMETER ChangedPaths
        Paths the update branch changes relative to the base branch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Fork,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$ChangedPaths
    )

    switch ($Fork.Platform) {
        'GitHub' { Assert-GitHubPushAllowed -Fork $Fork -ChangedPaths $ChangedPaths }
        # Azure Repos applies no path-based push restriction to the build service.
        'AzureDevOps' { }
        default { throw "Unknown fork platform '$($Fork.Platform)'." }
    }
}

function Get-ForkCurrentTagInstruction {
    <#
    .SYNOPSIS
        Returns one sentence telling a maintainer how to rerun with the current release set.
    .DESCRIPTION
        Used in the error raised when the release the fork contains cannot be worked out.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Fork
    )

    switch ($Fork.Platform) {
        'GitHub' { return Get-GitHubCurrentTagInstruction }
        'AzureDevOps' { return Get-AzureDevOpsCurrentTagInstruction }
        default { throw "Unknown fork platform '$($Fork.Platform)'." }
    }
}

function Publish-ForkPullRequest {
    <#
    .SYNOPSIS
        Creates the update pull request from the shared content.
    .DESCRIPTION
        A pull request is created once and never changed by later runs; a newer release gets
        a new pull request (see section 9).

        Every adapter must: label the pull request; create it as a draft when there are
        conflicts; and store a marker (ConvertTo-UpstreamTrackingMarker, with
        Content.BaselineTag, Head, and the Get-PullRequestTextHash of the title and
        description exactly as published) where Find-ForkPullRequest reads it back. The
        marker must be stored after every other change succeeds, so that a pull request with
        a marker was published completely.
    .PARAMETER Head
        The commit pushed to BranchName, recorded in the marker.
    .OUTPUTS
        [pscustomobject] with Number and Url.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Fork,

        [Parameter(Mandatory)]
        [string]$BaseBranch,

        [Parameter(Mandatory)]
        [string]$BranchName,

        [Parameter(Mandatory)]
        [string]$Head,

        [Parameter(Mandatory)]
        [pscustomobject]$Content
    )

    $publish = @{ Fork = $Fork; BaseBranch = $BaseBranch; BranchName = $BranchName; Head = $Head; Content = $Content }
    switch ($Fork.Platform) {
        'GitHub' { return Publish-GitHubPullRequest @publish }
        'AzureDevOps' { return Publish-AzureDevOpsPullRequest @publish }
        default { throw "Unknown fork platform '$($Fork.Platform)'." }
    }
}

#endregion

#region 8. Run reporting

function Add-TrackingSummary {
    <#
    .SYNOPSIS
        Writes the run's outcome to the console and to the pipeline's run summary.
    .DESCRIPTION
        GitHub Actions shows lines appended to GITHUB_STEP_SUMMARY. Azure Pipelines shows a
        Markdown file uploaded with the task.uploadsummary logging command. Each run reports
        exactly one outcome, so each call produces one summary entry.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-Host $Message
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
        Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $Message -Encoding utf8
    }
    elseif ($env:TF_BUILD -eq 'True' -and -not [string]::IsNullOrWhiteSpace($env:AGENT_TEMPDIRECTORY)) {
        $summaryPath = Join-Path $env:AGENT_TEMPDIRECTORY "upstream-release-$([guid]::NewGuid().ToString('N')).md"
        Set-Content -LiteralPath $summaryPath -Value $Message -Encoding utf8
        Write-Host "##vso[task.uploadsummary]$summaryPath"
    }
}

#endregion

#region 9. Orchestration

<#
    One pull request per release. Each update branch is named after the release it proposes
    (Get-UpdateBranchName), and its pull request is never changed after it is opened, so
    nothing a reviewer did is overwritten.

    When a newer release is proposed, every open update pull request for an older release is
    either:
      - closed, with its branch deleted, when nobody has worked on it; or
      - left open, with a comment linking the new pull request, when people have, because
        their commits, edits, comments or reviews would otherwise be lost. A maintainer
        merges it first or closes it.
    Get-UpstreamPullRequestEngagement decides which. Pull requests for newer releases, such
    as a prerelease requested by hand, are left alone.

    People can keep working while a run builds the new pull request, so each pull request is
    read again just before it is replaced (Get-LatestUpstreamPullRequest), and its branch is
    deleted with a lease on the commit it was published with before it is closed
    (Close-UntouchedUpstreamPullRequest). An edit or a push made at any point therefore
    keeps the pull request open.
#>

function Get-FetchedUpdateBranchHead {
    <#
    .SYNOPSIS
        Returns the commit an update branch pointed to when this run fetched it.
    .OUTPUTS
        [string] commit ID, or $null when the branch did not exist.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$BranchName
    )

    $head = Invoke-Git -Arguments @('rev-parse', '--verify', '--quiet', "refs/remotes/origin/$BranchName") -AllowFailure |
        Select-Object -First 1
    if ([string]::IsNullOrEmpty($head)) {
        return $null
    }
    return $head
}

function Remove-UpdateBranch {
    <#
    .SYNOPSIS
        Deletes an update branch from the fork, unless it no longer points to the expected commit.
    .DESCRIPTION
        The deletion is a push whose lease names ExpectedHead, so the fork refuses it when
        someone pushed to the branch since then, and their commit survives. Both platforms
        need the same permission for this as for the force push that replaces a branch.
    .OUTPUTS
        [bool] whether the branch was deleted.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$ForkAuthorization,

        [Parameter(Mandatory)]
        [string]$BranchName,

        [Parameter(Mandatory)]
        [string]$ExpectedHead
    )

    if (-not $PSCmdlet.ShouldProcess($BranchName, 'Delete update branch')) {
        return $false
    }
    $output = Invoke-AuthenticatedGit -Authorization $ForkAuthorization -AllowFailure -Arguments @(
        'push', "--force-with-lease=refs/heads/${BranchName}:$ExpectedHead", '--delete', 'origin', "refs/heads/$BranchName"
    )
    if ($LASTEXITCODE -eq 0) {
        return $true
    }
    Write-Warning "Kept branch '$BranchName', which no longer points to $ExpectedHead or could not be deleted:`n$($output -join "`n")"
    return $false
}

function Select-OlderUpstreamPullRequest {
    <#
    .SYNOPSIS
        Picks the pull requests that propose a release older than Than.
    .DESCRIPTION
        A pull request for a release deleted upstream cannot be compared, so it is left out.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$PullRequests,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Releases,

        [Parameter(Mandatory)]
        [pscustomobject]$Than
    )

    foreach ($pullRequest in $PullRequests) {
        $release = $Releases | Where-Object Tag -CEQ $pullRequest.Tag | Select-Object -First 1
        if ($null -ne $release -and (Compare-UpstreamRelease -Left $release -Right $Than) -lt 0) {
            $pullRequest
        }
    }
}

function Get-UpstreamPullRequestEngagement {
    <#
    .SYNOPSIS
        Tells whether people have worked on an update pull request, and so whether it must be kept.
    .DESCRIPTION
        Checks, cheapest first, for: a missing marker (edits cannot then be ruled out, so the
        pull request is kept); an edited title or description (the marker's content hash); a
        branch that no longer points to the commit it was published with (the marker's head),
        which catches added commits, amended ones and force pushes alike; and comments or
        reviews by people (Test-ForkPullRequestActivity).

        The branch is judged as this run fetched it. A push made after the fetch is caught
        later, by the lease with which Close-UntouchedUpstreamPullRequest deletes the branch.
    .PARAMETER PullRequest
        A normalised pull-request object, ideally read again just before (Get-LatestUpstreamPullRequest).
    .OUTPUTS
        [string] completing "it was left open because ...", or $null when nobody worked on it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Fork,

        [Parameter(Mandatory)]
        [pscustomobject]$PullRequest
    )

    if ($null -eq $PullRequest.Marker) {
        return 'its tracking marker is missing, so edits by people cannot be ruled out'
    }
    $hash = Get-PullRequestTextHash -Title $PullRequest.Title -Description $PullRequest.Description
    if ($hash -cne $PullRequest.Marker.contentHash) {
        return 'its title or description was edited'
    }

    $branchHead = Get-FetchedUpdateBranchHead -BranchName $PullRequest.BranchName
    if ($null -eq $branchHead) {
        return "its branch '$($PullRequest.BranchName)' could not be read"
    }
    if ($branchHead -cne $PullRequest.Marker.head) {
        return 'its branch changed after it was opened'
    }

    return Test-ForkPullRequestActivity -Fork $Fork -PullRequest $PullRequest
}

function Get-LatestUpstreamPullRequest {
    <#
    .SYNOPSIS
        Reads an update pull request again, to judge it as it is now rather than at the start of the run.
    .DESCRIPTION
        Building a replacement takes a while, during which people may edit, review or close
        the pull request. Reading it again just before acting keeps that window small.
    .OUTPUTS
        The refreshed normalised pull-request object, or $null when it is no longer open.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Fork,

        [Parameter(Mandatory)]
        [string]$BaseBranch,

        [Parameter(Mandatory)]
        [pscustomobject]$PullRequest
    )

    return Find-ForkPullRequest -Fork $Fork -BaseBranch $BaseBranch -State open -Tag $PullRequest.Tag |
        Where-Object Number -EQ $PullRequest.Number |
        Select-Object -First 1
}

function Close-UntouchedUpstreamPullRequest {
    <#
    .SYNOPSIS
        Closes a replaced pull request that nobody worked on, unless its branch changes meanwhile.
    .DESCRIPTION
        The steps are ordered so that a commit pushed at any moment survives, and the pull
        request it belongs to stays open:
          1. The marker records SupersededBy, so the closure is not later taken for a
             declined release (Test-UpstreamReleaseDeclined).
          2. The branch is deleted with a lease on the commit it was published with
             (Remove-UpdateBranch). The fork refuses the deletion if anyone pushed since.
          3. Only then is Comment posted and the pull request closed.
        When step 2 is refused, the original marker is put back and the pull request is left
        open, so the run reports it as changed during this run.
    .PARAMETER PullRequest
        A refreshed pull request (Get-LatestUpstreamPullRequest) that
        Get-UpstreamPullRequestEngagement found untouched.
    .OUTPUTS
        [bool] whether the pull request was closed.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Fork,

        [Parameter(Mandatory)]
        [string]$ForkAuthorization,

        [Parameter(Mandatory)]
        [pscustomobject]$PullRequest,

        [Parameter(Mandatory)]
        [string]$SupersededBy,

        [Parameter(Mandatory)]
        [string]$Comment
    )

    $marker = $PullRequest.Marker
    $supersededMarker = ConvertTo-UpstreamTrackingMarker -Baseline $marker.baseline -ContentHash $marker.contentHash `
        -Head $marker.head -SupersededBy $SupersededBy
    Set-ForkPullRequestMarker -Fork $Fork -PullRequest $PullRequest -Marker $supersededMarker

    if (-not (Remove-UpdateBranch -ForkAuthorization $ForkAuthorization -BranchName $PullRequest.BranchName -ExpectedHead $marker.head)) {
        # Restored as it was, including a SupersededBy left by an earlier run that failed here too.
        $restore = @{ Baseline = $marker.baseline; ContentHash = $marker.contentHash; Head = $marker.head }
        if (-not [string]::IsNullOrEmpty($marker.supersededBy)) {
            $restore.SupersededBy = $marker.supersededBy
        }
        Set-ForkPullRequestMarker -Fork $Fork -PullRequest $PullRequest -Marker (ConvertTo-UpstreamTrackingMarker @restore)
        return $false
    }

    Close-ForkPullRequest -Fork $Fork -PullRequest $PullRequest -Comment $Comment
    return $true
}

function Test-InterruptedUpstreamPullRequestClose {
    <#
    .SYNOPSIS
        Tells whether a run deleted the pull request's branch but failed before closing it.
    .DESCRIPTION
        Close-UntouchedUpstreamPullRequest records SupersededBy and deletes the branch before
        it closes the pull request. Such a pull request was found untouched then, and its
        branch can no longer be judged, so it only remains to close it.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$PullRequest
    )

    return $null -ne $PullRequest.Marker -and
        -not [string]::IsNullOrEmpty($PullRequest.Marker.supersededBy) -and
        $null -eq (Get-FetchedUpdateBranchHead -BranchName $PullRequest.BranchName)
}

function Close-ReplacedUpstreamPullRequest {
    <#
    .SYNOPSIS
        Closes the update pull requests that a newer one replaces, unless people worked on them.
    .DESCRIPTION
        Each pull request is read again first (Get-LatestUpstreamPullRequest) and skipped if
        it is no longer open. An untouched one is closed with its branch deleted
        (Close-UntouchedUpstreamPullRequest).

        One people worked on is left open with a comment linking the replacement. The comment
        is only posted when no comment on the pull request links the replacement yet, so a
        run that repeats the work of a failed one neither skips nor repeats it.

        A pull request that Test-InterruptedUpstreamPullRequestClose finds was being closed
        by a run that failed is closed without further checks.
    .PARAMETER PullRequests
        The open update pull requests for releases older than Replacement's.
    .PARAMETER Replacement
        The pull request that replaces them, with Tag and Url.
    .OUTPUTS
        [string] one sentence per pull request closed or left open, for the run summary.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Fork,

        [Parameter(Mandatory)]
        [string]$ForkAuthorization,

        [Parameter(Mandatory)]
        [string]$BaseBranch,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$PullRequests,

        [Parameter(Mandatory)]
        [pscustomobject]$Replacement
    )

    $closedComment = "Replaced by $($Replacement.Url), which proposes upstream $($Replacement.Tag). " +
        'Nobody had worked on this pull request, so it was closed.'
    foreach ($snapshot in $PullRequests) {
        $pullRequest = Get-LatestUpstreamPullRequest -Fork $Fork -BaseBranch $BaseBranch -PullRequest $snapshot
        if ($null -eq $pullRequest) {
            continue
        }
        $closedSentence = "Closed $($pullRequest.Url) (upstream $($pullRequest.Tag)), which it replaces, and deleted its branch."

        if (Test-InterruptedUpstreamPullRequestClose -PullRequest $pullRequest) {
            Close-ForkPullRequest -Fork $Fork -PullRequest $pullRequest -Comment $closedComment
            $closedSentence
            continue
        }

        $engagement = Get-UpstreamPullRequestEngagement -Fork $Fork -PullRequest $pullRequest
        if ($null -eq $engagement) {
            $closed = Close-UntouchedUpstreamPullRequest -Fork $Fork -ForkAuthorization $ForkAuthorization -PullRequest $pullRequest `
                -SupersededBy $Replacement.Tag -Comment $closedComment
            if ($closed) {
                $closedSentence
                continue
            }
            $engagement = 'its branch changed during this run'
        }

        # (?!\d) stops the URL of pull request 4 matching inside that of pull request 42.
        $alreadyNotified = @(Get-ForkPullRequestComment -Fork $Fork -PullRequest $pullRequest) -match ([regex]::Escape($Replacement.Url) + '(?!\d)')
        if ($alreadyNotified.Count -eq 0) {
            $comment = "Upstream $($Replacement.Tag) is now proposed in $($Replacement.Url). " +
                "This pull request was left open because $engagement; merge or close it when you are done with it."
            Add-ForkPullRequestComment -Fork $Fork -PullRequest $pullRequest -Comment $comment | Out-Null
        }
        "Left $($pullRequest.Url) (upstream $($pullRequest.Tag)) open because $engagement."
    }
}

function Select-OpenUpstreamPullRequest {
    <#
    .SYNOPSIS
        Picks the open update pull request that already covers a release, if any.
    .PARAMETER AllowNewer
        Also accept a pull request that proposes a newer release than Target; the newest wins.
    .OUTPUTS
        A normalised pull-request object, or $null.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$PullRequests,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Releases,

        [Parameter(Mandatory)]
        [pscustomobject]$Target,

        [switch]$AllowNewer
    )

    $selected = $null
    $selectedRelease = $null
    foreach ($pullRequest in $PullRequests) {
        # A pull request for a release deleted upstream cannot be compared, so it is ignored.
        $release = $Releases | Where-Object Tag -CEQ $pullRequest.Tag | Select-Object -First 1
        if ($null -eq $release) {
            continue
        }
        $comparison = Compare-UpstreamRelease -Left $release -Right $Target
        $covers = $comparison -eq 0 -or ($AllowNewer -and $comparison -gt 0)
        if ($covers -and ($null -eq $selectedRelease -or (Compare-UpstreamRelease -Left $release -Right $selectedRelease) -gt 0)) {
            $selected = $pullRequest
            $selectedRelease = $release
        }
    }
    return $selected
}

function Complete-AlreadyOpenRun {
    <#
    .SYNOPSIS
        Ends a run whose release already has an open pull request.
    .DESCRIPTION
        Still closes the untouched pull requests for older releases, and comments on the
        others, so the work of a run that failed after opening the kept pull request is
        completed. Pull requests for newer releases are left alone here.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Fork,

        [Parameter(Mandatory)]
        [string]$ForkAuthorization,

        [Parameter(Mandatory)]
        [string]$BaseBranch,

        [Parameter(Mandatory)]
        [pscustomobject]$Result,

        [Parameter(Mandatory)]
        [pscustomobject]$PullRequest,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$OpenPullRequests,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Releases,

        [Parameter(Mandatory)]
        [string]$Message,

        [switch]$DryRun
    )

    $sentences = @($Message)
    $keptRelease = $Releases | Where-Object Tag -CEQ $PullRequest.Tag | Select-Object -First 1
    if (-not $DryRun) {
        $older = @(Select-OlderUpstreamPullRequest -PullRequests $OpenPullRequests -Releases $Releases -Than $keptRelease)
        $sentences += @(Close-ReplacedUpstreamPullRequest -Fork $Fork -ForkAuthorization $ForkAuthorization -BaseBranch $BaseBranch `
                -PullRequests $older -Replacement $PullRequest)
    }
    Add-TrackingSummary ($sentences -join ' ')

    $Result.Outcome = 'AlreadyOpen'
    $Result.TargetTag = $PullRequest.Tag
    $Result.PullRequestUrl = $PullRequest.Url
    return $Result
}

function Invoke-UpstreamReleaseTracking {
    <#
    .SYNOPSIS
        Opens a pull request that merges the newest upstream release, replacing older ones.
    .DESCRIPTION
        Runs in a checkout of the fork whose 'origin' remote is the fork itself.

        1. Fetches the base branch, the update branches and every upstream tag.
        2. Chooses the target release. Stops when an open pull request already proposes it
           (or, on a scheduled run, a newer one); works out the release the fork already
           contains; and stops when the fork is up to date or a maintainer declined that
           release, which is checked before a missing baseline is reported. A fork that is
           up to date but whose release was named only by the CurrentTag input gets a pull
           request that records it in the state file instead.
        3. Builds the release's update branch from the base branch. An open pull request for
           the release built from another baseline than the CurrentTag input is closed in
           step 4, or, when people worked on it, the run stops and asks for it to be closed.
           The run also stops when an open pull request into another branch uses the update
           branch, so that its work is never overwritten.
        4. Pushes the branch and opens the pull request. Then closes the older update pull
           requests it replaces, or comments on those people worked on (see the comment at
           the top of this region).

        Expected environment variables:
          GH_TOKEN                        GitHub fork: token for gh and git.
          SYSTEM_ACCESSTOKEN              Azure DevOps fork: job token for REST and git.
          UPSTREAM_READ_TOKEN             Optional: token to read a private upstream.
    .PARAMETER Fork
        From New-GitHubForkContext or New-AzureDevOpsForkContext.
    .PARAMETER UpstreamRemoteUrl
        Git URL of the upstream. Defaults to the github.com URL of UpstreamRepository.
    .PARAMETER DryRun
        Builds the update branch locally and reports what would happen, without pushing or
        calling any API that changes state.
    .OUTPUTS
        [pscustomobject] with Outcome ('Disabled', 'NoRelease', 'UpToDate', 'AlreadyOpen',
        'Declined', 'DryRun' or 'Created'), TargetTag, PullRequestUrl and Conflicts.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
        [string]$UpstreamRepository,

        [Parameter(Mandatory)]
        [pscustomobject]$Fork,

        [Parameter(Mandatory)]
        [string]$BaseBranch,

        [string]$TargetTag,

        [string]$CurrentTag,

        [switch]$IncludePrereleases,

        [switch]$DryRun,

        [string]$UpstreamRemoteUrl
    )

    $convention = Get-UpstreamTrackingConvention
    $baseRef = "refs/remotes/origin/$BaseBranch"
    $updateBranches = "refs/heads/$($convention.UpdateBranchPrefix)*"
    $updateBranchRefs = "refs/remotes/origin/$($convention.UpdateBranchPrefix)*"
    $result = [pscustomobject]@{ Outcome = $null; TargetTag = $null; PullRequestUrl = $null; Conflicts = @() }

    if ($Fork.Platform -eq 'GitHub' -and $Fork.Repository -eq $UpstreamRepository) {
        Add-TrackingSummary "Upstream tracking is disabled: '$($Fork.DisplayName)' is the upstream repository itself."
        $result.Outcome = 'Disabled'
        return $result
    }
    if ([string]::IsNullOrWhiteSpace($UpstreamRemoteUrl)) {
        $UpstreamRemoteUrl = "https://github.com/$UpstreamRepository.git"
    }
    # Pipeline inputs cannot always be empty (Azure Pipelines needs a default), so blanks mean "not set".
    $TargetTag = $TargetTag.Trim()
    $CurrentTag = $CurrentTag.Trim()
    $isScheduled = [string]::IsNullOrEmpty($TargetTag)

    # --- 1. Fetch ---------------------------------------------------------------------------
    Remove-PersistedGitAuthorization
    $forkAuthorization = Get-ForkGitAuthorization -Fork $Fork

    # --prune drops the copies of update branches deleted since an earlier fetch, so a deleted
    # branch is never mistaken for one that still exists.
    Invoke-AuthenticatedGit -Authorization $forkAuthorization -Arguments @(
        'fetch', '--no-tags', '--prune', 'origin', "+refs/heads/${BaseBranch}:$baseRef", "+${updateBranches}:$updateBranchRefs"
    ) | Out-Null

    try {
        Invoke-AuthenticatedGit -Authorization (Get-UpstreamGitAuthorization) -Arguments @(
            'fetch', '--no-tags', '--force', $UpstreamRemoteUrl, "+refs/tags/*:$($convention.UpstreamTagRefRoot)/*"
        ) | Out-Null
    }
    catch {
        throw "Could not fetch tags from '$UpstreamRepository'. A private upstream needs the UPSTREAM_READ_TOKEN secret (or, on GitHub, a GitHub App with UPSTREAM_REPOSITORY_PRIVATE). $($_.Exception.Message)"
    }

    # --- 2. Decide what to merge --------------------------------------------------------------
    $releases = Get-UpstreamRelease -UpstreamRepository $UpstreamRepository -Token (Get-UpstreamApiToken -Fork $Fork)
    $target = Select-TargetUpstreamRelease -Releases $releases -RequestedTag $TargetTag -IncludePrereleases:$IncludePrereleases
    if ($null -eq $target) {
        Add-TrackingSummary "No eligible release was found in '$UpstreamRepository'."
        $result.Outcome = 'NoRelease'
        return $result
    }
    $result.TargetTag = $target.Tag

    # Checked before the current release is resolved, so that scheduled runs keep passing while
    # a bootstrap pull request (created with the CurrentTag input) waits to be merged.
    $openPullRequests = @(Find-ForkPullRequest -Fork $Fork -BaseBranch $BaseBranch -State open)
    $alreadyOpen = @{
        Fork              = $Fork
        ForkAuthorization = $forkAuthorization
        BaseBranch        = $BaseBranch
        Result            = $result
        OpenPullRequests  = $openPullRequests
        Releases          = $releases
        DryRun            = $DryRun
    }
    # A run given the CurrentTag input asks for a pull request built from that baseline, so an
    # open one built from another baseline does not cover its release; it is rebuilt in step 3.
    $coveringPullRequests = @($openPullRequests | Where-Object {
            [string]::IsNullOrEmpty($CurrentTag) -or ($null -ne $_.Marker -and [string]$_.Marker.baseline -ceq $CurrentTag)
        })
    # A scheduled run never proposes an older release than an open pull request does, for
    # example the newest stable release after a prerelease was requested by hand.
    $keptPullRequest = Select-OpenUpstreamPullRequest -PullRequests $coveringPullRequests -Releases $releases -Target $target -AllowNewer:$isScheduled
    if ($null -ne $keptPullRequest) {
        $message = if ($keptPullRequest.Tag -ceq $target.Tag) {
            "Pull request $($keptPullRequest.Url) already proposes upstream $($target.Tag)."
        }
        else {
            "Pull request $($keptPullRequest.Url) already proposes upstream $($keptPullRequest.Tag), which is newer than $($target.Tag); a scheduled run does not propose an older release."
        }
        return Complete-AlreadyOpenRun @alreadyOpen -PullRequest $keptPullRequest -Message $message
    }

    # The baseline a bootstrap pull request recorded, from its marker or, when an earlier run
    # failed before storing the marker, from the oldest baseline commit on its branch. The
    # newest open pull request is the one built from the most recent base branch.
    $pendingBaselineTag = $null
    foreach ($pullRequest in $openPullRequests) {
        if ($null -ne $pullRequest.Marker) {
            $pendingBaselineTag = [string]$pullRequest.Marker.baseline
        }
        else {
            $pullRequestBranchHead = Get-FetchedUpdateBranchHead -BranchName $pullRequest.BranchName
            if ($null -ne $pullRequestBranchHead) {
                $pendingBaselineTag = @(Get-UpdateBranchCommit -BaseRef $baseRef -Head $pullRequestBranchHead |
                        Where-Object { $null -ne $_.BaselineTag }) | Select-Object -Last 1 -ExpandProperty BaselineTag
            }
        }
        if (-not [string]::IsNullOrEmpty($pendingBaselineTag)) {
            break
        }
    }

    # Unknown is allowed for now: a maintainer may have declined the target release, in which
    # case there is nothing to do and no baseline is needed.
    $current = Resolve-CurrentUpstreamRelease -UpstreamRepository $UpstreamRepository -Fork $Fork -Releases $releases `
        -BaseBranch $BaseBranch -BaseRef $baseRef -CurrentTagOverride $CurrentTag -PendingBaselineTag $pendingBaselineTag -AllowUnknown
    if ($null -ne $current -and (Compare-UpstreamRelease -Left $target -Right $current) -le 0) {
        # A fork that is already current but was named by the CurrentTag input may still have
        # nothing that names its release, so the next scheduled run would ask again. A pull
        # request that records the release in the state file settles that once.
        $baseState = Read-UpstreamTrackingState -Ref $baseRef -UpstreamRepository $UpstreamRepository
        $needsRecord = $current.Source -eq 'Override' -and -not ($null -ne $baseState -and [string]$baseState.tag -ceq $current.Tag)
        if (-not $needsRecord) {
            Add-TrackingSummary "'$BaseBranch' already contains upstream $($current.Tag); the newest eligible release is $($target.Tag)."
            $result.Outcome = 'UpToDate'
            return $result
        }
        Write-Host "'$BaseBranch' already contains upstream $($current.Tag); proposing to record it in the state file."
        $target = $current
        $result.TargetTag = $target.Tag

        $keptPullRequest = Select-OpenUpstreamPullRequest -PullRequests $coveringPullRequests -Releases $releases -Target $target
        if ($null -ne $keptPullRequest) {
            return Complete-AlreadyOpenRun @alreadyOpen -PullRequest $keptPullRequest `
                -Message "Pull request $($keptPullRequest.Url) already records upstream $($target.Tag)."
        }
    }

    # A scheduled run respects a maintainer's decision; a run that names the tag overrides it.
    # A pull request this automation closed because a newer one replaced it was not declined.
    if ($isScheduled) {
        $declinedPullRequest = Find-ForkPullRequest -Fork $Fork -BaseBranch $BaseBranch -State closed -Tag $target.Tag |
            Where-Object { -not $_.IsMerged -and ($null -eq $_.Marker -or [string]::IsNullOrEmpty($_.Marker.supersededBy)) } |
            Select-Object -First 1
        if ($null -ne $declinedPullRequest) {
            Add-TrackingSummary "Upstream $($target.Tag) was declined by closing $($declinedPullRequest.Url); run again with target-tag '$($target.Tag)' to propose it anyway."
            $result.Outcome = 'Declined'
            return $result
        }
    }

    if ($null -eq $current) {
        throw (Format-UnknownCurrentReleaseMessage -UpstreamRepository $UpstreamRepository -Fork $Fork `
                -BaseBranch $BaseBranch -BaseRef $baseRef -Releases $releases)
    }

    # --- 3. Build the update branch -------------------------------------------------------------
    $branchName = Get-UpdateBranchName -Tag $target.Tag

    # An open pull request from this branch was built from another baseline than the CurrentTag
    # input names. The new pull request needs its branch, so it is closed before the push, but
    # only when nobody worked on it. It is judged here, to fail before the slow merge, and
    # again in step 4 as it is then.
    $rebuiltPullRequest = $openPullRequests | Where-Object BranchName -CEQ $branchName | Select-Object -First 1
    $refuseRebuild = {
        param([string]$Engagement)
        throw "Pull request $($rebuiltPullRequest.Url) already proposes upstream $($target.Tag) from another baseline, and cannot be rebuilt from upstream $($current.Tag) because $Engagement. Close it, then run again with target-tag '$($target.Tag)' and current-tag '$($current.Tag)'."
    }
    if ($null -ne $rebuiltPullRequest) {
        $engagement = if (-not (Test-InterruptedUpstreamPullRequestClose -PullRequest $rebuiltPullRequest)) {
            Get-UpstreamPullRequestEngagement -Fork $Fork -PullRequest $rebuiltPullRequest
        }
        if ($null -ne $engagement) {
            & $refuseRebuild $engagement
        }
        $openPullRequests = @($openPullRequests | Where-Object BranchName -CNE $branchName)
    }

    # A branch left by an earlier run that failed before opening its pull request, or by a
    # closed pull request (which keeps its own copy of the commits), is replaced. A branch that
    # an open pull request into another branch uses is not: the pull request was retargeted,
    # or opened before the base branch was changed, and people may be working on it there.
    $remoteBranchHead = Get-FetchedUpdateBranchHead -BranchName $branchName
    if ($null -ne $remoteBranchHead) {
        $otherPullRequest = Find-ForkPullRequest -Fork $Fork -State open -Tag $target.Tag |
            Where-Object { $null -eq $rebuiltPullRequest -or $_.Number -ne $rebuiltPullRequest.Number } |
            Select-Object -First 1
        if ($null -ne $otherPullRequest) {
            throw "Branch '$branchName' is used by the open pull request $($otherPullRequest.Url), which is not into '$BaseBranch'. Merge or close it, or retarget it to '$BaseBranch', then run again."
        }
    }

    Write-Host "Building '$branchName' from '$BaseBranch'."
    Invoke-Git -Arguments @('checkout', '--force', '-B', $branchName, $baseRef) | Out-Null
    $mergeResult = Invoke-UpstreamMerge -UpstreamRepository $UpstreamRepository -BaselineRelease $current -TargetRelease $target
    $conflicts = @($mergeResult.Conflicts)
    $result.Conflicts = $conflicts

    $changedPaths = @(Invoke-Git -Arguments @('diff', '--name-only', $baseRef, 'HEAD'))
    Assert-ForkPushAllowed -Fork $Fork -ChangedPaths $changedPaths

    $includedReleases = Get-UpstreamReleaseRange -Releases $releases -Current $current -Target $target -IncludePrereleases:$IncludePrereleases
    $forkDifferences = Get-ForkDifference -UpstreamTag $target.Tag
    $content = Get-UpstreamPullRequestContent -UpstreamRepository $UpstreamRepository -BaseBranch $BaseBranch -BranchName $branchName `
        -CurrentRelease $current -TargetRelease $target -IncludedReleases $includedReleases -MergeResult $mergeResult `
        -Conflicts $conflicts -ForkDifferences $forkDifferences
    $conflictCount = Format-Quantity -Count $content.ConflictCount -Singular 'unresolved conflict'

    if ($DryRun) {
        $rebuildNote = if ($null -ne $rebuiltPullRequest) { "close $($rebuiltPullRequest.Url) and " } else { '' }
        Add-TrackingSummary "Dry run: would ${rebuildNote}open '$($content.Title)' from '$branchName' with $conflictCount and $(Format-Quantity -Count $content.DifferenceCount -Singular 'fork difference')."
        $result.Outcome = 'DryRun'
        return $result
    }

    # --- 4. Publish -----------------------------------------------------------------------------
    if ($null -ne $rebuiltPullRequest) {
        $latest = Get-LatestUpstreamPullRequest -Fork $Fork -BaseBranch $BaseBranch -PullRequest $rebuiltPullRequest
        $comment = "Closed so that upstream $($target.Tag) can be proposed again from upstream $($current.Tag), as the current-tag input asked. " +
            'Nobody had worked on this pull request.'
        if ($null -ne $latest -and (Test-InterruptedUpstreamPullRequestClose -PullRequest $latest)) {
            Close-ForkPullRequest -Fork $Fork -PullRequest $latest -Comment $comment
        }
        elseif ($null -ne $latest) {
            $engagement = Get-UpstreamPullRequestEngagement -Fork $Fork -PullRequest $latest
            if ($null -ne $engagement) {
                & $refuseRebuild $engagement
            }
            # Recorded as superseded, so closing it does not decline the release.
            if (-not (Close-UntouchedUpstreamPullRequest -Fork $Fork -ForkAuthorization $forkAuthorization -PullRequest $latest `
                        -SupersededBy $target.Tag -Comment $comment)) {
                & $refuseRebuild 'its branch changed during this run'
            }
        }
        # Closed by someone during this run: only its branch, judged in step 3, is in the way.
        elseif (-not (Remove-UpdateBranch -ForkAuthorization $forkAuthorization -BranchName $branchName -ExpectedHead $remoteBranchHead)) {
            throw "Kept branch '$branchName' of the closed pull request $($rebuiltPullRequest.Url) because it changed during this run. Delete the branch and run again."
        }
        $remoteBranchHead = ''
    }

    # The lease names the head this run observed, so a push made since then is never overwritten.
    # An empty lease value means "the branch must not exist yet".
    $lease = "--force-with-lease=refs/heads/${branchName}:$remoteBranchHead"
    Invoke-AuthenticatedGit -Authorization $forkAuthorization -Arguments @('push', $lease, 'origin', "HEAD:refs/heads/$branchName") | Out-Null
    $pushedHead = Invoke-Git -Arguments @('rev-parse', 'HEAD') | Select-Object -First 1

    # The marker records the pushed commit, so any later change to the branch counts as work.
    $pullRequest = Publish-ForkPullRequest -Fork $Fork -BaseBranch $BaseBranch -BranchName $branchName -Head $pushedHead -Content $content
    $result.Outcome = 'Created'
    $result.PullRequestUrl = $pullRequest.Url

    $draftNote = if ($content.ConflictCount -gt 0) { " as a draft with $conflictCount" } else { '' }
    $sentences = @("Created $($pullRequest.Url)${draftNote}: $($content.Title).")
    if ($null -ne $rebuiltPullRequest) {
        Add-ForkPullRequestComment -Fork $Fork -PullRequest $rebuiltPullRequest -Comment "Rebuilt as $($pullRequest.Url)." | Out-Null
        $sentences += "Closed $($rebuiltPullRequest.Url), which proposed upstream $($target.Tag) from another baseline."
    }
    $replacement = [pscustomobject]@{ Tag = $target.Tag; Url = $pullRequest.Url }
    $replaced = @(Select-OlderUpstreamPullRequest -PullRequests $openPullRequests -Releases $releases -Than $target)
    $sentences += @(Close-ReplacedUpstreamPullRequest -Fork $Fork -ForkAuthorization $forkAuthorization -BaseBranch $BaseBranch `
            -PullRequests $replaced -Replacement $replacement)
    Add-TrackingSummary ($sentences -join ' ')
    return $result
}

#endregion
