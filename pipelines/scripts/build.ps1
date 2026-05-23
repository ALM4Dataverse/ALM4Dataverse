<# 
.SYNOPSIS
    Builds the artifacts that can be used to deploy to a Dataverse environment.

.DESCRIPTION
    This script packs the solutions from the source directory into managed and unmanaged
    zip files in the artifact staging directory. It also copies any additional assets
    defined in alm-config.psd1 and creates a lock file for script dependencies.

    Hooks defined in alm-config.psd1 are invoked at various stages of the build process
    to allow for custom pre- and post-build actions.
.PARAMETER SourceDirectory
    The root directory containing the solution folders and alm-config.psd1 file.
.PARAMETER ArtifactStagingDirectory
    The directory where the built artifacts will be placed.
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$SourceDirectory,
    
    [Parameter(Mandatory=$true)]
    [string]$ArtifactStagingDirectory
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot 'common.ps1')

Write-Host "##[section]Building Artifacts"

function Get-PacCliInstalledPackageVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PacToolPath
    )

    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $dotnet) {
        return ''
    }

    if (-not (Test-Path $PacToolPath)) {
        return ''
    }

    $toolListOutput = @(& $dotnet.Source tool list --tool-path $PacToolPath 2>&1)
    foreach ($line in $toolListOutput) {
        if ($line -match '^\s*microsoft\.powerapps\.cli\.tool\s+(\S+)\s+') {
            return $Matches[1].Split('+')[0]
        }
    }

    return ''
}

# Read solutions configuration
$config = Get-AlmConfig -BaseDirectory $SourceDirectory
Write-Host "##[debug]Loaded configuration from alm-config.psd1"

Invoke-Hooks -HookType "preBuild" -BaseDirectory $SourceDirectory -Config $config -AdditionalContext @{
    SourceDirectory = $SourceDirectory
    ArtifactStagingDirectory = $ArtifactStagingDirectory
}

foreach ($solution in $config.solutions) {
    $solutionName = $solution.name
    
    Write-Host "##[group]Building solution: $solutionName"
    
    Write-Host "Packing solution: $solutionName (Managed)"

    Compress-DataverseSolutionFile -Verbose `
        -Path "$SourceDirectory/solutions/$solutionName" `
        -OutputPath "$ArtifactStagingDirectory/solutions/${solutionName}.zip" `
        -PackageType Both
    
    Write-Host "##[endgroup]"
}

if ($config.assets -and $config.assets.Count -gt 0) {
    Write-Host "##[group]Copying extra asset files"
    foreach ($asset in $config.assets) {
        $sourcePath = Join-Path $SourceDirectory $asset
        $destinationPath = Join-Path $ArtifactStagingDirectory $asset
        
        if (Test-Path $sourcePath) {
            Write-Host "Copying asset: $asset"
            Copy-Item $sourcePath -Destination $destinationPath -Recurse -Force -Verbose
        } else {
            write-Host "##[error]Asset path not found: $sourcePath"
            throw "Asset path not found: $sourcePath"
        }
    }
    Write-Host "##[endgroup]"
}

Write-Host "##[group]Copying deployment scripts"
Copy-Item $PSScriptRoot/../.. -Destination "$ArtifactStagingDirectory/alm" -Recurse -Force -Verbose
Copy-Item (Join-Path $SourceDirectory 'alm-config.psd1') -Destination (Join-Path $ArtifactStagingDirectory 'alm-config.psd1') -Force -Verbose

# Create lock file with pinned module versions
$lockConfig = @{
    scriptDependencies = [hashtable]::new($config.scriptDependencies)
    pacCliVersion = [string]$config.pacCliVersion
}
foreach ($moduleName in ([string[]] $lockConfig.scriptDependencies.Keys)) {
    $module = Get-Module -Name $moduleName
    if ($module) {
        $version = $module.Version.ToString()
        if ($module.PrivateData -and $module.PrivateData.PSData -and $module.PrivateData.PSData.Prerelease) {
            $version += "-$($module.PrivateData.PSData.Prerelease)"
        }
        $lockConfig.scriptDependencies[$moduleName] = $version
    } else {
        write-Host "##[error]Module $moduleName not found in loaded modules."
        throw "Module $moduleName not found in loaded modules."
    }
}

$pacToolPath = Join-Path $HOME '.alm4dataverse\tools'
$resolvedPacVersion = Get-PacCliInstalledPackageVersion -PacToolPath $pacToolPath

if ([string]::IsNullOrWhiteSpace($resolvedPacVersion)) {
    throw "Unable to resolve installed PAC CLI package version from 'dotnet tool list --tool-path $pacToolPath'. Ensure installdependencies.ps1 has installed Microsoft.PowerApps.CLI.Tool before build.ps1 runs."
}

$lockConfig.pacCliVersion = $resolvedPacVersion

$lockPath = Join-Path $ArtifactStagingDirectory 'scriptDependencies.lock.json'
$lockConfig | ConvertTo-Json | Out-File $lockPath -Encoding UTF8

Write-Host "##[endgroup]"

Write-Host "##[section]Build completed successfully!"

Invoke-Hooks -HookType "postBuild" -BaseDirectory $SourceDirectory -Config $config -AdditionalContext @{
    SourceDirectory = $SourceDirectory
    ArtifactStagingDirectory = $ArtifactStagingDirectory
}
