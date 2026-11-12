#Requires -Version 7.2

<#
.SYNOPSIS
    Runs one EXPORT, BUILD and DEPLOY cycle in the GitHub Actions test application.
.DESCRIPTION
    Waits until neither test platform has active runs, then clones the test
    application and regenerates it from this checkout with the setup generators,
    pinning every shared action to SharedWorkflowRef. It raises the unpacked
    solution version to the shared Dev version, pushes with [skip ci], writes a
    unique marker to the Dev environment variable definition, dispatches EXPORT,
    and follows the BUILD and DEPLOY-<Branch> runs that EXPORT starts. Succeeds only
    when the Test environment ends with the same marker.

    With -StopActiveRuns it instead cancels every active run in the test
    application and waits for them to stop, so the shared E2E lock is not released
    while a child run can still change Dev or Test.
.PARAMETER AppRepository
    owner/name of the dedicated GitHub test application. Every active run in it is
    treated as part of E2E.
.PARAMETER SharedWorkflowRepository
    owner/name that the regenerated callers use for shared actions.
.PARAMETER SharedWorkflowRef
    Commit SHA under test. It must be reachable from SharedWorkflowRepository.
.PARAMETER AzDoOrganizationUrl
    Optional. With AzDoProject, also waits for the Azure DevOps test project to be
    idle, because both platforms share the Dev and Test environments.
.NOTES
    Requires git, gh authenticated through GH_TOKEN with contents and actions write
    on AppRepository, and an Azure CLI sign-in that can administer the Dev and Test
    environments. Changes the test repository's main branch and both environments.
.EXAMPLE
    ./.github/scripts/e2e/Invoke-GitHubE2E.ps1 -AppRepository contoso/alm-e2e-app -SharedWorkflowRepository contoso/ALM4Dataverse -SharedWorkflowRef 0123abcd -DevUrl https://contoso-dev.crm.dynamics.com -TestUrl https://contoso-test.crm.dynamics.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AppRepository,
    [Parameter()][string]$SharedWorkflowRepository,
    [Parameter()][string]$SharedWorkflowRef,
    [Parameter()][string]$DevUrl,
    [Parameter()][string]$TestUrl,
    [Parameter()][string]$AzDoOrganizationUrl,
    [Parameter()][string]$AzDoProject,
    [Parameter()][string]$RunLabel = 'local',
    [Parameter()][string]$SolutionName = 'ALM4DataverseE2E',
    [Parameter()][string]$MarkerSchemaName = 'alm4dv_E2EMarker',
    [Parameter()][string]$Branch = 'main',
    [Parameter()][string]$DeploymentEnvironmentName = 'TEST-main',
    [Parameter()][string]$WorkRoot = [System.IO.Path]::GetTempPath(),
    [Parameter()][double]$StageTimeoutMinutes = 90,
    [Parameter()][int]$PollSeconds = 30,
    [Parameter()][switch]$StopActiveRuns
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$almRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
if (-not (Get-Module -Name E2E)) {
    Import-Module (Join-Path $PSScriptRoot 'E2E.psm1')
}

$azDoContext = $null
if ($AzDoOrganizationUrl -and $AzDoProject) {
    $azDoContext = Get-E2EAzDoContext -OrganizationUrl $AzDoOrganizationUrl -Project $AzDoProject -AccessToken (Get-E2EAzDoAccessToken)
}

if ($StopActiveRuns) {
    Stop-E2EGitHubActiveRun -Repository $AppRepository -Confirm:$false
    Wait-E2EResourceIdle -GitHubRepository $AppRepository -TimeoutMinutes 15 -PollSeconds $PollSeconds
    return
}

foreach ($required in 'SharedWorkflowRepository', 'SharedWorkflowRef', 'DevUrl', 'TestUrl') {
    if ([string]::IsNullOrWhiteSpace((Get-Variable -Name $required -ValueOnly))) {
        throw "-$required is required unless -StopActiveRuns is used."
    }
}

Wait-E2EResourceIdle -GitHubRepository $AppRepository -AzDoContext $azDoContext -TimeoutMinutes $StageTimeoutMinutes -PollSeconds $PollSeconds

& gh auth setup-git
if ($LASTEXITCODE -ne 0) { throw 'gh auth setup-git failed.' }
$appRoot = Join-Path $WorkRoot ('alm4dataverse-e2e-github-' + [guid]::NewGuid().ToString('N'))
& git clone --quiet --branch $Branch "https://github.com/$AppRepository.git" $appRoot
if ($LASTEXITCODE -ne 0) { throw "Could not clone $AppRepository." }

Add-E2EStepSummary -Markdown "## GitHub Actions E2E`n`nShared actions: ``$SharedWorkflowRepository@$SharedWorkflowRef```n`n| Stage | Result | Link |`n|---|---|---|"

Update-E2EGitHubAppRepository -RepositoryRoot $appRoot -AlmRoot $almRoot -SharedWorkflowRepository $SharedWorkflowRepository `
    -SharedWorkflowRef $SharedWorkflowRef -SolutionName $SolutionName -Branch $Branch -DeploymentEnvironmentName $DeploymentEnvironmentName -Confirm:$false

Install-E2EDependency -AlmRoot $almRoot -RepositoryRoot $appRoot

$devConnection = Get-E2EDataverseConnection -Url $DevUrl
$devVersion = Get-E2ESolutionVersion -Connection $devConnection -SolutionName $SolutionName
$null = Set-E2ESolutionSourceVersion -RepositoryRoot $appRoot -SolutionName $SolutionName -MinimumVersion $devVersion -Confirm:$false
$null = Publish-E2EAppRepository -RepositoryRoot $appRoot -Branch $Branch -Message "E2E: regenerate from $SharedWorkflowRef [skip ci]" -Confirm:$false

$marker = "e2e-$RunLabel-$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'))"
Set-E2EMarker -Connection $devConnection -SchemaName $MarkerSchemaName -Value $marker -Confirm:$false
Write-Host "Dev marker set to '$marker'."

# The margin absorbs clock skew between this runner and GitHub; the lock and idle
# check mean no unrelated run can appear inside it.
$exportStart = (Get-Date).ToUniversalTime().AddMinutes(-1)
& gh workflow run EXPORT.yml --repo $AppRepository --ref $Branch -f "commit-message=E2E $marker"
if ($LASTEXITCODE -ne 0) { throw 'Could not dispatch EXPORT.' }

$export = Wait-E2EResult -Description 'the EXPORT run to start' -TimeoutMinutes 10 -PollSeconds $PollSeconds -ScriptBlock {
    Find-E2EGitHubRun -Repository $AppRepository -Workflow EXPORT.yml -EventName workflow_dispatch -CreatedAfter $exportStart
}
$null = Wait-E2EStage -Description 'EXPORT' -TimeoutMinutes $StageTimeoutMinutes -PollSeconds $PollSeconds -GetState {
    Get-E2EGitHubRunState -Repository $AppRepository -RunId $export.Id
}

$build = Wait-E2EResult -Description 'the BUILD run requested by EXPORT' -TimeoutMinutes 10 -PollSeconds $PollSeconds -ScriptBlock {
    Find-E2EGitHubRun -Repository $AppRepository -Workflow BUILD.yml -EventName repository_dispatch -CreatedAfter $exportStart
}
$buildStart = (Get-Date).ToUniversalTime().AddMinutes(-1)
$null = Wait-E2EStage -Description 'BUILD' -TimeoutMinutes $StageTimeoutMinutes -PollSeconds $PollSeconds -GetState {
    Get-E2EGitHubRunState -Repository $AppRepository -RunId $build.Id
}

$releases = @(Invoke-E2EGitHubApi -Path "repos/$AppRepository/releases?per_page=10")
if (-not @($releases | Where-Object { ([datetime]$_.created_at).ToUniversalTime() -ge $exportStart })) {
    throw 'BUILD succeeded but did not publish a GitHub Release.'
}

$deploy = Wait-E2EResult -Description "the DEPLOY-$Branch run requested by BUILD" -TimeoutMinutes 10 -PollSeconds $PollSeconds -ScriptBlock {
    Find-E2EGitHubRun -Repository $AppRepository -Workflow "DEPLOY-$Branch.yml" -EventName repository_dispatch -CreatedAfter $buildStart
}
$null = Wait-E2EStage -Description "DEPLOY-$Branch" -TimeoutMinutes $StageTimeoutMinutes -PollSeconds $PollSeconds -GetState {
    Get-E2EGitHubRunState -Repository $AppRepository -RunId $deploy.Id
}

$testMarker = Get-E2EMarker -Connection (Get-E2EDataverseConnection -Url $TestUrl) -SchemaName $MarkerSchemaName
if ($testMarker -ne $marker) {
    throw "Test environment marker is '$testMarker'; expected '$marker' from this run's export."
}
Add-E2EStepSummary -Markdown "`nTest environment marker matches ``$marker``."
Write-Host "E2E cycle succeeded: Test environment has marker '$marker'."
