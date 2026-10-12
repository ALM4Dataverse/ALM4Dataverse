$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
. "$repoRoot/pipelines/scripts/parallel-export.ps1"
. "$repoRoot/pipelines/scripts/common.ps1"

function Assert-ExportTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

foreach ($config in @(@{}, @{export=$null}, @{export=@{}}, @{export=@{parallel=$null;maxParallel=''}})) {
    $settings = Get-AlmExportSettings $config
    Assert-ExportTest ($settings.parallel -and $settings.maxParallel -eq 2 -and $settings.maxConcurrentOperations -eq 4) 'Incorrect export defaults'
}
Assert-ExportTest (-not (Get-AlmExportSettings @{export=@{parallel=$false}}).parallel) 'Explicit opt-out was lost'
foreach ($config in @(@{export='invalid'}, @{export=@{parallel='false'}}, @{export=@{maxParallel=0}}, @{export=@{maxParallel=9}}, @{export=@{maxConcurrentOperations=0}})) {
    $rejected = $false
    try { Get-AlmExportSettings $config | Out-Null } catch { $rejected = $true }
    Assert-ExportTest $rejected 'Invalid configuration was accepted'
}
foreach ($config in @(@{}, @{hooks=$null}, @{hooks=@{}}, @{hooks=@{postExport=$null}})) {
    Invoke-Hooks -HookType postExport -BaseDirectory $repoRoot -Config $config
}
$lines = @(Format-AlmLogLine -SolutionName Example -Phase Export -Text "First`nSecond")
Assert-ExportTest ($lines.Count -eq 2 -and $lines[1] -eq '[Example][Export] Second') 'Multiline output is not prefixed'
Assert-ExportTest ((Format-AlmLogLine Example Export '##vso[task.logissue type=warning]Detail') -eq '##vso[task.logissue type=warning][Example][Export] Detail') 'CI directive was changed'

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

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('alm-export-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$existingModules = @(Get-Module Rnwood.Dataverse.Data.PowerShell)
$modulePath = Join-Path $testRoot 'Rnwood.Dataverse.Data.PowerShell.psm1'
$moduleSource = @'
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
Set-Content -LiteralPath $modulePath -Value $moduleSource

try {
    foreach ($module in $existingModules) { Remove-Module $module }
    Import-Module $modulePath -Force
    foreach ($limit in @(1, 2)) {
        [AlmExportTestClient]::Reset($limit)
        $config = @{solutions=@(@{name='First'}, @{name='Second'});export=@{maxConcurrentOperations=$limit}}
        $state = Start-AlmExportPipeline -Config $config -TempDirectory $testRoot -MaxParallel 2
        $state.LogDirectory = Join-Path $testRoot "logs-$limit"
        $workDirectory = $state.WorkDirectory
        try {
            Assert-ExportTest $state.Connection.DetailsRead 'Source organization details were not initialized'
            Assert-ExportTest (Test-Path $state.HelpersPath) 'Helper script path is unavailable to workers'
            Start-AlmQueuedExports $state
            Assert-ExportTest ([AlmExportTestClient]::Started.Wait([TimeSpan]::FromSeconds(10))) 'Exports did not start'
            Assert-ExportTest ([AlmExportTestClient]::Peak -eq $limit) 'Shared concurrency limit was not respected'
            [AlmExportTestClient]::Release.Set()
            foreach ($name in @('First', 'Second')) {
                $zip = Wait-AlmSolutionExports $state $name
                Assert-ExportTest (Test-Path $zip) 'Unmanaged package missing'
                Assert-ExportTest ($state.CompletedExports[$name].Count -eq 2) 'Managed/unmanaged pairing was lost'
            }
            Assert-ExportTest ($state.Timings.Count -eq 4 -and $state.Clients.Count -eq 4) 'Package results or independent clients missing'
            Assert-ExportTest ($state.OperationBudget.CurrentCount -eq $limit) 'Remote-operation slots leaked'
        } finally { [AlmExportTestClient]::Release.Set(); Stop-AlmExportPipeline $state }
        Assert-ExportTest (-not (Test-Path $workDirectory)) 'Owned temporary directory was retained'
        Assert-ExportTest (-not $state.Connection.Disposed) 'Original connection was disposed'
        Assert-ExportTest (@($state.Clients | Where-Object { -not $_.Disposed }).Count -eq 0) 'Cloned connections leaked'
        Assert-ExportTest ((Get-ChildItem $state.LogDirectory -Filter '*.log').Count -eq 4) 'Detailed package logs missing'
    }

    [AlmExportTestClient]::Reset(1)
    $state = Start-AlmExportPipeline -Config @{solutions=@(@{name='Failure'})} -TempDirectory $testRoot -MaxParallel 1
    $state.LogDirectory = Join-Path $testRoot 'failure-logs'
    $failure = $null
    try {
        [AlmExportTestClient]::Release.Set()
        try { Wait-AlmSolutionExports $state Failure | Out-Null } catch { $failure = $_ }
        Assert-ExportTest ($null -ne $failure) 'Failed export was accepted'
        Assert-ExportTest ($state.OperationBudget.CurrentCount -eq 4) 'Failure leaked a remote-operation slot'
        $failureText = Get-Content (Join-Path $state.LogDirectory 'Failure-Export-Unmanaged.log') -Raw
        Assert-ExportTest ($failureText -match 'First failure detail') 'Failure details were not retained'
    } finally { Stop-AlmExportPipeline $state }

    foreach ($parallel in @($false, $true)) {
        [AlmExportTestClient]::Reset(1)
        [AlmExportTestClient]::Release.Set()
        $caseRoot = Join-Path $testRoot "pipeline-$parallel"
        New-Item -ItemType Directory -Path "$caseRoot/source/hooks", "$caseRoot/staging", "$caseRoot/temp" -Force | Out-Null
        Set-Content "$caseRoot/source/alm-config.psd1" -Value "@{solutions=@(@{name='First'},@{name='Second'});export=@{parallel=`$$parallel};hooks=@{preExport='hooks/pre.ps1';postExport='hooks/post.ps1'}}"
        foreach ($phase in @('pre', 'post')) {
            Set-Content "$caseRoot/source/hooks/$phase.ps1" -Value "param(`$Context) Add-Content (Join-Path `$Context.SourceDirectory 'hook-order.log') '$phase'"
        }
        foreach ($name in @('First', 'Second')) { Write-TestSolution "$caseRoot/source/solutions/$name" }
        git -C "$caseRoot/source" init --quiet
        git -C "$caseRoot/source" add .
        git -C "$caseRoot/source" -c user.name=ExportTest -c user.email=export-test@example.invalid commit --quiet -m 'Test baseline'
        if ($LASTEXITCODE -ne 0) { throw 'Could not create isolated test Git baseline' }
        Push-Location "$caseRoot/source"
        try {
            $result = & "$repoRoot/pipelines/scripts/export.ps1" -SourceDirectory "$caseRoot/source" -ArtifactStagingDirectory "$caseRoot/staging" -TempDirectory "$caseRoot/temp" -PassThru
        } finally { Pop-Location }
        Assert-ExportTest ($result.Parallel -eq $parallel -and $result.TotalSeconds -ge 0) 'PassThru result missing'
        Assert-ExportTest ([AlmExportTestClient]::VersionUpdates -eq 0) 'Unchanged sources caused a version update'
        Assert-ExportTest ((Get-Content "$caseRoot/source/hook-order.log") -join ',' -eq 'pre,post') 'Hook order changed'
        $summary = @(Get-Content "$caseRoot/staging/export-logs/summary.json" -Raw | ConvertFrom-Json)
        Assert-ExportTest ($summary.Count -eq 2 -and @($summary | Where-Object RunStatus -ne 'Succeeded').Count -eq 0) 'Per-solution summary missing'
        if ($parallel) { Assert-ExportTest ($result.WorkerTimings.Count -eq 4) 'Parallel package timings missing' }
    }
    Write-Host 'PASS: Strict configuration, hooks, bounded parallel exports, lazy client details, failure logs, cleanup, sequential opt-out and full EXPORT integration.'
} finally {
    [AlmExportTestClient]::Release.Set()
    Remove-Module Rnwood.Dataverse.Data.PowerShell -ErrorAction SilentlyContinue
    foreach ($module in $existingModules) { Import-Module $module.Path }
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}