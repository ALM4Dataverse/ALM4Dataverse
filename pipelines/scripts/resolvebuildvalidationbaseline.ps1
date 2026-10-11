[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$SourceDirectory,
    [Parameter(Mandatory)][string]$CollectionUri,
    [Parameter(Mandatory)][string]$Project,
    [Parameter(Mandatory)][string]$DefinitionId,
    [Parameter(Mandatory)][string]$AccessToken
)

$ErrorActionPreference = 'Stop'

function Get-AzureBuild {
    param([Parameter(Mandatory)][string]$BuildId)

    $projectSegment = [System.Uri]::EscapeDataString($Project)
    $uri = "$($CollectionUri.TrimEnd('/'))/$projectSegment/_apis/build/builds/$BuildId?api-version=7.1"
    return Invoke-RestMethod -Method Get -Uri $uri -Headers @{ Authorization = "Bearer $AccessToken" }
}

function Assert-SuccessfulBuild {
    param([Parameter(Mandatory)][string]$BuildId)

    if ($BuildId -notmatch '^\d+$') {
        throw "BUILD validation baseline resolved to invalid Azure DevOps build ID '$BuildId'."
    }

    $build = Get-AzureBuild -BuildId $BuildId
    if ([string]$build.definition.id -ne $DefinitionId) {
        throw "Baseline build '$BuildId' belongs to pipeline definition '$($build.definition.id)', not BUILD definition '$DefinitionId'."
    }
    if ([string]$build.status -ne 'completed' -or [string]$build.result -ne 'succeeded') {
        throw "Baseline build '$BuildId' is not a successfully completed BUILD run."
    }

    return [string]$build.id
}

function Resolve-FixedBuildIdentifier {
    param([Parameter(Mandatory)][string]$Identifier)

    if ($Identifier -match '^\d+$') {
        return Assert-SuccessfulBuild -BuildId $Identifier
    }

    $projectSegment = [System.Uri]::EscapeDataString($Project)
    $buildNumber = [System.Uri]::EscapeDataString($Identifier)
    $uri = "$($CollectionUri.TrimEnd('/'))/$projectSegment/_apis/build/builds?definitions=$DefinitionId&buildNumber=$buildNumber&statusFilter=completed&resultFilter=succeeded&queryOrder=finishTimeDescending&%24top=100&api-version=7.1"
    $response = Invoke-RestMethod -Method Get -Uri $uri -Headers @{ Authorization = "Bearer $AccessToken" }
    $matches = @($response.value | Where-Object {
        [string]$_.definition.id -eq $DefinitionId -and
        [string]$_.status -eq 'completed' -and
        [string]$_.result -eq 'succeeded' -and
        [string]$_.buildNumber -ceq $Identifier
    })
    if ($matches.Count -eq 0) {
        throw "No successful BUILD run with build number '$Identifier' was found in this Azure DevOps project."
    }
    if ($matches.Count -gt 1) {
        throw "More than one successful BUILD run has build number '$Identifier'; use its numeric run ID instead."
    }
    return [string]$matches[0].id
}

function Find-SuccessfulBuildForCommit {
    param([Parameter(Mandatory)][string]$CommitSha)

    $projectSegment = [System.Uri]::EscapeDataString($Project)
    $baseUri = "$($CollectionUri.TrimEnd('/'))/$projectSegment/_apis/build/builds"
    $continuationToken = ''
    $matchingBuildIds = @()
    do {
        $uri = "$baseUri`?definitions=$DefinitionId&statusFilter=completed&resultFilter=succeeded&queryOrder=finishTimeDescending&%24top=100&api-version=7.1"
        if (-not [string]::IsNullOrWhiteSpace($continuationToken)) {
            $uri += "&continuationToken=$([System.Uri]::EscapeDataString($continuationToken))"
        }

        $response = Invoke-WebRequest -Method Get -Uri $uri -Headers @{ Authorization = "Bearer $AccessToken" } -SkipHttpErrorCheck
        if ([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 300) {
            throw "Azure DevOps build query failed with HTTP $($response.StatusCode): $($response.Content)"
        }
        $payload = $response.Content | ConvertFrom-Json
        $builds = @($payload.value)
        $match = $builds | Where-Object {
            [string]$_.definition.id -eq $DefinitionId -and
            [string]$_.status -eq 'completed' -and
            [string]$_.result -eq 'succeeded' -and
            [string]$_.sourceVersion -ieq $CommitSha
        } | Select-Object -First 1
        if ($match) {
            $matchingBuildIds += [string]$match.id
        }

        $continuationToken = [string]$response.Headers['x-ms-continuationtoken']
    } while (-not [string]::IsNullOrWhiteSpace($continuationToken))

    if ($matchingBuildIds.Count -gt 1) {
        throw "Multiple successful BUILD runs match legacy deployment pointer commit '$CommitSha'. Configure a fixed BUILD run ID or build number instead of @environment-name."
    }
    if ($matchingBuildIds.Count -eq 0) {
        throw "No successful BUILD run was found for source commit '$CommitSha'."
    }
    return $matchingBuildIds[0]
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "BUILD validation configuration was not found: $ConfigPath"
}

$config = Import-PowerShellDataFile -LiteralPath $ConfigPath
$selector = ''
if ($config.Contains('buildValidation') -and $config.buildValidation -and $config.buildValidation.Contains('baselineRelease')) {
    $selector = ([string]$config.buildValidation.baselineRelease).Trim()
}

if ([string]::IsNullOrWhiteSpace($selector)) {
    Write-Host 'No BUILD validation baseline is configured.'
    Write-Host '##vso[task.setvariable variable=BuildValidationBaselineBuildId]'
    return
}

$baselineBuildId = ''
if ($selector -notmatch '^@') {
    $baselineBuildId = Resolve-FixedBuildIdentifier -Identifier $selector
}
elseif ($selector -match '^@(?<environment>[A-Za-z0-9._/-]+)$' -and $Matches.environment -notmatch '(^|/)\.\.?(/|$)') {
    $environmentName = $Matches.environment
    $pointerTag = "deployed/$environmentName"
    $tagRef = "refs/tags/$pointerTag"
    $fetchRefspec = "+$tagRef`:$tagRef"
    Push-Location $SourceDirectory
    try {
        $pointerLookupOutput = @(& git ls-remote --exit-code origin $tagRef 2>&1)
        $pointerLookupExitCode = $LASTEXITCODE
        if ($pointerLookupExitCode -eq 2) {
            Write-Warning "No successful deployment pointer exists for '$environmentName'; skipping the baseline and validating the candidate only."
            Write-Host '##vso[task.setvariable variable=BuildValidationBaselineBuildId]'
            $global:LASTEXITCODE = 0
            return
        }
        if ($pointerLookupExitCode -ne 0) {
            throw "Could not check deployment pointer '$pointerTag': $($pointerLookupOutput -join ' ')"
        }

        & git fetch --force origin $fetchRefspec 2>&1 | Write-Host
        if ($LASTEXITCODE -ne 0) {
            throw "Could not fetch deployment pointer '$pointerTag'. Ensure '$environmentName' has a successful deployment."
        }

        $tagType = (& git cat-file -t $tagRef 2>$null).Trim()
        if ($LASTEXITCODE -ne 0) {
            throw "Deployment pointer '$pointerTag' could not be read."
        }

        if ($tagType -eq 'tag') {
            $tagContents = @(& git cat-file -p $tagRef)
            if ($LASTEXITCODE -ne 0) {
                throw "Annotated deployment pointer '$pointerTag' could not be read."
            }
            $tagContentsText = $tagContents -join "`n"
            $runIdMatch = [regex]::Match([string]$tagContentsText, '(?im)^(?:BUILD run|Build ID):\s*(?<id>\d+)\s*$')
            if ($runIdMatch.Success) {
                $baselineBuildId = Assert-SuccessfulBuild -BuildId $runIdMatch.Groups['id'].Value
            }
        }

        if ([string]::IsNullOrWhiteSpace($baselineBuildId)) {
            $commitSha = (& git rev-list -n 1 $tagRef).Trim()
            if ($LASTEXITCODE -ne 0 -or $commitSha -notmatch '^[0-9a-fA-F]{40}$') {
                throw "Deployment pointer '$pointerTag' does not resolve to a source commit."
            }
            Write-Host "The '$pointerTag' pointer predates build-ID metadata; resolving a successful BUILD run for commit $commitSha."
            $baselineBuildId = Find-SuccessfulBuildForCommit -CommitSha $commitSha
        }
    }
    finally {
        Pop-Location
    }
}
else {
    throw "Unsupported BUILD validation baseline '$selector'. Use an Azure DevOps BUILD run ID or @environment-name."
}

$baselineBuildId = Assert-SuccessfulBuild -BuildId $baselineBuildId
Write-Host "Resolved BUILD validation baseline to Azure DevOps run $baselineBuildId."
Write-Host "##vso[task.setvariable variable=BuildValidationBaselineBuildId]$baselineBuildId"
