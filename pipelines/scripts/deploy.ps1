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
