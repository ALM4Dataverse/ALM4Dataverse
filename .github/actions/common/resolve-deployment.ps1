$ErrorActionPreference = 'Stop'

function Get-GitHubApiHeaders {
    return @{
        Authorization = "Bearer $($env:GITHUB_TOKEN)"
        Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
}

function Invoke-GitHubApi([string]$relativePath) {
    $uri = "https://api.github.com/repos/$($env:GITHUB_REPOSITORY)/$relativePath"
    return Invoke-RestMethod -Uri $uri -Headers (Get-GitHubApiHeaders)
}

function Resolve-BuildRunDisplayName([object]$run) {
    foreach ($propertyName in @('display_title', 'run_name')) {
        if ($run.PSObject.Properties.Name -contains $propertyName) {
            $value = [string]$run.$propertyName
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                return $value.Trim()
            }
        }
    }

    $headBranch = if ($run.PSObject.Properties.Name -contains 'head_branch') { [string]$run.head_branch } else { '' }
    $runNumber = if ($run.PSObject.Properties.Name -contains 'run_number') { [string]$run.run_number } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($headBranch) -and -not [string]::IsNullOrWhiteSpace($runNumber)) {
        return "$headBranch-$runNumber"
    }

    return ([string]$run.id).Trim()
}

function Resolve-BuildRunCanonicalName([object]$run) {
    $displayName = Resolve-BuildRunDisplayName -run $run
    if (-not [string]::IsNullOrWhiteSpace($displayName)) {
        return $displayName.Trim()
    }

    $repoName = ''
    foreach ($repoProperty in @('head_repository', 'repository')) {
        if ($run.PSObject.Properties.Name -contains $repoProperty) {
            $repo = $run.$repoProperty
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

    $branchName = if ($run.PSObject.Properties.Name -contains 'head_branch') { [string]$run.head_branch } else { '' }
    $branchName = $branchName -replace '[^a-zA-Z0-9._/-]', '-'
    $createdAt = if ($run.PSObject.Properties.Name -contains 'created_at') { [string]$run.created_at } else { '' }
    $formattedDate = if (-not [string]::IsNullOrWhiteSpace($createdAt)) { ([DateTimeOffset]::Parse($createdAt)).ToString('yyyy-MM-dd-HHmmss') } else { '' }
    $runNumber = if ($run.PSObject.Properties.Name -contains 'run_number') { [string]$run.run_number } else { '' }

    if (-not [string]::IsNullOrWhiteSpace($repoName) -and
        -not [string]::IsNullOrWhiteSpace($branchName) -and
        -not [string]::IsNullOrWhiteSpace($formattedDate) -and
        -not [string]::IsNullOrWhiteSpace($runNumber)) {
        return "$repoName-$branchName-$formattedDate-$runNumber"
    }

    return Resolve-BuildRunDisplayName -run $run
}

function ConvertTo-GateTagSegment([string]$value) {
    $sanitized = $value.Trim()
    $sanitized = $sanitized -replace '[^a-zA-Z0-9._/-]', '-'
    $sanitized = $sanitized -replace '-{2,}', '-'
    $sanitized = $sanitized -replace '\.{2,}', '.'
    $sanitized = $sanitized -replace '/{2,}', '/'
    $sanitized = $sanitized.Trim('/', '.', '-')
    if ($sanitized.EndsWith('.lock')) {
        $sanitized = $sanitized -replace '\.lock$', '-lock'
    }
    if ([string]::IsNullOrWhiteSpace($sanitized)) {
        throw "Build run name '$value' cannot be converted to a valid gate tag segment."
    }
    return $sanitized
}

function Resolve-WorkflowDispatchBranch([object]$githubContext) {
    $refType = if ($githubContext.PSObject.Properties.Name -contains 'ref_type') { [string]$githubContext.ref_type } else { '' }
    $refName = if ($githubContext.PSObject.Properties.Name -contains 'ref_name') { [string]$githubContext.ref_name } else { '' }

    if ([string]::IsNullOrWhiteSpace($refName) -and $githubContext.PSObject.Properties.Name -contains 'ref') {
        $fullRef = [string]$githubContext.ref
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

function Get-BuildRunById([string]$runId) {
    return Invoke-GitHubApi "actions/runs/$runId"
}

function Test-IsBuildWorkflowRun([object]$run) {
    $workflowPath = if ($run.PSObject.Properties.Name -contains 'path') { [string]$run.path } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($workflowPath) -and $workflowPath -match '(?i)(^|/)\.github/workflows/build\.ya?ml(?:@.+)?$') {
        return $true
    }

    $workflowName = if ($run.PSObject.Properties.Name -contains 'name') { [string]$run.name } else { '' }
    return -not [string]::IsNullOrWhiteSpace($workflowName) -and $workflowName.Trim() -ieq 'BUILD'
}

function Find-BuildRunByName([string]$runName) {
    for ($page = 1; $page -le 10; $page++) {
        $response = Invoke-GitHubApi "actions/workflows/BUILD.yml/runs?per_page=100&page=$page"
        $runs = @($response.workflow_runs)
        if ($runs.Count -eq 0) { break }

        $match = $runs | Where-Object {
            (Resolve-BuildRunDisplayName $_) -ieq $runName -or
            (Resolve-BuildRunCanonicalName $_) -ieq $runName
        } | Select-Object -First 1
        if ($match) { return $match }
    }

    throw "No BUILD workflow run named '$runName' was found. Use the exact BUILD name shown in the Actions run title or supply the numeric run ID instead."
}

function Find-LatestSuccessfulBuildRunForBranch([string]$branchName) {
    $requestedBranch = $branchName.Trim()
    if ([string]::IsNullOrWhiteSpace($requestedBranch)) {
        throw 'Cannot resolve the latest BUILD run because the selected workflow branch is empty.'
    }

    $encodedBranch = [System.Uri]::EscapeDataString($requestedBranch)
    $response = Invoke-GitHubApi "actions/workflows/BUILD.yml/runs?branch=$encodedBranch&status=success&per_page=1"
    $runs = @($response.workflow_runs)
    if ($runs.Count -eq 0) {
        throw "No successful BUILD workflow runs were found for branch '$requestedBranch'. Run BUILD on that branch first or supply build-run-name explicitly."
    }
    return $runs[0]
}

$environmentName = $env:INPUT_ENVIRONMENT_NAME.Trim()
$previousName = $env:INPUT_PREVIOUS_ENVIRONMENT_NAME.Trim()
$promotionMode = $env:INPUT_PROMOTION_MODE.Trim()

try { $githubContext = $env:INPUT_GITHUB_CONTEXT_JSON | ConvertFrom-Json -Depth 100 } catch { throw 'github-context-json is not valid JSON.' }
try { $callerInputs = $env:INPUT_CALLER_INPUTS_JSON | ConvertFrom-Json -Depth 50 } catch { throw 'caller-inputs-json is not valid JSON.' }

$eventName = [string]$githubContext.event_name
$repositoryDispatchBuildRunId = [string]$githubContext.event.client_payload.build_run_id
$repositoryDispatchBranch = [string]$githubContext.event.client_payload.branch
$triggerBranchInput = [string]$env:INPUT_TRIGGER_BRANCH
$manualRunSpecifier = [string]$callerInputs.'build-run-name'
if ([string]::IsNullOrWhiteSpace($manualRunSpecifier)) { $manualRunSpecifier = [string]$callerInputs.'build-run-id' }
$targetEnv = [string]$callerInputs.'target-environment'
$workflowDispatchBranch = ''

if ($eventName -eq 'repository_dispatch' -and [string]::IsNullOrWhiteSpace($triggerBranchInput)) {
    throw "repository_dispatch requires deploy input 'trigger-branch' to be set."
}
if ($promotionMode -notin @('manual-gate-tag', 'environment-approval')) {
    throw "Unsupported promotion-mode '$promotionMode'. Use 'manual-gate-tag' or 'environment-approval'."
}
if ($eventName -eq 'workflow_dispatch' -and [string]::IsNullOrWhiteSpace($targetEnv) -and $promotionMode -ne 'environment-approval') {
    throw "workflow_dispatch requires caller inputs to include 'target-environment' unless promotion-mode is 'environment-approval'."
}

$buildRun = switch ($eventName) {
    'repository_dispatch' {
        if ([string]::IsNullOrWhiteSpace($repositoryDispatchBuildRunId)) { throw 'repository_dispatch payload is missing client_payload.build_run_id.' }
        Get-BuildRunById $repositoryDispatchBuildRunId
    }
    'workflow_dispatch' {
        if ([string]::IsNullOrWhiteSpace($manualRunSpecifier)) {
            $workflowDispatchBranch = Resolve-WorkflowDispatchBranch $githubContext
            Find-LatestSuccessfulBuildRunForBranch $workflowDispatchBranch
        }
        elseif ($manualRunSpecifier.Trim() -match '^\d+$') {
            Get-BuildRunById $manualRunSpecifier.Trim()
        }
        else {
            Find-BuildRunByName $manualRunSpecifier.Trim()
        }
    }
    default { throw "Unsupported trigger-event-name '$eventName'." }
}

$buildRunId = [string]$buildRun.id
$buildRunName = Resolve-BuildRunCanonicalName $buildRun
if ($eventName -eq 'workflow_dispatch' -and -not [string]::IsNullOrWhiteSpace($manualRunSpecifier) -and $manualRunSpecifier.Trim() -notmatch '^\d+$') {
    $buildRunName = $manualRunSpecifier.Trim()
}
$buildRunTagKey = ConvertTo-GateTagSegment $buildRunName
$buildRunWorkflowPath = [string]$buildRun.path
$buildRunWorkflowName = [string]$buildRun.name
$buildRunConclusion = [string]$buildRun.conclusion

if (-not (Test-IsBuildWorkflowRun $buildRun)) {
    throw "Resolved workflow run '$buildRunId' does not belong to BUILD.yml. GitHub reported path '$buildRunWorkflowPath' and workflow name '$buildRunWorkflowName'."
}
if ($buildRunConclusion -ne 'success') {
    throw "BUILD workflow run '$buildRunName' ($buildRunId) has conclusion '$buildRunConclusion'. Only successful BUILD runs can be deployed."
}

$requiredGateTag = ''
if ($promotionMode -eq 'manual-gate-tag' -and -not [string]::IsNullOrWhiteSpace($previousName)) {
    $requiredGateTag = "$buildRunTagKey/deployed/$previousName"
}
$successGateTag = "$buildRunTagKey/deployed/$environmentName"
$environmentPointerTag = "deployed/$environmentName"

"build_run_id=$buildRunId" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
"build_run_name=$buildRunName" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
"build_run_tag_key=$buildRunTagKey" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
"required_gate_tag=$requiredGateTag" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
"success_gate_tag=$successGateTag" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
"environment_pointer_tag=$environmentPointerTag" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
"event_name=$eventName" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
"target_environment=$targetEnv" | Out-File -FilePath $env:GITHUB_OUTPUT -Append

Write-Host "Resolved build run id: $buildRunId"
Write-Host "Resolved build run name: $buildRunName"
Write-Host "Resolved build run tag key: $buildRunTagKey"
Write-Host "Resolved required gate tag: $requiredGateTag"
Write-Host "Resolved success gate tag: $successGateTag"
Write-Host "Resolved environment pointer tag: $environmentPointerTag"