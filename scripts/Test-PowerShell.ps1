#Requires -Version 7.2

[CmdletBinding()]
param(
    [string]$BaseRef = '',
    [string]$HeadRef = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'coverage.ps1')
$policy = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'powershell-validation.psd1')
foreach ($tool in $policy.Tools.GetEnumerator()) {
    Import-Module -Name $tool.Key -RequiredVersion $tool.Value -ErrorAction Stop
}

$trackedPaths = @(& git -C $repoRoot ls-files --cached --others --exclude-standard)
if ($LASTEXITCODE -ne 0) {
    throw 'Could not enumerate repository files.'
}
$sourcePaths = @($trackedPaths | Where-Object { $_ -match '\.(ps1|psm1|psd1|psrc|pssc|ps1xml|cdxml)$' } | Sort-Object -Unique)
$coveragePaths = @($sourcePaths | Where-Object { $_ -match '\.(ps1|psm1)$' -and $_ -notmatch '(^|/)tests/|\.Tests\.(ps1|psm1)$' })
$exceptions = @{}
foreach ($exception in $policy.Exceptions) {
    if ([string]::IsNullOrWhiteSpace($exception.Reason)) {
        throw 'Every analyzer exception must have a justification.'
    }
    $key = '{0}|{1}|{2}|{3}' -f $exception.Path, $exception.Rule, $exception.Function, $exception.Source
    if ($exceptions.ContainsKey($key)) {
        throw "Duplicate analyzer exception: $key"
    }
    $exceptions[$key] = 0
}

$failures = [System.Collections.Generic.List[string]]::new()
foreach ($relativePath in $sourcePaths) {
    $fullPath = Join-Path $repoRoot $relativePath
    if ($relativePath -match '\.(ps1xml|cdxml)$') {
        try {
            $null = [xml](Get-Content -LiteralPath $fullPath -Raw)
        }
        catch {
            $failures.Add(('{0}: Invalid XML: {1}' -f $relativePath, $_.Exception.Message))
        }
        continue
    }
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($fullPath, [ref]$tokens, [ref]$parseErrors)
    foreach ($parseError in $parseErrors) {
        $failures.Add(('{0}:{1}: {2}' -f $relativePath, $parseError.Extent.StartLineNumber, $parseError.Message))
    }
    if (@($parseErrors).Count -gt 0) {
        continue
    }
    if ($relativePath -match '\.(psrc|pssc)$') {
        continue
    }
    foreach ($diagnostic in @(Invoke-ScriptAnalyzer -Path $fullPath -Settings $policy.AnalyzerSettings)) {
        $node = $null
        $source = ''
        if ($null -ne $diagnostic.Extent) {
            $source = $diagnostic.Extent.Text
            $node = $ast.Find({
                param($candidate)
                $candidate.Extent.StartOffset -eq $diagnostic.Extent.StartOffset -and
                    $candidate.Extent.EndOffset -eq $diagnostic.Extent.EndOffset
            }, $true)
            if ($null -eq $node) {
                $node = $ast.FindAll({
                    param($candidate)
                    $candidate -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                        $candidate.Extent.StartOffset -le $diagnostic.Extent.StartOffset -and
                        $candidate.Extent.EndOffset -ge $diagnostic.Extent.EndOffset
                }, $true) | Sort-Object { $_.Extent.StartOffset } -Descending | Select-Object -First 1
            }
        }
        while ($null -ne $node -and $node -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) {
            $node = $node.Parent
        }
        $functionName = if ($null -ne $node) { $node.Name } else { '<script>' }
        $key = '{0}|{1}|{2}|{3}' -f $relativePath.Replace('\', '/'), $diagnostic.RuleName, $functionName, $source
        if ($exceptions.ContainsKey($key)) {
            $exceptions[$key]++
        }
        else {
            $location = if ($null -ne $diagnostic.Line) { $diagnostic.Line } else { '<file>' }
            $failures.Add(('{0}:{1}: {2}: {3}' -f $relativePath, $location, $diagnostic.RuleName, $diagnostic.Message))
        }
    }
}
foreach ($key in $exceptions.Keys) {
    if ($exceptions[$key] -ne 1) {
        $failures.Add("Analyzer exception must match exactly one finding; found $($exceptions[$key]): $key")
    }
}
if ($failures.Count -gt 0) {
    throw ($failures -join [Environment]::NewLine)
}
Write-Output "Parsed and analyzed $($sourcePaths.Count) PowerShell files; $($exceptions.Count) justified analyzer exceptions."

$modifiedFiles = @(Get-ModifiedPowerShellFile -RepositoryRoot $repoRoot -BaseRef $BaseRef -HeadRef $HeadRef)
$configuration = New-PesterConfiguration
$configuration.Run.Path = Join-Path $repoRoot 'tests'
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'Normal'
$configuration.TestResult.Enabled = $true
$configuration.TestResult.OutputPath = Join-Path $repoRoot 'TestResults/powershell.xml'
$configuration.TestResult.OutputFormat = 'NUnitXml'
$configuration.CodeCoverage.Enabled = $true
$configuration.CodeCoverage.UseBreakpoints = $false
$configuration.CodeCoverage.Path = @($coveragePaths | ForEach-Object { Join-Path $repoRoot $_ })
$configuration.CodeCoverage.OutputPath = Join-Path $repoRoot 'TestResults/coverage.xml'
$configuration.CodeCoverage.OutputFormat = 'JaCoCo'
$configuration.CodeCoverage.CoveragePercentTarget = 0
$result = Invoke-Pester -Configuration $configuration
$coverageReport = @(Get-PowerShellFileCoverage -RepositoryRoot $repoRoot -ModifiedFiles $modifiedFiles -Coverage $result.CodeCoverage -MinimumPercent 65)
$reportPath = Join-Path $repoRoot 'TestResults/coverage-files.json'
ConvertTo-Json -InputObject $coverageReport -Depth 5 | Set-Content -LiteralPath $reportPath -Encoding utf8
$allFileCoverage = @(Get-PowerShellFileCoverage -RepositoryRoot $repoRoot -ModifiedFiles $coveragePaths -Coverage $result.CodeCoverage -MinimumPercent 65)
ConvertTo-Json -InputObject $allFileCoverage -Depth 5 | Set-Content -LiteralPath (Join-Path $repoRoot 'TestResults/coverage-all-files.json') -Encoding utf8
$summary = [System.Collections.Generic.List[string]]::new()
$summary.Add('# Changed PowerShell File Coverage')
$summary.Add('')
$summary.Add('Minimum command coverage: 65% per changed executable file.')
$summary.Add('')
$summary.Add('| File | Executed / Total Commands | Coverage | Result |')
$summary.Add('|---|---:|---:|---|')
foreach ($entry in $coverageReport) {
    $summary.Add(('| {0} | {1} / {2} | {3:F2}% | {4} |' -f $entry.Path, $entry.ExecutedCommands, $entry.TotalCommands, $entry.Percent, $entry.Status))
}
if ($coverageReport.Count -eq 0) {
    $summary.Add('')
    $summary.Add('No executable PowerShell source files changed.')
}
$summaryText = $summary -join [Environment]::NewLine
$summaryText | Set-Content -LiteralPath (Join-Path $repoRoot 'TestResults/coverage-summary.md') -Encoding utf8
if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
    $summaryText | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8
}
Write-Output $summaryText
if ($result.TotalCount -eq 0 -or $result.FailedCount -gt 0 -or $result.FailedContainersCount -gt 0) {
    throw "Pester failed: $($result.FailedCount) tests and $($result.FailedContainersCount) containers failed."
}
Write-Output "Passed $($result.PassedCount) PowerShell tests."
$underCoveredFiles = @($coverageReport | Where-Object { -not $_.Passed })
if ($underCoveredFiles.Count -gt 0) {
    throw "Changed PowerShell files below 65% command coverage: $($underCoveredFiles.Path -join ', ')."
}