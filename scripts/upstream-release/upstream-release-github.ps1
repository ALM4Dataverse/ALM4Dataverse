#Requires -Version 7.2

<#
.SYNOPSIS
    GitHub fork adapter for upstream release tracking.
.DESCRIPTION
    Implements the fork platform interface (section 7 of upstream-release-functions.ps1)
    for a fork hosted on GitHub, using the gh CLI authenticated by GH_TOKEN. Also provides
    the optional Copilot coding agent hand-off, which exists only on GitHub.

    Loaded by upstream-release-functions.ps1; do not dot-source this file on its own.
#>

function New-GitHubForkContext {
    <#
    .SYNOPSIS
        Describes a fork hosted on GitHub for the engine.
    .DESCRIPTION
        Pure object construction; it changes no state, so it does not support ShouldProcess.
    .PARAMETER Repository
        The fork as 'owner/name'.
    .PARAMETER TokenSource
        Kind of token in GH_TOKEN: 'app', 'pat' or 'github-token' (the built-in token, which
        cannot push changes to workflow files).
    .PARAMETER AssignCopilot
        Assigns the Copilot coding agent after the pull request is published.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs an in-memory object only.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
        [string]$Repository,

        [ValidateSet('app', 'pat', 'github-token')]
        [string]$TokenSource = 'github-token',

        [switch]$AssignCopilot
    )

    [pscustomobject]@{
        Platform      = 'GitHub'
        DisplayName   = $Repository
        Repository    = $Repository
        TokenSource   = $TokenSource
        AssignCopilot = [bool]$AssignCopilot
    }
}

function ConvertTo-GitHubBasicAuthorization {
    <#
    .SYNOPSIS
        Converts a GitHub token into the git HTTP Authorization header value GitHub expects.
    .DESCRIPTION
        GitHub's Git endpoint accepts any user name with the token as the password. The
        Base64 form is masked in GitHub Actions logs, because the runner masks only the raw
        secret and cannot recognise this derived value.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Token
    )

    $basicCredential = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("x-access-token:$Token"))
    if ($env:GITHUB_ACTIONS -eq 'true') {
        Write-Host "::add-mask::$basicCredential"
    }
    return "basic $basicCredential"
}

function Get-GitHubGitAuthorization {
    <#
    .SYNOPSIS
        Fork platform interface: git Authorization header value for a GitHub fork, from GH_TOKEN.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ([string]::IsNullOrEmpty($env:GH_TOKEN)) {
        throw 'GH_TOKEN is not set. The workflow sets it to the GitHub App, personal access token or built-in token.'
    }
    return ConvertTo-GitHubBasicAuthorization -Token $env:GH_TOKEN
}

function Invoke-GitHubCli {
    <#
    .SYNOPSIS
        Runs a gh command, optionally with a different token from the ambient GH_TOKEN.
    .PARAMETER Token
        Overrides GH_TOKEN for this call only. When empty, gh uses the ambient GH_TOKEN.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [string]$Token,

        [switch]$AllowFailure
    )

    Invoke-NativeCommandWithEnvironment -Command gh -Arguments $Arguments -Environment @{ GH_TOKEN = $Token } -AllowFailure:$AllowFailure
}

function Format-GitHubPullRequestMarker {
    <#
    .SYNOPSIS
        Wraps marker JSON in the hidden HTML comment stored at the end of the description.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Marker
    )

    return "<!-- $((Get-UpstreamTrackingConvention).MarkerName) $Marker -->"
}

function Split-GitHubPullRequestBody {
    <#
    .SYNOPSIS
        Separates a description into the text people see and the marker hidden at its end.
    .OUTPUTS
        [pscustomobject] with Description (without the marker comment, trimmed) and Marker
        (from ConvertFrom-UpstreamTrackingMarker, or $null).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Body
    )

    $markerName = [regex]::Escape((Get-UpstreamTrackingConvention).MarkerName)
    $markerPattern = "<!-- $markerName (?<json>\{.*?\}) -->"
    $match = [regex]::Match([string]$Body, $markerPattern)
    [pscustomobject]@{
        Description = ([regex]::Replace([string]$Body, $markerPattern, '')).Trim()
        Marker      = if ($match.Success) { ConvertFrom-UpstreamTrackingMarker -Json $match.Groups['json'].Value } else { $null }
    }
}

function Find-GitHubPullRequest {
    <#
    .SYNOPSIS
        Fork platform interface: finds update pull requests on GitHub.
    .DESCRIPTION
        Uses the REST API, through 'gh api --paginate', because 'gh pr list' stops at a
        fixed limit and cannot match a branch prefix: an update pull request behind more
        than that many newer ones would otherwise be missed, and its branch overwritten.
        With a tag, GitHub filters by the exact branch instead. Without a base branch, pull
        requests into every branch are listed.
    .OUTPUTS
        Normalised pull-request objects (see section 7 of upstream-release-functions.ps1).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Fork,

        [string]$BaseBranch,

        [Parameter(Mandatory)]
        [ValidateSet('open', 'closed')]
        [string]$State,

        [string]$Tag
    )

    $query = @("state=$State", 'per_page=100')
    if (-not [string]::IsNullOrEmpty($BaseBranch)) {
        $query += "base=$([uri]::EscapeDataString($BaseBranch))"
    }
    if (-not [string]::IsNullOrEmpty($Tag)) {
        $owner = $Fork.Repository.Split('/')[0]
        $query += "head=$([uri]::EscapeDataString("${owner}:$(Get-UpdateBranchName -Tag $Tag)"))"
    }
    # The filter prints one compact JSON object per pull request, whatever the page. A pull
    # request from a deleted fork has no head repository.
    $filter = '.[] | {number, url: .html_url, title, body, mergedAt: .merged_at, headRefName: .head.ref, headRepository: .head.repo.full_name}'
    $lines = Invoke-GitHubCli -Arguments @(
        'api', "repos/$($Fork.Repository)/pulls?$($query -join '&')", '--paginate', '--jq', $filter
    )

    # GitHub lists the newest pull requests first. Lines that are not JSON objects are gh's
    # own notices, which share the output because stderr is captured too.
    $pullRequests = foreach ($line in $lines | Where-Object { $_ -like '{*' }) {
        $pullRequest = $line | ConvertFrom-Json
        $branchTag = Get-UpdateBranchTag -BranchName $pullRequest.headRefName
        # Branches of the same name in other forks are not this automation's.
        if ($pullRequest.headRepository -ne $Fork.Repository -or $null -eq $branchTag) {
            continue
        }
        $body = Split-GitHubPullRequestBody -Body $pullRequest.body
        [pscustomobject]@{
            Number      = [int]$pullRequest.number
            Url         = [string]$pullRequest.url
            BranchName  = [string]$pullRequest.headRefName
            Tag         = $branchTag
            IsMerged    = -not [string]::IsNullOrEmpty([string]$pullRequest.mergedAt)
            Marker      = $body.Marker
            Title       = [string]$pullRequest.title
            Description = $body.Description
        }
    }
    return $pullRequests
}

function Test-GitHubPullRequestActivity {
    <#
    .SYNOPSIS
        Fork platform interface: tells whether people have commented on or reviewed a pull request.
    .DESCRIPTION
        Uses GraphQL because only it reports whether an author is a bot, such as the Copilot
        code reviewer. An author GitHub no longer knows (a deleted account) counts as a person.
        Review comments on lines belong to a review, so they are covered by the reviews.

        Each connection is read to the end, through 'gh api --paginate', so a person who
        commented after many bot comments is still seen.
    .OUTPUTS
        [string] such as 'someone reviewed it', or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Fork,

        [Parameter(Mandatory)]
        [pscustomobject]$PullRequest
    )

    $owner, $name = $Fork.Repository.Split('/')
    $activities = [ordered]@{ reviews = 'someone reviewed it'; comments = 'someone commented on it' }
    foreach ($connection in $activities.Keys) {
        # gh --paginate fills $endCursor from pageInfo until hasNextPage is false.
        $query = 'query($owner: String!, $name: String!, $number: Int!, $endCursor: String) { repository(owner: $owner, name: $name) { ' +
            "pullRequest(number: `$number) { $connection(first: 100, after: `$endCursor) { nodes { author { __typename } } " +
            'pageInfo { hasNextPage endCursor } } } } }'
        # The filter prints 'person' or 'bot' per author, so gh's own notices cannot match.
        $filter = ".data.repository.pullRequest.$connection.nodes[] | if .author.__typename == `"Bot`" then `"bot`" else `"person`" end"
        # -f passes strings as they are; -F converts the number.
        $authors = Invoke-GitHubCli -Arguments @(
            'api', 'graphql', '--paginate', '--jq', $filter,
            '-f', "query=$query", '-f', "owner=$owner", '-f', "name=$name", '-F', "number=$($PullRequest.Number)"
        )
        if (@($authors) -contains 'person') {
            return $activities[$connection]
        }
    }
    return $null
}

function Add-GitHubPullRequestComment {
    <#
    .SYNOPSIS
        Fork platform interface: posts a comment on a GitHub pull request.
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

    Invoke-GitHubCli -Arguments @('pr', 'comment', [string]$PullRequest.Number, '--repo', $Fork.Repository, '--body', $Comment) | Out-Null
}

function Get-GitHubPullRequestComment {
    <#
    .SYNOPSIS
        Fork platform interface: returns the text of every comment on a GitHub pull request.
    .DESCRIPTION
        Reads the conversation comments through the REST API, to the last page. Each body
        is printed as a JSON string, so a body that spans several lines stays one value and
        gh's own notices, which share the output, cannot be mistaken for one.
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

    $lines = Invoke-GitHubCli -Arguments @(
        'api', "repos/$($Fork.Repository)/issues/$($PullRequest.Number)/comments?per_page=100", '--paginate', '--jq', '.[].body | @json'
    )
    foreach ($line in $lines | Where-Object { $_ -like '"*' }) {
        [string]($line | ConvertFrom-Json)
    }
}

function Set-GitHubPullRequestMarker {
    <#
    .SYNOPSIS
        Fork platform interface: replaces the marker at the end of a GitHub pull request's description.
    .DESCRIPTION
        Writes back the description as it was read, so the text people see, and with it the
        content hash, is unchanged.
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
    $bodyFile = New-TemporaryFile
    try {
        [IO.File]::WriteAllText($bodyFile.FullName, "$($PullRequest.Description)`n`n$(Format-GitHubPullRequestMarker -Marker $Marker)")
        Invoke-GitHubCli -Arguments @('pr', 'edit', [string]$PullRequest.Number, '--repo', $Fork.Repository, '--body-file', $bodyFile.FullName) | Out-Null
    }
    finally {
        Remove-Item -LiteralPath $bodyFile.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Close-GitHubPullRequest {
    <#
    .SYNOPSIS
        Fork platform interface: closes a replaced GitHub pull request.
    .DESCRIPTION
        GitHub closes a pull request by itself once its branch is deleted, which the engine
        has done by now. The comment is therefore posted separately, because 'gh pr close'
        skips its --comment for a pull request that is already closed. 'gh pr close' then
        only reports that it is closed already, and succeeds.
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

    Add-GitHubPullRequestComment -Fork $Fork -PullRequest $PullRequest -Comment $Comment
    Invoke-GitHubCli -Arguments @('pr', 'close', [string]$PullRequest.Number, '--repo', $Fork.Repository) | Out-Null
}

function Assert-GitHubPushAllowed {
    <#
    .SYNOPSIS
        Fork platform interface: rejects workflow-file changes when only the built-in token is available.
    .DESCRIPTION
        GitHub refuses pushes that change .github/workflows unless the token has the
        workflows permission, which the built-in GITHUB_TOKEN can never have.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Fork,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$ChangedPaths
    )

    $workflowPaths = @($ChangedPaths | Where-Object { $_ -like '.github/workflows/*' })
    if ($Fork.TokenSource -eq 'github-token' -and $workflowPaths.Count -gt 0) {
        throw ("The update changes workflow files ($($workflowPaths -join ', ')), which the built-in GITHUB_TOKEN " +
            'cannot push. Configure a GitHub App (UPSTREAM_TRACKING_APP_CLIENT_ID and UPSTREAM_TRACKING_APP_PRIVATE_KEY) ' +
            'or the UPSTREAM_TRACKING_TOKEN secret with workflow write permission.')
    }
}

function Get-GitHubCurrentTagInstruction {
    <#
    .SYNOPSIS
        Tells a maintainer how to rerun the workflow with the current upstream release set.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # GITHUB_WORKFLOW is the running workflow's name; outside Actions, use the shipped name.
    $workflowName = if ($env:GITHUB_WORKFLOW) { $env:GITHUB_WORKFLOW } else { 'Track Upstream Release' }
    return "Run the '$workflowName' workflow manually (Actions > $workflowName > Run workflow) with 'current-tag' set to that release."
}

function Format-GitHubPullRequestDescription {
    <#
    .SYNOPSIS
        Joins every content section and a footer into the description people see.
    .DESCRIPTION
        The hidden marker is appended separately, because it records a hash of this text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Content
    )

    $sections = @(
        $Content.EndUserChanges
        $Content.ForkComparison
        $Content.Conflicts
        $Content.Implementation
        $Content.Validation
        '---'
        '_Created by the Track Upstream Release workflow. A newer upstream release replaces this pull request, unless someone has worked on it; then the new one is opened alongside it._'
    )
    return ($sections | Where-Object { -not [string]::IsNullOrEmpty($_) }) -join "`n`n"
}

function Publish-GitHubPullRequest {
    <#
    .SYNOPSIS
        Fork platform interface: creates the update pull request on GitHub.
    .DESCRIPTION
        Ensures the tracking label exists first. The marker is part of the description, so
        it is stored with everything else in the one request that creates the pull request.
        The description goes through a temporary file because it can exceed the Windows
        command-line length limit.
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

    $convention = Get-UpstreamTrackingConvention
    Invoke-GitHubCli -Arguments @(
        'label', 'create', $convention.PullRequestLabel, '--repo', $Fork.Repository, '--force',
        '--color', '0E8A16', '--description', 'Automated update from an upstream release'
    ) | Out-Null

    $description = Format-GitHubPullRequestDescription -Content $Content
    $marker = ConvertTo-UpstreamTrackingMarker -Baseline $Content.BaselineTag -Head $Head `
        -ContentHash (Get-PullRequestTextHash -Title $Content.Title -Description $description)

    $bodyFile = New-TemporaryFile
    try {
        [IO.File]::WriteAllText($bodyFile.FullName, "$description`n`n$(Format-GitHubPullRequestMarker -Marker $marker)")
        $createArguments = @(
            'pr', 'create', '--repo', $Fork.Repository, '--base', $BaseBranch, '--head', $BranchName,
            '--title', $Content.Title, '--body-file', $bodyFile.FullName, '--label', $convention.PullRequestLabel
        )
        if ($Content.ConflictCount -gt 0) {
            $createArguments += '--draft'
        }
        # gh prints the new pull request's URL on a line of its own. Newer versions follow it
        # with hints on stderr, which share the output, so the URL is matched rather than
        # taken from a fixed position.
        $output = @(Invoke-GitHubCli -Arguments $createArguments)
        $urlMatch = $output | ForEach-Object { [regex]::Match([string]$_, '^(?<url>https://\S+/pull/(?<number>\d+))\s*$') } |
            Where-Object Success | Select-Object -First 1
        if ($null -eq $urlMatch) {
            throw "gh pr create did not report the new pull request's URL. Output: $($output -join ' ')"
        }
        return [pscustomobject]@{ Number = [int]$urlMatch.Groups['number'].Value; Url = $urlMatch.Groups['url'].Value }
    }
    finally {
        Remove-Item -LiteralPath $bodyFile.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Request-CopilotUpstreamReview {
    <#
    .SYNOPSIS
        Asks the Copilot coding agent to finish the update pull request.
    .DESCRIPTION
        Assigns Copilot to the pull request through the issues API, asking it to resolve any
        conflict markers and complete the Fork Difference Audit. GitHub only accepts this
        from a user token (a personal access token of a user with a Copilot licence); GitHub
        App and GITHUB_TOKEN tokens are rejected.

        The assignment API is in public preview, so every failure is reported as a warning
        and never fails a run whose pull request was already published.
    .PARAMETER Token
        User token; defaults to UPSTREAM_TRACKING_COPILOT_TOKEN.
    .OUTPUTS
        [bool] whether the assignment request succeeded.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Fork,

        [Parameter(Mandatory)]
        [int]$PullRequestNumber,

        [Parameter(Mandatory)]
        [string]$BranchName,

        [Parameter(Mandatory)]
        [bool]$HasConflicts,

        [string]$Token = $env:UPSTREAM_TRACKING_COPILOT_TOKEN
    )

    if ([string]::IsNullOrEmpty($Token)) {
        Write-Warning 'Copilot was not assigned: set the UPSTREAM_TRACKING_COPILOT_TOKEN secret to a personal access token of a user with Copilot.'
        return $false
    }

    $instructions = [System.Collections.Generic.List[string]]::new()
    if ($HasConflicts) {
        $instructions.Add('Resolve every conflict listed under "Unresolved conflicts" in the pull request description. Prefer the upstream framework change and re-apply fork-specific behaviour through configuration or hooks where possible.')
    }
    $instructions.Add('Complete the Fork Difference Audit described in AGENTS.md and replace the placeholders in the "End-user changes", "Fork comparison" and "Validation" sections of the pull request description.')
    $instructions.Add("Keep the hidden '$((Get-UpstreamTrackingConvention).MarkerName)' comment at the end of the description unchanged.")
    $instructions.Add('Run the checks listed in AGENTS.md and report their results.')

    $request = @{
        assignees        = @('copilot-swe-agent[bot]')
        agent_assignment = @{
            target_repo         = $Fork.Repository
            base_branch         = $BranchName
            custom_instructions = $instructions -join "`n"
        }
    }

    $requestFile = New-TemporaryFile
    try {
        [IO.File]::WriteAllText($requestFile.FullName, ($request | ConvertTo-Json -Depth 4))
        Invoke-GitHubCli -Token $Token -Arguments @(
            'api', '--method', 'POST', "repos/$($Fork.Repository)/issues/$PullRequestNumber/assignees", '--input', $requestFile.FullName
        ) | Out-Null
        Write-Host "Assigned Copilot to pull request #$PullRequestNumber."
        return $true
    }
    catch {
        # Invoke-GitHubCli threw on gh's exit code, which is still set. The Actions pwsh shell
        # would fail the step with it, although this optional step only warns.
        $global:LASTEXITCODE = 0
        Write-Warning "Copilot could not be assigned to pull request #${PullRequestNumber}: $($_.Exception.Message) Check that the Copilot coding agent is enabled for the repository and that the token's user has Copilot."
        return $false
    }
    finally {
        Remove-Item -LiteralPath $requestFile.FullName -Force -ErrorAction SilentlyContinue
    }
}
