BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $script:dependencyChecker = Join-Path $repoRoot '.github/scripts/check-outdated-dependencies.ps1'
    $script:dependencyUpdater = Join-Path $repoRoot '.github/scripts/update-dependency-prs.ps1'
    function git {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        param($Verb, $First)
    }
    function gh {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        param($Verb, $Operation)
    }
}

Describe 'Dependency update automation' {
    BeforeEach {
        $script:savedDependencyOutput = $env:GITHUB_OUTPUT
        $script:savedDependencyExitCode = $global:LASTEXITCODE
        $fixtureDirectory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $fixtureDirectory | Out-Null
        # These entry points use relative config paths; isolate their writes as well as CLI calls.
        Push-Location $fixtureDirectory
        $env:GITHUB_OUTPUT = Join-Path $fixtureDirectory 'outputs.txt'
        Set-Content 'alm-config-defaults.psd1' -Value "@{ scriptDependencies = @{ 'Test.Module' = '1.0.0' } }"
        Set-Content 'outdated-deps.json' -Value '[{"name":"Test.Module","currentVersion":"1.0.0","latestVersion":"2.0.0"}]'
        Mock Find-Module { [pscustomobject]@{ Version = [version]'2.0.0' } }
        Mock git {
            $global:LASTEXITCODE = 0
            switch ($Verb) {
                'rev-parse' { 'copilot/example' }
                'status' { ' M alm-config-defaults.psd1' }
            }
        }
        Mock gh {
            $global:LASTEXITCODE = 0
            if ($Operation -eq 'list') { '[]' }
            elseif ($Operation -eq 'create') { 'https://github.com/example/repo/pull/1' }
        }
    }

    AfterEach {
        Pop-Location
        $env:GITHUB_OUTPUT = $script:savedDependencyOutput
        $global:LASTEXITCODE = $script:savedDependencyExitCode
    }

    It 'reports newer module versions as actionable updates' {
        & $script:dependencyChecker
        (Get-Content 'outdated-deps.json' -Raw | ConvertFrom-Json).latestVersion | Should -Be '2.0.0'
        Get-Content $env:GITHUB_OUTPUT -Raw | Should -Match 'has_updates=true'
    }

    It 'runs the standalone offline dependency workflow smoke test' {
        $originalDirectory = (Get-Location).Path
        & (Join-Path $repoRoot '.github/scripts/test-dependency-workflow.ps1')
        (Get-Location).Path | Should -Be $originalDirectory
    }

    It 'ignores equal or older versions and reports gallery failures without crashing' -ForEach @(
        @{ LatestVersion = '1.0.0'; GalleryFailure = $false }
        @{ LatestVersion = '0.9.0'; GalleryFailure = $false }
        @{ LatestVersion = ''; GalleryFailure = $true }
    ) {
        Mock Find-Module {
            if ($GalleryFailure) { throw 'Gallery unavailable' }
            [pscustomobject]@{ Version = [version]$LatestVersion }
        }
        & $script:dependencyChecker
        Get-Content $env:GITHUB_OUTPUT -Raw | Should -Match 'has_updates=false'
    }

    It 'creates a dependency PR and updates only its configured module version' {
        & $script:dependencyUpdater
        (Import-PowerShellDataFile 'alm-config-defaults.psd1').scriptDependencies['Test.Module'] | Should -Be '2.0.0'
        Should -Invoke git -Times 1 -Exactly -ParameterFilter { $Verb -eq 'push' }
        Should -Invoke gh -Times 1 -Exactly -ParameterFilter { $Operation -eq 'create' }
        Should -Invoke git -Times 1 -Exactly -ParameterFilter { $Verb -eq 'checkout' -and $First -eq 'main' }
    }

    It 'updates an existing dependency PR rather than creating a duplicate' {
        Mock gh { $global:LASTEXITCODE = 0; '[{"number":17,"headRefName":"deps/update-test.module-to-1.5.0","title":"previous"}]' } -ParameterFilter { $Operation -eq 'list' }
        & $script:dependencyUpdater
        Should -Invoke git -Times 1 -Exactly -ParameterFilter { $Verb -eq 'rebase' }
        Should -Invoke gh -Times 1 -Exactly -ParameterFilter { $Operation -eq 'edit' }
        Should -Invoke gh -Times 0 -Exactly -ParameterFilter { $Operation -eq 'create' }
    }

    It 'recovers from an existing branch rebase failure' {
        Mock gh { $global:LASTEXITCODE = 0; '[{"number":17,"headRefName":"deps/update-test.module-to-1.5.0"}]' } -ParameterFilter { $Operation -eq 'list' }
        Mock git { $global:LASTEXITCODE = 1 } -ParameterFilter { $Verb -eq 'rebase' -and $First -ne '--abort' }
        & $script:dependencyUpdater
        Should -Invoke git -Times 1 -Exactly -ParameterFilter { $Verb -eq 'rebase' -and $First -eq '--abort' }
        Should -Invoke gh -Times 1 -Exactly -ParameterFilter { $Operation -eq 'edit' }
    }

    It 'skips stale versions that no longer match configuration' {
        Set-Content 'alm-config-defaults.psd1' -Value "@{ scriptDependencies = @{ 'Test.Module' = '3.0.0' } }"
        & $script:dependencyUpdater
        Should -Invoke git -Times 0 -Exactly -ParameterFilter { $Verb -eq 'push' }
        Should -Invoke gh -Times 0 -Exactly -ParameterFilter { $Operation -eq 'create' }
    }

    It 'does not push when git reports no changes' {
        Mock git { $global:LASTEXITCODE = 0 } -ParameterFilter { $Verb -eq 'status' }
        & $script:dependencyUpdater
        Should -Invoke git -Times 0 -Exactly -ParameterFilter { $Verb -eq 'push' }
    }

    It 'returns failure when a push or PR operation fails' -ForEach @(
        @{ FailedOperation = 'push' }
        @{ FailedOperation = 'create' }
        @{ FailedOperation = 'edit' }
    ) {
        if ($FailedOperation -eq 'push') {
            Mock git { $global:LASTEXITCODE = 1 } -ParameterFilter { $Verb -eq 'push' }
        }
        elseif ($FailedOperation -eq 'edit') {
            Mock gh { $global:LASTEXITCODE = 0; '[{"number":17,"headRefName":"deps/update-test.module-to-1.5.0"}]' } -ParameterFilter { $Operation -eq 'list' }
            Mock gh { $global:LASTEXITCODE = 1 } -ParameterFilter { $Operation -eq 'edit' }
        }
        else {
            Mock gh { $global:LASTEXITCODE = 1 } -ParameterFilter { $Operation -eq 'create' }
        }
        & $script:dependencyUpdater
        $global:LASTEXITCODE | Should -Be 1
    }
}