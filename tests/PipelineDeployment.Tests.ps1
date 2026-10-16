BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $script:deployScript = Join-Path $repoRoot 'pipelines/scripts/deploy.ps1'
    . (Join-Path $repoRoot 'pipelines/scripts/common.ps1')

    function Import-DataverseSolution {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        [CmdletBinding()]
        param($InFile, $Mode, $TimeoutSeconds, $EnvironmentVariables, $ConnectionReferences,
            [switch]$OverwriteUnmanagedCustomizations, [switch]$SkipIfSameVersion,
            [switch]$UseUpdateIfVersionMajorMinorMatches)
    }
    function Invoke-DataverseSolutionUpgrade {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        [CmdletBinding()]
        param($SolutionName, [switch]$IfExists)
    }
    function Get-DataverseRecord {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        param($TableName, $FilterValues, $Links, $Columns)
    }
    function Set-DataverseRecord {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        param($TableName, $Id, $InputObject)
    }
    function Publish-DataverseCustomizations {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'External Dataverse cmdlet name required by the mock contract.')]
        param()
    }
    function Compress-DataverseSolutionFile {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        [CmdletBinding()]
        param($Path, $OutputPath, $PackageType)
    }
    function Invoke-DeploymentTestDotnet {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        param($Verb, $Operation)
    }

    # Settings is literal solution-entry syntax, allowing missing/null/false keys to remain distinct.
    # Disable parallel packing so the IMPORT case can use the same in-runspace command mocks.
    function Write-DeploymentConfig {
        param([string]$Settings = '')
        Set-Content -LiteralPath (Join-Path $TestDrive 'alm-config.psd1') -Value @"
@{
    solutions = @(@{ name = 'Example'; $Settings })
    build = @{ parallel = `$false }
    hooks = @{}
}
"@
    }
}

Describe 'Deployment options' {
    BeforeEach {
        $script:savedDefaultUpn = $env:DATAVERSESERVICEACCOUNTUPN
        $script:savedCustomUpn = $env:CUSTOMUPN
        $env:DATAVERSESERVICEACCOUNTUPN = 'default@example.com'
        $env:CUSTOMUPN = 'custom@example.com'
        Mock Import-DataverseSolution {}
        Mock Invoke-DataverseSolutionUpgrade {}
        Mock Publish-DataverseCustomizations {}
        Mock Get-DataverseRecord {
            if ($TableName -eq 'systemuser') {
                return @{ fullname = 'Service Account'; Id = 'user-id' }
            }
            return @()
        }
    }

    AfterEach {
        $env:DATAVERSESERVICEACCOUNTUPN = $script:savedDefaultUpn
        $env:CUSTOMUPN = $script:savedCustomUpn
    }

    It 'uses managed packages when deployUnmanaged is <Label>' -ForEach @(
        @{ Label = 'missing'; Settings = '' }
        @{ Label = 'false'; Settings = 'deployUnmanaged = $false' }
        @{ Label = 'null'; Settings = 'deployUnmanaged = $null' }
    ) {
        Write-DeploymentConfig -Settings $Settings
        & $script:deployScript -ArtifactsPath $TestDrive
        Should -Invoke Import-DataverseSolution -Times 1 -Exactly -ParameterFilter {
            $InFile -like '*Example_managed.zip' -and $Mode -eq 'Auto'
        }
    }

    It 'honors per-solution unmanaged deployment without upgrade behavior' {
        Write-DeploymentConfig -Settings 'deployUnmanaged = $true'
        & $script:deployScript -ArtifactsPath $TestDrive
        Should -Invoke Import-DataverseSolution -Times 1 -Exactly -ParameterFilter {
            $InFile -like '*Example.zip' -and $Mode -eq 'NoUpgrade' -and
            -not $OverwriteUnmanagedCustomizations -and -not $UseUpdateIfVersionMajorMinorMatches
        }
        Should -Invoke Invoke-DataverseSolutionUpgrade -Times 0 -Exactly
    }

    It 'uses unmanaged packages for the import switch' {
        Write-DeploymentConfig
        & $script:deployScript -ArtifactsPath $TestDrive -UseUnmanagedSolutions
        Should -Invoke Import-DataverseSolution -Times 1 -Exactly -ParameterFilter {
            $InFile -like '*Example.zip' -and $Mode -eq 'NoUpgrade'
        }
        Should -Invoke Invoke-DataverseSolutionUpgrade -Times 0 -Exactly
    }

    It 'selects package and service-account defaults for <Label>' -ForEach @(
        @{ Label = 'missing keys'; Settings = ''; Unmanaged = $false; Package = 'Example_managed.zip'; Upn = 'default@example.com' }
        @{ Label = 'per-solution overrides'; Settings = "deployUnmanaged = `$true; serviceAccountUpnConfigKey = 'CustomUpn'"; Unmanaged = $false; Package = 'Example.zip'; Upn = 'custom@example.com' }
        @{ Label = 'false and empty keys'; Settings = "deployUnmanaged = `$false; serviceAccountUpnConfigKey = ''"; Unmanaged = $false; Package = 'Example_managed.zip'; Upn = 'default@example.com' }
        @{ Label = 'null keys'; Settings = 'deployUnmanaged = $null; serviceAccountUpnConfigKey = $null'; Unmanaged = $false; Package = 'Example_managed.zip'; Upn = 'default@example.com' }
        @{ Label = 'IMPORT overriding managed preference'; Settings = "deployUnmanaged = `$false; serviceAccountUpnConfigKey = 'CustomUpn'"; Unmanaged = $true; Package = 'Example.zip'; Upn = 'custom@example.com' }
        @{ Label = 'IMPORT with missing keys'; Settings = ''; Unmanaged = $true; Package = 'Example.zip'; Upn = 'default@example.com' }
    ) {
        Set-StrictMode -Version Latest
        Write-DeploymentConfig -Settings $Settings
        & $script:deployScript -ArtifactsPath $TestDrive -UseUnmanagedSolutions:$Unmanaged
        Should -Invoke Import-DataverseSolution -Times 1 -Exactly -ParameterFilter {
            [IO.Path]::GetFileName($InFile) -eq $Package
        }
        Should -Invoke Get-DataverseRecord -Times 1 -Exactly -ParameterFilter {
            $TableName -eq 'systemuser' -and $FilterValues.domainname -eq $Upn
        }
    }

    It 'imports source by building artifacts and deploying unmanaged packages without upgrades' {
        Write-DeploymentConfig
        New-Item -ItemType Directory -Path (Join-Path $TestDrive 'data'), (Join-Path $TestDrive 'solutions/Example'), (Join-Path $TestDrive 'artifacts/solutions') -Force | Out-Null
        Mock Compress-DataverseSolutionFile { Set-Content -LiteralPath $OutputPath -Value 'packed' }
        Mock Copy-Item { New-Item -ItemType Directory -Path $Destination -Force | Out-Null } -ParameterFilter { $Destination -match '[\\/]alm$' }
        Mock Get-Module { [pscustomobject]@{ Version = [version]'3.0.4'; PrivateData = @{ PSData = @{ Prerelease = 'preview.1' } } } } -ParameterFilter { $Name -eq 'Rnwood.Dataverse.Data.PowerShell' }
        Mock Get-Command { [pscustomobject]@{ Source = 'Invoke-DeploymentTestDotnet' } } -ParameterFilter { $Name -eq 'dotnet' }
        Mock Test-Path { $true } -ParameterFilter { $Path -match '[\\/]\.alm4dataverse[\\/]tools$' }
        Mock Invoke-DeploymentTestDotnet { $global:LASTEXITCODE = 0; 'microsoft.powerapps.cli.tool 2.7.4 pac' }
        $savedExitCode = $global:LASTEXITCODE
        try {
            & (Join-Path $repoRoot 'pipelines/scripts/import.ps1') -SourceDirectory $TestDrive -ArtifactStagingDirectory (Join-Path $TestDrive 'artifacts')
            Should -Invoke Compress-DataverseSolutionFile -Times 1 -Exactly
            Should -Invoke Import-DataverseSolution -Times 1 -Exactly -ParameterFilter { $InFile -like '*Example.zip' -and $Mode -eq 'NoUpgrade' }
            Should -Invoke Invoke-DataverseSolutionUpgrade -Times 0 -Exactly
        }
        finally { $global:LASTEXITCODE = $savedExitCode }
    }
}
