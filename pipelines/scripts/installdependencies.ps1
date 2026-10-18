<#
.SYNOPSIS
    Installs required dependencies as defined in alm-config.psd1 with optional lock file.
.DESCRIPTION
    This script reads the alm-config.psd1 file to determine which PowerShell modules
    and PAC CLI version are needed for the scripts to run. Use -ForBuild when the
    operation may build configured Power Apps code apps; Node.js is installed only
    when that operation has at least one configured code app.

    It supports version pinning via a scriptDependencies.lock.json file which is used
    for consistent dependency versions in the version that goes into artifacts.

    The versions can be specified as:
    - '' (empty string): installs the latest version
    - 'prerelease': installs the latest prerelease version
    - specific version number (e.g. '1.2.3' or '1.2.3-beta.1'): installs that specific version
.NOTES
    Run from the directory containing alm-config.psd1 and any lock file. Installs
    modules for CurrentUser, imports their exact installed manifests in this process
    and installs/updates PAC under HOME/.alm4dataverse/tools using dotnet.
    A lock replaces module selectors and, when present, the PAC selector.
    Resolved module versions must meet the bundled numeric minimums.
    PATH is updated for this process and exported through available CI path channels.
.EXAMPLE
    .\alm\pipelines\scripts\installdependencies.ps1
    .\alm\pipelines\scripts\installdependencies.ps1 -ForBuild
#>

param(
    [Parameter()]
    [switch]$ForBuild
)

$ErrorActionPreference = 'Stop'

. $PSScriptRoot/common.ps1

function Get-NodePlatform {
    $architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    $architectureName = switch ($architecture) {
        'X64' { 'x64' }
        'Arm64' { 'arm64' }
        'Arm' { 'armv7l' }
        default { throw "Node.js installation does not support architecture '$architecture'." }
    }

    if ($IsWindows) {
        if ($architectureName -eq 'armv7l') {
            throw "Node.js installation does not support Windows architecture '$architecture'."
        }
        return "win-$architectureName"
    }
    if ($IsLinux) {
        return "linux-$architectureName"
    }
    if ($IsMacOS -and $architectureName -in @('x64', 'arm64')) {
        return "darwin-$architectureName"
    }

    throw 'Node.js installation is supported only on Windows, Linux, and macOS.'
}

function Get-NodeVersionFromCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandPath
    )

    $versionOutput = @(& $CommandPath --version 2>&1)
    if ($LASTEXITCODE -ne 0 -or $versionOutput.Count -ne 1 -or $versionOutput[0] -notmatch '^v(\d+\.\d+\.\d+)$') {
        return $null
    }

    return [version]$Matches[1]
}

function Test-NodeVersionMatch {
    param(
        [Parameter(Mandatory = $true)]
        [version]$InstalledVersion,

        [Parameter(Mandatory = $true)]
        [string]$VersionSpecifier
    )

    if ($VersionSpecifier -match '^\d+$') {
        return $InstalledVersion.Major -eq [int]$VersionSpecifier
    }

    return $InstalledVersion -eq [version]$VersionSpecifier
}

function Add-ToolDirectoryToPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory
    )

    $pathSeparator = [System.IO.Path]::PathSeparator
    if (-not (($env:PATH -split [regex]::Escape([string]$pathSeparator)) -contains $Directory)) {
        $env:PATH = "$Directory$pathSeparator$env:PATH"
    }

    if ($env:GITHUB_PATH) {
        $Directory | Out-File -FilePath $env:GITHUB_PATH -Append -Encoding utf8
    }
    if ($env:TF_BUILD -eq 'True') {
        Write-Host "##vso[task.prependpath]$Directory"
    }
}

function Install-ConfiguredNodeVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VersionSpecifier
    )

    $trimmedSpecifier = $VersionSpecifier.Trim() -replace '^v', ''
    if ($trimmedSpecifier -notmatch '^(\d+|\d+\.\d+\.\d+)$') {
        throw "nodeVersion '$VersionSpecifier' is invalid. Use a major version such as '22' or an exact version such as '22.14.0'."
    }

    $platform = Get-NodePlatform
    $versionParts = $trimmedSpecifier -split '\.'
    $versionMajor = [int]$versionParts[0]
    $requestedExactVersion = if ($versionParts.Count -eq 3) { [version]$trimmedSpecifier } else { $null }
    $existingNode = Get-Command node -ErrorAction SilentlyContinue
    if ($existingNode) {
        $existingVersion = Get-NodeVersionFromCommand -CommandPath $existingNode.Source
        if ($existingVersion -and (Test-NodeVersionMatch -InstalledVersion $existingVersion -VersionSpecifier $trimmedSpecifier)) {
            if (Get-Command npm -ErrorAction SilentlyContinue) {
                Write-Host "Using existing Node.js $existingVersion and npm"
                return
            }
        }
    }

    $nodeRoot = Join-Path $HOME '.alm4dataverse/tools/node'
    $cachedVersions = @()
    if (Test-Path -LiteralPath $nodeRoot -PathType Container) {
        foreach ($cachedDirectory in Get-ChildItem -LiteralPath $nodeRoot -Directory) {
            if ($cachedDirectory.Name -match ('^v' + $versionMajor + '\.(\d+)\.(\d+)-' + [regex]::Escape($platform) + '$')) {
                $cachedVersion = [version](($cachedDirectory.Name -replace ('-' + [regex]::Escape($platform) + '$'), '') -replace '^v', '')
                $cachedNodePath = Join-Path $cachedDirectory.FullName $(if ($IsWindows) { 'node.exe' } else { 'bin/node' })
                if (Test-Path -LiteralPath $cachedNodePath -PathType Leaf) {
                    $cachedVersions += [pscustomobject]@{ Version = $cachedVersion; Directory = $cachedDirectory.FullName; NodePath = $cachedNodePath }
                }
            }
        }
    }

    if ($requestedExactVersion) {
        $resolvedVersion = "v$requestedExactVersion"
    }
    elseif ($cachedVersions.Count -gt 0) {
        $cached = $cachedVersions | Sort-Object Version -Descending | Select-Object -First 1
        $resolvedVersion = "v$($cached.Version)"
    }
    else {
        $releases = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' -TimeoutSec 30
        $latestRelease = $releases | Where-Object { $_.version -match ('^v' + $versionMajor + '\.\d+\.\d+$') } | Select-Object -First 1
        if (-not $latestRelease) {
            throw "No stable Node.js release was found for major version $versionMajor."
        }
        $resolvedVersion = $latestRelease.version
    }

    $resolvedNodeDirectory = Join-Path $nodeRoot "$resolvedVersion-$platform"
    $nodeExecutable = Join-Path $resolvedNodeDirectory $(if ($IsWindows) { 'node.exe' } else { 'bin/node' })
    if (-not (Test-Path -LiteralPath $nodeExecutable -PathType Leaf)) {
        $archiveExtension = if ($IsWindows) { 'zip' } else { 'tar.xz' }
        $archiveName = "node-$resolvedVersion-$platform.$archiveExtension"
        $downloadRoot = Join-Path ([System.IO.Path]::GetTempPath()) "alm4dataverse-node-$([guid]::NewGuid().ToString('N'))"
        $extractRoot = Join-Path $downloadRoot 'extract'
        New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null

        try {
            $archivePath = Join-Path $downloadRoot $archiveName
            $checksumsPath = Join-Path $downloadRoot 'SHASUMS256.txt'
            $distributionUrl = "https://nodejs.org/dist/$resolvedVersion"
            Invoke-WebRequest -Uri "$distributionUrl/$archiveName" -OutFile $archivePath -TimeoutSec 120
            Invoke-WebRequest -Uri "$distributionUrl/SHASUMS256.txt" -OutFile $checksumsPath -TimeoutSec 30

            $checksumPattern = '^\s*([A-Fa-f0-9]{64})\s+\*?' + [regex]::Escape($archiveName) + '$'
            $checksumMatch = [regex]::Match((Get-Content -LiteralPath $checksumsPath -Raw), $checksumPattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)
            if (-not $checksumMatch.Success) {
                throw "Node.js checksum for '$archiveName' was not found in SHASUMS256.txt."
            }
            $actualChecksum = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
            if (-not $actualChecksum.Equals($checksumMatch.Groups[1].Value, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Node.js archive checksum verification failed for '$archiveName'."
            }

            if ($IsWindows) {
                Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot
            }
            else {
                $tar = Get-Command tar -ErrorAction SilentlyContinue
                if (-not $tar) {
                    throw "The tar command is required to extract Node.js for $platform."
                }
                & $tar.Source -xf $archivePath -C $extractRoot
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to extract Node.js archive '$archiveName'."
                }
            }

            $extractedDirectory = Join-Path $extractRoot "node-$resolvedVersion-$platform"
            if (-not (Test-Path -LiteralPath (Join-Path $extractedDirectory $(if ($IsWindows) { 'node.exe' } else { 'bin/node' })) -PathType Leaf)) {
                throw "Node.js archive '$archiveName' did not contain the expected executable."
            }
            New-Item -ItemType Directory -Path $nodeRoot -Force | Out-Null
            if (-not (Test-Path -LiteralPath $resolvedNodeDirectory)) {
                Move-Item -LiteralPath $extractedDirectory -Destination $resolvedNodeDirectory
            }
        }
        finally {
            Remove-Item -LiteralPath $downloadRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $installedNodeVersion = Get-NodeVersionFromCommand -CommandPath $nodeExecutable
    if (-not $installedNodeVersion -or -not (Test-NodeVersionMatch -InstalledVersion $installedNodeVersion -VersionSpecifier $trimmedSpecifier)) {
        throw "Installed Node.js version '$installedNodeVersion' does not satisfy nodeVersion '$VersionSpecifier'."
    }

    $npmExecutable = Join-Path $resolvedNodeDirectory $(if ($IsWindows) { 'npm.cmd' } else { 'bin/npm' })
    if (-not (Test-Path -LiteralPath $npmExecutable -PathType Leaf)) {
        throw "Node.js $installedNodeVersion was installed, but npm was not found at '$npmExecutable'."
    }
    $nodePathDirectory = if ($IsWindows) { $resolvedNodeDirectory } else { Join-Path $resolvedNodeDirectory 'bin' }
    Add-ToolDirectoryToPath -Directory $nodePathDirectory
    Write-Host "Using Node.js $installedNodeVersion and npm from $resolvedNodeDirectory"
}

Write-Host "##[group] Installing Dependencies"

$config = Get-AlmConfig

if ($ForBuild) {
    $configuredCodeApps = @()
    foreach ($solution in $config.solutions) {
        $configuredCodeApps += @(Get-SolutionCodeAppPath -Solution $solution -BaseDirectory (Get-Location).Path)
    }

    if ($configuredCodeApps.Count -gt 0) {
        if (-not $config.ContainsKey('nodeVersion') -or [string]::IsNullOrWhiteSpace([string]$config.nodeVersion)) {
            throw "nodeVersion must be configured when BUILD or IMPORT includes Power Apps code apps."
        }
        Install-ConfiguredNodeVersion -VersionSpecifier ([string]$config.nodeVersion)
    }
    else {
        Write-Host 'No Power Apps code apps are configured; skipping Node.js installation.'
    }
}

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
    $modulePathSeparator = [System.IO.Path]::PathSeparator
    $env:PSModulePath = "$bundledModulesDir$modulePathSeparator$env:PSModulePath"
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
        $installedNumericVersion = [version](([string]$installedModule.Version -split '-', 2)[0])
        $minimumNumericVersion = [version](([string]$defaultVersion -split '-', 2)[0])
        if ($installedNumericVersion -lt $minimumNumericVersion) {
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
    # Use the NuGet tool-list version for locking; absence/unmatched output yields
    # '' for the caller to reject. Build metadata after '+' is not part of the pin.
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
    <#
    .SYNOPSIS
        Normalizes a PAC NuGet selector or rejects unsupported version syntax.
    .DESCRIPTION
        Whitespace becomes '' (latest stable); 'prerelease' permits previews.
        Otherwise requires an exact three-part numeric version with an optional
        prerelease suffix, not a wildcard, range or build-metadata suffix.
    #>
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

function Test-IsWindowsMsiPacLauncher {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PacPath
    )

    if (-not (Test-Path $PacPath)) {
        return $false
    }

    $installHelpOutput = @(& $PacPath install --help 2>&1)
    $installHelpText = ($installHelpOutput | ForEach-Object { [string]$_ }) -join "`n"
    if ($installHelpText -match '(?im)not a valid command|not understood in this context') {
        return $false
    }

    $bannerOutput = @(& $PacPath 2>&1)
    $bannerText = ($bannerOutput | ForEach-Object { [string]$_ }) -join "`n"
    if ($bannerText -match '(?im)\.NET\s+Framework') {
        return $true
    }

    if ($installHelpText -match '(?im)\binstall\s+latest\b|\bmanage\s+versions\b') {
        return $true
    }

    return $false
}

function Get-PacCandidatePath {
    $candidates = New-Object System.Collections.Generic.List[string]

    $msiDefaultRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerAppsCLI'

    foreach ($candidate in @(
        (Join-Path $msiDefaultRoot 'pac.cmd'),
        (Join-Path $msiDefaultRoot 'pac.launcher.exe'),
        (Join-Path $msiDefaultRoot 'pac.exe')
    )) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path $candidate) -and -not $candidates.Contains($candidate)) {
            $candidates.Add($candidate)
        }
    }

    foreach ($candidate in @(
        (Join-Path $env:ProgramFiles 'Power Platform CLI\pac.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft Power Platform CLI\pac.exe'),
        (Join-Path $env:ProgramFiles 'Power Platform CLI\pac.cmd'),
        (Join-Path $env:ProgramFiles 'Microsoft Power Platform CLI\pac.cmd'),
        (Join-Path ${env:ProgramFiles(x86)} 'Power Platform CLI\pac.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Power Platform CLI\pac.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Power Platform CLI\pac.cmd'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Power Platform CLI\pac.cmd'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\PowerAppsCLI\pac.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\PowerAppsCLI\pac.cmd'),
        (Join-Path $env:LOCALAPPDATA 'PowerAppsCLI\pac.exe'),
        (Join-Path $env:LOCALAPPDATA 'PowerAppsCLI\pac.cmd')
    )) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path $candidate) -and -not $candidates.Contains($candidate)) {
            $candidates.Add($candidate)
        }
    }

    $pacCommand = Get-Command pac -ErrorAction SilentlyContinue
    if ($pacCommand -and -not [string]::IsNullOrWhiteSpace($pacCommand.Source) -and -not $candidates.Contains($pacCommand.Source)) {
        $candidates.Add($pacCommand.Source)
    }

    $wherePac = Get-Command where.exe -ErrorAction SilentlyContinue
    if ($wherePac) {
        $whereOutput = @(& $wherePac.Source pac 2>$null)
        foreach ($line in $whereOutput) {
            $path = ([string]$line).Trim()
            if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path $path) -and -not $candidates.Contains($path)) {
                $candidates.Add($path)
            }
        }
    }

    return @($candidates.ToArray())
}

function Resolve-PacWindowsMsiExecutablePath {
    foreach ($candidate in (Get-PacCandidatePath)) {
        if (Test-IsWindowsMsiPacLauncher -PacPath $candidate) {
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

$pacToolPath = Join-Path $HOME '.alm4dataverse/tools'
if (-not (Test-Path $pacToolPath)) {
    New-Item -ItemType Directory -Path $pacToolPath -Force | Out-Null
}

$isWindowsOS = Test-AlmOperatingSystemWindows

if ($isWindowsOS) {
    Write-Host "Installing PAC CLI on Windows using MSI method with version specifier: '$pacCliVersion'"

    $msiPath = Join-Path ([System.IO.Path]::GetTempPath()) "powerapps-cli-1.0.msi"
    Invoke-WebRequest -Uri 'https://aka.ms/PowerAppsCLI' -OutFile $msiPath

    $msiArguments = @('/i', "`"$msiPath`"", '/qn', '/norestart')
    $msiProcess = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArguments -Wait -PassThru
    if ($msiProcess.ExitCode -ne 0) {
        throw "Power Platform CLI MSI installation failed with exit code $($msiProcess.ExitCode)."
    }

    $pacPath = Resolve-PacWindowsMsiExecutablePath
    if ([string]::IsNullOrWhiteSpace($pacPath)) {
        $known = Get-PacCandidatePath
        $knownText = if ($known.Count -gt 0) { $known -join ', ' } else { '<none>' }
        throw "Power Platform CLI MSI installation completed but MSI launcher pac.exe could not be resolved. PAC candidates found: $knownText"
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
    $pacToolPath = Join-Path (Join-Path $HOME '.alm4dataverse') 'tools'
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

    $pathSeparator = [System.IO.Path]::PathSeparator
    # The current process needs PATH immediately; runner-specific channels persist it
    # for later steps, whose shells do not inherit this process's environment changes.
    if (-not (($env:PATH -split [regex]::Escape([string]$pathSeparator)) -contains $pacToolPath)) {
        $env:PATH = "$pacToolPath$pathSeparator$env:PATH"
    }

    $pacExecutableName = if ($isWindowsOS) { 'pac.exe' } else { 'pac' }
    $pacExePath = Join-Path $pacToolPath $pacExecutableName
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
