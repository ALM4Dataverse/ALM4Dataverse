<#
.SYNOPSIS
    Defines the shared in-process export scheduler and logging helpers.
.DESCRIPTION
    Dot-source this file; it does not start workers. State returned by
    Start-AlmExportPipeline owns jobs, cloned clients, synchronization handles and
    a working directory and must be released with Stop-AlmExportPipeline in finally.
#>
function Get-AlmExportSetting {
    <#
    .SYNOPSIS
        Validates export settings while preserving explicit sequential opt-out.
    .DESCRIPTION
        Defaults: parallel=true, maxParallel=2 package workers,
        maxConcurrentOperations=4 Dataverse operation slots. Null/empty strings
        retain defaults; parallel must be Boolean and both limits integers 1-8,
        even when parallel is false. Returns a new hashtable or throws.
    #>
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
    # CI directives must remain at column zero for the runner to interpret them;
    # insert context after the directive rather than hiding it behind our prefix.
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
    # Thread jobs share these references: enqueue before signalling so the reader
    # can drain all available events after a wake-up without polling worker output.
    param($Events, [string]$SolutionName, [string]$Phase, [string]$Message)

    $Events.Queue.Enqueue([pscustomobject]@{ SolutionName = $SolutionName; Phase = $Phase; Message = $Message })
    $Events.Signal.Set() | Out-Null
}

function Expand-AlmExportSolution {
    # The SDK locates the managed companion beside the unmanaged ZIP returned by
    # Wait-AlmSolutionExport; both exports must finish before unpacking Both.
    # MappingFile redirects unpacked components; blank preserves the ordinary layout.
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
    <#
    .SYNOPSIS
        Allocates scheduler state and queues managed/unmanaged packages per solution.
    .DESCRIPTION
        Requires a loaded Dataverse module, a default cloneable connection and
        Start-ThreadJob. Duplicate names (case-insensitive) or missing cloning throw.
        Creates a unique directory beneath TempDirectory but does not launch jobs.
        Returns mutable state for the queue/wait/stop helpers; declined ShouldProcess
        returns nothing. The borrowed default connection is not owned by the state.
    .PARAMETER MaxParallel
        Maximum active package workers, separately bounded by operation slots from Config.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$TempDirectory,
        [ValidateRange(1, 8)][int]$MaxParallel = 2,
        [string]$BaseDirectory = '',
        [hashtable]$AdditionalHookContext = @{}
    )

    if (-not $PSCmdlet.ShouldProcess($TempDirectory, 'Initialize parallel export workers')) { return }

    $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($solution in $Config.solutions) {
        if (-not $names.Add($solution.name)) { throw "Duplicate solution in export configuration: $($solution.name)" }
    }
    $connection = Get-DataverseConnection -GetDefault
    $cloneMethod = $connection.GetType().GetMethods() | Where-Object { $_.Name -eq 'Clone' -and $_.GetParameters().Count -eq 1 } | Select-Object -First 1
    if (-not $cloneMethod) { throw 'Connection cloning is unavailable. Set export.parallel = $false to use sequential processing.' }
    # Populate details on the original client before cloning so workers do not
    # independently refresh partially initialized organization metadata.
    $null = $connection.OrganizationDetail
    Get-Command Start-ThreadJob -ErrorAction Stop | Out-Null
    $settings = Get-AlmExportSetting -Config $Config
    $workDirectory = Join-Path $TempDirectory ('export-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null
    $state = @{
        Config = $Config
        BaseDirectory = $BaseDirectory
        AdditionalHookContext = $AdditionalHookContext
        PendingExports = [System.Collections.Generic.Queue[object]]::new()
        ActiveExports = [System.Collections.Generic.List[object]]::new()
        PreparedSolutions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        CompletedExports = @{}
        ParallelExportSolutionHookResults = @{}
        PendingSolutionHooks = [System.Collections.Generic.Queue[object]]::new()
        ActiveSolutionHooks = [System.Collections.Generic.List[object]]::new()
        SolutionHookResults = @{}
        SolutionIndexes = @{}
        Jobs = [System.Collections.Generic.List[object]]::new()
        Clients = [System.Collections.Generic.List[object]]::new()
        Timings = [System.Collections.Generic.List[object]]::new()
        Connection = $connection
        CloneMethod = $cloneMethod
        ModulePath = (Get-Module Rnwood.Dataverse.Data.PowerShell | Select-Object -First 1).Path
        HelpersPath = $PSCommandPath
        CommonPath = Join-Path $PSScriptRoot 'common.ps1'
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
    for ($solutionIndex = 0; $solutionIndex -lt $Config.solutions.Count; $solutionIndex++) {
        $solution = $Config.solutions[$solutionIndex]
        $state.CompletedExports[$solution.name] = @{}
        $state.SolutionIndexes[$solution.name] = $solutionIndex
        foreach ($managed in @($false, $true)) {
            $suffix = if ($managed) { '_managed' } else { '' }
            $state.PendingExports.Enqueue(@{
                SolutionName = $solution.name
                SolutionConfig = $solution
                SolutionIndex = $solutionIndex
                Managed = $managed
                Path = (Join-Path $workDirectory "$($solution.name)$suffix.zip")
            })
        }
    }
    return $state
}

function Start-AlmQueuedExport {
    <#
    .SYNOPSIS
        Fills free worker slots from PendingExports, mutating the shared state.
    .DESCRIPTION
        Clones one client per package. ArgumentList passes live client, semaphore,
        cancellation and event references to thread jobs rather than serialized
        process-job copies. Declined ShouldProcess leaves the queue untouched.
        Worker output contains one Kind=Export completion record plus diagnostics.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '', Justification = 'The worker explicitly binds its parameters through Start-ThreadJob ArgumentList, preserving shared client and semaphore references.')]
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)][hashtable]$State)

    if (-not $PSCmdlet.ShouldProcess($State.WorkDirectory, 'Start queued solution exports')) { return }

    while ($State.PendingExports.Count -and $State.ActiveExports.Count -lt $State.MaxParallel) {
        $task = $State.PendingExports.Dequeue()
        $isFirstPackageForSolution = $State.PreparedSolutions.Add($task.SolutionName)
        if ($isFirstPackageForSolution) {
            $hookContext = @{}
            foreach ($key in $State.AdditionalHookContext.Keys) { $hookContext[$key] = $State.AdditionalHookContext[$key] }
            $hookContext.SolutionName = $task.SolutionName
            $hookContext.SolutionConfig = $task.SolutionConfig
            $hookContext.SolutionIndex = $task.SolutionIndex
            $hasPreExportSolutionHooks = $State.Config.ContainsKey('hooks') -and
                $State.Config['hooks'] -is [hashtable] -and
                $State.Config['hooks'].ContainsKey('preExportSolution') -and
                $State.Config['hooks']['preExportSolution']
            if ($hasPreExportSolutionHooks) {
                $hookClient = $State.CloneMethod.Invoke($State.Connection, [object[]]@($null))
                if ($null -eq $hookClient) { throw "[$($task.SolutionName)][preExportSolution] Connection cloning returned no client." }
                $State.Clients.Add($hookClient)
                $hookContext.Connection = $hookClient
                $hookContext.OperationBudget = $State.OperationBudget
                $hookContext.CancellationToken = $State.Cancellation.Token
                $null = Invoke-Hook -HookType preExportSolution -BaseDirectory $State.BaseDirectory -Config $State.Config -AdditionalContext $hookContext -LogContext:$false
            }
        }
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
            # Cancellation can fail the wait before ownership is acquired; only
            # release a slot actually held, including when export itself throws.
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
        if ($isFirstPackageForSolution) {
            Add-AlmParallelExportSolutionHook -State $State -SolutionConfig $task.SolutionConfig -SolutionIndex $task.SolutionIndex
        }
    }
}

function Receive-AlmExportJob {
    <#
    .SYNOPSIS
        Drains a terminal worker's streams, logs details and returns its completion record.
    .DESCRIPTION
        Job must carry AlmSolutionName/AlmPhase. Writes an optional per-worker log
        and host diagnostics, filtering nested group markers. Throws unless the job
        completed with exactly one Kind-bearing record and no ErrorRecord, even if
        other output appears successful. Does not remove the job or dispose its client.
    #>
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
    # Drain progress separately from completion records so long-running exports
    # remain visible while Receive-AlmExportJob waits until a worker is terminal.
    param([Parameter(Mandatory)][hashtable]$State)

    $entry = $null
    while ($State.LogEvents.Queue.TryDequeue([ref]$entry)) {
        Format-AlmLogLine -SolutionName $entry.SolutionName -Phase $entry.Phase -Text $entry.Message | ForEach-Object { Write-Host $_ }
    }
}

function Wait-AlmSolutionExport {
    <#
    .SYNOPSIS
        Advances all queued work until both packages for one configured solution finish.
    .DESCRIPTION
        Drains events and terminal jobs for any solution, records timings and starts
        more queued work while waiting. Returns the unmanaged ZIP path only after
        its managed companion and parallelExportSolution hook complete. Worker failure
        or declined startup with no active jobs throws; callers still own mandatory
        Stop-AlmExportPipeline cleanup.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$SolutionName)

    Start-AlmQueuedExport -State $State
    $hasParallelExportSolutionHook = $State.Config.ContainsKey('hooks') -and
        $State.Config['hooks'] -is [hashtable] -and
        $State.Config['hooks'].ContainsKey('parallelExportSolution') -and
        $State.Config['hooks']['parallelExportSolution']
    while (
        $State.CompletedExports[$SolutionName].Count -lt 2 -or
        ($hasParallelExportSolutionHook -and -not $State.ParallelExportSolutionHookResults.ContainsKey($SolutionName))
    ) {
        Invoke-AlmSolutionHookQueue -State $State
        Write-AlmExportEvent -State $State
        if ($State.ActiveExports.Count -eq 0 -and $State.ActiveSolutionHooks.Count -eq 0) {
            throw "[$SolutionName][Export] No active export workers; queued exports were not started."
        }
        $handles = [System.Threading.WaitHandle[]]@($State.LogEvents.Signal) +
            [System.Threading.WaitHandle[]]@($State.ActiveExports | ForEach-Object { $_.Finished }) +
            [System.Threading.WaitHandle[]]@($State.ActiveSolutionHooks | ForEach-Object { $_.Finished })
        [System.Threading.WaitHandle]::WaitAny($handles) | Out-Null
        Invoke-AlmSolutionHookQueue -State $State
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

function Invoke-AlmQueuedSolutionHook {
    <#
    .SYNOPSIS
        Starts queued per-solution hooks in background workers.
    .DESCRIPTION
        Each hook runs in an isolated thread-job runspace and receives its cloned
        Dataverse connection as Context.Connection. The worker sets that client
        as the runspace's default so existing Dataverse commands use the clone.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '', Justification = 'The worker receives the hook context and cloned Dataverse client explicitly through Start-ThreadJob ArgumentList.')]
    param([Parameter(Mandatory)][hashtable]$State)

    while ($State.PendingSolutionHooks.Count -and $State.ActiveSolutionHooks.Count -lt $State.MaxParallel) {
        $task = $State.PendingSolutionHooks.Dequeue()
        $hookType = $task.HookType
        $client = $State.CloneMethod.Invoke($State.Connection, [object[]]@($null))
        if ($null -eq $client) { throw "[$($task.SolutionName)][$hookType] Connection cloning returned no client." }
        $State.Clients.Add($client)
        $additionalContext = @{}
        foreach ($key in $task.AdditionalContext.Keys) { $additionalContext[$key] = $task.AdditionalContext[$key] }
        $additionalContext.Connection = $client
        $additionalContext.OperationBudget = $State.OperationBudget
        $additionalContext.CancellationToken = $State.Cancellation.Token
        $task.AdditionalContext = $additionalContext
        $job = Start-ThreadJob -ThrottleLimit 32 -ArgumentList @(
            $State.ModulePath, $State.HelpersPath, $State.CommonPath, $task, $State.LogEvents
        ) -ScriptBlock {
            param($ModulePath, $HelpersPath, $CommonPath, $Task, $Events)
            $ErrorActionPreference = 'Stop'
            $ProgressPreference = 'SilentlyContinue'
            $started = [datetime]::UtcNow
            $phase = $Task.HookType
            try {
                Import-Module $ModulePath -ErrorAction Stop
                . $HelpersPath
                . $CommonPath
                Set-DataverseConnectionAsDefault -Connection $Task.AdditionalContext.Connection
                try {
                    Send-AlmExportEvent -Events $Events -SolutionName $Task.SolutionName -Phase $phase -Message 'Started'
                    $results = @(Invoke-Hook -HookType $Task.HookType -BaseDirectory $Task.BaseDirectory -Config $Task.Config -AdditionalContext $Task.AdditionalContext -LogContext:$false)
                    Send-AlmExportEvent -Events $Events -SolutionName $Task.SolutionName -Phase $phase -Message "Completed in $([math]::Round(([datetime]::UtcNow-$started).TotalSeconds,2))s"
                } finally {
                    Set-DataverseConnectionAsDefault -Clear
                }
                [pscustomobject]@{ Kind = 'SolutionHook'; HookType = $Task.HookType; SolutionName = $Task.SolutionName; Results = $results; Started = $started; Finished = [datetime]::UtcNow }
            } catch {
                Send-AlmExportEvent -Events $Events -SolutionName $Task.SolutionName -Phase $phase -Message "Failed: $(($_ | Out-String).TrimEnd())"
                throw
            }
        }
        $job | Add-Member -NotePropertyName AlmSolutionName -NotePropertyValue $task.SolutionName
        $job | Add-Member -NotePropertyName AlmPhase -NotePropertyValue $hookType
        $State.Jobs.Add($job)
        $State.ActiveSolutionHooks.Add($job)
    }
}

function Add-AlmSolutionHook {
    <#
    .SYNOPSIS
        Queues a per-solution hook with a cloned connection and export context.
    .DESCRIPTION
        Per-solution hook type determines when callers queue it; queued hooks run
        in workers and share the operation budget and cancellation token.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][ValidateSet('parallelExportSolution', 'postExportSolution')][string]$HookType,
        [Parameter(Mandatory)][hashtable]$SolutionConfig,
        [Parameter(Mandatory)][int]$SolutionIndex
    )

    $hasHooks = $State.Config.ContainsKey('hooks') -and
        $State.Config['hooks'] -is [hashtable] -and
        $State.Config['hooks'].ContainsKey($HookType) -and
        $State.Config['hooks'][$HookType]
    if (-not $hasHooks) { return }
    $additionalContext = @{}
    foreach ($key in $State.AdditionalHookContext.Keys) { $additionalContext[$key] = $State.AdditionalHookContext[$key] }
    $additionalContext.SolutionName = $SolutionConfig.name
    $additionalContext.SolutionConfig = $SolutionConfig
    $additionalContext.SolutionIndex = $SolutionIndex
    $State.PendingSolutionHooks.Enqueue(@{
        SolutionName = $SolutionConfig.name
        SolutionIndex = $SolutionIndex
        SolutionConfig = $SolutionConfig
        HookType = $HookType
        Config = $State.Config
        BaseDirectory = $State.BaseDirectory
        AdditionalContext = $additionalContext
    })
    Invoke-AlmSolutionHookQueue -State $State
}

function Add-AlmParallelExportSolutionHook {
    <#
    .SYNOPSIS
        Starts the configured per-solution hook alongside its export workers.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$SolutionConfig,
        [Parameter(Mandatory)][int]$SolutionIndex
    )

    Add-AlmSolutionHook -State $State -HookType parallelExportSolution -SolutionConfig $SolutionConfig -SolutionIndex $SolutionIndex
}

function Add-AlmPostExportSolutionHook {
    <#
    .SYNOPSIS
        Queues the post-export hook for a solution after unpack and comparison.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$SolutionConfig,
        [Parameter(Mandatory)][int]$SolutionIndex
    )

    Add-AlmSolutionHook -State $State -HookType postExportSolution -SolutionConfig $SolutionConfig -SolutionIndex $SolutionIndex
}

function Invoke-AlmSolutionHookQueue {
    <#
    .SYNOPSIS
        Collects completed per-solution hooks and starts queued hooks.
    .DESCRIPTION
        Stores hook output by phase and solution, surfaces worker failures and
        fills available parallel slots from the pending queue.
    #>
    param([Parameter(Mandatory)][hashtable]$State)

    foreach ($job in @($State.ActiveSolutionHooks.ToArray())) {
        if ($job.State -in @('Completed', 'Failed', 'Stopped')) {
            $result = Receive-AlmExportJob -Job $job -LogDirectory $State.LogDirectory
            if ($result.Kind -ne 'SolutionHook') { throw "[$($job.AlmSolutionName)][$($job.AlmPhase)] Unexpected worker result '$($result.Kind)'." }
            switch ($result.HookType) {
                'parallelExportSolution' { $State.ParallelExportSolutionHookResults[$result.SolutionName] = @($result.Results) }
                'postExportSolution' { $State.SolutionHookResults[$result.SolutionName] = @($result.Results) }
                default { throw "[$($job.AlmSolutionName)][$($job.AlmPhase)] Unexpected hook type '$($result.HookType)'." }
            }
            $State.ActiveSolutionHooks.Remove($job) | Out-Null
        }
    }
    Invoke-AlmQueuedSolutionHook -State $State
}

function Complete-AlmSolutionHooks {
    <#
    .SYNOPSIS
        Waits for all queued per-solution export hooks to finish.
    .DESCRIPTION
        Continues draining hook events and completion records until no pending
        or active hooks remain, before the global postExport hook runs.
    #>
    param([Parameter(Mandatory)][hashtable]$State)

    while ($State.PendingSolutionHooks.Count -or $State.ActiveSolutionHooks.Count) {
        Invoke-AlmSolutionHookQueue -State $State
        if ($State.ActiveSolutionHooks.Count) {
            $handles = [System.Threading.WaitHandle[]]@($State.LogEvents.Signal) +
                [System.Threading.WaitHandle[]]@($State.ActiveSolutionHooks | ForEach-Object { $_.Finished })
            [System.Threading.WaitHandle]::WaitAny($handles) | Out-Null
        }
        Write-AlmExportEvent -State $State
    }
}

function Complete-AlmPostExportSolutionHook {
    param([Parameter(Mandatory)][hashtable]$State)

    Complete-AlmSolutionHooks -State $State
}

function Stop-AlmExportPipeline {
    <#
    .SYNOPSIS
        Cancels and releases an owned scheduler, including after failure.
    .DESCRIPTION
        Stops/removes jobs, drains remaining logs, disposes cloned clients and
        synchronization handles and deletes WorkDirectory, but not the default
        connection or external LogDirectory. Intended for one finally call per
        initialized state, not repeated disposal. Cleanup bypasses ambient WhatIf.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Mandatory teardown cancels owned jobs and releases clients, synchronization handles and temporary files; prompting must not strand resources after an export failure.')]
    param([Parameter(Mandatory)][hashtable]$State)

    $State.Cancellation.Cancel()
    try {
        foreach ($job in $State.Jobs) {
            if ($job.State -notin @('Completed', 'Failed', 'Stopped')) { Stop-Job -Job $job -WhatIf:$false -Confirm:$false }
            if ($job.HasMoreData) {
                try {
                    $result = Receive-AlmExportJob -Job $job -LogDirectory $State.LogDirectory
                    if ($result.Kind -eq 'Export') { $State.Timings.Add($result) }
                }
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