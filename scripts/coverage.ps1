function Get-ModifiedPowerShellFile {
    <#
    .SYNOPSIS
        Lists existing executable PowerShell source paths affected by a comparison.
    .DESCRIPTION
        With HeadRef, compares committed revisions; an all-zero base selects the
        complete head tree, and an omitted base uses the head's first parent.
        Without HeadRef, includes staged, unstaged and non-ignored untracked files.
        Tests and deleted paths are excluded. Git failures terminate validation.
    .OUTPUTS
        System.String. Unique repository-relative paths with forward slashes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [string]$BaseRef = '',
        [string]$HeadRef = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($HeadRef)) {
        if ([string]::IsNullOrWhiteSpace($BaseRef)) {
            $commitInfo = @(& git -C $RepositoryRoot rev-list --parents -n 1 $HeadRef)
            if ($LASTEXITCODE -ne 0) {
                throw 'Could not resolve the coverage comparison commit.'
            }
            $commitParts = ($commitInfo -join ' ').Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
            $BaseRef = if ($commitParts.Count -gt 1) { $commitParts[1] } else { '0000000000000000000000000000000000000000' }
        }
        # A new branch/root commit has no prior tree; do not silently skip its files.
        if ($BaseRef -match '^0+$') {
            $output = @(& git -c core.quotepath=false -C $RepositoryRoot ls-tree -r --name-only -z $HeadRef)
        }
        else {
            $output = @(& git -c core.quotepath=false -C $RepositoryRoot diff --name-only -z --find-renames --diff-filter=ACMR "$BaseRef..$HeadRef" --)
        }
    }
    else {
        $comparisonRef = if ([string]::IsNullOrWhiteSpace($BaseRef)) { 'HEAD' } else { $BaseRef }
        $output = @(& git -c core.quotepath=false -C $RepositoryRoot diff --name-only -z --find-renames --diff-filter=ACMR $comparisonRef --)
        if ($LASTEXITCODE -ne 0) {
            throw 'Could not determine modified PowerShell files.'
        }
        $output += @(& git -c core.quotepath=false -C $RepositoryRoot ls-files --others --exclude-standard -z)
    }
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not determine modified PowerShell files.'
    }

    $paths = ($output -join "`n").Split([char]0, [StringSplitOptions]::RemoveEmptyEntries)
    foreach ($path in @($paths | Sort-Object -Unique)) {
        $normalizedPath = $path.Replace('\', '/')
        if ($normalizedPath -match '\.(ps1|psm1)$' -and $normalizedPath -notmatch '(^|/)tests/|\.Tests\.(ps1|psm1)$' -and
            (Test-Path -LiteralPath (Join-Path $RepositoryRoot $path) -PathType Leaf)) {
            $normalizedPath
        }
    }
}

function Get-PowerShellFileCoverage {
    <#
    .SYNOPSIS
        Returns whole-file command coverage decisions for the supplied source paths.
    .DESCRIPTION
        Matches Pester's executed and missed commands by absolute path. Files with
        no commands are not applicable and pass; other files use the unrounded
        percentage, so display rounding cannot turn a failing result into a pass.
    .PARAMETER Coverage
        Pester CodeCoverage data containing CommandsExecuted and CommandsMissed.
    .PARAMETER MinimumPercent
        Inclusive per-file threshold, from 0 to 100; defaults to 65.
    .OUTPUTS
        PSCustomObject with Path, command counts, Percent, MinimumPercent, Passed
        and a human-readable Status for each requested file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ModifiedFiles,
        [Parameter(Mandatory)]$Coverage,
        [ValidateRange(0, 100)][double]$MinimumPercent = 65
    )

    foreach ($relativePath in $ModifiedFiles) {
        $fullPath = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot $relativePath))
        $executedCount = @($Coverage.CommandsExecuted | Where-Object { $_.File -eq $fullPath }).Count
        $missedCount = @($Coverage.CommandsMissed | Where-Object { $_.File -eq $fullPath }).Count
        $totalCount = $executedCount + $missedCount
        $percent = if ($totalCount -eq 0) { 100.0 } else { 100.0 * $executedCount / $totalCount }
        [pscustomobject]@{
            Path = $relativePath
            ExecutedCommands = $executedCount
            TotalCommands = $totalCount
            Percent = $percent
            MinimumPercent = $MinimumPercent
            Passed = $percent -ge $MinimumPercent
            Status = if ($totalCount -eq 0) { 'No executable commands' } elseif ($percent -ge $MinimumPercent) { 'Passed' } else { 'Failed' }
        }
    }
}