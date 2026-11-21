function Install-PortableGitHubCli {
    <#
    .SYNOPSIS
        Returns the bin directory of a Windows GitHub CLI installed beneath Destination.
    .DESCRIPTION
        Reuses an existing gh.exe without checking its version. Otherwise downloads the
        latest architecture-specific release and replaces the installation directory.
        Throws for unsupported architectures or download/extraction failures; removes
        the archive in finally, but retains the extracted installation for reuse.
    #>
    param(
        [Parameter(Mandatory)][string]$Destination
    )

    $architecture = switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { 'amd64' }
        'ARM64' { 'arm64' }
        'x86' { '386' }
        default { throw "Unsupported processor architecture '$env:PROCESSOR_ARCHITECTURE' for GitHub CLI." }
    }

    $installDir = Join-Path $Destination 'GitHubCLI'
    $ghBinDir = Join-Path $installDir 'bin'
    $ghExe = Join-Path $ghBinDir 'gh.exe'
    if (Test-Path -LiteralPath $ghExe) {
        Write-Host "GitHub CLI already available at: $ghExe"
        return $ghBinDir
    }

    $archivePath = Join-Path $Destination 'GitHubCLI.zip'
    try {
        if ($PSVersionTable.PSVersion.Major -lt 6) {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        }

        Write-Host "Downloading GitHub CLI..." -ForegroundColor Yellow
        $release = Invoke-RestMethod `
            -Uri 'https://api.github.com/repos/cli/cli/releases/latest' `
            -Headers @{ Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' } `
            -UseBasicParsing
        $asset = $release.assets |
            Where-Object { $_.name -match "^gh_.+_windows_$architecture\.zip$" } |
            Select-Object -First 1
        if (-not $asset) {
            throw "Could not find a GitHub CLI release archive for Windows architecture '$architecture'."
        }

        if (Test-Path -LiteralPath $installDir) {
            Remove-Item -LiteralPath $installDir -Recurse -Force
        }
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $archivePath -UseBasicParsing
        Expand-SetupConsoleArchive -ArchivePath $archivePath -DestinationPath $installDir

        $ghBinDir = Join-Path $installDir 'bin'
        $ghExe = Join-Path $ghBinDir 'gh.exe'
        if (-not (Test-Path -LiteralPath $ghExe)) {
            throw "GitHub CLI was extracted but gh.exe was not found at the expected location: $ghExe"
        }

        Write-Host "GitHub CLI downloaded to: $ghExe"
        return $ghBinDir
    }
    catch {
        Write-Host "Failed to download GitHub CLI: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
    finally {
        if (Test-Path -LiteralPath $archivePath) {
            Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
        }
    }
}
