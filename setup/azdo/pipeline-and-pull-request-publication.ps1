function Update-DeployPipelineInWorkingTree {
    <#
    .SYNOPSIS
    Replaces scaffold deployment-template entries with the selected environment sequence.
    .NOTES
    An empty target list removes the branch DEPLOY file; nonempty targets require the
    scaffold to exist. The line scanner recognizes the exact template and six-space
    parameter layout, not arbitrary YAML. Preserves other lines and appends entries
    in promotion order. Parameters other than environmentName and
    useAlm4DataverseExtension (for example secretVariables or timeoutInMinutes),
    including their nested lines, are carried over to the regenerated entry for the
    same environment name; entries for removed environments are dropped.
    Returns whether content changed (false under WhatIf).
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][array]$Environments,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter()][bool]$UseAlm4DataverseExtension = $true
    )

    if (-not $PSCmdlet.ShouldProcess($RepoRoot, 'Update Azure DevOps DEPLOY pipeline')) { return $false }

    $deployYamlName = "DEPLOY-$Branch.yml"
    $deployYamlPath = Join-Path $RepoRoot "pipelines\$deployYamlName"

    if (-not $Environments -or $Environments.Count -eq 0) {
        if (Test-Path -LiteralPath $deployYamlPath) {
            Remove-Item -LiteralPath $deployYamlPath -Force
            Write-Host "$deployYamlName removed because branch '$Branch' has no deployment environments configured." -ForegroundColor Yellow
            return $true
        }

        Write-Host "$deployYamlName is not required because branch '$Branch' has no deployment environments configured." -ForegroundColor Yellow
        return $false
    }

    if (-not (Test-Path -LiteralPath $deployYamlPath)) {
        throw "pipelines\$deployYamlName not found"
    }

    $originalContent = Get-Content -LiteralPath $deployYamlPath -Raw
    $contentLines = Get-Content -LiteralPath $deployYamlPath
    $cleanedContent = @()
    $preservedParameterLines = @{}
    $i = 0
    while ($i -lt $contentLines.Count) {
        $line = $contentLines[$i]
        if ($line.Trim() -eq '- template: pipelines/templates/stages/deploy-environment.yml@ALM4Dataverse') {
            $i++
            if ($i -lt $contentLines.Count -and $contentLines[$i].Trim() -eq 'parameters:') {
                $i++
                $existingEnvironmentName = $null
                $extraLines = [System.Collections.Generic.List[string]]::new()
                $inExtraParameter = $false
                # Deeper lines belong to the preceding parameter, such as list items.
                while ($i -lt $contentLines.Count -and $contentLines[$i] -match '^\s{6,}\S') {
                    $parameterLine = $contentLines[$i]
                    if ($parameterLine -match '^\s{6}environmentName:\s*(.*?)\s*$') {
                        $existingEnvironmentName = $Matches[1].Trim("'", '"')
                        $inExtraParameter = $false
                    }
                    elseif ($parameterLine -match '^\s{6}useAlm4DataverseExtension:') {
                        $inExtraParameter = $false
                    }
                    elseif ($parameterLine -match '^\s{6}\S') {
                        $inExtraParameter = $true
                        $extraLines.Add($parameterLine)
                    }
                    elseif ($inExtraParameter) {
                        $extraLines.Add($parameterLine)
                    }
                    $i++
                }
                if (-not [string]::IsNullOrWhiteSpace($existingEnvironmentName) -and $extraLines.Count -gt 0) {
                    $preservedParameterLines[$existingEnvironmentName] = @($extraLines)
                }
            }
        }
        else {
            $cleanedContent += $line
            $i++
        }
    }

    $newStages = "`n"
    foreach ($env in $Environments) {
        $newStages += "  - template: pipelines/templates/stages/deploy-environment.yml@ALM4Dataverse`n"
        $newStages += "    parameters:`n"
        $newStages += "      environmentName: $($env.ShortName)`n"
        $newStages += "      useAlm4DataverseExtension: $($UseAlm4DataverseExtension.ToString().ToLowerInvariant())`n"
        if ($preservedParameterLines.ContainsKey([string]$env.ShortName)) {
            foreach ($preservedLine in $preservedParameterLines[[string]$env.ShortName]) {
                $newStages += "$preservedLine`n"
            }
        }
    }

    $updatedContent = (($cleanedContent -join [Environment]::NewLine).TrimEnd() + $newStages).TrimEnd() + [Environment]::NewLine
    if ($updatedContent -eq $originalContent) {
        Write-Host "$deployYamlName already matches the selected deployment environments." -ForegroundColor Green
        return $false
    }

    Set-Content -LiteralPath $deployYamlPath -Value $updatedContent -NoNewline
    Write-Host "$deployYamlName updated in the working tree." -ForegroundColor Green
    return $true
}

function New-AzDoPullRequest {
    # SourceBranch/TargetBranch are short names: refs/heads/ is added to the REST payload.
    # Return the API response, or nothing if ShouldProcess declines; API failures propagate.
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$RepositoryId,
        [Parameter(Mandatory)][string]$SourceBranch,
        [Parameter(Mandatory)][string]$TargetBranch,
        [Parameter(Mandatory)][string]$Title,
        [Parameter()][string]$Description
    )

    if (-not $PSCmdlet.ShouldProcess($RepositoryId, 'Create Azure DevOps pull request')) { return }

    $body = @{
        sourceRefName = "refs/heads/$SourceBranch"
        targetRefName = "refs/heads/$TargetBranch"
        title         = $Title
        description   = $Description
    }

    return Invoke-VSTeamRequest -Method POST -Resource "git/repositories/$RepositoryId/pullrequests" -Body ($body | ConvertTo-Json -Depth 10) -ContentType 'application/json' -Version '7.1'
}

function Publish-AzDoRepoChange {
    <#
    .SYNOPSIS
    Stages all clone changes, commits/pushes the planned branch and optionally creates a pull request.
    .OUTPUTS
    System.Management.Automation.PSCustomObject. HasChanges, BranchName, TargetBranch,
    PullRequestUrl and Mode. Native Git output can also appear on the success stream.
    .NOTES
    Assumes the planned branch is already checked out. Even a clean index is pushed
    to ensure the branch exists, but no PR is created for that no-change path.
    Writes clone-local author config; location/error preference are restored on failure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][object]$PublishPlan,
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][object]$Repository
    )

    Push-Location $RepoRoot
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & git add -A
        if ($LASTEXITCODE -ne 0) {
            throw 'Git add failed.'
        }

        & git diff --cached --quiet
        $hasChanges = ($LASTEXITCODE -ne 0)
        if (-not $hasChanges) {
            Write-Host "No content changes detected, but ensuring branch '$($PublishPlan.BranchName)' exists on origin..." -ForegroundColor Yellow
            & git -c "http.extraheader=AUTHORIZATION: bearer $AccessToken" push -u origin $PublishPlan.BranchName 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw 'Git push failed.'
            }

            Write-Host 'No changes to commit; main repo already contains the required files.' -ForegroundColor Green
            return [pscustomobject]@{
                HasChanges     = $false
                BranchName     = $PublishPlan.BranchName
                TargetBranch   = $PublishPlan.TargetBranch
                PullRequestUrl = $null
                Mode           = $PublishPlan.Mode
            }
        }

        & git config user.name 'ALM4Dataverse Setup' 2>$null
        & git config user.email 'setup@alm4dataverse.local' 2>$null

        & git commit -m $PublishPlan.CommitMessage 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw 'Git commit failed.'
        }

        Write-Host "Pushing to origin/$($PublishPlan.BranchName)..." -ForegroundColor Yellow
        & git -c "http.extraheader=AUTHORIZATION: bearer $AccessToken" push -u origin $PublishPlan.BranchName 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw 'Git push failed.'
        }

        $pullRequestUrl = $null
        if ($PublishPlan.Mode -eq 'PullRequest') {
            Write-Host "Creating pull request into '$($PublishPlan.TargetBranch)'..." -ForegroundColor Yellow
            $pullRequest = New-AzDoPullRequest `
                -RepositoryId $Repository.Id `
                -SourceBranch $PublishPlan.BranchName `
                -TargetBranch $PublishPlan.TargetBranch `
                -Title $PublishPlan.PullRequestTitle `
                -Description $PublishPlan.PullRequestDescription

            if ($pullRequest -and $pullRequest._links -and $pullRequest._links.web -and $pullRequest._links.web.href) {
                $pullRequestUrl = $pullRequest._links.web.href
            }
            elseif ($pullRequest -and $pullRequest.url) {
                $pullRequestUrl = $pullRequest.url
            }
        }

        Write-Host 'Main repository updated successfully.' -ForegroundColor Green
        return [pscustomobject]@{
            HasChanges     = $true
            BranchName     = $PublishPlan.BranchName
            TargetBranch   = $PublishPlan.TargetBranch
            PullRequestUrl = $pullRequestUrl
            Mode           = $PublishPlan.Mode
        }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        Pop-Location
    }
}

function Invoke-AzDoSetupArtifactGeneration {
    <#
    .SYNOPSIS
    Generates configuration and pipeline YAML for one Azure DevOps setup publication.
    .DESCRIPTION
    Shared by publication and preview so both paths use the same generators. This
    function only writes files below RepoRoot; it does not contact Azure DevOps.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$CopyRoot,
        [Parameter(Mandatory)][object]$MainRepo,
        [Parameter(Mandatory)][string]$SharedRepositoryName,
        [Parameter(Mandatory)][string]$SharedRepositoryRef,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][bool]$UseAlm4DataverseExtension,
        [Parameter()][AllowNull()][array]$Solutions,
        [Parameter()][AllowEmptyCollection()][array]$DeploymentEnvironments = @(),
        [Parameter()][bool]$BuildValidationEnabled = $false,
        [Parameter()][AllowEmptyString()][string]$BuildValidationEnvironmentName = '',
        [Parameter()][AllowEmptyString()][string]$BuildValidationBaselineRelease = '',
        [Parameter()][System.Collections.IDictionary]$BuildValidationEnvironments = @{},
        [Parameter()][System.Collections.IDictionary]$SetupSettings
    )

    Sync-CopyToYourRepoIntoGitRepo `
        -SourceRoot $CopyRoot `
        -TargetRoot $RepoRoot `
        -RepositoryName $MainRepo.Name `
        -SharedRepositoryName $SharedRepositoryName `
        -SharedRepositoryRef $SharedRepositoryRef `
        -Branch $Branch `
        -UseAlm4DataverseExtension $UseAlm4DataverseExtension | Out-Null

    Update-AlmConfigInWorkingTree `
        -Solutions $Solutions `
        -BuildValidationEnabled $BuildValidationEnabled `
        -BuildValidationBaselineRelease $BuildValidationBaselineRelease `
        -RepoRoot $RepoRoot `
        -SetupSettings $SetupSettings | Out-Null

    Update-AzDoBuildPipelineInWorkingTree `
        -RepoRoot $RepoRoot `
        -SharedRepositoryName $SharedRepositoryName `
        -SharedRepositoryRef $SharedRepositoryRef `
        -BuildEnvironmentName $(if ($BuildValidationEnabled) { $BuildValidationEnvironmentName } else { '' }) `
        -UseAlm4DataverseExtension $UseAlm4DataverseExtension `
        -BuildValidationEnvironments $BuildValidationEnvironments | Out-Null

    Update-DeployPipelineInWorkingTree `
        -Environments $DeploymentEnvironments `
        -RepoRoot $RepoRoot `
        -Branch $Branch `
        -UseAlm4DataverseExtension $UseAlm4DataverseExtension | Out-Null
}

function Publish-AzDoBranchSetupChange {
    <#
    .SYNOPSIS
    Rebuilds one branch's setup files in the disposable clone and publishes its plan.
    .NOTES
    Destructively resets tracked changes and cleans untracked files before switching
    branches; RepoRoot must not be a user's working checkout. Existing target history
    wins, then default-branch history, then an orphan/available HEAD path.
    PR mode first creates a missing target branch (with an empty commit if needed)
    so Azure DevOps has a target. Null Solutions preserves that branch's list.
    Returns the publication result; failures do not roll back prior remote pushes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ConfiguredBranch,
        [Parameter(Mandatory)][object]$PublishPlan,
        [Parameter(Mandatory)][string]$DefaultBranch,
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][object]$Repository,
        [Parameter(Mandatory)][string]$CopyRoot,
        [Parameter(Mandatory)][string]$SharedRepositoryName,
        [Parameter()][string]$SharedRepositoryRef = 'main',
        [Parameter(Mandatory)][bool]$UseAlm4DataverseExtension,
        [Parameter()][AllowNull()][array]$Solutions,
        [Parameter()][array]$DeploymentEnvironments,
        [Parameter()][bool]$BuildValidationEnabled = $false,
        [Parameter()][AllowEmptyString()][string]$BuildValidationEnvironmentName = '',
        [Parameter()][AllowEmptyString()][string]$BuildValidationBaselineRelease = '',
        [Parameter()][System.Collections.IDictionary]$BuildValidationEnvironments = @{},
        [Parameter()][System.Collections.IDictionary]$SetupSettings
    )

    Push-Location $RepoRoot
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & git -c "http.extraheader=AUTHORIZATION: bearer $AccessToken" fetch origin '+refs/heads/*:refs/remotes/origin/*' --prune 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'Failed to refresh remote branches before publishing.'
        }

        & git reset --hard HEAD 2>&1 | Out-Null
        & git clean -fd 2>&1 | Out-Null

        & git -c "http.extraheader=AUTHORIZATION: bearer $AccessToken" -c credential.interactive=never ls-remote --exit-code --heads origin $ConfiguredBranch 2>&1 | Out-Null
        $targetBranchExistsOnOrigin = ($LASTEXITCODE -eq 0)

        & git -c "http.extraheader=AUTHORIZATION: bearer $AccessToken" -c credential.interactive=never ls-remote --exit-code --heads origin $DefaultBranch 2>&1 | Out-Null
        $defaultBranchExistsOnOrigin = ($LASTEXITCODE -eq 0)

        $seedRef = if ($targetBranchExistsOnOrigin) {
            "origin/$ConfiguredBranch"
        }
        elseif ($defaultBranchExistsOnOrigin) {
            "origin/$DefaultBranch"
        }
        else {
            $null
        }

        if ($PublishPlan.Mode -eq 'PullRequest' -and -not $targetBranchExistsOnOrigin) {
            Write-Host "Initializing target branch '$ConfiguredBranch' on origin before creating a pull request..." -ForegroundColor Yellow

            if ($seedRef) {
                & git checkout -B $ConfiguredBranch $seedRef 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to create local target branch '$ConfiguredBranch' from '$seedRef'."
                }
            }
            else {
                & git checkout --orphan $ConfiguredBranch 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to create orphan target branch '$ConfiguredBranch'."
                }
            }

            & git config user.name 'ALM4Dataverse Setup' 2>$null
            & git config user.email 'setup@alm4dataverse.local' 2>$null

            & git rev-parse --verify HEAD 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                & git commit --allow-empty -m "Initialize repository branch '$ConfiguredBranch' for ALM4Dataverse setup" 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to create initial commit for branch '$ConfiguredBranch'."
                }
            }

            & git -c "http.extraheader=AUTHORIZATION: bearer $AccessToken" push -u origin $ConfiguredBranch 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to push target branch '$ConfiguredBranch' to origin."
            }

            $targetBranchExistsOnOrigin = $true
            $seedRef = $ConfiguredBranch
        }

        & git rev-parse --verify HEAD 2>&1 | Out-Null
        $hasLocalHeadCommit = ($LASTEXITCODE -eq 0)

        if ($PublishPlan.Mode -eq 'PullRequest') {
            $workingBaseRef = if ($targetBranchExistsOnOrigin) { "origin/$ConfiguredBranch" } elseif ($seedRef) { $seedRef } else { 'HEAD' }
            & git checkout -B $PublishPlan.BranchName $workingBaseRef 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to create or switch to working branch '$($PublishPlan.BranchName)'."
            }
        }
        else {
            $directBaseRef = if ($targetBranchExistsOnOrigin) { "origin/$ConfiguredBranch" } elseif ($seedRef) { $seedRef } elseif ($hasLocalHeadCommit) { 'HEAD' } else { $null }
            if ($directBaseRef) {
                $checkoutOutput = @(& git checkout -B $ConfiguredBranch $directBaseRef 2>&1)
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to create or switch to target branch '$ConfiguredBranch' from '$directBaseRef': $($checkoutOutput -join ' ')"
                }
            }
            else {
                $checkoutOutput = @(& git checkout --orphan $ConfiguredBranch 2>&1)
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to create orphan target branch '$ConfiguredBranch': $($checkoutOutput -join ' ')"
                }
            }
        }

        Invoke-AzDoSetupArtifactGeneration `
            -RepoRoot $RepoRoot `
            -CopyRoot $CopyRoot `
            -MainRepo $Repository `
            -SharedRepositoryName $SharedRepositoryName `
            -SharedRepositoryRef $SharedRepositoryRef `
            -Branch $ConfiguredBranch `
            -UseAlm4DataverseExtension $UseAlm4DataverseExtension `
            -Solutions $Solutions `
            -DeploymentEnvironments $DeploymentEnvironments `
            -BuildValidationEnabled $BuildValidationEnabled `
            -BuildValidationEnvironmentName $BuildValidationEnvironmentName `
            -BuildValidationBaselineRelease $BuildValidationBaselineRelease `
            -BuildValidationEnvironments $BuildValidationEnvironments `
            -SetupSettings $SetupSettings

        return Publish-AzDoRepoChange -RepoRoot $RepoRoot -PublishPlan $PublishPlan -AccessToken $AccessToken -Repository $Repository
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        Pop-Location
    }
}

function Get-AzDoPublishSummaryText {
    # Count content-changing results only; no-change pushes are intentionally not
    # described as updates, and PullRequest mode does not guarantee a returned PR URL.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][array]$PublishResults
    )

    $results = @($PublishResults | Where-Object { $null -ne $_ })
    if ($results.Count -eq 0) {
        return 'No repository changes were needed'
    }

    $changedResults = @($results | Where-Object { $_.HasChanges })
    if ($changedResults.Count -eq 0) {
        return 'No repository changes were needed'
    }

    $pullRequestResults = @($changedResults | Where-Object { $_.Mode -eq 'PullRequest' })
    $directResults = @($changedResults | Where-Object { $_.Mode -ne 'PullRequest' })

    $summaryParts = @()
    if ($directResults.Count -gt 0) {
        $summaryParts += "$($directResults.Count) direct branch update(s)"
    }
    if ($pullRequestResults.Count -gt 0) {
        $summaryParts += "$($pullRequestResults.Count) pull request branch update(s)"
    }

    return ($summaryParts -join ' - ')
}
