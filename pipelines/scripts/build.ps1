<#
.SYNOPSIS
    Builds the artifacts that can be used to deploy to a Dataverse environment.

.DESCRIPTION
    This script packs the solutions from the source directory into managed and unmanaged
    zip files in the artifact staging directory. It also copies any additional assets
    defined in alm-config.psd1 and creates a lock file for script dependencies.

    Hooks defined in alm-config.psd1 are invoked at various stages of the build process
    to allow for custom pre- and post-build actions.

    Inline mapping buildCommand entries run after preBuild and before packing,
    allowing commands to produce mapped source files before their existence is
    checked. Mapping XML is generated for the pack cmdlet and removed in finally;
    mapped solutions require a cmdlet version supporting MappingFile.
.PARAMETER SourceDirectory
    The root directory containing the solution folders and alm-config.psd1 file.
.PARAMETER ArtifactStagingDirectory
    The directory where the built artifacts will be placed.
.NOTES
    Run installdependencies.ps1 first in this process. Requires PowerShell 7 for
    parallel packing/checks. Checker failures write reports before throwing;
    missing assets or unresolved installed dependency versions also fail the build.
    Artifact contents include deployment scripts, configuration and exact dependency
    versions; this script does not publish or tag the artifact.
.EXAMPLE
    .\pipelines\scripts\build.ps1 -SourceDirectory . -ArtifactStagingDirectory .\artifacts
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$SourceDirectory,

    [Parameter(Mandatory=$true)]
    [string]$ArtifactStagingDirectory
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot 'common.ps1')

Write-Host "##[section]Building Artifacts"

function Get-PacCliInstalledPackageVersion {
    # dotnet's package listing, not pac's display banner, supplies the lock-file version.
    # Missing tools/path or an unmatched listing return ''; strip NuGet build metadata.
    param(
        [Parameter(Mandatory = $true)]
        [string]$PacToolPath
    )

    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $dotnet) {
        return ''
    }

    if (-not (Test-Path $PacToolPath)) {
        return ''
    }

    $toolListOutput = @(& $dotnet.Source tool list --tool-path $PacToolPath 2>&1)
    foreach ($line in $toolListOutput) {
        if ($line -match '^\s*microsoft\.powerapps\.cli\.tool\s+(\S+)\s+') {
            return $Matches[1].Split('+')[0]
        }
    }

    return ''
}

function Get-AlmBuildSetting {
    <#
    .SYNOPSIS
        Returns validated packing settings without mutating Config.
    .DESCRIPTION
        Defaults to parallel=true and maxParallel=2. Null or empty-string entries
        retain defaults; explicit false is honored. Parallel must be Boolean and
        maxParallel an integer from 1 to 8, even when sequential packing is selected.
    #>
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$Config)

    $settings = @{ parallel = $true; maxParallel = 2 }
    if ($Config.ContainsKey('build') -and $null -ne $Config.build) {
        if ($Config.build -isnot [hashtable]) { throw 'build must be a hashtable.' }
        foreach ($name in @('parallel', 'maxParallel')) {
            if ($Config.build.ContainsKey($name)) {
                $value = $Config.build[$name]
                if ($null -ne $value -and -not ($value -is [string] -and $value -eq '')) { $settings[$name] = $value }
            }
        }
    }
    if ($settings.parallel -isnot [bool]) { throw 'build.parallel must be $true or $false.' }
    if ($settings.maxParallel -isnot [int] -or $settings.maxParallel -lt 1 -or $settings.maxParallel -gt 8) {
        throw 'build.maxParallel must be an integer between 1 and 8.'
    }
    return $settings
}

function Get-SolutionBuildCommandPlan {
    <#
    .SYNOPSIS
        Validates mapping build commands and emits their ordered execution plans.
    .DESCRIPTION
        MappingPlans supplies SolutionIndex, SolutionName and normalized Entries.
        Entries without BuildCommand are skipped. Commands require a nonblank
        executable; arguments must be a string array and parallel a Boolean
        (default true). WorkingDirectory defaults to SourceDirectory or resolves
        a relative override to an existing directory; this is not a containment
        check against '..'. Invalid command configuration throws before execution.
        Plans retain solution/mapping indexes, display name, executable, arguments,
        working directory and Parallel. GroupIndex changes when the next actual
        command's parallel flag changes, so sequential runs form ordering barriers.
    #>
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][array]$MappingPlans,
        [Parameter(Mandatory)][string]$SourceDirectory
    )

    $plans = [System.Collections.Generic.List[object]]::new()
    $groupIndex = -1
    $previousParallel = $null
    foreach ($mappingPlan in $MappingPlans) {
        for ($mappingIndex = 0; $mappingIndex -lt $mappingPlan.Entries.Count; $mappingIndex++) {
            $command = $mappingPlan.Entries[$mappingIndex].BuildCommand
            if ($null -eq $command) {
                continue
            }
            if (-not $command.ContainsKey('executable') -or $command.executable -isnot [string] -or [string]::IsNullOrWhiteSpace($command.executable)) {
                throw "buildCommand for mapping $($mappingIndex + 1) in solution '$($mappingPlan.SolutionName)' must have a non-empty executable string."
            }

            $arguments = @()
            if ($command.ContainsKey('arguments') -and $null -ne $command.arguments) {
                if ($command.arguments -isnot [array] -or @($command.arguments | Where-Object { $_ -isnot [string] }).Count -gt 0) {
                    throw "buildCommand arguments for mapping $($mappingIndex + 1) in solution '$($mappingPlan.SolutionName)' must be an array of strings."
                }
                $arguments = @($command.arguments)
            }

            $parallel = $true
            if ($command.ContainsKey('parallel') -and $null -ne $command.parallel) {
                $parallel = $command.parallel
            }
            if ($parallel -isnot [bool]) {
                throw "buildCommand parallel for mapping $($mappingIndex + 1) in solution '$($mappingPlan.SolutionName)' must be `$true or `$false."
            }
            if ($null -eq $previousParallel -or $previousParallel -ne $parallel) {
                $groupIndex++
                $previousParallel = $parallel
            }

            $workingDirectory = $SourceDirectory
            if ($command.ContainsKey('workingDirectory') -and $null -ne $command.workingDirectory) {
                if ($command.workingDirectory -isnot [string]) {
                    throw "buildCommand workingDirectory for mapping $($mappingIndex + 1) in solution '$($mappingPlan.SolutionName)' must be a relative path string."
                }
                if (-not [string]::IsNullOrWhiteSpace($command.workingDirectory)) {
                    if ([System.IO.Path]::IsPathRooted($command.workingDirectory)) {
                        throw "buildCommand workingDirectory for mapping $($mappingIndex + 1) in solution '$($mappingPlan.SolutionName)' must be relative to the repository root."
                    }
                    $workingDirectory = [System.IO.Path]::GetFullPath((Join-Path $SourceDirectory $command.workingDirectory))
                }
            }
            if (-not (Test-Path -LiteralPath $workingDirectory -PathType Container)) {
                throw "buildCommand workingDirectory for mapping $($mappingIndex + 1) in solution '$($mappingPlan.SolutionName)' was not found: $workingDirectory"
            }

            $commandName = "mapping $($mappingIndex + 1)"
            if ($command.ContainsKey('name') -and $command.name -is [string] -and -not [string]::IsNullOrWhiteSpace($command.name)) {
                $commandName = $command.name
            }
            $plans.Add([pscustomobject]@{
                SolutionIndex    = $mappingPlan.SolutionIndex
                SolutionName     = $mappingPlan.SolutionName
                CommandIndex     = $mappingIndex
                CommandName      = $commandName
                Executable       = $command.executable
                Arguments        = [string[]]$arguments
                WorkingDirectory = $workingDirectory
                Parallel         = $parallel
                GroupIndex       = $groupIndex
            })
        }
    }
    return $plans.ToArray()
}

function Invoke-SolutionBuildCommand {
    <#
    .SYNOPSIS
        Runs one planned build command and returns captured output and error text.
    .DESCRIPTION
        Uses the plan's working directory, restoring the prior location in finally.
        Captures stdout/stderr as strings and reports invocation exceptions or a
        nonzero LASTEXITCODE through ErrorMessage rather than throwing from the
        command body; null LASTEXITCODE is treated as zero. Location-entry failures
        can still throw. Returns SolutionName, CommandName, Output and ErrorMessage
        for the caller's grouped logging/failure gate; no command effects roll back.
    #>
    param([Parameter(Mandatory)][pscustomobject]$Plan)

    $output = @()
    $errorMessage = ''
    $exitCode = 0
    Push-Location -LiteralPath $Plan.WorkingDirectory
    try {
        $arguments = [string[]]$Plan.Arguments
        $output = @(& $Plan.Executable @arguments 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
        if ($null -eq $exitCode) { $exitCode = 0 }
        if ($exitCode -ne 0) {
            $errorMessage = "Command exited with code $exitCode."
        }
    }
    catch {
        $errorMessage = ($_ | Out-String).TrimEnd()
    }
    finally {
        Pop-Location
    }

    return [pscustomobject]@{
        SolutionName = $Plan.SolutionName
        CommandName  = $Plan.CommandName
        Output       = $output
        ErrorMessage = $errorMessage
    }
}

function New-SolutionCheckSeverityCount {
    return [ordered]@{
        Critical      = 0
        High          = 0
        Medium        = 0
        Low           = 0
        Informational = 0
    }
}

function Convert-SolutionCheckSeverityToRank {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Severity
    )

    switch ($Severity.Trim().ToLowerInvariant()) {
        'critical'      { return 5 }
        'high'          { return 4 }
        'medium'        { return 3 }
        'low'           { return 2 }
        'informational' { return 1 }
        default         { throw "Unknown solution check severity '$Severity'. Supported values: Critical, High, Medium, Low, Informational." }
    }
}

function Convert-SolutionCheckRankToSeverity {
    # Unknown ranks represent no findings; unlike severity-to-rank, this does not throw.
    param(
        [Parameter(Mandatory = $true)]
        [int]$Rank
    )

    switch ($Rank) {
        5 { return 'Critical' }
        4 { return 'High' }
        3 { return 'Medium' }
        2 { return 'Low' }
        1 { return 'Informational' }
        default { return 'None' }
    }
}

function Get-SolutionCheckHighestSeverity {
    # Missing or zero counts do not count as findings; return the 'None' sentinel.
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$SeverityCounts
    )

    foreach ($severity in @('Critical', 'High', 'Medium', 'Low', 'Informational')) {
        if ($SeverityCounts[$severity] -gt 0) {
            return $severity
        }
    }

    return 'None'
}

function ConvertFrom-SolutionCheckSeverityText {
    # Parse PAC's textual summaries, not SARIF: repeated "Severity[:=] count" entries
    # accumulate, and unmatched categories remain zero. Keep the worker parser aligned.
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConsoleText
    )

    $counts = New-SolutionCheckSeverityCount

    foreach ($severity in @('Critical', 'High', 'Medium', 'Low', 'Informational')) {
        $escaped = [regex]::Escape($severity)
        $severityMatches = [regex]::Matches($ConsoleText, "(?im)\b$escaped\b(?:\s+issues?)?\s*[:=]\s*(\d+)\b")
        foreach ($match in $severityMatches) {
            $counts[$severity] += [int]$match.Groups[1].Value
        }
    }

    return $counts
}

function Resolve-SolutionCheckExcludedFile {
    <#
    .SYNOPSIS
        Expands exclusion patterns to unique absolute file paths for PAC.
    .DESCRIPTION
        Relative patterns resolve under solutions/SolutionName; rooted patterns
        remain rooted. Null/blank entries are ignored and unmatched entries warn
        rather than failing the check. Patterns may match recursively.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceDirectory,

        [Parameter(Mandatory = $true)]
        [string]$SolutionName,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [array]$Patterns
    )

    $solutionRoot = Join-Path $SourceDirectory "solutions/$SolutionName"
    $resolvedFiles = New-Object System.Collections.Generic.List[string]

    foreach ($pattern in $Patterns) {
        if ($null -eq $pattern) {
            continue
        }

        $patternText = [string]$pattern
        if ([string]::IsNullOrWhiteSpace($patternText)) {
            continue
        }

        $patternText = $patternText.Trim()
        $searchPath = if ([System.IO.Path]::IsPathRooted($patternText)) {
            $patternText
        }
        else {
            Join-Path $solutionRoot $patternText
        }

        $matchedFiles = @(Get-ChildItem -Path $searchPath -File -Recurse -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        if ($matchedFiles.Count -eq 0 -and (Test-Path $searchPath -PathType Leaf)) {
            $matchedFiles = @((Resolve-Path $searchPath | Select-Object -ExpandProperty Path))
        }

        if ($matchedFiles.Count -eq 0) {
            Write-Host "##[warning]No files matched excludedFiles pattern '$patternText' for solution '$SolutionName'."
            continue
        }

        foreach ($match in $matchedFiles) {
            if (-not $resolvedFiles.Contains($match)) {
                $resolvedFiles.Add($match)
            }
        }
    }

    return @($resolvedFiles.ToArray())
}

function ConvertTo-SolutionCheckRuleOverrideFile {
    <#
    .SYNOPSIS
        Resolves an override path or writes structured overrides as JSON.
    .DESCRIPTION
        Null/blank returns ''; a nonblank string is passed through without path
        validation. Hashtable/array inputs overwrite a solution-named JSON file in
        the existing ReportRoot and return its path. Other types throw.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ReportRoot,

        [Parameter(Mandatory = $true)]
        [string]$SolutionName,

        $RuleLevelOverride
    )

    if ($null -eq $RuleLevelOverride) {
        return ''
    }

    if ($RuleLevelOverride -is [string]) {
        $candidate = [string]$RuleLevelOverride
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            return ''
        }

        return $candidate
    }

    $safeSolutionName = $SolutionName -replace '[^a-zA-Z0-9._-]', '_'
    $overridePath = Join-Path $ReportRoot "$safeSolutionName-ruleLevelOverride.json"

    if ($RuleLevelOverride -is [hashtable]) {
        @($RuleLevelOverride) | ConvertTo-Json -Depth 20 | Out-File -FilePath $overridePath -Encoding UTF8
        return $overridePath
    }

    if ($RuleLevelOverride -is [array]) {
        @($RuleLevelOverride) | ConvertTo-Json -Depth 20 | Out-File -FilePath $overridePath -Encoding UTF8
        return $overridePath
    }

    throw "solutionCheck.ruleLevelOverride for solution '$SolutionName' must be a JSON file path string, hashtable, or array."
}

function Write-SolutionCheckSummary {
    <#
    .SYNOPSIS
        Writes Markdown/JSON checker results and publishes available CI summaries.
    .DESCRIPTION
        Results require SolutionName, Error, ThresholdBreached, FailThreshold,
        HighestSeverity and SeverityCounts. Overwrites both requested files, appends
        Markdown to GITHUB_STEP_SUMMARY when set and emits an Azure summary attachment.
        Error takes display precedence over threshold failure.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [array]$Results,

        [Parameter(Mandatory = $true)]
        [string]$SummaryPath,

        [Parameter(Mandatory = $true)]
        [string]$SummaryJsonPath
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# Solution Check Summary')
    $lines.Add('')
    $lines.Add('| Solution | Status | Threshold | Highest | Critical | High | Medium | Low | Informational |')
    $lines.Add('|---|---:|---:|---:|---:|---:|---:|---:|---:|')

    foreach ($result in $Results) {
        $status = if ($result.Error) {
            'Error'
        }
        elseif ($result.ThresholdBreached) {
            'Failed'
        }
        else {
            'Passed'
        }

        $lines.Add("| $($result.SolutionName) | $status | $($result.FailThreshold) | $($result.HighestSeverity) | $($result.SeverityCounts.Critical) | $($result.SeverityCounts.High) | $($result.SeverityCounts.Medium) | $($result.SeverityCounts.Low) | $($result.SeverityCounts.Informational) |")
    }

    $lines.Add('')
    $summaryText = $lines -join "`r`n"
    $summaryText | Out-File -FilePath $SummaryPath -Encoding UTF8

    $jsonSummary = @{
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        results = $Results
    }
    $jsonSummary | ConvertTo-Json -Depth 30 | Out-File -FilePath $SummaryJsonPath -Encoding UTF8

    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
        $summaryText | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
    }

    if (-not [string]::IsNullOrWhiteSpace($env:TF_BUILD)) {
        Write-Host "##vso[task.addattachment type=Distributedtask.Core.Summary;name=Solution Check Summary;]$SummaryPath"
    }
}

function Invoke-SolutionCheck {
    <#
    .SYNOPSIS
        Checks enabled packed solutions and fails after collecting their reports.
    .DESCRIPTION
        Merges global and per-solution settings with Merge-AlmConfigValue. Uses
        global maxParallel (default 4, clamped to at least 1), not packing limits.
        Disabled solutions are skipped. Worker exceptions/nonzero PAC exits fail,
        as do findings at or above failThreshold (default Critical). Reports live
        under ArtifactStagingDirectory/solution-check; no result objects are returned.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [string]$SourceDirectory,

        [Parameter(Mandatory = $true)]
        [string]$ArtifactStagingDirectory
    )

    $globalSolutionCheck = @{}
    if ($Config.solutionCheck -is [hashtable]) {
        $globalSolutionCheck = $Config.solutionCheck
    }

    $solutionCheckEnabled = $false
    foreach ($solution in $Config.solutions) {
        $solutionLevel = if ($solution.ContainsKey('solutionCheck') -and $solution.solutionCheck -is [hashtable]) { $solution.solutionCheck } else { @{} }
        $merged = Merge-AlmConfigValue -DefaultValue $globalSolutionCheck -OverrideValue $solutionLevel
        if ($merged -is [hashtable] -and $merged.ContainsKey('enabled') -and [bool]$merged.enabled) {
            $solutionCheckEnabled = $true
            break
        }
    }

    if (-not $solutionCheckEnabled) {
        Write-Host "##[section]Solution check skipped (solutionCheck.enabled is false for all solutions)."
        return
    }

    $solutionCheckRoot = Join-Path $ArtifactStagingDirectory 'solution-check'
    if (-not (Test-Path $solutionCheckRoot)) {
        New-Item -ItemType Directory -Path $solutionCheckRoot -Force | Out-Null
    }

    $maxParallel = 4
    if ($globalSolutionCheck.ContainsKey('maxParallel') -and $null -ne $globalSolutionCheck.maxParallel) {
        $maxParallel = [int]$globalSolutionCheck.maxParallel
    }
    if ($maxParallel -lt 1) {
        $maxParallel = 1
    }

    $plans = New-Object System.Collections.Generic.List[object]
    foreach ($solution in $Config.solutions) {
        $solutionName = [string]$solution.name
        $solutionLevel = if ($solution.ContainsKey('solutionCheck') -and $solution.solutionCheck -is [hashtable]) { $solution.solutionCheck } else { @{} }
        $settings = Merge-AlmConfigValue -DefaultValue $globalSolutionCheck -OverrideValue $solutionLevel
        if (-not ($settings -is [hashtable])) {
            continue
        }

        $enabled = $settings.ContainsKey('enabled') -and [bool]$settings.enabled
        if (-not $enabled) {
            continue
        }

        $geo = if ($settings.ContainsKey('geo') -and -not [string]::IsNullOrWhiteSpace([string]$settings.geo)) {
            [string]$settings.geo
        }
        else {
            'Europe'
        }

        $ruleSetRaw = if ($settings.ContainsKey('ruleSet')) { [string]$settings.ruleSet } else { '' }
        $ruleSetValue = if ([string]::IsNullOrWhiteSpace($ruleSetRaw) -or $ruleSetRaw.Trim().ToLowerInvariant() -eq 'none') {
            ''
        }
        else {
            $ruleSetRaw.Trim()
        }

        $failThreshold = if ($settings.ContainsKey('failThreshold') -and -not [string]::IsNullOrWhiteSpace([string]$settings.failThreshold)) {
            [string]$settings.failThreshold
        }
        else {
            'Critical'
        }

        $excludedFilesRaw = @()
        if ($settings.ContainsKey('excludedFiles') -and $null -ne $settings.excludedFiles) {
            if ($settings.excludedFiles -is [string]) {
                $excludedFilesRaw = @([string]$settings.excludedFiles)
            }
            elseif ($settings.excludedFiles -is [array]) {
                $excludedFilesRaw = @($settings.excludedFiles)
            }
            else {
                throw "solutionCheck.excludedFiles for solution '$solutionName' must be a string or array of strings."
            }
        }

        $resolvedExcludedFiles = @()
        if (@($excludedFilesRaw).Count -gt 0) {
            $resolvedExcludedFiles = Resolve-SolutionCheckExcludedFile -SourceDirectory $SourceDirectory -SolutionName $solutionName -Patterns $excludedFilesRaw
        }
        $ruleOverrideFile = ConvertTo-SolutionCheckRuleOverrideFile -ReportRoot $solutionCheckRoot -SolutionName $solutionName -RuleLevelOverride $settings.ruleLevelOverride

        $plans.Add([pscustomobject]@{
            SolutionName   = $solutionName
            SolutionZip    = Join-Path $ArtifactStagingDirectory "solutions/$solutionName.zip"
            Geo            = $geo
            RuleSet        = $ruleSetValue
            ExcludedFiles  = @($resolvedExcludedFiles)
            RuleLevelFile  = $ruleOverrideFile
            FailThreshold  = $failThreshold
            ReportRoot     = $solutionCheckRoot
        })
    }

    if ($plans.Count -eq 0) {
        Write-Host "##[section]Solution check skipped (no enabled solutions)."
        return
    }

    Write-Host "##[section]Running PAC solution checks for $($plans.Count) solution(s) with max parallelism $maxParallel"

    # Parallel runspaces do not inherit these helper definitions. Keep the local
    # count/parser/highest helpers self-contained and equivalent to the outer helpers.
    $results = @($plans | ForEach-Object -ThrottleLimit $maxParallel -Parallel {
        $plan = $_
        $ErrorActionPreference = 'Stop'

        function New-Count {
            return [ordered]@{ Critical = 0; High = 0; Medium = 0; Low = 0; Informational = 0 }
        }

        function ConvertFrom-CountText {
            param([string]$Text)

            $counts = New-Count
            foreach ($severity in @('Critical', 'High', 'Medium', 'Low', 'Informational')) {
                $escaped = [regex]::Escape($severity)
                $severityMatches = [regex]::Matches($Text, "(?im)\b$escaped\b(?:\s+issues?)?\s*[:=]\s*(\d+)\b")
                foreach ($match in $severityMatches) {
                    $counts[$severity] += [int]$match.Groups[1].Value
                }
            }
            return $counts
        }

        function Get-Highest {
            param([hashtable]$Counts)
            foreach ($severity in @('Critical', 'High', 'Medium', 'Low', 'Informational')) {
                if ($Counts[$severity] -gt 0) { return $severity }
            }
            return 'None'
        }

        $safeName = $plan.SolutionName -replace '[^a-zA-Z0-9._-]', '_'
        $reportDirectory = Join-Path $plan.ReportRoot $safeName
        if (-not (Test-Path $reportDirectory)) {
            New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null
        }

        try {
            if (-not (Test-Path $plan.SolutionZip)) {
                throw "Packed solution zip not found: $($plan.SolutionZip)"
            }

            $pac = Get-Command pac -ErrorAction SilentlyContinue
            if (-not $pac) {
                throw 'Power Apps CLI (pac) was not found on PATH.'
            }

            $pacArgs = @('solution', 'check', '--path', $plan.SolutionZip, '--outputDirectory', $reportDirectory, '--geo', $plan.Geo)

            if (-not [string]::IsNullOrWhiteSpace($plan.RuleSet)) {
                $pacArgs += @('--ruleSet', $plan.RuleSet)
            }

            if ($plan.ExcludedFiles -and $plan.ExcludedFiles.Count -gt 0) {
                $pacArgs += @('--excludedFiles', ($plan.ExcludedFiles -join ','))
            }

            if (-not [string]::IsNullOrWhiteSpace($plan.RuleLevelFile)) {
                $pacArgs += @('--ruleLevelOverride', $plan.RuleLevelFile)
            }

            $output = @(& $pac.Source @pacArgs 2>&1)
            $exitCode = $LASTEXITCODE
            $outputText = ($output | ForEach-Object { [string]$_ }) -join "`r`n"
            $outputText | Out-File -FilePath (Join-Path $reportDirectory 'pac-solution-check.log') -Encoding UTF8

            $counts = ConvertFrom-CountText -Text $outputText
            $highest = Get-Highest -Counts $counts

            return [pscustomobject]@{
                SolutionName      = $plan.SolutionName
                ExitCode          = $exitCode
                Error             = $exitCode -ne 0
                ErrorMessage      = if ($exitCode -ne 0) { "PAC exited with code $exitCode" } else { '' }
                ReportDirectory   = $reportDirectory
                SeverityCounts    = $counts
                HighestSeverity   = $highest
                FailThreshold     = $plan.FailThreshold
                ThresholdBreached = $false
            }
        }
        catch {
            $message = $_.Exception.Message
            $message | Out-File -FilePath (Join-Path $reportDirectory 'pac-solution-check.error.log') -Encoding UTF8

            return [pscustomobject]@{
                SolutionName      = $plan.SolutionName
                ExitCode          = -1
                Error             = $true
                ErrorMessage      = $message
                ReportDirectory   = $reportDirectory
                SeverityCounts    = (New-Count)
                HighestSeverity   = 'None'
                FailThreshold     = $plan.FailThreshold
                ThresholdBreached = $false
            }
        }
    })

    # Workers return failures as data so all per-solution logs and the aggregate
    # summary survive a failed check instead of aborting at the first PAC error.
    $hasFailures = $false
    foreach ($result in $results) {
        if ($result.Error) {
            $hasFailures = $true
            continue
        }

        $highestRank = if ($result.HighestSeverity -eq 'None') { 0 } else { Convert-SolutionCheckSeverityToRank -Severity $result.HighestSeverity }
        $thresholdRank = Convert-SolutionCheckSeverityToRank -Severity $result.FailThreshold

        if ($highestRank -ge $thresholdRank -and $highestRank -gt 0) {
            $result.ThresholdBreached = $true
            $hasFailures = $true
        }
    }

    $summaryMarkdownPath = Join-Path $solutionCheckRoot 'summary.md'
    $summaryJsonPath = Join-Path $solutionCheckRoot 'solution-check-summary.json'
    Write-SolutionCheckSummary -Results $results -SummaryPath $summaryMarkdownPath -SummaryJsonPath $summaryJsonPath

    foreach ($result in $results) {
        if ($result.Error) {
            Write-Host "##[error]Solution check failed for '$($result.SolutionName)': $($result.ErrorMessage)"
            if (-not [string]::IsNullOrWhiteSpace($env:TF_BUILD)) {
                Write-Host "##vso[task.logissue type=error]Solution check failed for '$($result.SolutionName)': $($result.ErrorMessage)"
            }
            continue
        }

        if ($result.ThresholdBreached) {
            $message = "Solution '$($result.SolutionName)' exceeded threshold '$($result.FailThreshold)' with highest severity '$($result.HighestSeverity)'."
            Write-Host "##[error]$message"
            if (-not [string]::IsNullOrWhiteSpace($env:TF_BUILD)) {
                Write-Host "##vso[task.logissue type=error]$message"
            }
        }
        else {
            Write-Host "##[section]Solution '$($result.SolutionName)' passed solution check (highest severity: $($result.HighestSeverity), threshold: $($result.FailThreshold))."
        }
    }

    if ($hasFailures) {
        throw "One or more solution checks failed. See '$summaryMarkdownPath' and the per-solution logs under '$solutionCheckRoot'."
    }
}

# Read solutions configuration
$config = Get-AlmConfig -BaseDirectory $SourceDirectory
$buildSettings = Get-AlmBuildSetting -Config $config
$solutionNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($solution in $config.solutions) {
    if (-not $solutionNames.Add([string]$solution.name)) {
        throw "Duplicate solution in build configuration: $($solution.name)"
    }
}
Write-Host "##[debug]Loaded configuration from alm-config.psd1"

Invoke-Hook -HookType "preBuild" -BaseDirectory $SourceDirectory -Config $config -AdditionalContext @{
    SourceDirectory = $SourceDirectory
    ArtifactStagingDirectory = $ArtifactStagingDirectory
}

# Resolve the command first to trigger module autoload before capturing its path
# for isolated packing runspaces and checking optional MappingFile support.
$packCommand = Get-Command -Name 'Compress-DataverseSolutionFile' -ErrorAction Stop
$packModule = Get-Module -Name 'Rnwood.Dataverse.Data.PowerShell' | Select-Object -First 1
if ($null -eq $packModule) {
    Write-Host "##[error]Module Rnwood.Dataverse.Data.PowerShell not found in loaded modules."
    throw "Module Rnwood.Dataverse.Data.PowerShell not found in loaded modules."
}
$mappingPlans = @(
    for ($index = 0; $index -lt $config.solutions.Count; $index++) {
        [pscustomobject]@{
            SolutionIndex = $index
            SolutionName = [string]$config.solutions[$index].name
            Entries      = @(Get-SolutionPackagerMappingEntry -Solution $config.solutions[$index])
        }
    }
)
$packSupportsMappingFile = $null -ne $packCommand.PSObject.Properties['Parameters'] -and $packCommand.Parameters.ContainsKey('MappingFile')
$mappedSolutions = @($mappingPlans | Where-Object { $_.Entries.Count -gt 0 })
if ($mappedSolutions.Count -gt 0 -and -not $packSupportsMappingFile) {
    throw "Solution mappings require a version of Rnwood.Dataverse.Data.PowerShell that supports -MappingFile. Update scriptDependencies in alm-config.psd1 to the compatible module version."
}

$buildCommandPlans = @(Get-SolutionBuildCommandPlan -MappingPlans $mappingPlans -SourceDirectory $SourceDirectory)
if ($buildCommandPlans.Count -gt 0) {
    # Consecutive flag groups, rather than a global parallel/sequential partition,
    # preserve barriers in mapping order across solutions. Global sequential mode
    # overrides per-command parallel opt-in without moving commands between groups.
    $lastGroupIndex = ($buildCommandPlans | Measure-Object -Property GroupIndex -Maximum).Maximum
    for ($groupIndex = 0; $groupIndex -le $lastGroupIndex; $groupIndex++) {
        $groupPlans = @($buildCommandPlans | Where-Object { $_.GroupIndex -eq $groupIndex } | Sort-Object SolutionIndex, CommandIndex)
        $parallelPlans = @($groupPlans | Where-Object { $_.Parallel })
        $sequentialPlans = @($groupPlans | Where-Object { -not $_.Parallel })
        $groupResults = @()

        if (-not $buildSettings.parallel) {
            $parallelPlans = @()
            $sequentialPlans = $groupPlans
        }

        if ($parallelPlans.Count -gt 0) {
            Write-Host "##[section]Running $($parallelPlans.Count) parallel build command(s) with max parallelism $($buildSettings.maxParallel)"
            if ($parallelPlans.Count -eq 1) {
                $groupResults += Invoke-SolutionBuildCommand -Plan $parallelPlans[0]
            }
            else {
                # Parallel runspaces cannot call the local helper directly. Keep this
                # capture/exit-code/location-restoration path aligned with it; wait for
                # the group before replaying ordered logs or aborting later groups.
                $groupResults += @($parallelPlans | ForEach-Object -ThrottleLimit $buildSettings.maxParallel -Parallel {
                    $plan = $_
                    $ErrorActionPreference = 'Stop'
                    $output = @()
                    $errorMessage = ''
                    $exitCode = 0
                    Push-Location -LiteralPath $plan.WorkingDirectory
                    try {
                        $arguments = [string[]]$plan.Arguments
                        $output = @(& $plan.Executable @arguments 2>&1 | ForEach-Object { [string]$_ })
                        $exitCode = $LASTEXITCODE
                        if ($null -eq $exitCode) { $exitCode = 0 }
                        if ($exitCode -ne 0) {
                            $errorMessage = "Command exited with code $exitCode."
                        }
                    }
                    catch {
                        $errorMessage = ($_ | Out-String).TrimEnd()
                    }
                    finally {
                        Pop-Location
                    }
                    [pscustomobject]@{
                        SolutionIndex = $plan.SolutionIndex
                        CommandIndex  = $plan.CommandIndex
                        SolutionName  = $plan.SolutionName
                        CommandName   = $plan.CommandName
                        Output        = $output
                        ErrorMessage  = $errorMessage
                    }
                } | Sort-Object SolutionIndex, CommandIndex)
            }
        }

        foreach ($plan in $sequentialPlans) {
            $groupResults += Invoke-SolutionBuildCommand -Plan $plan
        }

        foreach ($result in $groupResults) {
            Write-Host "##[group]Build command: $($result.SolutionName) / $($result.CommandName)"
            foreach ($line in $result.Output) {
                Write-Host "[$($result.SolutionName)][Build:$($result.CommandName)] $line"
            }
            if (-not [string]::IsNullOrWhiteSpace($result.ErrorMessage)) {
                Write-Host "##[error][$($result.SolutionName)][Build:$($result.CommandName)] $($result.ErrorMessage)"
                Write-Host "##[endgroup]"
                throw "Build command '$($result.CommandName)' failed for solution '$($result.SolutionName)': $($result.ErrorMessage)"
            }
            Write-Host "##[endgroup]"
        }
    }
}

$generatedMappingFiles = [System.Collections.Generic.List[string]]::new()
try {
    # Commands have finished producing mapped sources before XML validation. Keep the
    # generated files alive until all pack workers finish; they pass paths, not XML text.
    $packPlans = @(
    for ($index = 0; $index -lt $config.solutions.Count; $index++) {
        $solutionName = [string]$config.solutions[$index].name
        $solutionPath = Join-Path $SourceDirectory "solutions/$solutionName"
        $mappingFile = ''
        $mappingEntries = $mappingPlans[$index].Entries
        if ($mappingEntries.Count -gt 0) {
            $mappingXml = ConvertTo-SolutionPackagerMappingXml `
                -Entries $mappingEntries `
                -SourceDirectory $SourceDirectory `
                -SolutionPath $solutionPath `
                -SolutionName $solutionName
            $mappingFile = Join-Path ([System.IO.Path]::GetTempPath()) "alm4dataverse-mapping-$([guid]::NewGuid().ToString('N')).xml"
            $generatedMappingFiles.Add($mappingFile)
            [System.IO.File]::WriteAllText($mappingFile, $mappingXml, [System.Text.UTF8Encoding]::new($false))
        }
        [pscustomobject]@{
            Index        = $index
            SolutionName = $solutionName
            Path         = $solutionPath
            OutputPath   = Join-Path $ArtifactStagingDirectory "solutions/$solutionName.zip"
            MappingFile  = $mappingFile
        }
    }
)

if ($buildSettings.parallel) {
    $buildModulePath = if ($packModule.PSObject.Properties['Path']) { [string]$packModule.Path } else { '' }
    foreach ($plan in $packPlans) {
        $plan | Add-Member -NotePropertyName ModulePath -NotePropertyValue $buildModulePath
    }
    Write-Host "##[section]Packing $($packPlans.Count) solution(s) with max parallelism $($buildSettings.maxParallel)"
    # Capture each worker's streams as data, then replay in configuration order;
    # parallel completion order must not interleave solution log groups.
    $packResults = @($packPlans | ForEach-Object -ThrottleLimit $buildSettings.maxParallel -Parallel {
        $plan = $_
        $ErrorActionPreference = 'Stop'
        try {
            if (-not [string]::IsNullOrWhiteSpace($plan.ModulePath)) {
                Import-Module -Name $plan.ModulePath -ErrorAction Stop
            }
            $output = @(
                & {
                    if ([string]::IsNullOrWhiteSpace($plan.MappingFile)) {
                        Compress-DataverseSolutionFile -Verbose `
                            -Path $plan.Path `
                            -OutputPath $plan.OutputPath `
                            -PackageType Both
                    }
                    else {
                        Compress-DataverseSolutionFile -Verbose `
                            -Path $plan.Path `
                            -OutputPath $plan.OutputPath `
                            -PackageType Both `
                            -MappingFile $plan.MappingFile
                    }
                } *>&1 | ForEach-Object { [string]$_ }
            )
            [pscustomobject]@{
                Index        = $plan.Index
                SolutionName = $plan.SolutionName
                Output       = $output
                ErrorMessage = ''
            }
        }
        catch {
            [pscustomobject]@{
                Index        = $plan.Index
                SolutionName = $plan.SolutionName
                Output       = @()
                ErrorMessage = ($_ | Out-String).TrimEnd()
            }
        }
    } | Sort-Object Index)

    foreach ($result in $packResults) {
        Write-Host "##[group]Building solution: $($result.SolutionName)"
        foreach ($line in $result.Output) {
            Write-Host "[$($result.SolutionName)][Pack] $line"
        }
        if (-not [string]::IsNullOrWhiteSpace($result.ErrorMessage)) {
            Write-Host "##[error][$($result.SolutionName)][Pack] $($result.ErrorMessage)"
            Write-Host "##[endgroup]"
            throw "Failed to pack solution '$($result.SolutionName)': $($result.ErrorMessage)"
        }
        Write-Host "##[endgroup]"
    }
}
else {
    Write-Host "##[section]Packing $($packPlans.Count) solution(s) sequentially"
    foreach ($plan in $packPlans) {
        Write-Host "##[group]Building solution: $($plan.SolutionName)"
        Write-Host "Packing solution: $($plan.SolutionName) (Managed)"
        if ([string]::IsNullOrWhiteSpace($plan.MappingFile)) {
            Compress-DataverseSolutionFile -Verbose `
                -Path $plan.Path `
                -OutputPath $plan.OutputPath `
                -PackageType Both
        }
        else {
            Compress-DataverseSolutionFile -Verbose `
                -Path $plan.Path `
                -OutputPath $plan.OutputPath `
                -PackageType Both `
                -MappingFile $plan.MappingFile
        }
        Write-Host "##[endgroup]"
    }
}
}
finally {
    # Mapping files are build scratch, not deployment assets, even on packing failure.
    foreach ($mappingFile in $generatedMappingFiles) {
        if (Test-Path -LiteralPath $mappingFile) {
            Remove-Item -LiteralPath $mappingFile -Force
        }
    }
}

Invoke-SolutionCheck -Config $config -SourceDirectory $SourceDirectory -ArtifactStagingDirectory $ArtifactStagingDirectory

if ($config.ContainsKey('assets') -and $config.assets -and $config.assets.Count -gt 0) {
    Write-Host "##[group]Copying extra asset files"
    foreach ($asset in $config.assets) {
        $sourcePath = Join-Path $SourceDirectory $asset
        $destinationPath = Join-Path $ArtifactStagingDirectory $asset

        if (Test-Path $sourcePath) {
            Write-Host "Copying asset: $asset"
            Copy-Item $sourcePath -Destination $destinationPath -Recurse -Force -Verbose
        } else {
            write-Host "##[error]Asset path not found: $sourcePath"
            throw "Asset path not found: $sourcePath"
        }
    }
    Write-Host "##[endgroup]"
}

Write-Host "##[group]Copying deployment scripts"
Copy-Item $PSScriptRoot/../.. -Destination "$ArtifactStagingDirectory/alm" -Recurse -Force -Verbose
Copy-Item (Join-Path $SourceDirectory 'alm-config.psd1') -Destination (Join-Path $ArtifactStagingDirectory 'alm-config.psd1') -Force -Verbose

# Pin what this process actually loaded/installed, not the requested floating
# selectors, so deployments can reproduce the build's dependency selection.
$lockConfig = @{
    scriptDependencies = $config.scriptDependencies.Clone()
    pacCliVersion = [string]$config.pacCliVersion
}
foreach ($moduleName in ([string[]] $lockConfig.scriptDependencies.Keys)) {
    $module = Get-Module -Name $moduleName
    if ($module) {
        $version = $module.Version.ToString()
        if ($module.PrivateData -and $module.PrivateData.PSData -and $module.PrivateData.PSData.Prerelease) {
            $version += "-$($module.PrivateData.PSData.Prerelease)"
        }
        $lockConfig.scriptDependencies[$moduleName] = $version
    } else {
        write-Host "##[error]Module $moduleName not found in loaded modules."
        throw "Module $moduleName not found in loaded modules."
    }
}

$pacToolPath = Join-Path $HOME '.alm4dataverse/tools'
$resolvedPacVersion = Get-PacCliInstalledPackageVersion -PacToolPath $pacToolPath

if ([string]::IsNullOrWhiteSpace($resolvedPacVersion)) {
    throw "Unable to resolve installed PAC CLI package version from 'dotnet tool list --tool-path $pacToolPath'. Ensure installdependencies.ps1 has installed Microsoft.PowerApps.CLI.Tool before build.ps1 runs."
}

$lockConfig.pacCliVersion = $resolvedPacVersion

$lockPath = Join-Path $ArtifactStagingDirectory 'scriptDependencies.lock.json'
$lockConfig | ConvertTo-Json | Out-File $lockPath -Encoding UTF8

Write-Host "##[endgroup]"

Write-Host "##[section]Build completed successfully!"

Invoke-Hook -HookType "postBuild" -BaseDirectory $SourceDirectory -Config $config -AdditionalContext @{
    SourceDirectory = $SourceDirectory
    ArtifactStagingDirectory = $ArtifactStagingDirectory
}
