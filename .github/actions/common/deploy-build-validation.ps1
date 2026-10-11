[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ArtifactsPath,
    [Parameter(Mandatory)][string]$EnvironmentName
)

$ErrorActionPreference = 'Stop'

function Get-GitHubApiHeaders {
    return @{
        Authorization = "Bearer $env:GITHUB_TOKEN"
        Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
}

function Invoke-GitHubApi {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [switch]$AllowNotFound
    )

    $uri = "https://api.github.com/repos/$($env:GITHUB_REPOSITORY)/$RelativePath"
    try {
        return Invoke-RestMethod -Method Get -Uri $uri -Headers (Get-GitHubApiHeaders)
    }
    catch {
        $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        if ($AllowNotFound -and $statusCode -eq 404) {
            return $null
        }
        throw
    }
}

function Get-ReleaseMetadata {
    param([Parameter(Mandatory)][object]$Release)

    $body = [string]$Release.body
    $branch = [regex]::Match($body, '(?im)<!--\s*alm4dataverse-build-branch:(?<value>[^\s]+)\s*-->')
    $build = [regex]::Match($body, '(?im)^Build:\s*(?<value>[^\r\n]+)\s*$')
    $commit = [regex]::Match($body, '(?im)^Source commit:\s*(?<value>[0-9a-f]{40})\s*$')
    $run = [regex]::Match($body, '(?im)^BUILD run:\s*\[(?<value>\d+)\]\s*\(')
    if (-not $branch.Success -or -not $build.Success -or -not $commit.Success -or -not $run.Success) {
        throw "Release '$($Release.tag_name)' does not contain complete ALM4Dataverse build metadata."
    }

    return [pscustomobject]@{
        BuildName = $build.Groups['value'].Value.Trim()
        SourceCommit = $commit.Groups['value'].Value
        RunId = $run.Groups['value'].Value
        TagName = [string]$Release.tag_name
    }
}

function Get-ReleaseByTag {
    param([Parameter(Mandatory)][string]$TagName)

    $encodedTag = [System.Uri]::EscapeDataString($TagName)
    return Invoke-GitHubApi -RelativePath "releases/tags/$encodedTag" -AllowNotFound
}

function Resolve-CommitFromTagReference {
    param([Parameter(Mandatory)][object]$Reference)

    $tagObject = $Reference.object
    while ([string]$tagObject.type -eq 'tag') {
        $annotatedTag = Invoke-GitHubApi -RelativePath "git/tags/$([System.Uri]::EscapeDataString([string]$tagObject.sha))"
        $tagObject = $annotatedTag.object
    }
    if ([string]$tagObject.type -ne 'commit' -or [string]$tagObject.sha -notmatch '^[0-9a-fA-F]{40}$') {
        throw 'The deployment pointer does not resolve to a source commit.'
    }
    return [string]$tagObject.sha
}

function Find-UniqueReleaseForCommit {
    param([Parameter(Mandatory)][string]$CommitSha)

    $matchingReleases = @()
    for ($page = 1; $page -le 100; $page++) {
        $releases = @(Invoke-GitHubApi -RelativePath "releases?per_page=100&page=$page")
        if ($releases.Count -eq 0) {
            break
        }
        foreach ($release in $releases) {
            try {
                $metadata = Get-ReleaseMetadata -Release $release
            }
            catch {
                continue
            }
            if ($metadata.SourceCommit -ine $CommitSha) {
                continue
            }
            $matchingReleases += [pscustomobject]@{
                RunId = $metadata.RunId
                TagName = $metadata.TagName
            }
        }
    }
    if ($matchingReleases.Count -gt 1) {
        throw "Multiple successful BUILD releases match legacy deployment pointer commit '$CommitSha'. Configure a fixed BUILD run ID instead of @environment-name."
    }
    if ($matchingReleases.Count -eq 1) {
        return $matchingReleases[0]
    }
    return $null
}

function Resolve-Baseline {
    param([Parameter(Mandatory)][string]$Selector)

    if ($Selector -match '^\d+$') {
        return [pscustomobject]@{ RunId = $Selector; TagName = '' }
    }

    if ($Selector.StartsWith('@')) {
        $environment = $Selector.Substring(1)
        if ([string]::IsNullOrWhiteSpace($environment) -or $environment -match '(^|/)\.\.?(/|$)') {
            throw "Invalid BUILD validation baseline environment selector '$Selector'."
        }
        $pointerTag = "deployed/$environment"
        $encodedPointerTag = ($pointerTag -split '/' | ForEach-Object { [System.Uri]::EscapeDataString($_) }) -join '/'
        $reference = Invoke-GitHubApi -RelativePath "git/ref/tags/$encodedPointerTag" -AllowNotFound
        if ($null -eq $reference) {
            return $null
        }

        if ([string]$reference.object.type -eq 'tag') {
            $annotatedTag = Invoke-GitHubApi -RelativePath "git/tags/$([System.Uri]::EscapeDataString([string]$reference.object.sha))"
            $tagMessage = [string]$annotatedTag.message
            $runMatch = [regex]::Match($tagMessage, '(?im)^BUILD run:\s*(?<id>\d+)\s*$')
            $releaseMatch = [regex]::Match($tagMessage, '(?im)^Release tag:\s*(?<tag>[^\r\n]+)\s*$')
            if ($runMatch.Success) {
                return [pscustomobject]@{
                    RunId = $runMatch.Groups['id'].Value
                    TagName = $(if ($releaseMatch.Success) { $releaseMatch.Groups['tag'].Value.Trim() } else { '' })
                }
            }
        }

        $commitSha = Resolve-CommitFromTagReference -Reference $reference
        $releaseMatch = Find-UniqueReleaseForCommit -CommitSha $commitSha
        if ($null -eq $releaseMatch) {
            throw "No successful BUILD release was found for the commit currently deployed to '$environment' ($commitSha)."
        }
        return $releaseMatch
    }

    $release = Get-ReleaseByTag -TagName $Selector
    if ($null -eq $release) {
        throw "GitHub Release tag '$Selector' was not found. Use a BUILD run ID, an existing BUILD Release tag, or @environment-name."
    }
    $metadata = Get-ReleaseMetadata -Release $release
    return [pscustomobject]@{
        RunId = $metadata.RunId
        TagName = $metadata.TagName
    }
}

function Assert-SuccessfulBuildRun {
    param([Parameter(Mandatory)][string]$RunId)

    $run = Invoke-GitHubApi -RelativePath "actions/runs/$RunId" -AllowNotFound
    if ($null -eq $run) {
        throw "GitHub BUILD run '$RunId' was not found."
    }
    $workflowPath = [string]$run.path
    if ($workflowPath -notmatch '(?i)(^|/)\.github/workflows/build\.ya?ml(?:@.+)?$' -and [string]$run.name -ine 'BUILD') {
        throw "GitHub run '$RunId' is not a BUILD workflow run."
    }
    if ([string]$run.status -ne 'completed' -or [string]$run.conclusion -ne 'success') {
        throw "GitHub BUILD run '$RunId' did not complete successfully."
    }
}

function Expand-BaselineArchive {
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    if (Test-Path -LiteralPath $DestinationPath) {
        Remove-Item -LiteralPath $DestinationPath -Recurse -Force
    }
    New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $DestinationPath -Force
    $deployScript = Join-Path $DestinationPath 'alm/pipelines/scripts/deploy.ps1'
    if (-not (Test-Path -LiteralPath $deployScript)) {
        throw "Downloaded baseline package does not contain '$deployScript'."
    }
}

function Download-BaselineReleaseAsset {
    param(
        [Parameter(Mandatory)][string]$ReleaseTag,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    $release = Get-ReleaseByTag -TagName $ReleaseTag
    if ($null -eq $release) {
        return $false
    }
    $asset = @($release.assets | Where-Object { [string]$_.name -eq 'artifacts.zip' } | Select-Object -First 1)
    if ($asset.Count -eq 0) {
        return $false
    }

    $downloadDirectory = Join-Path $env:RUNNER_TEMP "alm4dataverse-release-baseline-$([guid]::NewGuid().ToString('N'))"
    $archivePath = Join-Path $downloadDirectory 'artifacts.zip'
    try {
        New-Item -ItemType Directory -Path $downloadDirectory -Force | Out-Null
        $env:GH_TOKEN = $env:GITHUB_TOKEN
        & gh release download $ReleaseTag --repo $env:GITHUB_REPOSITORY --pattern 'artifacts.zip' --dir $downloadDirectory --clobber
        if ($LASTEXITCODE -ne 0) {
            return $false
        }

        if (-not (Test-Path -LiteralPath $archivePath)) {
            return $false
        }
        Expand-BaselineArchive -ArchivePath $archivePath -DestinationPath $DestinationPath
        return $true
    }
    finally {
        if (Test-Path -LiteralPath $downloadDirectory) {
            Remove-Item -LiteralPath $downloadDirectory -Recurse -Force
        }
    }
}

function Download-BaselineRunArtifact {
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    $response = Invoke-GitHubApi -RelativePath "actions/runs/$RunId/artifacts?name=artifacts&per_page=100"
    $artifact = @($response.artifacts | Where-Object { [string]$_.name -eq 'artifacts' -and -not [bool]$_.expired } | Select-Object -First 1)
    if ($artifact.Count -eq 0) {
        throw "BUILD run '$RunId' has no retained 'artifacts' Actions artifact and no downloadable Release asset."
    }

    $archivePath = Join-Path $env:RUNNER_TEMP "alm4dataverse-baseline-$([guid]::NewGuid().ToString('N')).zip"
    try {
        $uri = "https://api.github.com/repos/$($env:GITHUB_REPOSITORY)/actions/artifacts/$($artifact[0].id)/zip"
        Invoke-WebRequest -Method Get -Uri $uri -Headers (Get-GitHubApiHeaders) -OutFile $archivePath
        Expand-BaselineArchive -ArchivePath $archivePath -DestinationPath $DestinationPath
    }
    finally {
        if (Test-Path -LiteralPath $archivePath) {
            Remove-Item -LiteralPath $archivePath -Force
        }
    }
}

$configPath = Join-Path $ArtifactsPath 'alm-config.psd1'
$configuration = if (Test-Path -LiteralPath $configPath) {
    Import-PowerShellDataFile -LiteralPath $configPath
}
else {
    @{}
}
$baselineSelector = ''
if ($configuration.Contains('buildValidation') -and $configuration.buildValidation -and $configuration.buildValidation.Contains('baselineRelease')) {
    $baselineSelector = ([string]$configuration.buildValidation.baselineRelease).Trim()
}

if ([string]::IsNullOrWhiteSpace($baselineSelector)) {
    Write-Host 'No BUILD validation baseline is configured; deploying only the candidate artifacts.'
    & (Join-Path $ArtifactsPath 'alm/pipelines/scripts/deploy.ps1') -ArtifactsPath $ArtifactsPath
    return
}

if ([string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN) -or [string]::IsNullOrWhiteSpace($env:GITHUB_REPOSITORY)) {
    throw 'GITHUB_TOKEN and GITHUB_REPOSITORY are required to resolve the BUILD validation baseline.'
}

$baseline = Resolve-Baseline -Selector $baselineSelector
if ($null -eq $baseline) {
    Write-Warning "No successful deployment pointer exists for '$($baselineSelector.Substring(1))'; skipping the baseline and validating the candidate only."
    & (Join-Path $ArtifactsPath 'alm/pipelines/scripts/deploy.ps1') -ArtifactsPath $ArtifactsPath
    return
}

Assert-SuccessfulBuildRun -RunId ([string]$baseline.RunId)
$baselineArtifactsPath = Join-Path $env:RUNNER_TEMP "alm4dataverse-baseline-$([guid]::NewGuid().ToString('N'))"
try {
    $downloadedFromRelease = $false
    if (-not [string]::IsNullOrWhiteSpace([string]$baseline.TagName)) {
        $downloadedFromRelease = Download-BaselineReleaseAsset -ReleaseTag ([string]$baseline.TagName) -DestinationPath $baselineArtifactsPath
    }
    if (-not $downloadedFromRelease) {
        Download-BaselineRunArtifact -RunId ([string]$baseline.RunId) -DestinationPath $baselineArtifactsPath
    }

    Write-Host "Deploying BUILD baseline run $($baseline.RunId) to validation environment '$EnvironmentName'."
    & (Join-Path $baselineArtifactsPath 'alm/pipelines/scripts/deploy.ps1') -ArtifactsPath $baselineArtifactsPath

    Write-Host "Deploying candidate BUILD artifacts to validation environment '$EnvironmentName'."
    & (Join-Path $ArtifactsPath 'alm/pipelines/scripts/deploy.ps1') -ArtifactsPath $ArtifactsPath
}
finally {
    if (Test-Path -LiteralPath $baselineArtifactsPath) {
        Remove-Item -LiteralPath $baselineArtifactsPath -Recurse -Force
    }
}
