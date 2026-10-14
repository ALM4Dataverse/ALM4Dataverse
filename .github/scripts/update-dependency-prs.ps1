<#
.SYNOPSIS
    Creates or updates PRs for outdated script dependencies
.DESCRIPTION
    For each outdated dependency found, this script creates a new PR or updates
    an existing PR if one is already open for the same dependency.
#>

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot '../../pipelines/scripts/common.ps1')

Write-Host "Creating/updating PRs for outdated dependencies..."

# Read the outdated dependencies
if (-not (Test-Path "outdated-deps.json")) {
    Write-Host "No outdated dependencies file found"
    exit 0
}

$outdatedDeps = Get-Content "outdated-deps.json" -Raw | ConvertFrom-Json

if (-not $outdatedDeps -or $outdatedDeps.Count -eq 0) {
    Write-Host "No outdated dependencies to process"
    exit 0
}

# Configure git
Invoke-CheckedNativeCommand -Command git -Arguments @('config', 'user.name', 'github-actions[bot]')
Invoke-CheckedNativeCommand -Command git -Arguments @('config', 'user.email', 'github-actions[bot]@users.noreply.github.com')

# Determine base branch from the current repository
$baseBranch = Invoke-CheckedNativeCommand -Command git -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')
if ($baseBranch -like "deps/*" -or $baseBranch -like "copilot/*") {
    # If we're on a feature branch, use main as base
    $baseBranch = "main"
}

Write-Host "Using base branch: $baseBranch"

$hasErrors = $false

foreach ($dep in $outdatedDeps) {
    $moduleName = $dep.name
    $currentVersion = $dep.currentVersion
    $latestVersion = $dep.latestVersion

    Write-Host "`nProcessing $moduleName ($currentVersion -> $latestVersion)..."

    # Create branch name
    $branchName = "deps/update-$($moduleName.ToLower())-to-$latestVersion"

    # Check if a PR already exists for this dependency
    $existingPRs = Invoke-CheckedNativeCommand -Command gh -Arguments @('pr', 'list', '--state', 'open', '--json', 'number,headRefName,title') | ConvertFrom-Json
    $existingPR = $existingPRs | Where-Object { $_.headRefName -like "deps/update-$($moduleName.ToLower())-*" }

    # Fetch the base branch to ensure we have the latest
    Invoke-CheckedNativeCommand -Command git -Arguments @('fetch', 'origin', $baseBranch)

    if ($existingPR) {
        Write-Host "Found existing PR #$($existingPR.number) with branch $($existingPR.headRefName)"

        # Checkout and update the existing branch
        try {
            Invoke-CheckedNativeCommand -Command git -Arguments @('fetch', 'origin', $existingPR.headRefName)
            Invoke-CheckedNativeCommand -Command git -Arguments @('checkout', '-B', $existingPR.headRefName, "origin/$($existingPR.headRefName)")
            # Rebase on top of base branch for linear history
            Invoke-CheckedNativeCommand -Command git -Arguments @('rebase', "origin/$baseBranch")
        }
        catch {
            Write-Host "##[warning]Could not checkout/rebase existing branch, creating new one"
            Invoke-CheckedNativeCommand -Command git -Arguments @('rebase', '--abort') -AllowFailure | Out-Null
            Invoke-CheckedNativeCommand -Command git -Arguments @('checkout', '-b', $branchName, "origin/$baseBranch")
        }
    } else {
        Write-Host "Creating new branch: $branchName"
        Invoke-CheckedNativeCommand -Command git -Arguments @('checkout', '-b', $branchName, "origin/$baseBranch")
        # Fetch the remote branch if it already exists (e.g. from a previous failed run)
        # so that --force-with-lease has a valid remote tracking ref to compare against
        Invoke-CheckedNativeCommand -Command git -Arguments @('fetch', 'origin', $branchName) -AllowFailure | Out-Null
    }

    # Update the dependency in alm-config-defaults.psd1
    $configPath = "alm-config-defaults.psd1"
    $configContent = Get-Content $configPath -Raw

    # Escape special regex characters in module name and version
    $escapedModuleName = [regex]::Escape($moduleName)
    $escapedCurrentVersion = [regex]::Escape($currentVersion)

    # Replace the version for this specific module - handle both single and double quotes
    $pattern = "(`"$escapedModuleName`"|'$escapedModuleName')\s*=\s*(`"|')$escapedCurrentVersion(`"|')"
    $replacement = "`${1} = `"$latestVersion`""
    $newContent = $configContent -replace $pattern, $replacement

    if ($configContent -eq $newContent) {
        Write-Host "##[warning]No changes made to config file for $moduleName"
        # Return to base branch and continue
        Invoke-CheckedNativeCommand -Command git -Arguments @('checkout', $baseBranch)
        continue
    }

    Set-Content -Path $configPath -Value $newContent -NoNewline

    # Check if there are actual changes
    $gitStatus = Invoke-CheckedNativeCommand -Command git -Arguments @('status', '--porcelain')
    if (-not $gitStatus) {
        Write-Host "##[warning]No git changes detected for $moduleName"
        Invoke-CheckedNativeCommand -Command git -Arguments @('checkout', $baseBranch)
        continue
    }

    # Commit and push
    Invoke-CheckedNativeCommand -Command git -Arguments @('add', $configPath)
    Invoke-CheckedNativeCommand -Command git -Arguments @('commit', '-m', "chore(deps): update $moduleName to $latestVersion")
    git push --force-with-lease origin HEAD
    if ($LASTEXITCODE -ne 0) {
        Write-Host "##[error]Failed to push branch for $moduleName"
        $hasErrors = $true
        Invoke-CheckedNativeCommand -Command git -Arguments @('checkout', $baseBranch)
        continue
    }

    # Create or update PR
    $prTitle = "chore(deps): update $moduleName to $latestVersion"
    $prBody = @"
## Dependency Update

This PR updates the ``$moduleName`` PowerShell module dependency.

- **Current version:** $currentVersion
- **New version:** $latestVersion

### Changes
- Updates ``$moduleName`` in ``alm-config-defaults.psd1``

---
*This PR was automatically created by the Update Script Dependencies workflow.*
"@

    if ($existingPR) {
        Write-Host "Updating existing PR #$($existingPR.number)"
        try {
            Invoke-CheckedNativeCommand -Command gh -Arguments @('pr', 'edit', $existingPR.number, '--title', $prTitle, '--body', $prBody)
            Write-Host "✓ Updated PR #$($existingPR.number)"
        }
        catch {
            Write-Host "##[error]Failed to update PR: $_"
            $hasErrors = $true
            Invoke-CheckedNativeCommand -Command git -Arguments @('checkout', $baseBranch)
            continue
        }
    } else {
        Write-Host "Creating new PR"
        try {
            $newPR = Invoke-CheckedNativeCommand -Command gh -Arguments @('pr', 'create', '--title', $prTitle, '--body', $prBody, '--base', $baseBranch, '--head', $branchName)
            Write-Host "✓ Created new PR: $newPR"
        }
        catch {
            Write-Host "##[error]Failed to create PR: $_"
            $hasErrors = $true
            Invoke-CheckedNativeCommand -Command git -Arguments @('checkout', $baseBranch)
            continue
        }
    }

    # Return to base branch for next iteration
    Invoke-CheckedNativeCommand -Command git -Arguments @('checkout', $baseBranch)
}

if ($hasErrors) {
    Write-Host "##[error]One or more dependencies could not be processed. See errors above."
    exit 1
}

Write-Host "`nAll PRs created/updated successfully!"
