function Install-PortableGit {
    <#
    .SYNOPSIS
    Returns the Git bin directory, using system Git off Windows or installing portable Git on Windows.
    .NOTES
    Non-Windows systems require Git on PATH. Windows reuses an existing bin\git.exe
    without version verification; download, extraction and missing-executable failures
    terminate setup. PATH is updated by the caller.
    .PARAMETER Platform
    Defaults to the current platform; overridable for testing the Windows installer path.
    #>
    param(
        [Parameter(Mandatory)][string]$Destination,
        [System.PlatformID]$Platform = [System.Environment]::OSVersion.Platform
    )

    if ($Platform -ne [System.PlatformID]::Win32NT) {
        $gitCommand = Get-Command git -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $gitCommand) {
            throw 'Git must be installed and available on PATH on non-Windows systems.'
        }

        $gitBinDir = Split-Path -Parent $gitCommand.Source
        Write-Host "Using system Git at: $($gitCommand.Source)"
        return $gitBinDir
    }

    $gitDir = Join-Path $Destination "Git"
    $gitBinDir = Join-Path $gitDir 'bin'
    $gitExe = Join-Path $gitBinDir 'git.exe'

    if (Test-Path -LiteralPath $gitExe -PathType Leaf) {
        Write-Host "Git already available at: $gitExe"
        return $gitBinDir
    }

    Write-Host "Downloading portable Git..." -ForegroundColor Yellow
    $gitUrl = "https://github.com/git-for-windows/git/releases/download/v2.52.0.windows.1/PortableGit-2.52.0-64-bit.7z.exe"
    $gitInstaller = Join-Path $Destination "PortableGit.exe"

    try {
        # PowerShell 5.1 sometimes needs TLS 1.2 explicitly.
        try {
            if ($PSVersionTable.PSVersion.Major -lt 6) {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            }
        }
        catch {
            Write-Verbose 'Could not set the legacy TLS preference; continuing with the current protocol settings.'
        }

        Invoke-WebRequest -Uri $gitUrl -OutFile $gitInstaller -UseBasicParsing

        if (-not (Test-Path $gitInstaller)) {
            throw "Failed to download Git installer"
        }

        Write-Host "Extracting portable Git to $gitDir..." -ForegroundColor Yellow
        New-DirectoryIfMissing -Path $gitDir

        # The .7z.exe is a self-extracting archive
        $extractArgs = @('-o"' + $gitDir + '"', '-y')
        $process = Start-Process -FilePath $gitInstaller -ArgumentList $extractArgs -Wait -NoNewWindow -PassThru

        if ($process.ExitCode -ne 0) {
            throw "Git extraction failed with exit code $($process.ExitCode)"
        }

        # Clean up installer
        Remove-Item $gitInstaller -Force -ErrorAction SilentlyContinue

        if (-not (Test-Path -LiteralPath $gitExe -PathType Leaf)) {
            throw "Git extraction completed but git.exe not found at expected location"
        }

        Write-Host "Git extracted successfully to: $gitDir"
        return $gitBinDir
    }
    catch {
        Write-Host "Failed to install portable Git: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}
