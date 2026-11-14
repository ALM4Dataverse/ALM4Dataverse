function Get-DataverseEnvironmentCatalog {
    <#
    .SYNOPSIS
    Returns discovery environments, reusing the script cache unless ForceRefresh is specified.
    .NOTES
    Acquires a Global Discovery token before calling the discovery cmdlet because
    its token callback runs on a worker task. The callback only returns that token.
    ShowStatus affects presentation only. An empty discovery result throws.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject], [object[]])]
    param(
        [Parameter()][switch]$ForceRefresh,
        [Parameter()][switch]$ShowStatus
    )

    $hasCachedCatalog = ($null -ne (Get-Variable -Name 'dataverseEnvironmentCatalog' -Scope Script -ErrorAction SilentlyContinue)) -and $null -ne $script:dataverseEnvironmentCatalog
    if (-not $ForceRefresh -and $hasCachedCatalog) {
        return @($script:dataverseEnvironmentCatalog)
    }

    $discoveryResource = 'https://globaldisco.crm.dynamics.com'
    if ($ShowStatus) {
        Write-Host 'Authenticating to retrieve Dataverse environments...' -ForegroundColor DarkGray
    }

    $discoveryAccessToken = Get-SetupAccessToken -ResourceUrl $discoveryResource
    $accessTokenProvider = {
        param($resource)
        if (-not [string]::IsNullOrWhiteSpace($resource)) {
            try {
                $resourceAuthority = ([System.Uri]$resource).GetLeftPart([System.UriPartial]::Authority)
            }
            catch {
                throw 'Dataverse environment discovery requested an invalid authentication resource.'
            }

            if ($resourceAuthority -ne $discoveryResource) {
                throw 'Dataverse environment discovery requested a token for an unexpected resource.'
            }
        }

        return $discoveryAccessToken
    }.GetNewClosure()

    $fetchCatalog = {
        @(Get-DataverseEnvironment -AccessToken $accessTokenProvider)
    }

    if ($ShowStatus) {
        $script:dataverseEnvironmentCatalog = @(Invoke-WithSpectreStatus -Status 'Retrieving Dataverse environments...' -ScriptBlock $fetchCatalog)
    }
    else {
        $script:dataverseEnvironmentCatalog = @(& $fetchCatalog)
    }

    if (-not $script:dataverseEnvironmentCatalog -or $script:dataverseEnvironmentCatalog.Count -eq 0) {
        throw 'No Dataverse environments found for this user.'
    }

    return @($script:dataverseEnvironmentCatalog)
}

function Select-DataverseEnvironment {
    <#
    .SYNOPSIS
    Returns a discovered environment selected from a URL-normalized menu, or null on cancellation.
    .NOTES
    ExcludeUrl removes a target before PreferredUrl is promoted to the first choice.
    No remaining environments is an error; PreferredUrl does not bypass discovery.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][string]$Prompt = "Select a Dataverse environment",
        [Parameter()][string]$ExcludeUrl,
        [Parameter()][string]$PreferredUrl,
        [Parameter()][string[]]$PromptGuidanceLines,
        [Parameter()][string]$PromptGuidanceDocRelativePath,
        [Parameter()][string]$PromptGuidanceRef
    )

    $environments = @(Get-DataverseEnvironmentCatalog -ShowStatus)

    $normalizedExcludeUrl = ConvertTo-NormalizedEnvironmentUrl -Url $ExcludeUrl
    $normalizedPreferredUrl = ConvertTo-NormalizedEnvironmentUrl -Url $PreferredUrl

    if ($ExcludeUrl) {
        $environments = @($environments | Where-Object {
            (ConvertTo-NormalizedEnvironmentUrl -Url $_.Endpoints["WebApplication"]) -ne $normalizedExcludeUrl
        })
        if ($environments.Count -eq 0) {
            throw "No environments available after filtering."
        }
    }

    $menuItems = @()
    $menuActions = @()

    if (-not [string]::IsNullOrWhiteSpace($normalizedPreferredUrl)) {
        $preferredEnvironment = $environments | Where-Object {
            (ConvertTo-NormalizedEnvironmentUrl -Url $_.Endpoints['WebApplication']) -eq $normalizedPreferredUrl
        } | Select-Object -First 1

        if ($preferredEnvironment) {
            $menuItems += "Use existing environment: $($preferredEnvironment.FriendlyName) - $($preferredEnvironment.UniqueName) ($($preferredEnvironment.Endpoints['WebApplication']))"
            $menuActions += $preferredEnvironment

            $environments = @($environments | Where-Object {
                (ConvertTo-NormalizedEnvironmentUrl -Url $_.Endpoints['WebApplication']) -ne $normalizedPreferredUrl
            })
        }
    }

    foreach ($env in $environments) {
        $webUrl = $env.Endpoints["WebApplication"]
        $menuItems += "$($env.FriendlyName) - $($env.UniqueName) ($webUrl)"
        $menuActions += $env
    }

    $selectedIndex = Select-FromMenu `
        -Title $Prompt `
        -Items $menuItems `
        -PromptGuidanceLines $PromptGuidanceLines `
        -PromptGuidanceDocRelativePath $PromptGuidanceDocRelativePath `
        -PromptGuidanceRef $PromptGuidanceRef
    if ($null -eq $selectedIndex) {
        return $null
    }

    return $menuActions[$selectedIndex]
}

function Get-OptionalObjectPropertyValue {
    # Missing objects/keys/properties return null under StrictMode; preserve false and zero values.
    [CmdletBinding()]
    param(
        [Parameter()][object]$InputObject,
        [Parameter(Mandatory)][string]$PropertyName
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [hashtable]) {
        if ($InputObject.ContainsKey($PropertyName)) {
            return $InputObject[$PropertyName]
        }

        return $null
    }

    if ($InputObject.PSObject -and $InputObject.PSObject.Properties.Name -contains $PropertyName) {
        return $InputObject.$PropertyName
    }

    return $null
}

function Select-AzDoMainRepository {
    <#
    .SYNOPSIS
    Selects or creates the application's repository in ProjectName and returns its VSTeam object.
    .NOTES
    SharedRepositoryName optionally excludes the template repository. Cancellation,
    blank new names and unresolved repository IDs throw rather than returning a partial choice.
    ExistingOnly disables repository creation for existing-repository setup and ApplyConfig.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter()][string]$SharedRepositoryName,
        [Parameter()][switch]$ExistingOnly,
        [Parameter()][switch]$ApplyConfig
    )

    Write-Section `
        -Message "Selecting main Git repository"

    $repos = @(Invoke-WithSpectreStatus -Status "Retrieving repositories in '$ProjectName'..." -ScriptBlock {
        Get-VSTeamGitRepository -ProjectName $ProjectName
    })
    # 'Main' repo is the user's application repo (not the shared ALM4Dataverse repo)
    $reposSorted = @($repos | Sort-Object -Property Name)

    $repoNames = @($reposSorted | ForEach-Object { $_.Name })
    if (-not [string]::IsNullOrWhiteSpace($SharedRepositoryName)) {
        $repoNames = @($repoNames | Where-Object { $_ -ne $SharedRepositoryName })
    }
    if ($ExistingOnly -and $repoNames.Count -eq 0) {
        if ($ApplyConfig) {
            throw 'ApplyConfig requires an existing application repository.'
        }
        throw 'Existing-repository setup requires an existing application repository.'
    }
    $menu = if ($ExistingOnly) { @($repoNames) } else { @('Create a new repository') + @($repoNames) }

    Write-Host "Select the repository where you want to set up pipelines:" -ForegroundColor Green

    $selectedIndex = Select-FromMenu `
        -Title "Select the main repository" `
        -Items $menu `
        -PromptGuidanceLines @(
            'Choose the primary application repository where your solutions and other assets will be stored.'
        ) `
        -PromptGuidanceDocRelativePath 'docs/setup/azdo-automated-setup.md' `
        -PromptGuidanceRef $ALM4DataverseRef
    if ($null -eq $selectedIndex) {
        throw "No main repository selected."
    }

    if (-not $ExistingOnly -and $selectedIndex -eq 0) {
        $newRepoName = Read-TextWithDefault -Prompt 'Enter the name for the new main repository'
        $newRepoName = $newRepoName.Trim()
        if ([string]::IsNullOrWhiteSpace($newRepoName)) {
            throw "Repository name cannot be empty."
        }

        $created = Invoke-WithSpectreStatus -Status "Creating Git repository '$newRepoName' in project '$ProjectName'..." -ScriptBlock {
            Add-VSTeamGitRepository -ProjectName $ProjectName -Name $newRepoName
        }
        if (-not $created -or -not $created.Id) {
            throw "Failed to create Git repository '$newRepoName'."
        }
        $created | Add-Member -NotePropertyName IsNewRepository -NotePropertyValue $true -Force
        Write-Host "Created repository '$newRepoName'."
        return $created
    }

    $selectedName = $menu[$selectedIndex]
    $selected = $reposSorted | Where-Object { $_.Name -eq $selectedName } | Select-Object -First 1
    if (-not $selected -or -not $selected.Id) {
        throw "Failed to resolve selected repository '$selectedName'."
    }

    $selected | Add-Member -NotePropertyName IsNewRepository -NotePropertyValue $false -Force
    Write-Host "Selected main repository: $($selected.Name)"
    return $selected
}

function Get-AzDoSharedRepositoryNameFromWorkingTree {
    # Returns only the shared repository recorded in the Azure DevOps setup config.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Branch', Justification = 'Retained for existing callers; shared repository configuration is not branch-specific.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch
    )

    $configPath = Join-Path $RepoRoot 'alm-config.psd1'
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $config = ConvertFrom-AlmConfigContentForSetup -ConfigContent ([System.IO.File]::ReadAllText($configPath))
        if (
            [string](Get-OptionalObjectPropertyValue -InputObject $config -PropertyName 'provider') -ieq 'azDO' -and
            $config.Contains('repository') -and
            -not [string]::IsNullOrWhiteSpace([string]$config.repository)
        ) {
            return [string]$config.repository
        }
    }

    return $null
}

function Get-AzDoDeploymentEnvironmentNamesFromWorkingTree {
    # Returns only the ordered deployment environment names recorded for this branch.
    [CmdletBinding()]
    [OutputType([string], [object[]])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch
    )

    $configPath = Join-Path $RepoRoot 'alm-config.psd1'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        return @()
    }

    $config = ConvertFrom-AlmConfigContentForSetup -ConfigContent ([System.IO.File]::ReadAllText($configPath))
    if (-not $config.Contains('branches')) {
        return @()
    }
    if ($config.branches -isnot [System.Collections.IDictionary]) {
        throw 'The branches setting in alm-config.psd1 must be a hashtable keyed by branch name.'
    }

    $branchConfiguration = Get-AlmSetupBranchConfiguration -Config $config -BranchName $Branch
    $environmentNames = @()
    if ($branchConfiguration.Contains('deploymentEnvironments') -and $null -ne $branchConfiguration.deploymentEnvironments) {
        if ($branchConfiguration.deploymentEnvironments -isnot [array]) {
            throw "The deploymentEnvironments setting for branch '$Branch' must be an array of environment names."
        }
        $environmentNames = @($branchConfiguration.deploymentEnvironments)
    }

    foreach ($environmentName in $environmentNames) {
        if ($environmentName -isnot [string] -or [string]::IsNullOrWhiteSpace($environmentName)) {
            throw "The deploymentEnvironments setting for branch '$Branch' must contain non-empty environment names."
        }
    }
    return @($environmentNames)
}

function Get-AzDoExtensionModeFromWorkingTree {
    <#
    .SYNOPSIS
    Reads the configured extension mode from alm-config.psd1.
    .OUTPUTS
    System.Management.Automation.PSCustomObject. IsConfigured, HasConflict,
    UseAlm4DataverseExtension and SourceFiles. The mode is null when absent or conflicting.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Branch', Justification = 'Retained for existing callers; extension mode is repository-wide.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch
    )

    $configPath = Join-Path $RepoRoot 'alm-config.psd1'
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $config = ConvertFrom-AlmConfigContentForSetup -ConfigContent ([System.IO.File]::ReadAllText($configPath))
        if (
            [string](Get-OptionalObjectPropertyValue -InputObject $config -PropertyName 'provider') -ieq 'azDO' -and
            $config.Contains('azDOUseAlm4DataverseExtension')
        ) {
            if ($config.azDOUseAlm4DataverseExtension -isnot [bool]) {
                throw 'azDOUseAlm4DataverseExtension in alm-config.psd1 must be a Boolean.'
            }
            return [pscustomobject]@{
                IsConfigured              = $true
                HasConflict               = $false
                UseAlm4DataverseExtension = [bool]$config.azDOUseAlm4DataverseExtension
                SourceFiles               = @($configPath)
            }
        }
    }

    return [pscustomobject]@{
        IsConfigured                = $false
        HasConflict                 = $false
        UseAlm4DataverseExtension   = $null
        SourceFiles                 = @()
    }
}

function Select-AzDoSharedRepository {
    <#
    .SYNOPSIS
    Returns the selected or newly created template repository, excluding the application repository.
    .PARAMETER UsePreferredIfAvailable
    Uses PreferredRepositoryName directly when it is accessible; otherwise opens the selection menu.
    .PARAMETER RequirePreferred
    Fails instead of opening the selection menu when PreferredRepositoryName is inaccessible.
    .PARAMETER ValidatePreferredOnly
    Returns the preferred repository when accessible, or null without opening the selection menu.
    .NOTES
    PreferredRepositoryName is promoted when available and otherwise seeds the new-name
    prompt. UsePreferredIfAvailable avoids the prompt when the preferred repository exists.
    ValidatePreferredOnly checks accessibility without prompting. Blank names are reprompted
    during selection; cancellation or a missing created ID throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter()][string]$PreferredRepositoryName,
        [Parameter()][string]$ExcludeRepositoryName,
        [Parameter()][switch]$UsePreferredIfAvailable,
        [Parameter()][switch]$RequirePreferred,
        [Parameter()][switch]$ValidatePreferredOnly
    )

    if ($ValidatePreferredOnly -and ($UsePreferredIfAvailable -or $RequirePreferred)) {
        throw 'ValidatePreferredOnly cannot be combined with UsePreferredIfAvailable or RequirePreferred.'
    }
    if ($RequirePreferred -and (-not $UsePreferredIfAvailable -or [string]::IsNullOrWhiteSpace($PreferredRepositoryName))) {
        throw 'RequirePreferred needs UsePreferredIfAvailable and a preferred repository name.'
    }

    Write-Section `
        -Message 'Selecting shared ALM4Dataverse repository'

    $repos = @(Invoke-WithSpectreStatus -Status "Retrieving shared repository options in '$ProjectName'..." -ScriptBlock {
        Get-VSTeamGitRepository -ProjectName $ProjectName
    })
    $reposSorted = @($repos | Sort-Object -Property Name)
    $candidateRepos = @($reposSorted | Where-Object {
        [string]::IsNullOrWhiteSpace($ExcludeRepositoryName) -or $_.Name -ne $ExcludeRepositoryName
    })

    if ($ValidatePreferredOnly) {
        if ([string]::IsNullOrWhiteSpace($PreferredRepositoryName)) {
            return $null
        }

        return $candidateRepos |
            Where-Object { $_.Name -eq $PreferredRepositoryName } |
            Select-Object -First 1
    }

    if ($UsePreferredIfAvailable -and -not [string]::IsNullOrWhiteSpace($PreferredRepositoryName)) {
        $preferredRepo = $candidateRepos | Where-Object { $_.Name -eq $PreferredRepositoryName } | Select-Object -First 1
        if ($preferredRepo) {
            Write-Host "Using existing shared repository: $($preferredRepo.Name)"
            return $preferredRepo
        }

        if ($RequirePreferred) {
            throw "The selected shared repository '$PreferredRepositoryName' is not accessible in project '$ProjectName'. Select a different shared repository."
        }

        Write-Warning "Configured shared repository '$PreferredRepositoryName' is not accessible in project '$ProjectName'. Select an accessible repository instead."
    }

    $menuItems = @()
    $menuActions = @()

    if (-not [string]::IsNullOrWhiteSpace($PreferredRepositoryName)) {
        $preferredRepo = $candidateRepos | Where-Object { $_.Name -eq $PreferredRepositoryName } | Select-Object -First 1
        if ($preferredRepo) {
            $menuItems += "Use current shared repository: $($preferredRepo.Name)"
            $menuActions += @{ Type = 'UseExisting'; Repo = $preferredRepo }
            $candidateRepos = @($candidateRepos | Where-Object { $_.Id -ne $preferredRepo.Id })
        }
    }

    foreach ($candidateRepo in $candidateRepos) {
        $menuItems += "Use existing repository: $($candidateRepo.Name)"
        $menuActions += @{ Type = 'UseExisting'; Repo = $candidateRepo }
    }

    $defaultNewName = if ([string]::IsNullOrWhiteSpace($PreferredRepositoryName)) { 'ALM4Dataverse' } else { $PreferredRepositoryName }
    $menuItems += 'Create a new repository'
    $menuActions += @{ Type = 'CreateNew'; DefaultName = $defaultNewName }

    $selection = Select-FromMenu `
        -Title 'Select the shared repository that will host the ALM4Dataverse templates' `
        -Items $menuItems `
        -PromptGuidanceLines @(
            'Choose the shared repository that will store reusable ALM4Dataverse templates for this project.',
            'Use the existing shared repository when one is already referenced by your main repo to keep template source consistent.'
        ) `
        -PromptGuidanceDocRelativePath 'docs/setup/azdo-automated-setup.md' `
        -PromptGuidanceRef $ALM4DataverseRef
    if ($null -eq $selection) {
        throw 'No shared repository selected.'
    }

    $selectedAction = $menuActions[$selection]
    if ($selectedAction.Type -eq 'UseExisting') {
        Write-Host "Selected shared repository: $($selectedAction.Repo.Name)"
        return $selectedAction.Repo
    }

    while ($true) {
        $newRepoName = Read-TextWithDefault -Prompt 'Enter the name for the shared repository' -DefaultValue $selectedAction.DefaultName

        $newRepoName = $newRepoName.Trim()
        if ([string]::IsNullOrWhiteSpace($newRepoName)) {
            Write-Warning 'Repository name cannot be empty.'
            continue
        }

        $createdRepo = Invoke-WithSpectreStatus -Status "Creating Git repository '$newRepoName' in project '$ProjectName'..." -ScriptBlock {
            Add-VSTeamGitRepository -ProjectName $ProjectName -Name $newRepoName
        }
        if (-not $createdRepo -or -not $createdRepo.Id) {
            throw "Failed to create Git repository '$newRepoName'."
        }

        Write-Host "Created shared repository '$newRepoName'."
        return $createdRepo
    }
}

function Get-AzDoCallerSecretVariableBlock {
    <#
    .SYNOPSIS
    Returns the template-level secretVariables block from an existing caller pipeline.
    .NOTES
    Recognizes the generated caller layout: the key at four spaces under the single
    template's parameters, followed by list items indented at four or more spaces.
    Returns the lines joined by the platform newline, or an empty string when the file
    or block is absent, so callers can append it to regenerated content verbatim.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return '' }

    $secretVariableLines = [System.Collections.Generic.List[string]]::new()
    $inSecretVariables = $false
    foreach ($existingLine in @(Get-Content -LiteralPath $Path)) {
        if ($existingLine -match '^\s{4}secretVariables:') {
            $inSecretVariables = $true
            $secretVariableLines.Add($existingLine)
        }
        elseif ($inSecretVariables -and ($existingLine -match '^\s{5,}\S' -or $existingLine -match '^\s{4}-\s')) {
            $secretVariableLines.Add($existingLine)
        }
        else {
            $inSecretVariables = $false
        }
    }

    return ($secretVariableLines -join [Environment]::NewLine)
}

function Sync-CopyToYourRepoIntoGitRepo {
    <#
    .SYNOPSIS
    Copies the scaffold into a working tree, adapting branch, repository and extension references.
    .NOTES
    Overwrites differing scaffold files but preserves existing alm-config.psd1 for the
    later merge, existing application-owned files (AGENTS.md and data/), and existing
    BUILD/DEPLOY-Branch callers, which the BUILD and DEPLOY updaters regenerate
    afterwards without discarding their custom parameters. EXPORT and IMPORT are
    refreshed from the scaffold but keep an existing template-level secretVariables
    block. Every pipeline caller's repository resource is renamed to
    SharedRepositoryName. DEPLOY-main becomes DEPLOY-Branch; extension false selects the
    fallback. Obsolete .template companions are removed for existing destinations.
    Does not commit.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)][string]$RepositoryName,
        [Parameter(Mandatory)][string]$SharedRepositoryName,
        [Parameter()][string]$SharedRepositoryRef = 'main',
        [Parameter(Mandatory)][string]$Branch,
        [Parameter()][bool]$UseAlm4DataverseExtension = $true
    )

    if (-not (Test-Path -LiteralPath $SourceRoot)) {
        throw "Source folder not found: $SourceRoot"
    }

    Write-Section `
        -Message "Syncing pipeline files into main repository"
    Write-Host "Source: $SourceRoot" -ForegroundColor DarkGray
    Write-Host "Target: $TargetRoot" -ForegroundColor DarkGray

    $allSourceFiles = Get-ChildItem -LiteralPath $SourceRoot -Recurse -Force | Where-Object { -not $_.PSIsContainer }

    foreach ($file in $allSourceFiles) {
        $relativePath = $file.FullName.Substring($SourceRoot.Length).TrimStart('\', '/')
        $normalizedRelativePath = $relativePath -replace '\\', '/'
        $destPath = Join-Path $TargetRoot $relativePath

        if ($normalizedRelativePath -eq 'alm-config.psd1' -and (Test-Path -LiteralPath $destPath)) {
            if (Test-Path -LiteralPath "$destPath.template") {
                Remove-Item -LiteralPath "$destPath.template" -Force
            }

            Write-Host 'Preserving existing alm-config.psd1 so current solution defaults and extended config can be merged later.' -ForegroundColor DarkGray
            continue
        }

        if ((Test-ApplicationOwnedScaffoldPath -RelativePath $normalizedRelativePath) -and (Test-Path -LiteralPath $destPath)) {
            Write-Host "Preserving existing $normalizedRelativePath." -ForegroundColor DarkGray
            continue
        }

        if ($normalizedRelativePath -eq 'pipelines/DEPLOY-main.yml') {
            $destPath = Join-Path $TargetRoot "pipelines/DEPLOY-$Branch.yml"
        }
        if ($normalizedRelativePath -in @('pipelines/BUILD.yml', 'pipelines/DEPLOY-main.yml') -and (Test-Path -LiteralPath $destPath)) {
            continue
        }

        $destDir = Split-Path -Parent $destPath
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }

        $sourceFileToUse = $file.FullName
        $isTempFile = $false

        if ($normalizedRelativePath -eq 'pipelines/DEPLOY-main.yml') {

            $content = Get-Content -LiteralPath $file.FullName -Raw
            $content = $content -replace "source: 'BUILD'", "source: '$RepositoryName\BUILD'"
            $content = $content -replace "- main", "- $Branch"
            $content = $content -replace '(?m)^(\s*name:\s*)ALM4Dataverse\s*$', "`${1}$SharedRepositoryName"
            if (-not $UseAlm4DataverseExtension) {
                $content = $content -replace '(?m)^(\s*#?\s*useAlm4DataverseExtension:\s*)true\s*$', '${1}false'
            }

            $tempFile = [System.IO.Path]::GetTempFileName()
            $content | Set-Content -LiteralPath $tempFile -NoNewline
            $sourceFileToUse = $tempFile
            $isTempFile = $true
        }
        elseif ($normalizedRelativePath -in @('pipelines/EXPORT.yml', 'pipelines/IMPORT.yml')) {
            $content = Get-Content -LiteralPath $file.FullName -Raw
            if (-not $UseAlm4DataverseExtension) {
                $content = $content -replace '(?m)^(\s*useAlm4DataverseExtension:\s*)true\s*$', '${1}false'
            }
            $content = $content -replace '(?m)^(\s*name:\s*)ALM4Dataverse\s*$', "`${1}$SharedRepositoryName"
            $secretVariableBlock = Get-AzDoCallerSecretVariableBlock -Path $destPath
            if ($secretVariableBlock) {
                $content = $content.TrimEnd("`r", "`n") + [Environment]::NewLine + $secretVariableBlock + [Environment]::NewLine
            }

            $tempFile = [System.IO.Path]::GetTempFileName()
            $content | Set-Content -LiteralPath $tempFile -NoNewline
            $sourceFileToUse = $tempFile
            $isTempFile = $true
        }
        elseif ($normalizedRelativePath -eq 'pipelines/BUILD.yml') {
            $content = Get-Content -LiteralPath $file.FullName -Raw
            $content = $content -replace '(?m)^(\s*name:\s*)ALM4Dataverse\s*$', "`${1}$SharedRepositoryName"

            $tempFile = [System.IO.Path]::GetTempFileName()
            $content | Set-Content -LiteralPath $tempFile -NoNewline
            $sourceFileToUse = $tempFile
            $isTempFile = $true
        }

        if ($normalizedRelativePath -in @('pipelines/BUILD.yml', 'pipelines/EXPORT.yml', 'pipelines/IMPORT.yml', 'pipelines/DEPLOY-main.yml')) {
            $content = [System.IO.File]::ReadAllText($sourceFileToUse)
            $escapedRef = ([string]$SharedRepositoryRef).Replace("'", "''")
            $updatedContent = [regex]::Replace($content, '(?m)^(?<indent>\s*ref:\s*)[^\r\n]*$', {
                param($match)
                return $match.Groups['indent'].Value + "'refs/heads/$escapedRef'"
            })
            if ($updatedContent -cne $content) {
                if ($isTempFile) {
                    Set-Content -LiteralPath $sourceFileToUse -Value $updatedContent -NoNewline
                }
                else {
                    $tempFile = [System.IO.Path]::GetTempFileName()
                    Set-Content -LiteralPath $tempFile -Value $updatedContent -NoNewline
                    $sourceFileToUse = $tempFile
                    $isTempFile = $true
                }
            }
        }

        try {
            if (Test-Path -LiteralPath $destPath) {
                $srcHash = Get-FileHash -LiteralPath $sourceFileToUse -Algorithm SHA256
                $dstHash = Get-FileHash -LiteralPath $destPath -Algorithm SHA256

                if ($srcHash.Hash -ne $dstHash.Hash) {
                    Copy-Item -LiteralPath $sourceFileToUse -Destination $destPath -Force
                    if (Test-Path -LiteralPath "$destPath.template") {
                        Remove-Item -LiteralPath "$destPath.template" -Force
                    }
                }
                else {
                    if (Test-Path -LiteralPath "$destPath.template") {
                        Remove-Item -LiteralPath "$destPath.template" -Force
                    }
                }
            }
            else {
                Copy-Item -LiteralPath $sourceFileToUse -Destination $destPath -Force
            }
        }
        finally {
            if ($isTempFile -and (Test-Path -LiteralPath $sourceFileToUse)) {
                Remove-Item -LiteralPath $sourceFileToUse -Force
            }
        }
    }

    Write-Host 'Pipeline files synced into the working tree.' -ForegroundColor Green
}

function New-AzDoRepoWorkingTree {
    <#
    .SYNOPSIS
    Clones an Azure DevOps repository and returns Path and BaseBranch for subsequent edits.
    .NOTES
    The repository default branch takes precedence over PreferredBranch. WorkBranch,
    when supplied, is reset/created from that base. Uses a per-command bearer header;
    restores location and error preference but leaves clone cleanup to the caller.
    WhatIf returns nothing; clone or branch preparation failures throw.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][object]$TargetRepo,
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter()][string]$PreferredBranch = 'main',
        [Parameter()][string]$WorkBranch
    )

    if (-not $PSCmdlet.ShouldProcess($TargetRepo.Name, 'Clone repository and prepare working branch')) { return }

    if (-not $TargetRepo.remoteUrl) {
        throw "Could not determine remoteUrl for repository '$($TargetRepo.Name)'."
    }

    $cloneRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ALM4Dataverse-MainRepo-" + [guid]::NewGuid().ToString('n'))
    if (Test-Path -LiteralPath $cloneRoot) {
        try { Remove-Item -LiteralPath $cloneRoot -Recurse -Force -ErrorAction Stop } catch { throw }
    }

    Write-Host "Cloning '$($TargetRepo.Name)' to a temp folder..." -ForegroundColor Yellow
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'

        $cloneOutput = @(& git -c "http.extraheader=AUTHORIZATION: bearer $AccessToken" clone $TargetRepo.remoteUrl $cloneRoot 2>&1)
        if ($LASTEXITCODE -ne 0) {
            $cloneErrorDetails = @($cloneOutput | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $cloneErrorMessage = if ($cloneErrorDetails.Count -gt 0) { $cloneErrorDetails[-1] } else { "Exit code: $LASTEXITCODE" }
            throw "Git clone failed. $cloneErrorMessage"
        }

        Push-Location $cloneRoot
        try {
            $branch = $PreferredBranch
            if ($TargetRepo.defaultBranch) {
                $branch = ConvertFrom-GitRefToBranchName -Ref $TargetRepo.defaultBranch
            }
            if ([string]::IsNullOrWhiteSpace($branch)) {
                $branch = 'main'
            }

            $hasCommits = $false
            try {
                & git rev-parse HEAD 2>$null | Out-Null
                $hasCommits = ($LASTEXITCODE -eq 0)
            }
            catch {
                $hasCommits = $false
            }

            if ($hasCommits) {
                & git checkout $branch 2>&1 | Out-Host
                if ($LASTEXITCODE -ne 0) {
                    & git checkout -b $branch 2>&1 | Out-Host
                    if ($LASTEXITCODE -ne 0) {
                        throw "Git checkout failed for branch '$branch'."
                    }
                }
            }
            else {
                & git checkout -b $branch 2>&1 | Out-Host
                if ($LASTEXITCODE -ne 0) {
                    throw "Git checkout -b failed with exit code $LASTEXITCODE"
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($WorkBranch) -and $WorkBranch -ne $branch) {
                & git checkout -B $WorkBranch 2>&1 | Out-Host
                if ($LASTEXITCODE -ne 0) {
                    throw "Git checkout failed for working branch '$WorkBranch'."
                }
            }

            return [pscustomobject]@{
                Path       = $cloneRoot
                BaseBranch = $branch
            }
        }
        finally {
            Pop-Location
        }
    }
    catch {
        try { Remove-Item -LiteralPath $cloneRoot -Recurse -Force -ErrorAction Stop } catch { Write-Verbose 'Could not remove the failed repository clone; preserving the original failure.' }
        throw
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}
