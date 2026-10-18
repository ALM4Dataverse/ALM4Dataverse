<#
.SYNOPSIS
    Deploy Dataverse solutions from artifacts.
.DESCRIPTION
    This script deploys the Dataverse solutions found in the specified artifacts path
    to the connected Dataverse environment. It supports both managed and unmanaged
    solutions based on the provided parameter.

    It also sets connection references and environment variables based on environment
    variables prefixed with "DataverseConnRef_" and "DataverseEnvVar_" respectively.

    Configured organization-table, OrgDbOrgSettings, and Power Platform environment
    settings are applied before the preDeploy hook and again after the postDeploy
    hook when post-deployment maps are configured. Power Platform API settings use
    the authenticated Azure identity and require tenant-scoped Power Platform RBAC.

    Hooks defined in alm-config.psd1 are invoked at various stages of the deployment
    process to allow for custom pre- and post-deployment actions.
.PARAMETER ArtifactsPath
    The path to the artifacts containing the solutions to deploy.
.PARAMETER UseUnmanagedSolutions
    Forces unmanaged packages for every solution, overriding per-solution preferences.
.NOTES
    Requires installed dependencies and a default Dataverse connection. Reads
    alm-config.psd1 from the artifacts root. Solutions must be listed in dependency
    order. Stages packages, runs migrations, applies managed upgrades in reverse
    order, then assigns/activates processes and publishes all customizations.
    Service-account UPN comes from the configured environment-variable key (default
    DataverseServiceAccountUpn); missing users/values fail after any earlier imports.
    Deployment is not transactional and does not roll back earlier side effects.
    Code apps are patched into existing solution components by default before imports.
    Setting codeAppPublishMethod to 'pac' retains the PAC push path and its Power
    Platform API RBAC requirements.
.EXAMPLE
    .\pipelines\scripts\deploy.ps1 -ArtifactsPath .\artifacts
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

$organizationSettingsContext = @{
    HookType = 'preDeploy'
    BaseDirectory = $ArtifactsPath
    Config = $solutionsConfig
    ArtifactsPath = $ArtifactsPath
    UseUnmanagedSolutions = $UseUnmanagedSolutions
}

Invoke-ConfiguredOrganizationSettingMap -Settings $solutionsConfig.organizationSettings -SettingMapName 'organizationSettings' -Context $organizationSettingsContext
Invoke-ConfiguredOrganizationSettingMap -Settings $solutionsConfig.orgDbOrgSettings -SettingMapName 'orgDbOrgSettings' -Context $organizationSettingsContext -OrgDbOrgSettings
$powerPlatformEnvironmentContext = @{}
Invoke-PowerPlatformSettingMap -Settings $solutionsConfig.powerPlatformSettings -SettingMapName 'powerPlatformSettings' -Context $organizationSettingsContext -EnvironmentContext $powerPlatformEnvironmentContext

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

    $packageExtractionDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("alm4dataverse-package-deploy-" + [guid]::NewGuid().ToString('N'))
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($packagePath, $packageExtractionDirectory)
        $packageAssemblyPath = Join-Path $packageExtractionDirectory 'ALM4Dataverse.PackageDeployer.dll'
        if (-not (Test-Path -LiteralPath $packageAssemblyPath -PathType Leaf)) {
            throw "Package Deployer archive '$packagePath' does not contain ALM4Dataverse.PackageDeployer.dll at its root."
        }
        Write-Host "##[debug]Package assembly path: $packageAssemblyPath"

        $pacArguments = @('package', 'deploy', '--package', $packageAssemblyPath, '--environment', $targetEnvironment, '--logConsole')
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
    }
    finally {
        if (Test-Path -LiteralPath $packageExtractionDirectory -PathType Container) {
            Remove-Item -LiteralPath $packageExtractionDirectory -Recurse -Force
        }
    }
    return
}

if ($packageDeployerEnabled -and $UseUnmanagedSolutions) {
    Write-Host "##[section]Package Deployer deployment is enabled, but UseUnmanagedSolutions was requested. Falling back to script-based unmanaged deployment."
}

if ($packageDeployerEnabled -and $insidePackageDeployer) {
    Write-Host "##[debug]Detected in-package deployment context. Running script-based deployment steps inside deployment package."
}

Invoke-Hook -HookType "preDeploy" -BaseDirectory $ArtifactsPath -Config $solutionsConfig -AdditionalContext @{
    ArtifactsPath = $ArtifactsPath
    UseUnmanagedSolutions = $UseUnmanagedSolutions
}

# Define solutions to deploy
$solutions = @()
foreach ($solutionConfig in $solutionsConfig.solutions) {
    $deployUnmanaged = $UseUnmanagedSolutions -or ($solutionConfig.ContainsKey('deployUnmanaged') -and $solutionConfig.deployUnmanaged -eq $true)
    if ($deployUnmanaged) {
        $fileName = "$($solutionConfig.name).zip"
    }
    else {
        $fileName = "$($solutionConfig.name)_managed.zip"
    }

    $serviceAccountUpnKey = 'DataverseServiceAccountUpn'
    if ($solutionConfig.ContainsKey('serviceAccountUpnConfigKey') -and -not [string]::IsNullOrWhiteSpace($solutionConfig.serviceAccountUpnConfigKey)) {
        $serviceAccountUpnKey = $solutionConfig.serviceAccountUpnConfigKey
    }

    $codeAppPublishMethod = 'solution'
    if ($solutionConfig.ContainsKey('codeAppPublishMethod') -and
        -not [string]::IsNullOrWhiteSpace([string]$solutionConfig.codeAppPublishMethod)) {
        $codeAppPublishMethod = ([string]$solutionConfig.codeAppPublishMethod).Trim().ToLowerInvariant()
    }
    if ($codeAppPublishMethod -notin @('solution', 'pac')) {
        throw "Solution '$($solutionConfig.name)' codeAppPublishMethod '$codeAppPublishMethod' is invalid. Use 'solution' or 'pac'."
    }

    $solutionsDirectory = Join-Path -Path $ArtifactsPath -ChildPath 'solutions'
    $solutions += @{
        Name = $solutionConfig.name
        File = Join-Path -Path $solutionsDirectory -ChildPath $fileName
        DeployUnmanaged = $deployUnmanaged
        ServiceAccountUpnConfigKey = $serviceAccountUpnKey
        CodeApps = @(Get-SolutionCodeAppPath -Solution $solutionConfig -BaseDirectory $ArtifactsPath)
        CodeAppPublishMethod = $codeAppPublishMethod
    }
}

Write-Host "##[section]Preparing Code App solution packages"
foreach ($solution in $solutions) {
    if ($solution.CodeAppPublishMethod -ne 'solution') {
        continue
    }
    foreach ($codeAppPath in $solution.CodeApps) {
        Update-SolutionCodeAppPackage `
            -SolutionFile $solution.File `
            -CodeAppPath $codeAppPath `
            -SolutionName $solution.Name
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

# Holding solutions keep old components available until every dependent package
# is staged and dataMigrations has run; removal upgrades then run most-dependent first.
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

    $mode = if ($solution.DeployUnmanaged) {
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
        -OverwriteUnmanagedCustomizations:(-not $solution.DeployUnmanaged) `
        -SkipIfSameVersion `
        -UseUpdateIfVersionMajorMinorMatches:(-not $solution.DeployUnmanaged)
    Write-Host "##[endgroup]"
}


Invoke-Hook -HookType "dataMigrations" -BaseDirectory $ArtifactsPath -Config $solutionsConfig -AdditionalContext @{
    ArtifactsPath = $ArtifactsPath
    UseUnmanagedSolutions = $UseUnmanagedSolutions
}

# Apply upgrades in reverse order (most dependent first)
Write-Host "##[section]Applying solution upgrades"
[array]::Reverse($solutions)
foreach ($solution in $solutions) {
    if ($solution.DeployUnmanaged) {
        continue
    }
    Write-Host "##[group]Apply solution upgrade (if required): $($solution.Name)"
    Invoke-DataverseSolutionUpgrade -Verbose -SolutionName $solution.Name -IfExists
    Write-Host "##[endgroup]"
}

# Activate workflows/flows
[array]::Reverse($solutions)
Write-Host "##[section]Activating Processes"

foreach ($solution in $solutions) {
    Write-Host "##[group]Activating processes for solution: $($solution.Name)"

    $serviceAccountUpnKey = $solution.ServiceAccountUpnConfigKey.ToUpperInvariant()
    [string] $serviceAccountUpn = [System.Environment]::GetEnvironmentVariable($serviceAccountUpnKey)
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

    $processes = @(Get-DataverseRecord -TableName workflow `
        -FilterValues @{"and" = @(
                @{"solution.uniquename" = "$($solution.Name)"}
                @{"or" = @(
                    @{ "statecode:NotEqual" = 1 } # Not Activated
                    @{ "ownerid:NotEqual" = $serviceAccountUser.Id } # Ownership also requires correction
                )}
             )
        } `
        -Links @{"workflow.solutionid" = "solution.solutionid" } `
        -Columns name, workflowid)

    if ($processes.Count -gt 0) {
        foreach ($process in $processes) {
            if ($process.ownerid -ne $serviceAccountUser.Id) {
                # Deactivate before changing owner, then activate under the service account.
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

foreach ($solution in $solutions) {
    if ($solution.CodeAppPublishMethod -ne 'pac' -or $solution.CodeApps.Count -eq 0) {
        continue
    }
    foreach ($codeAppPath in $solution.CodeApps) {
        if ([string]::IsNullOrWhiteSpace($env:DATAVERSE_URL)) {
            throw "DATAVERSE_URL is required to push code apps for solution '$($solution.Name)'. Connect to the target environment before deployment."
        }

        $pac = Get-Command pac -ErrorAction SilentlyContinue
        if (-not $pac) {
            throw 'Power Apps CLI (pac) was not found on PATH.'
        }

        Write-Host "##[group]Pushing code app for solution '$($solution.Name)' from '$codeAppPath'"
        $pacArgs = @('code', 'push', '--environment', $env:DATAVERSE_URL, '--solutionName', $solution.Name)
        Push-Location -LiteralPath $codeAppPath
        try {
            $pacOutput = @(& $pac.Source @pacArgs 2>&1)
            $pacExitCode = $LASTEXITCODE
            $pacOutputText = ($pacOutput | ForEach-Object { [string]$_ }) -join "`n"
            $apiRequestFailed = $pacOutputText -match '(?im)HTTP error status:\s*[45]\d{2}\s+for\s+(GET|POST|PUT|PATCH|DELETE)\s+https?://\S*/powerapps/'
            if ($pacExitCode -ne 0 -or $apiRequestFailed) {
                $failureMessage = "PAC code push failed for solution '$($solution.Name)' with exit code $pacExitCode."
                if ($apiRequestFailed -and $pacExitCode -eq 0) {
                    $failureMessage += ' PAC reported an API request failure despite returning success.'
                }
                $failureMessage += "`nPAC output:`n$pacOutputText"
                throw $failureMessage
            }
            foreach ($line in $pacOutput) {
                Write-Host ([string]$line)
            }
        }
        finally {
            Pop-Location
            Write-Host "##[endgroup]"
        }
    }
}

Invoke-Hook -HookType "postDeploy" -BaseDirectory $ArtifactsPath -Config $solutionsConfig -AdditionalContext @{
    ArtifactsPath = $ArtifactsPath
    UseUnmanagedSolutions = $UseUnmanagedSolutions
}

$organizationSettingsContext.HookType = 'postDeploy'
Invoke-ConfiguredOrganizationSettingMap -Settings $solutionsConfig.postDeployOrganizationSettings -SettingMapName 'postDeployOrganizationSettings' -Context $organizationSettingsContext
Invoke-ConfiguredOrganizationSettingMap -Settings $solutionsConfig.postDeployOrgDbOrgSettings -SettingMapName 'postDeployOrgDbOrgSettings' -Context $organizationSettingsContext -OrgDbOrgSettings
Invoke-PowerPlatformSettingMap -Settings $solutionsConfig.postDeployPowerPlatformSettings -SettingMapName 'postDeployPowerPlatformSettings' -Context $organizationSettingsContext -EnvironmentContext $powerPlatformEnvironmentContext

Write-Host "##[section]Deployment  completed successfully!"
