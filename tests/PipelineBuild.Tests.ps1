BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $script:buildScript = Join-Path $repoRoot 'pipelines/scripts/build.ps1'
    # Capture XML during packing: production removes the generated mapping file before
    # assertions run, so retaining its path alone cannot verify directives or escaping.
    if (-not ('AlmBuildMappingTestCapture' -as [type])) {
        Add-Type -TypeDefinition @'
public static class AlmBuildMappingTestCapture
{
    public static string MappingPath { get; set; }
    public static string MappingXml { get; set; }
}
'@
    }
    function Compress-DataverseSolutionFile {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        [CmdletBinding()]
        param($Path, $OutputPath, $PackageType, $MappingFile)
    }
    function Invoke-TestDotnet {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        param($Verb, $Operation)
    }
    function Invoke-TestPac {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        param($Verb, $Operation, [Parameter(ValueFromRemainingArguments = $true)][string[]]$RemainingArguments)
    }
}

Describe 'Build artifacts and solution-check helpers' {
    BeforeEach {
        $script:savedEnvironment = @{
            GITHUB_STEP_SUMMARY             = $env:GITHUB_STEP_SUMMARY
            TF_BUILD                        = $env:TF_BUILD
            ALM_BUILD_TEST_REAL_PARALLEL    = $env:ALM_BUILD_TEST_REAL_PARALLEL
            ALM_BUILD_TEST_MODULE_PATH      = $env:ALM_BUILD_TEST_MODULE_PATH
            ALM_BUILD_TEST_REQUIRE_PACK_COMMAND = $env:ALM_BUILD_TEST_REQUIRE_PACK_COMMAND
            ALM_BUILD_TEST_PACK_COMMAND_RESOLVED = $env:ALM_BUILD_TEST_PACK_COMMAND_RESOLVED
            ALM_BUILD_TEST_PARALLEL_COMMAND_STAGE = $env:ALM_BUILD_TEST_PARALLEL_COMMAND_STAGE
        }
        $env:ALM_BUILD_TEST_REAL_PARALLEL = $null
        $env:ALM_BUILD_TEST_MODULE_PATH = $null
        $env:ALM_BUILD_TEST_REQUIRE_PACK_COMMAND = $null
        $env:ALM_BUILD_TEST_PACK_COMMAND_RESOLVED = $null
        $env:ALM_BUILD_TEST_PARALLEL_COMMAND_STAGE = $null
        $script:savedExitCode = $global:LASTEXITCODE
        $fixtureRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:sourceDirectory = Join-Path $fixtureRoot 'source'
        $script:artifactDirectory = Join-Path $fixtureRoot 'artifacts'
        New-Item -ItemType Directory -Path (Join-Path $script:sourceDirectory 'data'), (Join-Path $script:sourceDirectory 'solutions/Example'), (Join-Path $script:sourceDirectory 'plugins'), (Join-Path $script:artifactDirectory 'solutions') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:sourceDirectory 'data/example.txt') -Value 'asset'
        Set-Content -LiteralPath (Join-Path $script:sourceDirectory 'plugins/Example.dll') -Value 'plugin'
        Set-Content -LiteralPath (Join-Path $script:sourceDirectory 'plugins/Second.dll') -Value 'plugin'
        Set-Content -LiteralPath (Join-Path $script:sourceDirectory 'alm-config.psd1') -Value @'
@{
    solutions = @(@{ name = 'Example'; solutionCheck = @{} })
    assets = @('data')
    hooks = @{}
}
'@
        $env:GITHUB_STEP_SUMMARY = Join-Path $fixtureRoot 'job-summary.md'
        $env:TF_BUILD = 'True'
        Mock Compress-DataverseSolutionFile {
            if (-not [string]::IsNullOrWhiteSpace($MappingFile)) {
                [AlmBuildMappingTestCapture]::MappingPath = $MappingFile
                [AlmBuildMappingTestCapture]::MappingXml = Get-Content -LiteralPath $MappingFile -Raw
            }
            Set-Content -LiteralPath $OutputPath -Value 'packed solution'
        }
        Mock Copy-Item { New-Item -ItemType Directory -Path $Destination -Force | Out-Null } -ParameterFilter { $Destination -match '[\\/]alm$' }
        Mock Get-Module {
            if ($env:ALM_BUILD_TEST_REQUIRE_PACK_COMMAND -eq 'true' -and $env:ALM_BUILD_TEST_PACK_COMMAND_RESOLVED -ne 'true') {
                throw 'Pack command was not resolved before module lookup.'
            }
            [pscustomobject]@{
                Path        = $env:ALM_BUILD_TEST_MODULE_PATH
                Version     = [version]'3.0.4'
                PrivateData = @{ PSData = @{ Prerelease = 'preview.1' } }
            }
        } -ParameterFilter { $Name -eq 'Rnwood.Dataverse.Data.PowerShell' }
        Mock Get-Command {
            $env:ALM_BUILD_TEST_PACK_COMMAND_RESOLVED = 'true'
            [pscustomobject]@{
                Name = 'Compress-DataverseSolutionFile'
                Parameters = @{ MappingFile = [pscustomobject]@{ Name = 'MappingFile' } }
            }
        } -ParameterFilter { $Name -eq 'Compress-DataverseSolutionFile' }
        Mock Get-Command { [pscustomobject]@{ Source = 'Invoke-TestDotnet' } } -ParameterFilter { $Name -eq 'dotnet' }
        Mock Test-Path { $true } -ParameterFilter { $Path -match '[\\/]\.alm4dataverse[\\/]tools$' }
        Mock Invoke-TestDotnet { $global:LASTEXITCODE = 0; 'microsoft.powerapps.cli.tool 2.7.4+build pac' }
        Mock Get-Command { [pscustomobject]@{ Source = 'Invoke-TestPac' } } -ParameterFilter { $Name -eq 'pac' }
        Mock Invoke-TestPac { $global:LASTEXITCODE = 0; 'Critical: 0'; 'High: 1'; 'Low: 2' }
        # Most cases keep work in Pester's runspace so mocks remain visible. Both overlap cases
        # opt out and supply an importable pack module to exercise actual worker isolation.
        Mock ForEach-Object {
            if ($env:ALM_BUILD_TEST_REAL_PARALLEL -eq 'true') {
                $InputObject | Microsoft.PowerShell.Core\ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel $Parallel
            }
            else {
                if ($null -ne $Parallel -and $null -ne $InputObject -and $InputObject.PSObject.Properties['CommandName']) {
                    $env:ALM_BUILD_TEST_PARALLEL_COMMAND_STAGE = 'true'
                }
                $InputObject | Microsoft.PowerShell.Core\ForEach-Object -Process $Parallel
            }
        } -ParameterFilter { $null -ne $Parallel -and $env:ALM_BUILD_TEST_REAL_PARALLEL -ne 'true' }
    }

    AfterEach {
        foreach ($name in $script:savedEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $script:savedEnvironment[$name])
        }
        $global:LASTEXITCODE = $script:savedExitCode
        Remove-Variable -Name ALM_BUILD_TEST_PAC_PACK_ARGUMENTS -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name ALM_BUILD_TEST_CAPTURED_MAPPING_PATH, ALM_BUILD_TEST_CAPTURED_MAPPING_XML -Scope Global -ErrorAction SilentlyContinue
    }

    It 'packs solutions, copies assets/configuration, and locks actual installed versions' {
        & $script:buildScript -SourceDirectory $script:sourceDirectory -ArtifactStagingDirectory $script:artifactDirectory
        Should -Invoke Compress-DataverseSolutionFile -Times 1 -Exactly -ParameterFilter { $PackageType -eq 'Both' }
        Should -Invoke ForEach-Object -Times 1 -Exactly -ParameterFilter { $null -ne $Parallel -and $ThrottleLimit -eq 2 }
        Test-Path (Join-Path $script:artifactDirectory 'data/example.txt') | Should -BeTrue
        Test-Path (Join-Path $script:artifactDirectory 'alm-config.psd1') | Should -BeTrue
        $lock = Get-Content (Join-Path $script:artifactDirectory 'scriptDependencies.lock.json') -Raw | ConvertFrom-Json -AsHashtable
        $lock.scriptDependencies['Rnwood.Dataverse.Data.PowerShell'] | Should -Be '3.0.4-preview.1'
        $lock.pacCliVersion | Should -Be '2.7.4'
    }

    It 'rejects a missing extra asset' {
        Remove-Item (Join-Path $script:sourceDirectory 'data') -Recurse -Force
        { & $script:buildScript -SourceDirectory $script:sourceDirectory -ArtifactStagingDirectory $script:artifactDirectory } | Should -Throw '*Asset path not found*'
    }

    It 'fails when a required module is not loaded' {
        Mock Get-Module { $null } -ParameterFilter { $Name -eq 'Rnwood.Dataverse.Data.PowerShell' }
        { & $script:buildScript -SourceDirectory $script:sourceDirectory -ArtifactStagingDirectory $script:artifactDirectory } | Should -Throw '*not found in loaded modules*'
    }

    It 'resolves the pack command before checking loaded modules' {
        Set-Content -LiteralPath (Join-Path $script:sourceDirectory 'alm-config.psd1') -Value @'
@{
    solutions = @(@{ name = 'Example' })
    build = @{ parallel = $false }
    assets = @('data')
    hooks = @{}
}
'@
        $env:ALM_BUILD_TEST_REQUIRE_PACK_COMMAND = 'true'
        & $script:buildScript -SourceDirectory $script:sourceDirectory -ArtifactStagingDirectory $script:artifactDirectory
        $env:ALM_BUILD_TEST_PACK_COMMAND_RESOLVED | Should -Be 'true'
        Should -Invoke Get-Command -Times 1 -Exactly -ParameterFilter { $Name -eq 'Compress-DataverseSolutionFile' }
    }

    It 'fails when PAC package version cannot be resolved' {
        Mock Invoke-TestDotnet { $global:LASTEXITCODE = 0; 'No tools installed' }
        { & $script:buildScript -SourceDirectory $script:sourceDirectory -ArtifactStagingDirectory $script:artifactDirectory } | Should -Throw '*Unable to resolve installed PAC CLI package version*'
    }

    It 'parses severities, selects the highest, and rejects unsupported thresholds' {
        . $script:buildScript -SourceDirectory $script:sourceDirectory -ArtifactStagingDirectory $script:artifactDirectory
        $counts = ConvertFrom-SolutionCheckSeverityText -ConsoleText "Critical: 1`nHigh issues: 2`nLow=3"
        $counts.Critical | Should -Be 1
        $counts.High | Should -Be 2
        $counts.Low | Should -Be 3
        Get-SolutionCheckHighestSeverity -SeverityCounts $counts | Should -Be Critical
        Get-SolutionCheckHighestSeverity -SeverityCounts @{ Critical = 0; High = 0; Medium = 0; Low = 0; Informational = 0 } | Should -Be None
        foreach ($severity in @('Critical', 'High', 'Medium', 'Low', 'Informational')) {
            $rank = Convert-SolutionCheckSeverityToRank -Severity $severity
            Convert-SolutionCheckRankToSeverity -Rank $rank | Should -Be $severity
        }
        Convert-SolutionCheckRankToSeverity -Rank 0 | Should -Be None
        { Convert-SolutionCheckSeverityToRank -Severity Unknown } | Should -Throw '*Unknown solution check severity*'
    }

    It 'uses defaults for missing build settings and validates explicit parallel limits' {
        . $script:buildScript -SourceDirectory $script:sourceDirectory -ArtifactStagingDirectory $script:artifactDirectory
        $settings = Get-AlmBuildSetting -Config @{}
        $settings.parallel | Should -BeTrue
        $settings.maxParallel | Should -Be 2
        $settings = Get-AlmBuildSetting -Config @{ build = @{ parallel = $false; maxParallel = 4 } }
        $settings.parallel | Should -BeFalse
        $settings.maxParallel | Should -Be 4
        { Get-AlmBuildSetting -Config @{ build = 'invalid' } } | Should -Throw '*build must be a hashtable*'
        { Get-AlmBuildSetting -Config @{ build = @{ parallel = 'false' } } } | Should -Throw '*build.parallel*'
        { Get-AlmBuildSetting -Config @{ build = @{ maxParallel = 9 } } } | Should -Throw '*build.maxParallel*'
    }

    It 'runs build commands in parallel by default before packing' {
        Set-Content -LiteralPath (Join-Path $script:sourceDirectory 'alm-config.psd1') -Value @'
@{
    solutions = @(@{
        name = 'Example'
        mappings = @(
            @{
                type = 'FileToFile'
                source = 'plugins/Example.dll'
                destination = 'PluginAssemblies/Example.dll'
                buildCommand = @{ executable = 'pwsh'; arguments = @('-NoProfile', '-Command', 'Write-Output first') }
            }
            @{
                type = 'FileToFile'
                source = 'plugins/Second.dll'
                destination = 'PluginAssemblies/Second.dll'
                buildCommand = @{ executable = 'pwsh'; arguments = @('-NoProfile', '-Command', 'Write-Output second') }
            }
        )
    })
    assets = @('data')
    hooks = @{}
}
'@
        & $script:buildScript -SourceDirectory $script:sourceDirectory -ArtifactStagingDirectory $script:artifactDirectory
        $env:ALM_BUILD_TEST_PARALLEL_COMMAND_STAGE | Should -Be 'true'
        Should -Invoke Compress-DataverseSolutionFile -Times 1 -Exactly
    }

    It 'runs an individually sequential build command without a nested parallel stage' {
        Set-Content -LiteralPath (Join-Path $script:sourceDirectory 'alm-config.psd1') -Value @'
@{
    solutions = @(@{
        name = 'Example'
        mappings = @(
            @{
                type = 'FileToFile'
                source = 'plugins/Example.dll'
                destination = 'PluginAssemblies/Example.dll'
                buildCommand = @{ executable = 'pwsh'; arguments = @('-NoProfile', '-Command', 'Write-Output first'); parallel = $false }
            }
        )
    })
    assets = @('data')
    hooks = @{}
}
'@
        & $script:buildScript -SourceDirectory $script:sourceDirectory -ArtifactStagingDirectory $script:artifactDirectory
        Should -Invoke ForEach-Object -Times 1 -Exactly -ParameterFilter { $null -ne $Parallel -and $ThrottleLimit -eq 2 }
        Should -Invoke Compress-DataverseSolutionFile -Times 1 -Exactly
    }

    It 'runs a mapping buildCommand before validating its generated source file' {
        $generatedSource = Join-Path $script:sourceDirectory 'plugins/generated/Generated.dll'
        $buildScript = Join-Path $TestDrive 'create-mapped-plugin.ps1'
        Set-Content -LiteralPath $buildScript -Value @'
param([string]$OutputPath)
New-Item -ItemType Directory -Path (Split-Path $OutputPath -Parent) -Force | Out-Null
Set-Content -LiteralPath $OutputPath -Value built
'@
        $commandExecutable = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        Set-Content -LiteralPath (Join-Path $script:sourceDirectory 'alm-config.psd1') -Value @"
@{
    solutions = @(@{
        name = 'Example'
        mappings = @(
            @{
                type = 'FileToFile'
                source = 'plugins/generated/Generated.dll'
                destination = 'PluginAssemblies/Generated.dll'
                buildCommand = @{
                    executable = '$commandExecutable'
                    arguments = @('-NoProfile', '-File', '$buildScript', '$generatedSource')
                    parallel = `$false
                }
            }
        )
    })
    build = @{ parallel = `$false }
    assets = @('data')
    hooks = @{}
}
"@

        & $script:buildScript -SourceDirectory $script:sourceDirectory -ArtifactStagingDirectory $script:artifactDirectory

        Get-Content -LiteralPath $generatedSource -Raw | Should -Match 'built'
        [AlmBuildMappingTestCapture]::MappingXml | Should -Match 'Generated.dll'
    }

    It 'fails the build when a configured build command exits unsuccessfully' {
        Set-Content -LiteralPath (Join-Path $script:sourceDirectory 'alm-config.psd1') -Value @'
@{
    solutions = @(@{
        name = 'Example'
        mappings = @(
            @{
                type = 'FileToFile'
                source = 'plugins/Example.dll'
                destination = 'PluginAssemblies/Example.dll'
                buildCommand = @{ name = 'command 1'; executable = 'pwsh'; arguments = @('-NoProfile', '-Command', 'exit 7'); parallel = $false }
            }
        )
    })
    assets = @('data')
    hooks = @{}
}
'@
        { & $script:buildScript -SourceDirectory $script:sourceDirectory -ArtifactStagingDirectory $script:artifactDirectory } |
            Should -Throw "*Build command 'command 1' failed for solution 'Example'*"
        Should -Invoke Compress-DataverseSolutionFile -Times 0 -Exactly
    }

    It 'rejects malformed build command arguments before running commands' {
        Set-Content -LiteralPath (Join-Path $script:sourceDirectory 'alm-config.psd1') -Value @'
@{
    solutions = @(@{
        name = 'Example'
        mappings = @(
            @{
                type = 'FileToFile'
                source = 'plugins/Example.dll'
                destination = 'PluginAssemblies/Example.dll'
                buildCommand = @{ executable = 'pwsh'; arguments = 'build' }
            }
        )
    })
    assets = @('data')
    hooks = @{}
}
'@
        { & $script:buildScript -SourceDirectory $script:sourceDirectory -ArtifactStagingDirectory $script:artifactDirectory } |
            Should -Throw '*buildCommand arguments for mapping 1 in solution ''Example'' must be an array of strings*'
        Should -Invoke Compress-DataverseSolutionFile -Times 0 -Exactly
    }

    It 'runs configured parallel build commands concurrently within the build limit' {
        $barrierDirectory = Join-Path $TestDrive 'build-command-barrier'
        New-Item -ItemType Directory -Path $barrierDirectory -Force | Out-Null
        $commandWorkerScript = Join-Path $TestDrive 'build-command-worker.ps1'
        # Child build commands must both reach their markers before either exits; this proves
        # overlap independently of pack-worker concurrency and fails with bounded waiting.
        Set-Content -LiteralPath $commandWorkerScript -Value @'
param([string]$BarrierDirectory, [string]$Name)
$marker = Join-Path $BarrierDirectory "$Name.started"
Set-Content -LiteralPath $marker -Value started
$deadline = [datetime]::UtcNow.AddSeconds(10)
while ([datetime]::UtcNow -lt $deadline) {
    if ((Test-Path (Join-Path $BarrierDirectory 'First.started')) -and (Test-Path (Join-Path $BarrierDirectory 'Second.started'))) {
        exit 0
    }
    Start-Sleep -Milliseconds 25
}
throw "Build command '$Name' did not overlap with the other command."
'@
        $packModulePath = Join-Path $TestDrive 'Rnwood.Dataverse.Data.PowerShell.psm1'
        # This pack stub only completes the pipeline; the separate worker script above is
        # the concurrency probe, unlike the pack-overlap fixture later in this suite.
        Set-Content -LiteralPath $packModulePath -Value @'
function Compress-DataverseSolutionFile {
    param($Path, $OutputPath, $PackageType, $MappingFile)
    Set-Content -LiteralPath $OutputPath -Value packed
}
Export-ModuleMember -Function Compress-DataverseSolutionFile
'@
        $commandExecutable = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        Set-Content -LiteralPath (Join-Path $script:sourceDirectory 'alm-config.psd1') -Value @"
@{
    solutions = @(@{
        name = 'Example'
        mappings = @(
            @{
                type = 'FileToFile'
                source = 'plugins/Example.dll'
                destination = 'PluginAssemblies/Example.dll'
                buildCommand = @{ executable = '$commandExecutable'; arguments = @('-NoProfile', '-File', '$commandWorkerScript', '$barrierDirectory', 'First') }
            }
            @{
                type = 'FileToFile'
                source = 'plugins/Second.dll'
                destination = 'PluginAssemblies/Second.dll'
                buildCommand = @{ executable = '$commandExecutable'; arguments = @('-NoProfile', '-File', '$commandWorkerScript', '$barrierDirectory', 'Second') }
            }
        )
    })
    assets = @('data')
    hooks = @{}
}
"@
        $previousRealParallelSetting = $env:ALM_BUILD_TEST_REAL_PARALLEL
        $previousModulePath = $env:ALM_BUILD_TEST_MODULE_PATH
        try {
            $env:ALM_BUILD_TEST_MODULE_PATH = $packModulePath
            $env:ALM_BUILD_TEST_REAL_PARALLEL = 'true'
            & $script:buildScript -SourceDirectory $script:sourceDirectory -ArtifactStagingDirectory $script:artifactDirectory
        }
        finally {
            $env:ALM_BUILD_TEST_REAL_PARALLEL = $previousRealParallelSetting
            $env:ALM_BUILD_TEST_MODULE_PATH = $previousModulePath
        }

        Test-Path (Join-Path $script:artifactDirectory 'solutions/Example.zip') | Should -BeTrue
    }

    It 'fails before packing when the installed module lacks mapping support' {
        Set-Content -LiteralPath (Join-Path $script:sourceDirectory 'alm-config.psd1') -Value @'
@{
    solutions = @(@{
        name = 'Example'
        mappings = @(
            @{ type = 'FileToFile'; source = 'plugins/Example.dll'; destination = 'PluginAssemblies\Example.dll' }
        )
    })
    build = @{ parallel = $false }
    assets = @('data')
    hooks = @{}
}
'@
        Mock Get-Command {
            [pscustomobject]@{ Name = 'Compress-DataverseSolutionFile' }
        } -ParameterFilter { $Name -eq 'Compress-DataverseSolutionFile' }

        { & $script:buildScript -SourceDirectory $script:sourceDirectory -ArtifactStagingDirectory $script:artifactDirectory } |
            Should -Throw '*Solution mappings require a version of Rnwood.Dataverse.Data.PowerShell that supports -MappingFile*'
        Should -Invoke Compress-DataverseSolutionFile -Times 0 -Exactly
        Should -Invoke Invoke-TestPac -Times 0 -Exactly
    }

    It 'generates mapping XML in entry order with all supported directive types' {
        # Ampersands force XML attribute escaping as well as ordered directive generation.
        $pluginDirectory = Join-Path $script:sourceDirectory 'plugins/Source&Metadata'
        $pluginFile = Join-Path $script:sourceDirectory 'plugins/bin&build/Example.dll'
        $webResourceDirectory = Join-Path $script:sourceDirectory 'webresources'
        New-Item -ItemType Directory -Path $pluginDirectory, (Split-Path $pluginFile -Parent), $webResourceDirectory -Force | Out-Null
        Set-Content -LiteralPath $pluginFile -Value 'plugin'
        Set-Content -LiteralPath (Join-Path $script:sourceDirectory 'alm-config.psd1') -Value @'
@{
    solutions = @(@{
        name = 'Example'
        mappings = @(
            @{ type = 'FileToFile'; source = 'plugins/bin&build/Example.dll'; destination = 'PluginAssemblies\Example.dll' }
            @{ type = 'Folder'; source = 'plugins/Source&Metadata'; destination = 'PluginAssemblies\Metadata' }
            @{ type = 'FileToPath'; source = 'webresources'; destination = 'WebResources\**\*.*' }
        )
    })
    build = @{ parallel = $false }
    assets = @('data')
    hooks = @{}
}
'@
        Mock Get-Command {
            [pscustomobject]@{
                Name = 'Compress-DataverseSolutionFile'
                Parameters = @{ MappingFile = [pscustomobject]@{ Name = 'MappingFile' } }
            }
        } -ParameterFilter { $Name -eq 'Compress-DataverseSolutionFile' }

        & $script:buildScript -SourceDirectory $script:sourceDirectory -ArtifactStagingDirectory $script:artifactDirectory

        Should -Invoke Compress-DataverseSolutionFile -Times 1 -Exactly -ParameterFilter { -not [string]::IsNullOrWhiteSpace($MappingFile) }
        Should -Invoke Invoke-TestPac -Times 0 -Exactly
        [AlmBuildMappingTestCapture]::MappingXml | Should -Match '<Mappings>'
        [AlmBuildMappingTestCapture]::MappingXml | Should -Match 'bin&amp;build'
        $mappingXml = [xml][AlmBuildMappingTestCapture]::MappingXml
        $mappingTypes = @($mappingXml.Mappings.ChildNodes | ForEach-Object { $_.LocalName }) -join ','
        $mappingTypes | Should -Be 'FileToFile,Folder,FileToPath'
        $mappingXml.Mappings.FileToFile.GetAttribute('to') | Should -Be ([System.IO.Path]::GetFullPath($pluginFile))
        $expectedPluginDestination = [System.IO.Path]::GetFullPath((Join-Path $script:sourceDirectory 'solutions/Example/PluginAssemblies/Example.dll'))
        $mappingXml.Mappings.FileToFile.GetAttribute('map') | Should -Be $expectedPluginDestination
        Test-Path -LiteralPath ([AlmBuildMappingTestCapture]::MappingPath) | Should -BeFalse
    }

    It 'rejects the removed mappingFile setting before packing' {
        Set-Content -LiteralPath (Join-Path $script:sourceDirectory 'alm-config.psd1') -Value @'
@{
    solutions = @(@{ name = 'Example'; mappingFile = 'solutions/Example/Missing.xml' })
    build = @{ parallel = $false }
    assets = @('data')
    hooks = @{}
}
'@
        { & $script:buildScript -SourceDirectory $script:sourceDirectory -ArtifactStagingDirectory $script:artifactDirectory } |
            Should -Throw '*mappingFile for solution ''Example'' is no longer supported*'
        Should -Invoke Compress-DataverseSolutionFile -Times 0 -Exactly
    }

    It 'rejects separate solution-level build commands' {
        Set-Content -LiteralPath (Join-Path $script:sourceDirectory 'alm-config.psd1') -Value @'
@{
    solutions = @(@{ name = 'Example'; buildCommands = @() })
    build = @{ parallel = $false }
    assets = @('data')
    hooks = @{}
}
'@
        { & $script:buildScript -SourceDirectory $script:sourceDirectory -ArtifactStagingDirectory $script:artifactDirectory } |
            Should -Throw '*buildCommands for solution ''Example'' are no longer supported as a separate setting*'
        Should -Invoke Compress-DataverseSolutionFile -Times 0 -Exactly
    }

    It 'rejects unsupported mapping directive types before packing' {
        Set-Content -LiteralPath (Join-Path $script:sourceDirectory 'alm-config.psd1') -Value @'
@{
    solutions = @(@{
        name = 'Example'
        mappings = @(
            @{ type = 'File'; source = 'plugins/Example.dll'; destination = 'PluginAssemblies/Example.dll' }
        )
    })
    build = @{ parallel = $false }
    assets = @('data')
    hooks = @{}
}
'@
        { & $script:buildScript -SourceDirectory $script:sourceDirectory -ArtifactStagingDirectory $script:artifactDirectory } |
            Should -Throw '*Unsupported mappings type ''File'' for solution ''Example''*'
        Should -Invoke Compress-DataverseSolutionFile -Times 0 -Exactly
    }

    It 'rejects mapping sources that do not exist before packing' {
        Set-Content -LiteralPath (Join-Path $script:sourceDirectory 'alm-config.psd1') -Value @'
@{
    solutions = @(@{
        name = 'Example'
        mappings = @(
            @{ type = 'FileToFile'; source = 'plugins/Missing.dll'; destination = 'PluginAssemblies\Missing.dll' }
        )
    })
    build = @{ parallel = $false }
    assets = @('data')
    hooks = @{}
}
'@
        { & $script:buildScript -SourceDirectory $script:sourceDirectory -ArtifactStagingDirectory $script:artifactDirectory } |
            Should -Throw '*Mapping source file not found for solution ''Example''*'
        Should -Invoke Compress-DataverseSolutionFile -Times 0 -Exactly
    }

    It 'packs sequentially when build parallelization is disabled' {
        Set-Content -LiteralPath (Join-Path $script:sourceDirectory 'alm-config.psd1') -Value @'
@{
    solutions = @(@{ name = 'Example' })
    build = @{ parallel = $false; maxParallel = 4 }
    assets = @('data')
    hooks = @{}
}
'@
        & $script:buildScript -SourceDirectory $script:sourceDirectory -ArtifactStagingDirectory $script:artifactDirectory
        Should -Invoke ForEach-Object -Times 0 -Exactly -ParameterFilter { $null -ne $Parallel }
        Should -Invoke Compress-DataverseSolutionFile -Times 1 -Exactly
    }

    It 'rejects duplicate solution names without starting pack work' {
        Set-Content -LiteralPath (Join-Path $script:sourceDirectory 'alm-config.psd1') -Value @'
@{
    solutions = @(@{ name = 'Example' }, @{ name = 'example' })
    assets = @('data')
    hooks = @{}
}
'@
        { & $script:buildScript -SourceDirectory $script:sourceDirectory -ArtifactStagingDirectory $script:artifactDirectory } |
            Should -Throw '*Duplicate solution in build configuration: example*'
        Should -Invoke Compress-DataverseSolutionFile -Times 0 -Exactly
        Should -Invoke ForEach-Object -Times 0 -Exactly -ParameterFilter { $null -ne $Parallel }
    }

    It 'packs multiple solutions concurrently through real parallel runspaces' {
        $solutionRoot = Join-Path $script:sourceDirectory 'solutions'
        New-Item -ItemType Directory -Path (Join-Path $solutionRoot 'First'), (Join-Path $solutionRoot 'Second') -Force | Out-Null
        $barrierDirectory = Join-Path $TestDrive 'pack-worker-barrier'
        New-Item -ItemType Directory -Path $barrierDirectory -Force | Out-Null
        $script:packWorkerModulePath = Join-Path $TestDrive 'Rnwood.Dataverse.Data.PowerShell.psm1'
        # Each embedded pack invocation must observe its peer's marker before returning;
        # sequential execution therefore fails instead of passing a timing-only assertion.
        Set-Content -LiteralPath $script:packWorkerModulePath -Value @"
function Compress-DataverseSolutionFile {
    param([string]`$Path, [string]`$OutputPath, [string]`$PackageType)
    `$solutionName = Split-Path -Path `$Path -Leaf
    Set-Content -LiteralPath (Join-Path '$barrierDirectory' "`$solutionName.started") -Value started
    `$deadline = [datetime]::UtcNow.AddSeconds(15)
    while ([datetime]::UtcNow -lt `$deadline) {
        if ((Test-Path (Join-Path '$barrierDirectory' 'First.started')) -and (Test-Path (Join-Path '$barrierDirectory' 'Second.started'))) {
            Set-Content -LiteralPath `$OutputPath -Value "packed `$solutionName"
            return
        }
        Start-Sleep -Milliseconds 25
    }
    throw "Pack worker for '`$solutionName' did not overlap with the other solution."
}
Export-ModuleMember -Function Compress-DataverseSolutionFile
"@
        Set-Content -LiteralPath (Join-Path $script:sourceDirectory 'alm-config.psd1') -Value @'
@{
    solutions = @(@{ name = 'First' }, @{ name = 'Second' })
    assets = @('data')
    hooks = @{}
}
'@

        $previousRealParallelSetting = $env:ALM_BUILD_TEST_REAL_PARALLEL
        $previousModulePath = $env:ALM_BUILD_TEST_MODULE_PATH
        try {
            $env:ALM_BUILD_TEST_MODULE_PATH = $script:packWorkerModulePath
            $env:ALM_BUILD_TEST_REAL_PARALLEL = 'true'
            & $script:buildScript -SourceDirectory $script:sourceDirectory -ArtifactStagingDirectory $script:artifactDirectory
        }
        finally {
            $env:ALM_BUILD_TEST_REAL_PARALLEL = $previousRealParallelSetting
            $env:ALM_BUILD_TEST_MODULE_PATH = $previousModulePath
        }

        (Get-Content -LiteralPath (Join-Path $script:artifactDirectory 'solutions/First.zip') -Raw).Trim() | Should -Be 'packed First'
        (Get-Content -LiteralPath (Join-Path $script:artifactDirectory 'solutions/Second.zip') -Raw).Trim() | Should -Be 'packed Second'
    }

    It 'resolves unique exclusions and skips null, empty, and unmatched patterns' {
        . $script:buildScript -SourceDirectory $script:sourceDirectory -ArtifactStagingDirectory $script:artifactDirectory
        $filePath = Join-Path $script:sourceDirectory 'solutions/Example/script.js'
        Set-Content -LiteralPath $filePath -Value 'content'
        $files = @(Resolve-SolutionCheckExcludedFile -SourceDirectory $script:sourceDirectory -SolutionName Example -Patterns @($null, '', '*.js', $filePath, 'missing/*.js'))
        $files | Should -Be @($filePath)
    }

    It 'writes rule overrides while preserving path overrides and rejecting invalid values' {
        . $script:buildScript -SourceDirectory $script:sourceDirectory -ArtifactStagingDirectory $script:artifactDirectory
        ConvertTo-SolutionCheckRuleOverrideFile -ReportRoot $script:artifactDirectory -SolutionName Example -RuleLevelOverride $null | Should -Be ''
        ConvertTo-SolutionCheckRuleOverrideFile -ReportRoot $script:artifactDirectory -SolutionName Example -RuleLevelOverride '' | Should -Be ''
        ConvertTo-SolutionCheckRuleOverrideFile -ReportRoot $script:artifactDirectory -SolutionName Example -RuleLevelOverride 'existing.json' | Should -Be 'existing.json'
        $overridePath = ConvertTo-SolutionCheckRuleOverrideFile -ReportRoot $script:artifactDirectory -SolutionName Example -RuleLevelOverride @{ Id = 'rule'; OverrideLevel = 'High' }
        (Get-Content $overridePath -Raw | ConvertFrom-Json).Id | Should -Be rule
        $overridePath = ConvertTo-SolutionCheckRuleOverrideFile -ReportRoot $script:artifactDirectory -SolutionName Example -RuleLevelOverride @(@{ Id = 'first' }, @{ Id = 'second' })
        @(Get-Content $overridePath -Raw | ConvertFrom-Json).Count | Should -Be 2
        { ConvertTo-SolutionCheckRuleOverrideFile -ReportRoot $script:artifactDirectory -SolutionName Example -RuleLevelOverride 42 } | Should -Throw '*must be a JSON file path*'
    }

    It 'writes readable and machine-readable checker summaries for success, findings, and errors' {
        . $script:buildScript -SourceDirectory $script:sourceDirectory -ArtifactStagingDirectory $script:artifactDirectory
        $results = @(
            foreach ($status in @('passed', 'failed', 'error')) {
                @{ SolutionName = $status; Error = $status -eq 'error'; ThresholdBreached = $status -eq 'failed'; FailThreshold = 'High'; HighestSeverity = 'None'; SeverityCounts = @{ Critical = 0; High = 0; Medium = 0; Low = 0; Informational = 0 } }
            }
        )
        $summaryPath = Join-Path $script:artifactDirectory 'summary.md'
        $jsonPath = Join-Path $script:artifactDirectory 'summary.json'
        Write-SolutionCheckSummary -Results $results -SummaryPath $summaryPath -SummaryJsonPath $jsonPath
        $summary = Get-Content $summaryPath -Raw
        $summary | Should -Match 'Passed'
        $summary | Should -Match 'Failed'
        $summary | Should -Match 'Error'
        (Get-Content $jsonPath -Raw | ConvertFrom-Json).results.Count | Should -Be 3
        Get-Content $env:GITHUB_STEP_SUMMARY -Raw | Should -Be $summary
    }

    It 'checks enabled solutions with configured exclusions, overrides, and threshold' {
        Set-Content -LiteralPath (Join-Path $script:sourceDirectory 'solutions/Example/script.js') -Value 'script'
        Set-Content -LiteralPath (Join-Path $script:sourceDirectory 'alm-config.psd1') -Value @'
@{
    solutions = @(@{ name = 'Example'; solutionCheck = @{} }, @{ name = 'Disabled'; solutionCheck = @{ enabled = $false } })
    solutionCheck = @{ enabled = $true; maxParallel = 0; geo = 'UnitedStates'; ruleSet = 'rule-set'; excludedFiles = '*.js'; ruleLevelOverride = @{ Id = 'rule'; OverrideLevel = 'Low' }; failThreshold = 'Critical' }
    assets = @('data')
    hooks = @{}
}
'@
        & $script:buildScript -SourceDirectory $script:sourceDirectory -ArtifactStagingDirectory $script:artifactDirectory
        Should -Invoke ForEach-Object -Times 1 -Exactly -ParameterFilter { $null -ne $Parallel -and $ThrottleLimit -eq 1 }
        Should -Invoke Invoke-TestPac -Times 1 -Exactly
        $report = Get-Content (Join-Path $script:artifactDirectory 'solution-check/solution-check-summary.json') -Raw | ConvertFrom-Json
        $report.results.Count | Should -Be 1
        $report.results[0].HighestSeverity | Should -Be High
        $report.results[0].ThresholdBreached | Should -BeFalse
        Test-Path (Join-Path $script:artifactDirectory 'solution-check/Example/pac-solution-check.log') | Should -BeTrue
    }

    It 'fails checker findings at or above the configured severity' {
        Set-Content -LiteralPath (Join-Path $script:sourceDirectory 'alm-config.psd1') -Value "@{ solutions = @(@{ name = 'Example'; solutionCheck = @{} }); solutionCheck = @{ enabled = `$true; failThreshold = 'High'; ruleSet = 'none'; excludedFiles = @('*.js') }; hooks = @{} }"
        { & $script:buildScript -SourceDirectory $script:sourceDirectory -ArtifactStagingDirectory $script:artifactDirectory } | Should -Throw '*Solution check*'
        $report = Get-Content (Join-Path $script:artifactDirectory 'solution-check/solution-check-summary.json') -Raw | ConvertFrom-Json
        $report.results[0].ThresholdBreached | Should -BeTrue
    }

    It 'fails and records checker errors instead of passing them as clean checks' {
        Set-Content -LiteralPath (Join-Path $script:sourceDirectory 'alm-config.psd1') -Value "@{ solutions = @(@{ name = 'Example'; solutionCheck = @{} }); solutionCheck = @{ enabled = `$true }; hooks = @{} }"
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'pac' }
        { & $script:buildScript -SourceDirectory $script:sourceDirectory -ArtifactStagingDirectory $script:artifactDirectory } | Should -Throw '*Solution check*'
        $report = Get-Content (Join-Path $script:artifactDirectory 'solution-check/solution-check-summary.json') -Raw | ConvertFrom-Json
        $report.results[0].Error | Should -BeTrue
        $report.results[0].ErrorMessage | Should -Match 'not found on PATH'
    }

    It 'rejects unsupported exclusion configuration before calling PAC' {
        Set-Content -LiteralPath (Join-Path $script:sourceDirectory 'alm-config.psd1') -Value "@{ solutions = @(@{ name = 'Example'; solutionCheck = @{} }); solutionCheck = @{ enabled = `$true; excludedFiles = 42 }; hooks = @{} }"
        { & $script:buildScript -SourceDirectory $script:sourceDirectory -ArtifactStagingDirectory $script:artifactDirectory } | Should -Throw '*excludedFiles*must be a string or array*'
        Should -Invoke Invoke-TestPac -Times 0 -Exactly
    }
}