function Select-BuildValidationBaselineEnvironment {
    <#
    .SYNOPSIS
        Selects an @shortName deployment baseline distinct from the BUILD environment.
    .DESCRIPTION
        Deduplicates nonblank short names case-insensitively. Exclusions match either
        short name or URL ignoring case and trailing slashes, not full URL normalization.
        Returns empty for no eligible environments or an explicit no-baseline choice;
        cancelling returns to the environment-detail menu. CurrentBaselineRelease marks
        the current choice, including an empty no-baseline choice, and lists it first
        because the selection prompt has no default-index setting. This chooses a
        selector, not a release artifact.
    .PARAMETER CurrentBaselineRelease
        The configured @shortName baseline, an empty string for no baseline, or null
        when no baseline has been configured yet.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][array]$DeploymentEnvironments,
        [Parameter()][AllowEmptyString()][string]$ExcludedEnvironmentName = '',
        [Parameter()][AllowEmptyString()][string]$ExcludedEnvironmentUrl = '',
        [Parameter()][AllowNull()][AllowEmptyString()][string]$CurrentBaselineRelease = $null
    )

    $uniqueEnvironments = @()
    foreach ($environment in @($DeploymentEnvironments)) {
        $shortName = [string](Get-OptionalObjectPropertyValue -InputObject $environment -PropertyName 'ShortName')
        $environmentUrl = [string](Get-OptionalObjectPropertyValue -InputObject $environment -PropertyName 'Url')
        if (-not [string]::IsNullOrWhiteSpace($ExcludedEnvironmentName) -and $shortName -ieq $ExcludedEnvironmentName) {
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($ExcludedEnvironmentUrl) -and
            -not [string]::IsNullOrWhiteSpace($environmentUrl) -and
            $environmentUrl.TrimEnd('/') -ieq $ExcludedEnvironmentUrl.TrimEnd('/')) {
            continue
        }
        if ([string]::IsNullOrWhiteSpace($shortName) -or
            @($uniqueEnvironments | Where-Object { [string]$_.ShortName -ieq $shortName }).Count -gt 0) {
            continue
        }

        $uniqueEnvironments += [pscustomobject]@{
            ShortName = $shortName
            FriendlyName = [string](Get-OptionalObjectPropertyValue -InputObject $environment -PropertyName 'FriendlyName')
        }
    }

    if ($uniqueEnvironments.Count -eq 0) {
        Write-Host 'No deployment environments are configured, so no baseline environment can be selected. BUILD validation will deploy only the candidate release.' -ForegroundColor Yellow
        return ''
    }

    $environmentEntries = @($uniqueEnvironments | ForEach-Object {
        $friendlyName = if ([string]::IsNullOrWhiteSpace($_.FriendlyName)) { $_.ShortName } else { $_.FriendlyName }
        [pscustomobject]@{
            Label     = "$friendlyName ($($_.ShortName))"
            ShortName = [string]$_.ShortName
            Value     = "@$($_.ShortName)"
        }
    })

    $currentBaselineShortName = ''
    if (-not [string]::IsNullOrWhiteSpace($CurrentBaselineRelease)) {
        $currentBaselineShortName = $CurrentBaselineRelease.Trim()
        if ($currentBaselineShortName.StartsWith('@')) {
            $currentBaselineShortName = $currentBaselineShortName.Substring(1)
        }
    }

    $entries = @()
    if ($null -ne $CurrentBaselineRelease) {
        $currentEntry = $environmentEntries | Where-Object { $_.ShortName -ieq $currentBaselineShortName } | Select-Object -First 1
        if ($currentEntry) {
            $entries += [pscustomobject]@{
                Label = "$($currentEntry.Label) (current)"
                Value = $currentEntry.Value
            }
        }
        elseif ([string]::IsNullOrWhiteSpace($currentBaselineShortName)) {
            $entries += [pscustomobject]@{
                Label = 'No baseline release (current)'
                Value = ''
            }
        }
    }

    if (@($entries | Where-Object { [string]::IsNullOrEmpty($_.Value) }).Count -eq 0) {
        $entries += [pscustomobject]@{
            Label = 'No baseline release'
            Value = ''
        }
    }

    foreach ($environmentEntry in $environmentEntries) {
        if (@($entries | Where-Object { $_.Value -eq $environmentEntry.Value }).Count -gt 0) {
            continue
        }
        $entries += [pscustomobject]@{
            Label = $environmentEntry.Label
            Value = $environmentEntry.Value
        }
    }

    $selectedIndex = Select-FromMenu -Title 'Select the separate deployment environment whose latest successful deployment should be used as the BUILD validation baseline' -Items @($entries.Label)
    if ($null -eq $selectedIndex) {
        Request-SetupWizardBack
    }

    return [string]$entries[$selectedIndex].Value
}

function Select-ConfiguredDeploymentEnvironment {
    <#
    .SYNOPSIS
        Interactively edits an ordered list using provider-owned environment callbacks.
    .PARAMETER AddEnvironmentScriptBlock
        Called with the current selection array as one positional argument. Returns
        an environment to append, or null to leave the list unchanged.
    .PARAMETER EditEnvironmentScriptBlock
        Optional callback receiving the current array, selected object and zero-based
        index. A non-null result replaces that entry; null retains it.
    .PARAMETER InitialEditEnvironmentName
        Opens the edit callback directly for the matching short or friendly name, then
        returns the updated list.
    .DESCRIPTION
        Initial objects are retained, not deep-cloned. Move earlier and later reorder
        existing entries without reopening their detail editor, so promotion order can
        change without re-entering credentials. Done or a null management selection
        emits the current list. Callbacks own validation and side effects; exceptions,
        including wizard navigation, propagate without rollback.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter()][array]$InitialEnvironments,
        [Parameter(Mandatory)][scriptblock]$AddEnvironmentScriptBlock,
        [Parameter()][scriptblock]$EditEnvironmentScriptBlock,
        [Parameter()][string]$InitialEditEnvironmentName,
        [Parameter()][string]$Heading = 'Target Deployment Environments',
        [Parameter()][string]$Title = 'Manage deployment environments',
        [Parameter()][string[]]$GuidanceLines,
        [Parameter()][string]$DocRelativePath,
        [Parameter()][string]$Ref
    )

    $selectedEnvironments = @()
    if ($InitialEnvironments) {
        $selectedEnvironments += @($InitialEnvironments)
    }

    $formatEnvironmentMenuLabel = {
        param($Environment)
        $shortName = [string]$Environment.ShortName
        $friendlyName = if ([string]::IsNullOrWhiteSpace($Environment.FriendlyName)) { $shortName } else { [string]$Environment.FriendlyName }
        $url = if ([string]::IsNullOrWhiteSpace($Environment.Url)) { '<not set>' } else { [string]$Environment.Url }
        "$shortName - $friendlyName ($url)"
    }.GetNewClosure()

    while ($true) {
        $effectiveGuidanceLines = if ($GuidanceLines -and @($GuidanceLines).Count -gt 0) {
            @($GuidanceLines)
        }
        else {
            @(
                'Use this step to define which environments each branch deploys to and in what order.',
                'Short names become stage labels and list order becomes promotion order, so keep both stable and intentional.'
            )
        }

        Write-Section `
            -Message $Heading `
            -GuidanceLines $effectiveGuidanceLines `
            -GuidanceDocRelativePath $DocRelativePath `
            -GuidanceRef $Ref

        Show-EnvironmentConfigurationTable -EnvironmentConfigurations $selectedEnvironments
        [Spectre.Console.AnsiConsole]::WriteLine()

        if (-not [string]::IsNullOrWhiteSpace($InitialEditEnvironmentName)) {
            if (-not $EditEnvironmentScriptBlock) {
                throw 'An initial environment edit was requested but no edit callback is available.'
            }

            $editIndex = -1
            for ($environmentIndex = 0; $environmentIndex -lt $selectedEnvironments.Count; $environmentIndex++) {
                if ([string]$selectedEnvironments[$environmentIndex].ShortName -ieq $InitialEditEnvironmentName) {
                    $editIndex = $environmentIndex
                    break
                }
            }
            if ($editIndex -lt 0) {
                for ($environmentIndex = 0; $environmentIndex -lt $selectedEnvironments.Count; $environmentIndex++) {
                    if ([string]$selectedEnvironments[$environmentIndex].FriendlyName -ieq $InitialEditEnvironmentName) {
                        if ($editIndex -ge 0) {
                            throw "More than one deployment environment matches '$InitialEditEnvironmentName'."
                        }
                        $editIndex = $environmentIndex
                    }
                }
            }
            if ($editIndex -lt 0) {
                throw "No deployment environment matches '$InitialEditEnvironmentName'."
            }

            $updatedEnvironment = & $EditEnvironmentScriptBlock @($selectedEnvironments) $selectedEnvironments[$editIndex] $editIndex
            if ($null -ne $updatedEnvironment) {
                $selectedEnvironments[$editIndex] = $updatedEnvironment
            }
            return @($selectedEnvironments)
        }

        $menuItems = @('Add an environment')
        if ($selectedEnvironments.Count -gt 0) {
            if ($EditEnvironmentScriptBlock) {
                $menuItems += 'Edit an environment'
            }
            if ($selectedEnvironments.Count -gt 1) {
                $menuItems += 'Move an environment earlier'
                $menuItems += 'Move an environment later'
            }
            $menuItems += 'Remove an environment'
            $menuItems += 'Clear list'
            $menuItems += 'Done'
        }
        else {
            $menuItems += 'Done'
        }

        $selection = Select-FromMenu `
            -Title $Title `
            -Items $menuItems `
            -ActionItems @('Done') `
            -ActionSectionTitle '---' `
            -PreserveExistingContent `
            -SkipPromptGuidance
        if ($null -eq $selection) {
            return @($selectedEnvironments)
        }

        switch ($menuItems[$selection]) {
            'Add an environment' {
                $newEnvironment = & $AddEnvironmentScriptBlock @($selectedEnvironments)
                if ($null -ne $newEnvironment) {
                    $selectedEnvironments += $newEnvironment
                }
            }
            'Move an environment earlier' {
                $moveIndexes = @(1..($selectedEnvironments.Count - 1))
                $environmentMenuItems = @($moveIndexes | ForEach-Object { & $formatEnvironmentMenuLabel $selectedEnvironments[$_] })
                $moveSelection = Select-FromMenu -Title 'Select the environment to move earlier' -Items $environmentMenuItems
                if ($null -ne $moveSelection) {
                    $moveIndex = $moveIndexes[$moveSelection]
                    $movedEnvironment = $selectedEnvironments[$moveIndex]
                    $selectedEnvironments[$moveIndex] = $selectedEnvironments[$moveIndex - 1]
                    $selectedEnvironments[$moveIndex - 1] = $movedEnvironment
                }
            }
            'Move an environment later' {
                $moveIndexes = @(0..($selectedEnvironments.Count - 2))
                $environmentMenuItems = @($moveIndexes | ForEach-Object { & $formatEnvironmentMenuLabel $selectedEnvironments[$_] })
                $moveSelection = Select-FromMenu -Title 'Select the environment to move later' -Items $environmentMenuItems
                if ($null -ne $moveSelection) {
                    $moveIndex = $moveIndexes[$moveSelection]
                    $movedEnvironment = $selectedEnvironments[$moveIndex]
                    $selectedEnvironments[$moveIndex] = $selectedEnvironments[$moveIndex + 1]
                    $selectedEnvironments[$moveIndex + 1] = $movedEnvironment
                }
            }
            'Remove an environment' {
                $environmentMenuItems = @($selectedEnvironments | ForEach-Object { & $formatEnvironmentMenuLabel $_ })

                $removeSelection = Select-FromMenu -Title 'Select the environment to remove' -Items $environmentMenuItems
                if ($null -ne $removeSelection) {
                    $selectedEnvironments = @(
                        for ($selectedIndex = 0; $selectedIndex -lt $selectedEnvironments.Count; $selectedIndex++) {
                            if ($selectedIndex -ne $removeSelection) {
                                $selectedEnvironments[$selectedIndex]
                            }
                        }
                    )
                }
            }
            'Clear list' {
                $selectedEnvironments = @()
                [Spectre.Console.AnsiConsole]::MarkupLine('[yellow]Environment list cleared.[/]')
            }
            'Edit an environment' {
                $environmentMenuItems = @($selectedEnvironments | ForEach-Object { & $formatEnvironmentMenuLabel $_ })

                $editSelection = Select-FromMenu -Title 'Select the environment to edit' -Items $environmentMenuItems
                if ($null -eq $editSelection) {
                    continue
                }

                $updatedEnvironment = & $EditEnvironmentScriptBlock @($selectedEnvironments) $selectedEnvironments[$editSelection] $editSelection
                if ($null -ne $updatedEnvironment) {
                    $selectedEnvironments[$editSelection] = $updatedEnvironment
                }
            }
            'Done' {
                return @($selectedEnvironments)
            }
        }
    }
}

function Get-DefaultBranchEnvironmentMappingsFromStrategy {
    <#
    .SYNOPSIS
        Creates suggested branch mappings without changing environment objects.
    .DESCRIPTION
        Simple assigns all non-null environments to MainBranch. GitflowLike assigns
        the first prod/production name match to MainBranch, the rest to DevelopBranch,
        and none to HotfixBranch. Without a production match main stays empty.
        Emits BranchName/Environments objects; this heuristic is not policy validation.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject], [object[]])]
    param(
        [Parameter(Mandatory)][ValidateSet('Simple', 'GitflowLike')][string]$Strategy,
        [Parameter(Mandatory)][array]$EnvironmentConfigurations,
        [Parameter()][string]$MainBranch = 'main',
        [Parameter()][string]$DevelopBranch = 'develop',
        [Parameter()][string]$HotfixBranch = 'hotfix'
    )

    $items = @($EnvironmentConfigurations | Where-Object { $null -ne $_ })

    if ($Strategy -eq 'Simple') {
        return @(
            [pscustomobject]@{
                BranchName   = $MainBranch
                Environments = @($items)
            }
        )
    }

    $prodCandidates = @($items | Where-Object {
        $shortName = if ($_.PSObject.Properties.Name -contains 'ShortName') { [string]$_.ShortName } else { '' }
        $friendlyName = if ($_.PSObject.Properties.Name -contains 'FriendlyName') { [string]$_.FriendlyName } else { '' }
        ($shortName -match '(?i)^prod$|production') -or ($friendlyName -match '(?i)^prod$|production')
    })

    $prodEnvironment = $prodCandidates | Select-Object -First 1
    $nonProd = @()
    foreach ($environment in $items) {
        if ($null -ne $prodEnvironment -and $environment -eq $prodEnvironment) {
            continue
        }

        $nonProd += $environment
    }

    $mappings = @(
        [pscustomobject]@{
            BranchName   = $DevelopBranch
            Environments = @($nonProd)
        },
        [pscustomobject]@{
            BranchName   = $HotfixBranch
            Environments = @()
        },
        [pscustomobject]@{
            BranchName   = $MainBranch
            Environments = @($(if ($prodEnvironment) { @($prodEnvironment) } else { @() }))
        }
    )

    if (-not $prodEnvironment) {
        $mappings[2].Environments = @()
    }

    return @($mappings)
}

function Test-BranchEnvironmentMappingDuplicate {
    # Only cross-branch deployment assignments conflict. DEV fields are not checked;
    # duplicate entries on one branch are allowed. Identity is normalized URL, falling
    # back to ShortName; blank identities are ignored and hashtable keys ignore case.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][array]$BranchMappings
    )

    $assignedUrls = @{}
    foreach ($mapping in @($BranchMappings)) {
        $branchName = [string]$mapping.BranchName
        foreach ($environment in @($mapping.Environments)) {
            if ($null -eq $environment) {
                continue
            }

            $normalizedUrl = ConvertTo-NormalizedEnvironmentUrl -Url $environment.Url
            if ([string]::IsNullOrWhiteSpace($normalizedUrl)) {
                $normalizedUrl = [string]$environment.ShortName
            }

            if ([string]::IsNullOrWhiteSpace($normalizedUrl)) {
                continue
            }

            if ($assignedUrls.ContainsKey($normalizedUrl) -and $assignedUrls[$normalizedUrl] -ne $branchName) {
                return $true
            }

            $assignedUrls[$normalizedUrl] = $branchName
        }
    }

    return $false
}

function Show-BranchEnvironmentMappingTable {
    # Prefer configured DEV details over discovered existing DEV details. This is
    # a display projection only; absent DEV labels render as <none>, not an error.
    [CmdletBinding()]
    param(
        [Parameter()][array]$BranchMappings
    )

    Initialize-SpectreConsole

    $items = @($BranchMappings)
    if ($items.Count -eq 0) {
        [Spectre.Console.AnsiConsole]::MarkupLine('[grey]No branch mappings configured yet.[/]')
        return
    }

    $table = New-SpectreTable -Columns @('Branch', 'DEV environment', 'Deployment environments', 'BUILD validation')
    foreach ($mapping in $items) {
        $branchName = [string]$mapping.BranchName
        $devEnvironmentLabel = '<none>'

        $devEnvironment = $null
        if ($mapping.PSObject.Properties.Name -contains 'DevEnvironmentConfiguration' -and $mapping.DevEnvironmentConfiguration) {
            $devEnvironment = $mapping.DevEnvironmentConfiguration
        }
        elseif ($mapping.PSObject.Properties.Name -contains 'ExistingDevEnvironment' -and $mapping.ExistingDevEnvironment) {
            $devEnvironment = $mapping.ExistingDevEnvironment
        }

        if ($devEnvironment) {
            if ($devEnvironment.PSObject.Properties.Name -contains 'ShortName' -and -not [string]::IsNullOrWhiteSpace([string]$devEnvironment.ShortName)) {
                $devEnvironmentLabel = [string]$devEnvironment.ShortName
            }
            elseif ($devEnvironment.PSObject.Properties.Name -contains 'FriendlyName' -and -not [string]::IsNullOrWhiteSpace([string]$devEnvironment.FriendlyName)) {
                $devEnvironmentLabel = [string]$devEnvironment.FriendlyName
            }
            elseif ($devEnvironment.PSObject.Properties.Name -contains 'Name' -and -not [string]::IsNullOrWhiteSpace([string]$devEnvironment.Name)) {
                $devEnvironmentLabel = [string]$devEnvironment.Name
            }
            elseif ($devEnvironment.PSObject.Properties.Name -contains 'Url' -and -not [string]::IsNullOrWhiteSpace([string]$devEnvironment.Url)) {
                $devEnvironmentLabel = [string]$devEnvironment.Url
            }
        }

        $environments = @($mapping.Environments)
        $environmentNames = @($environments | ForEach-Object {
            if ($null -eq $_) { return $null }
            if ($_.PSObject.Properties.Name -contains 'ShortName' -and -not [string]::IsNullOrWhiteSpace([string]$_.ShortName)) {
                return [string]$_.ShortName
            }
            return [string]$_.FriendlyName
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

        $buildValidationLabel = 'Disabled'
        if ($mapping.PSObject.Properties.Name -contains 'BuildValidationEnabled' -and $mapping.BuildValidationEnabled) {
            $buildValidationLabel = [string]$mapping.BuildValidationEnvironmentName
            if ([string]::IsNullOrWhiteSpace($buildValidationLabel)) {
                $buildValidationLabel = 'Enabled'
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$mapping.BuildValidationBaselineRelease)) {
                $buildValidationLabel += " (baseline: $([string]$mapping.BuildValidationBaselineRelease))"
            }
        }

        Add-SpectreTableRow -Table $table -Cells @(
            $branchName,
            $devEnvironmentLabel,
            $(if ($environmentNames.Count -gt 0) { $environmentNames -join ', ' } else { '<none>' }),
            $buildValidationLabel
        )
    }

    [Spectre.Console.AnsiConsole]::Write($table)
}

function Get-SetupEnvironmentConfigurationSummary {
    <#
    .SYNOPSIS
        Summarizes environment configuration without displaying secrets.
    .DESCRIPTION
        Includes the selected Dataverse environment, credential metadata, service
        account and, when requested, the BUILD baseline selection.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()][object]$EnvironmentConfiguration,
        [Parameter()][switch]$IncludeBaseline,
        [Parameter()][AllowEmptyString()][string]$BaselineRelease = '',
        [Parameter()][switch]$BaselineConfigured
    )

    $friendlyName = [string](Get-OptionalObjectPropertyValue -InputObject $EnvironmentConfiguration -PropertyName 'FriendlyName')
    $environmentUrl = [string](Get-OptionalObjectPropertyValue -InputObject $EnvironmentConfiguration -PropertyName 'Url')
    $dataverseEnvironment = if (-not [string]::IsNullOrWhiteSpace($friendlyName) -and -not [string]::IsNullOrWhiteSpace($environmentUrl)) {
        "$friendlyName ($environmentUrl)"
    }
    elseif (-not [string]::IsNullOrWhiteSpace($friendlyName)) {
        $friendlyName
    }
    elseif (-not [string]::IsNullOrWhiteSpace($environmentUrl)) {
        $environmentUrl
    }
    else {
        'not configured'
    }

    $credentials = Get-OptionalObjectPropertyValue -InputObject $EnvironmentConfiguration -PropertyName 'Credentials'
    $credentialSummary = if ($credentials) {
        [string](Get-CredentialSummaryText -Credentials $credentials)
    }
    else {
        'not configured'
    }
    if ([string]::IsNullOrWhiteSpace($credentialSummary)) {
        $credentialSummary = 'configured'
    }

    $serviceAccount = [string](Get-OptionalObjectPropertyValue -InputObject $EnvironmentConfiguration -PropertyName 'ServiceAccountUPN')
    if ([string]::IsNullOrWhiteSpace($serviceAccount)) {
        $serviceAccount = 'not configured'
    }

    $summaryParts = @(
        "Dataverse: $dataverseEnvironment"
        "Credentials: $credentialSummary"
        "Service account: $serviceAccount"
    )
    if ($IncludeBaseline) {
        $baselineSummary = if (-not $BaselineConfigured) {
            'not configured'
        }
        elseif ([string]::IsNullOrWhiteSpace($BaselineRelease)) {
            'none'
        }
        else {
            $BaselineRelease
        }
        $summaryParts += "Baseline: $baselineSummary"
    }

    return ($summaryParts -join '; ')
}

function Invoke-SetupEnvironmentConfigurationWizard {
    <#
    .SYNOPSIS
        Edits the parts of one Dataverse environment configuration in order.
    .DESCRIPTION
        Uses a nested wizard so Dataverse selection, editable target names,
        credentials, service-account ownership, and an optional BUILD baseline
        have independent completion summaries. A generated target name is locked
        and pre-completed. Changing the Dataverse URL clears credentials and
        ownership selected for a different environment. Done returns the updated
        state; cancelling returns null to the calling editor.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'SelectDataverseEnvironmentAction', Justification = 'Captured by the nested Dataverse-environment step.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'SelectCredentialsAction', Justification = 'Captured by the nested credential step.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'SelectServiceAccountAction', Justification = 'Captured by the nested service-account step.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][scriptblock]$SelectDataverseEnvironmentAction,
        [Parameter()][AllowNull()][object]$InitialConfiguration,
        [Parameter()][AllowEmptyString()][string]$InitialTargetName = '',
        [Parameter()][string]$DataverseEnvironmentStepName = 'Dataverse environment',
        [Parameter()][scriptblock]$SelectTargetNameAction,
        [Parameter()][string]$TargetNameStepName = 'Target name',
        [Parameter()][switch]$TargetNameIsFixed,
        [Parameter(Mandatory)][scriptblock]$SelectCredentialsAction,
        [Parameter(Mandatory)][scriptblock]$SelectServiceAccountAction,
        [Parameter()][scriptblock]$SelectBaselineAction,
        [Parameter()][AllowEmptyString()][string]$InitialBaselineRelease = '',
        [Parameter()][switch]$BaselineConfigured,
        [Parameter()][string]$HelpDocRelativePath,
        [Parameter()][string]$HelpRef
    )

    # Bind commands now: closures created below cannot resolve sibling setup functions at invocation time.
    $requestSetupWizardBackCommand = Get-SetupCommandBinding -Name Request-SetupWizardBack

    $normalizeEnvironmentUrlScriptBlock = (Get-Command ConvertTo-NormalizedEnvironmentUrl -CommandType Function -ErrorAction Stop).ScriptBlock
    $credentialSummaryScriptBlock = (Get-Command Get-CredentialSummaryText -CommandType Function -ErrorAction Stop).ScriptBlock
    $targetName = [string](Get-OptionalObjectPropertyValue -InputObject $InitialConfiguration -PropertyName 'ShortName')
    if ([string]::IsNullOrWhiteSpace($targetName)) {
        $targetName = $InitialTargetName
    }

    $environmentState = [pscustomobject]@{
        ShortName         = $targetName
        FriendlyName      = [string](Get-OptionalObjectPropertyValue -InputObject $InitialConfiguration -PropertyName 'FriendlyName')
        Url               = ConvertTo-NormalizedEnvironmentUrl -Url ([string](Get-OptionalObjectPropertyValue -InputObject $InitialConfiguration -PropertyName 'Url'))
        Credentials       = Get-OptionalObjectPropertyValue -InputObject $InitialConfiguration -PropertyName 'Credentials'
        ServiceAccountUPN = [string](Get-OptionalObjectPropertyValue -InputObject $InitialConfiguration -PropertyName 'ServiceAccountUPN')
        BaselineRelease   = $InitialBaselineRelease
        BaselineConfigured = [bool]$BaselineConfigured
    }

    $steps = [System.Collections.Generic.List[object]]::new()
    $steps.Add([pscustomobject]@{
        Name = $DataverseEnvironmentStepName
        IsComplete = -not [string]::IsNullOrWhiteSpace($environmentState.Url)
        Summary = {
            if ([string]::IsNullOrWhiteSpace($environmentState.Url)) {
                return 'Not selected'
            }
            if ([string]::IsNullOrWhiteSpace($environmentState.FriendlyName)) {
                return $environmentState.Url
            }
            return "$($environmentState.FriendlyName) ($($environmentState.Url))"
        }.GetNewClosure()
        Action = {
            $selectedEnvironment = & $SelectDataverseEnvironmentAction $environmentState
            if ($null -eq $selectedEnvironment) {
                & $requestSetupWizardBackCommand
            }

            $selectedUrl = [string](& $normalizeEnvironmentUrlScriptBlock -Url ([string]$selectedEnvironment.Url))
            if ([string]::IsNullOrWhiteSpace($selectedUrl)) {
                & $requestSetupWizardBackCommand
            }

            if ($selectedUrl -ine $environmentState.Url) {
                $environmentState.Credentials = $null
                $environmentState.ServiceAccountUPN = ''
            }
            $environmentState.FriendlyName = [string]$selectedEnvironment.FriendlyName
            $environmentState.Url = $selectedUrl
        }.GetNewClosure()
    })

    if ($SelectTargetNameAction -or $TargetNameIsFixed) {
        $targetNameStep = [pscustomobject]@{
            Name = $TargetNameStepName
            IsComplete = -not [string]::IsNullOrWhiteSpace($environmentState.ShortName)
            IsLocked = [bool]$TargetNameIsFixed
            Summary = {
                if ([string]::IsNullOrWhiteSpace($environmentState.ShortName)) {
                    return 'Not configured'
                }
                if ($TargetNameIsFixed) {
                    return "$($environmentState.ShortName) (generated from branch)"
                }
                return $environmentState.ShortName
            }.GetNewClosure()
            Action = if ($SelectTargetNameAction) {
                {
                $selectedTargetName = [string](& $SelectTargetNameAction $environmentState)
                if ([string]::IsNullOrWhiteSpace($selectedTargetName)) {
                    & $requestSetupWizardBackCommand
                }
                $environmentState.ShortName = $selectedTargetName.Trim()
                }.GetNewClosure()
            }
            else {
                { & $requestSetupWizardBackCommand }.GetNewClosure()
            }
        }
        $steps.Add($targetNameStep)
    }

    $steps.Add([pscustomobject]@{
        Name = 'Credentials'
        IsComplete = $null -ne $environmentState.Credentials
        Summary = {
            if ($null -eq $environmentState.Credentials) {
                return 'Not configured'
            }
            $summary = [string](& $credentialSummaryScriptBlock -Credentials $environmentState.Credentials)
            if ([string]::IsNullOrWhiteSpace($summary)) {
                return 'Configured'
            }
            return $summary
        }.GetNewClosure()
        Action = {
            $selectedCredentials = & $SelectCredentialsAction $environmentState
            if ($null -eq $selectedCredentials) {
                & $requestSetupWizardBackCommand
            }
            $environmentState.Credentials = $selectedCredentials
        }.GetNewClosure()
    })
    $steps.Add([pscustomobject]@{
        Name = 'Service account'
        IsComplete = -not [string]::IsNullOrWhiteSpace($environmentState.ServiceAccountUPN)
        Summary = {
            if ([string]::IsNullOrWhiteSpace($environmentState.ServiceAccountUPN)) {
                return 'Not configured'
            }
            return $environmentState.ServiceAccountUPN
        }.GetNewClosure()
        Action = {
            $selectedServiceAccount = [string](& $SelectServiceAccountAction $environmentState)
            if ([string]::IsNullOrWhiteSpace($selectedServiceAccount)) {
                & $requestSetupWizardBackCommand
            }
            $environmentState.ServiceAccountUPN = $selectedServiceAccount.Trim()
        }.GetNewClosure()
    })

    if ($SelectBaselineAction) {
        $steps.Add([pscustomobject]@{
            Name = 'BUILD baseline'
            IsComplete = [bool]$environmentState.BaselineConfigured
            Summary = {
                if (-not $environmentState.BaselineConfigured) {
                    return 'Not configured'
                }
                if ([string]::IsNullOrWhiteSpace($environmentState.BaselineRelease)) {
                    return 'No baseline'
                }
                return $environmentState.BaselineRelease
            }.GetNewClosure()
            Action = {
                $selectedBaseline = & $SelectBaselineAction $environmentState
                if ($null -eq $selectedBaseline) {
                    & $requestSetupWizardBackCommand
                }
                $environmentState.BaselineRelease = [string]$selectedBaseline
                $environmentState.BaselineConfigured = $true
            }.GetNewClosure()
        })
    }

    $applyAction = { return $environmentState }.GetNewClosure()
    return Invoke-SetupWizard `
        -Title $Title `
        -Steps @($steps.ToArray()) `
        -ApplyAction $applyAction `
        -ApplyActionName 'Done' `
        -RequireSequentialSteps `
        -ReturnToCaller `
        -HelpDocRelativePath $HelpDocRelativePath `
        -HelpRef $HelpRef
}

function Get-SetupBranchMenuItem {
    <#
    .SYNOPSIS
        Creates selectable branch and environment rows for the guided setup menu.
    .DESCRIPTION
        Emits each configured branch and its DEV, deployment, and enabled BUILD-validation
        environments as indented menu entries with targets for focused editing.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter()][AllowNull()][object[]]$BranchStates
    )

    $menuItems = @()
    foreach ($branchState in @($BranchStates)) {
        if ($null -eq $branchState) {
            continue
        }

        $branchName = [string](Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'BranchName')
        if ([string]::IsNullOrWhiteSpace($branchName)) {
            continue
        }

        $menuItems += [pscustomobject]@{
            Label  = $branchName
            Depth  = 1
            Target = [pscustomobject]@{
                Kind       = 'Branch'
                BranchName = $branchName
            }
        }

        $devEnvironment = Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'DevEnvironmentConfiguration'
        if (-not $devEnvironment) {
            $devEnvironment = Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'ExistingDevEnvironment'
        }
        if ($devEnvironment) {
            $devName = [string](Get-OptionalObjectPropertyValue -InputObject $devEnvironment -PropertyName 'ShortName')
            if ([string]::IsNullOrWhiteSpace($devName)) {
                $devName = [string](Get-OptionalObjectPropertyValue -InputObject $devEnvironment -PropertyName 'FriendlyName')
            }
            if ([string]::IsNullOrWhiteSpace($devName)) {
                $devName = 'Configured'
            }
            $devSummary = Get-SetupEnvironmentConfigurationSummary -EnvironmentConfiguration $devEnvironment
            $menuItems += [pscustomobject]@{
                Label  = "DEV: $devName ($branchName) - $devSummary"
                Depth  = 2
                Target = [pscustomobject]@{
                    Kind            = 'DevEnvironment'
                    BranchName      = $branchName
                    EnvironmentName = $devName
                }
            }
        }

        $deploymentEnvironments = Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'DeploymentEnvironments'
        if ($null -eq $deploymentEnvironments) {
            $deploymentEnvironments = Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'Environments'
        }
        $deploymentIndex = 0
        foreach ($environment in @($deploymentEnvironments)) {
            if ($null -eq $environment) {
                continue
            }

            $deploymentIndex++
            $environmentName = [string](Get-OptionalObjectPropertyValue -InputObject $environment -PropertyName 'ShortName')
            if ([string]::IsNullOrWhiteSpace($environmentName)) {
                $environmentName = [string](Get-OptionalObjectPropertyValue -InputObject $environment -PropertyName 'FriendlyName')
            }
            if ([string]::IsNullOrWhiteSpace($environmentName)) {
                $environmentName = "Environment $deploymentIndex"
            }
            $environmentSummary = Get-SetupEnvironmentConfigurationSummary -EnvironmentConfiguration $environment
            $menuItems += [pscustomobject]@{
                Label  = "Deployment: $environmentName ($branchName) - $environmentSummary"
                Depth  = 2
                Target = [pscustomobject]@{
                    Kind            = 'DeploymentEnvironment'
                    BranchName      = $branchName
                    EnvironmentName = $environmentName
                }
            }
        }

        if ([bool](Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'BuildValidationEnabled')) {
            $buildValidationName = [string](Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'BuildValidationEnvironmentName')
            if ([string]::IsNullOrWhiteSpace($buildValidationName)) {
                $buildValidationEnvironment = Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'BuildValidationEnvironmentConfiguration'
                if (-not $buildValidationEnvironment) {
                    $buildValidationEnvironment = Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'ExistingBuildValidationEnvironment'
                }
                $buildValidationName = [string](Get-OptionalObjectPropertyValue -InputObject $buildValidationEnvironment -PropertyName 'ShortName')
            }
            if ([string]::IsNullOrWhiteSpace($buildValidationName)) {
                $buildValidationName = 'Configured'
            }
            $buildValidationEnvironment = Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'BuildValidationEnvironmentConfiguration'
            if (-not $buildValidationEnvironment) {
                $buildValidationEnvironment = Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'ExistingBuildValidationEnvironment'
            }
            $buildValidationSummary = Get-SetupEnvironmentConfigurationSummary `
                -EnvironmentConfiguration $buildValidationEnvironment `
                -IncludeBaseline `
                -BaselineRelease ([string](Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'BuildValidationBaselineRelease')) `
                -BaselineConfigured
            $menuItems += [pscustomobject]@{
                Label  = "BUILD validation: $buildValidationName ($branchName) - $buildValidationSummary"
                Depth  = 2
                Target = [pscustomobject]@{
                    Kind            = 'BuildValidation'
                    BranchName      = $branchName
                    EnvironmentName = $buildValidationName
                }
            }
        }
        else {
            # An empty target name opens the BUILD editor's enable prompt rather than the environment editor.
            $menuItems += [pscustomobject]@{
                Label  = "BUILD validation: Disabled ($branchName) - select to enable"
                Depth  = 2
                Target = [pscustomobject]@{
                    Kind            = 'BuildValidation'
                    BranchName      = $branchName
                    EnvironmentName = ''
                }
            }
        }
    }

    return @($menuItems)
}

function Get-SetupSinglePublishPlanSummary {
    <#
    .SYNOPSIS
        Formats the single repository publication plan for a guided setup menu.
    .DESCRIPTION
        Setup publishes generated files for every configured branch in one change on
        the selected target branch. Returns 'Not configured' when no plan exists.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()][object]$PublishPlan
    )

    if ($null -eq $PublishPlan) {
        return 'Not configured'
    }

    $targetBranch = [string](Get-OptionalObjectPropertyValue -InputObject $PublishPlan -PropertyName 'TargetBranch')
    $mode = [string](Get-OptionalObjectPropertyValue -InputObject $PublishPlan -PropertyName 'Mode')
    if ($mode -eq 'PullRequest') {
        $sourceBranch = [string](Get-OptionalObjectPropertyValue -InputObject $PublishPlan -PropertyName 'BranchName')
        if ([string]::IsNullOrWhiteSpace($sourceBranch)) {
            return "$targetBranch`: pull request for all branches"
        }
        return "$targetBranch`: PR from $sourceBranch for all branches"
    }

    if ($mode -eq 'Direct') {
        return "$targetBranch`: direct commit for all branches"
    }

    if ([string]::IsNullOrWhiteSpace($targetBranch)) {
        return 'Not configured'
    }
    return "$targetBranch`: not configured"
}

function Get-SetupSolutionMenuSummary {
    <#
    .SYNOPSIS
        Formats selected solution names for a guided setup menu.
    .DESCRIPTION
        Shows the source branch and at most three configured solution names. A null
        selection means solution setup has not run; an empty list is a valid selection.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()][object]$SolutionData,
        [Parameter()][string]$SourceBranch
    )

    if ($null -eq $SolutionData) {
        return 'Not configured'
    }

    $solutionNames = @()
    foreach ($solution in @(Get-OptionalObjectPropertyValue -InputObject $SolutionData -PropertyName 'Solutions')) {
        if ($null -eq $solution) {
            continue
        }

        $solutionName = [string](Get-OptionalObjectPropertyValue -InputObject $solution -PropertyName 'name')
        if ([string]::IsNullOrWhiteSpace($solutionName)) {
            $solutionName = [string](Get-OptionalObjectPropertyValue -InputObject $solution -PropertyName 'UniqueName')
        }
        if ([string]::IsNullOrWhiteSpace($solutionName)) {
            $solutionName = [string](Get-OptionalObjectPropertyValue -InputObject $solution -PropertyName 'uniquename')
        }
        if ([string]::IsNullOrWhiteSpace($solutionName)) {
            $solutionName = [string](Get-OptionalObjectPropertyValue -InputObject $solution -PropertyName 'FriendlyName')
        }
        if ([string]::IsNullOrWhiteSpace($solutionName) -and $solution -is [string]) {
            $solutionName = $solution
        }
        if (-not [string]::IsNullOrWhiteSpace($solutionName)) {
            $solutionNames += $solutionName
        }
    }

    $solutionSummary = if ($solutionNames.Count -eq 0) {
        'No solutions selected'
    }
    else {
        $visibleNames = @($solutionNames | Select-Object -First 3)
        if ($solutionNames.Count -gt $visibleNames.Count) {
            $visibleNames += "+$($solutionNames.Count - $visibleNames.Count)"
        }
        $visibleNames -join ', '
    }

    if (-not [string]::IsNullOrWhiteSpace($SourceBranch)) {
        $solutionSummary = '{0}: {1}' -f $SourceBranch, $solutionSummary
    }
    if ($solutionSummary.Length -gt 100) {
        $solutionSummary = $solutionSummary.Substring(0, 97).TrimEnd() + '...'
    }
    return $solutionSummary
}
