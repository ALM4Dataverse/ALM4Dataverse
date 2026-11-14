function Publish-GitHubRepoChange {
    <#
    .SYNOPSIS
        Commits and pushes prepared worktree changes, optionally creating/updating a PR.
    .DESCRIPTION
        PublishPlan supplies Mode, BranchName, TargetBranch and commit/PR text.
        Stages all files and sets clone-local author identity. Even without a diff,
        pushes the branch but does not create a PR. Returns HasChanges, branch names,
        PullRequestUrl and Mode alongside native command output; callers capture that
        output through the setup operation wrapper. Restores location/error preference
        on failure, but does not roll back remote writes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][object]$PublishPlan
    )

    Push-Location $RepoRoot
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & git add -A
        if ($LASTEXITCODE -ne 0) { throw 'Git add failed.' }

        & git diff --cached --quiet
        $hasChanges = ($LASTEXITCODE -ne 0)

        if (-not $hasChanges) {
            Write-Host "No content changes detected, but ensuring branch '$($PublishPlan.BranchName)' exists on origin..." -ForegroundColor Yellow
            & git push -u origin $PublishPlan.BranchName 2>&1
            if ($LASTEXITCODE -ne 0) { throw 'Git push failed.' }

            Write-Host 'No changes to commit; repository already contains the required files.' -ForegroundColor Green
            return [pscustomobject]@{
                HasChanges     = $false
                BranchName     = $PublishPlan.BranchName
                TargetBranch   = $PublishPlan.TargetBranch
                PullRequestUrl = $null
                Mode           = $PublishPlan.Mode
            }
        }

        & git config user.name 'ALM4Dataverse Setup'
        & git config user.email 'setup@alm4dataverse.local'
        & git commit -m $PublishPlan.CommitMessage 2>&1
        if ($LASTEXITCODE -ne 0) { throw 'Git commit failed.' }

        Write-Host "Pushing to origin/$($PublishPlan.BranchName)..." -ForegroundColor Yellow
        & git push -u origin $PublishPlan.BranchName 2>&1
        if ($LASTEXITCODE -ne 0) { throw 'Git push failed.' }

        $pullRequestUrl = $null
        if ($PublishPlan.Mode -eq 'PullRequest') {
            $existingPrOutput = (& gh pr list --head $PublishPlan.BranchName --base $PublishPlan.TargetBranch --state open --json number,url 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -ne 0) {
                throw 'Failed to query existing pull requests.'
            }

            $existingPullRequests = @()
            if (-not [string]::IsNullOrWhiteSpace($existingPrOutput)) {
                $existingPullRequests = @($existingPrOutput | ConvertFrom-Json)
            }

            $existingPullRequest = $existingPullRequests | Select-Object -First 1
            if ($existingPullRequest) {
                Write-Host "Updating existing pull request #$($existingPullRequest.number)..." -ForegroundColor Yellow
                & gh pr edit $existingPullRequest.number --title $PublishPlan.PullRequestTitle --body $PublishPlan.PullRequestDescription 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw 'Failed to update the pull request.'
                }
                $pullRequestUrl = $existingPullRequest.url
            }
            else {
                Write-Host "Creating pull request into '$($PublishPlan.TargetBranch)'..." -ForegroundColor Yellow
                $pullRequestUrl = (& gh pr create --title $PublishPlan.PullRequestTitle --body $PublishPlan.PullRequestDescription --base $PublishPlan.TargetBranch --head $PublishPlan.BranchName 2>&1 | Out-String).Trim()
                if ($LASTEXITCODE -ne 0) {
                    throw 'Failed to create the pull request.'
                }
            }
        }

        Write-Host 'Repository updated successfully.' -ForegroundColor Green
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

function Invoke-GitHubSetupArtifactGeneration {
    <#
    .SYNOPSIS
        Generates configuration and workflows for one GitHub setup publication.
    .DESCRIPTION
        Shared by publication and preview so both paths use the same generators.
        This function only writes files below RepoRoot; it does not contact GitHub.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ConfiguredBranch,
        [Parameter(Mandatory)][string]$CopyRoot,
        [Parameter(Mandatory)][string]$SharedWorkflowRepository,
        [Parameter(Mandatory)][string]$SharedWorkflowReference,
        [Parameter(Mandatory)][string]$PromotionMode,
        [Parameter()][AllowNull()][array]$Solutions,
        [Parameter()][AllowEmptyCollection()][array]$DeploymentEnvironments = @(),
        [Parameter()][AllowEmptyCollection()][array]$DeployWorkflowBranchDefinitions = @(),
        [Parameter()][bool]$BuildValidationEnabled = $false,
        [Parameter()][AllowEmptyString()][string]$BuildValidationEnvironmentName = '',
        [Parameter()][AllowEmptyString()][string]$BuildValidationBaselineRelease = '',
        [Parameter()][System.Collections.IDictionary]$BuildValidationEnvironments = @{},
        [Parameter()][System.Collections.IDictionary]$SetupSettings,
        [Parameter()][switch]$SkipDeployWorkflow
    )

    Copy-WorkflowTemplatesToRepo `
        -SourceRoot $CopyRoot `
        -TargetRoot $RepoRoot `
        -Branch $ConfiguredBranch `
        -SharedWorkflowRepository $SharedWorkflowRepository `
        -SharedWorkflowRef $SharedWorkflowReference `
        -SkipDeployWorkflow:$SkipDeployWorkflow | Out-Null

    Update-AlmConfigInRepoClone `
        -Solutions $Solutions `
        -BuildValidationEnabled $BuildValidationEnabled `
        -BuildValidationBaselineRelease $BuildValidationBaselineRelease `
        -RepoRoot $RepoRoot `
        -SetupSettings $SetupSettings | Out-Null

    $buildEnvironmentName = if ($BuildValidationEnabled) { [string]$BuildValidationEnvironmentName } else { '' }
    Update-BuildWorkflowInRepoClone `
        -RepoRoot $RepoRoot `
        -SharedWorkflowRepository $SharedWorkflowRepository `
        -SharedWorkflowReference $SharedWorkflowReference `
        -BuildEnvironmentName $buildEnvironmentName `
        -BuildValidationEnabled $BuildValidationEnabled `
        -BuildValidationEnvironments $BuildValidationEnvironments | Out-Null

    if (-not $SkipDeployWorkflow) {
        $effectiveDeployWorkflowDefinitions = @()
        if ($DeployWorkflowBranchDefinitions -and @($DeployWorkflowBranchDefinitions).Count -gt 0) {
            $effectiveDeployWorkflowDefinitions = @($DeployWorkflowBranchDefinitions)
        }
        else {
            $effectiveDeployWorkflowDefinitions = @(
                [pscustomobject]@{
                    BranchName             = $ConfiguredBranch
                    DeploymentEnvironments = @($DeploymentEnvironments)
                }
            )
        }

        foreach ($deployDefinition in @($effectiveDeployWorkflowDefinitions)) {
            $workflowBranchName = [string]$deployDefinition.BranchName
            $workflowDeploymentEnvironments = @($deployDefinition.DeploymentEnvironments)

            if ([string]::IsNullOrWhiteSpace($workflowBranchName)) {
                continue
            }

            Update-DeployWorkflowInRepoClone `
                -RepoRoot $RepoRoot `
                -Branch $workflowBranchName `
                -DeploymentEnvironments $workflowDeploymentEnvironments `
                -SharedWorkflowRepository $SharedWorkflowRepository `
                -SharedWorkflowRef $SharedWorkflowReference `
                -PromotionMode $PromotionMode | Out-Null
        }
    }
}

function Publish-GitHubBranchSetupChange {
    <#
    .SYNOPSIS
        Resets a disposable clone, generates one branch's files and publishes its plan.
    .DESCRIPTION
        Hard-resets and cleans RepoRoot, so it must not be a user's working checkout.
        Refreshes origin refs and seeds missing branches from the default when possible.
        PR mode creates a missing target branch on origin before preparing the PR head.
        DeployWorkflowBranchDefinitions overrides the single-branch deployment list;
        SkipDeployWorkflow leaves deploy files alone. Returns the publication result
        and restores caller location/error preference; remote changes are not rolled back.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ConfiguredBranch,
        [Parameter(Mandatory)][object]$PublishPlan,
        [Parameter(Mandatory)][string]$DefaultBranch,
        [Parameter(Mandatory)][string]$CopyRoot,
        [Parameter(Mandatory)][string]$SharedWorkflowRepository,
        [Parameter(Mandatory)][string]$SharedWorkflowReference,
        [Parameter(Mandatory)][string]$PromotionMode,
        [Parameter()][AllowNull()][array]$Solutions,
        [Parameter()][array]$DeploymentEnvironments,
        [Parameter()][array]$DeployWorkflowBranchDefinitions,
        [Parameter()][bool]$BuildValidationEnabled = $false,
        [Parameter()][AllowEmptyString()][string]$BuildValidationEnvironmentName = '',
        [Parameter()][AllowEmptyString()][string]$BuildValidationBaselineRelease = '',
        [Parameter()][System.Collections.IDictionary]$BuildValidationEnvironments = @{},
        [Parameter()][System.Collections.IDictionary]$SetupSettings,
        [Parameter()][switch]$SkipDeployWorkflow
    )

    Push-Location $RepoRoot
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & git fetch origin '+refs/heads/*:refs/remotes/origin/*' --prune 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'Failed to refresh remote branches before publishing.'
        }

        & git reset --hard HEAD 2>&1 | Out-Null
        & git clean -fd 2>&1 | Out-Null

        & git ls-remote --exit-code --heads origin $ConfiguredBranch 2>&1 | Out-Null
        $targetBranchExistsOnOrigin = ($LASTEXITCODE -eq 0)

        & git ls-remote --exit-code --heads origin $DefaultBranch 2>&1 | Out-Null
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

            & git push -u origin $ConfiguredBranch 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to push target branch '$ConfiguredBranch' to origin."
            }

            $targetBranchExistsOnOrigin = $true
            $seedRef = $ConfiguredBranch
        }

        if ($PublishPlan.Mode -eq 'PullRequest') {
            $workingBaseRef = if ($targetBranchExistsOnOrigin) { "origin/$ConfiguredBranch" } elseif ($seedRef) { $seedRef } else { 'HEAD' }
            & git checkout -B $PublishPlan.BranchName $workingBaseRef 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to create or switch to working branch '$($PublishPlan.BranchName)'."
            }
        }
        else {
            $directBaseRef = if ($targetBranchExistsOnOrigin) { "origin/$ConfiguredBranch" } elseif ($seedRef) { $seedRef } else { $null }
            if ($directBaseRef) {
                & git checkout -B $ConfiguredBranch $directBaseRef 2>&1 | Out-Null
            }
            else {
                & git checkout --orphan $ConfiguredBranch 2>&1 | Out-Null
            }
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to create or switch to target branch '$ConfiguredBranch'."
            }
        }

        Invoke-GitHubSetupArtifactGeneration `
            -RepoRoot $RepoRoot `
            -ConfiguredBranch $ConfiguredBranch `
            -CopyRoot $CopyRoot `
            -SharedWorkflowRepository $SharedWorkflowRepository `
            -SharedWorkflowReference $SharedWorkflowReference `
            -PromotionMode $PromotionMode `
            -Solutions $Solutions `
            -DeploymentEnvironments $DeploymentEnvironments `
            -DeployWorkflowBranchDefinitions $DeployWorkflowBranchDefinitions `
            -BuildValidationEnabled $BuildValidationEnabled `
            -BuildValidationEnvironmentName $BuildValidationEnvironmentName `
            -BuildValidationBaselineRelease $BuildValidationBaselineRelease `
            -BuildValidationEnvironments $BuildValidationEnvironments `
            -SetupSettings $SetupSettings `
            -SkipDeployWorkflow:$SkipDeployWorkflow

        return Publish-GitHubRepoChange -RepoRoot $RepoRoot -PublishPlan $PublishPlan
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        Pop-Location
    }
}

function Get-GitHubPublishSummaryText {
    # Branch-creation pushes with HasChanges=false deliberately do not count as
    # content updates. Null/empty results produce the same no-changes display text.
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

function Get-GitHubSetupRemovedBranchName {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][array]$BranchStates,
        [Parameter(Mandatory)][object]$ExistingSetupState,
        [Parameter(Mandatory)][string]$DefaultBranch
    )

    $selectedBranchNames = @($BranchStates | ForEach-Object { [string]$_.BranchName })
    $existingBranchNames = @($ExistingSetupState.DeploymentBranchMappings | ForEach-Object {
        if ($null -eq $_) {
            return $null
        }
        if ($_.PSObject.Properties.Name -contains 'BranchName') {
            return [string]$_.BranchName
        }
        return $null
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)

    return @($existingBranchNames | Where-Object { $_ -notin $selectedBranchNames -and $_ -ne $DefaultBranch })
}

function Get-GitHubSetupDeployWorkflowDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][array]$BranchStates,
        [Parameter()][array]$RemovedBranchNames = @()
    )

    $definitions = @(
        foreach ($branchState in $BranchStates) {
            [pscustomobject]@{
                BranchName             = [string]$branchState.BranchName
                DeploymentEnvironments = @($branchState.DeploymentEnvironments)
            }
        }
    )
    foreach ($removedBranchName in $RemovedBranchNames) {
        $definitions += [pscustomobject]@{
            BranchName             = [string]$removedBranchName
            DeploymentEnvironments = @()
        }
    }

    return $definitions
}

function Get-GitHubSetupArtifactsPreview {
    <#
    .SYNOPSIS
        Generates GitHub setup files and returns repository changes for review.
    .DESCRIPTION
        Uses the same artifact generator as publication inside an isolated temporary tree.
        The selected repository is never modified.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$CopyRoot,
        [Parameter(Mandatory)][string]$DefaultBranch,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Ref,
        [Parameter(Mandatory)][string]$PromotionMode,
        [Parameter(Mandatory)][object]$ExistingSetupState,
        [Parameter(Mandatory)][array]$BranchStates,
        [Parameter()][System.Collections.IDictionary]$ProviderOptions = @{},
        [Parameter()][AllowNull()][object]$SolutionResult
    )

    $settings = Get-AlmSetupConfiguration `
        -Provider GitHub `
        -Repository $Repository `
        -Ref $Ref `
        -BranchStates $BranchStates `
        -ProviderOptions $ProviderOptions
    $buildValidationEnvironments = Get-AlmSetupBuildValidationEnvironmentMap -BranchStates $BranchStates
    $deployDefinitions = Get-GitHubSetupDeployWorkflowDefinition `
        -BranchStates $BranchStates `
        -RemovedBranchNames (Get-GitHubSetupRemovedBranchName -BranchStates $BranchStates -ExistingSetupState $ExistingSetupState -DefaultBranch $DefaultBranch)
    $solutions = if ($SolutionResult) { @($SolutionResult.Solutions) } else { $null }
    $previewRelativePaths = @(Get-ChildItem -LiteralPath $CopyRoot -Force -ErrorAction Stop | ForEach-Object { [string]$_.Name })
    if ('alm-config.psd1' -notin $previewRelativePaths) {
        $previewRelativePaths += 'alm-config.psd1'
    }
    $previewRoot = New-SetupPreviewRoot -BaseRoot $RepoRoot -RelativePaths $previewRelativePaths

    try {
        Invoke-GitHubSetupArtifactGeneration `
            -RepoRoot $previewRoot `
            -ConfiguredBranch $DefaultBranch `
            -CopyRoot $CopyRoot `
            -SharedWorkflowRepository $Repository `
            -SharedWorkflowReference $Ref `
            -PromotionMode $PromotionMode `
            -Solutions $solutions `
            -DeployWorkflowBranchDefinitions $deployDefinitions `
            -BuildValidationEnabled ($buildValidationEnvironments.Count -gt 0) `
            -BuildValidationEnvironments $buildValidationEnvironments `
            -SetupSettings $settings

        $configPath = Join-Path $previewRoot 'alm-config.psd1'
        if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
            throw 'The generated alm-config.psd1 preview was not created.'
        }

        $workflowRoot = Join-Path $previewRoot '.github/workflows'
        if (-not (Test-Path -LiteralPath $workflowRoot -PathType Container)) {
            throw 'The generated GitHub workflow preview directory was not created.'
        }

        return [pscustomobject]@{
            FileChanges = @(Get-SetupRepositoryFileChange -RepositoryRoot $RepoRoot -PreviewRoot $previewRoot -RelativePaths $previewRelativePaths)
        }
    }
    finally {
        Remove-Item -LiteralPath $previewRoot -Recurse -Force -ErrorAction Stop
    }
}

function Invoke-GitHubBranchAwareSetupApply {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'CloneRoot', Justification = 'Captured by the nested branch publication script block.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'CopyRoot', Justification = 'Captured by the nested branch publication script block.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'PromotionMode', Justification = 'Captured by the nested branch publication script block.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CloneRoot,
        [Parameter(Mandatory)][string]$CopyRoot,
        [Parameter(Mandatory)][string]$DefaultBranch,
        [Parameter(Mandatory)][object]$ExistingSetupState,
        [Parameter(Mandatory)][string]$SharedWorkflowRepository,
        [Parameter(Mandatory)][string]$SharedWorkflowReference,
        [Parameter(Mandatory)][string]$ALM4DataverseRef,
        [Parameter(Mandatory)][string]$PromotionMode,
        [Parameter(Mandatory)][object]$WizardState,
        [Parameter()][System.Collections.IDictionary]$ProviderOptions = @{}
    )

    $branchStates = @($WizardState.BranchStates)
    $selectedBranchNames = @($branchStates | ForEach-Object { [string]$_.BranchName })
    $removedBranchNames = @(Get-GitHubSetupRemovedBranchName `
            -BranchStates $branchStates `
            -ExistingSetupState $ExistingSetupState `
            -DefaultBranch $DefaultBranch)
    $publishBranchStates = @($branchStates)
    $defaultBranchState = $publishBranchStates | Where-Object { $_.BranchName -ieq $DefaultBranch } | Select-Object -First 1
    if (-not $defaultBranchState) {
        $defaultBranchState = New-GitHubBranchSetupState `
            -BranchName $DefaultBranch `
            -ExistingDevEnvironment $ExistingSetupState.DevEnvironment `
            -DeploymentEnvironments @()
        $defaultBranchState.PublishPlan = Get-BranchTargetedRepoChangePublishPlan `
            -ProviderName 'GitHub' `
            -RepositoryName $RepoFullName `
            -TargetBranch $DefaultBranch `
            -DefaultCommitMessage "Sync ALM4Dataverse workflow availability updates on '$DefaultBranch'" `
            -DefaultPullRequestTitle "Sync ALM4Dataverse workflow availability updates on '$DefaultBranch'" `
            -DefaultPullRequestDescription "This pull request ensures ALM4Dataverse workflow availability updates are present on '$DefaultBranch', including deploy workflow definitions for configured branches." `
            -GuidanceLines @(
                "GitHub requires workflows to be present on '$DefaultBranch' for availability.",
                'Choose how to publish these default-branch workflow availability updates.'
            ) `
            -DocRelativePath 'docs/setup/github-setup.md' `
            -Ref $ALM4DataverseRef
        $publishBranchStates += $defaultBranchState
    }

    foreach ($removedBranchName in $removedBranchNames) {
        $removedBranchState = New-GitHubBranchSetupState `
            -BranchName $removedBranchName `
            -ExistingDevEnvironment $null `
            -DeploymentEnvironments @()
        $removedBranchState.PublishPlan = Get-BranchTargetedRepoChangePublishPlan `
            -ProviderName 'GitHub' `
            -RepositoryName $RepoFullName `
            -TargetBranch $removedBranchName `
            -DefaultCommitMessage "Sync non-deploy ALM4Dataverse workflow updates for branch '$removedBranchName'" `
            -DefaultPullRequestTitle "Sync non-deploy ALM4Dataverse workflow updates for branch '$removedBranchName'" `
            -DefaultPullRequestDescription "This pull request updates non-deploy ALM4Dataverse workflow files on '$removedBranchName' so shared workflow changes stay aligned across long-lived branches." `
            -GuidanceLines @(
                "Branch '$removedBranchName' is no longer mapped for deployment, but shared non-deploy workflow updates still need to be merged.",
                'Choose how to publish these synchronization updates.'
            ) `
            -DocRelativePath 'docs/setup/github-setup.md' `
            -Ref $ALM4DataverseRef
        $publishBranchStates += $removedBranchState
    }

    $buildValidationEnvironments = Get-AlmSetupBuildValidationEnvironmentMap -BranchStates $branchStates
    $buildValidationEnabled = $buildValidationEnvironments.Count -gt 0
    $useImmutableWifSubject = [bool]$WizardState.UseImmutableWifSubject
    $ProviderOptions['GitHubUseImmutableWifSubject'] = $useImmutableWifSubject

    $buildValidationEnvironmentName = if ($buildValidationEnvironments.Count -eq 1) {
        [string]@($buildValidationEnvironments.Values)[0]
    }
    else {
        ''
    }
    $setupSettings = Get-AlmSetupConfiguration `
        -Provider GitHub `
        -Repository $SharedWorkflowRepository `
        -Ref $SharedWorkflowReference `
        -BranchStates $branchStates `
        -ProviderOptions $ProviderOptions
    $deployDefinitions = Get-GitHubSetupDeployWorkflowDefinition `
        -BranchStates $branchStates `
        -RemovedBranchNames $removedBranchNames
    $solutions = if ($WizardState.SolutionResult) { @($WizardState.SolutionResult.Solutions) } else { $null }
    $publishResults = @()

    foreach ($branchState in $publishBranchStates) {
        $branchName = [string]$branchState.BranchName
        $isSelectedBranch = $selectedBranchNames -contains $branchName
        $isRemovedBranch = $removedBranchNames -contains $branchName
        $deployDefinitionsForBranch = if ($branchName -ieq $DefaultBranch) { $deployDefinitions } else { @() }
        $solutionsForBranch = if ($isSelectedBranch) { $solutions } else { $null }

        $publishResult = Invoke-WithErrorHandling `
            -OperationName "Publishing repository changes for branch '$branchName'" `
            -StatusMessage "Publishing repository changes for branch '$branchName'..." `
            -CaptureOutputInPanel `
            -ScriptBlock {
                Publish-GitHubBranchSetupChange `
                    -RepoRoot $CloneRoot `
                    -ConfiguredBranch $branchName `
                    -PublishPlan $branchState.PublishPlan `
                    -DefaultBranch $DefaultBranch `
                    -CopyRoot $CopyRoot `
                    -SharedWorkflowRepository $SharedWorkflowRepository `
                    -SharedWorkflowReference $SharedWorkflowReference `
                    -PromotionMode $PromotionMode `
                    -Solutions $solutionsForBranch `
                    -DeploymentEnvironments @($branchState.DeploymentEnvironments) `
                    -DeployWorkflowBranchDefinitions $deployDefinitionsForBranch `
                    -BuildValidationEnabled $buildValidationEnabled `
                    -BuildValidationEnvironmentName $buildValidationEnvironmentName `
                    -BuildValidationEnvironments $buildValidationEnvironments `
                    -SetupSettings $setupSettings `
                    -SkipDeployWorkflow:$isRemovedBranch
            }

        $publishResults += [pscustomobject]@{
            ConfiguredBranch = $branchName
            BranchName       = $publishResult.BranchName
            TargetBranch     = $publishResult.TargetBranch
            PullRequestUrl   = $publishResult.PullRequestUrl
            Mode             = $publishResult.Mode
            HasChanges       = $publishResult.HasChanges
        }
    }

    $enabledBuildBranches = @($branchStates | Where-Object { $_.BuildValidationEnabled -and $_.BuildValidationEnvironmentConfiguration })
    return [pscustomobject]@{
        BranchStates                              = $branchStates
        SolutionResult                            = $WizardState.SolutionResult
        SolutionSourceBranch                      = $WizardState.SolutionSourceBranch
        BuildValidationEnabled                    = $buildValidationEnabled
        BuildValidationEnvironmentName            = $buildValidationEnvironmentName
        BuildValidationBaselineRelease            = $(if ($enabledBuildBranches.Count -eq 1) { [string]$enabledBuildBranches[0].BuildValidationBaselineRelease } else { '' })
        BuildValidationEnvironmentConfiguration   = $(if ($enabledBuildBranches.Count -eq 1) { $enabledBuildBranches[0].BuildValidationEnvironmentConfiguration } else { $null })
        BuildValidationEnvironmentConfigurations   = @($enabledBuildBranches | ForEach-Object { $_.BuildValidationEnvironmentConfiguration })
        UseImmutableWifSubject                    = $useImmutableWifSubject
        PublishResults                            = @($publishResults)
    }
}

function Get-GitHubSetupResourceChange {
    <#
    .SYNOPSIS
        Describes GitHub and Dataverse changes deferred until setup is applied.
    .DESCRIPTION
        The plan contains resource names and settings only; credential values are omitted.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$BranchStates,
        [Parameter(Mandatory)][object]$RepoIdentity,
        [Parameter(Mandatory)][string]$RepoFullName,
        [Parameter(Mandatory)][bool]$UseImmutableWifSubject,
        [Parameter(Mandatory)][bool]$UseGitHubEnvironments,
        [Parameter(Mandatory)][bool]$UseRepositoryVariablePrefix,
        [Parameter(Mandatory)][bool]$EnableEnvironmentApprovals,
        [Parameter()][int[]]$RequiredReviewerIds = @()
    )

    $changes = [System.Collections.Generic.List[object]]::new()
    $currentImmutableSubject = [bool](Get-OptionalObjectPropertyValue -InputObject $RepoIdentity -PropertyName 'UseImmutableSubject')
    if ($UseImmutableWifSubject -and -not $currentImmutableSubject) {
        $changes.Add([pscustomobject]@{
                Action   = 'Enable'
                Resource = 'GitHub repository OIDC setting'
                Target   = $RepoFullName
                Details  = 'Enable immutable subject claims while preserving the existing claim-selection mode.'
            })
    }

    $environmentTargets = [System.Collections.Generic.List[object]]::new()
    $configuredBuildEnvironmentNames = @()
    foreach ($branchState in $BranchStates) {
        if ($branchState.DevEnvironmentConfiguration) {
            $environmentTargets.Add([pscustomobject]@{
                    Role                       = 'DEV'
                    BranchName                 = [string]$branchState.BranchName
                    EnvironmentConfiguration   = $branchState.DevEnvironmentConfiguration
                    EnableApprovals            = $false
                })
        }

        if ($branchState.BuildValidationEnabled -and $branchState.BuildValidationEnvironmentConfiguration) {
            $buildEnvironment = $branchState.BuildValidationEnvironmentConfiguration
            $buildEnvironmentName = [string]$buildEnvironment.ShortName
            if ($configuredBuildEnvironmentNames -notcontains $buildEnvironmentName) {
                $configuredBuildEnvironmentNames += $buildEnvironmentName
                $environmentTargets.Add([pscustomobject]@{
                        Role                     = 'BUILD'
                        BranchName               = [string]$branchState.BranchName
                        EnvironmentConfiguration = $buildEnvironment
                        EnableApprovals          = $false
                    })
            }
        }

        foreach ($environment in @($branchState.DeploymentEnvironments)) {
            $environmentTargets.Add([pscustomobject]@{
                    Role                     = 'Deployment'
                    BranchName               = [string]$branchState.BranchName
                    EnvironmentConfiguration = $environment
                    EnableApprovals          = $EnableEnvironmentApprovals
                })
        }
    }

    $requiredReviewerCount = @($RequiredReviewerIds | Where-Object { $_ -gt 0 }).Count
    foreach ($environmentTarget in $environmentTargets) {
        $environment = $environmentTarget.EnvironmentConfiguration
        $environmentName = [string]$environment.ShortName
        $credentials = Get-OptionalObjectPropertyValue -InputObject $environment -PropertyName 'Credentials'
        if (-not $credentials) {
            throw "No credentials were captured for GitHub environment '$environmentName'."
        }

        $authType = [string](Get-OptionalObjectPropertyValue -InputObject $credentials -PropertyName 'AuthType')
        $hasClientSecret = -not [string]::IsNullOrWhiteSpace([string](Get-OptionalObjectPropertyValue -InputObject $credentials -PropertyName 'ClientSecret'))
        if ($authType -eq 'WIF' -and -not [string]::IsNullOrWhiteSpace([string](Get-OptionalObjectPropertyValue -InputObject $credentials -PropertyName 'ApplicationObjectId'))) {
            $changes.Add([pscustomobject]@{
                    Action   = 'Create or update'
                    Resource = 'Entra federated identity credential'
                    Target   = "$RepoFullName/$environmentName"
                    Details  = 'Configure the GitHub Actions workload identity subject for this environment.'
                })
        }

        if ($UseGitHubEnvironments) {
            $environmentDetails = 'Set variables AZURE_CLIENT_ID, AZURE_TENANT_ID, DATAVERSE_URL, and DATAVERSESERVICEACCOUNTUPN.'
            if ($authType -eq 'Secret') {
                if ($hasClientSecret) {
                    $environmentDetails += ' Set AZURE_CLIENT_SECRET; its value is hidden.'
                }
                else {
                    $environmentDetails += ' No client-secret value was supplied, so any existing AZURE_CLIENT_SECRET is retained.'
                }
            }
            if ($environmentTarget.EnableApprovals -and $requiredReviewerCount -gt 0) {
                $environmentDetails += " Require approval from $requiredReviewerCount selected reviewer(s)."
            }

            $changes.Add([pscustomobject]@{
                    Action   = 'Create or update'
                    Resource = 'GitHub environment'
                    Target   = "$RepoFullName/$environmentName"
                    Details  = $environmentDetails
                })
        }
        else {
            $prefix = if ($UseRepositoryVariablePrefix) {
                [string](Get-GitHubEnvironmentPrefix -EnvironmentName $environmentName)
            }
            else {
                ''
            }
            $variableNames = @(
                "${prefix}AZURE_CLIENT_ID",
                "${prefix}AZURE_TENANT_ID",
                "${prefix}DATAVERSE_URL",
                "${prefix}DATAVERSE_SERVICE_ACCOUNT_UPN"
            ) -join ', '
            $variableDetails = "Set repository variables $variableNames."
            if ($authType -eq 'Secret') {
                if ($hasClientSecret) {
                    $changes.Add([pscustomobject]@{
                            Action   = 'Create or update'
                            Resource = 'GitHub environment secret'
                            Target   = "$RepoFullName/$environmentName"
                            Details  = 'Ensure the environment and set AZURE_CLIENT_SECRET; its value is hidden.'
                        })
                }
                else {
                    $variableDetails += ' No client-secret value was supplied, so any existing AZURE_CLIENT_SECRET is retained.'
                }
            }
            $changes.Add([pscustomobject]@{
                    Action   = 'Set or update'
                    Resource = 'GitHub repository variables'
                    Target   = "$RepoFullName/$environmentName"
                    Details  = $variableDetails
                })
        }

        $changes.Add([pscustomobject]@{
                Action   = 'Ensure'
                Resource = 'Dataverse application and service-account users'
                Target   = $environmentName
                Details  = 'Ensure both configured users have the System Administrator role.'
            })
    }

    return @($changes.ToArray())
}

function Invoke-GitHubSetupPostApply {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'TenantId', Justification = 'Captured by nested environment-configuration callbacks.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'RepoOwner', Justification = 'Captured by nested environment-configuration callbacks.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'RepoName', Justification = 'Captured by nested environment-configuration callbacks.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'RepoOwnerId', Justification = 'Captured by nested environment-configuration callbacks.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'RepoId', Justification = 'Captured by nested environment-configuration callbacks.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'UseRepositoryVariablePrefix', Justification = 'Captured by nested environment-configuration callbacks.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'EnableEnvironmentApprovals', Justification = 'Captured by nested environment-configuration callbacks.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'RequiredReviewerIds', Justification = 'Captured by nested environment-configuration callbacks.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$SetupResult,
        [Parameter(Mandatory)][object]$RepoIdentity,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$RepoOwner,
        [Parameter(Mandatory)][string]$RepoName,
        [Parameter(Mandatory)][string]$RepoFullName,
        [Parameter(Mandatory)][string]$RepoOwnerId,
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][bool]$UseGitHubEnvironments,
        [Parameter(Mandatory)][bool]$UseRepositoryVariablePrefix,
        [Parameter(Mandatory)][bool]$EnableEnvironmentApprovals,
        [Parameter()][array]$RequiredReviewerIds = @()
    )

    $branchStates = @($SetupResult.BranchStates)
    $useImmutableWifSubject = [bool]$SetupResult.UseImmutableWifSubject
    if ($useImmutableWifSubject -and -not [bool](Get-OptionalObjectPropertyValue -InputObject $RepoIdentity -PropertyName 'UseImmutableSubject')) {
        $updatedOidcCustomization = Invoke-WithErrorHandling `
            -OperationName "Enabling immutable GitHub OIDC subjects for '$RepoFullName'" `
            -StatusMessage "Enabling immutable GitHub OIDC subjects for '$RepoFullName'..." `
            -ScriptBlock {
                Set-GitHubRepositoryImmutableSubject `
                    -Owner $RepoOwner `
                    -Repo $RepoName `
                    -CurrentCustomization $RepoIdentity.OidcCustomization
            }
        if (-not $updatedOidcCustomization) {
            throw "GitHub did not return updated OIDC settings for '$RepoFullName'."
        }

        $RepoIdentity.OidcCustomization = $updatedOidcCustomization
        $RepoIdentity.UseImmutableSubject = [bool]$updatedOidcCustomization.use_immutable_subject
    }

    $devBranchStates = @($branchStates | Where-Object { $_.DevEnvironmentConfiguration })
    if ($devBranchStates.Count -eq 0) {
        [Spectre.Console.AnsiConsole]::MarkupLine('[yellow]No DEV environment credentials were configured in the wizard, so this step will be skipped.[/]')
    }
    else {
        foreach ($branchState in $devBranchStates) {
            $devEnvironmentConfiguration = $branchState.DevEnvironmentConfiguration
            Write-Section -Message "Apply DEV environment configuration for branch '$($branchState.BranchName)'"
            if ($UseGitHubEnvironments) {
                Write-Host "Setting up GitHub environment '$($devEnvironmentConfiguration.ShortName)' for branch '$($branchState.BranchName)'." -ForegroundColor Green
            }
            else {
                Write-Host "Setting up repo-level credentials for DEV environment '$($devEnvironmentConfiguration.ShortName)'." -ForegroundColor Green
            }
            Write-Host ''

            Invoke-WithErrorHandling `
                -OperationName "Setting up DEV credentials for branch '$($branchState.BranchName)'" `
                -StatusMessage "Applying DEV environment credentials for branch '$($branchState.BranchName)'..." `
                -CaptureOutputInPanel `
                -ScriptBlock {
                    Set-GitHubEnvironmentConfiguration `
                        -EnvironmentConfiguration $devEnvironmentConfiguration `
                        -TenantId $TenantId `
                        -RepoOwner $RepoOwner `
                        -RepoName $RepoName `
                        -RepoFullName $RepoFullName `
                        -RepoOwnerId $RepoOwnerId `
                        -RepoId $RepoId `
                        -UseImmutableWifSubject $useImmutableWifSubject `
                        -UseGitHubEnvironments $UseGitHubEnvironments `
                        -UseRepositoryVariablePrefix $UseRepositoryVariablePrefix `
                        -EnableApprovals:$false
                } | Out-Null
        }
    }

    $enabledBuildBranchStates = @($branchStates | Where-Object { $_.BuildValidationEnabled })
    $buildBranchesWithoutEnvironment = @($enabledBuildBranchStates | Where-Object { -not $_.BuildValidationEnvironmentConfiguration })
    if ($buildBranchesWithoutEnvironment.Count -gt 0) {
        $branchNames = @($buildBranchesWithoutEnvironment | ForEach-Object { [string]$_.BranchName }) -join ', '
        throw "BUILD validation is enabled for branch(es) '$branchNames', but no environment configuration was returned."
    }
    if ($enabledBuildBranchStates.Count -eq 0) {
        [Spectre.Console.AnsiConsole]::MarkupLine('[yellow]BUILD validation is disabled for every branch, so BUILD environment credentials will be skipped.[/]')
    }
    else {
        $configuredBuildEnvironmentNames = @()
        foreach ($branchState in $enabledBuildBranchStates) {
            $environmentConfiguration = $branchState.BuildValidationEnvironmentConfiguration
            $environmentName = [string]$environmentConfiguration.ShortName
            if ($configuredBuildEnvironmentNames -contains $environmentName) {
                continue
            }
            $configuredBuildEnvironmentNames += $environmentName

            Write-Host "Applying BUILD validation environment '$environmentName' for branch '$($branchState.BranchName)'." -ForegroundColor Green
            Write-Host ''

            Invoke-WithErrorHandling `
                -OperationName "Applying BUILD validation environment configuration for branch '$($branchState.BranchName)'" `
                -AllowSkip `
                -ScriptBlock {
                    Set-GitHubEnvironmentConfiguration `
                        -EnvironmentConfiguration $environmentConfiguration `
                        -TenantId $TenantId `
                        -RepoOwner $RepoOwner `
                        -RepoName $RepoName `
                        -RepoFullName $RepoFullName `
                        -RepoOwnerId $RepoOwnerId `
                        -RepoId $RepoId `
                        -UseImmutableWifSubject $useImmutableWifSubject `
                        -UseGitHubEnvironments $UseGitHubEnvironments `
                        -UseRepositoryVariablePrefix $UseRepositoryVariablePrefix `
                        -EnableApprovals:$false
                } `
                -StatusMessage "Applying BUILD validation environment '$environmentName'..." `
                -CaptureOutputInPanel | Out-Null
        }
    }

    $allDeploymentEnvironments = @($branchStates | ForEach-Object { @($_.DeploymentEnvironments) })
    if ($UseGitHubEnvironments) {
        Write-Host 'Configuring GitHub environment credentials for deployment stages.' -ForegroundColor Green
    }
    else {
        Write-Host 'Configuring repo-level credentials for deployment stages.' -ForegroundColor Green
    }
    Write-Host ''

    if ($allDeploymentEnvironments.Count -eq 0) {
        Write-Host 'No deployment environments selected. You can run this script again to add them later.' -ForegroundColor Yellow
    }
    else {
        foreach ($branchState in $branchStates) {
            foreach ($environment in @($branchState.DeploymentEnvironments)) {
                Write-Section -Message "Applying environment configuration '$($environment.ShortName)' for branch '$($branchState.BranchName)'"
                Write-Host "Dataverse URL: $($environment.Url)" -ForegroundColor DarkGray
                Write-Host ''

                Invoke-WithErrorHandling `
                    -OperationName "Applying environment configuration for $($environment.ShortName)" `
                    -AllowSkip `
                    -ScriptBlock {
                        Set-GitHubEnvironmentConfiguration `
                            -EnvironmentConfiguration $environment `
                            -TenantId $TenantId `
                            -RepoOwner $RepoOwner `
                            -RepoName $RepoName `
                            -RepoFullName $RepoFullName `
                            -RepoOwnerId $RepoOwnerId `
                            -RepoId $RepoId `
                            -UseImmutableWifSubject $useImmutableWifSubject `
                            -UseGitHubEnvironments $UseGitHubEnvironments `
                            -UseRepositoryVariablePrefix $UseRepositoryVariablePrefix `
                            -EnableApprovals:$EnableEnvironmentApprovals `
                            -RequiredReviewerIds $RequiredReviewerIds
                    } `
                    -StatusMessage "Applying configuration for environment '$($environment.ShortName)'..." `
                    -CaptureOutputInPanel | Out-Null
            }
        }
    }
}
