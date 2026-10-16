#Requires -Version 7.2

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$TestPaths,
    [Parameter(Mandatory)][string[]]$CoveragePaths,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$PesterVersion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$workerCount = [Math]::Min(4, [Math]::Min([Environment]::ProcessorCount, $TestPaths.Count))
$shards = @(
    for ($index = 0; $index -lt $workerCount; $index++) {
        [pscustomobject]@{
            Name = '{0:D2}' -f ($index + 1)
            TestPaths = [System.Collections.Generic.List[string]]::new()
        }
    }
)
for ($index = 0; $index -lt $TestPaths.Count; $index++) {
    $shards[$index % $workerCount].TestPaths.Add($TestPaths[$index])
}

$jobs = @(
    foreach ($shard in $shards) {
        $workerName = $shard.Name
        $workerParameters = @{
            ShardName = $workerName
            TestPaths = @($shard.TestPaths)
            CoveragePaths = $CoveragePaths
            OutputDirectory = $OutputDirectory
            PesterVersion = $PesterVersion
        }
        Start-Job -Name $workerName -ScriptBlock {
            $ErrorActionPreference = 'Stop'
            $shardName = $using:workerParameters.ShardName
            $testPaths = $using:workerParameters.TestPaths
            $coveragePaths = $using:workerParameters.CoveragePaths
            $outputDirectory = $using:workerParameters.OutputDirectory
            $pesterVersion = $using:workerParameters.PesterVersion
            Import-Module Pester -RequiredVersion $pesterVersion -ErrorAction Stop

            $configuration = New-PesterConfiguration
            $configuration.Run.Path = $testPaths
            $configuration.Run.PassThru = $true
            $configuration.Output.Verbosity = 'None'
            $configuration.TestResult.Enabled = $true
            $configuration.TestResult.OutputPath = Join-Path $outputDirectory "powershell-shard-$shardName.xml"
            $configuration.TestResult.OutputFormat = 'NUnitXml'
            $configuration.CodeCoverage.Enabled = $true
            $configuration.CodeCoverage.UseBreakpoints = $false
            $configuration.CodeCoverage.Path = $coveragePaths
            $configuration.CodeCoverage.OutputPath = Join-Path $outputDirectory "coverage-shard-$shardName.xml"
            $configuration.CodeCoverage.OutputFormat = 'JaCoCo'
            $configuration.CodeCoverage.CoveragePercentTarget = 0
            $result = Invoke-Pester -Configuration $configuration

            $failedTests = @(
                foreach ($test in $result.Failed) {
                    [pscustomobject]@{
                        Name = $test.ExpandedName
                        Messages = @($test.ErrorRecord | ForEach-Object { $_.Exception.Message })
                    }
                }
            )
            $failedContainers = @(
                foreach ($container in $result.FailedContainers) {
                    foreach ($record in $container.ErrorRecord) { $record.Exception.Message }
                }
            )
            $coverageCommands = @(
                foreach ($command in @($result.CodeCoverage.CommandsExecuted) + @($result.CodeCoverage.CommandsMissed)) {
                    [pscustomobject]@{
                        File = $command.File
                        StartLine = $command.StartLine
                        EndLine = $command.EndLine
                        StartColumn = $command.StartColumn
                        EndColumn = $command.EndColumn
                        HitCount = $command.HitCount
                    }
                }
            )
            $summary = [pscustomobject]@{
                ShardName = $shardName
                TotalCount = $result.TotalCount
                PassedCount = $result.PassedCount
                FailedCount = $result.FailedCount
                FailedContainersCount = $result.FailedContainersCount
                FailedTests = $failedTests
                FailedContainers = $failedContainers
                CoverageCommands = $coverageCommands
            }
            $summaryJson = ConvertTo-Json -InputObject $summary -Depth 6
            [IO.File]::WriteAllText(
                (Join-Path $outputDirectory "powershell-shard-$shardName.json"),
                $summaryJson,
                [Text.UTF8Encoding]::new($false)
            )
        }
    }
)

try {
    $null = Wait-Job -Job $jobs
    foreach ($job in $jobs) {
        $jobErrors = @()
        $null = Receive-Job -Job $job -ErrorAction Continue -ErrorVariable +jobErrors
        $summaryPath = Join-Path $OutputDirectory ('powershell-shard-{0}.json' -f $job.Name)
        if ($job.State -ne 'Completed' -or -not (Test-Path -LiteralPath $summaryPath)) {
            $details = @($jobErrors | ForEach-Object { $_.ToString() })
            $reason = $job.ChildJobs[0].JobStateInfo.Reason
            if ($details.Count -eq 0 -and $null -ne $reason) { $details = @($reason.ToString()) }
            throw "PowerShell test worker '$($job.Name)' failed: $($details -join [Environment]::NewLine)"
        }
    }
}
finally {
    Remove-Job -Job $jobs -Force
}

$workerSummaries = @(
    foreach ($shard in $shards) {
        Get-Content -LiteralPath (Join-Path $OutputDirectory "powershell-shard-$($shard.Name).json") -Raw | ConvertFrom-Json
    }
)
$coverageCommands = @{}
foreach ($summary in $workerSummaries) {
    foreach ($command in @($summary.CoverageCommands)) {
        $key = '{0}|{1}|{2}|{3}|{4}' -f $command.File, $command.StartLine, $command.EndLine, $command.StartColumn, $command.EndColumn
        if (-not $coverageCommands.ContainsKey($key)) {
            $coverageCommands[$key] = [pscustomobject]@{ File = $command.File; Executed = $false }
        }
        if ($command.HitCount -gt 0) { $coverageCommands[$key].Executed = $true }
    }
}
$executedCommands = [System.Collections.Generic.List[object]]::new()
$missedCommands = [System.Collections.Generic.List[object]]::new()
foreach ($command in $coverageCommands.Values) {
    $coverageEntry = [pscustomobject]@{ File = $command.File }
    if ($command.Executed) { $executedCommands.Add($coverageEntry) }
    else { $missedCommands.Add($coverageEntry) }
}
$failedTests = @($workerSummaries | ForEach-Object { $_.FailedTests })
$failedContainers = @($workerSummaries | ForEach-Object { $_.FailedContainers })
[pscustomobject]@{
    TotalCount = ($workerSummaries | Measure-Object -Property TotalCount -Sum).Sum
    PassedCount = ($workerSummaries | Measure-Object -Property PassedCount -Sum).Sum
    FailedCount = ($workerSummaries | Measure-Object -Property FailedCount -Sum).Sum
    FailedContainersCount = ($workerSummaries | Measure-Object -Property FailedContainersCount -Sum).Sum
    FailedTests = $failedTests
    FailedContainers = $failedContainers
    WorkerCount = $workerCount
    CodeCoverage = [pscustomobject]@{
        CommandsExecuted = $executedCommands.ToArray()
        CommandsMissed = $missedCommands.ToArray()
    }
}
