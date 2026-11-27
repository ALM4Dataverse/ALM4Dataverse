BeforeAll {
    Set-StrictMode -Version Latest
    $repoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repoRoot 'scripts/upstream-release/upstream-release-functions.ps1')
    $script:entryScript = Join-Path $repoRoot 'scripts/upstream-release/update-upstream-release-pr.ps1'
    $script:upstreamRepository = 'example/upstream'
    $script:gitHubFork = New-GitHubForkContext -Repository 'contoso/fork' -TokenSource app
    $script:azureDevOpsFork = New-AzureDevOpsForkContext -CollectionUri 'https://dev.azure.com/contoso' -Project 'ALM' -Repository 'fork'

    function Invoke-FixtureGit {
        param(
            [Parameter(Mandatory)]
            [string]$Path,

            [Parameter(Mandatory)]
            [string[]]$Arguments
        )

        # --git-dir addresses bare repositories even where safe.bareRepository is 'explicit'.
        $location = if ($Path.EndsWith('.git')) { "--git-dir=$Path" } else { '-C', $Path }
        Invoke-CheckedNativeCommand -Command git -Arguments (@($location) + $Arguments)
    }

    function Add-FixtureCommit {
        param(
            [Parameter(Mandatory)]
            [string]$Path,

            [Parameter(Mandatory)]
            [hashtable]$Files,

            [string]$Tag
        )

        foreach ($relativePath in $Files.Keys) {
            $fullPath = Join-Path $Path $relativePath
            New-Item -ItemType Directory -Path (Split-Path -Parent $fullPath) -Force | Out-Null
            [IO.File]::WriteAllText($fullPath, $Files[$relativePath])
        }
        Invoke-FixtureGit -Path $Path -Arguments @('add', '--all') | Out-Null
        Invoke-FixtureGit -Path $Path -Arguments @('commit', '--quiet', '-m', "Change $($Files.Keys -join ', ')") | Out-Null
        if ($Tag) {
            Invoke-FixtureGit -Path $Path -Arguments @('tag', '-a', $Tag, '-m', $Tag) | Out-Null
        }
    }

    function Initialize-FixtureRepository {
        param(
            [Parameter(Mandatory)]
            [string]$Path
        )

        Invoke-CheckedNativeCommand -Command git -Arguments @('init', '--quiet', '--initial-branch=main', $Path) | Out-Null
        Invoke-FixtureGit -Path $Path -Arguments @('config', 'user.name', 'Fixture') | Out-Null
        Invoke-FixtureGit -Path $Path -Arguments @('config', 'user.email', 'fixture@example.com') | Out-Null
        Invoke-FixtureGit -Path $Path -Arguments @('config', 'core.autocrlf', 'false') | Out-Null
    }

    function Get-OriginBranchFile {
        param(
            [Parameter(Mandatory)]
            [string]$Branch,

            [Parameter(Mandatory)]
            [string]$Path
        )

        Invoke-FixtureGit -Path $script:fixture.Origin -Arguments @('show', "${Branch}:$Path")
    }

    function Invoke-FixtureTracking {
        param(
            [pscustomobject]$Fork = $script:gitHubFork,

            [hashtable]$Options = @{}
        )

        $parameters = @{
            UpstreamRepository = $script:upstreamRepository
            Fork               = $Fork
            BaseBranch         = 'main'
            UpstreamRemoteUrl  = $script:fixture.Upstream
            CurrentTag         = 'v1.0.0'
        }
        foreach ($name in $Options.Keys) {
            $parameters[$name] = $Options[$name]
        }
        Invoke-UpstreamReleaseTracking @parameters
    }

    function Get-ReleaseResponse {
        # Shaped like items of GitHub's "List releases" response.
        param(
            [Parameter(Mandatory)]
            [string]$Tag,

            [bool]$Prerelease = $false,

            [bool]$Draft = $false
        )

        [pscustomobject]@{ tag_name = $Tag; prerelease = $Prerelease; draft = $Draft }
    }

    function Get-GitHubPullRequestFixture {
        # A pull request as the simulated GitHub stores it, for states a run cannot produce
        # itself. Its marker matches its title and description, as if nobody had edited them.
        param(
            [Parameter(Mandatory)]
            [int]$Number,

            [Parameter(Mandatory)]
            [string]$Tag,

            [ValidateSet('open', 'closed')]
            [string]$State = 'open',

            [switch]$Merged,

            [string]$SupersededBy,

            [switch]$CrossRepository
        )

        $title = "Update upstream from v1.0.0 to $Tag"
        $description = 'Generated description'
        $marker = ConvertTo-UpstreamTrackingMarker -Baseline 'v1.0.0' -Head ('0' * 40) -SupersededBy $SupersededBy `
            -ContentHash (Get-PullRequestTextHash -Title $title -Description $description)
        @{
            number            = $Number
            url               = "https://github.com/contoso/fork/pull/$Number"
            title             = $title
            body              = "$description`n`n$(Format-GitHubPullRequestMarker -Marker $marker)"
            mergedAt          = if ($Merged) { '2024-01-01T00:00:00Z' } else { $null }
            headRefName       = Get-UpdateBranchName -Tag $Tag
            baseRefName       = 'main'
            isCrossRepository = [bool]$CrossRepository
            isDraft           = $false
            state             = $State
            comments          = @()
            reviews           = @()
        }
    }

    function Get-GitHubPullRequestRecord {
        # The simulated GitHub's record of a pull request; changes to it are seen by later gh calls.
        param(
            [Parameter(Mandatory)]
            [int]$Number
        )

        $script:gitHub.PullRequests | Where-Object { $_.number -eq $Number } | Select-Object -First 1
    }

    function Get-AzureDevOpsPullRequestFixture {
        # A pull request as the simulated Azure Repos stores it. Without a marker, like one
        # whose creating run failed before storing it.
        param(
            [Parameter(Mandatory)]
            [int]$Id,

            [Parameter(Mandatory)]
            [string]$Tag,

            [ValidateSet('active', 'completed', 'abandoned')]
            [string]$Status = 'active',

            [string]$Marker,

            [string]$ForkSource
        )

        $record = @{
            pullRequestId = $Id
            status        = $Status
            sourceRefName = "refs/heads/$(Get-UpdateBranchName -Tag $Tag)"
            targetRefName = 'refs/heads/main'
            title         = "Update upstream from v1.0.0 to $Tag"
            description   = 'Generated description'
            isDraft       = $false
            createdBy     = @{ id = 'build-service' }
            reviewers     = @()
            threads       = @()
        }
        if ($Marker) {
            $record.marker = $Marker
        }
        if ($ForkSource) {
            $record.forkSource = @{ name = $ForkSource }
        }
        return $record
    }

    function Add-ReviewerCommit {
        # Pushes a person's commit to an update branch, as a reviewer would in the web editor.
        param(
            [Parameter(Mandatory)]
            [string]$Branch,

            [Parameter(Mandatory)]
            [hashtable]$Files
        )

        Invoke-FixtureGit -Path $script:fixture.Work -Arguments @('fetch', '--quiet', 'origin') | Out-Null
        Invoke-FixtureGit -Path $script:fixture.Work -Arguments @('checkout', '--quiet', '--force', '-B', $Branch, "origin/$Branch") | Out-Null
        Add-FixtureCommit -Path $script:fixture.Work -Files $Files
        Invoke-FixtureGit -Path $script:fixture.Work -Arguments @('push', '--quiet', 'origin', "HEAD:$Branch") | Out-Null
    }

    function Add-OriginReviewerCommit {
        # Moves an update branch in the fork directly, without touching the work tree, as a
        # reviewer's push that lands while a run is in progress. With Amend, the branch's last
        # commit is rewritten with its message, and so its trailers, unchanged.
        param(
            [Parameter(Mandatory)]
            [string]$Branch,

            [switch]$Amend
        )

        $origin = $script:fixture.Origin
        $tree = Invoke-FixtureGit -Path $origin -Arguments @('rev-parse', "$Branch^{tree}")
        $parent = if ($Amend) { "$Branch^" } else { $Branch }
        $message = if ($Amend) { (Invoke-FixtureGit -Path $origin -Arguments @('log', '-1', '--format=%B', $Branch)) -join "`n" } else { 'Reviewer fix' }
        $commit = Invoke-FixtureGit -Path $origin -Arguments @(
            '-c', 'user.name=Reviewer', '-c', 'user.email=reviewer@example.com', 'commit-tree', $tree, '-p', $parent, '-m', $message
        )
        Invoke-FixtureGit -Path $origin -Arguments @('update-ref', "refs/heads/$Branch", $commit) | Out-Null
    }

    function Get-OriginUpdateBranch {
        # The update branches that exist in the fork.
        Invoke-FixtureGit -Path $script:fixture.Origin -Arguments @('for-each-ref', '--format=%(refname:short)', 'refs/heads/update/upstream-release/')
    }

    function Initialize-UpstreamWithRelease {
        # Copies the shared upstream and publishes one more release on top, returning its path.
        param(
            [Parameter(Mandatory)]
            [string]$Tag,

            [Parameter(Mandatory)]
            [hashtable]$Files
        )

        $upstream = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Invoke-CheckedNativeCommand -Command git -Arguments @('clone', '--quiet', $script:templates.Upstream, $upstream) | Out-Null
        Initialize-FixtureRepository -Path $upstream
        Add-FixtureCommit -Path $upstream -Tag $Tag -Files $Files
        return $upstream
    }

    # The fork has no history in common with the upstream, like a fork whose update pull
    # requests were squash-merged, so every run must record a baseline before merging.
    # The upstream and the fork seeds are read-only, so they are built once.
    $script:templates = @{
        Upstream         = Join-Path $TestDrive 'upstream'
        ForkSeed         = Join-Path $TestDrive 'fork-seed'
        ConflictForkSeed = Join-Path $TestDrive 'conflict-fork-seed'
    }
    Initialize-FixtureRepository -Path $script:templates.Upstream
    Add-FixtureCommit -Path $script:templates.Upstream -Tag 'v1.0.0' -Files @{ 'shared.txt' = "one`ntwo`nthree`n"; 'README.md' = "upstream`n" }
    Add-FixtureCommit -Path $script:templates.Upstream -Tag 'v1.1.0' -Files @{ 'shared.txt' = "one`ntwo`nthree upstream`n"; 'new.txt' = "new in 1.1`n" }
    Add-FixtureCommit -Path $script:templates.Upstream -Tag 'v1.2.0-beta.1' -Files @{ '.github/workflows/ci.yml' = "name: ci`n" }
    Initialize-FixtureRepository -Path $script:templates.ForkSeed
    Add-FixtureCommit -Path $script:templates.ForkSeed -Files @{ 'shared.txt' = "one`ntwo`nthree`n"; 'README.md' = "upstream`n"; 'fork.txt' = "fork only`n" }
    Initialize-FixtureRepository -Path $script:templates.ConflictForkSeed
    Add-FixtureCommit -Path $script:templates.ConflictForkSeed -Files @{ 'shared.txt' = "one`ntwo`nthree fork`n"; 'README.md' = "upstream`n" }

    function Initialize-TrackingFixture {
        param(
            [string]$ForkSeed = $script:templates.ForkSeed
        )

        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $fixture = @{
            Upstream = $script:templates.Upstream
            Origin   = Join-Path $root 'origin.git'
            Work     = Join-Path $root 'work'
        }

        Invoke-CheckedNativeCommand -Command git -Arguments @('clone', '--quiet', '--bare', $ForkSeed, $fixture.Origin) | Out-Null
        Invoke-CheckedNativeCommand -Command git -Arguments @('clone', '--quiet', $fixture.Origin, $fixture.Work) | Out-Null
        Invoke-FixtureGit -Path $fixture.Work -Arguments @('config', 'user.name', 'Automation') | Out-Null
        Invoke-FixtureGit -Path $fixture.Work -Arguments @('config', 'user.email', 'automation@example.com') | Out-Null
        Invoke-FixtureGit -Path $fixture.Work -Arguments @('config', 'core.autocrlf', 'false') | Out-Null
        return $fixture
    }

    function Use-TrackingEnvironment {
        # Saves and clears every variable the engine reads, so a developer's or CI runner's
        # environment cannot change test results. Restore-TrackingEnvironment undoes it.
        $script:savedEnvironment = @{}
        foreach ($name in 'GH_TOKEN', 'SYSTEM_ACCESSTOKEN', 'UPSTREAM_READ_TOKEN', 'GITHUB_STEP_SUMMARY', 'GITHUB_ACTIONS', 'GITHUB_WORKFLOW', 'TF_BUILD', 'BUILD_DEFINITIONNAME') {
            $script:savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $null)
        }
    }

    function Restore-TrackingEnvironment {
        foreach ($name in $script:savedEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $script:savedEnvironment[$name])
        }
    }
}

AfterAll {
    # Git writes its objects read-only, which Pester's own TestDrive cleanup cannot delete.
    Get-ChildItem -LiteralPath $TestDrive -Recurse -File -Force | ForEach-Object { $_.Attributes = 'Normal' }
}

Describe 'Upstream release ordering' {
    It 'orders <Lower> below <Higher>' -ForEach @(
        @{ Lower = 'v1.2.0-alpha'; Higher = 'v1.2.0-alpha.1' }
        @{ Lower = 'v1.2.0-alpha.1'; Higher = 'v1.2.0-alpha.beta' }
        @{ Lower = 'v1.2.0-beta.2'; Higher = 'v1.2.0-beta.10' }
        @{ Lower = 'v1.2.0-rc.1'; Higher = 'v1.2.0' }
        @{ Lower = 'v1.2.0'; Higher = 'v1.2.0.1' }
        @{ Lower = 'v1.9.0'; Higher = 'v1.10.0' }
    ) {
        $lowerRelease = New-UpstreamReleaseRecord -UpstreamRepository 'a/b' -Tag $Lower
        $higherRelease = New-UpstreamReleaseRecord -UpstreamRepository 'a/b' -Tag $Higher

        Compare-UpstreamRelease -Left $lowerRelease -Right $higherRelease | Should -Be -1
        Compare-UpstreamRelease -Left $higherRelease -Right $lowerRelease | Should -Be 1
    }

    It 'treats missing numeric parts and build metadata as equal' {
        $short = New-UpstreamReleaseRecord -UpstreamRepository 'a/b' -Tag '1.2'
        $long = New-UpstreamReleaseRecord -UpstreamRepository 'a/b' -Tag 'v1.2.0+build.7'

        Compare-UpstreamRelease -Left $short -Right $long | Should -Be 0
    }

    It 'rejects tags that are not versions' {
        New-UpstreamReleaseRecord -UpstreamRepository 'a/b' -Tag 'nightly' | Should -BeNullOrEmpty
    }

    It 'treats a labelled tag as a prerelease even when GitHub does not flag it' {
        (New-UpstreamReleaseRecord -UpstreamRepository 'a/b' -Tag 'v2.0.0-rc.1' -IsPrerelease $false).IsPrerelease | Should -BeTrue
    }
}

Describe 'Upstream release discovery and selection' {
    BeforeEach {
        Mock Invoke-UpstreamGitHubApi {
            Get-ReleaseResponse -Tag 'v1.10.0'
            Get-ReleaseResponse -Tag 'nightly' -Prerelease $true
            Get-ReleaseResponse -Tag 'v1.11.0-beta.1' -Prerelease $true
            Get-ReleaseResponse -Tag 'v1.12.0' -Draft $true
            Get-ReleaseResponse -Tag 'v1.9.0'
        }
        $script:releases = Get-UpstreamRelease -UpstreamRepository 'a/b' -WarningAction SilentlyContinue
    }

    It 'lists published, parseable releases oldest first' {
        $script:releases.Tag | Should -Be @('v1.9.0', 'v1.10.0', 'v1.11.0-beta.1')
    }

    It 'chooses <Expected> when IncludePrereleases is <IncludePrereleases> and the requested tag is "<RequestedTag>"' -ForEach @(
        @{ IncludePrereleases = $false; RequestedTag = ''; Expected = 'v1.10.0' }
        @{ IncludePrereleases = $true; RequestedTag = ''; Expected = 'v1.11.0-beta.1' }
        @{ IncludePrereleases = $false; RequestedTag = 'v1.11.0-beta.1'; Expected = 'v1.11.0-beta.1' }
        @{ IncludePrereleases = $true; RequestedTag = 'v1.9.0'; Expected = 'v1.9.0' }
    ) {
        $target = Select-TargetUpstreamRelease -Releases $script:releases -RequestedTag $RequestedTag -IncludePrereleases:$IncludePrereleases

        $target.Tag | Should -Be $Expected
    }

    It 'fails when the requested release does not exist' {
        { Select-TargetUpstreamRelease -Releases $script:releases -RequestedTag 'v9.9.9' } | Should -Throw '*was not found*'
    }

    It 'lists the release notes between the current and target releases' {
        $current = $script:releases[0]
        $target = $script:releases[2]

        (Get-UpstreamReleaseRange -Releases $script:releases -Current $current -Target $target).Tag | Should -Be @('v1.10.0', 'v1.11.0-beta.1')
    }

    It 'explains how to read a private upstream when the release list cannot be read' {
        Mock Invoke-UpstreamGitHubApi { throw 'Response status code does not indicate success: 404 (Not Found).' }

        { Get-UpstreamRelease -UpstreamRepository 'a/b' } | Should -Throw '*UPSTREAM_READ_TOKEN*404*'
    }

    It 'takes the current release from <Expected> when history finds v1.9.0 and the pending baseline is ''<Pending>''' -ForEach @(
        @{ Pending = 'v1.10.0'; Expected = 'PendingBaseline'; Tag = 'v1.10.0' }
        @{ Pending = 'v1.9.0'; Expected = 'History'; Tag = 'v1.9.0' }
        @{ Pending = ''; Expected = 'History'; Tag = 'v1.9.0' }
    ) {
        Mock Read-UpstreamTrackingState { $null }
        Mock Resolve-UpstreamTagCommit { "commit-$Tag" }
        # Only v1.9.0 was merged with a merge commit, as in a fork that later squash-merged.
        Mock Test-GitAncestor { $Ancestor -eq 'commit-v1.9.0' }

        $current = Resolve-CurrentUpstreamRelease -UpstreamRepository 'a/b' -Fork ([pscustomobject]@{ Platform = 'GitHub' }) `
            -Releases $script:releases -BaseBranch main -BaseRef 'refs/remotes/origin/main' -PendingBaselineTag $Pending

        $current.Source | Should -Be $Expected
        $current.Tag | Should -Be $Tag
    }
}

Describe 'GitHub REST access to the upstream' {
    BeforeEach {
        Use-TrackingEnvironment
    }

    AfterEach {
        Restore-TrackingEnvironment
    }

    It 'flattens every page and sends the token only when one is given' {
        Mock Invoke-RestMethod { , @([pscustomobject]@{ id = 1 }, [pscustomobject]@{ id = 2 }); , @([pscustomobject]@{ id = 3 }) }

        (Invoke-UpstreamGitHubApi -Path 'repos/a/b/releases' -Token 'read-token').id | Should -Be @(1, 2, 3)
        Invoke-UpstreamGitHubApi -Path 'repos/a/b/releases' | Out-Null

        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://api.github.com/repos/a/b/releases' -and $FollowRelLink -and $Headers.Authorization -eq 'Bearer read-token'
        }
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { -not $Headers.ContainsKey('Authorization') }
    }

    It 'reads the upstream with <Expected> for a <Platform> fork' -ForEach @(
        @{ Platform = 'GitHub'; ReadToken = $null; Expected = 'fork-token' }
        @{ Platform = 'GitHub'; ReadToken = 'read-token'; Expected = 'read-token' }
        @{ Platform = 'AzureDevOps'; ReadToken = $null; Expected = $null }
        @{ Platform = 'AzureDevOps'; ReadToken = 'read-token'; Expected = 'read-token' }
    ) {
        $env:GH_TOKEN = 'fork-token'
        $env:UPSTREAM_READ_TOKEN = $ReadToken

        Get-UpstreamApiToken -Fork ([pscustomobject]@{ Platform = $Platform }) | Should -Be $Expected
    }

    It 'never sends the fork token to the upstream Git endpoint' {
        $env:GH_TOKEN = 'fork-token'
        Get-UpstreamGitAuthorization | Should -BeNullOrEmpty

        $env:UPSTREAM_READ_TOKEN = 'read-token'
        Get-UpstreamGitAuthorization | Should -Be "basic $([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('x-access-token:read-token')))"
    }
}

Describe 'Upstream release tracking for a GitHub fork' {
    BeforeEach {
        Use-TrackingEnvironment
        $env:GH_TOKEN = 'fork-token'

        $script:fixture = Initialize-TrackingFixture
        # Simulated GitHub: every pull request of the fork, and each gh command run, as
        # "<command> <pull request number>" for the commands that address one.
        $script:gitHub = @{
            PullRequests = [System.Collections.Generic.List[hashtable]]::new()
            NextNumber   = 42
            FailClose    = $false
            FailComment  = $false
            # Scriptblocks keyed by gh command, each run once just before that command is
            # handled, to simulate something happening during a run.
            Hooks        = @{}
            Calls        = [System.Collections.Generic.List[string]]::new()
        }

        Mock Invoke-UpstreamGitHubApi {
            Get-ReleaseResponse -Tag 'v1.0.0'
            Get-ReleaseResponse -Tag 'v1.1.0'
            Get-ReleaseResponse -Tag 'v1.2.0-beta.1' -Prerelease $true
        }

        Mock Invoke-GitHubCli {
            $command = "$($Arguments[0]) $($Arguments[1])"
            if ($Arguments[0] -eq 'api' -and $Arguments[1] -like 'repos/contoso/fork/pulls[?]*') {
                $command = 'api pulls'
            }
            elseif ($Arguments[0] -eq 'api' -and $Arguments[1] -match '^repos/contoso/fork/issues/(\d+)/comments') {
                $command = 'api comments'
                $commentsOf = [int]$Matches[1]
            }
            if ($script:gitHub.Hooks.ContainsKey($command)) {
                $hook = $script:gitHub.Hooks[$command]
                $script:gitHub.Hooks.Remove($command)
                & $hook
            }
            # Options are read by name, as gh reads them; flags without a value are tested with -contains.
            $option = @{}
            for ($index = 2; $index -lt $Arguments.Count - 1; $index++) {
                if ($Arguments[$index] -like '--*') {
                    $option[$Arguments[$index]] = $Arguments[$index + 1]
                }
            }
            $record = if ($command -in 'pr edit', 'pr comment', 'pr close') { Get-GitHubPullRequestRecord -Number $Arguments[2] }
            $script:gitHub.Calls.Add($(if ($record) { "$command $($record.number)" } else { $command }))

            switch ($command) {
                'api pulls' {
                    # The output of the --jq filter: one compact object per pull request, newest first.
                    $query = [uri]::UnescapeDataString(($Arguments[1] -split '\?', 2)[1])
                    $state = [regex]::Match($query, '(?:^|&)state=(\w+)').Groups[1].Value
                    $headMatch = [regex]::Match($query, '(?:^|&)head=contoso:([^&]+)')
                    $baseMatch = [regex]::Match($query, '(?:^|&)base=([^&]+)')
                    $script:gitHub.PullRequests |
                        Where-Object {
                            $_.state -eq $state -and
                            (-not $headMatch.Success -or $_.headRefName -eq $headMatch.Groups[1].Value) -and
                            (-not $baseMatch.Success -or $_.baseRefName -eq $baseMatch.Groups[1].Value)
                        } |
                        Sort-Object { $_.number } -Descending |
                        ForEach-Object {
                            [ordered]@{
                                number = $_.number; url = $_.url; title = $_.title; body = $_.body; mergedAt = $_.mergedAt
                                headRefName = $_.headRefName; headRepository = if ($_.isCrossRepository) { 'someone/fork' } else { 'contoso/fork' }
                            } | ConvertTo-Json -Compress
                        }
                }
                'pr create' {
                    $number = $script:gitHub.NextNumber++
                    $created = @{
                        number            = $number
                        url               = "https://github.com/contoso/fork/pull/$number"
                        title             = $option['--title']
                        body              = Get-Content -LiteralPath $option['--body-file'] -Raw
                        mergedAt          = $null
                        headRefName       = $option['--head']
                        baseRefName       = $option['--base']
                        isCrossRepository = $false
                        isDraft           = $Arguments -contains '--draft'
                        state             = 'open'
                        comments          = @()
                        reviews           = @()
                    }
                    $script:gitHub.PullRequests.Add($created)
                    # gh 2.106 follows the URL with a hint on stderr, which the caller captures too.
                    $created.url
                    'hint: if you need to wait for this pull request to be reviewed, merged, or closed before continuing, use this instead of polling:'
                    '  - Event subscriptions are in preview and may not be enabled for your account.'
                }
                'pr edit' { $record.body = Get-Content -LiteralPath $option['--body-file'] -Raw }
                # The workflow's token belongs to an app, so GitHub reports its comments as a bot's.
                'pr comment' {
                    if ($script:gitHub.FailComment) {
                        throw 'HTTP 502: Bad Gateway'
                    }
                    $record.comments += @{ author = 'Bot'; body = $option['--body'] }
                }
                'pr close' {
                    if ($script:gitHub.FailClose) {
                        throw 'HTTP 502: Bad Gateway'
                    }
                    $record.state = 'closed'
                }
                # The output of the --jq filter: each body as a JSON string.
                'api comments' { (Get-GitHubPullRequestRecord -Number $commentsOf).comments | ForEach-Object { $_.body | ConvertTo-Json -Compress } }
                'api graphql' {
                    # The output of the --jq filter for the one connection the query reads.
                    $number = [int](($Arguments | Where-Object { $_ -like 'number=*' }) -replace '^number=', '')
                    $activity = Get-GitHubPullRequestRecord -Number $number
                    $connection = if (($Arguments | Where-Object { $_ -like 'query=*' }) -match '\breviews\(') { 'reviews' } else { 'comments' }
                    foreach ($item in $activity[$connection]) {
                        if ($item.author -eq 'Bot') { 'bot' } else { 'person' }
                    }
                }
            }
        }

        Push-Location -LiteralPath $script:fixture.Work
    }

    AfterEach {
        Pop-Location
        Restore-TrackingEnvironment
    }

    It 'opens a pull request that merges the newest stable release on its own branch and keeps fork files' {
        $result = Invoke-FixtureTracking

        $result.Outcome | Should -Be 'Created'
        $result.TargetTag | Should -Be 'v1.1.0'
        $result.PullRequestUrl | Should -Be 'https://github.com/contoso/fork/pull/42'
        $branch = 'update/upstream-release/v1.1.0'
        Get-OriginBranchFile -Branch $branch -Path 'shared.txt' | Should -Be @('one', 'two', 'three upstream')
        Get-OriginBranchFile -Branch $branch -Path 'fork.txt' | Should -Be 'fork only'
        $state = (Get-OriginBranchFile -Branch $branch -Path '.github/upstream-release.json') -join "`n" | ConvertFrom-Json
        $state.upstreamRepository | Should -Be $script:upstreamRepository
        $state.tag | Should -Be 'v1.1.0'
        $published = Get-GitHubPullRequestRecord -Number 42
        $published.headRefName | Should -Be $branch
        $published.isDraft | Should -BeFalse
        $published.body | Should -Match 'Recorded `v1.0.0` as the already-merged upstream baseline'
        $published.body | Should -Match 'Only in the fork: `fork.txt`'
        Invoke-FixtureGit -Path $script:fixture.Origin -Arguments @('log', '-1', '--format=%B', $branch) |
            Should -Contain 'Upstream-Release-Tracking: v1.1.0'
    }

    It 'stores the baseline, the pushed commit and a hash of the published title and description in the marker' {
        Invoke-FixtureTracking | Out-Null

        $published = Get-GitHubPullRequestRecord -Number 42
        $published.body | Should -Match '<!-- upstream-release-tracking \{"baseline":"v1.0.0","contentHash":"[0-9A-F]{64}","head":"[0-9a-f]{40}"\} -->$'
        $body = Split-GitHubPullRequestBody -Body $published.body
        $body.Marker.contentHash | Should -Be (Get-PullRequestTextHash -Title $published.title -Description $body.Description)
        $body.Marker.head | Should -Be (Invoke-FixtureGit -Path $script:fixture.Origin -Arguments @('rev-parse', 'update/upstream-release/v1.1.0'))
    }

    It 'merges a prerelease when prereleases are included' {
        $result = Invoke-FixtureTracking -Options @{ IncludePrereleases = $true }

        $result.TargetTag | Should -Be 'v1.2.0-beta.1'
        Get-OriginBranchFile -Branch 'update/upstream-release/v1.2.0-beta.1' -Path '.github/workflows/ci.yml' | Should -Be 'name: ci'
        (Get-GitHubPullRequestRecord -Number 42).body |
            Should -Match '\[v1.2.0-beta.1\]\(https://github.com/example/upstream/releases/tag/v1.2.0-beta.1\) \(prerelease\)'
    }

    It 'refuses to push workflow changes with the built-in token' {
        $fork = New-GitHubForkContext -Repository 'contoso/fork' -TokenSource github-token

        { Invoke-FixtureTracking -Fork $fork -Options @{ IncludePrereleases = $true } } |
            Should -Throw '*changes workflow files (.github/workflows/ci.yml)*'
        Get-OriginUpdateBranch | Should -BeNullOrEmpty
    }

    It 'commits conflict markers to a draft pull request that lists the conflicted files' {
        $script:fixture = Initialize-TrackingFixture -ForkSeed $script:templates.ConflictForkSeed
        Set-Location -LiteralPath $script:fixture.Work

        $result = Invoke-FixtureTracking

        $result.Conflicts.Path | Should -Be 'shared.txt'
        (Get-OriginBranchFile -Branch 'update/upstream-release/v1.1.0' -Path 'shared.txt') -join "`n" | Should -Match '<<<<<<< '
        $published = Get-GitHubPullRequestRecord -Number 42
        $published.isDraft | Should -BeTrue
        $published.body | Should -Match '\n\| `shared\.txt` \| '
        # Each pending task carries a self-contained prompt for GitHub Copilot.
        $published.body | Should -BeLike "*``````text`n*git fetch --no-tags https://github.com/$script:upstreamRepository.git refs/tags/v1.1.0*Fork Difference Audit*"
        $published.body | Should -BeLike "*``````text`n*merges upstream $script:upstreamRepository v1.1.0 into main*git grep -l -E*"
    }

    It 'reports the fork as up to date from the committed state file' {
        Invoke-FixtureGit -Path $script:fixture.Work -Arguments @('fetch', '--quiet', $script:fixture.Upstream, '+refs/tags/*:refs/upstream-release-tags/*') | Out-Null
        Write-UpstreamTrackingState -UpstreamRepository $script:upstreamRepository -Release ([pscustomobject]@{ Tag = 'v1.1.0' }) -Commit 'unused'
        Invoke-FixtureGit -Path $script:fixture.Work -Arguments @('commit', '--quiet', '-m', 'Record state') | Out-Null
        Invoke-FixtureGit -Path $script:fixture.Work -Arguments @('push', '--quiet', 'origin', 'HEAD:main') | Out-Null

        $result = Invoke-FixtureTracking -Options @{ CurrentTag = '' }

        $result.Outcome | Should -Be 'UpToDate'
        Should -Invoke Invoke-GitHubCli -Times 0 -ParameterFilter { $Arguments[0] -eq 'pr' -and $Arguments[1] -ne 'list' }
    }

    It 'explains how to supply the current release when no source names it' {
        $env:GITHUB_WORKFLOW = 'Track Upstream Release'

        { Invoke-FixtureTracking -Options @{ CurrentTag = ' ' } } |
            Should -Throw "*.github/upstream-release.json on 'main': not found*Recent upstream releases: v1.2.0-beta.1, v1.1.0, v1.0.0*Actions > Track Upstream Release > Run workflow) with 'current-tag'*"
    }

    It 'does not reopen a release whose pull request a person closed unless it is requested' {
        $script:gitHub.PullRequests.Add((Get-GitHubPullRequestFixture -Number 6 -Tag 'v1.1.0' -State closed -Merged))
        $script:gitHub.PullRequests.Add((Get-GitHubPullRequestFixture -Number 7 -Tag 'v1.1.0' -State closed))

        (Invoke-FixtureTracking).Outcome | Should -Be 'Declined'
        (Invoke-FixtureTracking -Options @{ TargetTag = 'v1.1.0' }).Outcome | Should -Be 'Created'
    }

    It 'reports a declined bootstrap release before asking for the current release' {
        $script:gitHub.PullRequests.Add((Get-GitHubPullRequestFixture -Number 7 -Tag 'v1.1.0' -State closed))

        # No CurrentTag and no state file: only the declined pull request could have named the baseline.
        (Invoke-FixtureTracking -Options @{ CurrentTag = '' }).Outcome | Should -Be 'Declined'
    }

    It 'proposes a release again whose pull request was closed only because a newer one replaced it' {
        $script:gitHub.PullRequests.Add((Get-GitHubPullRequestFixture -Number 7 -Tag 'v1.1.0' -State closed -SupersededBy 'v1.2.0-beta.1'))

        (Invoke-FixtureTracking).Outcome | Should -Be 'Created'
    }

    It 'never overwrites the branch of an update pull request a person retargeted to another branch' {
        Invoke-FixtureTracking | Out-Null
        (Get-GitHubPullRequestRecord -Number 42).baseRefName = 'release'
        $branch = 'update/upstream-release/v1.1.0'
        Add-OriginReviewerCommit -Branch $branch
        $reviewedHead = Invoke-FixtureGit -Path $script:fixture.Origin -Arguments @('rev-parse', $branch)

        { Invoke-FixtureTracking } |
            Should -Throw "*Branch '$branch' is used by the open pull request https://github.com/contoso/fork/pull/42, which is not into 'main'*"
        Invoke-FixtureGit -Path $script:fixture.Origin -Arguments @('rev-parse', $branch) | Should -Be $reviewedHead
    }

    It 'leaves an open pull request alone when it already proposes the release, even before its baseline is merged' {
        $script:gitHub.PullRequests.Add((Get-GitHubPullRequestFixture -Number 7 -Tag 'v1.1.0'))

        # No CurrentTag and no state file: a bootstrap pull request is still waiting for review.
        $result = Invoke-FixtureTracking -Options @{ CurrentTag = '' }

        $result.Outcome | Should -Be 'AlreadyOpen'
        $result.PullRequestUrl | Should -Be 'https://github.com/contoso/fork/pull/7'
        Should -Invoke Invoke-GitHubCli -Times 0 -ParameterFilter { $Arguments[0] -eq 'pr' -and $Arguments[1] -ne 'list' }
    }

    It 'closes the pull request a newer release replaces, and deletes its branch, when nobody worked on it' {
        Invoke-FixtureTracking -Options @{ TargetTag = 'v1.1.0' } | Out-Null

        $result = Invoke-FixtureTracking -Options @{ IncludePrereleases = $true }

        $result.Outcome | Should -Be 'Created'
        $result.PullRequestUrl | Should -Be 'https://github.com/contoso/fork/pull/43'
        $replaced = Get-GitHubPullRequestRecord -Number 42
        $replaced.state | Should -Be 'closed'
        $replaced.comments[-1].body | Should -Match '^Replaced by https://github\.com/contoso/fork/pull/43, which proposes upstream v1\.2\.0-beta\.1\.'
        (Split-GitHubPullRequestBody -Body $replaced.body).Marker.supersededBy | Should -Be 'v1.2.0-beta.1'
        $script:gitHub.Calls.IndexOf('pr edit 42') | Should -BeLessThan $script:gitHub.Calls.IndexOf('pr close 42') -Because 'the marker must name the replacement before the pull request is closed'
        Get-OriginUpdateBranch | Should -Be 'update/upstream-release/v1.2.0-beta.1'
    }

    It 'keeps a replaced pull request open, and links the new one, when <Case>' -ForEach @(
        @{ Case = 'a person added a commit'; Change = 'commit'; Reason = 'its branch changed after it was opened' }
        @{ Case = 'a person amended the last commit'; Change = 'amend'; Reason = 'its branch changed after it was opened' }
        @{ Case = 'a person edited the title'; Change = 'title'; Reason = 'its title or description was edited' }
        @{ Case = 'a person edited the description'; Change = 'description'; Reason = 'its title or description was edited' }
        @{ Case = 'the marker was removed'; Change = 'marker'; Reason = 'its tracking marker is missing, so edits by people cannot be ruled out' }
        @{ Case = 'a person reviewed it'; Change = 'review'; Reason = 'someone reviewed it' }
        @{ Case = 'a person commented on it'; Change = 'comment'; Reason = 'someone commented on it' }
    ) {
        Invoke-FixtureTracking -Options @{ TargetTag = 'v1.1.0' } | Out-Null
        $pullRequest = Get-GitHubPullRequestRecord -Number 42
        switch ($Change) {
            'commit' { Add-ReviewerCommit -Branch 'update/upstream-release/v1.1.0' -Files @{ 'reviewer.txt' = "review fix`n" } }
            'amend' { Add-OriginReviewerCommit -Branch 'update/upstream-release/v1.1.0' -Amend }
            'title' { $pullRequest.title = 'Upstream v1.1.0, with fixes' }
            'description' { $pullRequest.body = "A reviewer's note`n`n$($pullRequest.body)" }
            'marker' { $pullRequest.body = 'Rewritten by a reviewer' }
            'review' { $pullRequest.reviews = @(@{ author = 'User' }) }
            'comment' { $pullRequest.comments = @(@{ author = 'User'; body = 'Looks good' }) }
        }

        $result = Invoke-FixtureTracking -Options @{ IncludePrereleases = $true }

        $result.Outcome | Should -Be 'Created'
        $pullRequest.state | Should -Be 'open'
        $pullRequest.comments[-1].body | Should -Be ("Upstream v1.2.0-beta.1 is now proposed in https://github.com/contoso/fork/pull/43. " +
            "This pull request was left open because $Reason; merge or close it when you are done with it.")
        Get-OriginUpdateBranch | Should -Contain 'update/upstream-release/v1.1.0'
        Should -Invoke Invoke-GitHubCli -Times 0 -ParameterFilter { $Arguments[1] -eq 'close' }
    }

    It 'closes a replaced pull request that only bots reviewed or commented on' {
        Invoke-FixtureTracking -Options @{ TargetTag = 'v1.1.0' } | Out-Null
        $pullRequest = Get-GitHubPullRequestRecord -Number 42
        $pullRequest.reviews = @(@{ author = 'Bot' })
        $pullRequest.comments = @(@{ author = 'Bot'; body = 'Pull request overview' })

        Invoke-FixtureTracking -Options @{ IncludePrereleases = $true } | Out-Null

        $pullRequest.state | Should -Be 'closed'
    }

    It 'finishes closing replaced pull requests after a failed run, but never closes a newer one' {
        Invoke-FixtureTracking -Options @{ TargetTag = 'v1.1.0' } | Out-Null
        $script:gitHub.FailClose = $true
        { Invoke-FixtureTracking -Options @{ IncludePrereleases = $true } } | Should -Throw '*HTTP 502*'
        $script:gitHub.FailClose = $false
        Get-OriginUpdateBranch | Should -Not -Contain 'update/upstream-release/v1.1.0' -Because 'the branch is deleted before the close that failed'

        # A scheduled run excludes prereleases, yet keeps the newer prerelease pull request.
        $result = Invoke-FixtureTracking

        $result.Outcome | Should -Be 'AlreadyOpen'
        $result.TargetTag | Should -Be 'v1.2.0-beta.1'
        $result.PullRequestUrl | Should -Be 'https://github.com/contoso/fork/pull/43'
        (Get-GitHubPullRequestRecord -Number 42).state | Should -Be 'closed'
        (Get-GitHubPullRequestRecord -Number 43).state | Should -Be 'open'
    }

    It 'posts a link to the replacement once, even after a run that failed to post it' {
        Invoke-FixtureTracking -Options @{ TargetTag = 'v1.1.0' } | Out-Null
        $pullRequest = Get-GitHubPullRequestRecord -Number 42
        $pullRequest.comments = @(@{ author = 'User'; body = 'Looks good' })
        $script:gitHub.FailComment = $true
        { Invoke-FixtureTracking -Options @{ IncludePrereleases = $true } } | Should -Throw '*HTTP 502*'
        $script:gitHub.FailComment = $false

        Invoke-FixtureTracking -Options @{ IncludePrereleases = $true } | Out-Null
        $result = Invoke-FixtureTracking -Options @{ IncludePrereleases = $true }

        $result.Outcome | Should -Be 'AlreadyOpen'
        $pullRequest.state | Should -Be 'open'
        @($pullRequest.comments | Where-Object { $_.body -match 'pull/43\b' }).Count | Should -Be 1
    }

    It 'leaves a pull request for a newer release alone when an older release is requested' {
        Invoke-FixtureTracking -Options @{ TargetTag = 'v1.2.0-beta.1' } | Out-Null

        $result = Invoke-FixtureTracking -Options @{ TargetTag = 'v1.1.0' }

        $result.Outcome | Should -Be 'Created'
        $newer = Get-GitHubPullRequestRecord -Number 42
        $newer.state | Should -Be 'open'
        $newer.comments | Should -BeNullOrEmpty
        Get-OriginUpdateBranch | Should -Contain 'update/upstream-release/v1.2.0-beta.1'
    }

    It 'keeps a replaced pull request open when its branch is pushed to during the run, before <Command>' -ForEach @(
        @{ Command = 'api graphql' }
        @{ Command = 'pr edit' }
    ) {
        Invoke-FixtureTracking -Options @{ TargetTag = 'v1.1.0' } | Out-Null
        $branch = 'update/upstream-release/v1.1.0'
        # A reviewer's push lands after the run fetched the branch: while activity is read,
        # or after every check, just as the marker records the replacement.
        $script:gitHub.Hooks[$Command] = { Add-OriginReviewerCommit -Branch 'update/upstream-release/v1.1.0' }

        Invoke-FixtureTracking -Options @{ IncludePrereleases = $true } | Out-Null

        $pullRequest = Get-GitHubPullRequestRecord -Number 42
        $pullRequest.state | Should -Be 'open'
        $pullRequest.comments[-1].body | Should -Match 'left open because its branch changed during this run;'
        (Split-GitHubPullRequestBody -Body $pullRequest.body).Marker.supersededBy | Should -BeNullOrEmpty -Because 'the marker is restored'
        Invoke-FixtureGit -Path $script:fixture.Origin -Arguments @('log', '-1', '--format=%s', $branch) | Should -Be 'Reviewer fix'
    }

    It 'keeps a replaced pull request open when it is edited while the run builds its replacement' {
        Invoke-FixtureTracking -Options @{ TargetTag = 'v1.1.0' } | Out-Null
        $script:gitHub.Hooks['pr create'] = { (Get-GitHubPullRequestRecord -Number 42).title = 'Upstream v1.1.0, with fixes' }

        Invoke-FixtureTracking -Options @{ IncludePrereleases = $true } | Out-Null

        $pullRequest = Get-GitHubPullRequestRecord -Number 42
        $pullRequest.state | Should -Be 'open'
        $pullRequest.comments[-1].body | Should -Match 'left open because its title or description was edited;'
    }

    It 'deletes an update branch only while it points to the expected commit' {
        Invoke-FixtureTracking -Options @{ TargetTag = 'v1.1.0' } | Out-Null
        $branch = 'update/upstream-release/v1.1.0'
        $head = Invoke-FixtureGit -Path $script:fixture.Origin -Arguments @('rev-parse', $branch)
        $authorization = Get-ForkGitAuthorization -Fork $script:gitHubFork

        Remove-UpdateBranch -ForkAuthorization $authorization -BranchName $branch -ExpectedHead ('0' * 39 + '1') -WarningAction SilentlyContinue |
            Should -BeFalse
        Get-OriginUpdateBranch | Should -Contain $branch

        Remove-UpdateBranch -ForkAuthorization $authorization -BranchName $branch -ExpectedHead $head | Should -BeTrue
        Get-OriginUpdateBranch | Should -Not -Contain $branch
    }

    It 'replaces a bootstrap pull request using the baseline in its marker' {
        Invoke-FixtureTracking -Options @{ TargetTag = 'v1.1.0' } | Out-Null

        # No CurrentTag and no state file on the base branch.
        $result = Invoke-FixtureTracking -Options @{ CurrentTag = ''; IncludePrereleases = $true }

        $result.Outcome | Should -Be 'Created'
        (Get-GitHubPullRequestRecord -Number 43).title | Should -Be 'Update upstream from v1.0.0 to v1.2.0-beta.1'
        (Get-GitHubPullRequestRecord -Number 42).state | Should -Be 'closed'
    }

    It 'rebuilds a pull request for the release from the baseline the current tag names, when nobody worked on it' {
        Invoke-FixtureTracking -Options @{ TargetTag = 'v1.2.0-beta.1' } | Out-Null

        $result = Invoke-FixtureTracking -Options @{ TargetTag = 'v1.2.0-beta.1'; CurrentTag = 'v1.1.0' }

        $result.Outcome | Should -Be 'Created'
        (Get-GitHubPullRequestRecord -Number 43).title | Should -Be 'Update upstream from v1.1.0 to v1.2.0-beta.1'
        $rebuilt = Get-GitHubPullRequestRecord -Number 42
        $rebuilt.state | Should -Be 'closed'
        (Split-GitHubPullRequestBody -Body $rebuilt.body).Marker.supersededBy | Should -Be 'v1.2.0-beta.1' -Because 'closing it must not decline the release'
        $rebuilt.comments[-1].body | Should -Be 'Rebuilt as https://github.com/contoso/fork/pull/43.'
        Get-OriginUpdateBranch | Should -Be 'update/upstream-release/v1.2.0-beta.1'
        (Invoke-FixtureTracking -Options @{ TargetTag = 'v1.2.0-beta.1'; CurrentTag = 'v1.1.0' }).Outcome | Should -Be 'AlreadyOpen'
    }

    It 'refuses to rebuild a pull request from another baseline when people worked on it' {
        Invoke-FixtureTracking -Options @{ TargetTag = 'v1.2.0-beta.1' } | Out-Null
        $pullRequest = Get-GitHubPullRequestRecord -Number 42
        $pullRequest.comments = @(@{ author = 'User'; body = 'Resolving these now' })

        { Invoke-FixtureTracking -Options @{ TargetTag = 'v1.2.0-beta.1'; CurrentTag = 'v1.1.0' } } |
            Should -Throw "*cannot be rebuilt from upstream v1.1.0 because someone commented on it. Close it, then run again with target-tag 'v1.2.0-beta.1' and current-tag 'v1.1.0'."

        $pullRequest.state | Should -Be 'open'
        Should -Invoke Invoke-GitHubCli -Times 0 -ParameterFilter { $Arguments[0] -eq 'pr' -and $Arguments[1] -eq 'close' }
        Should -Invoke Invoke-GitHubCli -Times 1 -Exactly -ParameterFilter { $Arguments[0] -eq 'pr' -and $Arguments[1] -eq 'create' } -Because 'only the first run created a pull request'
    }

    It 'refuses to rebuild a pull request whose branch is pushed to after it was checked' {
        Invoke-FixtureTracking -Options @{ TargetTag = 'v1.2.0-beta.1' } | Out-Null
        $script:gitHub.Hooks['pr edit'] = { Add-OriginReviewerCommit -Branch 'update/upstream-release/v1.2.0-beta.1' }

        { Invoke-FixtureTracking -Options @{ TargetTag = 'v1.2.0-beta.1'; CurrentTag = 'v1.1.0' } } |
            Should -Throw '*cannot be rebuilt from upstream v1.1.0 because its branch changed during this run.*'

        $pullRequest = Get-GitHubPullRequestRecord -Number 42
        $pullRequest.state | Should -Be 'open'
        (Split-GitHubPullRequestBody -Body $pullRequest.body).Marker.supersededBy | Should -BeNullOrEmpty
        Invoke-FixtureGit -Path $script:fixture.Origin -Arguments @('log', '-1', '--format=%s', 'update/upstream-release/v1.2.0-beta.1') | Should -Be 'Reviewer fix'
    }

    It 'opens a pull request that only records the release when the named current release is the newest' {
        $result = Invoke-FixtureTracking -Options @{ CurrentTag = 'v1.1.0' }

        $result.Outcome | Should -Be 'Created'
        $result.TargetTag | Should -Be 'v1.1.0'
        (Get-GitHubPullRequestRecord -Number 42).title | Should -Be 'Record upstream v1.1.0 as the merged upstream release'
        ((Get-OriginBranchFile -Branch 'update/upstream-release/v1.1.0' -Path '.github/upstream-release.json') -join "`n" | ConvertFrom-Json).tag |
            Should -Be 'v1.1.0'
        Get-OriginBranchFile -Branch 'update/upstream-release/v1.1.0' -Path 'shared.txt' | Should -Be @('one', 'two', 'three') -Because 'no upstream change is merged'
    }

    It 'pushes nothing and changes no pull request in a dry run' {
        Invoke-FixtureTracking -Options @{ TargetTag = 'v1.1.0' } | Out-Null

        $result = Invoke-FixtureTracking -Options @{ IncludePrereleases = $true; DryRun = $true }

        $result.Outcome | Should -Be 'DryRun'
        Get-OriginUpdateBranch | Should -Be 'update/upstream-release/v1.1.0'
        (Get-GitHubPullRequestRecord -Number 42).state | Should -Be 'open'
        Should -Invoke Invoke-GitHubCli -Times 1 -Exactly -ParameterFilter { $Arguments[0] -eq 'pr' -and $Arguments[1] -ne 'list' } -Because 'only the first run created a pull request'
    }

    It 'ignores pull requests from other repositories that use the same branch name' {
        $script:gitHub.PullRequests.Add((Get-GitHubPullRequestFixture -Number 8 -Tag 'v1.1.0' -CrossRepository))

        $result = Invoke-FixtureTracking

        $result.Outcome | Should -Be 'Created'
        Should -Invoke Invoke-GitHubCli -Times 0 -ParameterFilter { $Arguments -contains '8' }
    }

    It 'tells reviewers how to accept a binary file that was added on both sides' {
        [IO.File]::WriteAllBytes((Join-Path $script:fixture.Work 'logo.bin'), [byte[]](0, 1, 2))

        $record = New-MergeConflictRecord -Code 'AA' -Path 'logo.bin'

        $record.Description | Should -Be 'Binary file added in the fork and upstream'
        $record.Resolution | Should -Match "Replace it with upstream's version"
    }

    It 'commits an update with more conflicts than fit on a command line' {
        # 1,000 paths of about 120 characters: over 120 KB of conflict list, yet each path
        # stays within the Windows 260-character limit under the test drive.
        $paths = foreach ($index in 1..1000) { 'conflicts/' + ('x' * 100) + "-$index.txt" }
        $writeConflictFiles = {
            param([string]$Repository, [string]$Content, [string]$Tag)
            New-Item -ItemType Directory -Path (Join-Path $Repository 'conflicts') -Force | Out-Null
            foreach ($path in $paths) {
                [IO.File]::WriteAllText((Join-Path $Repository $path), $Content)
            }
            Invoke-FixtureGit -Path $Repository -Arguments @('add', '--all') | Out-Null
            Invoke-FixtureGit -Path $Repository -Arguments @('commit', '--quiet', '-m', 'Add conflicting files') | Out-Null
            if ($Tag) {
                Invoke-FixtureGit -Path $Repository -Arguments @('tag', '-a', $Tag, '-m', $Tag) | Out-Null
            }
        }
        $script:fixture.Upstream = Initialize-UpstreamWithRelease -Tag 'v1.3.0' -Files @{ 'later.txt' = "new in 1.3`n" }
        & $writeConflictFiles -Repository $script:fixture.Upstream -Content "upstream`n" -Tag 'v1.4.0'
        Invoke-FixtureGit -Path $script:fixture.Work -Arguments @('checkout', '--quiet', '--force', '-B', 'main', 'origin/main') | Out-Null
        & $writeConflictFiles -Repository $script:fixture.Work -Content "fork`n"
        Invoke-FixtureGit -Path $script:fixture.Work -Arguments @('push', '--quiet', 'origin', 'HEAD:main') | Out-Null
        Mock Invoke-UpstreamGitHubApi {
            Get-ReleaseResponse -Tag 'v1.0.0'
            Get-ReleaseResponse -Tag 'v1.4.0'
        }

        $result = Invoke-FixtureTracking

        $result.Outcome | Should -Be 'Created'
        $result.Conflicts.Count | Should -Be 1000
        $message = Invoke-FixtureGit -Path $script:fixture.Origin -Arguments @('log', '-1', '--format=%B', 'update/upstream-release/v1.4.0')
        @($message | Where-Object { $_ -like '- conflicts/*' }).Count | Should -Be 1000
    }

    It 'does nothing when run in the upstream repository itself' {
        $global:LASTEXITCODE = 1

        $result = & $script:entryScript -GitHubRepository $script:upstreamRepository -UpstreamRepository $script:upstreamRepository -BaseBranch main

        $result.Outcome | Should -Be 'Disabled'
        (Get-Location).Path | Should -Be $script:fixture.Work
        $LASTEXITCODE | Should -Be 0 -Because 'the pwsh step fails on an exit code left by a git command whose failure was expected'
    }
}

Describe 'Upstream release tracking for an Azure DevOps fork' {
    BeforeEach {
        Use-TrackingEnvironment
        $env:SYSTEM_ACCESSTOKEN = 'job-token'

        $script:fixture = Initialize-TrackingFixture
        # Simulated Azure Repos: pull requests keyed by id (each with its marker and comment
        # threads), plus every state-changing request in the order it was made.
        $script:azureDevOps = @{
            PullRequests = @{}
            NextId       = 9
            Requests     = [System.Collections.Generic.List[pscustomobject]]::new()
            FailMarker   = $false
        }

        Mock Invoke-UpstreamGitHubApi {
            Get-ReleaseResponse -Tag 'v1.0.0'
            Get-ReleaseResponse -Tag 'v1.1.0'
            Get-ReleaseResponse -Tag 'v1.2.0-beta.1' -Prerelease $true
        }

        Mock Invoke-AzureDevOpsApi {
            $verb = if ($Method) { $Method } else { 'Get' }
            if ($verb -ne 'Get') {
                $script:azureDevOps.Requests.Add([pscustomobject]@{ Method = $verb; Path = $Path; Body = $Body; ContentType = $ContentType })
            }
            if ($script:azureDevOps.FailMarker -and "$verb $Path" -match '^Patch pullRequests/\d+/properties$') {
                throw 'HTTP 500: Internal Server Error'
            }
            $pullRequest = if ($Path -match '^pull[Rr]equests/(\d+)') { $script:azureDevOps.PullRequests[[int]$Matches[1]] }

            $response = switch -Regex ("$verb $Path") {
                '^Get pullrequests\?' {
                    $query = [uri]::UnescapeDataString(($Path -split '\?', 2)[1])
                    $status = [regex]::Match($query, 'searchCriteria\.status=(\w+)').Groups[1].Value
                    $source = [regex]::Match($query, 'searchCriteria\.sourceRefName=([^&]+)').Groups[1].Value
                    $target = [regex]::Match($query, 'searchCriteria\.targetRefName=([^&]+)').Groups[1].Value
                    $listed = $script:azureDevOps.PullRequests.Values | Where-Object {
                        ($status -eq 'all' -or $_.status -eq $status) -and (-not $source -or $_.sourceRefName -eq $source) -and
                        (-not $target -or $_.targetRefName -eq $target)
                    }
                    @{ value = @($listed | Sort-Object { $_.pullRequestId } -Descending) }
                }
                '^Get pullrequests/\d+$' { $pullRequest }
                '^Patch pullrequests/\d+$' {
                    $pullRequest.status = $Body.status
                    $pullRequest
                }
                '^Get pullRequests/\d+/properties$' {
                    $values = @{}
                    if ($pullRequest.Contains('marker')) {
                        $values['upstream-release-tracking'] = @{ '$type' = 'System.String'; '$value' = $pullRequest.marker }
                    }
                    @{ count = $values.Count; value = $values }
                }
                '^Patch pullRequests/\d+/properties$' {
                    $pullRequest.marker = $Body[0].value
                    @{}
                }
                '^Get pullRequests/\d+/threads$' { @{ value = @($pullRequest.threads) } }
                '^Post pullRequests/\d+/threads$' {
                    # The pipeline's build service created the pull request, so it writes the comments too.
                    $pullRequest.threads += @{
                        status   = $Body.status
                        comments = @(@{ content = $Body.comments[0].content; commentType = 'text'; author = @{ id = 'build-service' } })
                    }
                    @{}
                }
                '^Post pullrequests$' {
                    $id = $script:azureDevOps.NextId++
                    $script:azureDevOps.PullRequests[$id] = @{
                        pullRequestId = $id
                        status        = 'active'
                        sourceRefName = $Body.sourceRefName
                        targetRefName = $Body.targetRefName
                        title         = $Body.title
                        description   = $Body.description
                        isDraft       = $Body.isDraft
                        createdBy     = @{ id = 'build-service' }
                        reviewers     = @()
                        threads       = @()
                    }
                    @{ pullRequestId = $id }
                }
                default { @{} }
            }
            # Invoke-RestMethod returns objects parsed from JSON, not hashtables.
            $response | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        }

        Push-Location -LiteralPath $script:fixture.Work
    }

    AfterEach {
        Pop-Location
        Restore-TrackingEnvironment
    }

    It 'creates a labelled draft pull request with its marker and details comment' {
        $script:fixture = Initialize-TrackingFixture -ForkSeed $script:templates.ConflictForkSeed
        Set-Location -LiteralPath $script:fixture.Work

        $result = Invoke-FixtureTracking -Fork $script:azureDevOpsFork

        $result.Outcome | Should -Be 'Created'
        $result.PullRequestUrl | Should -Be 'https://dev.azure.com/contoso/ALM/_git/fork/pullrequest/9'
        $created = $script:azureDevOps.Requests | Where-Object { $_.Method -eq 'Post' -and $_.Path -eq 'pullrequests' }
        $created.Body.sourceRefName | Should -Be 'refs/heads/update/upstream-release/v1.1.0'
        $created.Body.targetRefName | Should -Be 'refs/heads/main'
        $created.Body.isDraft | Should -BeTrue
        $created.Body.labels.name | Should -Be 'upstream-release'
        $created.Body.description.Length | Should -BeLessOrEqual 4000
        $created.Body.description | Should -Match 'committed conflict markers in 1 file'

        $markerRequest = $script:azureDevOps.Requests | Where-Object { $_.Path -eq 'pullRequests/9/properties' }
        $markerRequest.ContentType | Should -Be 'application/json-patch+json'
        $marker = ConvertFrom-UpstreamTrackingMarker -Json $markerRequest.Body[0].value
        $marker.baseline | Should -Be 'v1.0.0'
        $marker.head | Should -Be (Invoke-FixtureGit -Path $script:fixture.Origin -Arguments @('rev-parse', 'update/upstream-release/v1.1.0'))
        $marker.contentHash | Should -Be (Get-PullRequestTextHash -Title $created.Body.title -Description $created.Body.description)

        $thread = $script:azureDevOps.Requests | Where-Object { $_.Method -eq 'Post' -and $_.Path -eq 'pullRequests/9/threads' }
        $thread.Body.comments[0].content | Should -Match '^## Upstream release details'
        $thread.Body.comments[0].content | Should -Match '\n\| `shared\.txt` \| '
        $script:azureDevOps.Requests.IndexOf($markerRequest) | Should -BeGreaterThan $script:azureDevOps.Requests.IndexOf($thread) -Because 'the marker is stored last'
    }

    It 'abandons the pull request a newer release replaces, and deletes its branch, when nobody worked on it' {
        Invoke-FixtureTracking -Fork $script:azureDevOpsFork -Options @{ TargetTag = 'v1.1.0' } | Out-Null

        $result = Invoke-FixtureTracking -Fork $script:azureDevOpsFork -Options @{ IncludePrereleases = $true }

        $result.Outcome | Should -Be 'Created'
        $result.PullRequestUrl | Should -Be 'https://dev.azure.com/contoso/ALM/_git/fork/pullrequest/10'
        $replaced = $script:azureDevOps.PullRequests[9]
        $replaced.status | Should -Be 'abandoned'
        (ConvertFrom-UpstreamTrackingMarker -Json $replaced.marker).supersededBy | Should -Be 'v1.2.0-beta.1'
        $replaced.threads[-1].comments[0].content | Should -Match '^Replaced by https://dev\.azure\.com/contoso/ALM/_git/fork/pullrequest/10,'
        $requests = @($script:azureDevOps.Requests | ForEach-Object { "$($_.Method) $($_.Path)" })
        [array]::LastIndexOf($requests, 'Patch pullRequests/9/properties') | Should -BeLessThan ([array]::IndexOf($requests, 'Patch pullrequests/9')) -Because 'the marker must name the replacement before the pull request is abandoned'
        Get-OriginUpdateBranch | Should -Be 'update/upstream-release/v1.2.0-beta.1'
    }

    It 'keeps a replaced pull request open, and links the new one, when <Case>' -ForEach @(
        @{ Case = 'a person voted on it'; Change = 'vote'; Reason = 'someone voted on it' }
        @{ Case = 'a person commented on it'; Change = 'comment'; Reason = 'someone commented on it' }
    ) {
        Invoke-FixtureTracking -Fork $script:azureDevOpsFork -Options @{ TargetTag = 'v1.1.0' } | Out-Null
        $pullRequest = $script:azureDevOps.PullRequests[9]
        switch ($Change) {
            'vote' { $pullRequest.reviewers = @(@{ id = 'reviewer'; vote = 10 }) }
            'comment' { $pullRequest.threads += @{ status = 'active'; comments = @(@{ content = 'Why?'; commentType = 'text'; author = @{ id = 'reviewer' } }) } }
        }

        Invoke-FixtureTracking -Fork $script:azureDevOpsFork -Options @{ IncludePrereleases = $true } | Out-Null

        $pullRequest.status | Should -Be 'active'
        $pullRequest.threads[-1].comments[0].content | Should -Be ('Upstream v1.2.0-beta.1 is now proposed in https://dev.azure.com/contoso/ALM/_git/fork/pullrequest/10. ' +
            "This pull request was left open because $Reason; merge or close it when you are done with it.")
        Get-OriginUpdateBranch | Should -Contain 'update/upstream-release/v1.1.0'
    }

    It 'never overwrites the branch of an update pull request opened into another branch' {
        Invoke-FixtureTracking -Fork $script:azureDevOpsFork | Out-Null
        $script:azureDevOps.PullRequests[9].targetRefName = 'refs/heads/release'
        $branch = 'update/upstream-release/v1.1.0'
        Add-OriginReviewerCommit -Branch $branch
        $reviewedHead = Invoke-FixtureGit -Path $script:fixture.Origin -Arguments @('rev-parse', $branch)

        { Invoke-FixtureTracking -Fork $script:azureDevOpsFork } |
            Should -Throw "*Branch '$branch' is used by the open pull request https://dev.azure.com/contoso/ALM/_git/fork/pullrequest/9, which is not into 'main'*"
        Invoke-FixtureGit -Path $script:fixture.Origin -Arguments @('rev-parse', $branch) | Should -Be $reviewedHead
    }

    It 'finds an update pull request behind a full page of newer pull requests' {
        $unrelated = foreach ($id in 200..101) { @{ pullRequestId = $id; status = 'active'; sourceRefName = "refs/heads/feature/$id"; title = 'Feature' } }
        Mock Invoke-AzureDevOpsApi {
            $skip = [int][regex]::Match($Path, '\$skip=(\d+)').Groups[1].Value
            $page = if ($skip -eq 0) { $unrelated } else { @(@{ pullRequestId = 9; status = 'active'; sourceRefName = 'refs/heads/update/upstream-release/v1.1.0'; title = 'Update' }) }
            @{ value = @($page) } | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        } -ParameterFilter { $Path -like 'pullrequests[?]*' }
        Mock Invoke-AzureDevOpsApi { [pscustomobject]@{ description = 'Generated'; count = 0; value = @{} } }

        $found = @(Find-AzureDevOpsPullRequest -Fork $script:azureDevOpsFork -BaseBranch main -State open)

        $found.Number | Should -Be 9
        Should -Invoke Invoke-AzureDevOpsApi -Times 2 -Exactly -ParameterFilter { $Path -like 'pullrequests[?]*' }
    }

    It 'ignores system comments, deleted comments and the build service''s own vote' {
        Invoke-FixtureTracking -Fork $script:azureDevOpsFork -Options @{ TargetTag = 'v1.1.0' } | Out-Null
        $pullRequest = $script:azureDevOps.PullRequests[9]
        $pullRequest.reviewers = @(@{ id = 'build-service'; vote = 10 }, @{ id = 'reviewer'; vote = 0 })
        $pullRequest.threads += @(
            @{ comments = @(@{ content = 'Pushed a commit'; commentType = 'system'; author = @{ id = 'reviewer' } }) }
            @{ comments = @(@{ content = 'Withdrawn'; commentType = 'text'; isDeleted = $true; author = @{ id = 'reviewer' } }) }
            @{ isDeleted = $true; comments = @(@{ content = 'Removed thread'; commentType = 'text'; author = @{ id = 'reviewer' } }) }
        )

        Invoke-FixtureTracking -Fork $script:azureDevOpsFork -Options @{ IncludePrereleases = $true } | Out-Null

        $pullRequest.status | Should -Be 'abandoned'
    }

    It 'treats an abandoned pull request as declined but not a completed one' {
        $marker = ConvertTo-UpstreamTrackingMarker -Baseline 'v1.0.0' -ContentHash ('0' * 64) -Head ('0' * 40)
        $script:azureDevOps.PullRequests[3] = Get-AzureDevOpsPullRequestFixture -Id 3 -Tag 'v1.1.0' -Status completed -Marker $marker
        (Invoke-FixtureTracking -Fork $script:azureDevOpsFork -Options @{ DryRun = $true }).Outcome | Should -Be 'DryRun'

        $script:azureDevOps.PullRequests[4] = Get-AzureDevOpsPullRequestFixture -Id 4 -Tag 'v1.1.0' -Status abandoned -Marker $marker
        (Invoke-FixtureTracking -Fork $script:azureDevOpsFork).Outcome | Should -Be 'Declined'
    }

    It 'keeps a pull request whose marker was never stored, and reads its baseline from its branch' {
        $script:azureDevOps.FailMarker = $true
        { Invoke-FixtureTracking -Fork $script:azureDevOpsFork } | Should -Throw '*HTTP 500*'
        $script:azureDevOps.FailMarker = $false

        # Pull request 9 exists without a marker, and nothing else names the current release.
        (Invoke-FixtureTracking -Fork $script:azureDevOpsFork -Options @{ CurrentTag = '' }).Outcome | Should -Be 'AlreadyOpen'
        $result = Invoke-FixtureTracking -Fork $script:azureDevOpsFork -Options @{ CurrentTag = ''; IncludePrereleases = $true }

        $result.Outcome | Should -Be 'Created'
        $script:azureDevOps.PullRequests[10].title | Should -Be 'Update upstream from v1.0.0 to v1.2.0-beta.1'
        $script:azureDevOps.PullRequests[9].status | Should -Be 'active'
        $script:azureDevOps.PullRequests[9].threads[-1].comments[0].content | Should -Match 'left open because its tracking marker is missing'
    }

    It 'ignores pull requests from forks of the repository that use the same branch name' {
        $script:azureDevOps.PullRequests[6] = Get-AzureDevOpsPullRequestFixture -Id 6 -Tag 'v1.1.0' -ForkSource 'refs/heads/update/upstream-release/v1.1.0' `
            -Marker (ConvertTo-UpstreamTrackingMarker -Baseline 'v1.0.0' -ContentHash ('0' * 64) -Head ('0' * 40))

        $result = Invoke-FixtureTracking -Fork $script:azureDevOpsFork

        $result.Outcome | Should -Be 'Created'
        $script:azureDevOps.Requests | Where-Object Path -Like 'pullrequests/6*' | Should -BeNullOrEmpty
    }

    It 'runs through the entry script with the pipeline defaults' {
        # Inside the entry script, $script: in a mock refers to that script, so this mock is self-contained.
        Mock Invoke-AzureDevOpsApi { [pscustomobject]@{ value = @() } }
        $savedPipeline = @{ SYSTEM_COLLECTIONURI = $env:SYSTEM_COLLECTIONURI; SYSTEM_TEAMPROJECT = $env:SYSTEM_TEAMPROJECT }
        $env:SYSTEM_COLLECTIONURI = 'https://dev.azure.com/contoso/'
        $env:SYSTEM_TEAMPROJECT = 'ALM'
        try {
            $result = & $script:entryScript -AzureDevOpsRepository 'fork' -UpstreamRepository $script:upstreamRepository -BaseBranch main `
                -UpstreamRemoteUrl $script:fixture.Upstream -CurrentTag 'v1.0.0' -TargetTag ' ' -DryRun
        }
        finally {
            $env:SYSTEM_COLLECTIONURI = $savedPipeline.SYSTEM_COLLECTIONURI
            $env:SYSTEM_TEAMPROJECT = $savedPipeline.SYSTEM_TEAMPROJECT
        }

        $result.Outcome | Should -Be 'DryRun'
        $result.TargetTag | Should -Be 'v1.1.0'
        Should -Invoke Invoke-AzureDevOpsApi -ParameterFilter { $Fork.ApiRoot -eq 'https://dev.azure.com/contoso/ALM/_apis/git/repositories/fork' }
    }
}

Describe 'Azure DevOps adapter' {
    BeforeEach {
        Use-TrackingEnvironment
    }

    AfterEach {
        Restore-TrackingEnvironment
    }

    It 'requires the job token' {
        { Get-AzureDevOpsGitAuthorization } | Should -Throw '*SYSTEM_ACCESSTOKEN*'

        $env:SYSTEM_ACCESSTOKEN = 'job-token'
        Get-AzureDevOpsGitAuthorization | Should -Be 'bearer job-token'
    }

    It 'calls the repository API with the job token, API version and an unrolled-safe JSON body' {
        $env:SYSTEM_ACCESSTOKEN = 'job-token'
        Mock Invoke-RestMethod { }

        Invoke-AzureDevOpsApi -Fork $script:azureDevOpsFork -Path 'pullrequests?$top=1'
        Invoke-AzureDevOpsApi -Fork $script:azureDevOpsFork -Method Patch -Path 'pullRequests/1/properties' -ApiVersion '7.1-preview.1' `
            -Body @(@{ op = 'add' }) -ContentType 'application/json-patch+json'

        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://dev.azure.com/contoso/ALM/_apis/git/repositories/fork/pullrequests?$top=1&api-version=7.1' -and
            $Method -eq 'Get' -and $Headers.Authorization -eq 'Bearer job-token' -and $null -eq $Body
        }
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -like '*/pullRequests/1/properties?api-version=7.1-preview.1' -and
            $ContentType -eq 'application/json-patch+json' -and ($Body | ConvertFrom-Json -NoEnumerate) -is [array]
        }
    }

    It 'shortens only the release list when a description exceeds the Azure DevOps limit' {
        $content = [pscustomobject]@{
            EndUserChanges  = (1..400 | ForEach-Object { "- release note line $_" }) -join "`n"
            Implementation  = '## Implementation details'
            Validation      = '## Validation'
            ConflictCount   = 3
            DifferenceCount = 2
        }

        $description = Format-AzureDevOpsPullRequestDescription -Content $content

        $description.Length | Should -BeLessOrEqual 4000
        $description | Should -Match '- release note line \d+\n\n_Release list shortened to fit the Azure DevOps limit'
        $description | Should -Match '## Unresolved conflicts'
        $description | Should -Match '## Implementation details\n\n## Validation\n\n---'
    }
}

Describe 'Upstream pull-request content' {
    It 'keeps a GitHub description within 65,536 characters however large the update is' {
        $release = { param($Tag) [pscustomobject]@{ Tag = $Tag; NotesUrl = "https://github.com/example/upstream/releases/tag/$Tag"; IsPrerelease = $false } }
        $longFolder = 'a-long-folder-name-that-makes-every-path-long/' * 2
        $parameters = @{
            UpstreamRepository = $script:upstreamRepository
            BaseBranch         = 'main'
            BranchName         = 'update/upstream-release/v9.0.0'
            CurrentRelease     = & $release 'v1.0.0'
            TargetRelease      = & $release 'v9.0.0'
            IncludedReleases   = @(1..1000 | ForEach-Object { & $release "v1.$_.0" })
            MergeResult        = [pscustomobject]@{ BaselineRecorded = $true; BaselineTag = 'v1.0.0' }
            Conflicts          = @(1..1000 | ForEach-Object { New-MergeConflictRecord -Code 'UD' -Path "${longFolder}conflict-$_.txt" })
            ForkDifferences    = @(1..3000 | ForEach-Object { [pscustomobject]@{ Status = 'M'; Path = "folder-$($_ % 50)/${longFolder}file-$_.txt" } })
        }

        $description = Format-GitHubPullRequestDescription -Content (Get-UpstreamPullRequestContent @parameters)
        # Publish-GitHubPullRequest appends the marker, which is under 200 characters.
        $body = "$description`n`n$(Format-GitHubPullRequestMarker -Marker (ConvertTo-UpstreamTrackingMarker -Baseline 'v1.0.0' -ContentHash ('0' * 64) -Head ('0' * 40)))"

        $body.Length | Should -BeLessOrEqual 65536
        $body | Should -Match 'earlier releases not listed'
        $body | Should -Match 'more files are not listed'
        $body | Should -Match 'more conflicted files not listed'
        ([regex]::Matches($body, '<details>')).Count | Should -Be ([regex]::Matches($body, '</details>')).Count
    }
}
