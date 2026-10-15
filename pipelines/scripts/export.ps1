<#
.SYNOPSIS
    Exports Dataverse solutions from a specified environment and unpacks them into the source directory.
.DESCRIPTION
    This script exports the Dataverse solutions defined in alm-config.psd1 from the connected
    Dataverse environment. It exports both managed and unmanaged versions of each solution
    and saves them to the specified artifact staging directory.

    After exporting, it unpacks each solution into the source directory's solution folders.
    If any changes are detected in the unpacked solutions compared to the existing source,
    it increments the solution version in both the source and the environment.

    Hooks defined in alm-config.psd1 are invoked at various stages of the export process
    to allow for custom pre- and post-export actions.
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$SourceDirectory,

    [Parameter(Mandatory=$true)]
    [string]$ArtifactStagingDirectory,

    [string]$TempDirectory = "([IO.Path]::GetTempPath())\$([IO.Path]::GetTempFileName())",

    [Parameter(Mandatory=$false)]
    [string]$EnvironmentName = "Unknown",

    [Parameter(Mandatory=$true)]
    [string]$BranchName,

    [string]$DefaultBranchName,

    [switch]$PassThru
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'parallel-export.ps1')

$exportClock = [System.Diagnostics.Stopwatch]::StartNew()
Write-Host "##[section]Exporting Solutions from $EnvironmentName"

# Read solutions configuration
$solutionsConfig = Get-AlmConfig -BaseDirectory $SourceDirectory -LogConfig:$false
$exportSettings = Get-AlmExportSetting -Config $solutionsConfig
$branchBaseVersion = Resolve-AlmBranchBaseVersion -Config $solutionsConfig -BranchName $BranchName
if (-not $branchBaseVersion.HasBranchOverride) {
    $defaultBranch = Resolve-AlmDefaultBranchName -RepositoryPath $SourceDirectory -DefaultBranchName $DefaultBranchName
    if ($branchBaseVersion.BranchName -cne $defaultBranch) {
        Write-Warning "EXPORT is using buildVersion.default '$($branchBaseVersion.MajorMinor)' on non-default branch '$($branchBaseVersion.BranchName)' (default branch '$defaultBranch'). Configure buildVersion.branches for this branch to select an explicit base version."
    }
}

Invoke-Hook -HookType "preExport" -BaseDirectory $SourceDirectory -Config $solutionsConfig -LogContext:$false -AdditionalContext @{
    SourceDirectory = $SourceDirectory
    ArtifactStagingDirectory = $ArtifactStagingDirectory
    TempDirectory = $TempDirectory
    EnvironmentName = $EnvironmentName
}

$exportPipeline = $null
$exportStatus = 'Failed'
$exportLogDirectory = Join-Path $ArtifactStagingDirectory 'export-logs'
$generatedMappingFiles = [System.Collections.Generic.List[string]]::new()
try {
$mappingEntriesBySolution = @{}
$mappingFilesBySolution = @{}
foreach ($solution in $solutionsConfig.solutions) {
    $solutionName = [string]$solution.name
    $entries = @(Get-SolutionPackagerMappingEntry -Solution $solution)
    $mappingEntriesBySolution[$solutionName] = $entries
    if ($entries.Count -eq 0) { continue }

    $mappingXml = ConvertTo-SolutionPackagerMappingXml `
        -Entries $entries `
        -SourceDirectory $SourceDirectory `
        -SolutionPath (Join-Path $SourceDirectory "solutions/$solutionName") `
        -SolutionName $solutionName `
        -AllowMissingSource
    $mappingFile = Join-Path ([System.IO.Path]::GetTempPath()) "alm4dataverse-mapping-$([guid]::NewGuid().ToString('N')).xml"
    $generatedMappingFiles.Add($mappingFile)
    [System.IO.File]::WriteAllText($mappingFile, $mappingXml, [System.Text.UTF8Encoding]::new($false))
    $mappingFilesBySolution[$solutionName] = $mappingFile
}

$mappedSolutions = @($mappingEntriesBySolution.GetEnumerator() | Where-Object { $_.Value.Count -gt 0 })
if ($mappedSolutions.Count -gt 0) {
    $exportCommandName = if ($exportSettings.parallel) { 'Expand-DataverseSolutionFile' } else { 'Export-DataverseSolution' }
    $exportCommand = Get-Command -Name $exportCommandName -ErrorAction Stop
    $packCommand = Get-Command -Name 'Compress-DataverseSolutionFile' -ErrorAction Stop
    foreach ($command in @($exportCommand, $packCommand)) {
        if ($null -eq $command.Parameters -or -not $command.Parameters.ContainsKey('MappingFile')) {
            throw "Solution mappings in EXPORT require '$($command.Name)' to support -MappingFile. Update scriptDependencies in alm-config.psd1 to a compatible module version."
        }
    }
}

if ($exportSettings.parallel) {
    $exportPipeline = Start-AlmExportPipeline -Config $solutionsConfig -TempDirectory $TempDirectory -MaxParallel $exportSettings.maxParallel
    $exportPipeline.LogDirectory = $exportLogDirectory
    Start-AlmQueuedExport -State $exportPipeline
}
foreach ($solution in $solutionsConfig.solutions) {
    $solutionName = $solution.name
    $exportZipPath = $null
    if ($null -ne $exportPipeline) { $exportZipPath = Wait-AlmSolutionExport -State $exportPipeline -SolutionName $solutionName }

    Write-Host "[$solutionName][Unpack] Started (managed and unmanaged)"

    if (-not (Test-Path "$SourceDirectory/solutions")) {
        New-Item -ItemType Directory -Path "$SourceDirectory/solutions" | Out-Null
    }

    if ((Test-Path $SourceDirectory/solutions/$solutionName)) {
        $mappingFile = $mappingFilesBySolution[$solutionName]
        if (-not [string]::IsNullOrWhiteSpace($mappingFile)) {
            $null = ConvertTo-SolutionPackagerMappingXml `
                -Entries $mappingEntriesBySolution[$solutionName] `
                -SourceDirectory $SourceDirectory `
                -SolutionPath "$SourceDirectory/solutions/$solutionName" `
                -SolutionName $solutionName
            Compress-DataverseSolutionFile -PackageType Managed -OutputPath "$TempDirectory/$solutionName-managed.old.zip" -Path "$SourceDirectory/solutions/$solutionName" -MappingFile $mappingFile
        } else {
            Compress-DataverseSolutionFile -PackageType Managed -OutputPath "$TempDirectory/$solutionName-managed.old.zip" -Path "$SourceDirectory/solutions/$solutionName"
        }
        Remove-Item -Recurse -Force "$SourceDirectory/solutions/$solutionName"
    }

    if ($null -ne $exportPipeline) {
        $mappingFile = $mappingFilesBySolution[$solutionName]
        if ([string]::IsNullOrWhiteSpace($mappingFile)) {
            & { $ProgressPreference = 'SilentlyContinue'; Expand-AlmExportSolution -ZipPath $exportZipPath -OutputPath "$SourceDirectory/solutions/$solutionName" } *>&1 |
                ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { throw $_ }; Format-AlmLogLine -SolutionName $solutionName -Phase Unpack -Text ([string]$_) | ForEach-Object { Write-Host $_ } }
        } else {
            & { $ProgressPreference = 'SilentlyContinue'; Expand-AlmExportSolution -ZipPath $exportZipPath -OutputPath "$SourceDirectory/solutions/$solutionName" -MappingFile $mappingFile } *>&1 |
                ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { throw $_ }; Format-AlmLogLine -SolutionName $solutionName -Phase Unpack -Text ([string]$_) | ForEach-Object { Write-Host $_ } }
        }
    } else {
        $mappingFile = $mappingFilesBySolution[$solutionName]
        if ([string]::IsNullOrWhiteSpace($mappingFile)) {
            & { $ProgressPreference = 'SilentlyContinue'; Export-DataverseSolution -Verbose -SolutionName $solutionName -OutFolder "$SourceDirectory/solutions/$solutionName" -UnpackMsApp } *>&1 |
                ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { throw $_ }; Format-AlmLogLine -SolutionName $solutionName -Phase ExportUnpack -Text ([string]$_) | ForEach-Object { Write-Host $_ } }
        } else {
            & { $ProgressPreference = 'SilentlyContinue'; Export-DataverseSolution -Verbose -SolutionName $solutionName -OutFolder "$SourceDirectory/solutions/$solutionName" -UnpackMsApp -MappingFile $mappingFile } *>&1 |
                ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { throw $_ }; Format-AlmLogLine -SolutionName $solutionName -Phase ExportUnpack -Text ([string]$_) | ForEach-Object { Write-Host $_ } }
        }
    }

    Write-Host "[$solutionName][Unpack] Completed"

    Write-Host "[$solutionName][Compare] Checking for changes"

    # This ensures that when we compare, the file is normalized compared to what we will generate
    # Indentation etc is different in the initial export.
    $solutionXmlPath = "$SourceDirectory/solutions/$solutionName/Other/Solution.xml"
    [xml]$solutionXml = Get-Content -Path $solutionXmlPath
    $solutionXml.Save($solutionXmlPath)

    # Test if anything changed and increment version if so
    $gitStatus = git -C "$SourceDirectory" status --porcelain solutions/$solutionName
    if ([string]::IsNullOrEmpty($gitStatus)) {
        Write-Host "##[debug][$solutionName][Compare] No changes"
    } else {
        Format-AlmLogLine -SolutionName $solutionName -Phase Compare -Text "##[debug]Changes detected`n$gitStatus" | ForEach-Object { Write-Host $_ }

        if ((Test-Path "$TempDirectory/$solutionName-managed.old.zip")) {
            $mappingFile = $mappingFilesBySolution[$solutionName]
            if ([string]::IsNullOrWhiteSpace($mappingFile)) {
                Compress-DataverseSolutionFile -PackageType Managed -OutputPath "$TempDirectory/$solutionName-managed.new.zip" -Path "$SourceDirectory/solutions/$solutionName"
            } else {
                Compress-DataverseSolutionFile -PackageType Managed -OutputPath "$TempDirectory/$solutionName-managed.new.zip" -Path "$SourceDirectory/solutions/$solutionName" -MappingFile $mappingFile
            }

            $changesareadditive = (Compare-DataverseSolutionComponents -FileToFile -SolutionFile "$TempDirectory/$solutionName-managed.new.zip" -TargetSolutionFile "$TempDirectory/$solutionName-managed.old.zip" -TestIfAdditive -Verbose)
            if ($changesareadditive) {
                Write-Host "##[debug][$solutionName][Compare] Changes are additive only."
            } else {
                Write-Host "##[debug][$solutionName][Compare] Changes include non-additive changes."
            }

            Remove-Item -Path "$TempDirectory/$solutionName-managed.old.zip","$TempDirectory/$solutionName-managed.new.zip"
        } else {
            $changesareadditive = $true
        }

        $solutionXmlPath = "$SourceDirectory/solutions/$solutionName/Other/Solution.xml"
        [xml]$solutionXml = Get-Content -Path $solutionXmlPath
        $currentVersion = [version] $solutionXml.ImportExportXml.SolutionManifest.Version

        $baseMatches = $currentVersion.Major -eq $branchBaseVersion.Major -and
            [Math]::Max(0, $currentVersion.Build) -eq $branchBaseVersion.Build
        if ($baseMatches) {
            $versionBeforeIncrement = [version]::new(
                $branchBaseVersion.Major,
                [Math]::Max(0, $currentVersion.Minor),
                $branchBaseVersion.Build,
                [Math]::Max(0, $currentVersion.Revision)
            )
        }
        else {
            Write-Host "##[debug][$solutionName][Version] Resetting solution version to branch base $($branchBaseVersion.Major).$($branchBaseVersion.Build)"
            $versionBeforeIncrement = [version]::new(
                $branchBaseVersion.Major,
                0,
                $branchBaseVersion.Build,
                0
            )
        }

        $newversion = Get-NextAlmSolutionVersion -Version $versionBeforeIncrement -IsAdditive $changesareadditive
        $newversion = Register-AlmSolutionVersion `
            -RepositoryPath $SourceDirectory `
            -SolutionName $solutionName `
            -Version $newversion `
            -IsAdditive $changesareadditive

        $solutionXml.ImportExportXml.SolutionManifest.Version = $newversion.ToString()
        $solutionXml.Save($solutionXmlPath)

        Write-Host "##[debug][$solutionName][Version] Reserved and updated solution folder to $newversion"

        if ($null -ne $exportPipeline) {
            $exportPipeline.OperationBudget.Wait($exportPipeline.Cancellation.Token)
            try { Set-DataverseSolution -UniqueName $solutionName -Version $newversion.ToString() }
            finally { $exportPipeline.OperationBudget.Release() | Out-Null }
        } else { Set-DataverseSolution -UniqueName $solutionName -Version $newversion.ToString() }
        Write-Host "##[debug][$solutionName][Version] Updated environment to $newversion"
    }

    Write-Host "[$solutionName][Compare] Completed"
}

Invoke-Hook -HookType "postExport" -BaseDirectory $SourceDirectory -Config $solutionsConfig -LogContext:$false -AdditionalContext @{
    SourceDirectory = $SourceDirectory
    ArtifactStagingDirectory = $ArtifactStagingDirectory
    TempDirectory = $TempDirectory
    EnvironmentName = $EnvironmentName
}
$exportStatus = 'Succeeded'
} finally {
    foreach ($mappingFile in $generatedMappingFiles) {
        if (Test-Path -LiteralPath $mappingFile) { Remove-Item -LiteralPath $mappingFile -Force }
    }
    if ($null -ne $exportPipeline) { Stop-AlmExportPipeline -State $exportPipeline }
    New-Item -ItemType Directory -Path $exportLogDirectory -Force | Out-Null
    $summary = @(foreach ($solution in $solutionsConfig.solutions) {
        $name = $solution.name
        $timings = @()
        if ($null -ne $exportPipeline) { $timings = @($exportPipeline.Timings | Where-Object SolutionName -eq $name) }
        $row = [pscustomobject]@{
            Solution = $name
            RunStatus = $exportStatus
            PackagesCompleted = $(if ($null -ne $exportPipeline) { $timings.Count } else { $null })
            ExportSpanSeconds = $(if ($timings.Count) { (($timings.Finished | Sort-Object | Select-Object -Last 1) - ($timings.Started | Sort-Object | Select-Object -First 1)).TotalSeconds } else { $null })
        }
        Write-Host "[$name][Summary] Run=$exportStatus; packages=$($row.PackagesCompleted); export span=$($row.ExportSpanSeconds)s"
        $row
    })
    ConvertTo-Json -InputObject $summary -Depth 8 | Set-Content -LiteralPath (Join-Path $exportLogDirectory 'summary.json') -Encoding utf8
    if ($null -ne $exportPipeline) {
        ConvertTo-Json -InputObject $exportPipeline.Timings.ToArray() -Depth 8 | Set-Content -LiteralPath (Join-Path $exportLogDirectory 'timings.json') -Encoding utf8
    }
    if ($env:TF_BUILD) { Write-Host "##vso[artifact.upload containerfolder=export-logs;artifactname=export-logs]$exportLogDirectory" }
    Write-Host "[Export][Summary] Detailed logs: $exportLogDirectory"
}

Write-Host "##[section]Export completed successfully!"
$exportClock.Stop()
if ($PassThru) {
    $workerTimings = @()
    if ($null -ne $exportPipeline) { $workerTimings = $exportPipeline.Timings.ToArray() }
    [pscustomobject]@{ Parallel = $exportSettings.parallel; TotalSeconds = $exportClock.Elapsed.TotalSeconds; WorkerTimings = $workerTimings }
}
