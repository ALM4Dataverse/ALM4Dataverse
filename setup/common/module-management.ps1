function Get-ModulePathDelimiter {
    return [System.IO.Path]::PathSeparator
}

function Install-NuGetProviderIfMissing {
    # Installs for the current user only when provider discovery returns nothing;
    # installation errors follow the caller's error preference.
    $nuget = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
    if (-not $nuget) {
        Write-Host "Installing NuGet package provider (required for Save-Module)..." -ForegroundColor Yellow
        Install-PackageProvider -Name NuGet -Force -Scope CurrentUser | Out-Null
    }
}

function Get-ModuleAvailableExact {
    # Returns the first discoverable exact-version PSModuleInfo, or null. This
    # checks disk availability on PSModulePath, not whether a module is loaded.
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$RequiredVersion
    )

    $mods = Get-Module -Name $Name -ListAvailable -ErrorAction SilentlyContinue
    if (-not $mods) { return $null }

    return $mods | Where-Object { $_.Version -eq [version]$RequiredVersion } | Select-Object -First 1
}

function Save-ModuleExact {
    # Downloads the pinned version (and Save-Module dependencies); Destination
    # must be made discoverable separately before Import-RequiredModuleVersion runs.
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$RequiredVersion,
        [Parameter(Mandatory)][string]$Destination
    )

    Install-NuGetProviderIfMissing

    Write-Host "Downloading $Name $RequiredVersion to $Destination" -ForegroundColor Yellow
    Save-Module -Name $Name -RequiredVersion $RequiredVersion -Path $Destination -Force
}

function Import-RequiredModuleVersion {
    <#
    .SYNOPSIS
        Imports and verifies an exact module version, downloading it if unavailable.
    .DESCRIPTION
        Destination must already be on PSModulePath; saving there does not amend
        the search path. Rechecks discoverability after download, then force-imports
        and verifies the loaded version. Failures throw. Host messages, not the
        loaded module object, are the normal output.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$RequiredVersion,
        [Parameter(Mandatory)][string]$Destination
    )

    $targetVersion = $RequiredVersion

    $available = Get-ModuleAvailableExact -Name $Name -RequiredVersion $targetVersion
    if (-not $available) {
        Save-ModuleExact -Name $Name -RequiredVersion $targetVersion -Destination $Destination
        $available = Get-ModuleAvailableExact -Name $Name -RequiredVersion $targetVersion
        if (-not $available) {
            throw "Module $Name $targetVersion was downloaded but is still not discoverable on PSModulePath."
        }
    }

    Import-Module -Name $Name -RequiredVersion $targetVersion -Force -ErrorAction Stop
    $loaded = Get-Module -Name $Name | Where-Object { $_.Version -eq [version]$targetVersion } | Select-Object -First 1
    if (-not $loaded) {
        throw "Failed to import $Name version $targetVersion. Loaded version: $((Get-Module -Name $Name | Select-Object -First 1).Version)"
    }

    Write-Host "Loaded $Name $($loaded.Version)"
}

function Resolve-DevelopmentDefaultAlm4DataverseRef {
    <#
    .SYNOPSIS
        Chooses a local branch or detached commit for development setup.
    .DESCRIPTION
        Checks PrimaryRepositoryPath then this script's directory, skipping locations
        without .git. Returns a nonblank current branch or a 40-character lowercase
        commit; otherwise returns FallbackRef. Caught command/processing errors throw
        with repository context rather than silently falling back. Restores the
        caller's error preference after each probe.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][string]$PrimaryRepositoryPath,
        [Parameter()][string]$FallbackRef = 'stable'
    )

    $candidateRepos = @()
    foreach ($candidate in @($PrimaryRepositoryPath, $script:SetupRepositoryRoot)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $candidateRepos += $candidate
        }
    }
    $candidateRepos = @($candidateRepos | Select-Object -Unique)

    foreach ($repoPath in $candidateRepos) {
        $gitDir = Join-Path $repoPath '.git'
        if (-not (Test-Path -LiteralPath $gitDir)) {
            continue
        }

        try {
            $previousErrorActionPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'

                # Detached HEAD emits no output; join first so trimming is safe for an empty result.
                $branch = (@(& git -C $repoPath branch --show-current 2>$null) -join [Environment]::NewLine).Trim()
                if (-not [string]::IsNullOrWhiteSpace($branch)) {
                    Write-Host "Development mode: Using current local branch '$branch' as ALM4DataverseRef" -ForegroundColor Yellow
                    return $branch
                }

                $commit = (@(& git -C $repoPath rev-parse HEAD 2>$null) -join [Environment]::NewLine).Trim()
                if ($commit -match '^[0-9a-f]{40}$') {
                    Write-Host "Development mode: Repository is in detached HEAD; using commit '$commit' as ALM4DataverseRef" -ForegroundColor Yellow
                    return $commit
                }
            }
            finally {
                $ErrorActionPreference = $previousErrorActionPreference
            }
        }
        catch {
            throw "Could not resolve development ALM4DataverseRef from '$repoPath': $($_.Exception.Message)"
        }
    }

    Write-Host "Development mode: Could not resolve current branch/commit. Using '$FallbackRef' as ALM4DataverseRef" -ForegroundColor Yellow
    return $FallbackRef
}
