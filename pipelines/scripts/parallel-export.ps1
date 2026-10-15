function Get-AlmExportSetting {
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$Config)

    $settings = @{ parallel = $true; maxParallel = 2; maxConcurrentOperations = 4 }
    if ($Config.ContainsKey('export') -and $null -ne $Config.export) {
        if ($Config.export -isnot [hashtable]) { throw 'export must be a hashtable.' }
        foreach ($name in @('parallel', 'maxParallel', 'maxConcurrentOperations')) {
            if ($Config.export.ContainsKey($name)) {
                $value = $Config.export[$name]
                if ($null -ne $value -and -not ($value -is [string] -and $value -eq '')) { $settings[$name] = $value }
            }
        }
    }
    if ($settings.parallel -isnot [bool]) { throw 'export.parallel must be $true or $false.' }
    foreach ($name in @('maxParallel', 'maxConcurrentOperations')) {
        if ($settings[$name] -isnot [int] -or $settings[$name] -lt 1 -or $settings[$name] -gt 8) {
            throw "export.$name must be an integer between 1 and 8."
        }
    }
    return $settings
}

function Format-AlmLogLine {
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$SolutionName,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )

    foreach ($line in ($Text -split '\r?\n')) {
        $prefix = "[$SolutionName][$Phase]"
        if ($line -match '^(##vso\[[^\]]+\]|##\[(?:debug|warning|error|section)\]|::(?:warning|error|notice)(?: [^:]*)?::)(.*)$') {
            "$($Matches[1])$prefix $($Matches[2])"
        } else { "$prefix $line" }
    }
}

function Send-AlmExportEvent {
    param($Events, [string]$SolutionName, [string]$Phase, [string]$Message)

    $Events.Queue.Enqueue([pscustomobject]@{ SolutionName = $SolutionName; Phase = $Phase; Message = $Message })
    $Events.Signal.Set() | Out-Null
}

function Expand-AlmExportSolution {
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$MappingFile
    )

    if ([string]::IsNullOrWhiteSpace($MappingFile)) {
        Expand-DataverseSolutionFile -Path $ZipPath -OutputPath $OutputPath -PackageType Both -UnpackMsapp
    } else {
        Expand-DataverseSolutionFile -Path $ZipPath -OutputPath $OutputPath -PackageType Both -UnpackMsapp -MappingFile $MappingFile
    }
}

function Start-AlmExportPipeline {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$TempDirectory,
        [ValidateRange(1, 8)][int]$MaxParallel = 2
    )

    if (-not $PSCmdlet.ShouldProcess($TempDirectory, 'Initialize parallel export workers')) { return }

    $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($solution in $Config.solutions) {
        if (-not $names.Add($solution.name)) { throw "Duplicate solution in export configuration: $($solution.name)" }
    }
    $connection = Get-DataverseConnection -GetDefault
    $cloneMethod = $connection.GetType().GetMethods() | Where-Object { $_.Name -eq 'Clone' -and $_.GetParameters().Count -eq 1 } | Select-Object -First 1
    if (-not $cloneMethod) { throw 'Connection cloning is unavailable. Set export.parallel = $false to use sequential processing.' }
    $null = $connection.OrganizationDetail
    Get-Command Start-ThreadJob -ErrorAction Stop | Out-Null
    $settings = Get-AlmExportSetting -Config $Config
    $workDirectory = Join-Path $TempDirectory ('export-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null
    $state = @{
        PendingExports = [System.Collections.Generic.Queue[object]]::new()
        ActiveExports = [System.Collections.Generic.List[object]]::new()
        CompletedExports = @{}
        Jobs = [System.Collections.Generic.List[object]]::new()
        Clients = [System.Collections.Generic.List[object]]::new()
        Timings = [System.Collections.Generic.List[object]]::new()
        Connection = $connection
        CloneMethod = $cloneMethod
        ModulePath = (Get-Module Rnwood.Dataverse.Data.PowerShell | Select-Object -First 1).Path
        HelpersPath = $PSCommandPath
        WorkDirectory = $workDirectory
        MaxParallel = $MaxParallel
        OperationBudget = [System.Threading.SemaphoreSlim]::new($settings.maxConcurrentOperations, $settings.maxConcurrentOperations)
        Cancellation = [System.Threading.CancellationTokenSource]::new()
        LogEvents = [pscustomobject]@{
            Queue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
            Signal = [System.Threading.AutoResetEvent]::new($false)
        }
        LogDirectory = ''
    }
    foreach ($solution in $Config.solutions) {
        $state.CompletedExports[$solution.name] = @{}
        foreach ($managed in @($false, $true)) {
            $suffix = if ($managed) { '_managed' } else { '' }
            $state.PendingExports.Enqueue(@{ SolutionName = $solution.name; Managed = $managed; Path = (Join-Path $workDirectory "$($solution.name)$suffix.zip") })
        }
    }
    return $state
}

function Start-AlmQueuedExport {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '', Justification = 'The worker explicitly binds its parameters through Start-ThreadJob ArgumentList, preserving shared client and semaphore references.')]
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)][hashtable]$State)

    if (-not $PSCmdlet.ShouldProcess($State.WorkDirectory, 'Start queued solution exports')) { return }

    while ($State.PendingExports.Count -and $State.ActiveExports.Count -lt $State.MaxParallel) {
        $task = $State.PendingExports.Dequeue()
        $client = $State.CloneMethod.Invoke($State.Connection, [object[]]@($null))
        if ($null -eq $client) { throw "[$($task.SolutionName)][Export] Connection cloning returned no client." }
        $State.Clients.Add($client)
        $job = Start-ThreadJob -ThrottleLimit 32 -ArgumentList @($State.ModulePath, $client, $task, $State.OperationBudget, $State.Cancellation.Token, $State.LogEvents, $State.HelpersPath) -ScriptBlock {
            param($ModulePath, $Client, $Task, $Budget, $Cancellation, $Events, $HelpersPath)
            $ErrorActionPreference = 'Stop'
            $ProgressPreference = 'SilentlyContinue'
            $started = [datetime]::UtcNow
            Import-Module $ModulePath
            . $HelpersPath
            $phase = if ($Task.Managed) { 'Export:Managed' } else { 'Export:Unmanaged' }
            $acquired = $false
            try {
                $Budget.Wait($Cancellation)
                $acquired = $true
                Send-AlmExportEvent -Events $Events -SolutionName $Task.SolutionName -Phase $phase -Message 'Started'
                Export-DataverseSolution -SolutionName $Task.SolutionName -Managed:$Task.Managed -OutFile $Task.Path -Connection $Client
                Send-AlmExportEvent -Events $Events -SolutionName $Task.SolutionName -Phase $phase -Message "Completed in $([math]::Round(([datetime]::UtcNow-$started).TotalSeconds,2))s"
            } catch {
                Send-AlmExportEvent -Events $Events -SolutionName $Task.SolutionName -Phase $phase -Message "Failed: $(($_ | Out-String).TrimEnd())"
                throw
            } finally {
                if ($acquired) { $Budget.Release() | Out-Null }
            }
            [pscustomobject]@{ Kind = 'Export'; SolutionName = $Task.SolutionName; Managed = $Task.Managed; Path = $Task.Path; Started = $started; Finished = [datetime]::UtcNow }
        }
        $job | Add-Member -NotePropertyName AlmSolutionName -NotePropertyValue $task.SolutionName
        $job | Add-Member -NotePropertyName AlmPhase -NotePropertyValue $(if ($task.Managed) { 'Export:Managed' } else { 'Export:Unmanaged' })
        $State.Jobs.Add($job)
        $State.ActiveExports.Add($job)
    }
}

function Receive-AlmExportJob {
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)]$Job, [string]$LogDirectory = '')

    $solutionName = $Job.AlmSolutionName
    $phase = $Job.AlmPhase
    $records = @(Receive-Job -Job $Job -ErrorAction Continue *>&1)
    $result = @($records | Where-Object { $_.PSObject.Properties['Kind'] })
    $details = @(foreach ($record in $records | Where-Object { -not $_.PSObject.Properties['Kind'] }) {
        foreach ($line in ([string]$record -split '\r?\n')) {
            if ($line.StartsWith("[$solutionName]")) { $line }
            elseif ($line -notmatch '^(##\[(?:endgroup|group)\]|::(?:endgroup|group)::)') { Format-AlmLogLine -SolutionName $solutionName -Phase $phase -Text $line }
        }
    })
    if ($LogDirectory) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $LogDirectory "$solutionName-$($phase.Replace(':','-')).log") -Value (@("[$solutionName][$phase] Worker state=$($Job.State)") + $details) -Encoding utf8
    }
    if ($details.Count) {
        if ($env:TF_BUILD) { Write-Host "##[group][$solutionName][$phase] Details" }
        elseif ($env:GITHUB_ACTIONS) { Write-Host "::group::[$solutionName][$phase] Details" }
        try { $details | ForEach-Object { Write-Host $_ } }
        finally {
            if ($env:TF_BUILD) { Write-Host '##[endgroup]' }
            elseif ($env:GITHUB_ACTIONS) { Write-Host '::endgroup::' }
        }
    }
    if ($Job.State -ne 'Completed' -or $result.Count -ne 1 -or @($records | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }).Count) {
        throw "[$solutionName][$phase] Worker failed: $($Job.JobStateInfo.Reason)"
    }
    return $result[0]
}

function Write-AlmExportEvent {
    param([Parameter(Mandatory)][hashtable]$State)

    $entry = $null
    while ($State.LogEvents.Queue.TryDequeue([ref]$entry)) {
        Format-AlmLogLine -SolutionName $entry.SolutionName -Phase $entry.Phase -Text $entry.Message | ForEach-Object { Write-Host $_ }
    }
}

function Wait-AlmSolutionExport {
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$SolutionName)

    Start-AlmQueuedExport -State $State
    while ($State.CompletedExports[$SolutionName].Count -lt 2) {
        Write-AlmExportEvent -State $State
        if ($State.ActiveExports.Count -eq 0) { throw "[$SolutionName][Export] No active export workers; queued exports were not started." }
        $handles = [System.Threading.WaitHandle[]]@($State.LogEvents.Signal) + [System.Threading.WaitHandle[]]@($State.ActiveExports | ForEach-Object { $_.Finished })
        [System.Threading.WaitHandle]::WaitAny($handles) | Out-Null
        Write-AlmExportEvent -State $State
        foreach ($job in @($State.ActiveExports.ToArray())) {
            if ($job.State -in @('Completed', 'Failed', 'Stopped')) {
                $result = Receive-AlmExportJob -Job $job -LogDirectory $State.LogDirectory
                $State.Timings.Add($result)
                $key = if ($result.Managed) { 'Managed' } else { 'Unmanaged' }
                $State.CompletedExports[$result.SolutionName][$key] = $result.Path
                $State.ActiveExports.Remove($job) | Out-Null
            }
        }
        Start-AlmQueuedExport -State $State
    }
    return $State.CompletedExports[$SolutionName].Unmanaged
}

function Stop-AlmExportPipeline {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Mandatory teardown cancels owned jobs and releases clients, synchronization handles and temporary files; prompting must not strand resources after an export failure.')]
    param([Parameter(Mandatory)][hashtable]$State)

    $State.Cancellation.Cancel()
    try {
        foreach ($job in $State.Jobs) {
            if ($job.State -notin @('Completed', 'Failed', 'Stopped')) { Stop-Job -Job $job -WhatIf:$false -Confirm:$false }
            if ($job.HasMoreData) {
                try { $State.Timings.Add((Receive-AlmExportJob -Job $job -LogDirectory $State.LogDirectory)) }
                catch { Write-Host ([string]$_) }
            }
            Remove-Job -Job $job -Force -WhatIf:$false -Confirm:$false
        }
        Write-AlmExportEvent -State $State
    } finally {
        foreach ($client in $State.Clients) { $client.Dispose() }
        $State.OperationBudget.Dispose()
        $State.Cancellation.Dispose()
        $State.LogEvents.Signal.Dispose()
        Remove-Item -LiteralPath $State.WorkDirectory -Recurse -Force -WhatIf:$false -Confirm:$false
    }
}