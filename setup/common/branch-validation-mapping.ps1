function Set-BranchBuildValidationMapping {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Updates an in-memory branch mapping record only.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$BranchMapping,
        [Parameter(Mandatory)][object]$BuildValidationSettings
    )

    $requiredProperties = @(
        'BuildValidationEnabled',
        'BuildValidationEnvironmentName',
        'BuildValidationBaselineRelease',
        'BuildValidationEnvironmentConfiguration',
        'ExistingBuildValidationEnvironment'
    )
    $settingsProperties = @($BuildValidationSettings.PSObject.Properties.Name)
    foreach ($propertyName in $requiredProperties) {
        if ($settingsProperties -notcontains $propertyName) {
            throw "Build validation editor result is missing required property '$propertyName'."
        }
    }

    foreach ($propertyName in $requiredProperties) {
        $BranchMapping.$propertyName = $BuildValidationSettings.$propertyName
    }

    $BranchMapping.BuildValidationEnabled = [bool]$BranchMapping.BuildValidationEnabled
    $BranchMapping.BuildValidationEnvironmentName = [string]$BranchMapping.BuildValidationEnvironmentName
    $BranchMapping.BuildValidationBaselineRelease = [string]$BranchMapping.BuildValidationBaselineRelease
    return $BranchMapping
}

function Select-BranchEnvironmentMapping {
    <#
    .SYNOPSIS
        Edits branch, DEV, deployment and BUILD-validation mappings.
    .PARAMETER BranchOnly
        Hides the built-in environment assignment editor; callback-based editors
        remain available.
    .PARAMETER EditDevEnvironmentScriptBlock
        Receives the complete mapping array as one argument, then the current mapping.
        A focused DEV-environment edit also receives the target name as a third
        argument. A normal edit replaces DevEnvironmentConfiguration, including null;
        a null result from a focused edit leaves the current configuration unchanged.
    .PARAMETER EditDeploymentEnvironmentsScriptBlock
        Receives the complete mapping array and current mapping. Its non-null outputs
        replace Environments; no output clears that list.
    .PARAMETER EditBuildValidationScriptBlock
        Receives the complete mapping array and current mapping, and returns a record
        with BUILD-validation settings for the current branch. A focused edit also
        receives the target environment name as a third argument; a null result from
        that edit leaves the current settings unchanged.
    .PARAMETER InitialEditTarget
        Opens a branch editor or one of its environment editors directly before returning
        the updated mappings.
    .PARAMETER IsNewRepository
        Shows the branch-strategy prompt for a new repository only.
    .DESCRIPTION
        Copies mapping records but shares nested environment objects. A sole empty
        main mapping is initialized with the default branch. The branch strategy is
        prompted only when IsNewRepository is set. Environment callbacks run for
        bootstrap and added branches; existing branches are edited from their menu.
        Each branch editor menu displays that branch's current mapping first.
        Built-in assignment excludes other branches' targets and sorts by ShortName.
        Done checks cross-branch deployment duplicates; a null management selection
        returns current mappings without that check. Callback failures/back navigation
        propagate; no resource changes made by callbacks are rolled back.
        InitialEditTarget skips the outer branch menu and opens the targeted editor.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject], [object[]])]
    param(
        [Parameter()][AllowEmptyCollection()][array]$EnvironmentConfigurations = @(),
        [Parameter()][array]$InitialBranchMappings,
        [Parameter()][string]$Title = 'Manage deployment branches and environment mappings',
        [Parameter()][string]$DocRelativePath,
        [Parameter()][string]$Ref,
        [Parameter()][switch]$BranchOnly,
        [Parameter()][switch]$IsNewRepository,
        [Parameter()][scriptblock]$EditDevEnvironmentScriptBlock,
        [Parameter()][scriptblock]$EditDeploymentEnvironmentsScriptBlock,
        [Parameter()][scriptblock]$EditBuildValidationScriptBlock,
        [Parameter()][AllowNull()][object]$InitialEditTarget
    )

    $allEnvironments = @($EnvironmentConfigurations | Where-Object { $null -ne $_ })
    $branchMappings = @()
    foreach ($mapping in @($InitialBranchMappings)) {
        if ($null -eq $mapping -or [string]::IsNullOrWhiteSpace([string]$mapping.BranchName)) {
            continue
        }

        $branchMappings += [pscustomobject]@{
            BranchName                  = [string]$mapping.BranchName
            DevEnvironmentConfiguration = $(if ($mapping.PSObject.Properties.Name -contains 'DevEnvironmentConfiguration') { $mapping.DevEnvironmentConfiguration } else { $null })
            ExistingDevEnvironment      = $(if ($mapping.PSObject.Properties.Name -contains 'ExistingDevEnvironment') { $mapping.ExistingDevEnvironment } else { $null })
            Environments                = @($mapping.Environments | Where-Object { $null -ne $_ })
            BuildValidationEnabled = [bool]$(if ($mapping.PSObject.Properties.Name -contains 'BuildValidationEnabled') { $mapping.BuildValidationEnabled } else { $false })
            BuildValidationEnvironmentName = [string]$(if ($mapping.PSObject.Properties.Name -contains 'BuildValidationEnvironmentName') { $mapping.BuildValidationEnvironmentName } else { '' })
            BuildValidationBaselineRelease = [string]$(if ($mapping.PSObject.Properties.Name -contains 'BuildValidationBaselineRelease') { $mapping.BuildValidationBaselineRelease } else { '' })
            BuildValidationEnvironmentConfiguration = $(if ($mapping.PSObject.Properties.Name -contains 'BuildValidationEnvironmentConfiguration') { $mapping.BuildValidationEnvironmentConfiguration } else { $null })
            ExistingBuildValidationEnvironment = $(if ($mapping.PSObject.Properties.Name -contains 'ExistingBuildValidationEnvironment') { $mapping.ExistingBuildValidationEnvironment } else { $null })
        }
    }

    if ($IsNewRepository) {
        if ($branchMappings.Count -eq 0) {
            $branchMappings = @(
                [pscustomobject]@{
                    BranchName = 'main'
                    DevEnvironmentConfiguration = $null
                    ExistingDevEnvironment = $null
                    Environments = @()
                    BuildValidationEnabled = $false
                    BuildValidationEnvironmentName = ''
                    BuildValidationBaselineRelease = ''
                    BuildValidationEnvironmentConfiguration = $null
                    ExistingBuildValidationEnvironment = $null
                }
            )
        }

        $strategyItems = @(
            'main only (recommended simple option)',
            'main + develop (required for environments that enforce PRs)'
        )

        $strategySelection = Select-FromMenu `
            -Title 'Choose a branching strategy for this repository' `
            -Items $strategyItems `
            -PromptGuidanceLines @(
                'main only is the simplest setup and works well when deployments can be committed directly to main.',
                'main + develop is better when environments or branch policies enforce pull requests before updates reach main.'
            ) `
            -PromptGuidanceDocRelativePath $DocRelativePath `
            -PromptGuidanceRef $Ref

        if ($null -eq $strategySelection) {
            return @($branchMappings)
        }

        if ($strategySelection -eq 1) {
            $branchMappings = @(
                [pscustomobject]@{
                    BranchName                  = 'main'
                    DevEnvironmentConfiguration = $null
                    ExistingDevEnvironment      = $null
                    Environments                = @()
                    BuildValidationEnabled = $false
                    BuildValidationEnvironmentName = ''
                    BuildValidationBaselineRelease = ''
                    BuildValidationEnvironmentConfiguration = $null
                    ExistingBuildValidationEnvironment = $null
                },
                [pscustomobject]@{
                    BranchName                  = 'develop'
                    DevEnvironmentConfiguration = $null
                    ExistingDevEnvironment      = $null
                    Environments                = @()
                    BuildValidationEnabled = $false
                    BuildValidationEnvironmentName = ''
                    BuildValidationBaselineRelease = ''
                    BuildValidationEnvironmentConfiguration = $null
                    ExistingBuildValidationEnvironment = $null
                }
            )
        }

        for ($bootstrapIndex = 0; $bootstrapIndex -lt $branchMappings.Count; $bootstrapIndex++) {
            $bootstrapMapping = $branchMappings[$bootstrapIndex]

            if ($EditDevEnvironmentScriptBlock) {
                $bootstrapMapping.DevEnvironmentConfiguration = & $EditDevEnvironmentScriptBlock @($branchMappings) $bootstrapMapping
                $branchMappings[$bootstrapIndex] = $bootstrapMapping
            }

            if ($EditDeploymentEnvironmentsScriptBlock) {
                $updatedDeploymentEnvironments = @(& $EditDeploymentEnvironmentsScriptBlock @($branchMappings) $bootstrapMapping)
                $bootstrapMapping.Environments = @($updatedDeploymentEnvironments | Where-Object { $null -ne $_ })
                $branchMappings[$bootstrapIndex] = $bootstrapMapping
            }

        }

        if ($EditBuildValidationScriptBlock) {
            for ($bootstrapIndex = 0; $bootstrapIndex -lt $branchMappings.Count; $bootstrapIndex++) {
                $bootstrapMapping = $branchMappings[$bootstrapIndex]
                $buildValidationSettings = & $EditBuildValidationScriptBlock @($branchMappings) $bootstrapMapping
                [void](Set-BranchBuildValidationMapping -BranchMapping $bootstrapMapping -BuildValidationSettings $buildValidationSettings)
                $branchMappings[$bootstrapIndex] = $bootstrapMapping
            }
        }
    }

    $focusedBranchIndex = -1
    $focusedEditAction = ''
    $focusedEnvironmentName = ''
    $targetKind = ''
    if ($null -ne $InitialEditTarget) {
        $targetKind = [string](Get-OptionalObjectPropertyValue -InputObject $InitialEditTarget -PropertyName 'Kind')
        $targetBranchName = [string](Get-OptionalObjectPropertyValue -InputObject $InitialEditTarget -PropertyName 'BranchName')
        $focusedEnvironmentName = [string](Get-OptionalObjectPropertyValue -InputObject $InitialEditTarget -PropertyName 'EnvironmentName')
        for ($branchIndex = 0; $branchIndex -lt $branchMappings.Count; $branchIndex++) {
            if ([string]$branchMappings[$branchIndex].BranchName -ieq $targetBranchName) {
                $focusedBranchIndex = $branchIndex
                break
            }
        }

        if ($focusedBranchIndex -lt 0) {
            throw "Branch '$targetBranchName' is no longer configured."
        }

        $focusedEditAction = switch ($targetKind) {
            'Branch' { '' }
            'DevEnvironment' { 'Edit DEV environment' }
            'DeploymentEnvironment' { 'Edit deployment environments' }
            'BuildValidation' { 'Edit BUILD validation' }
            default { throw "Unsupported branch configuration target '$targetKind'." }
        }
    }

    while ($true) {
        if ($null -eq $InitialEditTarget) {
            Write-Section `
                -Message 'Configure deployment branch mappings' `
                -GuidanceLines @(
                    'Define which branches setup manages, and map each branch to DEV and deployment targets.',
                    'Use a branch edit menu to configure DEV, ordered deployment targets, and BUILD validation.',
                    'Each deployment target should belong to only one branch to avoid ambiguous promotion paths.'
                ) `
                -GuidanceDocRelativePath 'docs/setup/github-setup.md' `
                -GuidanceRef $Ref

            Show-BranchEnvironmentMappingTable -BranchMappings $branchMappings
            [Spectre.Console.AnsiConsole]::WriteLine()

            $menuItems = @('Add a branch mapping')
            if ($branchMappings.Count -gt 0) {
                $menuItems += 'Edit a branch mapping'
                $menuItems += 'Remove a branch mapping'
            }
            $menuItems += 'Done'

            $selection = Select-FromMenu -Title $Title -Items $menuItems -PreserveExistingContent -SkipPromptGuidance
            if ($null -eq $selection) {
                return @($branchMappings)
            }

            $selectedMenuItem = $menuItems[$selection]
        }
        else {
            $selectedMenuItem = 'Edit a branch mapping'
        }

        switch ($selectedMenuItem) {
            'Add a branch mapping' {
                $defaultBranchName = if ($branchMappings.Count -eq 0) { 'main' } else { '' }
                $branchName = Read-TextWithDefault -Prompt 'Branch name' -DefaultValue $defaultBranchName
                $branchName = $branchName.Trim()
                if ([string]::IsNullOrWhiteSpace($branchName)) {
                    [Spectre.Console.AnsiConsole]::MarkupLine('[red]Branch name is required.[/]')
                    continue
                }

                if ($branchMappings | Where-Object { $_.BranchName -ieq $branchName }) {
                    [Spectre.Console.AnsiConsole]::MarkupLine("[red]Branch '$([string](ConvertTo-SpectreMarkupLiteral -Text $branchName))' already exists.[/]")
                    continue
                }

                $newBranchMapping = [pscustomobject]@{
                    BranchName                  = $branchName
                    DevEnvironmentConfiguration = $null
                    ExistingDevEnvironment      = $null
                    Environments                = @()
                    BuildValidationEnabled = $false
                    BuildValidationEnvironmentName = ''
                    BuildValidationBaselineRelease = ''
                    BuildValidationEnvironmentConfiguration = $null
                    ExistingBuildValidationEnvironment = $null
                }

                $branchMappings += $newBranchMapping
                $newBranchIndex = $branchMappings.Count - 1

                if ($EditDevEnvironmentScriptBlock) {
                    $newBranchMapping.DevEnvironmentConfiguration = & $EditDevEnvironmentScriptBlock @($branchMappings) $newBranchMapping
                    $branchMappings[$newBranchIndex] = $newBranchMapping
                }

                if ($EditDeploymentEnvironmentsScriptBlock) {
                    $updatedDeploymentEnvironments = @(& $EditDeploymentEnvironmentsScriptBlock @($branchMappings) $newBranchMapping)
                    $newBranchMapping.Environments = @($updatedDeploymentEnvironments | Where-Object { $null -ne $_ })
                    $branchMappings[$newBranchIndex] = $newBranchMapping
                }

                if ($EditBuildValidationScriptBlock) {
                    $buildValidationSettings = & $EditBuildValidationScriptBlock @($branchMappings) $newBranchMapping
                    [void](Set-BranchBuildValidationMapping -BranchMapping $newBranchMapping -BuildValidationSettings $buildValidationSettings)
                    $branchMappings[$newBranchIndex] = $newBranchMapping
                }
            }
            'Remove a branch mapping' {
                $branchMenu = @($branchMappings | ForEach-Object { [string]$_.BranchName })
                $removeIndex = Select-FromMenu -Title 'Select branch mapping to remove' -Items $branchMenu
                if ($null -eq $removeIndex) {
                    continue
                }

                $branchMappings = @(
                    for ($i = 0; $i -lt $branchMappings.Count; $i++) {
                        if ($i -ne $removeIndex) {
                            $branchMappings[$i]
                        }
                    }
                )
            }
            'Edit a branch mapping' {
                $branchMenu = @($branchMappings | ForEach-Object { [string]$_.BranchName })
                $editIndex = if ($null -ne $InitialEditTarget) {
                    $focusedBranchIndex
                }
                else {
                    Select-FromMenu -Title 'Select branch mapping to edit' -Items $branchMenu
                }
                if ($null -eq $editIndex) {
                    continue
                }

                $currentMapping = $branchMappings[$editIndex]
                $exitEditMenu = $false
                $mappingMenuItems = @('Rename branch')
                if ($EditDevEnvironmentScriptBlock) {
                    $mappingMenuItems += 'Edit DEV environment'
                }
                if ($EditDeploymentEnvironmentsScriptBlock) {
                    $mappingMenuItems += 'Edit deployment environments'
                    $mappingMenuItems += 'Clear all deployment environments'
                }
                if ($EditBuildValidationScriptBlock) {
                    $mappingMenuItems += 'Edit BUILD validation'
                }
                if (-not $BranchOnly) {
                    $mappingMenuItems += 'Assign environments'
                    $mappingMenuItems += 'Clear all assigned environments'
                }
                $mappingMenuItems += 'Done'

                while ($true) {
                    $isFocusedEnvironmentEdit = $null -ne $InitialEditTarget -and $targetKind -ne 'Branch'
                    if ($isFocusedEnvironmentEdit) {
                        $mappingAction = [Array]::IndexOf($mappingMenuItems, $focusedEditAction)
                        if ($mappingAction -lt 0) {
                            throw "The '$focusedEditAction' editor is not available for branch '$($currentMapping.BranchName)'."
                        }
                    }
                    else {
                        Show-BranchEnvironmentMappingTable -BranchMappings @($currentMapping)
                        [Spectre.Console.AnsiConsole]::WriteLine()
                        $mappingAction = Select-FromMenu -Title "Edit branch '$($currentMapping.BranchName)'" -Items $mappingMenuItems -PreserveExistingContent
                    }
                    if ($null -eq $mappingAction) {
                        break
                    }

                    switch ($mappingMenuItems[$mappingAction]) {
                        'Rename branch' {
                            $newBranchName = Read-TextWithDefault -Prompt 'Branch name' -DefaultValue $currentMapping.BranchName
                            $newBranchName = $newBranchName.Trim()
                            if ([string]::IsNullOrWhiteSpace($newBranchName)) {
                                [Spectre.Console.AnsiConsole]::MarkupLine('[red]Branch name is required.[/]')
                                continue
                            }

                            $duplicate = $false
                            for ($branchIndex = 0; $branchIndex -lt $branchMappings.Count; $branchIndex++) {
                                if ($branchIndex -eq $editIndex) {
                                    continue
                                }

                                if ($branchMappings[$branchIndex].BranchName -ieq $newBranchName) {
                                    $duplicate = $true
                                    break
                                }
                            }

                            if ($duplicate) {
                                [Spectre.Console.AnsiConsole]::MarkupLine("[red]Branch '$([string](ConvertTo-SpectreMarkupLiteral -Text $newBranchName))' already exists.[/]")
                                continue
                            }

                            $currentMapping.BranchName = $newBranchName
                            $branchMappings[$editIndex] = $currentMapping
                        }
                        'Edit DEV environment' {
                            if ($targetKind -eq 'DevEnvironment') {
                                $updatedDevEnvironment = & $EditDevEnvironmentScriptBlock @($branchMappings) $currentMapping $focusedEnvironmentName
                                if ($null -ne $updatedDevEnvironment) {
                                    $currentMapping.DevEnvironmentConfiguration = $updatedDevEnvironment
                                    $branchMappings[$editIndex] = $currentMapping
                                }
                            }
                            else {
                                $currentMapping.DevEnvironmentConfiguration = & $EditDevEnvironmentScriptBlock @($branchMappings) $currentMapping
                                $branchMappings[$editIndex] = $currentMapping
                            }
                        }
                        'Edit deployment environments' {
                            if ($targetKind -eq 'DeploymentEnvironment') {
                                $updatedDeploymentEnvironments = @(& $EditDeploymentEnvironmentsScriptBlock @($branchMappings) $currentMapping $focusedEnvironmentName)
                            }
                            else {
                                $updatedDeploymentEnvironments = @(& $EditDeploymentEnvironmentsScriptBlock @($branchMappings) $currentMapping)
                            }
                            $currentMapping.Environments = @($updatedDeploymentEnvironments | Where-Object { $null -ne $_ })
                            $branchMappings[$editIndex] = $currentMapping
                        }
                        'Edit BUILD validation' {
                            if ($targetKind -eq 'BuildValidation') {
                                $buildValidationSettings = & $EditBuildValidationScriptBlock @($branchMappings) $currentMapping $focusedEnvironmentName
                                if ($null -ne $buildValidationSettings) {
                                    [void](Set-BranchBuildValidationMapping -BranchMapping $currentMapping -BuildValidationSettings $buildValidationSettings)
                                    $branchMappings[$editIndex] = $currentMapping
                                }
                            }
                            else {
                                $buildValidationSettings = & $EditBuildValidationScriptBlock @($branchMappings) $currentMapping
                                [void](Set-BranchBuildValidationMapping -BranchMapping $currentMapping -BuildValidationSettings $buildValidationSettings)
                                $branchMappings[$editIndex] = $currentMapping
                            }
                        }
                        'Clear all deployment environments' {
                            $currentMapping.Environments = @()
                            $branchMappings[$editIndex] = $currentMapping
                        }
                        'Assign environments' {
                            $availableMap = @{}
                            foreach ($environment in $allEnvironments) {
                                $envUrl = ConvertTo-NormalizedEnvironmentUrl -Url $environment.Url
                                if ([string]::IsNullOrWhiteSpace($envUrl)) {
                                    $envUrl = [string]$environment.ShortName
                                }

                                if ([string]::IsNullOrWhiteSpace($envUrl)) {
                                    continue
                                }

                                $availableMap[$envUrl] = [pscustomobject]@{
                                    Environment   = $environment
                                    AssignedTo    = $null
                                    IsSelected    = $false
                                }
                            }

                            foreach ($mapping in $branchMappings) {
                                foreach ($environment in @($mapping.Environments)) {
                                    if ($null -eq $environment) {
                                        continue
                                    }

                                    $envUrl = ConvertTo-NormalizedEnvironmentUrl -Url $environment.Url
                                    if ([string]::IsNullOrWhiteSpace($envUrl)) {
                                        $envUrl = [string]$environment.ShortName
                                    }

                                    if ([string]::IsNullOrWhiteSpace($envUrl) -or -not $availableMap.ContainsKey($envUrl)) {
                                        continue
                                    }

                                    if ($mapping.BranchName -ieq $currentMapping.BranchName) {
                                        $availableMap[$envUrl].IsSelected = $true
                                    }
                                    else {
                                        $availableMap[$envUrl].AssignedTo = [string]$mapping.BranchName
                                    }
                                }
                            }

                            while ($true) {
                                $candidateItems = @()
                                $candidateMap = @()
                                foreach ($entry in $availableMap.GetEnumerator() | Sort-Object { $_.Value.Environment.ShortName }) {
                                    $environment = $entry.Value.Environment
                                    $shortName = [string]$environment.ShortName
                                    $friendlyName = if ($environment.PSObject.Properties.Name -contains 'FriendlyName' -and -not [string]::IsNullOrWhiteSpace($environment.FriendlyName)) { [string]$environment.FriendlyName } else { $shortName }

                                    if (-not [string]::IsNullOrWhiteSpace($entry.Value.AssignedTo)) {
                                        continue
                                    }

                                    $selectedLabel = if ($entry.Value.IsSelected) { '[selected]' } else { '[not selected]' }
                                    $candidateItems += "$shortName - $friendlyName $selectedLabel"
                                    $candidateMap += $entry.Key
                                }

                                if ($candidateItems.Count -eq 0) {
                                    [Spectre.Console.AnsiConsole]::MarkupLine('[yellow]No selectable environments available for this branch.[/]')
                                    break
                                }

                                $toggleSelection = Select-FromMenu -Title "Select environments for branch '$($currentMapping.BranchName)' (toggle one at a time)" -Items @($candidateItems + @('Done')) -PromptGuidanceLines @(
                                    'Choose which configured environments should run in this branch-specific deploy pipeline/workflow.',
                                    'Environment assignments are exclusive across branches in this setup flow.'
                                ) -PreserveExistingContent
                                if ($null -eq $toggleSelection -or $toggleSelection -eq $candidateItems.Count) {
                                    break
                                }

                                $selectedKey = $candidateMap[$toggleSelection]
                                $availableMap[$selectedKey].IsSelected = -not $availableMap[$selectedKey].IsSelected
                            }

                            $updatedBranchEnvironments = @()
                            foreach ($entry in $availableMap.GetEnumerator()) {
                                if ($entry.Value.IsSelected) {
                                    $updatedBranchEnvironments += $entry.Value.Environment
                                }
                            }

                            $currentMapping.Environments = @($updatedBranchEnvironments | Sort-Object ShortName)
                            $branchMappings[$editIndex] = $currentMapping
                        }
                        'Clear all assigned environments' {
                            $currentMapping.Environments = @()
                            $branchMappings[$editIndex] = $currentMapping
                        }
                        'Done' {
                            $exitEditMenu = $true
                        }
                    }

                    if ($exitEditMenu) {
                        break
                    }

                    if ($isFocusedEnvironmentEdit) {
                        return @($branchMappings)
                    }
                }

                if ($null -ne $InitialEditTarget) {
                    return @($branchMappings)
                }
            }
            'Done' {
                if (Test-BranchEnvironmentMappingDuplicate -BranchMappings $branchMappings) {
                    [Spectre.Console.AnsiConsole]::MarkupLine('[red]Each environment can only be assigned to one branch. Resolve duplicates before continuing.[/]')
                    continue
                }

                return @($branchMappings)
            }
        }
    }
}
