BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repoRoot 'pipelines/scripts/common.ps1')
}

Describe 'Validation orchestration and coverage enforcement' {
    BeforeEach {
        $script:savedValidationExitCode = $global:LASTEXITCODE
        $script:savedValidationSummary = $env:GITHUB_STEP_SUMMARY
        $env:GITHUB_STEP_SUMMARY = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.md')
        Mock Import-PowerShellDataFile {
            @{ Tools = @{}; AnalyzerSettings = @{ IncludeRules = @('PSAvoidAssignmentToAutomaticVariable') }; Exceptions = @() }
        } -ParameterFilter { $Path -like '*powershell-validation.psd1' }
        Mock Invoke-ScriptAnalyzer { @() }
        Mock git {
            $global:LASTEXITCODE = 0
            if ($args -contains 'diff') { return "pipelines/scripts/common.ps1`0" }
            if ($args -contains 'ls-files' -and $args -notcontains '-z') {
                'pipelines/scripts/common.ps1'
                'alm-config-defaults.psd1'
            }
        }
        Mock Invoke-Pester {
            [pscustomobject]@{
                TotalCount = 4; FailedCount = 0; FailedContainersCount = 0; PassedCount = 4
                CodeCoverage = @{ CommandsExecuted = @([pscustomobject]@{ File = (Join-Path $repoRoot 'pipelines/scripts/common.ps1') }); CommandsMissed = @() }
            }
        }
        Mock Set-Content {
            Microsoft.PowerShell.Management\Set-Content -LiteralPath (Join-Path $TestDrive ([IO.Path]::GetFileName($LiteralPath))) -Value $Value
        } -ParameterFilter { $LiteralPath -match '[\\/]TestResults[\\/]' }
    }

    AfterEach {
        $global:LASTEXITCODE = $script:savedValidationExitCode
        $env:GITHUB_STEP_SUMMARY = $script:savedValidationSummary
    }

    It 'configures executable coverage, writes reports, and passes covered changes' {
        $output = & (Join-Path $repoRoot 'scripts/Test-PowerShell.ps1')
        $output | Should -Contain 'Passed 4 PowerShell tests.'
        Should -Invoke Invoke-Pester -Times 1 -Exactly -ParameterFilter {
            $Configuration.CodeCoverage.Enabled.Value -and $Configuration.CodeCoverage.CoveragePercentTarget.Value -eq 0 -and
            -not $Configuration.CodeCoverage.UseBreakpoints.Value -and
            $Configuration.TestResult.OutputFormat.Value -eq 'NUnitXml'
        }
        (Get-Content (Join-Path $TestDrive 'coverage-files.json') -Raw | ConvertFrom-Json).Percent | Should -Be 100
        Test-Path (Join-Path $TestDrive 'coverage-all-files.json') | Should -BeTrue
        Get-Content $env:GITHUB_STEP_SUMMARY -Raw | Should -Match 'common.ps1'
    }

    It 'writes coverage reports before failing under-covered changed files' {
        Mock Invoke-Pester {
            [pscustomobject]@{
                TotalCount = 4; FailedCount = 0; FailedContainersCount = 0; PassedCount = 4
                CodeCoverage = @{ CommandsExecuted = @(); CommandsMissed = @([pscustomobject]@{ File = (Join-Path $repoRoot 'pipelines/scripts/common.ps1') }) }
            }
        }
        { & (Join-Path $repoRoot 'scripts/Test-PowerShell.ps1') } | Should -Throw '*below 65%*common.ps1*'
        (Get-Content (Join-Path $TestDrive 'coverage-files.json') -Raw | ConvertFrom-Json).Passed | Should -BeFalse
        Test-Path (Join-Path $TestDrive 'coverage-summary.md') | Should -BeTrue
    }

    It 'rejects zero or failed tests even when coverage would pass' -ForEach @(
        @{ Total = 0; Failed = 0; Containers = 0 }
        @{ Total = 1; Failed = 1; Containers = 0 }
        @{ Total = 1; Failed = 0; Containers = 1 }
    ) {
        Mock Invoke-Pester {
            [pscustomobject]@{
                TotalCount = $Total; FailedCount = $Failed; FailedContainersCount = $Containers; PassedCount = 0
                CodeCoverage = @{ CommandsExecuted = @(); CommandsMissed = @() }
            }
        }
        { & (Join-Path $repoRoot 'scripts/Test-PowerShell.ps1') } | Should -Throw '*Pester failed*'
        Test-Path (Join-Path $TestDrive 'coverage-files.json') | Should -BeTrue
    }

    It 'fails immediately if Git cannot enumerate repository files' {
        Mock git { $global:LASTEXITCODE = 1 }
        { & (Join-Path $repoRoot 'scripts/Test-PowerShell.ps1') } | Should -Throw '*Could not enumerate repository files*'
        Should -Invoke Invoke-Pester -Times 0 -Exactly
    }

    It 'attributes name-only diagnostic extents to the nearest owning function' -ForEach @(
        @{ FunctionName = 'New-SolutionCheckSeverityCount' }
        @{ FunctionName = 'New-Count' }
    ) {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'pipelines/scripts/build.ps1'), [ref]$tokens, [ref]$parseErrors)
        $definition = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $FunctionName
        }, $true)
        $startOffset = $definition.Extent.StartOffset + 'function '.Length
        $diagnostic = [pscustomobject]@{
            Extent = [pscustomobject]@{ Text = $FunctionName; StartOffset = $startOffset; EndOffset = $startOffset + $FunctionName.Length }
            Line = $definition.Extent.StartLineNumber
            RuleName = 'PSUseShouldProcessForStateChangingFunctions'
            Message = 'Constructor finding'
        }
        Mock Invoke-ScriptAnalyzer { $diagnostic } -ParameterFilter { $Path -like '*build.ps1' }
        Mock Import-PowerShellDataFile {
            @{ Tools = @{}; AnalyzerSettings = @{}; Exceptions = @(
                @{ Path = 'pipelines/scripts/build.ps1'; Rule = $diagnostic.RuleName; Function = $FunctionName; Source = $FunctionName; Reason = 'In-memory constructor.' }
            ) }
        } -ParameterFilter { $Path -like '*powershell-validation.psd1' }
        Mock git {
            $global:LASTEXITCODE = 0
            if ($args -contains 'diff') { return "pipelines/scripts/common.ps1`0" }
            if ($args -contains 'ls-files' -and $args -notcontains '-z') { 'pipelines/scripts/common.ps1'; 'pipelines/scripts/build.ps1' }
        }
        & (Join-Path $repoRoot 'scripts/Test-PowerShell.ps1') | Should -Contain 'Passed 4 PowerShell tests.'
        Should -Invoke Invoke-Pester -Times 1 -Exactly
    }

    It 'reports file-level analyzer diagnostics that have no source extent' {
        Mock Invoke-ScriptAnalyzer {
            [pscustomobject]@{ Extent = $null; Line = $null; RuleName = 'PSUseBOMForUnicodeEncodedFile'; Message = 'Missing BOM encoding' }
        }
        { & (Join-Path $repoRoot 'scripts/Test-PowerShell.ps1') } | Should -Throw '*common.ps1:<file>: PSUseBOMForUnicodeEncodedFile: Missing BOM encoding*'
        Should -Invoke Invoke-Pester -Times 0 -Exactly
    }
}

Describe 'Repository analyzer policy' {
    It 'has no unused-parameter, naming, or output-type findings' {
        $policy = Import-PowerShellDataFile (Join-Path $repoRoot 'scripts/powershell-validation.psd1')
        $paths = @(& git -C $repoRoot ls-files --cached --others --exclude-standard |
            Where-Object { $_ -match '\.(ps1|psm1|psd1)$' } | Sort-Object -Unique)
        $findings = @(
            foreach ($path in $paths) {
                Invoke-ScriptAnalyzer -Path (Join-Path $repoRoot $path) -Settings $policy.AnalyzerSettings |
                    Where-Object { $_.RuleName -in @('PSReviewUnusedParameter','PSUseSingularNouns','PSUseApprovedVerbs','PSUseOutputTypeCorrectly') }
            }
        )
        $findings | Should -BeNullOrEmpty
    }

    It 'limits blanket unused-parameter suppressions to empty mock command stubs' {
        $paths = @(& git -C $repoRoot ls-files --cached --others --exclude-standard |
            Where-Object { $_ -match '\.(ps1|psm1)$' } | Sort-Object -Unique)
        foreach ($path in $paths) {
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $path), [ref]$tokens, [ref]$parseErrors)
            foreach ($paramBlock in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.ParamBlockAst] }, $true)) {
                foreach ($attribute in $paramBlock.Attributes) {
                    if ($attribute.TypeName.FullName -notmatch 'SuppressMessage(Attribute)?$' -or
                        $attribute.PositionalArguments.Count -lt 2 -or
                        $attribute.PositionalArguments[0].Value -ne 'PSReviewUnusedParameter') { continue }
                    @($attribute.NamedArguments | Where-Object { $_.ArgumentName -eq 'Justification' -and -not [string]::IsNullOrWhiteSpace($_.Argument.Value) }).Count | Should -Be 1
                    if ([string]::IsNullOrWhiteSpace($attribute.PositionalArguments[1].Value)) {
                        $path | Should -BeLike 'tests/*'
                        $paramBlock.Parent.Parent | Should -BeOfType ([System.Management.Automation.Language.FunctionDefinitionAst])
                        $paramBlock.Parent.EndBlock.Statements.Count | Should -Be 0
                    }
                }
            }
        }
    }

    It 'matches each reviewed state-change exception exactly once without disabling the rule' {
        $policy = Import-PowerShellDataFile (Join-Path $repoRoot 'scripts/powershell-validation.psd1')
        $exceptions = @($policy.Exceptions | Where-Object { $_.Rule -eq 'PSUseShouldProcessForStateChangingFunctions' })
        $exceptions.Count | Should -Be 18
        foreach ($group in $exceptions | Group-Object Path) {
            $diagnostics = @(Invoke-ScriptAnalyzer -Path (Join-Path $repoRoot $group.Name) -Settings $policy.AnalyzerSettings |
                Where-Object { $_.RuleName -eq 'PSUseShouldProcessForStateChangingFunctions' })
            $diagnostics.Count | Should -Be $group.Count
            foreach ($exception in $group.Group) {
                $exception.Source | Should -Be $exception.Function
                @($diagnostics | Where-Object { $_.Extent.Text -eq $exception.Source }).Count | Should -Be 1
                $exception.Reason | Should -Not -BeNullOrEmpty
            }
        }
        @(Invoke-ScriptAnalyzer -ScriptDefinition 'function New-UnreviewedResource { Set-Content resource.txt example }' -Settings $policy.AnalyzerSettings |
            Where-Object { $_.RuleName -eq 'PSUseShouldProcessForStateChangingFunctions' }).Count | Should -Be 1
    }

    It 'uses default rules with only the intentional host-output exclusion' {
        $policy = Import-PowerShellDataFile (Join-Path $repoRoot 'scripts/powershell-validation.psd1')
        $policy.AnalyzerSettings.IncludeDefaultRules | Should -BeTrue
        $policy.AnalyzerSettings.ContainsKey('IncludeRules') | Should -BeFalse
        $policy.AnalyzerSettings.ExcludeRules | Should -Be @('PSAvoidUsingWriteHost')
    }

    It 'reports naming, unused parameters, and empty catches without rejecting host output' {
        $policy = Import-PowerShellDataFile (Join-Path $repoRoot 'scripts/powershell-validation.psd1')
        $definition = 'function Parse-Things { param($Unused) Write-Host "status"; try { Get-Item missing } catch {} }'
        $rules = @(Invoke-ScriptAnalyzer -ScriptDefinition $definition -Settings $policy.AnalyzerSettings | Select-Object -ExpandProperty RuleName)
        $rules | Should -Contain PSUseApprovedVerbs
        $rules | Should -Contain PSReviewUnusedParameter
        $rules | Should -Contain PSAvoidUsingEmptyCatchBlock
        $rules | Should -Not -Contain PSAvoidUsingWriteHost
    }
}

Describe 'Validation gate enforcement' {
    BeforeEach {
        $fixtureRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
        $sourcePaths = @(& git -C $repoRoot ls-files --cached --others --exclude-standard) |
            Where-Object { $_ -match '\.(ps1|psm1|psd1|psrc|pssc|ps1xml|cdxml)$' } | Sort-Object -Unique
        foreach ($relativePath in $sourcePaths) {
            $destinationPath = Join-Path $fixtureRoot $relativePath
            New-Item -ItemType Directory -Path (Split-Path $destinationPath -Parent) -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $repoRoot $relativePath) -Destination $destinationPath -Force
        }
        & git -C $fixtureRoot init --quiet
        $LASTEXITCODE | Should -Be 0
        Set-Content -LiteralPath (Join-Path $fixtureRoot 'validator-entry.ps1') -Value @'
param([string]$ValidatorPath)
try {
    & $ValidatorPath
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
'@
    }

    It 'fails on an unexpected analyzer finding' {
        Set-Content -LiteralPath (Join-Path $fixtureRoot 'regression-probe.ps1') -Value '$matches = @()'
        $output = @(& pwsh -NoProfile -File (Join-Path $fixtureRoot 'validator-entry.ps1') -ValidatorPath (Join-Path $fixtureRoot 'scripts/Test-PowerShell.ps1') 2>&1)
        $LASTEXITCODE | Should -Not -Be 0
        ($output | Out-String) | Should -Match 'PSAvoidAssignmentToAutomaticVariable'
    }

    It 'fails when a documented exception no longer matches' {
        $setupPath = Join-Path $fixtureRoot 'setup-azdo.ps1'
        $content = (Get-Content -LiteralPath $setupPath -Raw).Replace(
            'ConvertTo-SecureString -String $adoAccessToken.Token -AsPlainText -Force', '$null')
        Set-Content -LiteralPath $setupPath -Value $content
        $output = @(& pwsh -NoProfile -File (Join-Path $fixtureRoot 'validator-entry.ps1') -ValidatorPath (Join-Path $fixtureRoot 'scripts/Test-PowerShell.ps1') 2>&1)
        $LASTEXITCODE | Should -Not -Be 0
        ($output | Out-String) | Should -Match 'Analyzer exception must match exactly one\s+finding;\s+found 0'
    }
}
