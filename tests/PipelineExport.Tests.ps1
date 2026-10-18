BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $script:exportScript = Join-Path $repoRoot 'pipelines/scripts/export.ps1'
    # Snapshot generated XML and mapping/pathspec calls inside the mocks: export deletes its
    # mapping files on return. Reset the shared capture below to isolate each regression case.
    if (-not ('AlmExportMappingTestCapture' -as [type])) {
        Add-Type -TypeDefinition @'
public static class AlmExportMappingTestCapture
{
    public static string MappingPath { get; set; }
    public static string MappingXml { get; set; }
    public static readonly System.Collections.Generic.List<string> CompressionMappingPaths = new System.Collections.Generic.List<string>();
    public static readonly System.Collections.Generic.List<string> GitStatusArguments = new System.Collections.Generic.List<string>();
}
'@
    }
    function Export-DataverseSolution {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        [CmdletBinding()]
        param($SolutionName, $OutFolder, [switch]$UnpackMsApp, $MappingFile)
    }
    function Compress-DataverseSolutionFile {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        [CmdletBinding()]
        param($PackageType, $OutputPath, $Path, $MappingFile)
    }
    function Compare-DataverseSolutionComponents {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'External Dataverse cmdlet name required by the mock contract.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        [CmdletBinding()]
        param([switch]$FileToFile, $SolutionFile, $TargetSolutionFile, [switch]$TestIfAdditive)
    }
    function Set-DataverseSolution {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        param($UniqueName, $Version)
    }
    function Register-AlmSolutionVersion {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        param($RepositoryPath, $SolutionName, $Version, $IsAdditive)
    }
    function git {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Command', Justification = 'Mock command signature; Pester inspects these arguments.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'RemainingArguments', Justification = 'The mapping regression mock inspects git pathspec arguments.')]
        param($Command, [Parameter(ValueFromRemainingArguments = $true)][string[]]$RemainingArguments)
    }
}

Describe 'Export and version changes' {
    BeforeEach {
        $fixtureRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:exportSource = Join-Path $fixtureRoot 'source'
        $script:exportArtifacts = Join-Path $fixtureRoot 'artifacts'
        $script:exportTemp = Join-Path $fixtureRoot 'temp'
        New-Item -ItemType Directory -Path $script:exportSource, $script:exportArtifacts, $script:exportTemp -Force | Out-Null
        # Sequential mode keeps Dataverse and reservation calls in Pester's mocked runspace.
        # The branch base maps to Major.Build, so 1.2.3.4 already matches the configured 1.3.
        Set-Content (Join-Path $script:exportSource 'alm-config.psd1') -Value "@{ solutions = @(@{ name = 'Example' }); hooks = @{}; export = @{ parallel = `$false }; buildVersion = @{ default = '1.3'; branches = @{} } }"
        Mock Export-DataverseSolution {
            if (-not [string]::IsNullOrWhiteSpace($MappingFile)) {
                [AlmExportMappingTestCapture]::MappingPath = $MappingFile
                [AlmExportMappingTestCapture]::MappingXml = Get-Content -LiteralPath $MappingFile -Raw
            }
            New-Item -ItemType Directory -Path (Join-Path $OutFolder 'Other') -Force | Out-Null
            Set-Content (Join-Path $OutFolder 'Other/Solution.xml') -Value '<ImportExportXml><SolutionManifest><Version>1.2.3.4</Version></SolutionManifest></ImportExportXml>'
        }
        Mock Compress-DataverseSolutionFile {
            if (-not [string]::IsNullOrWhiteSpace($MappingFile)) { [AlmExportMappingTestCapture]::CompressionMappingPaths.Add($MappingFile) }
            Set-Content -LiteralPath $OutputPath -Value 'packed'
        }
        Mock Compare-DataverseSolutionComponents { $true }
        Mock Set-DataverseSolution {}
        Mock Register-AlmSolutionVersion { $Version }
        Mock git { ' M solutions/Example/Other/Solution.xml' }
        $script:capturedWarnings = @()
        [AlmExportMappingTestCapture]::MappingPath = $null
        [AlmExportMappingTestCapture]::MappingXml = $null
        [AlmExportMappingTestCapture]::CompressionMappingPaths.Clear()
        [AlmExportMappingTestCapture]::GitStatusArguments.Clear()
    }

    It 'increments the revision for a first export' {
        & $script:exportScript -SourceDirectory $script:exportSource -ArtifactStagingDirectory $script:exportArtifacts -TempDirectory $script:exportTemp -EnvironmentName TEST -BranchName main -DefaultBranchName main
        Should -Invoke Export-DataverseSolution -Times 1 -Exactly -ParameterFilter { $SolutionName -eq 'Example' -and $UnpackMsApp }
        Should -Invoke Set-DataverseSolution -Times 1 -Exactly -ParameterFilter { $UniqueName -eq 'Example' -and $Version -eq '1.2.3.5' }
        Should -Invoke Register-AlmSolutionVersion -Times 1 -Exactly -ParameterFilter { $SolutionName -eq 'Example' -and $Version.ToString() -eq '1.2.3.5' -and $IsAdditive }
        Should -Invoke Compare-DataverseSolutionComponents -Times 0 -Exactly
        [xml]$xml = Get-Content (Join-Path $script:exportSource 'solutions/Example/Other/Solution.xml') -Raw
        $xml.ImportExportXml.SolutionManifest.Version | Should -Be '1.2.3.5'
    }

    It 'uses inline mappings during sequential export without running build commands' {
        New-Item -ItemType Directory -Path (Join-Path $script:exportSource 'plugins') -Force | Out-Null
        Set-Content (Join-Path $script:exportSource 'plugins/Example.dll') -Value 'plugin'
        # The deliberately unavailable executable makes accidental BUILD work during EXPORT
        # fail, while the existing source file still permits mapping/unpack validation.
        Set-Content (Join-Path $script:exportSource 'alm-config.psd1') -Value @'
@{
    solutions = @(@{
        name = 'Example'
        mappings = @(@{
            type = 'FileToFile'
            source = 'plugins/Example.dll'
            destination = 'PluginAssemblies/Example.dll'
            buildCommand = @{ name = 'Not run by export'; executable = 'missing-build-tool'; arguments = @() }
        })
    })
    hooks = @{}
    export = @{ parallel = $false }
    buildVersion = @{ default = '1.3'; branches = @{} }
}
'@

        & $script:exportScript -SourceDirectory $script:exportSource -ArtifactStagingDirectory $script:exportArtifacts -TempDirectory $script:exportTemp -BranchName main -DefaultBranchName main

        Should -Invoke Export-DataverseSolution -Times 1 -Exactly -ParameterFilter { -not [string]::IsNullOrWhiteSpace($MappingFile) }
        [AlmExportMappingTestCapture]::MappingXml | Should -Match '<Mapping>'
        $mappingXml = [xml][AlmExportMappingTestCapture]::MappingXml
        $mappingXml.Mapping.FileToFile.GetAttribute('map') | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $script:exportSource 'solutions/Example/PluginAssemblies/Example.dll')))
        $mappingXml.Mapping.FileToFile.GetAttribute('to') | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $script:exportSource 'plugins/Example.dll')))
        Test-Path -LiteralPath ([AlmExportMappingTestCapture]::MappingPath) | Should -BeFalse
    }

    It 'detects changes to mapped source files outside the solution directory' {
        New-Item -ItemType Directory -Path (Join-Path $script:exportSource 'plugins'), (Join-Path $script:exportSource 'solutions/Example/Other') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:exportSource 'plugins/Example.dll') -Value 'plugin'
        Set-Content -LiteralPath (Join-Path $script:exportSource 'solutions/Example/Other/Solution.xml') -Value '<ImportExportXml><SolutionManifest><Version>1.2.3.4</Version></SolutionManifest></ImportExportXml>'
        Set-Content -LiteralPath (Join-Path $script:exportSource 'alm-config.psd1') -Value @'
@{
    solutions = @(@{
        name = 'Example'
        mappings = @(@{
            type = 'FileToFile'
            source = 'plugins/Example.dll'
            destination = 'PluginAssemblies/Example.dll'
        })
    })
    hooks = @{}
    export = @{ parallel = $false }
    buildVersion = @{ default = '1.3'; branches = @{} }
}
'@
        # Return a change only if EXPORT asks Git about the mapped source outside solutions;
        # a hard-coded nonempty status would hide regressions in pathspec construction.
        Mock git {
            if ($RemainingArguments -contains 'plugins/Example.dll') {
                [AlmExportMappingTestCapture]::GitStatusArguments.AddRange($RemainingArguments)
                ' M plugins/Example.dll'
            }
        }

        & $script:exportScript -SourceDirectory $script:exportSource -ArtifactStagingDirectory $script:exportArtifacts -TempDirectory $script:exportTemp -BranchName main -DefaultBranchName main

        [AlmExportMappingTestCapture]::GitStatusArguments | Should -Contain 'plugins/Example.dll'
        Should -Invoke Compress-DataverseSolutionFile -Times 2 -Exactly
        Should -Invoke Compare-DataverseSolutionComponents -Times 1 -Exactly
        Should -Invoke Set-DataverseSolution -Times 1 -Exactly -ParameterFilter { $Version -eq '1.2.3.5' }
    }

    It 'rejects duplicate solution names before generating sequential mapping files' -ForEach @(
        @{ FirstName = 'Example'; SecondName = 'Example' }
        @{ FirstName = 'Example'; SecondName = 'example' }
    ) {
        Set-Content -LiteralPath (Join-Path $script:exportSource 'alm-config.psd1') -Value @"
@{
    solutions = @(
        @{ name = '$FirstName'; mappings = @(@{ type = 'FileToFile'; source = 'plugins/First.dll'; destination = 'First.dll' }) }
        @{ name = '$SecondName'; mappings = @(@{ type = 'FileToFile'; source = 'plugins/Second.dll'; destination = 'Second.dll' }) }
    )
    hooks = @{}
    export = @{ parallel = `$false }
    buildVersion = @{ default = '1.3'; branches = @{} }
}
"@

        {
            & $script:exportScript -SourceDirectory $script:exportSource -ArtifactStagingDirectory $script:exportArtifacts -TempDirectory $script:exportTemp -BranchName main -DefaultBranchName main
        } | Should -Throw '*Duplicate solution in export configuration*'

        Should -Invoke Export-DataverseSolution -Times 0 -Exactly
        Should -Invoke Compress-DataverseSolutionFile -Times 0 -Exactly
        [AlmExportMappingTestCapture]::MappingPath | Should -BeNullOrEmpty
    }

    It 'uses inline mappings for old and new packages when comparing export changes' {
        New-Item -ItemType Directory -Path (Join-Path $script:exportSource 'plugins'), (Join-Path $script:exportSource 'solutions/Example') -Force | Out-Null
        Set-Content (Join-Path $script:exportSource 'plugins/Example.dll') -Value 'plugin'
        Set-Content (Join-Path $script:exportSource 'alm-config.psd1') -Value @'
@{
    solutions = @(@{
        name = 'Example'
        mappings = @(@{
            type = 'FileToFile'
            source = 'plugins/Example.dll'
            destination = 'PluginAssemblies/Example.dll'
        })
    })
    hooks = @{}
    export = @{ parallel = $false }
    buildVersion = @{ default = '1.3'; branches = @{} }
}
'@

        & $script:exportScript -SourceDirectory $script:exportSource -ArtifactStagingDirectory $script:exportArtifacts -TempDirectory $script:exportTemp -BranchName main -DefaultBranchName main

        Should -Invoke Compress-DataverseSolutionFile -Times 2 -Exactly -ParameterFilter { -not [string]::IsNullOrWhiteSpace($MappingFile) }
        [AlmExportMappingTestCapture]::CompressionMappingPaths.Count | Should -Be 2
        [AlmExportMappingTestCapture]::CompressionMappingPaths | Should -Contain ([AlmExportMappingTestCapture]::MappingPath)
        Test-Path -LiteralPath ([AlmExportMappingTestCapture]::MappingPath) | Should -BeFalse
    }

    It 'does not require a connection when per-solution hooks are not configured' {
        $result = & $script:exportScript -SourceDirectory $script:exportSource -ArtifactStagingDirectory $script:exportArtifacts -TempDirectory $script:exportTemp -BranchName main -DefaultBranchName main -PassThru

        $result.Parallel | Should -BeFalse
    }

    It 'increments revision for additive changes and minor version for removals' -ForEach @(
        @{ Additive = $true; ExpectedVersion = '1.2.3.5' }
        @{ Additive = $false; ExpectedVersion = '1.3.3.0' }
    ) {
        New-Item -ItemType Directory -Path (Join-Path $script:exportSource 'solutions/Example') -Force | Out-Null
        Mock Compare-DataverseSolutionComponents { $Additive }
        & $script:exportScript -SourceDirectory $script:exportSource -ArtifactStagingDirectory $script:exportArtifacts -TempDirectory $script:exportTemp -BranchName main -DefaultBranchName main
        Should -Invoke Set-DataverseSolution -Times 1 -Exactly -ParameterFilter { $Version -eq $ExpectedVersion }
        Should -Invoke Compare-DataverseSolutionComponents -Times 1 -Exactly
        @(Get-ChildItem $script:exportTemp).Count | Should -Be 0
        [xml]$xml = Get-Content (Join-Path $script:exportSource 'solutions/Example/Other/Solution.xml') -Raw
        $xml.ImportExportXml.SolutionManifest.Version | Should -Be $ExpectedVersion
    }

    It 'resets the solution counters to the branch base when Major.Build does not match' -ForEach @(
        @{ Additive = $true; ExpectedVersion = '1.0.3.1' }
        @{ Additive = $false; ExpectedVersion = '1.1.3.0' }
    ) {
        New-Item -ItemType Directory -Path (Join-Path $script:exportSource 'solutions/Example') -Force | Out-Null
        Mock Export-DataverseSolution {
            New-Item -ItemType Directory -Path (Join-Path $OutFolder 'Other') -Force | Out-Null
            Set-Content (Join-Path $OutFolder 'Other/Solution.xml') -Value '<ImportExportXml><SolutionManifest><Version>1.2.2.4</Version></SolutionManifest></ImportExportXml>'
        }
        Mock Compare-DataverseSolutionComponents { $Additive }
        & $script:exportScript -SourceDirectory $script:exportSource -ArtifactStagingDirectory $script:exportArtifacts -TempDirectory $script:exportTemp -BranchName main -DefaultBranchName main
        Should -Invoke Set-DataverseSolution -Times 1 -Exactly -ParameterFilter { $Version -eq $ExpectedVersion }
        [xml]$xml = Get-Content (Join-Path $script:exportSource 'solutions/Example/Other/Solution.xml') -Raw
        $xml.ImportExportXml.SolutionManifest.Version | Should -Be $ExpectedVersion
    }

    It 'resets the solution counters when Major differs from the branch base' {
        New-Item -ItemType Directory -Path (Join-Path $script:exportSource 'solutions/Example') -Force | Out-Null
        Mock Export-DataverseSolution {
            New-Item -ItemType Directory -Path (Join-Path $OutFolder 'Other') -Force | Out-Null
            Set-Content (Join-Path $OutFolder 'Other/Solution.xml') -Value '<ImportExportXml><SolutionManifest><Version>2.2.3.4</Version></SolutionManifest></ImportExportXml>'
        }
        Mock Compare-DataverseSolutionComponents { $true }
        & $script:exportScript -SourceDirectory $script:exportSource -ArtifactStagingDirectory $script:exportArtifacts -TempDirectory $script:exportTemp -BranchName main -DefaultBranchName main
        Should -Invoke Set-DataverseSolution -Times 1 -Exactly -ParameterFilter { $Version -eq '1.0.3.1' }
    }

    It 'uses checked increments when a solution version component is at its limit' -ForEach @(
        @{ CurrentVersion = '1.2.3.2147483647'; Additive = $true; Message = '*Cannot increment solution revision beyond*' }
        @{ CurrentVersion = '1.2147483647.3.0'; Additive = $false; Message = '*Cannot increment solution minor beyond*' }
    ) {
        New-Item -ItemType Directory -Path (Join-Path $script:exportSource 'solutions/Example') -Force | Out-Null
        Mock Export-DataverseSolution {
            New-Item -ItemType Directory -Path (Join-Path $OutFolder 'Other') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $OutFolder 'Other/Solution.xml') -Value "<ImportExportXml><SolutionManifest><Version>$CurrentVersion</Version></SolutionManifest></ImportExportXml>"
        }
        Mock Compare-DataverseSolutionComponents { $Additive }

        { & $script:exportScript -SourceDirectory $script:exportSource -ArtifactStagingDirectory $script:exportArtifacts -TempDirectory $script:exportTemp -BranchName main -DefaultBranchName main } |
            Should -Throw $Message
        Should -Invoke Set-DataverseSolution -Times 0 -Exactly
    }

    It 'leaves unchanged solution versions alone' {
        Mock git { '' }
        & $script:exportScript -SourceDirectory $script:exportSource -ArtifactStagingDirectory $script:exportArtifacts -TempDirectory $script:exportTemp -BranchName main -DefaultBranchName main
        Should -Invoke Set-DataverseSolution -Times 0 -Exactly
        Should -Invoke Register-AlmSolutionVersion -Times 0 -Exactly
        [xml]$xml = Get-Content (Join-Path $script:exportSource 'solutions/Example/Other/Solution.xml') -Raw
        $xml.ImportExportXml.SolutionManifest.Version | Should -Be '1.2.3.4'
    }

    It 'propagates export failure without updating environment versions' {
        Mock Export-DataverseSolution { throw 'Export unavailable' }
        { & $script:exportScript -SourceDirectory $script:exportSource -ArtifactStagingDirectory $script:exportArtifacts -TempDirectory $script:exportTemp -BranchName main -DefaultBranchName main } | Should -Throw '*Export unavailable*'
        Should -Invoke Set-DataverseSolution -Times 0 -Exactly
    }

    It 'warns when a non-default branch uses the default version rule' {
        $null = & $script:exportScript -SourceDirectory $script:exportSource -ArtifactStagingDirectory $script:exportArtifacts -TempDirectory $script:exportTemp -BranchName 'feature/new' -DefaultBranchName main 3>&1 |
            ForEach-Object { if ($_ -is [System.Management.Automation.WarningRecord]) { $script:capturedWarnings += $_.Message } }
        ($script:capturedWarnings -join "`n") | Should -Match "non-default branch 'feature/new'.*Configure buildVersion.branches"
    }

    It 'does not warn when a non-default branch has an explicit version rule' {
        Set-Content (Join-Path $script:exportSource 'alm-config.psd1') -Value "@{ solutions = @(@{ name = 'Example' }); hooks = @{}; export = @{ parallel = `$false }; buildVersion = @{ default = '1.3'; branches = @{ 'feature/new' = '2.0' } } }"
        $null = & $script:exportScript -SourceDirectory $script:exportSource -ArtifactStagingDirectory $script:exportArtifacts -TempDirectory $script:exportTemp -BranchName 'feature/new' -DefaultBranchName main 3>&1 |
            ForEach-Object { if ($_ -is [System.Management.Automation.WarningRecord]) { $script:capturedWarnings += $_.Message } }
        $script:capturedWarnings.Count | Should -Be 0
    }
}