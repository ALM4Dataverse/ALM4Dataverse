<#
.SYNOPSIS
    Resolves deployment inputs to a BUILD identity, artifact source and promotion tags.
.DESCRIPTION
    Consumes INPUT_* environment values supplied by the deploy composite action and
    GitHub context/caller-input JSON. Uses GITHUB_TOKEN and GITHUB_REPOSITORY for
    API lookup and appends selection fields to GITHUB_OUTPUT; it does not deploy
    or create tags. Branch mismatches, unsupported promotion modes and unresolved
    or unsuccessful BUILD identities throw. Release metadata can retain identity
    after the historical run disappears, with an empty build_run_id output.
#>
$ErrorActionPreference = 'Stop'

function Get-GitHubApiHeader {
    return @{
        Authorization = "Bearer $($env:GITHUB_TOKEN)"
        Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
}

function Invoke-GitHubApi {
    <#
    .SYNOPSIS
        Gets a repository-relative REST resource with the current GitHub token.
    .PARAMETER AllowNotFound
        Converts only HTTP 404 to null; authorization, transport and other failures
        propagate. RelativePath must already encode any dynamic path components.
    #>
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [switch]$AllowNotFound
    )

    $uri = "https://api.github.com/repos/$($env:GITHUB_REPOSITORY)/$RelativePath"
    try {
        return Invoke-RestMethod -Uri $uri -Headers (Get-GitHubApiHeader)
    }
    catch {
        $statusCode = $null
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        if ($AllowNotFound -and $statusCode -eq 404) {
            return $null
        }
        throw
    }
}

function Resolve-BuildRunDisplayName {
    # Prefer supplied titles; older run payloads fall back to branch-number, then ID.
    param([Parameter(Mandatory)][object]$Run)

    foreach ($propertyName in @('display_title', 'run_name')) {
        if ($Run.PSObject.Properties.Name -contains $propertyName) {
            $value = [string]$Run.$propertyName
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                return $value.Trim()
            }
        }
    }

    $headBranch = if ($Run.PSObject.Properties.Name -contains 'head_branch') { [string]$Run.head_branch } else { '' }
    $runNumber = if ($Run.PSObject.Properties.Name -contains 'run_number') { [string]$Run.run_number } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($headBranch) -and -not [string]::IsNullOrWhiteSpace($runNumber)) {
        return "$headBranch-$runNumber"
    }

    return ([string]$Run.id).Trim()
}

function Resolve-BuildRunCanonicalName {
    # Display identity remains authoritative, including its numeric-ID fallback.
    # Only an empty display result reaches the legacy repository/branch/date form.
    param([Parameter(Mandatory)][object]$Run)

    $displayName = Resolve-BuildRunDisplayName -Run $Run
    if (-not [string]::IsNullOrWhiteSpace($displayName)) {
        return $displayName.Trim()
    }

    $repoName = ''
    foreach ($repoProperty in @('head_repository', 'repository')) {
        if ($Run.PSObject.Properties.Name -contains $repoProperty) {
            $repo = $Run.$repoProperty
            if ($null -ne $repo -and $repo.PSObject.Properties.Name -contains 'name') {
                $repoName = [string]$repo.name
                if (-not [string]::IsNullOrWhiteSpace($repoName)) {
                    break
                }
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($repoName)) {
        $repoName = ([string]$env:GITHUB_REPOSITORY).Split('/')[-1]
    }

    $branchName = if ($Run.PSObject.Properties.Name -contains 'head_branch') { [string]$Run.head_branch } else { '' }
    $branchName = $branchName -replace '[^a-zA-Z0-9._/-]', '-'
    $createdAt = if ($Run.PSObject.Properties.Name -contains 'created_at') { [string]$Run.created_at } else { '' }
    $formattedDate = if (-not [string]::IsNullOrWhiteSpace($createdAt)) { ([DateTimeOffset]::Parse($createdAt)).ToString('yyyy-MM-dd-HHmmss') } else { '' }
    $runNumber = if ($Run.PSObject.Properties.Name -contains 'run_number') { [string]$Run.run_number } else { '' }

    if (-not [string]::IsNullOrWhiteSpace($repoName) -and
        -not [string]::IsNullOrWhiteSpace($branchName) -and
        -not [string]::IsNullOrWhiteSpace($formattedDate) -and
        -not [string]::IsNullOrWhiteSpace($runNumber)) {
        return "$repoName-$branchName-$formattedDate-$runNumber"
    }

    return Resolve-BuildRunDisplayName -Run $Run
}

function ConvertTo-BuildReleaseTag {
    # Legacy selector normalization is not gate normalization: preserve their
    # distinct dot/hyphen rules so existing published names remain addressable.
    param([Parameter(Mandatory)][string]$BuildName)

    $sanitized = $BuildName.Trim() `
        -replace '[^a-zA-Z0-9._/-]', '-' `
        -replace '\.{2,}', '-' `
        -replace '/{2,}', '/'
    $sanitized = $sanitized.Trim('/', '.')
    if ($sanitized.EndsWith('.lock')) {
        $sanitized = $sanitized -replace '\.lock$', '-lock'
    }
    if ([string]::IsNullOrWhiteSpace($sanitized)) {
        throw "BUILD name '$BuildName' cannot be converted to a Release tag."
    }
    return $sanitized
}

function ConvertTo-GateTagSegment {
    # Returns a path-capable segment (slashes remain), not a URL-encoded string;
    # reject names that sanitize away completely before building gate tag paths.
    param([Parameter(Mandatory)][string]$Value)

    $sanitized = $Value.Trim()
    $sanitized = $sanitized -replace '[^a-zA-Z0-9._/-]', '-'
    $sanitized = $sanitized -replace '-{2,}', '-'
    $sanitized = $sanitized -replace '\.{2,}', '.'
    $sanitized = $sanitized -replace '/{2,}', '/'
    $sanitized = $sanitized.Trim('/', '.', '-')
    if ($sanitized.EndsWith('.lock')) {
        $sanitized = $sanitized -replace '\.lock$', '-lock'
    }
    if ([string]::IsNullOrWhiteSpace($sanitized)) {
        throw "Build run name '$Value' cannot be converted to a valid gate tag segment."
    }
    return $sanitized
}

function Resolve-WorkflowDispatchBranch {
    <#
    .SYNOPSIS
        Reads a manual dispatch branch from short or full GitHub ref fields.
    .DESCRIPTION
        Missing ref returns ''; a known non-branch ref throws. When only ref_name
        is supplied without ref_type, the name is accepted as a branch.
    #>
    param([Parameter(Mandatory)][object]$GitHubContext)

    $refType = if ($null -ne $GitHubContext.PSObject.Properties['ref_type']) { [string]$GitHubContext.ref_type } else { '' }
    $refName = if ($null -ne $GitHubContext.PSObject.Properties['ref_name']) { [string]$GitHubContext.ref_name } else { '' }

    if ([string]::IsNullOrWhiteSpace($refName) -and $null -ne $GitHubContext.PSObject.Properties['ref']) {
        $fullRef = [string]$GitHubContext.ref
        if ($fullRef -match '^refs/heads/(?<branch>.+)$') {
            $refName = $Matches['branch']
            if ([string]::IsNullOrWhiteSpace($refType)) { $refType = 'branch' }
        }
        elseif ($fullRef -match '^refs/tags/(?<tag>.+)$') {
            $refName = $Matches['tag']
            if ([string]::IsNullOrWhiteSpace($refType)) { $refType = 'tag' }
        }
    }

    if ([string]::IsNullOrWhiteSpace($refName)) { return '' }
    if (-not [string]::IsNullOrWhiteSpace($refType) -and $refType -ne 'branch') {
        throw "Omitting build-run-name is only supported for branch-based workflow_dispatch runs. Selected ref '$refName' has type '$refType'."
    }
    return $refName.Trim()
}

function Test-IsBuildWorkflowRun {
    # Accept either the conventional workflow path or BUILD display name for
    # older payloads; this identity test does not verify the run's conclusion.
    param([Parameter(Mandatory)][object]$Run)

    $workflowPath = if ($Run.PSObject.Properties.Name -contains 'path') { [string]$Run.path } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($workflowPath) -and $workflowPath -match '(?i)(^|/)\.github/workflows/build\.ya?ml(?:@.+)?$') {
        return $true
    }

    $workflowName = if ($Run.PSObject.Properties.Name -contains 'name') { [string]$Run.name } else { '' }
    return -not [string]::IsNullOrWhiteSpace($workflowName) -and $workflowName.Trim() -ieq 'BUILD'
}

function Get-BuildRunById {
    param(
        [Parameter(Mandatory)][string]$RunId,
        [switch]$AllowNotFound
    )
    return Invoke-GitHubApi -RelativePath "actions/runs/$RunId" -AllowNotFound:$AllowNotFound
}

function Get-GitHubReleaseByTag {
    # Absence is a supported fallback to metadata tags or workflow-run lookup.
    param([Parameter(Mandatory)][string]$TagName)
    $encodedTag = [System.Uri]::EscapeDataString($TagName)
    return Invoke-GitHubApi -RelativePath "releases/tags/$encodedTag" -AllowNotFound
}

function Resolve-GitTagCommitSha {
    # Peel annotated tags (including nested tags) until reaching a commit; the
    # caller compares it to the selected BUILD source rather than trusting tag names.
    param([Parameter(Mandatory)][string]$TagName)

    $encodedTag = [System.Uri]::EscapeDataString($TagName)
    $reference = Invoke-GitHubApi -RelativePath "git/ref/tags/$encodedTag" -AllowNotFound
    if ($null -eq $reference) {
        throw "Git tag '$TagName' was not found."
    }

    $tagObject = $reference.object
    while ([string]$tagObject.type -eq 'tag') {
        $annotatedTag = Invoke-GitHubApi -RelativePath "git/tags/$([System.Uri]::EscapeDataString([string]$tagObject.sha))"
        $tagObject = $annotatedTag.object
    }
    if ([string]$tagObject.type -ne 'commit' -or [string]::IsNullOrWhiteSpace([string]$tagObject.sha)) {
        throw "Git tag '$TagName' does not resolve to a commit."
    }
    return [string]$tagObject.sha
}

function Get-BuildMetadataForTag {
    <#
    .SYNOPSIS
        Reads legacy ALM metadata from an annotated companion tag.
    .DESCRIPTION
        Looks under alm4dataverse/metadata/TagName. Missing/lightweight tags or
        incomplete messages return null. Valid messages return BuildName, Branch,
        SourceCommit, RunId and TagName; non-404 API failures still throw.
    #>
    param([Parameter(Mandatory)][string]$TagName)

    $metadataTag = "alm4dataverse/metadata/$TagName"
    $encodedTag = ($metadataTag -split '/' | ForEach-Object { [System.Uri]::EscapeDataString($_) }) -join '/'
    $reference = Invoke-GitHubApi -RelativePath "git/ref/tags/$encodedTag" -AllowNotFound
    if ($null -eq $reference -or [string]$reference.object.type -ne 'tag') { return $null }

    $tagObject = Invoke-GitHubApi -RelativePath "git/tags/$([System.Uri]::EscapeDataString([string]$reference.object.sha))" -AllowNotFound
    if ($null -eq $tagObject) { return $null }
    $message = [string]$tagObject.message
    $build = [regex]::Match($message, '(?im)^Build:\s*(?<value>[^\r\n]+)\s*$')
    $branch = [regex]::Match($message, '(?im)^Branch:\s*(?<value>[^\r\n]+)\s*$')
    $commit = [regex]::Match($message, '(?im)^Source commit:\s*(?<value>[0-9a-f]{40})\s*$')
    $run = [regex]::Match($message, '(?im)^BUILD run:\s*(?<value>\d+)\s*$')
    if (-not $build.Success -or -not $branch.Success -or -not $commit.Success -or -not $run.Success) { return $null }

    return [pscustomobject]@{
        BuildName = $build.Groups['value'].Value.Trim()
        Branch = $branch.Groups['value'].Value.Trim()
        SourceCommit = $commit.Groups['value'].Value
        RunId = $run.Groups['value'].Value
        TagName = $TagName
    }
}

function Get-ReleaseInformation {
    <#
    .SYNOPSIS
        Extracts the machine-readable BUILD identity from a Release body.
    .DESCRIPTION
        Requires the encoded branch marker, Build, full source SHA and linked
        numeric BUILD run. Returns BuildName, decoded Branch, SourceCommit, RunId
        and TagName, throwing on incomplete metadata. Does not verify tag contents.
    #>
    param([Parameter(Mandatory)][object]$Release)

    $body = [string]$Release.body
    $branch = [regex]::Match($body, '(?im)<!--\s*alm4dataverse-build-branch:(?<value>[^\s]+)\s*-->')
    $build = [regex]::Match($body, '(?im)^Build:\s*(?<value>[^\r\n]+)\s*$')
    $commit = [regex]::Match($body, '(?im)^Source commit:\s*(?<value>[0-9a-f]{40})\s*$')
    $run = [regex]::Match($body, '(?im)^BUILD run:\s*\[(?<value>\d+)\]\s*\(')
    if (-not $branch.Success -or -not $build.Success -or -not $commit.Success -or -not $run.Success) {
        throw "Release '$($Release.tag_name)' does not contain complete ALM build metadata."
    }

    return [pscustomobject]@{
        BuildName = $build.Groups['value'].Value.Trim()
        Branch = [System.Uri]::UnescapeDataString($branch.Groups['value'].Value).Trim()
        SourceCommit = $commit.Groups['value'].Value
        RunId = $run.Groups['value'].Value
        TagName = [string]$Release.tag_name
    }
}

function Find-LatestManagedReleaseForBranch {
    # Scan at most 100 pages; ignore unrelated/incomplete releases and stable
    # publications. "Latest" means greatest numeric BUILD run ID, not Release date.
    # Return a Release/Metadata/BuildRunId wrapper or null when none match exactly.
    param([Parameter(Mandatory)][string]$BranchName)

    $latestMatch = $null
    for ($page = 1; $page -le 100; $page++) {
        $releases = @(Invoke-GitHubApi -RelativePath "releases?per_page=100&page=$page")
        if ($releases.Count -eq 0) { break }
        foreach ($release in $releases) {
            try { $metadata = Get-ReleaseInformation -Release $release } catch { continue }
            if (-not (Test-GitHubReleasePrerelease -Release $release)) { continue }
            if ($metadata.Branch -cne $BranchName) { continue }

            $match = [pscustomobject]@{
                Release = $release
                Metadata = $metadata
                BuildRunId = [long]$metadata.RunId
            }
            if ($null -eq $latestMatch -or
                $match.BuildRunId -gt $latestMatch.BuildRunId) {
                $latestMatch = $match
            }
        }
    }

    return $latestMatch
}

function Test-GitHubReleasePrerelease {
    # Support both REST objects and hashtable fixtures; absent prerelease is false.
    param([Parameter(Mandatory)][object]$Release)

    if ($Release -is [System.Collections.IDictionary]) {
        return $Release.Contains('prerelease') -and [bool]$Release['prerelease']
    }
    $property = $Release.PSObject.Properties['prerelease']
    return $null -ne $property -and [bool]$property.Value
}

function Find-ReleaseForBuildRun {
    # Search up to 100 pages of ALM prereleases by exact metadata RunId.
    # Return Release/Metadata or null; multiple matches are an error, not a choice.
    param([Parameter(Mandatory)][string]$RunId)

    $matchingReleases = @()
    for ($page = 1; $page -le 100; $page++) {
        $releases = @(Invoke-GitHubApi -RelativePath "releases?per_page=100&page=$page")
        if ($releases.Count -eq 0) { break }
        foreach ($release in $releases) {
            if (-not (Test-GitHubReleasePrerelease -Release $release)) { continue }
            try { $releaseMetadata = Get-ReleaseInformation -Release $release } catch { continue }
            if ($releaseMetadata.RunId -ceq $RunId) {
                $matchingReleases += [pscustomobject]@{
                    Release = $release
                    Metadata = $releaseMetadata
                }
            }
        }
    }

    if ($matchingReleases.Count -gt 1) {
        throw "Multiple GitHub Releases match BUILD run '$RunId'; refusing to write an ambiguous deployment pointer."
    }
    if ($matchingReleases.Count -eq 1) {
        return $matchingReleases[0]
    }
    return $null
}

function Find-BuildRunByName {
    # Legacy run-name selection is case-insensitive and returns the first match
    # within 100 pages; it does not establish uniqueness or success here.
    param([Parameter(Mandatory)][string]$RunName)
    for ($page = 1; $page -le 100; $page++) {
        $response = Invoke-GitHubApi -RelativePath "actions/workflows/BUILD.yml/runs?per_page=100&page=$page"
        $runs = @($response.workflow_runs)
        if ($runs.Count -eq 0) { break }
        $match = $runs | Where-Object { (Resolve-BuildRunDisplayName $_) -ieq $RunName -or (Resolve-BuildRunCanonicalName $_) -ieq $RunName } | Select-Object -First 1
        if ($match) { return $match }
    }
    throw "No BUILD workflow run named '$RunName' was found."
}

function Find-LatestSuccessfulBuildRunForBranch {
    # Ask GitHub for one successful conventional BUILD workflow run; no match throws.
    param([Parameter(Mandatory)][string]$BranchName)
    $encodedBranch = [System.Uri]::EscapeDataString($BranchName.Trim())
    $response = Invoke-GitHubApi -RelativePath "actions/workflows/BUILD.yml/runs?branch=$encodedBranch&status=success&per_page=1"
    $runs = @($response.workflow_runs)
    if ($runs.Count -eq 0) { throw "No successful BUILD workflow runs were found for branch '$BranchName'." }
    return $runs[0]
}

$environmentName = $env:INPUT_ENVIRONMENT_NAME.Trim()
$previousName = $env:INPUT_PREVIOUS_ENVIRONMENT_NAME.Trim()
$promotionMode = $env:INPUT_PROMOTION_MODE.Trim()
$githubContext = $env:INPUT_GITHUB_CONTEXT_JSON | ConvertFrom-Json -Depth 100
$callerInputs = $env:INPUT_CALLER_INPUTS_JSON | ConvertFrom-Json -Depth 50
$eventName = [string]$githubContext.event_name
$dispatchRunId = [string]$githubContext.event.client_payload.build_run_id
$dispatchBranch = [string]$githubContext.event.client_payload.branch
$dispatchSourceSha = [string]$githubContext.event.client_payload.sha
$dispatchReleaseTag = [string]$githubContext.event.client_payload.release_tag
$triggerBranch = $env:INPUT_TRIGGER_BRANCH.Trim()
$manualSelector = [string]$callerInputs.'build-run-name'
if ([string]::IsNullOrWhiteSpace($manualSelector)) { $manualSelector = [string]$callerInputs.'build-run-id' }
$targetEnvironment = [string]$callerInputs.'target-environment'

$callerBranch = if ($eventName -eq 'repository_dispatch') { $dispatchBranch.Trim() } else { Resolve-WorkflowDispatchBranch $githubContext }
if ([string]::IsNullOrWhiteSpace($triggerBranch) -or $callerBranch -cne $triggerBranch) { throw "Deployment branch '$callerBranch' does not match trigger-branch '$triggerBranch'." }
if ($promotionMode -notin @('manual-gate-tag', 'environment-approval')) { throw "Unsupported promotion-mode '$promotionMode'." }
if ($eventName -eq 'workflow_dispatch' -and [string]::IsNullOrWhiteSpace($targetEnvironment) -and $promotionMode -ne 'environment-approval') { throw 'workflow_dispatch requires target-environment.' }

$release = $null
$metadata = $null
$requestedReleaseTag = $dispatchReleaseTag.Trim()
# Manual text may name a current Release, normalized legacy tag or metadata
# companion. With no selector, prefer managed branch Releases before run history.
if ($eventName -eq 'workflow_dispatch' -and -not [string]::IsNullOrWhiteSpace($manualSelector) -and $manualSelector -notmatch '^\d+$') {
    $normalizedTag = ConvertTo-BuildReleaseTag $manualSelector
    $tagCandidates = @($manualSelector)
    if ($tagCandidates -cnotcontains $normalizedTag) { $tagCandidates += $normalizedTag }
    $legacyPrefixedTag = "v$normalizedTag"
    if ($tagCandidates -cnotcontains $legacyPrefixedTag) { $tagCandidates += $legacyPrefixedTag }

    foreach ($tagCandidate in $tagCandidates) {
        $release = Get-GitHubReleaseByTag $tagCandidate
        if ($null -ne $release) {
            $requestedReleaseTag = [string]$release.tag_name
            break
        }

        $metadata = Get-BuildMetadataForTag $tagCandidate
        if ($null -ne $metadata) {
            $requestedReleaseTag = $metadata.TagName
            break
        }
    }
}
if ([string]::IsNullOrWhiteSpace($requestedReleaseTag) -and [string]::IsNullOrWhiteSpace($manualSelector)) {
    $latest = Find-LatestManagedReleaseForBranch $callerBranch
    if ($null -ne $latest) {
        $metadata = $latest.Metadata
        $release = $latest.Release
        $requestedReleaseTag = [string]$release.tag_name
    }
}
if (-not [string]::IsNullOrWhiteSpace($requestedReleaseTag) -and $null -eq $release) {
    $release = Get-GitHubReleaseByTag $requestedReleaseTag
}
if ($null -ne $release) { $metadata = Get-ReleaseInformation $release }
if ($null -eq $metadata -and -not [string]::IsNullOrWhiteSpace($requestedReleaseTag)) { $metadata = Get-BuildMetadataForTag $requestedReleaseTag }
if ($null -ne $metadata) {
    if ($metadata.Branch -cne $callerBranch) { throw "Release/build branch '$($metadata.Branch)' does not match deployment branch '$callerBranch'." }
    $requestedReleaseTag = $metadata.TagName
}

$buildRun = $null
if ($eventName -eq 'repository_dispatch' -and -not [string]::IsNullOrWhiteSpace($dispatchRunId)) {
    $buildRun = Get-BuildRunById $dispatchRunId
}
elseif ($null -ne $metadata -and -not [string]::IsNullOrWhiteSpace($metadata.RunId)) {
    $buildRun = Get-BuildRunById $metadata.RunId -AllowNotFound
}
elseif ($eventName -eq 'workflow_dispatch' -and -not [string]::IsNullOrWhiteSpace($manualSelector)) {
    if ($manualSelector -match '^\d+$') { $buildRun = Get-BuildRunById $manualSelector }
    else { $buildRun = Find-BuildRunByName $manualSelector }
}
elseif ($eventName -eq 'workflow_dispatch') {
    $buildRun = Find-LatestSuccessfulBuildRunForBranch $callerBranch
}

if ($null -eq $buildRun -and $null -ne $metadata) {
    # Retained Release metadata can outlive Actions run retention. An empty run ID
    # deliberately disables artifact-download fallback in the composite action.
    $buildRun = [pscustomobject]@{ id = ''; path = '.github/workflows/BUILD.yml'; name = 'BUILD'; run_name = $metadata.BuildName; display_title = $metadata.BuildName; head_sha = $metadata.SourceCommit; head_branch = $metadata.Branch; conclusion = 'success' }
}
if ($null -eq $buildRun) { throw 'Could not resolve a BUILD run for deployment.' }
if (-not (Test-IsBuildWorkflowRun $buildRun)) { throw "Resolved run '$($buildRun.id)' is not a BUILD run." }
if ([string]$buildRun.conclusion -ne 'success') { throw "BUILD run '$($buildRun.id)' is not successful." }

if ($requestedReleaseTag -match '[\r\n]') {
    Write-Warning "The selected BUILD provided a malformed multi-line Release tag; resolving it from BUILD run '$($buildRun.id)' instead."
    $requestedReleaseTag = ''
    $release = $null
}
if ([string]::IsNullOrWhiteSpace($requestedReleaseTag)) {
    $runRelease = Find-ReleaseForBuildRun -RunId ([string]$buildRun.id)
    if ($null -ne $runRelease) {
        $release = $runRelease.Release
        $metadata = $runRelease.Metadata
        $requestedReleaseTag = $metadata.TagName
    }
}

$buildName = if ($null -ne $metadata) { $metadata.BuildName } else { Resolve-BuildRunCanonicalName $buildRun }
$buildTagKey = ConvertTo-GateTagSegment $buildName
$sourceSha = if ($null -ne $metadata) { $metadata.SourceCommit } elseif ($eventName -eq 'repository_dispatch' -and $dispatchSourceSha) { $dispatchSourceSha } else { [string]$buildRun.head_sha }
$sourceBranch = if ($null -ne $metadata) { $metadata.Branch } elseif ($eventName -eq 'repository_dispatch') { $dispatchBranch } else { [string]$buildRun.head_branch }
if ([string]::IsNullOrWhiteSpace($sourceBranch) -or $sourceBranch -cne $callerBranch) { throw "Selected BUILD branch '$sourceBranch' does not match deployment branch '$callerBranch'." }
if ([string]::IsNullOrWhiteSpace($sourceSha)) { throw 'Could not resolve the selected build source commit.' }
if ($requestedReleaseTag) { $tagSha = Resolve-GitTagCommitSha $requestedReleaseTag; if ($tagSha -ine $sourceSha) { throw "Selected tag '$requestedReleaseTag' does not match source commit '$sourceSha'." } }

$releaseHasArtifacts = $false
if ($null -ne $release) { $releaseHasArtifacts = @($release.assets | Where-Object { $_.name -eq 'artifacts.zip' }).Count -gt 0 }

# Per-build gates are append-only promotion evidence; the environment pointer is
# separate and moves after deployment in both promotion modes.
$requiredGateTag = if ($promotionMode -eq 'manual-gate-tag' -and $previousName) { "deployed/$buildTagKey/$previousName" } else { '' }
$successGateTag = if ($promotionMode -eq 'manual-gate-tag') { "deployed/$buildTagKey/$environmentName" } else { '' }
$environmentPointerTag = "deployed/$environmentName"
$artifactSource = if ($releaseHasArtifacts) { 'release' } else { 'build' }

"build_run_id=$([string]$buildRun.id)" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
"build_run_name=$buildName" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
"build_source_branch=$sourceBranch" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
"build_source_sha=$sourceSha" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
"build_run_tag_key=$buildTagKey" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
"release_tag=$requestedReleaseTag" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
"artifact_source=$artifactSource" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
"required_gate_tag=$requiredGateTag" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
"success_gate_tag=$successGateTag" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
"environment_pointer_tag=$environmentPointerTag" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
"event_name=$eventName" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
"target_environment=$targetEnvironment" | Out-File -FilePath $env:GITHUB_OUTPUT -Append

Write-Host "Resolved build: $buildName ($([string]$buildRun.id)); branch=$sourceBranch; source=$sourceSha; artifact=$artifactSource"
