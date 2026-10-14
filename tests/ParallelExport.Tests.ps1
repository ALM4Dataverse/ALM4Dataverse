BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repoRoot 'pipelines/scripts/parallel-export.ps1')
}

Describe 'Parallel export configuration' {
    It 'uses defaults for missing and empty settings under strict mode' -ForEach @(
        @{ Config = @{} }
        @{ Config = @{ export = $null } }
        @{ Config = @{ export = @{} } }
        @{ Config = @{ export = @{ parallel = $null; maxParallel = ''; maxConcurrentOperations = '' } } }
    ) {
        Set-StrictMode -Version Latest
        $settings = Get-AlmExportSetting -Config $Config
        $settings.parallel | Should -BeTrue
        $settings.maxParallel | Should -Be 2
        $settings.maxConcurrentOperations | Should -Be 4
    }

    It 'preserves explicit sequential opt-out' {
        (Get-AlmExportSetting -Config @{ export = @{ parallel = $false } }).parallel | Should -BeFalse
    }

    It 'rejects invalid export settings' -ForEach @(
        @{ Config = @{ export = 'invalid' } }
        @{ Config = @{ export = @{ parallel = 'false' } } }
        @{ Config = @{ export = @{ maxParallel = 0 } } }
        @{ Config = @{ export = @{ maxParallel = 9 } } }
        @{ Config = @{ export = @{ maxConcurrentOperations = 0 } } }
        @{ Config = @{ export = @{ maxConcurrentOperations = 9 } } }
    ) {
        { Get-AlmExportSetting -Config $Config } | Should -Throw '*export*'
    }

    It 'accepts configured concurrency limits' {
        $settings = Get-AlmExportSetting -Config @{ export = @{ maxParallel = 8; maxConcurrentOperations = 1 } }
        $settings.maxParallel | Should -Be 8
        $settings.maxConcurrentOperations | Should -Be 1
    }
}

Describe 'Parallel export logging' {
    It 'prefixes every line with the solution and phase' {
        $lines = @(Format-AlmLogLine -SolutionName Example -Phase Export -Text "First`nSecond")
        $lines | Should -Be @('[Example][Export] First', '[Example][Export] Second')
    }

    It 'preserves CI directives before the log prefix' -ForEach @(
        @{ Text = '##vso[task.logissue type=warning]Detail'; Expected = '##vso[task.logissue type=warning][Example][Export] Detail' }
        @{ Text = '##[warning]Detail'; Expected = '##[warning][Example][Export] Detail' }
        @{ Text = '::error::Detail'; Expected = '::error::[Example][Export] Detail' }
    ) {
        Format-AlmLogLine -SolutionName Example -Phase Export -Text $Text | Should -Be $Expected
    }
}

Describe 'Parallel export runtime' {
    BeforeAll {
        . (Join-Path $repoRoot 'pipelines/scripts/common.ps1')
        if (-not ('AlmExportTestClient' -as [type])) {
            Add-Type -TypeDefinition @'
public sealed class AlmExportTestClient : System.IDisposable
{
    private bool isCloning;
    private bool isClone;
    private static int started;
    private static int expectedStarts;
    private static int active;
    public static AlmExportTestClient Default { get; set; }
    public static int Peak { get; private set; }
    public static int VersionUpdates { get; set; }
    public static System.Threading.CountdownEvent Started { get; private set; }
    public static System.Threading.ManualResetEventSlim Release { get; private set; }
    public bool DetailsRead { get; private set; }
    public bool Disposed { get; private set; }
    public object OrganizationDetail
    {
        get
        {
            if (!isCloning && !DetailsRead)
            {
                if (isClone) throw new System.InvalidOperationException("RefreshInstanceDetails");
                DetailsRead = true;
            }
            return this;
        }
    }
    public AlmExportTestClient Clone(object logger)
    {
        isCloning = true;
        try { _ = OrganizationDetail; return new AlmExportTestClient { DetailsRead = DetailsRead, isClone = true }; }
        finally { isCloning = false; }
    }
    public static void Reset(int count)
    {
        Started?.Dispose();
        Release?.Dispose();
        started = 0; active = 0; Peak = 0; VersionUpdates = 0; expectedStarts = count;
        Started = new System.Threading.CountdownEvent(count);
        Release = new System.Threading.ManualResetEventSlim(false);
        Default = new AlmExportTestClient();
    }
    public void BeginExport()
    {
        _ = OrganizationDetail;
        int current = System.Threading.Interlocked.Increment(ref active);
        lock (typeof(AlmExportTestClient)) { if (current > Peak) Peak = current; }
        if (System.Threading.Interlocked.Increment(ref started) <= expectedStarts) Started.Signal();
    }
    public void AwaitRelease()
    {
        if (!Release.Wait(System.TimeSpan.FromSeconds(15))) throw new System.TimeoutException("Test export was not released");
    }
    public void EndExport() { System.Threading.Interlocked.Decrement(ref active); }
    public void Dispose() { Disposed = true; }
}
'@
        }
        $script:exportModuleSource = @'
function Get-DataverseConnection { param([switch]$GetDefault); [AlmExportTestClient]::Default }
function Write-TestSolution {
    param($OutputPath)
    New-Item -ItemType Directory -Path "$OutputPath/Other" -Force | Out-Null
    [xml]$document = '<ImportExportXml><SolutionManifest><Version>1.0.0.0</Version></SolutionManifest></ImportExportXml>'
    $document.Save("$OutputPath/Other/Solution.xml")
}
function Export-DataverseSolution {
    [CmdletBinding()]
    param($SolutionName, [switch]$Managed, $OutFile, $OutFolder, [switch]$UnpackMsApp, $Connection)
    if ($null -eq $Connection) { $Connection = [AlmExportTestClient]::Default }
    $Connection.BeginExport()
    try {
        $Connection.AwaitRelease()
        Write-Verbose 'Export detail'
        if ($SolutionName -eq 'Failure') { throw "First failure detail`nSecond failure detail" }
        if ($OutFile) { Set-Content -LiteralPath $OutFile -Value $SolutionName }
        else { Write-TestSolution $OutFolder }
    } finally { $Connection.EndExport() }
}
function Expand-DataverseSolutionFile { param($Path, $OutputPath, $PackageType, [switch]$UnpackMsapp); Write-TestSolution $OutputPath }
function Compress-DataverseSolutionFile { param($PackageType, $OutputPath, $Path); Set-Content -LiteralPath $OutputPath -Value 'baseline' }
function Set-DataverseSolution { param($UniqueName, $Version); [AlmExportTestClient]::VersionUpdates++ }
'@
    }

    BeforeEach {
        $script:savedExportModules = @(Get-Module Rnwood.Dataverse.Data.PowerShell)
        $exitCodeVariable = Get-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
        $script:savedExportExitCode = @{
            Exists = $null -ne $exitCodeVariable
            Value = $(if ($null -ne $exitCodeVariable) { $exitCodeVariable.Value } else { $null })
        }
        $script:workerRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:workerState = $null
        New-Item -ItemType Directory -Path $script:workerRoot -Force | Out-Null
        $modulePath = Join-Path $script:workerRoot 'Rnwood.Dataverse.Data.PowerShell.psm1'
        Set-Content -LiteralPath $modulePath -Value $script:exportModuleSource
        foreach ($module in $script:savedExportModules) { Remove-Module $module }
        Import-Module $modulePath -Global -Force
        [AlmExportTestClient]::Reset(1)
    }

    AfterEach {
        [AlmExportTestClient]::Release.Set()
        try {
            if ($null -ne $script:workerState) { Stop-AlmExportPipeline -State $script:workerState }
        }
        finally {
            Remove-Module Rnwood.Dataverse.Data.PowerShell -ErrorAction SilentlyContinue
            foreach ($module in $script:savedExportModules) { Import-Module $module.Path -Global }
            if ($script:savedExportExitCode.Exists) { $global:LASTEXITCODE = $script:savedExportExitCode.Value }
            else { Remove-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue }
        }
    }

    AfterAll {
        [AlmExportTestClient]::Started.Dispose()
        [AlmExportTestClient]::Release.Dispose()
    }

    It 'bounds simultaneous operations to <Limit> and cleans up independent clients' -ForEach @(
        @{ Limit = 1 }
        @{ Limit = 2 }
    ) {
        [AlmExportTestClient]::Reset($Limit)
        $config = @{ solutions = @(@{ name = 'First' }, @{ name = 'Second' }); export = @{ maxConcurrentOperations = $Limit } }
        $script:workerState = Start-AlmExportPipeline -Config $config -TempDirectory $script:workerRoot -MaxParallel 2
        $state = $script:workerState
        $state.LogDirectory = Join-Path $script:workerRoot 'logs'
        $state.Connection.DetailsRead | Should -BeTrue
        Test-Path $state.HelpersPath | Should -BeTrue
        Start-AlmQueuedExport -State $state
        [AlmExportTestClient]::Started.Wait([TimeSpan]::FromSeconds(10)) | Should -BeTrue
        [AlmExportTestClient]::Peak | Should -Be $Limit
        [AlmExportTestClient]::Release.Set()
        foreach ($name in @('First', 'Second')) {
            $zip = Wait-AlmSolutionExport -State $state -SolutionName $name
            Test-Path $zip | Should -BeTrue
            $state.CompletedExports[$name].Count | Should -Be 2
        }
        $state.Timings.Count | Should -Be 4
        $state.Clients.Count | Should -Be 4
        $state.OperationBudget.CurrentCount | Should -Be $Limit
        Stop-AlmExportPipeline -State $state
        $script:workerState = $null
        Test-Path $state.WorkDirectory | Should -BeFalse
        $state.Connection.Disposed | Should -BeFalse
        @($state.Clients | Where-Object { -not $_.Disposed }).Count | Should -Be 0
        @(Get-ChildItem $state.LogDirectory -Filter '*.log').Count | Should -Be 4
    }

    It 'propagates worker failure and preserves details without leaking operation slots' {
        $script:workerState = Start-AlmExportPipeline -Config @{ solutions = @(@{ name = 'Failure' }) } -TempDirectory $script:workerRoot -MaxParallel 1
        $script:workerState.LogDirectory = Join-Path $script:workerRoot 'failure-logs'
        [AlmExportTestClient]::Release.Set()
        { Wait-AlmSolutionExport -State $script:workerState -SolutionName Failure } | Should -Throw '*Failure*Worker failed*'
        $script:workerState.OperationBudget.CurrentCount | Should -Be 4
        $failureText = Get-Content (Join-Path $script:workerState.LogDirectory 'Failure-Export-Unmanaged.log') -Raw
        $failureText | Should -Match 'First failure detail'
        $failureText | Should -Match 'Second failure detail'
    }

    It 'preserves hooks, unchanged versions and summaries with parallel=<Parallel>' -ForEach @(
        @{ Parallel = $false }
        @{ Parallel = $true }
    ) {
        [AlmExportTestClient]::Release.Set()
        $source = Join-Path $script:workerRoot 'source'
        $staging = Join-Path $script:workerRoot 'staging'
        $temp = Join-Path $script:workerRoot 'temp'
        New-Item -ItemType Directory -Path "$source/hooks", $staging, $temp -Force | Out-Null
        Set-Content "$source/alm-config.psd1" -Value "@{ solutions = @(@{ name = 'First' }, @{ name = 'Second' }); export = @{ parallel = `$$Parallel }; hooks = @{ preExport = 'hooks/pre.ps1'; postExport = 'hooks/post.ps1' } }"
        foreach ($phase in @('pre', 'post')) {
            Set-Content "$source/hooks/$phase.ps1" -Value "param(`$Context) Add-Content (Join-Path `$Context.SourceDirectory 'hook-order.log') '$phase'"
        }
        foreach ($name in @('First', 'Second')) { Write-TestSolution "$source/solutions/$name" }
        Invoke-CheckedNativeCommand -Command git -Arguments @('-C', $source, 'init', '--quiet')
        Invoke-CheckedNativeCommand -Command git -Arguments @('-C', $source, 'add', '.')
        Invoke-CheckedNativeCommand -Command git -Arguments @('-C', $source, '-c', 'user.name=ExportTest', '-c', 'user.email=export-test@example.invalid', 'commit', '--quiet', '-m', 'Test baseline')
        Push-Location $source
        try {
            $result = & (Join-Path $repoRoot 'pipelines/scripts/export.ps1') -SourceDirectory $source -ArtifactStagingDirectory $staging -TempDirectory $temp -BranchName main -DefaultBranchName main -PassThru
        }
        finally { Pop-Location }
        $result.Parallel | Should -Be $Parallel
        $result.TotalSeconds | Should -BeGreaterOrEqual 0
        [AlmExportTestClient]::VersionUpdates | Should -Be 0
        @(Get-Content "$source/hook-order.log") | Should -Be @('pre', 'post')
        $summary = @(Get-Content "$staging/export-logs/summary.json" -Raw | ConvertFrom-Json)
        $summary.Count | Should -Be 2
        @($summary | Where-Object RunStatus -ne 'Succeeded').Count | Should -Be 0
        if ($Parallel) { $result.WorkerTimings.Count | Should -Be 4 }
        else { $result.WorkerTimings.Count | Should -Be 0 }
    }

    It 'does not initialize connections or temporary files under WhatIf' {
        $state = Start-AlmExportPipeline -Config @{ solutions = @(@{ name = 'First' }) } -TempDirectory $script:workerRoot -WhatIf
        $state | Should -BeNullOrEmpty
        [AlmExportTestClient]::Default.DetailsRead | Should -BeFalse
        @(Get-ChildItem $script:workerRoot -Directory).Count | Should -Be 0
    }

    It 'does not dequeue exports or clone clients under WhatIf' {
        $script:workerState = Start-AlmExportPipeline -Config @{ solutions = @(@{ name = 'First' }) } -TempDirectory $script:workerRoot
        Start-AlmQueuedExport -State $script:workerState -WhatIf
        $script:workerState.PendingExports.Count | Should -Be 2
        $script:workerState.Jobs.Count | Should -Be 0
        $script:workerState.Clients.Count | Should -Be 0
    }

    It 'cleans up owned resources even when ambient WhatIf is enabled' {
        $state = Start-AlmExportPipeline -Config @{ solutions = @(@{ name = 'First' }) } -TempDirectory $script:workerRoot
        $script:workerState = $state
        $savedWhatIfPreference = $WhatIfPreference
        try {
            $WhatIfPreference = $true
            Stop-AlmExportPipeline -State $state
            $script:workerState = $null
            Test-Path $state.WorkDirectory | Should -BeFalse
            $state.Connection.Disposed | Should -BeFalse
        }
        finally { $WhatIfPreference = $savedWhatIfPreference }
    }

    It 'fails promptly rather than waiting when worker startup is declined' {
        $script:workerState = Start-AlmExportPipeline -Config @{ solutions = @(@{ name = 'First' }) } -TempDirectory $script:workerRoot
        $savedWhatIfPreference = $WhatIfPreference
        try {
            $WhatIfPreference = $true
            { Wait-AlmSolutionExport -State $script:workerState -SolutionName First } | Should -Throw '*No active export workers*'
            $script:workerState.PendingExports.Count | Should -Be 2
            $script:workerState.Jobs.Count | Should -Be 0
        }
        finally { $WhatIfPreference = $savedWhatIfPreference }
    }
}