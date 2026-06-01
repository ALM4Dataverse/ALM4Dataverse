<# 
.SYNOPSIS
    Builds the artifacts that can be used to deploy to a Dataverse environment.

.DESCRIPTION
    This script packs the solutions from the source directory into managed and unmanaged
    zip files in the artifact staging directory. It also copies any additional assets
    defined in alm-config.psd1 and creates a lock file for script dependencies.

    Hooks defined in alm-config.psd1 are invoked at various stages of the build process
    to allow for custom pre- and post-build actions.
.PARAMETER SourceDirectory
    The root directory containing the solution folders and alm-config.psd1 file.
.PARAMETER ArtifactStagingDirectory
    The directory where the built artifacts will be placed.
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

function New-SolutionCheckSeverityCounts {
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

function Parse-SolutionCheckSeverityCounts {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConsoleText
    )

    $counts = New-SolutionCheckSeverityCounts

    foreach ($severity in @('Critical', 'High', 'Medium', 'Low', 'Informational')) {
        $escaped = [regex]::Escape($severity)
        $matches = [regex]::Matches($ConsoleText, "(?im)\b$escaped\b(?:\s+issues?)?\s*[:=]\s*(\d+)\b")
        foreach ($match in $matches) {
            $counts[$severity] += [int]$match.Groups[1].Value
        }
    }

    return $counts
}

function Resolve-SolutionCheckExcludedFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceDirectory,

        [Parameter(Mandatory = $true)]
        [string]$SolutionName,

        [Parameter(Mandatory = $true)]
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

        $matches = @(Get-ChildItem -Path $searchPath -File -Recurse -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        if ($matches.Count -eq 0 -and (Test-Path $searchPath -PathType Leaf)) {
            $matches = @((Resolve-Path $searchPath | Select-Object -ExpandProperty Path))
        }

        if ($matches.Count -eq 0) {
            Write-Host "##[warning]No files matched excludedFiles pattern '$patternText' for solution '$SolutionName'."
            continue
        }

        foreach ($match in $matches) {
            if (-not $resolvedFiles.Contains($match)) {
                $resolvedFiles.Add($match)
            }
        }
    }

    return @($resolvedFiles.ToArray())
}

function ConvertTo-SolutionCheckRuleOverrideFile {
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
        $solutionLevel = if ($solution.solutionCheck -is [hashtable]) { $solution.solutionCheck } else { @{} }
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
        $solutionLevel = if ($solution.solutionCheck -is [hashtable]) { $solution.solutionCheck } else { @{} }
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
            $resolvedExcludedFiles = Resolve-SolutionCheckExcludedFiles -SourceDirectory $SourceDirectory -SolutionName $solutionName -Patterns $excludedFilesRaw
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

    $results = @($plans | ForEach-Object -ThrottleLimit $maxParallel -Parallel {
        $plan = $_
        $ErrorActionPreference = 'Stop'

        function New-Counts {
            return [ordered]@{ Critical = 0; High = 0; Medium = 0; Low = 0; Informational = 0 }
        }

        function Parse-Counts {
            param([string]$Text)

            $counts = New-Counts
            foreach ($severity in @('Critical', 'High', 'Medium', 'Low', 'Informational')) {
                $escaped = [regex]::Escape($severity)
                $matches = [regex]::Matches($Text, "(?im)\b$escaped\b(?:\s+issues?)?\s*[:=]\s*(\d+)\b")
                foreach ($match in $matches) {
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

            $args = @('solution', 'check', '--path', $plan.SolutionZip, '--outputDirectory', $reportDirectory, '--geo', $plan.Geo)

            if (-not [string]::IsNullOrWhiteSpace($plan.RuleSet)) {
                $args += @('--ruleSet', $plan.RuleSet)
            }

            if ($plan.ExcludedFiles -and $plan.ExcludedFiles.Count -gt 0) {
                $args += @('--excludedFiles', ($plan.ExcludedFiles -join ','))
            }

            if (-not [string]::IsNullOrWhiteSpace($plan.RuleLevelFile)) {
                $args += @('--ruleLevelOverride', $plan.RuleLevelFile)
            }

            $output = @(& $pac.Source @args 2>&1)
            $exitCode = $LASTEXITCODE
            $outputText = ($output | ForEach-Object { [string]$_ }) -join "`r`n"
            $outputText | Out-File -FilePath (Join-Path $reportDirectory 'pac-solution-check.log') -Encoding UTF8

            $counts = Parse-Counts -Text $outputText
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
                SeverityCounts    = (New-Counts)
                HighestSeverity   = 'None'
                FailThreshold     = $plan.FailThreshold
                ThresholdBreached = $false
            }
        }
    })

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
Write-Host "##[debug]Loaded configuration from alm-config.psd1"

Invoke-Hooks -HookType "preBuild" -BaseDirectory $SourceDirectory -Config $config -AdditionalContext @{
    SourceDirectory = $SourceDirectory
    ArtifactStagingDirectory = $ArtifactStagingDirectory
}

foreach ($solution in $config.solutions) {
    $solutionName = $solution.name
    
    Write-Host "##[group]Building solution: $solutionName"
    
    Write-Host "Packing solution: $solutionName (Managed)"

    Compress-DataverseSolutionFile -Verbose `
        -Path "$SourceDirectory/solutions/$solutionName" `
        -OutputPath "$ArtifactStagingDirectory/solutions/${solutionName}.zip" `
        -PackageType Both
    
    Write-Host "##[endgroup]"
}

Invoke-SolutionCheck -Config $config -SourceDirectory $SourceDirectory -ArtifactStagingDirectory $ArtifactStagingDirectory

if ($config.assets -and $config.assets.Count -gt 0) {
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

# Create lock file with pinned module versions
$lockConfig = @{
    scriptDependencies = [hashtable]::new($config.scriptDependencies)
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

$pacToolPath = Join-Path $HOME '.alm4dataverse\tools'
$resolvedPacVersion = Get-PacCliInstalledPackageVersion -PacToolPath $pacToolPath

if ([string]::IsNullOrWhiteSpace($resolvedPacVersion)) {
    throw "Unable to resolve installed PAC CLI package version from 'dotnet tool list --tool-path $pacToolPath'. Ensure installdependencies.ps1 has installed Microsoft.PowerApps.CLI.Tool before build.ps1 runs."
}

$lockConfig.pacCliVersion = $resolvedPacVersion

$lockPath = Join-Path $ArtifactStagingDirectory 'scriptDependencies.lock.json'
$lockConfig | ConvertTo-Json | Out-File $lockPath -Encoding UTF8

Write-Host "##[endgroup]"

Write-Host "##[section]Build completed successfully!"

Invoke-Hooks -HookType "postBuild" -BaseDirectory $SourceDirectory -Config $config -AdditionalContext @{
    SourceDirectory = $SourceDirectory
    ArtifactStagingDirectory = $ArtifactStagingDirectory
}
