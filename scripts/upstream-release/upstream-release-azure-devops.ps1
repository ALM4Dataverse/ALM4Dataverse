#Requires -Version 7.2

<#
.SYNOPSIS
    Azure DevOps fork adapter for upstream release tracking.
.DESCRIPTION
    Implements the fork platform interface (section 7 of upstream-release-functions.ps1)
    for a fork hosted in Azure Repos, using the Azure DevOps REST API with the pipeline's
    job token (System.AccessToken, exposed to the script as SYSTEM_ACCESSTOKEN).

    Differences from GitHub that shape this adapter:
      - A pull-request description is limited to 4,000 characters, so the fork comparison
        and conflict table are posted as a comment thread and the description links to it.
      - The tracking marker is stored as a pull-request property instead of a hidden
        comment, so reviewers can edit the description freely.

    Loaded by upstream-release-functions.ps1; do not dot-source this file on its own.
#>

function Get-AzureDevOpsConvention {
    <#
    .SYNOPSIS
        Returns the Azure DevOps-specific limits and texts used by this adapter.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    [pscustomobject]@{
        ApiVersion           = '7.1'
        # Pull-request properties are still a preview API.
        PropertiesApiVersion = '7.1-preview.1'
        DescriptionLimit     = 4000
        # Identifies the comment threads this automation owns, so a later run can close them.
        DetailsHeading       = '## Upstream release details'
    }
}

function New-AzureDevOpsForkContext {
    <#
    .SYNOPSIS
        Describes a fork hosted in Azure Repos for the engine.
    .DESCRIPTION
        Pure object construction; it changes no state, so it does not support ShouldProcess.
    .PARAMETER CollectionUri
        Organisation URL, as in System.CollectionUri (for example https://dev.azure.com/contoso/).
    .PARAMETER Project
        Project name, as in System.TeamProject.
    .PARAMETER Repository
        Repository name, as in Build.Repository.Name.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs an in-memory object only.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^https://')]
        [string]$CollectionUri,

        [Parameter(Mandatory)]
        [string]$Project,

        [Parameter(Mandatory)]
        [string]$Repository
    )

    $collection = $CollectionUri.TrimEnd('/') + '/'
    $projectPath = [uri]::EscapeDataString($Project)
    $repositoryPath = [uri]::EscapeDataString($Repository)

    [pscustomobject]@{
        Platform      = 'AzureDevOps'
        DisplayName   = "$Project/$Repository"
        CollectionUri = $collection
        Project       = $Project
        Repository    = $Repository
        ApiRoot       = "$collection$projectPath/_apis/git/repositories/$repositoryPath"
        WebRoot       = "$collection$projectPath/_git/$repositoryPath"
    }
}

function Get-AzureDevOpsAccessToken {
    <#
    .SYNOPSIS
        Returns SYSTEM_ACCESSTOKEN, or throws with the pipeline change that provides it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ([string]::IsNullOrEmpty($env:SYSTEM_ACCESSTOKEN)) {
        throw 'SYSTEM_ACCESSTOKEN is not set. Map it in the pipeline step: env: SYSTEM_ACCESSTOKEN: $(System.AccessToken)'
    }
    return $env:SYSTEM_ACCESSTOKEN
}

function Invoke-AzureDevOpsApi {
    <#
    .SYNOPSIS
        Calls the Azure DevOps REST API for the fork repository with the job token.
    .PARAMETER Path
        Path below the repository's API root, optionally with a query string, for example
        'pullrequests?searchCriteria.status=active'. The api-version is appended here.
    .PARAMETER Body
        Request object, serialised to JSON. Arrays are passed whole, not unrolled.
    .PARAMETER ContentType
        Overrides application/json, for example for JSON Patch documents.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Fork,

        [Parameter(Mandatory)]
        [string]$Path,

        [ValidateSet('Get', 'Post', 'Patch')]
        [string]$Method = 'Get',

        [object]$Body,

        [string]$ContentType = 'application/json',

        [string]$ApiVersion = (Get-AzureDevOpsConvention).ApiVersion
    )

    $separator = if ($Path.Contains('?')) { '&' } else { '?' }
    $request = @{
        Uri     = "$($Fork.ApiRoot)/$Path${separator}api-version=$ApiVersion"
        Method  = $Method
        Headers = @{ Authorization = "Bearer $(Get-AzureDevOpsAccessToken)" }
    }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $request.Body = ConvertTo-Json -InputObject $Body -Depth 10
        $request.ContentType = $ContentType
    }
    Invoke-RestMethod @request
}

function Get-AzureDevOpsGitAuthorization {
    <#
    .SYNOPSIS
        Fork platform interface: git Authorization header value for an Azure Repos fork.
    .DESCRIPTION
        The same header the checkout task writes when persistCredentials is true.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return "bearer $(Get-AzureDevOpsAccessToken)"
}

function Get-AzureDevOpsPullRequestUrl {
    <#
    .SYNOPSIS
        Web URL of a pull request; the REST responses carry only API URLs.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Fork,

        [Parameter(Mandatory)]
        [int]$PullRequestId
    )

    return "$($Fork.WebRoot)/pullrequest/$PullRequestId"
}

function Get-AzureDevOpsPullRequestMarker {
    <#
    .SYNOPSIS
        Reads the tracking marker property of a pull request.
    .DESCRIPTION
        The properties response is a dictionary whose keys are property names, each holding
        a '$value'. Keys are read through PSObject.Properties because a missing key is an
        error under strict mode.
    .OUTPUTS
        [pscustomobject] from ConvertFrom-UpstreamTrackingMarker, or $null.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Fork,

        [Parameter(Mandatory)]
        [int]$PullRequestId
    )

    $response = Invoke-AzureDevOpsApi -Fork $Fork -Path "pullRequests/$PullRequestId/properties" -ApiVersion (Get-AzureDevOpsConvention).PropertiesApiVersion
    $properties = $response.PSObject.Properties['value']
    if ($null -eq $properties -or $null -eq $properties.Value) {
        return $null
    }
    $markerProperty = $properties.Value.PSObject.Properties[(Get-UpstreamTrackingConvention).MarkerName]
    if ($null -eq $markerProperty) {
        return $null
    }
    return ConvertFrom-UpstreamTrackingMarker -Json ([string]$markerProperty.Value.'$value')
}

function Set-AzureDevOpsPullRequestMarker {
    <#
    .SYNOPSIS
        Stores the tracking marker as a pull-request property (JSON Patch 'add' replaces it).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Fork,

        [Parameter(Mandatory)]
        [int]$PullRequestId,

        [Parameter(Mandatory)]
        [string]$Marker
    )

    if (-not $PSCmdlet.ShouldProcess("pull request $PullRequestId", 'Set upstream tracking marker')) {
        return
    }
    $patch = @(@{ op = 'add'; path = "/$((Get-UpstreamTrackingConvention).MarkerName)"; value = $Marker })
    Invoke-AzureDevOpsApi -Fork $Fork -Method Patch -Path "pullRequests/$PullRequestId/properties" -Body $patch `
        -ContentType 'application/json-patch+json' -ApiVersion (Get-AzureDevOpsConvention).PropertiesApiVersion | Out-Null
}

function Find-AzureDevOpsPullRequest {
    <#
    .SYNOPSIS
        Fork platform interface: finds update pull requests in Azure Repos.
    .DESCRIPTION
        'closed' covers both completed (merged) and abandoned pull requests. The search
        cannot match a branch prefix, so without a tag every pull request into the base
        branch is listed and the update branches are picked here. Without a base branch, pull
        requests into every branch are listed.

        Open pull requests are read again one by one, because the list truncates
        descriptions and the full text is needed to detect edits.

        The list is read page by page to the end, so an update pull request behind many
        newer ones is still found and its branch is never mistaken for an orphan.
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

    $criteria = @("searchCriteria.status=$(if ($State -eq 'open') { 'active' } else { 'all' })")
    if (-not [string]::IsNullOrEmpty($BaseBranch)) {
        $criteria += "searchCriteria.targetRefName=$([uri]::EscapeDataString("refs/heads/$BaseBranch"))"
    }
    if (-not [string]::IsNullOrEmpty($Tag)) {
        $criteria += "searchCriteria.sourceRefName=$([uri]::EscapeDataString("refs/heads/$(Get-UpdateBranchName -Tag $Tag)"))"
    }
    # The API has no continuation token: a page shorter than $top is the last one.
    $pageSize = 100
    $listed = [System.Collections.Generic.List[object]]::new()
    do {
        $page = @((Invoke-AzureDevOpsApi -Fork $Fork -Path "pullrequests?$($criteria -join '&')&`$top=$pageSize&`$skip=$($listed.Count)").value)
        $listed.AddRange($page)
    } while ($page.Count -eq $pageSize)

    # Azure DevOps lists the newest pull requests first.
    $pullRequests = foreach ($pullRequest in $listed) {
        if ($State -eq 'closed' -and $pullRequest.status -eq 'active') {
            continue
        }
        $branchTag = Get-UpdateBranchTag -BranchName $pullRequest.sourceRefName
        if ($null -eq $branchTag) {
            continue
        }
        # A pull request from a fork of this repository with a branch of the same name has a
        # forkSource and is not this automation's. The property is omitted for pull requests
        # within the repository.
        $forkSource = $pullRequest.PSObject.Properties['forkSource']
        if ($null -ne $forkSource -and $null -ne $forkSource.Value) {
            continue
        }
        $id = [int]$pullRequest.pullRequestId
        $description = $null
        if ($State -eq 'open') {
            $description = [string](Invoke-AzureDevOpsApi -Fork $Fork -Path "pullrequests/$id").description
        }
        [pscustomobject]@{
            Number      = $id
            Url         = Get-AzureDevOpsPullRequestUrl -Fork $Fork -PullRequestId $id
            BranchName  = $pullRequest.sourceRefName -replace '^refs/heads/', ''
            Tag         = $branchTag
            IsMerged    = $pullRequest.status -eq 'completed'
            Marker      = Get-AzureDevOpsPullRequestMarker -Fork $Fork -PullRequestId $id
            Title       = [string]$pullRequest.title
            Description = $description
        }
    }
    return $pullRequests
}

function Test-AzureDevOpsPullRequestActivity {
    <#
    .SYNOPSIS
        Fork platform interface: tells whether people have commented on or voted on a pull request.
    .DESCRIPTION
        Anyone other than the pull request's creator (the pipeline's build service identity,
        which also writes this automation's comments) counts as a person. Votes are read from
        the reviewers; comments from the threads, ignoring the system comments Azure DevOps
        adds for pushes and status changes, and deleted comments.

        Azure DevOps leaves out properties that have no value, such as the reviewers of a pull
        request nobody reviews or the isDeleted flag of a comment that was never deleted, so
        optional properties are read through PSObject.Properties to stay strict-mode safe.
    .OUTPUTS
        [string] such as 'someone voted on it', or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Fork,

        [Parameter(Mandatory)]
        [pscustomobject]$PullRequest
    )

    $readOptional = { param($Item, $Name) $property = $Item.PSObject.Properties[$Name]; if ($null -ne $property) { $property.Value } }

    $details = Invoke-AzureDevOpsApi -Fork $Fork -Path "pullrequests/$($PullRequest.Number)"
    $creatorId = [string]$details.createdBy.id

    $votes = @(& $readOptional $details 'reviewers' | Where-Object { [int]$_.vote -ne 0 -and [string]$_.id -ne $creatorId })
    if ($votes.Count -gt 0) {
        return 'someone voted on it'
    }

    $threads = Invoke-AzureDevOpsApi -Fork $Fork -Path "pullRequests/$($PullRequest.Number)/threads"
    $comments = @(& $readOptional $threads 'value' | Where-Object { -not (& $readOptional $_ 'isDeleted') } |
            ForEach-Object { & $readOptional $_ 'comments' } | Where-Object {
                (& $readOptional $_ 'commentType') -ne 'system' -and -not (& $readOptional $_ 'isDeleted') -and
                [string](& $readOptional $_ 'author').id -ne $creatorId
            })
    if ($comments.Count -gt 0) {
        return 'someone commented on it'
    }
    return $null
}

function Add-AzureDevOpsPullRequestComment {
    <#
    .SYNOPSIS
        Fork platform interface: posts a comment on an Azure Repos pull request.
    .DESCRIPTION
        The comment starts an active thread, so a branch policy that requires comments to be
        resolved asks a reviewer to acknowledge it before completing the pull request.
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

    Add-AzureDevOpsThread -Fork $Fork -PullRequestId $PullRequest.Number -Content $Comment
}

function Get-AzureDevOpsPullRequestComment {
    <#
    .SYNOPSIS
        Fork platform interface: returns the text of every comment on an Azure Repos pull request.
    .DESCRIPTION
        Includes system and deleted comments; the engine only looks for a link it posted.
        Optional properties are read as in Test-AzureDevOpsPullRequestActivity.
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

    $readOptional = { param($Item, $Name) $property = $Item.PSObject.Properties[$Name]; if ($null -ne $property) { $property.Value } }

    $threads = Invoke-AzureDevOpsApi -Fork $Fork -Path "pullRequests/$($PullRequest.Number)/threads"
    & $readOptional $threads 'value' | ForEach-Object { & $readOptional $_ 'comments' } | ForEach-Object {
        [string](& $readOptional $_ 'content')
    }
}

function Close-AzureDevOpsPullRequest {
    <#
    .SYNOPSIS
        Fork platform interface: abandons a replaced Azure Repos pull request.
    .DESCRIPTION
        The engine has already recorded the replacement in the marker and deleted the
        branch. Azure Repos keeps a pull request active when its branch is deleted, so it is
        abandoned here, after the comment.
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

    if (-not $PSCmdlet.ShouldProcess($PullRequest.Url, 'Abandon replaced pull request')) {
        return
    }
    $id = $PullRequest.Number
    Add-AzureDevOpsThread -Fork $Fork -PullRequestId $id -Content $Comment
    Invoke-AzureDevOpsApi -Fork $Fork -Method Patch -Path "pullrequests/$id" -Body @{ status = 'abandoned' } | Out-Null
}

function Get-AzureDevOpsCurrentTagInstruction {
    <#
    .SYNOPSIS
        Tells a maintainer how to rerun the pipeline with the current upstream release set.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # BUILD_DEFINITIONNAME is the running pipeline's name; outside a pipeline, describe it.
    $pipelineName = if ($env:BUILD_DEFINITIONNAME) { "the '$env:BUILD_DEFINITIONNAME' pipeline" } else { 'the upstream tracking pipeline' }
    return "Run $pipelineName manually (Run pipeline) with 'Upstream release tag the base branch already contains' (currentTag) set to that release."
}

function Format-AzureDevOpsPullRequestDescription {
    <#
    .SYNOPSIS
        Builds a description that fits the 4,000-character limit.
    .DESCRIPTION
        The fork comparison and conflict table are replaced by short notes pointing to the
        details comment. If the result is still too long, only the end-user section is cut
        at a line break, because its list of included releases is the part that grows and the
        release notes hold it in full. The conflict warning, the pointers to the details
        comment, Implementation and Validation are always kept.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Content
    )

    $limit = (Get-AzureDevOpsConvention).DescriptionLimit
    $sectionSeparator = "`n`n"
    $forkNote = "## Fork comparison`n`n$(Format-Quantity -Count $Content.DifferenceCount -Singular 'file') differ from the upstream release. " +
        'The full inventory and the pending audit are in the "Upstream release details" comment.'
    $conflictNote = ''
    if ($Content.ConflictCount -gt 0) {
        $conflictNote = "## Unresolved conflicts`n`nThis draft pull request contains committed conflict markers in " +
            "$(Format-Quantity -Count $Content.ConflictCount -Singular 'file'). " +
            'The "Upstream release details" comment lists them.'
    }

    $otherSections = @(
        $forkNote
        $conflictNote
        $Content.Implementation
        $Content.Validation
        '---'
        '_Created by the Track Upstream Release pipeline. A newer upstream release replaces this pull request, unless someone has worked on it; then the new one is opened alongside it._'
    ) | Where-Object { -not [string]::IsNullOrEmpty($_) }
    $rest = $otherSections -join $sectionSeparator

    $description = $Content.EndUserChanges + $sectionSeparator + $rest
    if ($description.Length -le $limit) {
        return $description
    }

    $truncationNote = "`n`n_Release list shortened to fit the Azure DevOps limit; see the release notes for the full list._"
    $endUserBudget = $limit - $rest.Length - $sectionSeparator.Length - $truncationNote.Length
    if ($endUserBudget -le 0) {
        # Only reachable if the fixed sections alone grow past the limit.
        throw "The Azure DevOps pull request description needs $($rest.Length) characters without the release list, more than the limit of $limit."
    }
    $endUserChanges = $Content.EndUserChanges.Substring(0, $endUserBudget)
    $lastLineBreak = $endUserChanges.LastIndexOf("`n")
    if ($lastLineBreak -gt 0) {
        $endUserChanges = $endUserChanges.Substring(0, $lastLineBreak)
    }
    return $endUserChanges.TrimEnd() + $truncationNote + $sectionSeparator + $rest
}

function Add-AzureDevOpsThread {
    <#
    .SYNOPSIS
        Posts a Markdown comment as a new active thread on a pull request.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Fork,

        [Parameter(Mandatory)]
        [int]$PullRequestId,

        [Parameter(Mandatory)]
        [string]$Content
    )

    if (-not $PSCmdlet.ShouldProcess("pull request $PullRequestId", 'Add comment')) {
        return
    }
    $thread = @{
        comments = @(@{ parentCommentId = 0; content = $Content; commentType = 'text' })
        status   = 'active'
    }
    Invoke-AzureDevOpsApi -Fork $Fork -Method Post -Path "pullRequests/$PullRequestId/threads" -Body $thread | Out-Null
}

function Publish-AzureDevOpsPullRequest {
    <#
    .SYNOPSIS
        Fork platform interface: creates the update pull request in Azure Repos.
    .DESCRIPTION
        Then posts the details comment (the fork comparison and the conflict table, which do
        not fit the description limit) and stores the marker property, in that order: the
        marker is stored only once everything else has succeeded.
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

    $description = Format-AzureDevOpsPullRequestDescription -Content $Content
    $request = @{
        sourceRefName = "refs/heads/$BranchName"
        targetRefName = "refs/heads/$BaseBranch"
        title         = $Content.Title
        description   = $description
        isDraft       = $Content.ConflictCount -gt 0
        labels        = @(@{ name = (Get-UpstreamTrackingConvention).PullRequestLabel })
    }
    $created = Invoke-AzureDevOpsApi -Fork $Fork -Method Post -Path 'pullrequests' -Body $request
    $id = [int]$created.pullRequestId

    $details = @((Get-AzureDevOpsConvention).DetailsHeading, $Content.ForkComparison, $Content.Conflicts) |
        Where-Object { -not [string]::IsNullOrEmpty($_) }
    Add-AzureDevOpsThread -Fork $Fork -PullRequestId $id -Content ($details -join "`n`n")

    $marker = ConvertTo-UpstreamTrackingMarker -Baseline $Content.BaselineTag -Head $Head `
        -ContentHash (Get-PullRequestTextHash -Title $Content.Title -Description $description)
    Set-AzureDevOpsPullRequestMarker -Fork $Fork -PullRequestId $id -Marker $marker

    return [pscustomobject]@{ Number = $id; Url = (Get-AzureDevOpsPullRequestUrl -Fork $Fork -PullRequestId $id) }
}
