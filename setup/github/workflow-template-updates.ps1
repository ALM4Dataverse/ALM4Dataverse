function Copy-WorkflowTemplatesToRepo {
    <#
    .SYNOPSIS
        Copies ALM4Dataverse workflow templates into the user's GitHub repository clone.
    .DESCRIPTION
        Rewrites shared action references and preserves custom secrets-json inputs.
        BUILD is generated separately; an existing branch-named DEPLOY and existing
        alm-config.psd1 are retained for later targeted updates. Existing
        application-owned files (AGENTS.md and data/) are never overwritten. Other
        differing files are overwritten, not generally merged. Temporary patched copies
        are removed after copying; a missing SourceRoot throws.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'SharedWorkflowRepository', Justification = 'Used by the nested workflow-update callback.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'SharedWorkflowRef', Justification = 'Used by the nested workflow-update callback.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$SharedWorkflowRepository,
        [Parameter(Mandatory)][string]$SharedWorkflowRef,
        [Parameter()][switch]$SkipDeployWorkflow
    )

    if (-not (Test-Path -LiteralPath $SourceRoot)) {
        throw "Source folder not found: $SourceRoot"
    }

    Write-Section `
        -Message "Syncing workflow files into repository"
    Write-Host "Source: $SourceRoot" -ForegroundColor DarkGray
    Write-Host "Target: $TargetRoot" -ForegroundColor DarkGray

    $allSourceFiles = Get-ChildItem -LiteralPath $SourceRoot -Recurse -Force | Where-Object { -not $_.PSIsContainer }

    foreach ($file in $allSourceFiles) {
        $relativePath = $file.FullName.Substring($SourceRoot.Length).TrimStart('\', '/')
        $normalizedRelativePath = $relativePath -replace '\\','/'
        $destPath     = Join-Path $TargetRoot $relativePath

        if ($normalizedRelativePath -eq '.github/workflows/BUILD.yml') {
            continue
        }

        if ($normalizedRelativePath -eq '.github/workflows/DEPLOY-main.yml') {
            if ($SkipDeployWorkflow) {
                continue
            }

            $destPath = Join-Path $TargetRoot ".github/workflows/DEPLOY-$Branch.yml"
            if (Test-Path -LiteralPath $destPath) {
                continue
            }
        }

        if ($normalizedRelativePath -eq 'alm-config.psd1' -and (Test-Path -LiteralPath $destPath)) {
            if (Test-Path -LiteralPath "$destPath.template") {
                Remove-Item -LiteralPath "$destPath.template" -Force
            }

            Write-Host 'Preserving existing alm-config.psd1 so current solution defaults and extended config can be merged later.' -ForegroundColor DarkGray
            continue
        }

        if ((Test-ApplicationOwnedScaffoldPath -RelativePath $normalizedRelativePath) -and (Test-Path -LiteralPath $destPath)) {
            Write-Host "Preserving existing $normalizedRelativePath." -ForegroundColor DarkGray
            continue
        }

        $destDir = Split-Path -Parent $destPath
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }

        $sourceFileToUse = $file.FullName
        $isTempFile      = $false

        # Patch all shared action references (build/export/import/deploy/etc.) to the selected repository/ref.
        # BUILD is excluded above and rebuilt by Update-BuildWorkflowInRepoClone.
        if ($normalizedRelativePath -like '.github/workflows/*.yml') {
            $content = Get-Content -LiteralPath $sourceFileToUse -Raw
            $updatedContent = [Regex]::Replace(
                $content,
                'ALM4Dataverse/ALM4Dataverse/\.github/actions/([A-Za-z0-9._-]+)@[A-Za-z0-9._/\-]+',
                {
                    param($m)
                    return "$SharedWorkflowRepository/.github/actions/$($m.Groups[1].Value)@$SharedWorkflowRef"
                }
            )

            if ($updatedContent -ne $content) {
                if ($isTempFile) {
                    Set-Content -LiteralPath $sourceFileToUse -Value $updatedContent -NoNewline
                }
                else {
                    $tempFile = [System.IO.Path]::GetTempFileName()
                    Set-Content -LiteralPath $tempFile -Value $updatedContent -NoNewline
                    $sourceFileToUse = $tempFile
                    $isTempFile      = $true
                }
            }
        }

        # Rename DEPLOY-main.yml to match the branch, and patch branch references
        if ($normalizedRelativePath -eq '.github/workflows/DEPLOY-main.yml') {
            $content = Get-Content -LiteralPath $sourceFileToUse -Raw
            $content = $content -replace "branches:\s*\[\s*main\s*\]", "branches: [ $Branch ]"
            $content = $content -replace 'workflow_name: ''BUILD''', "workflow_name: 'BUILD'"
            $content = $content -replace '\bTEST-main\b', 'TEST'

            if ($isTempFile) {
                Set-Content -LiteralPath $sourceFileToUse -Value $content -NoNewline
            }
            else {
                $tempFile = [System.IO.Path]::GetTempFileName()
                Set-Content -LiteralPath $tempFile -Value $content -NoNewline
                $sourceFileToUse = $tempFile
                $isTempFile      = $true
            }
        }

        try {
            if (Test-Path -LiteralPath $destPath) {
                if ($normalizedRelativePath -like '.github/workflows/*.yml') {
                    $existingContent = [System.IO.File]::ReadAllText($destPath)
                    $sourceContent = [System.IO.File]::ReadAllText($sourceFileToUse)
                    $mergedContent = Merge-SecretJsonInput -ExistingContent $existingContent -GeneratedContent $sourceContent
                    if ($mergedContent -cne $sourceContent) {
                        if ($isTempFile) {
                            Set-Content -LiteralPath $sourceFileToUse -Value $mergedContent -NoNewline
                        }
                        else {
                            $tempFile = [System.IO.Path]::GetTempFileName()
                            Set-Content -LiteralPath $tempFile -Value $mergedContent -NoNewline
                            $sourceFileToUse = $tempFile
                            $isTempFile = $true
                        }
                    }
                }

                $srcHash = Get-FileHash -LiteralPath $sourceFileToUse -Algorithm SHA256
                $dstHash = Get-FileHash -LiteralPath $destPath        -Algorithm SHA256

                if ($srcHash.Hash -ne $dstHash.Hash) {
                    Copy-Item -LiteralPath $sourceFileToUse -Destination $destPath -Force
                    if (Test-Path -LiteralPath "$destPath.template") {
                        Remove-Item -LiteralPath "$destPath.template" -Force
                    }
                }
                else {
                    if (Test-Path -LiteralPath "$destPath.template") {
                        Remove-Item -LiteralPath "$destPath.template" -Force
                    }
                }
            }
            else {
                Copy-Item -LiteralPath $sourceFileToUse -Destination $destPath -Force
            }
        }
        finally {
            if ($isTempFile -and (Test-Path -LiteralPath $sourceFileToUse)) {
                Remove-Item -LiteralPath $sourceFileToUse -Force
            }
        }
    }

    Write-Host "Workflow files synced." -ForegroundColor Green
}

function Update-AlmConfigInRepoClone {
    <#
    .SYNOPSIS
        Updates the alm-config.psd1 file in a local clone with the selected solutions.
    .DESCRIPTION
        Null Solutions means selection was skipped and preserves the existing list;
        an empty array explicitly clears it. Always updates solution checking and
        baseline release through targeted shared setters, retaining extended config.
        ShouldProcess refusal returns false; successful writes emit no result object.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param(
        [Parameter()][AllowNull()][array]$Solutions,
        [Parameter(Mandatory)][bool]$BuildValidationEnabled,
        [Parameter()][AllowEmptyString()][string]$BuildValidationBaselineRelease = '',
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter()][System.Collections.IDictionary]$SetupSettings
    )

    if (-not $PSCmdlet.ShouldProcess($RepoRoot, 'Update ALM configuration')) { return $false }

    $configPath = Join-Path $RepoRoot 'alm-config.psd1'
    $templatePath = if ($script:SetupRepositoryRoot) { Join-Path $script:SetupRepositoryRoot 'copy-to-your-repo\alm-config.psd1' } else { $null }

    $effectiveSolutions = @()
    if ($null -ne $Solutions) {
        $effectiveSolutions = @($Solutions)
        [void](Set-AlmConfigSolutionsInFile -ConfigPath $configPath -Solutions $effectiveSolutions -CreateIfMissing -TemplatePath $templatePath)
    }
    else {
        Write-Host 'Skipping solution list updates in alm-config.psd1 because solution selection was not run.' -ForegroundColor Yellow
    }

    if ($SetupSettings) {
        [void](Set-AlmConfigSetupSettingsInFile -ConfigPath $configPath -Settings $SetupSettings -CreateIfMissing -TemplatePath $templatePath)
    }
    [void](Set-AlmConfigSolutionCheckEnabledInFile -ConfigPath $configPath -Enabled $BuildValidationEnabled -CreateIfMissing -TemplatePath $templatePath)
    $effectiveBaselineRelease = if ($SetupSettings) { '' } else { $BuildValidationBaselineRelease }
    [void](Set-AlmConfigBuildValidationBaselineReleaseInFile -ConfigPath $configPath -BaselineRelease $effectiveBaselineRelease -CreateIfMissing -TemplatePath $templatePath)
    Write-Host "Updated alm-config.psd1 with $($effectiveSolutions.Count) solution(s); solutionCheck.enabled=$BuildValidationEnabled; buildValidation.baselineRelease='$effectiveBaselineRelease'."
}

function Update-BuildWorkflowInRepoClone {
    <#
    .SYNOPSIS
        Regenerates BUILD with explicit source branch/SHA inputs and optional validation scope.
    .DESCRIPTION
        Associates a GitHub environment only when validation is enabled with a nonblank
        name. Preserves existing secrets-json customizations, but replaces other
        workflow content. Returns false when ShouldProcess declines; otherwise writes
        the file without returning a result object.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$SharedWorkflowRepository,
        [Parameter(Mandatory)][string]$SharedWorkflowReference,
        [Parameter(Mandatory)][AllowEmptyString()][string]$BuildEnvironmentName,
        [Parameter(Mandatory)][bool]$BuildValidationEnabled,
        [Parameter()][System.Collections.IDictionary]$BuildValidationEnvironments
    )

    if (-not $PSCmdlet.ShouldProcess($RepoRoot, 'Update GitHub BUILD workflow')) { return $false }

    $buildWorkflowPath = Join-Path $RepoRoot '.github/workflows/BUILD.yml'
    $existingContent = if (Test-Path -LiteralPath $buildWorkflowPath) {
        [System.IO.File]::ReadAllText($buildWorkflowPath)
    }
    else {
        ''
    }

    $escapedBuildEnvironmentName = ([string]$BuildEnvironmentName).Replace("'", "''")

    $environmentInput = if ($BuildValidationEnabled -and -not [string]::IsNullOrWhiteSpace($BuildEnvironmentName)) {
        $escapedBuildEnvironmentName
    }
    else {
        ''
    }

    # GitHub evaluates toJSON at workflow runtime, not while this installer builds
    # text. Without validation there is no default secret to pass to the build action.
    $secretsInput = if ([string]::IsNullOrWhiteSpace($environmentInput)) {
        @'
                # Add any custom secrets explicitly to this JSON object.
                secrets-json: >-
                    {
                    }
'@
    }
    else {
        @"
                # Add any custom secrets explicitly to this JSON object.
                secrets-json: >-
                                        {
                                            "AZURE_CLIENT_SECRET": `${{ toJSON(secrets.AZURE_CLIENT_SECRET) }}
                                        }
"@
    }

    $environmentBlock = ''
    if ($BuildValidationEnabled -and -not [string]::IsNullOrWhiteSpace($BuildEnvironmentName)) {
        $environmentBlock = @"
        environment:
            name: '$escapedBuildEnvironmentName'
            deployment: false
"@
        $environmentBlock += "`r`n"
    }

    $buildValidationEnvironments = [ordered]@{}
    if ($PSBoundParameters.ContainsKey('BuildValidationEnvironments')) {
        foreach ($branchName in @($BuildValidationEnvironments.Keys | Sort-Object)) {
            $environmentName = [string]$BuildValidationEnvironments[$branchName]
            if ([string]::IsNullOrWhiteSpace([string]$branchName) -or [string]::IsNullOrWhiteSpace($environmentName)) {
                throw 'Branch BUILD validation settings must include non-empty branch and environment names.'
            }
            $buildValidationEnvironments[[string]$branchName] = $environmentName
        }
    }

    $branchAwareValidation = $PSBoundParameters.ContainsKey('BuildValidationEnvironments')
    if ($branchAwareValidation -and $buildValidationEnvironments.Count -gt 0) {
        $environmentMapJson = ConvertTo-Json -InputObject $buildValidationEnvironments -Depth 5 -Compress
        $branchNamesJson = ConvertTo-Json -InputObject @($buildValidationEnvironments.Keys) -Depth 3 -Compress
        $environmentMapLiteral = $environmentMapJson.Replace("'", "''")
        $branchNamesLiteral = $branchNamesJson.Replace("'", "''")
        $sourceBranchExpression = "(github.event_name == 'repository_dispatch' && github.event.client_payload.branch) || github.ref_name"
        $branchValidationCondition = '${{ contains(fromJSON(' + "'" + $branchNamesLiteral + "'" + '), ' + $sourceBranchExpression + ') }}'
        $branchNoValidationCondition = '${{ !contains(fromJSON(' + "'" + $branchNamesLiteral + "'" + '), ' + $sourceBranchExpression + ') }}'
        $branchEnvironmentExpression = '${{ fromJSON(' + "'" + $environmentMapLiteral + "'" + ')[' + $sourceBranchExpression + '] }}'
        $branchSecretsInput = @'
                # Add any custom secrets explicitly to this JSON object.
                secrets-json: >-
                    {
                        "AZURE_CLIENT_SECRET": ${{ toJSON(secrets.AZURE_CLIENT_SECRET) }}
                    }
'@
        $buildJobs = @"
jobs:
    build-validation:
        if: $branchValidationCondition
        runs-on: ubuntu-latest
        timeout-minutes: 360
        environment:
            name: $branchEnvironmentExpression
            deployment: false
        permissions:
            contents: write
            actions: write
            id-token: write
        steps:
            - name: Build Dataverse solutions
              uses: $SharedWorkflowRepository/.github/actions/build@$SharedWorkflowReference
              with:
                build-name: `${{ format('{0}-{1}-{2}-{3}', github.event.repository.name, (github.event_name == 'repository_dispatch' && github.event.client_payload.branch) || github.ref_name, (github.event_name == 'repository_dispatch' && github.event.client_payload.exported_at) || github.event.head_commit.timestamp || github.event.repository.updated_at || github.run_id, github.run_number) }}
                source-branch: `${{ (github.event_name == 'repository_dispatch' && github.event.client_payload.branch) || github.ref_name }}
                source-ref: `${{ (github.event_name == 'repository_dispatch' && github.event.client_payload.sha) || github.sha }}
                environment-name: $branchEnvironmentExpression
                vars-json: `${{ toJSON(vars) }}
$branchSecretsInput

    build:
        if: $branchNoValidationCondition
        runs-on: ubuntu-latest
        timeout-minutes: 360
        permissions:
            contents: write
            actions: write
            id-token: write
        steps:
            - name: Build Dataverse solutions
              uses: $SharedWorkflowRepository/.github/actions/build@$SharedWorkflowReference
              with:
                build-name: `${{ format('{0}-{1}-{2}-{3}', github.event.repository.name, (github.event_name == 'repository_dispatch' && github.event.client_payload.branch) || github.ref_name, (github.event_name == 'repository_dispatch' && github.event.client_payload.exported_at) || github.event.head_commit.timestamp || github.event.repository.updated_at || github.run_id, github.run_number) }}
                source-branch: `${{ (github.event_name == 'repository_dispatch' && github.event.client_payload.branch) || github.ref_name }}
                source-ref: `${{ (github.event_name == 'repository_dispatch' && github.event.client_payload.sha) || github.sha }}
                environment-name: ''
                vars-json: `${{ toJSON(vars) }}
"@
    }
    else {
        $buildJobs = @"
jobs:
    build:
        runs-on: ubuntu-latest
        timeout-minutes: 360
$environmentBlock        permissions:
            contents: write
            actions: write
            id-token: write
        steps:
            - name: Build Dataverse solutions
              uses: $SharedWorkflowRepository/.github/actions/build@$SharedWorkflowReference
              with:
                build-name: `${{ format('{0}-{1}-{2}-{3}', github.event.repository.name, (github.event_name == 'repository_dispatch' && github.event.client_payload.branch) || github.ref_name, (github.event_name == 'repository_dispatch' && github.event.client_payload.exported_at) || github.event.head_commit.timestamp || github.event.repository.updated_at || github.run_id) }}
                source-branch: `${{ (github.event_name == 'repository_dispatch' && github.event.client_payload.branch) || github.ref_name }}
                source-ref: `${{ (github.event_name == 'repository_dispatch' && github.event.client_payload.sha) || github.sha }}
                environment-name: '$environmentInput'
                vars-json: `${{ toJSON(vars) }}
$secretsInput
"@
    }

    # repository_dispatch runs on the default branch, so EXPORT's payload supplies
    # the actual source branch and SHA. Push/manual runs use their event ref instead.
    # Contents/actions writes support release publication and downstream dispatch;
    # id-token permits WIF. Validation environment association is not a deployment.
    $newContent = @"
name: BUILD

# Triggers on every push to any branch.
# Also supports manual runs and repository_dispatch from EXPORT.
# Packs Dataverse solutions into deployable artifacts and tags the source commit.
#
# See docs/usage/building-releases.md and docs/setup/github-setup.md

run-name: `${{ format('{0}-{1}-{2}-{3}', github.event.repository.name, (github.event_name == 'repository_dispatch' && github.event.client_payload.branch) || github.ref_name, (github.event_name == 'repository_dispatch' && github.event.client_payload.exported_at) || github.event.head_commit.timestamp || github.event.repository.updated_at || github.run_id, github.run_number) }}

on:
    push:
        branches:
            - '**'
    workflow_dispatch:
    repository_dispatch:
        types:
            - alm4dataverse-export-build

${buildJobs}
"@

                    $newContent = Merge-SecretJsonInput -ExistingContent $existingContent -GeneratedContent $newContent
                    $buildWorkflowDirectory = Split-Path -Parent $buildWorkflowPath
                    if (-not (Test-Path -LiteralPath $buildWorkflowDirectory)) {
                        New-Item -ItemType Directory -Path $buildWorkflowDirectory -Force | Out-Null
                    }
    Set-Content -LiteralPath $buildWorkflowPath -Value $newContent.TrimStart("`r", "`n") -NoNewline
}

function Update-DeployWorkflowInRepoClone {
    <#
    .SYNOPSIS
        Rebuilds DEPLOY-{branch}.yml using selected deployment environments.
    .DESCRIPTION
        DeploymentEnvironments order defines the promotion chain. An empty list removes
        the branch's workflow. Environment-approval mode accepts branch-specific dispatch
        and sequential automatic promotion; manual-gate-tag mode requires an explicit
        target. Preserves existing secrets-json inputs but regenerates other content.
        Returns false on ShouldProcess refusal; normal writes/removal have no result.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$DeploymentEnvironments,
        [Parameter(Mandatory)][string]$SharedWorkflowRepository,
        [Parameter(Mandatory)][string]$SharedWorkflowRef,
        [Parameter()][ValidateSet('manual-gate-tag','environment-approval')][string]$PromotionMode = 'manual-gate-tag'
    )

    if (-not $PSCmdlet.ShouldProcess($RepoRoot, 'Update GitHub DEPLOY workflow')) { return $false }

    $deployFilePath = Join-Path $RepoRoot ".github/workflows/DEPLOY-$Branch.yml"
    $existingContent = if (Test-Path -LiteralPath $deployFilePath) {
        [System.IO.File]::ReadAllText($deployFilePath)
    }
    else {
        ''
    }

    $deployDirectory = Split-Path -Parent $deployFilePath
    if (-not (Test-Path -LiteralPath $deployDirectory)) {
        New-Item -ItemType Directory -Path $deployDirectory -Force | Out-Null
    }

    if (-not $DeploymentEnvironments -or $DeploymentEnvironments.Count -eq 0) {
        if (Test-Path -LiteralPath $deployFilePath) {
            Remove-Item -LiteralPath $deployFilePath -Force
            Write-Host "Removed DEPLOY workflow '$deployFilePath' because branch '$Branch' has no deployment environments configured." -ForegroundColor Yellow
        }
        else {
            Write-Host "No deployment environments selected for branch '$Branch'; no DEPLOY workflow file will be created." -ForegroundColor Yellow
        }

        return
    }

    $usesRef = "$SharedWorkflowRepository/.github/actions/deploy@$SharedWorkflowRef"

    $lines = New-Object System.Collections.Generic.List[string]

    $lines.Add("name: DEPLOY-$Branch")
    if ($PromotionMode -eq 'environment-approval') {
        $lines.Add('run-name: ${{ github.event_name == ''workflow_dispatch'' && format(''Deploy {0} <- {1}'', github.event.inputs[''target-environment''] || ''auto'', github.event.inputs[''build-run-name''] || format(''latest from {0}'', github.ref_name)) || format(''Deploy auto <- run {0}'', github.run_id) }}')
    }
    else {
        $lines.Add('run-name: ${{ github.event_name == ''workflow_dispatch'' && format(''Deploy {0} <- {1}'', github.event.inputs[''target-environment''], github.event.inputs[''build-run-name''] || format(''latest from {0}'', github.ref_name)) || format(''Deploy auto <- run {0}'', github.run_id) }}')
    }
    $lines.Add("")
    $lines.Add('# Stage-per-environment deployment workflow (generated by setup-github.ps1).')
    $lines.Add('#')
    $lines.Add('# To add another environment later:')
    $lines.Add('#   1. Add it to workflow_dispatch target-environment options.')
    $lines.Add('#   2. Add a deploy-* job and chain needs to the previous stage.')
    $lines.Add('#   3. Set previous-environment-name to the previous stage short name.')
    if ($PromotionMode -eq 'environment-approval') {
        $lines.Add('#   4. In environment-approval mode, keep the repository_dispatch trigger enabled.')
    }
    $lines.Add('')
    $lines.Add('permissions:')
    $lines.Add('  actions: read')
    $lines.Add('  contents: write')
    $lines.Add('  id-token: write')
    $lines.Add('')
    $lines.Add('on:')
    if ($PromotionMode -eq 'environment-approval') {
        $dispatchBranchToken = ($Branch.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
        if ([string]::IsNullOrWhiteSpace($dispatchBranchToken)) {
            throw "Could not derive repository_dispatch event type token from branch '$Branch'."
        }

        $lines.Add('  repository_dispatch:')
        $lines.Add("    types: ['alm4dataverse-build-deploy-$dispatchBranchToken']")
    }
    $lines.Add('  workflow_dispatch:')
    $lines.Add('    inputs:')
    $lines.Add('      build-run-name:')
    $lines.Add("        description: 'Optional exact BUILD name to deploy. Leave blank to use the latest successful BUILD from this branch. Numeric run IDs also work.'")
    $lines.Add('        required: false')
    $lines.Add('        type: string')
    $lines.Add('      target-environment:')
    if ($PromotionMode -eq 'environment-approval') {
        $validEnvironmentList = ($DeploymentEnvironments | ForEach-Object { $_.ShortName }) -join ', '
        $validEnvironmentListEscaped = $validEnvironmentList.Replace("'", "''")
        $lines.Add("        description: 'Optional target environment. Leave blank to start from the first configured stage. Valid values: $validEnvironmentListEscaped.'")
        $lines.Add('        required: false')
        $lines.Add('        type: string')
    }
    else {
        $lines.Add("        description: 'Target environment to deploy to'")
        $lines.Add('        required: true')
        $lines.Add('        type: choice')
        $lines.Add('        options:')

        foreach ($env in $DeploymentEnvironments) {
            $envNameEscaped = ([string]$env.ShortName).Replace("'", "''")
            $lines.Add("          - '$envNameEscaped'")
        }
    }

    $lines.Add('')
    $lines.Add('jobs:')

    # Generated jobs limit concurrency per environment, cancelling superseded runs,
    # and request WIF, artifact-read and deployment-tag-write permissions. Names may normalize alike,
    # so job IDs must be unique independently of the displayed environment names.
    $previousJobId = $null
    $previousEnvName = ''
    $jobIdSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    for ($i = 0; $i -lt $DeploymentEnvironments.Count; $i++) {
        $envName = [string]$DeploymentEnvironments[$i].ShortName
        $envNameEscaped = $envName.Replace("'", "''")
        $branchEscaped = $Branch.Replace("'", "''")

        $baseJobId = ('deploy-' + (($envName.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')))
        if ([string]::IsNullOrWhiteSpace($baseJobId) -or $baseJobId -eq 'deploy-') {
            $baseJobId = "deploy-stage-$($i + 1)"
        }

        $jobId = $baseJobId
        $suffix = 2
        while ($jobIdSet.Contains($jobId)) {
            $jobId = "$baseJobId-$suffix"
            $suffix++
        }
        [void]$jobIdSet.Add($jobId)

        $lines.Add("  ${jobId}:")
        # Targeted manual runs may skip preceding jobs. Automatic continuation must
        # instead require the previous job's success and the dispatch's matching branch.
        if ($i -eq 0) {
            $lines.Add('    # First stage in the chain.')
            if ($PromotionMode -eq 'manual-gate-tag') {
                $lines.Add('    # Manual-gate-tag mode requires an explicit workflow_dispatch, even for stage 1.')
            }

            if ($PromotionMode -eq 'environment-approval') {
                $lines.Add('    if: >-')
                $lines.Add('      (')
                $lines.Add("        github.event_name == 'repository_dispatch' &&")
                $lines.Add("        '$PromotionMode' == 'environment-approval' &&")
                $lines.Add("        github.event.client_payload.branch == '$branchEscaped'")
                $lines.Add('      ) || (')
                $lines.Add('        github.event_name == ''workflow_dispatch'' &&')
                $lines.Add('        (')
                $lines.Add("          inputs.target-environment == '$envNameEscaped' ||")
                $lines.Add("          ('$PromotionMode' == 'environment-approval' && inputs.target-environment == '')")
                $lines.Add('        )')
                $lines.Add('      )')
            }
            else {
                $lines.Add("    if: `${{ github.event_name == 'workflow_dispatch' && inputs.target-environment == '$envNameEscaped' }}")
            }
        }
        else {
            $lines.Add("    needs: $previousJobId")
            $lines.Add('    # Allow manual targeted deploys even when earlier jobs are skipped in this run,')
            $lines.Add('    # but do not bypass failed prerequisite stages on automatic runs.')
            if ($PromotionMode -eq 'environment-approval') {
                $lines.Add('    if: >-')
                $lines.Add('      !cancelled() && (')
                $lines.Add('      (')
                $lines.Add("        github.event_name == 'repository_dispatch' &&")
                $lines.Add("        '$PromotionMode' == 'environment-approval' &&")
                $lines.Add("        github.event.client_payload.branch == '$branchEscaped' &&")
                $lines.Add("        needs['{0}'].result == 'success'" -f $previousJobId)
                $lines.Add('      ) || (')
                $lines.Add("        github.event_name == 'workflow_dispatch' &&")
                $lines.Add('        (')
                $lines.Add(("          inputs.target-environment == '{0}' ||" -f $envNameEscaped))
                $lines.Add(("          ('$PromotionMode' == 'environment-approval' && inputs.target-environment == '' && needs['{0}'].result == 'success')" -f $previousJobId))
                $lines.Add('        )')
                $lines.Add('      )')
                $lines.Add('      )')
            }
            else {
                $lines.Add("    if: `${{ !cancelled() && github.event_name == 'workflow_dispatch' && inputs.target-environment == '$envNameEscaped' }}")
            }
        }

        $lines.Add('    runs-on: ubuntu-latest')
        $lines.Add('    timeout-minutes: 360')
        $lines.Add("    environment: '$envNameEscaped'")
        $lines.Add('    concurrency:')
        $lines.Add("      group: alm4dataverse-environment-$envNameEscaped")
        $lines.Add('      cancel-in-progress: true')
        $lines.Add('    permissions:')
        $lines.Add('      actions: read')
        $lines.Add('      contents: write')
        $lines.Add('      id-token: write')
        $lines.Add('    steps:')
        $lines.Add("      - name: Deploy to $envNameEscaped")
        $lines.Add("        uses: $usesRef")
        $lines.Add('        with:')
        $lines.Add("          environment-name: '$envNameEscaped'")
        if ($i -eq 0) {
            $lines.Add("          previous-environment-name: ''")
        }
        else {
            $prevEscaped = $previousEnvName.Replace("'", "''")
            $lines.Add("          previous-environment-name: '$prevEscaped'")
        }
        $lines.Add("          promotion-mode: $PromotionMode")
        $lines.Add("          trigger-branch: '$branchEscaped'")
        $lines.Add('          github-context-json: ${{ toJSON(github) }}')
        $lines.Add('          caller-inputs-json: ${{ toJSON(inputs) }}')
        $lines.Add('          vars-json: ${{ toJSON(vars) }}')
        $lines.Add('          # Add any custom secrets explicitly to this JSON object.')
        $lines.Add('          secrets-json: >-')
        $lines.Add('            {')
        $lines.Add('              "AZURE_CLIENT_SECRET": ${{ toJSON(secrets.AZURE_CLIENT_SECRET) }}')
        $lines.Add('            }')
        $lines.Add('')

        $previousJobId = $jobId
        $previousEnvName = $envName
    }

    $output = ($lines -join [Environment]::NewLine).TrimEnd() + [Environment]::NewLine
    $output = Merge-SecretJsonInput -ExistingContent $existingContent -GeneratedContent $output
    Set-Content -LiteralPath $deployFilePath -Value $output -NoNewline

    $envList = ($DeploymentEnvironments | ForEach-Object { $_.ShortName }) -join ', '
    Write-Host "Updated DEPLOY workflow '$deployFilePath' with environments: $envList (promotion mode: $PromotionMode)" -ForegroundColor Green
}
