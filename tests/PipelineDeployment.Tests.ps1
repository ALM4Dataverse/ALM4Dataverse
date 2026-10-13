BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $script:deployScript = Join-Path $repoRoot 'pipelines/scripts/deploy.ps1'
    . (Join-Path $repoRoot 'pipelines/scripts/common.ps1')

    function Import-DataverseSolution {
        [CmdletBinding()]
        param($InFile, $Mode, $TimeoutSeconds, $EnvironmentVariables, $ConnectionReferences,
            [switch]$OverwriteUnmanagedCustomizations, [switch]$SkipIfSameVersion,
            [switch]$UseUpdateIfVersionMajorMinorMatches)
    }
    function Invoke-DataverseSolutionUpgrade {
        [CmdletBinding()]
        param($SolutionName, [switch]$IfExists)
    }
    function Get-DataverseRecord {
        param($TableName, $FilterValues, $Links, $Columns)
    }
    function Set-DataverseRecord {
        param($TableName, $Id, $InputObject)
    }
    function Publish-DataverseCustomizations {}
    function Compress-DataverseSolutionFile {
        [CmdletBinding()]
        param($Path, $OutputPath, $PackageType)
    }
    function Invoke-DeploymentTestDotnet { param($Verb, $Operation) }

    function Write-DeploymentConfig {
        param([string]$Settings = '')
        Set-Content -LiteralPath (Join-Path $TestDrive 'alm-config.psd1') -Value @"
@{
    solutions = @(@{ name = 'Example'; $Settings })
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

    It 'honors the per-solution service account key' {
        Write-DeploymentConfig -Settings "serviceAccountUpnConfigKey = 'CustomUpn'"
        & $script:deployScript -ArtifactsPath $TestDrive
        Should -Invoke Get-DataverseRecord -Times 1 -Exactly -ParameterFilter {
            $TableName -eq 'systemuser' -and $FilterValues.domainname -eq 'custom@example.com'
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
