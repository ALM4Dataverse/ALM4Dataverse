<#
.SYNOPSIS
    Imports Dataverse solutions and other artifacts to dev environments from source control.
.DESCRIPTION
    This script first builds the latest version of artifacts based on the source directory.
    It then deploys the packed solutions to the connected Dataverse environment using the deploy script.

    This is used to "import" the latest source code changes into a Dataverse environment.
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

Write-Host "##[section]Importing"


# Step 1: Build/pack the solutions
Write-Host "##[group]Step 1: Packing solutions"
& "$PSScriptRoot/build.ps1" `
    -SourceDirectory $SourceDirectory `
    -ArtifactStagingDirectory $ArtifactStagingDirectory

if (-not $?) {
    Write-Host "##[error]Build/pack step failed"
    throw "Build/pack step failed"
}
Write-Host "##[endgroup]"

Write-Host "##[group]Step 2: Deploying"

# Step 2: Deploy the packed solutions using the deploy script
& "$PSScriptRoot/deploy.ps1" `
    -ArtifactsPath "$ArtifactStagingDirectory" `
    -UseUnmanagedSolutions

if (-not $?) {
    Write-Host "##[error]Deploy step failed"
    throw "Deploy step failed"
}

Write-Host "##[endgroup]"
Write-Host "##[section]Import completed successfully!"

