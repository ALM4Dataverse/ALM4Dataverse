#Requires -Version 7.2

<#
.SYNOPSIS
    Opens a pull request that merges the newest upstream release into this fork, replacing older ones.
.DESCRIPTION
    Entry point for the Track Upstream Release GitHub workflow and Azure DevOps pipeline. It
    describes the fork, changes to the repository root and calls Invoke-UpstreamReleaseTracking,
    which is documented in upstream-release-functions.ps1 together with the steps it performs.

    Choose the fork's platform with -GitHubRepository or -AzureDevOpsRepository. The upstream
    is always a GitHub repository.

    See "Track Upstream Releases" in docs/usage/updating.md for configuration.
.PARAMETER GitHubRepository
    The fork on GitHub as 'owner/name'. The script does nothing when it equals UpstreamRepository.
.PARAMETER ForkTokenSource
    GitHub fork: kind of token in GH_TOKEN, 'app', 'pat' or 'github-token'.
.PARAMETER AzureDevOpsRepository
    The fork's Azure Repos repository name, as in Build.Repository.Name.
.PARAMETER AzureDevOpsCollectionUri
    Azure DevOps fork: organisation URL. Defaults to the pipeline's System.CollectionUri.
.PARAMETER AzureDevOpsProject
    Azure DevOps fork: project name. Defaults to the pipeline's System.TeamProject.
.PARAMETER UpstreamRepository
    Upstream GitHub repository as 'owner/name', for example 'ALM4Dataverse/ALM4Dataverse'.
.PARAMETER BaseBranch
    Fork branch the update pull request targets.
.PARAMETER TargetTag
    Upstream release to merge instead of the newest eligible one. Blank means "not set".
.PARAMETER CurrentTag
    Upstream release the base branch already contains. Needed only when it cannot be detected
    from .github/upstream-release.json or upstream tags in the base branch's history; the
    error then says so. Blank means "not set".
.PARAMETER IncludePrereleases
    Considers upstream prereleases when choosing the newest release.
.PARAMETER DryRun
    Builds the update branch locally and reports the outcome without pushing or changing
    anything on the fork's platform.
.PARAMETER UpstreamRemoteUrl
    Git URL of the upstream; defaults to its github.com URL.
.NOTES
    Run in a disposable checkout of the fork whose 'origin' remote is the fork. The script
    switches branches, commits, and force-pushes the update branch with a lease. Tokens are
    read from GH_TOKEN (GitHub fork), SYSTEM_ACCESSTOKEN (Azure DevOps fork) and
    UPSTREAM_READ_TOKEN.
.EXAMPLE
    ./scripts/upstream-release/update-upstream-release-pr.ps1 -GitHubRepository contoso/ALM4Dataverse -UpstreamRepository ALM4Dataverse/ALM4Dataverse -BaseBranch main -DryRun
.EXAMPLE
    ./scripts/upstream-release/update-upstream-release-pr.ps1 -AzureDevOpsRepository ALM4Dataverse -UpstreamRepository ALM4Dataverse/ALM4Dataverse -BaseBranch main
#>
[CmdletBinding(DefaultParameterSetName = 'GitHub')]
param(
    [Parameter(Mandatory, ParameterSetName = 'GitHub')]
    [string]$GitHubRepository,

    [Parameter(ParameterSetName = 'GitHub')]
    [ValidateSet('app', 'pat', 'github-token')]
    [string]$ForkTokenSource = 'github-token',

    [Parameter(Mandatory, ParameterSetName = 'AzureDevOps')]
    [string]$AzureDevOpsRepository,

    [Parameter(ParameterSetName = 'AzureDevOps')]
    [string]$AzureDevOpsCollectionUri = $env:SYSTEM_COLLECTIONURI,

    [Parameter(ParameterSetName = 'AzureDevOps')]
    [string]$AzureDevOpsProject = $env:SYSTEM_TEAMPROJECT,

    [Parameter(Mandatory)]
    [string]$UpstreamRepository,

    [Parameter(Mandatory)]
    [string]$BaseBranch,

    [string]$TargetTag,

    [string]$CurrentTag,

    [switch]$IncludePrereleases,

    [switch]$DryRun,

    [string]$UpstreamRemoteUrl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'upstream-release-functions.ps1')

$fork = if ($PSCmdlet.ParameterSetName -eq 'GitHub') {
    New-GitHubForkContext -Repository $GitHubRepository -TokenSource $ForkTokenSource
}
else {
    New-AzureDevOpsForkContext -CollectionUri $AzureDevOpsCollectionUri -Project $AzureDevOpsProject -Repository $AzureDevOpsRepository
}

$tracking = @{
    UpstreamRepository = $UpstreamRepository
    Fork               = $fork
    BaseBranch         = $BaseBranch
    TargetTag          = $TargetTag
    CurrentTag         = $CurrentTag
    IncludePrereleases = $IncludePrereleases
    DryRun             = $DryRun
    UpstreamRemoteUrl  = $UpstreamRemoteUrl
}

# The state file and conflict paths are repository-relative.
$repositoryRoot = Invoke-CheckedNativeCommand -Command git -Arguments @('rev-parse', '--show-toplevel') | Select-Object -First 1
Push-Location -LiteralPath $repositoryRoot
try {
    Invoke-UpstreamReleaseTracking @tracking
    # Git commands whose failure is an answer (a missing state file, a commit that is not an
    # ancestor) leave a nonzero $LASTEXITCODE behind. The pwsh steps of GitHub Actions and
    # Azure Pipelines fail on that value even after a successful run, so it is cleared here.
    $global:LASTEXITCODE = 0
}
finally {
    Pop-Location
}
