<#
.SYNOPSIS
    Installs required dependencies as defined in alm-config.psd1 with optional lock file.
.DESCRIPTION
    This script reads the alm-config.psd1 file to determine which PowerShell modules
    and PAC CLI version are needed for the scripts to run.

    It supports version pinning via a scriptDependencies.lock.json file which is used
    for consistent dependency versions in the version that goes into artifacts.

    The versions can be specified as:
    - '' (empty string): installs the latest version
    - 'prerelease': installs the latest prerelease version
    - specific version number (e.g. '1.2.3' or '1.2.3-beta.1'): installs that specific version
#>

. $PSScriptRoot/common.ps1

Write-Host "##[group] Installing Dependencies"

$config = Get-AlmConfig

$lockFile = 'scriptDependencies.lock.json'
if (Test-Path $lockFile) {
    $lockData = Get-Content $lockFile -Raw | ConvertFrom-Json -AsHashtable
    $config.scriptDependencies = $lockData.scriptDependencies
    if ($lockData.ContainsKey('pacCliVersion')) {
        $config.pacCliVersion = $lockData.pacCliVersion
    }
    Write-Host "Using pinned versions from lock file"
}

# If bundled modules directory exists (self-contained/offline mode), use those directly
$bundledModulesDir = Join-Path (Get-Location) 'modules'
$usingBundledModules = $false
if (Test-Path $bundledModulesDir) {
    $usingBundledModules = $true
    Write-Host "Using bundled modules from $bundledModulesDir"
    $env:PSModulePath = "$bundledModulesDir;$env:PSModulePath"
    foreach ($module in $config.scriptDependencies.Keys) {
        Import-Module $module -ErrorAction Stop
        $loadedModule = Get-Module -Name $module
        Write-Host "Loaded bundled $module version $($loadedModule.Version) $($loadedModule.Prerelease)"
    }
}

if (-not $usingBundledModules) {
foreach ($module in $config.scriptDependencies.Keys) {

    $version = $config.scriptDependencies[$module]

    Write-Host "Installing $module module with version specifier: '$version'"
    if ($version -eq '') {
        $installedModule = Install-Module -Name $module -Scope CurrentUser -Force -PassThru
    }
    elseif ($version -eq 'prerelease') {
        $installedModule = Install-Module -Name $module -Scope CurrentUser -Force -AllowPrerelease -PassThru
    }
    else {
        $installedModule = Install-Module -Name $module -Scope CurrentUser -Force -RequiredVersion $version -AllowPrerelease:($version.Contains("-")) -PassThru
    }
    Write-Host "Installed $module version $($installedModule.Version)"
    
    if ($config._defaults.scriptDependencies.ContainsKey($module)) {
        $defaultVersion = $config._defaults.scriptDependencies[$module]
        if (([version] $version) -lt ([version]$defaultVersion)) {
            throw "Installed version $($installedModule.Version) of $module is less than the default minimum required version $defaultVersion. Please update the version in alm-config.psd1."
        }
    }

    # Manually load the installed module to ensure the correct version is used
    # This is complex because Import-Module does not support version ranges or prerelease directly

    # This ensures that we load the exact installed version even when running locally
    # where multiple versions may be present

    $moduletoload = get-installedmodule -Name $module -RequiredVersion $installedModule.Version -AllowPrerelease:($installedModule.Version.Contains("-"))

    if (-not $moduletoload) {
        Write-Host "##[error]Failed to find installed module $module version $($installedModule.Version)"
        
        throw "Failed to find installed module $module version $($installedModule.Version)"
    }
    Import-Module "$($moduletoload.InstalledLocation)/*.psd1"
  
    $loadedModule = Get-Module -Name $module
    Write-Host "Loaded $module version $($loadedModule.Version) $($loadedModule.Prerelease)"
}
}

if ($usingBundledModules) {
    Write-Host "Dependencies loaded from bundled modules"
}

function Get-PacCliInstalledPackageVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PacPath
    )

    if (-not (Test-Path $PacPath)) {
        return ''
    }

    $versionOutput = @(& $PacPath --version 2>&1)
    if ($LASTEXITCODE -eq 0) {
        foreach ($line in $versionOutput) {
            $lineText = [string]$line
            if ($lineText -match '(?i)^\s*Version\s*:\s*(\d+\.\d+\.\d+(?:-[0-9A-Za-z][0-9A-Za-z\.-]*)?)(?:\+[0-9A-Za-z\.-]+)?(?:\s|$)') {
                return $Matches[1]
            }
        }

        $versionText = ($versionOutput | ForEach-Object { [string]$_ }) -join "`n"
        if ($versionText -match '(?im)^\s*(\d+\.\d+\.\d+(?:-[0-9A-Za-z][0-9A-Za-z\.-]*)?)(?:\+[0-9A-Za-z\.-]+)?\s*$') {
            return $Matches[1]
        }
    }

    $helpOutput = @(& $PacPath 2>&1)
    if ($LASTEXITCODE -eq 0) {
        foreach ($line in $helpOutput) {
            $lineText = [string]$line
            if ($lineText -match '(?i)^\s*Version\s*:\s*(\d+\.\d+\.\d+(?:-[0-9A-Za-z][0-9A-Za-z\.-]*)?)(?:\+[0-9A-Za-z\.-]+)?(?:\s|$)') {
                return $Matches[1]
            }
        }
    }

    return ''
}

function Resolve-PacCliVersionSpecifier {
    param(
        [Parameter(Mandatory = $false)]
        [string]$RawValue
    )

    if ([string]::IsNullOrWhiteSpace($RawValue)) {
        return ''
    }

    $trimmed = $RawValue.Trim()
    if ($trimmed -eq 'prerelease') {
        return 'prerelease'
    }

    if ($trimmed -match '^\d+\.\d+\.\d+(?:-[0-9A-Za-z][0-9A-Za-z\.-]*)?$') {
        return $trimmed
    }

    throw "pacCliVersion '$RawValue' is invalid. Use '', 'prerelease', or an exact CLI version like '1.50.1' or '2.7.4-preview.1'."
}

function Resolve-PacExecutablePath {
    $pacCommand = Get-Command pac -ErrorAction SilentlyContinue
    if ($pacCommand) {
        return $pacCommand.Source
    }

    $candidatePaths = @(
        (Join-Path $env:ProgramFiles 'Power Platform CLI\pac.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Power Platform CLI\pac.exe'),
        (Join-Path $HOME '.alm4dataverse\tools\pac.exe')
    )

    foreach ($candidate in $candidatePaths) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path $candidate)) {
            return $candidate
        }
    }

    return ''
}

$pacCliVersion = ''
if ($config.ContainsKey('pacCliVersion') -and $null -ne $config.pacCliVersion) {
    $pacCliVersion = [string]$config.pacCliVersion
}

$pacCliVersion = Resolve-PacCliVersionSpecifier -RawValue $pacCliVersion

$isWindowsOS = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)

if ($isWindowsOS) {
    Write-Host "Installing PAC CLI on Windows using MSI method with version specifier: '$pacCliVersion'"

    $pacPath = Resolve-PacExecutablePath
    if ([string]::IsNullOrWhiteSpace($pacPath)) {
        $msiPath = Join-Path ([System.IO.Path]::GetTempPath()) "powerapps-cli-1.0.msi"
        Invoke-WebRequest -Uri 'https://aka.ms/PowerAppsCLI' -OutFile $msiPath

        $msiArguments = @('/i', "`"$msiPath`"", '/qn', '/norestart')
        $msiProcess = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArguments -Wait -PassThru
        if ($msiProcess.ExitCode -ne 0) {
            throw "Power Platform CLI MSI installation failed with exit code $($msiProcess.ExitCode)."
        }

        $pacPath = Resolve-PacExecutablePath
        if ([string]::IsNullOrWhiteSpace($pacPath)) {
            throw "Power Platform CLI MSI installation completed but pac.exe could not be resolved on PATH or known install locations."
        }
    }

    $pacDirectory = Split-Path -Parent $pacPath
    if (-not (($env:PATH -split ';') -contains $pacDirectory)) {
        $env:PATH = "$pacDirectory;$env:PATH"
    }
    if ($env:GITHUB_PATH) {
        $pacDirectory | Out-File -FilePath $env:GITHUB_PATH -Append -Encoding utf8
    }
    if ($env:TF_BUILD -eq 'True') {
        Write-Host "##vso[task.prependpath]$pacDirectory"
    }

    if ($pacCliVersion -eq 'prerelease') {
        throw "pacCliVersion 'prerelease' is not supported with Windows MSI installation. Use '' (latest) or an exact version."
    }

    if ([string]::IsNullOrWhiteSpace($pacCliVersion)) {
        & $pacPath install latest
    }
    else {
        & $pacPath install $pacCliVersion
    }

    if (-not $?) {
        throw "Failed to install PAC CLI version '$pacCliVersion' via Windows MSI method."
    }

    $pacVersion = Get-PacCliInstalledPackageVersion -PacPath $pacPath
    if ([string]::IsNullOrWhiteSpace($pacVersion)) {
        throw "PAC CLI installation completed but the installed version could not be resolved from pac output."
    }

    Write-Host "Installed PAC CLI version $pacVersion"
}
else {
    $pacToolPath = Join-Path $HOME '.alm4dataverse\tools'
    if (-not (Test-Path $pacToolPath)) {
        New-Item -ItemType Directory -Path $pacToolPath -Force | Out-Null
    }

    $installArgs = @('tool', 'install', 'Microsoft.PowerApps.CLI.Tool', '--tool-path', $pacToolPath)
    $updateArgs = @('tool', 'update', 'Microsoft.PowerApps.CLI.Tool', '--tool-path', $pacToolPath)

    if ($pacCliVersion -eq 'prerelease') {
        $installArgs += '--prerelease'
        $updateArgs += '--prerelease'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($pacCliVersion)) {
        $installArgs += @('--version', $pacCliVersion)
        $updateArgs += @('--version', $pacCliVersion)
    }

    Write-Host "Installing PAC CLI with version specifier: '$pacCliVersion'"

    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $dotnet) {
        throw "dotnet command not found in PATH. dotnet is required to install PAC CLI."
    }

    $pacExePath = Join-Path $pacToolPath 'pac.exe'
    if (Test-Path $pacExePath) {
        & dotnet @updateArgs
        if (-not $?) {
            Write-Host "PAC CLI update failed. Reinstalling..."
            & dotnet tool uninstall Microsoft.PowerApps.CLI.Tool --tool-path $pacToolPath | Out-Null
            & dotnet @installArgs
        }
    }
    else {
        & dotnet @installArgs
    }

    if (-not $?) {
        throw "Failed to install PAC CLI."
    }

    if (-not (($env:PATH -split ';') -contains $pacToolPath)) {
        $env:PATH = "$pacToolPath;$env:PATH"
    }

    if ($env:GITHUB_PATH) {
        $pacToolPath | Out-File -FilePath $env:GITHUB_PATH -Append -Encoding utf8
    }

    if ($env:TF_BUILD -eq 'True') {
        Write-Host "##vso[task.prependpath]$pacToolPath"
    }

    if (-not (Test-Path $pacExePath)) {
        throw "PAC CLI installation completed but pac.exe was not found at $pacExePath"
    }

    $pacVersion = Get-PacCliInstalledPackageVersion -PacPath $pacExePath

    if ([string]::IsNullOrWhiteSpace($pacVersion)) {
        throw "PAC CLI installation completed but the installed version could not be resolved from pac output."
    }

    Write-Host "Installed PAC CLI version $pacVersion"
}

Write-Host "Dependencies Installed"
Write-Host "##[endgroup]"
