<#
.SYNOPSIS
    Deploy Dataverse solutions from artifacts.
.DESCRIPTION
    This script deploys the Dataverse solutions found in the specified artifacts path
    to the connected Dataverse environment. It supports both managed and unmanaged
    solutions based on the provided parameter.

    It also sets connection references and environment variables based on environment
    variables prefixed with "ConnRef_" and "EnvVar_" respectively.

    Hooks defined in alm-config.psd1 are invoked at various stages of the deployment
    process to allow for custom pre- and post-deployment actions.
.PARAMETER ArtifactsPath
    The path to the artifacts containing the solutions to deploy.
.PARAMETER UseUnmanagedSolutions
    Switch to indicate whether to deploy unmanaged solutions instead of managed.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ArtifactsPath,

    # This switch indicates whether to deploy unmanaged solutions.
    # Used for the IMPORT scenario.
    [switch]$UseUnmanagedSolutions
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot 'common.ps1')

Write-Host "##[section]Deploying "

# Read solution configuration
# Simplified logic: alm-config.psd1 should be in the artifacts root
$solutionsConfig = Get-AlmConfig -BaseDirectory $ArtifactsPath
Write-Host "##[debug]Loaded configuration"

$packageDeployerEnabled = $false
if ($solutionsConfig.ContainsKey('buildPackageDeployer') -and $null -ne $solutionsConfig.buildPackageDeployer) {
    $packageDeployerEnabled = [bool]$solutionsConfig.buildPackageDeployer
}

$insidePackageDeployer = $false
if (-not [string]::IsNullOrWhiteSpace($env:ALM4DATAVERSE_IN_PACKAGE_DEPLOY)) {
    $insidePackageDeployer = @('1', 'true', 'yes', 'on') -contains $env:ALM4DATAVERSE_IN_PACKAGE_DEPLOY.Trim().ToLowerInvariant()
}

$packagePath = Join-Path $ArtifactsPath 'ALM4Dataverse.PackageDeployer.pdpkg.zip'

if ($packageDeployerEnabled -and -not $UseUnmanagedSolutions -and -not $insidePackageDeployer) {
    if (-not (Test-Path $packagePath -PathType Leaf)) {
        throw "Package Deployer deploy path is enabled (buildPackageDeployer = `$true), but package '$packagePath' was not found in build artifacts. Ensure build.ps1 generated it before deployment."
    }

    $pac = Get-Command pac -ErrorAction SilentlyContinue
    if (-not $pac) {
        throw 'Power Apps CLI (pac) was not found on PATH.'
    }

    $targetEnvironment = [string]$env:DATAVERSE_URL
    if ([string]::IsNullOrWhiteSpace($targetEnvironment)) {
        throw "DATAVERSE_URL is required for package deployment. pac package deploy needs an explicit --environment value to avoid relying on profile defaults."
    }
    $targetEnvironment = $targetEnvironment.Trim()

    $settingsEntries = New-Object System.Collections.Generic.List[string]

    Get-ChildItem Env: | Where-Object { $_.Name -like 'DataverseConnRef_*' -or $_.Name -like 'DataverseEnvVar_*' } | ForEach-Object {
        if (-not [string]::IsNullOrWhiteSpace($_.Value)) {
            $settingsEntries.Add("$($_.Name)=$($_.Value)")
        }
    }

    $serviceAccountKeys = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    $null = $serviceAccountKeys.Add('DataverseServiceAccountUpn')
    foreach ($solutionConfig in $solutionsConfig.solutions) {
        if ($solutionConfig.PSObject.Properties.Name -contains 'serviceAccountUpnConfigKey' -and -not [string]::IsNullOrWhiteSpace([string]$solutionConfig.serviceAccountUpnConfigKey)) {
            $null = $serviceAccountKeys.Add(([string]$solutionConfig.serviceAccountUpnConfigKey))
        }
    }

    foreach ($serviceAccountKey in $serviceAccountKeys) {
        $serviceAccountValue = [System.Environment]::GetEnvironmentVariable($serviceAccountKey)
        if (-not [string]::IsNullOrWhiteSpace($serviceAccountValue)) {
            $settingsEntries.Add("$serviceAccountKey=$serviceAccountValue")
        }
    }

    $pacArguments = @('package', 'deploy', '--package', $packagePath, '--environment', $targetEnvironment)
    if ($settingsEntries.Count -gt 0) {
        $pacArguments += @('--settings', ($settingsEntries -join '|'))
    }

    Write-Host "##[section]Deploying via Package Deployer package: $packagePath"
    Write-Host "##[debug]Package deploy environment: $targetEnvironment"
    $packageDeployOutput = @(& $pac.Source @pacArguments 2>&1)
    $packageDeployExitCode = $LASTEXITCODE
    foreach ($line in $packageDeployOutput) {
        Write-Host $line
    }
    $packageDeployText = ($packageDeployOutput | ForEach-Object { [string]$_ }) -join "`n"

    if ($packageDeployExitCode -ne 0) {
        throw "pac package deploy failed with exit code $packageDeployExitCode`n$packageDeployText"
    }

    if ($packageDeployText -match '(?im)^\s*error\s*:') {
        throw "pac package deploy reported an error in output despite zero exit code.`n$packageDeployText"
    }

    Write-Host "##[section]Deployment completed successfully via Package Deployer package."
    return
}

if ($packageDeployerEnabled -and $UseUnmanagedSolutions) {
    Write-Host "##[section]Package Deployer deployment is enabled, but UseUnmanagedSolutions was requested. Falling back to script-based unmanaged deployment."
}

if ($packageDeployerEnabled -and $insidePackageDeployer) {
    Write-Host "##[debug]Detected in-package deployment context. Running script-based deployment steps inside deployment package."
}

Invoke-Hooks -HookType "preDeploy" -BaseDirectory $ArtifactsPath -Config $solutionsConfig -AdditionalContext @{
    ArtifactsPath = $ArtifactsPath
    UseUnmanagedSolutions = $UseUnmanagedSolutions
}

# Define solutions to deploy
$solutions = @()
foreach ($solutionConfig in $solutionsConfig.solutions) {
    if ($UseUnmanagedSolutions -or ($solutionConfig.PSObject.Properties.Name -contains 'deployUnmanaged' -and $solutionConfig.deployUnmanaged -eq $true)) {
        $fileName = "$($solutionConfig.name).zip"
    }
    else {
        $fileName = "$($solutionConfig.name)_managed.zip"
    }
    
    $solutions += @{
        Name = $solutionConfig.name
        File = Join-Path $ArtifactsPath solutions $fileName
    }
}
$connectionReferences = @{}

# Find all env vars prefixed with "DataverseConnRef_" to set as connection references
Get-ChildItem Env: | Where-Object { $_.Name -like "DataverseConnRef_*" } | ForEach-Object {
    $connRefName = $_.Name.Substring(17) # Remove "DataverseConnRef_" prefix
    $connectionReferences[$connRefName] = $_.Value
}

$environmentVariables = @{}

# Find all env vars prefixed with "DataverseEnvVar_" to set as environment variables
Get-ChildItem Env: | Where-Object { $_.Name -like "DataverseEnvVar_*" } | ForEach-Object {
    $envVarName = $_.Name.Substring(16) # Remove "DataverseEnvVar_" prefix
    $environmentVariables[$envVarName] = $_.Value
}

# Stage all solutions first (in dependency order)
Write-Host "##[section]Staging solutions"
$importTimeoutSeconds = if ($null -ne $solutionsConfig.importTimeoutSeconds) { $solutionsConfig.importTimeoutSeconds } else { 10800 }
$connectionReferences.GetEnumerator() | ForEach-Object {
    Write-Host "##[debug]Connection Reference: $($_.Key) = $($_.Value)"
}
$environmentVariables.GetEnumerator() | ForEach-Object {
    Write-Host "##[debug]Environment Variable: $($_.Key) = $($_.Value)"
}
foreach ($solution in $solutions) {
    Write-Host "##[group]Staging solution: $($solution.Name) from file: $($solution.File)"

    $mode = if ($UseUnmanagedSolutions) { 
        "NoUpgrade"
    }
    elseif ($solutions.Count -eq 1) {
        # Optimisation: if only one solution, can do "Auto" mode
        "Auto" 
    }
    else { 
        "HoldingSolution" 
    }

    Import-DataverseSolution `
        -Verbose `
        -InFile $solution.File `
        -Mode $mode `
        -TimeoutSeconds $importTimeoutSeconds `
        -EnvironmentVariables $environmentVariables `
        -ConnectionReferences $connectionReferences `
        -PublishWorkflows `
        -OverwriteUnmanagedCustomizations:(-not $UseUnmanagedSolutions) `
        -SkipIfSameVersion `
        -UseUpdateIfVersionMajorMinorMatches:(-not $UseUnmanagedSolutions)
    Write-Host "##[endgroup]"
}


Invoke-Hooks -HookType "dataMigrations" -BaseDirectory $ArtifactsPath -Config $solutionsConfig -AdditionalContext @{
    ArtifactsPath = $ArtifactsPath
    UseUnmanagedSolutions = $UseUnmanagedSolutions
}

# Apply upgrades in reverse order (most dependent first)
Write-Host "##[section]Applying solution upgrades"
[array]::Reverse($solutions)
foreach ($solution in $solutions) {
    Write-Host "##[group]Apply solution upgrade (if required): $($solution.Name)"
    Invoke-DataverseSolutionUpgrade -Verbose -SolutionName $solution.Name -IfExists
    Write-Host "##[endgroup]"
}

# Activate workflows/flows
[array]::Reverse($solutions)
Write-Host "##[section]Activating Processes"

foreach ($solution in $solutions) {
    Write-Host "##[group]Activating processes for solution: $($solution.Name)"

    if ($solution.PSObject.Properties.Name -contains 'serviceAccountUpnConfigKey' -and $solution.serviceAccountUpnConfigKey) {
        $serviceAccountUpnKey = $solution.serviceAccountUpnConfigKey
    }
    else {
        $serviceAccountUpnKey = 'DataverseServiceAccountUpn'
    }
    $serviceAccountUpnKey = $serviceAccountUpnKey.ToUpper()
    [string] $serviceAccountUpn = get-content env:$serviceAccountUpnKey -erroraction continue
    if ([string]::IsNullOrEmpty($serviceAccountUpn)) {
        Write-Host "##[error]Service account UPN not specified in environment variable '$serviceAccountUpnKey'."
        throw "Service account UPN not specified."
    } else {
        Write-Host "##[debug]Using service account UPN from environment variable '$serviceAccountUpnKey': $serviceAccountUpn"
    }

    $serviceAccountUser = Get-DataverseRecord -tablename systemuser -filtervalues @{domainname = $serviceAccountUpn}

    if ($null -eq $serviceAccountUser) {
        Write-Host "##[error]Service account user with UPN '$serviceAccountUpn' not found in Dataverse."
        throw "Service account user not found."
    } else {
        Write-Host "##[debug]Found service account user: $($serviceAccountUser.fullname) (ID: $($serviceAccountUser.Id))"
    }

    $processes = Get-DataverseRecord -TableName workflow `
        -FilterValues @{"and" = @(
                @{"solution.uniquename" = "$($solution.Name)"}
                @{"or" = @(
                    @{ "statecode:NotEqual" = 1 } # Not Activated
                    @{ "ownerid:NotEqual" = $serviceAccountUser.Id } # Activated
                )}
             )
        } `
        -Links @{"workflow.solutionid" = "solution.solutionid" } `
        -Columns name, workflowid

    if ($processes.Count -gt 0) {
        foreach ($process in $processes) {
            if ($process.ownerid -ne $serviceAccountUser.Id) {
                Write-Host "Reassigning process: $($process.name) to service account user: $($serviceAccountUser.fullname)"
                
                Set-DataverseRecord `
                    -TableName workflow `
                    -Id $process.workflowid `
                    -InputObject @{statecode = 0; statuscode = 1; }
                    
                Set-DataverseRecord `
                    -TableName workflow `
                    -Id $process.workflowid `
                    -InputObject @{ownerid = $serviceAccountUser.Id}
            }

            Write-Host "Activating process: $($process.name)"
            Set-DataverseRecord `
                -TableName workflow `
                -Id $process.workflowid `
                -InputObject @{statecode = 1; statuscode = 2; }
        }
    }
    else {
        Write-Host "##[debug]No draft processes found to activate for solution: $($solution.Name)"
    }
    Write-Host "##[endgroup]"
}
Write-Host "##[endgroup]"

# Publish all customizations
Write-Host "##[section]Publishing Customizations"
Publish-DataverseCustomizations

Invoke-Hooks -HookType "postDeploy" -BaseDirectory $ArtifactsPath -Config $solutionsConfig -AdditionalContext @{
    ArtifactsPath = $ArtifactsPath
    UseUnmanagedSolutions = $UseUnmanagedSolutions
}

Write-Host "##[section]Deployment  completed successfully!"
