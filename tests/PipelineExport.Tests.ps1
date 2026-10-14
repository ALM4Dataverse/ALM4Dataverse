BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $script:exportScript = Join-Path $repoRoot 'pipelines/scripts/export.ps1'
    function Export-DataverseSolution {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        [CmdletBinding()]
        param($SolutionName, $OutFolder, [switch]$UnpackMsApp)
    }
    function Compress-DataverseSolutionFile {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        [CmdletBinding()]
        param($PackageType, $OutputPath, $Path)
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
    function git {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Command', Justification = 'Mock command signature; Pester inspects these arguments.')]
        param($Command)
    }
}

Describe 'Export and version changes' {
    BeforeEach {
        $fixtureRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:exportSource = Join-Path $fixtureRoot 'source'
        $script:exportArtifacts = Join-Path $fixtureRoot 'artifacts'
        $script:exportTemp = Join-Path $fixtureRoot 'temp'
        New-Item -ItemType Directory -Path $script:exportSource, $script:exportArtifacts, $script:exportTemp -Force | Out-Null
        Set-Content (Join-Path $script:exportSource 'alm-config.psd1') -Value "@{ solutions = @(@{ name = 'Example' }); hooks = @{}; export = @{ parallel = `$false }; buildVersion = @{ default = '1.3'; branches = @{} } }"
        Mock Export-DataverseSolution {
            New-Item -ItemType Directory -Path (Join-Path $OutFolder 'Other') -Force | Out-Null
            Set-Content (Join-Path $OutFolder 'Other/Solution.xml') -Value '<ImportExportXml><SolutionManifest><Version>1.2.3.4</Version></SolutionManifest></ImportExportXml>'
        }
        Mock Compress-DataverseSolutionFile { Set-Content -LiteralPath $OutputPath -Value 'packed' }
        Mock Compare-DataverseSolutionComponents { $true }
        Mock Set-DataverseSolution {}
        Mock git { ' M solutions/Example/Other/Solution.xml' }
    }

    It 'increments the revision for a first export' {
        & $script:exportScript -SourceDirectory $script:exportSource -ArtifactStagingDirectory $script:exportArtifacts -TempDirectory $script:exportTemp -EnvironmentName TEST -BranchName main
        Should -Invoke Export-DataverseSolution -Times 1 -Exactly -ParameterFilter { $SolutionName -eq 'Example' -and $UnpackMsApp }
        Should -Invoke Set-DataverseSolution -Times 1 -Exactly -ParameterFilter { $UniqueName -eq 'Example' -and $Version -eq '1.2.3.5' }
        Should -Invoke Compare-DataverseSolutionComponents -Times 0 -Exactly
        [xml]$xml = Get-Content (Join-Path $script:exportSource 'solutions/Example/Other/Solution.xml') -Raw
        $xml.ImportExportXml.SolutionManifest.Version | Should -Be '1.2.3.5'
    }

    It 'increments revision for additive changes and minor version for removals' -ForEach @(
        @{ Additive = $true; ExpectedVersion = '1.2.3.5' }
        @{ Additive = $false; ExpectedVersion = '1.3.3.0' }
    ) {
        New-Item -ItemType Directory -Path (Join-Path $script:exportSource 'solutions/Example') -Force | Out-Null
        Mock Compare-DataverseSolutionComponents { $Additive }
        & $script:exportScript -SourceDirectory $script:exportSource -ArtifactStagingDirectory $script:exportArtifacts -TempDirectory $script:exportTemp -BranchName main
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
        & $script:exportScript -SourceDirectory $script:exportSource -ArtifactStagingDirectory $script:exportArtifacts -TempDirectory $script:exportTemp -BranchName main
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
        & $script:exportScript -SourceDirectory $script:exportSource -ArtifactStagingDirectory $script:exportArtifacts -TempDirectory $script:exportTemp -BranchName main
        Should -Invoke Set-DataverseSolution -Times 1 -Exactly -ParameterFilter { $Version -eq '1.0.3.1' }
    }

    It 'leaves unchanged solution versions alone' {
        Mock git { '' }
        & $script:exportScript -SourceDirectory $script:exportSource -ArtifactStagingDirectory $script:exportArtifacts -TempDirectory $script:exportTemp -BranchName main
        Should -Invoke Set-DataverseSolution -Times 0 -Exactly
        [xml]$xml = Get-Content (Join-Path $script:exportSource 'solutions/Example/Other/Solution.xml') -Raw
        $xml.ImportExportXml.SolutionManifest.Version | Should -Be '1.2.3.4'
    }

    It 'propagates export failure without updating environment versions' {
        Mock Export-DataverseSolution { throw 'Export unavailable' }
        { & $script:exportScript -SourceDirectory $script:exportSource -ArtifactStagingDirectory $script:exportArtifacts -TempDirectory $script:exportTemp -BranchName main } | Should -Throw '*Export unavailable*'
        Should -Invoke Set-DataverseSolution -Times 0 -Exactly
    }
}