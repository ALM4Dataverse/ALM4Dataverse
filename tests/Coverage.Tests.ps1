BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/coverage.ps1')
}

Describe 'Per-file coverage threshold' {
    It 'passes exactly 65 percent and fails a separate module below the threshold' {
        $coveredPath = Join-Path $TestDrive 'covered.ps1'
        $uncoveredPath = Join-Path $TestDrive 'uncovered.psm1'
        $coverage = @{
            CommandsExecuted = @(
                1..65 | ForEach-Object { @{ File = $coveredPath } }
                1..64 | ForEach-Object { @{ File = $uncoveredPath } }
            )
            CommandsMissed = @(
                1..35 | ForEach-Object { @{ File = $coveredPath } }
                1..36 | ForEach-Object { @{ File = $uncoveredPath } }
            )
        }
        $report = @(Get-PowerShellFileCoverage -RepositoryRoot $TestDrive -ModifiedFiles covered.ps1,uncovered.psm1 -Coverage $coverage)
        $report[0].Percent | Should -Be 65
        $report[0].Passed | Should -BeTrue
        $report[1].Percent | Should -Be 64
        $report[1].Passed | Should -BeFalse
    }

    It 'fails a completely unexecuted file' {
        $coverage = @{ CommandsExecuted = @(); CommandsMissed = @(@{ File = (Join-Path $TestDrive 'uncovered.psm1') }) }
        $report = Get-PowerShellFileCoverage -RepositoryRoot $TestDrive -ModifiedFiles uncovered.psm1 -Coverage $coverage
        $report.Percent | Should -Be 0
        $report.Passed | Should -BeFalse
    }

    It 'marks files with no executable commands as not applicable' {
        $coverage = @{ CommandsExecuted = @(); CommandsMissed = @() }
        $report = Get-PowerShellFileCoverage -RepositoryRoot $TestDrive -ModifiedFiles empty.ps1 -Coverage $coverage
        $report.Status | Should -Be 'No executable commands'
        $report.Passed | Should -BeTrue
    }

    It 'returns no results when no source files changed' {
        $coverage = @{ CommandsExecuted = @(); CommandsMissed = @() }
        @(Get-PowerShellFileCoverage -RepositoryRoot $TestDrive -ModifiedFiles @() -Coverage $coverage).Count | Should -Be 0
    }
}

Describe 'Pester module coverage integration' {
    It 'records execution of an imported module' {
        $fixtureRoot = Join-Path $TestDrive 'module-coverage'
        New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $fixtureRoot 'Fixture.psm1') -Value @'
function Get-FixtureValue {
    return 42
}
'@
        Set-Content -LiteralPath (Join-Path $fixtureRoot 'Fixture.Tests.ps1') -Value @'
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Fixture.psm1') -Force
}
Describe 'Module fixture' {
    It 'returns its value' { Get-FixtureValue | Should -Be 42 }
}
'@
        Set-Content -LiteralPath (Join-Path $fixtureRoot 'Run-Fixture.ps1') -Value @'
$ErrorActionPreference = 'Stop'
Import-Module Pester -RequiredVersion 5.7.1
$configuration = New-PesterConfiguration
$configuration.Run.Path = Join-Path $PSScriptRoot 'Fixture.Tests.ps1'
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'None'
$configuration.CodeCoverage.Enabled = $true
$configuration.CodeCoverage.Path = Join-Path $PSScriptRoot 'Fixture.psm1'
$configuration.CodeCoverage.OutputPath = Join-Path $PSScriptRoot 'coverage.xml'
$result = Invoke-Pester -Configuration $configuration
if ($result.FailedCount -gt 0) { throw 'Module fixture failed.' }
$result.CodeCoverage | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $PSScriptRoot 'coverage.json')
'@
        & pwsh -NoProfile -File (Join-Path $fixtureRoot 'Run-Fixture.ps1') | Out-Null
        $LASTEXITCODE | Should -Be 0
        $coverage = Get-Content -LiteralPath (Join-Path $fixtureRoot 'coverage.json') -Raw | ConvertFrom-Json
        $report = Get-PowerShellFileCoverage -RepositoryRoot $fixtureRoot -ModifiedFiles Fixture.psm1 -Coverage $coverage
        $report.TotalCommands | Should -BeGreaterThan 0
        $report.Percent | Should -Be 100
        $report.Passed | Should -BeTrue
    }
}

Describe 'Modified PowerShell file selection' {
    BeforeEach {
        $repositoryRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $repositoryRoot -Force | Out-Null
        & git -C $repositoryRoot init --quiet
        & git -C $repositoryRoot config user.email test@example.com
        & git -C $repositoryRoot config user.name 'Coverage Tests'
        Set-Content -LiteralPath (Join-Path $repositoryRoot 'existing.ps1') -Value "Write-Output 'original'"
        Set-Content -LiteralPath (Join-Path $repositoryRoot 'removed.ps1') -Value "Write-Output 'original'"
        & git -C $repositoryRoot add .
        & git -C $repositoryRoot commit --quiet -m initial
        $script:baseCommit = & git -C $repositoryRoot rev-parse HEAD
    }

    It 'includes changed scripts and modules but excludes tests and data/XML files' {
        Add-Content -LiteralPath (Join-Path $repositoryRoot 'existing.ps1') -Value "Write-Output 'modified'"
        Set-Content -LiteralPath (Join-Path $repositoryRoot 'added.psm1') -Value "Write-Output 'new'"
        & git -C $repositoryRoot add added.psm1
        Set-Content -LiteralPath (Join-Path $repositoryRoot 'untracked.ps1') -Value "Write-Output 'new'"
        Set-Content -LiteralPath (Join-Path $repositoryRoot 'Example.Tests.ps1') -Value ''
        Set-Content -LiteralPath (Join-Path $repositoryRoot 'config.psd1') -Value '@{}'
        Set-Content -LiteralPath (Join-Path $repositoryRoot 'format.ps1xml') -Value '<Configuration />'
        @(Get-ModifiedPowerShellFile -RepositoryRoot $repositoryRoot) | Should -Be @('added.psm1', 'existing.ps1', 'untracked.ps1')
    }

    It 'compares committed changes and includes rename targets rather than deleted files' {
        & git -C $repositoryRoot mv existing.ps1 renamed.psm1
        & git -C $repositoryRoot rm --quiet removed.ps1
        & git -C $repositoryRoot commit --quiet -m rename
        @(Get-ModifiedPowerShellFile -RepositoryRoot $repositoryRoot -BaseRef $script:baseCommit -HeadRef HEAD) | Should -Be @('renamed.psm1')
    }

    It 'checks all sources for the first commit of a new branch' {
        @(Get-ModifiedPowerShellFile -RepositoryRoot $repositoryRoot -BaseRef ('0' * 40) -HeadRef HEAD) | Should -Be @('existing.ps1', 'removed.ps1')
    }

    It 'handles module filenames containing spaces' {
        Set-Content -LiteralPath (Join-Path $repositoryRoot 'module with spaces.psm1') -Value "Write-Output 'new'"
        @(Get-ModifiedPowerShellFile -RepositoryRoot $repositoryRoot) | Should -Be @('module with spaces.psm1')
    }

    It 'uses the previous commit for manual and tag CI runs' {
        Add-Content -LiteralPath (Join-Path $repositoryRoot 'existing.ps1') -Value "Write-Output 'modified'"
        & git -C $repositoryRoot add existing.ps1
        & git -C $repositoryRoot commit --quiet -m update
        @(Get-ModifiedPowerShellFile -RepositoryRoot $repositoryRoot -HeadRef HEAD) | Should -Be @('existing.ps1')
    }
}