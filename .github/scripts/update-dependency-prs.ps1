<#
.SYNOPSIS
    Creates or updates PRs for outdated script dependencies
.DESCRIPTION
    For each outdated dependency found, this script creates a new PR or updates
    an existing PR if one is already open for the same dependency.
#>

$ErrorActionPreference = "Stop"

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
git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"

# Determine base branch from the current repository
$baseBranch = git rev-parse --abbrev-ref HEAD
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
    $existingPRs = gh pr list --state open --json number,headRefName,title | ConvertFrom-Json
    $existingPR = $existingPRs | Where-Object { $_.headRefName -like "deps/update-$($moduleName.ToLower())-*" }
    
    # Fetch the base branch to ensure we have the latest
    git fetch origin $baseBranch
    
    if ($existingPR) {
        Write-Host "Found existing PR #$($existingPR.number) with branch $($existingPR.headRefName)"
        
        # Checkout and update the existing branch
        try {
            git fetch origin $existingPR.headRefName
            git checkout -B $existingPR.headRefName origin/$existingPR.headRefName
            # Rebase on top of base branch for linear history
            git rebase origin/$baseBranch
        }
        catch {
            Write-Host "##[warning]Could not checkout/rebase existing branch, creating new one"
            git rebase --abort 2>$null || $true
            git checkout -b $branchName origin/$baseBranch
        }
    } else {
        Write-Host "Creating new branch: $branchName"
        git checkout -b $branchName origin/$baseBranch
        # Fetch the remote branch if it already exists (e.g. from a previous failed run)
        # so that --force-with-lease has a valid remote tracking ref to compare against
        git fetch origin ${branchName} 2>&1 | Out-Null
    }
    
    # Update the dependency in alm-config-defaults.psd1
    $configPath = "alm-config-defaults.psd1"
    $configContent = Get-Content $configPath -Raw
    
    # Escape special regex characters in module name and version
    $escapedModuleName = [regex]::Escape($moduleName)
    $escapedCurrentVersion = [regex]::Escape($currentVersion)
    
    # Replace the version for this specific module - handle both single and double quotes
    $pattern = "(`"$escapedModuleName`"|'$escapedModuleName')\s*=\s*(`"|')$escapedCurrentVersion(`"|')"
    $replacement = "`${1} = `"`$latestVersion`""
    $newContent = $configContent -replace $pattern, $replacement
    
    if ($configContent -eq $newContent) {
        Write-Host "##[warning]No changes made to config file for $moduleName"
        # Return to base branch and continue
        git checkout $baseBranch 2>$null || $true
        continue
    }
    
    Set-Content -Path $configPath -Value $newContent -NoNewline
    
    # Check if there are actual changes
    $gitStatus = git status --porcelain
    if (-not $gitStatus) {
        Write-Host "##[warning]No git changes detected for $moduleName"
        git checkout $baseBranch 2>$null || $true
        continue
    }
    
    # Commit and push
    git add $configPath
    git commit -m "chore(deps): update $moduleName to $latestVersion"
    git push --force-with-lease origin HEAD
    if ($LASTEXITCODE -ne 0) {
        Write-Host "##[error]Failed to push branch for $moduleName"
        $hasErrors = $true
        git checkout $baseBranch 2>$null || $true
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
            gh pr edit $existingPR.number --title $prTitle --body $prBody
            Write-Host "✓ Updated PR #$($existingPR.number)"
        }
        catch {
            Write-Host "##[error]Failed to update PR: $_"
            $hasErrors = $true
            git checkout $baseBranch 2>$null || $true
            continue
        }
    } else {
        Write-Host "Creating new PR"
        try {
            $newPR = gh pr create --title $prTitle --body $prBody --base $baseBranch --head $branchName
            Write-Host "✓ Created new PR: $newPR"
        }
        catch {
            Write-Host "##[error]Failed to create PR: $_"
            $hasErrors = $true
            git checkout $baseBranch 2>$null || $true
            continue
        }
    }
    
    # Return to base branch for next iteration
    git checkout $baseBranch 2>$null || $true
}

Write-Host "`nAll PRs created/updated successfully!"

if ($hasErrors) {
    Write-Host "##[error]One or more dependencies could not be processed. See errors above."
    exit 1
}
