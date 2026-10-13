#Requires -Version 7.2

[CmdletBinding()]
param(
    [string[]]$TestPath = @('tests/SetupCommon.Tests.ps1', 'tests/SetupEnvironment.Tests.ps1', 'tests/SetupProviders.Tests.ps1', 'tests/SetupRepository.Tests.ps1', 'tests/SetupWizard.Tests.ps1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$global:LASTEXITCODE = 0
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$policy = Import-PowerShellDataFile (Join-Path $repoRoot 'scripts/powershell-validation.psd1')
Import-Module Pester -RequiredVersion $policy.Tools.Pester -ErrorAction Stop
$configuration = New-PesterConfiguration
$configuration.Run.Path = @($TestPath | ForEach-Object { Join-Path $repoRoot $_ })
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'None'
$configuration.CodeCoverage.Enabled = $true
$configuration.CodeCoverage.UseBreakpoints = $false
$configuration.CodeCoverage.Path = @('setup-common.ps1', 'setup-azdo.ps1', 'setup-github.ps1') | ForEach-Object { Join-Path $repoRoot $_ }
$configuration.CodeCoverage.CoveragePercentTarget = 0
$result = Invoke-Pester -Configuration $configuration
foreach ($test in $result.Failed) {
    Write-Output $test.ExpandedName
    foreach ($record in $test.ErrorRecord) { Write-Output $record.Exception.Message }
}
foreach ($container in $result.FailedContainers) {
    foreach ($record in $container.ErrorRecord) { Write-Output $record.Exception.Message }
}
Write-Output ('Setup checks: {0} passed, {1} failed.' -f $result.PassedCount, $result.FailedCount)
foreach ($path in @('setup-common.ps1', 'setup-azdo.ps1', 'setup-github.ps1')) {
    $executed = @($result.CodeCoverage.CommandsExecuted | Where-Object { [IO.Path]::GetFileName($_.File) -eq $path }).Count
    $missed = @($result.CodeCoverage.CommandsMissed | Where-Object { [IO.Path]::GetFileName($_.File) -eq $path })
    $total = $executed + $missed.Count
    if ($total) { Write-Output ('{0}: {1:F2}% ({2}/{3})' -f $path, (100 * $executed / $total), $executed, $total) }
    $missed | Group-Object Function | Sort-Object Count -Descending | Select-Object -First 8 Count, Name | Format-Table -AutoSize
}
if ($result.TotalCount -eq 0 -or $result.FailedCount -or $result.FailedContainersCount) { throw 'Setup tests failed.' }