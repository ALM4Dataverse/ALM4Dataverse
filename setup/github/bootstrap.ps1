function Install-PortableGitHubCli {
    <#
    .SYNOPSIS
        Returns the bin directory of the GitHub CLI used by setup.
    .DESCRIPTION
        Uses gh from PATH on non-Windows systems, where setup cannot install system
        packages. On Windows, reuses an existing gh.exe without checking its version or
        downloads the latest architecture-specific release and replaces the installation
        directory. Throws for a missing non-Windows gh, unsupported Windows architectures
        or download/extraction failures. The Windows archive is removed in finally; the
        extracted installation is retained for reuse.
    .PARAMETER Destination
        Windows installation directory for the downloaded GitHub CLI.
    .PARAMETER Platform
        Defaults to the current platform; overridable for testing the Windows installer path.
    #>
    param(
        [Parameter(Mandatory)][string]$Destination,
        [System.PlatformID]$Platform = [System.Environment]::OSVersion.Platform
    )

    if ($Platform -ne [System.PlatformID]::Win32NT) {
        $ghCommand = Get-Command gh -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $ghCommand) {
            throw 'GitHub CLI (gh) must be installed and available on PATH on non-Windows systems. Azure Cloud Shell includes it.'
        }

        Write-Host "Using system GitHub CLI at: $($ghCommand.Source)"
        return (Split-Path -Parent $ghCommand.Source)
    }

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
