function Set-SetupWizardContext {
    # Script-scoped navigation/help state; CurrentStepIndex is zero-based.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string[]]$StepNames,
        [Parameter(Mandatory)][int]$CurrentStepIndex,
        [Parameter()][switch]$IsNavigationMenu,
        [Parameter()][string]$HelpDocRelativePath,
        [Parameter()][string]$HelpRef
    )

    $script:SetupWizardContext = [pscustomobject]@{
        Title                 = $Title
        StepNames             = @($StepNames)
        CurrentStepIndex      = $CurrentStepIndex
        IsNavigationMenu      = [bool]$IsNavigationMenu
        HelpDocRelativePath   = $HelpDocRelativePath
        HelpRef               = $HelpRef
    }
    Clear-SetupPromptDocContext
}

function Set-SetupPhaseContext {
    # Phase indexes are zero-based and independent of the wizard's step context.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$PhaseNames,
        [Parameter(Mandatory)][int]$CurrentPhaseIndex
    )

    $script:SetupPhaseContext = [pscustomobject]@{
        PhaseNames         = @($PhaseNames)
        CurrentPhaseIndex  = $CurrentPhaseIndex
    }
}

function Clear-SetupPhaseContext {
    [CmdletBinding()]
    param()

    Remove-Variable -Name 'SetupPhaseContext' -Scope Script -ErrorAction SilentlyContinue
}

function Get-SetupPhaseContext {
    [CmdletBinding()]
    param()

    return (Get-Variable -Name 'SetupPhaseContext' -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
}

function Clear-SetupWizardContext {
    [CmdletBinding()]
    param()

    Remove-Variable -Name 'SetupWizardContext' -Scope Script -ErrorAction SilentlyContinue
}

function Get-SetupWizardContext {
    [CmdletBinding()]
    param()

    return (Get-Variable -Name 'SetupWizardContext' -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
}

function Get-SetupCurrentSectionMessage {
    [CmdletBinding()]
    param()

    return (Get-Variable -Name 'SetupCurrentSectionMessage' -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
}

function Set-SetupPromptDocContext {
    # Replaces the script-scoped documentation context; it does not display guidance.
    [CmdletBinding()]
    param(
        [Parameter()][string]$DocRelativePath,
        [Parameter()][string]$Ref
    )

    $script:SetupPromptDocContext = [pscustomobject]@{
        DocRelativePath = $DocRelativePath
        Ref             = $Ref
    }
}

function Clear-SetupPromptDocContext {
    [CmdletBinding()]
    param()

    Remove-Variable -Name 'SetupPromptDocContext' -Scope Script -ErrorAction SilentlyContinue
    Remove-Variable -Name 'SetupActivePromptHelpUrl' -Scope Script -ErrorAction SilentlyContinue
}

function Get-SetupPromptDocContext {
    [CmdletBinding()]
    param()

    return (Get-Variable -Name 'SetupPromptDocContext' -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
}

function Get-SetupPromptHelpContext {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][string]$DocRelativePath,
        [Parameter()][string]$Ref
    )

    $promptDocContext = Get-SetupPromptDocContext
    $wizardContext = Get-SetupWizardContext
    $effectiveDocRelativePath = $DocRelativePath
    $effectiveRef = $Ref

    if ([string]::IsNullOrWhiteSpace($effectiveDocRelativePath)) {
        if ($promptDocContext -and -not [string]::IsNullOrWhiteSpace($promptDocContext.DocRelativePath)) {
            $effectiveDocRelativePath = [string]$promptDocContext.DocRelativePath
            if ([string]::IsNullOrWhiteSpace($effectiveRef)) {
                $effectiveRef = [string]$promptDocContext.Ref
            }
        }
        elseif ($wizardContext -and -not [string]::IsNullOrWhiteSpace($wizardContext.HelpDocRelativePath)) {
            $effectiveDocRelativePath = [string]$wizardContext.HelpDocRelativePath
        }
        else {
            $defaultHelpDocRelativePath = Get-Variable -Name 'SetupDefaultHelpDocRelativePath' -Scope Script -ValueOnly -ErrorAction SilentlyContinue
            $effectiveDocRelativePath = [string]$defaultHelpDocRelativePath
        }
    }

    if ([string]::IsNullOrWhiteSpace($effectiveRef) -and $wizardContext) {
        $effectiveRef = [string]$wizardContext.HelpRef
    }
    if ([string]::IsNullOrWhiteSpace($effectiveRef) -and $promptDocContext) {
        $effectiveRef = [string]$promptDocContext.Ref
    }
    if ([string]::IsNullOrWhiteSpace($effectiveDocRelativePath)) {
        return $null
    }

    return [pscustomobject]@{
        DocRelativePath = $effectiveDocRelativePath
        Ref             = (Get-Alm4DataverseDocumentationRef -Ref $effectiveRef)
    }
}

function Get-SetupPromptHelpUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][string]$DocRelativePath,
        [Parameter()][string]$Ref
    )

    $helpContext = Get-SetupPromptHelpContext -DocRelativePath $DocRelativePath -Ref $Ref
    if (-not $helpContext) {
        return ''
    }

    return Get-Alm4DataverseDocUrl -RelativePath $helpContext.DocRelativePath -Ref $helpContext.Ref
}

function Get-SetupActivePromptHelpUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return [string](Get-Variable -Name 'SetupActivePromptHelpUrl' -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
}

function Request-SetupWizardBack {
    # Navigation is an exception protocol so nested prompts can unwind to the wizard.
    [CmdletBinding()]
    param()

    throw ([System.InvalidOperationException]::new('__ALM4DATAVERSE_WIZARD_BACK__'))
}

function Test-IsSetupWizardBackException {
    # Match the exact marker and exception type, including reflection-wrapped errors.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][System.Exception]$Exception
    )

    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [System.InvalidOperationException] -and $current.Message -eq '__ALM4DATAVERSE_WIZARD_BACK__') {
            return $true
        }

        $current = $current.InnerException
    }

    return $false
}

function New-SetupHeroPanel {
    # Despite the legacy name this returns plain banner text, not a Spectre panel.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Message
    )

    Initialize-SpectreConsole

    return "ALM4Dataverse Setup - $Message"
}

function New-SetupTipsPanel {
    [CmdletBinding()]
    param()

    Initialize-SpectreConsole

    $tipLines = @(
        '- Use Up and Down arrows to move through prompts.',
        '- Press Enter to confirm the highlighted option.',
        '- Press Esc to return to the setup menu; Esc on the main menu cancels setup.',
        '- Longer lists automatically enable search so you can type to filter.',
        '- The wizard navigation menu appears after each step so you can go back before applying changes.'
    )

    return (New-SpectrePanel -Content ([Spectre.Console.Markup]::new(('[grey]' + (($tipLines | ForEach-Object { ConvertTo-SpectreMarkupLiteral -Text $_ }) -join '[/]' + [Environment]::NewLine + '[grey]') + '[/]'))) -Header 'Controls and flow' -BorderColor 'grey42' -Expand)
}

function Write-SetupDashboard {
    # Prefer a native full-width bar; hosts without cursor APIs get an inline banner.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [Parameter()][switch]$IncludeTrailingSpacer,
        [Parameter()][switch]$ShowProductBrand
    )

    Initialize-SpectreConsole

    if (-not (Write-SetupConsoleBar -Text (New-SetupHeroPanel -Message $Message) -ForegroundColor ([ConsoleColor]::Black) -BackgroundColor ([ConsoleColor]::Gray) -AdvanceCursor)) {
        $heroText = "[black on grey]$(ConvertTo-SpectreMarkupLiteral -Text (New-SetupHeroPanel -Message $Message))[/]"
        [Spectre.Console.AnsiConsole]::MarkupLine($heroText)
    }

    if ($ShowProductBrand) {
        $productVersion = [string](Get-Variable -Name 'ALM4DataverseVersion' -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
        if ([string]::IsNullOrWhiteSpace($productVersion)) {
            $productVersion = 'Development'
        }

        $brandIconRows = @(
            '⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀'
            '⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣠⣤⣶⣶⣶⣶⣶⣤⣄⡀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣠⣤⣶⣶⣶⣶⣦⣤⣀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀'
            '⠀⠀⠀⠀⠀⠀⠀⠀⣠⣶⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣦⣄⠀⠀⠀⠀⣠⣾⣿⣿⣿⣿⡿⢿⣿⣿⣿⣿⣿⣦⡄⠀⠀⠀⠀⠀⠀⠀⠀'
            '⠀⠀⠀⠀⠀⠀⠀⣴⡿⠟⠛⡛⠻⠿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣷⣄⢠⣾⣿⣿⣿⣿⡿⠟⠓⠀⠙⣿⣿⣿⣿⣿⣿⣦⠀⠀⠀⠀⠀⠀⠀'
            '⠀⠀⠀⠀⠀⠀⡜⡕⢌⠌⡂⡂⠅⠂⠀⠉⠻⢿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠋⣠⣶⣏⣠⣾⣿⣧⡈⢻⣿⣿⣿⣇⠀⠀⠀⠀⠀⠀'
            '⠀⠀⠀⠀⠀⠀⢕⢜⡔⡕⡕⡕⠀⠀⠀⠀⠀⠈⠻⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠇⢰⣿⣿⣿⣿⣿⣿⣿⣷⠀⢿⣿⣿⣿⠀⠀⠀⠀⠀⠀'
            '⠀⠀⠀⠀⠀⠐⣝⢮⡺⣜⢮⣂⠀⠀⠀⠀⠀⠀⠀⠈⠻⣿⣿⣿⣿⣿⣿⣿⣿⡿⢻⣿⣿⣿⣿⣿⣿⣿⣿⠿⣿⣿⣿⣿⠃⠀⠀⠀⠀⠀'
            '⠀⠀⠀⠀⠀⠀⢯⣗⣟⣮⣗⣗⡄⠀⠀⠀⠀⠀⢀⢄⠢⡊⡻⣿⣿⣿⣿⣿⣿⣧⠈⢿⣿⣿⣿⣿⣿⣿⠏⢠⣿⣿⣿⣿⠀⠀⠀⠀⠀⠀'
            '⠀⠀⠀⠀⠀⠀⠘⣷⣻⣾⢾⣳⡿⣵⢦⢤⣔⢖⡵⡱⡕⡕⡜⡜⣻⣿⣿⣿⣿⣿⣷⣄⡉⠛⠻⣿⡏⣁⣴⣿⣿⣿⣿⠃⠀⠀⠀⠀⠀⠀'
            '⠀⠀⠀⠀⠀⠀⠀⠘⢿⢿⣿⣿⣿⣟⣿⣽⣞⣯⢯⣻⢮⣫⢞⠮⠂⠈⢿⣿⣿⣿⣿⣿⣿⣿⣷⣿⣿⣿⣿⣿⣿⡿⠃⠀⠀⠀⠀⠀⠀⠀'
            '⠀⠀⠀⠀⠀⠀⠀⠀⠀⠙⠿⣿⣿⣿⣿⣿⣽⣯⣿⣽⣽⠞⠉⠀⠀⠀⠀⠈⠻⢿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠿⠋⠀⠀⠀⠀⠀⠀⠀⠀⠀'
            '⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠉⠙⠛⠛⠛⠛⠋⠉⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⠉⠛⠛⠛⠛⠛⠉⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀'
        )
        $brandNameRowIndex = 4
        $brandVersionRowIndex = 6
        $brandVersionMarkup = '[grey]' +
            (ConvertTo-SpectreMarkupLiteral -Text $productVersion) +
            '[/]'
        [Spectre.Console.AnsiConsole]::WriteLine()
        for ($brandRowIndex = 0; $brandRowIndex -lt $brandIconRows.Count; $brandRowIndex++) {
            $brandRowMarkup = '[bold green]' + $brandIconRows[$brandRowIndex] + '[/]'
            if ($brandRowIndex -eq $brandNameRowIndex) {
                $brandRowMarkup += '    [bold]ALM4Dataverse[/]'
            }
            elseif ($brandRowIndex -eq $brandVersionRowIndex) {
                $brandRowMarkup += "    $brandVersionMarkup"
            }
            [Spectre.Console.AnsiConsole]::MarkupLine($brandRowMarkup)
        }
    }

    if ($IncludeTrailingSpacer) {
        [Spectre.Console.AnsiConsole]::WriteLine()
    }
}

function Test-IsUserInterruptException {
    # Inspect wrappers because async/reflection calls can hide the cancellation type.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][System.Exception]$Exception
    )

    $current = $Exception
    while ($null -ne $current) {
        if (
            $current -is [System.Management.Automation.PipelineStoppedException] -or
            $current -is [System.OperationCanceledException] -or
            $current -is [System.Threading.Tasks.TaskCanceledException]
        ) {
            return $true
        }

        $current = $current.InnerException
    }

    return $false
}

function Invoke-SetupWizard {
    <#
    .SYNOPSIS
        Executes named setup steps linearly or through a guided navigation menu.
    .PARAMETER Steps
        Ordered objects with Name and Action scriptblock properties. Optional
        IsComplete and IsLocked properties represent completed prerequisite steps;
        LockAfterCompletion prevents repeating one-time setup actions. Summary may
        be a string or scriptblock; scriptblocks are evaluated each time the menu is
        rendered. SubItems may be a scriptblock returning ordered objects with Label,
        Depth, and Target properties. These rows appear indented beneath their parent,
        and selecting one passes Target as the Action's first argument. Steps may provide
        HelpDocRelativePath and HelpRef to select their own help page and documentation
        revision. Steps without a summary show Complete or Not configured.
    .PARAMETER PreviewAction
        Adds an optional preview action, separate from required setup steps. It is
        available only after every setup step is complete and selecting it does not
        change setup completion.
    .PARAMETER PreviewActionName
        Label for the optional preview action.
    .PARAMETER ApplyAction
        When supplied, adds an Apply changes action in a separate menu group. It is
        ready only after all setup steps are complete. Failed applies are reported and
        return to the menu without discarding step state.
    .PARAMETER IsNewRepository
        Restricts new repositories to the furthest step reached, while still allowing
        users to revisit earlier steps.
    .PARAMETER RequireSequentialSteps
        Restricts navigation to the furthest step reached for workflows that must
        complete prerequisite steps in order.
    .PARAMETER ReturnToCaller
        Requires ApplyAction, hides the whole-setup exit action, and returns null when
        the navigation menu is cancelled. Use this for nested editors.
    .PARAMETER HelpDocRelativePath
        Default help page for the wizard and steps without a step-specific page.
    .PARAMETER HelpRef
        Documentation revision used for wizard help links unless a prompt supplies
        another ref. F1 opens the current help page and resumes the prompt.
    .DESCRIPTION
        Without ApplyAction, a back marker repeats the preceding step; if the first
        step has no predecessor, setup is cancelled. With ApplyAction, step selection
        is menu-driven and all setup steps must complete before previewing or applying.
        PreviewAction is optional and does not change setup completion. Setup and action
        choices are grouped separately in the menu. Exit without applying changes is
        always available with ApplyAction and asks for confirmation before leaving.
        Escape in a step returns to the navigation menu; Escape on that menu cancels
        setup. F1 opens the active help page without leaving the prompt. Re-running a
        step invalidates completion of later steps; locked prerequisite steps remain
        complete. No action side effects are rolled back.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][array]$Steps,
        [Parameter()][scriptblock]$PreviewAction,
        [Parameter()][string]$PreviewActionName = 'Preview changes',
        [Parameter()][scriptblock]$ApplyAction,
        [Parameter()][string]$ApplyActionName = 'Apply changes',
        [Parameter()][switch]$IsNewRepository,
        [Parameter()][switch]$RequireSequentialSteps,
        [Parameter()][switch]$ReturnToCaller,
        [Parameter()][string]$HelpDocRelativePath,
        [Parameter()][string]$HelpRef
    )

    if ($PreviewAction -and -not $ApplyAction) {
        throw 'PreviewAction requires ApplyAction.'
    }
    if ($ReturnToCaller -and -not $ApplyAction) {
        throw 'ReturnToCaller requires ApplyAction.'
    }

    if ($Steps.Count -eq 0 -and -not $ApplyAction) {
        return
    }

    $stepNames = @($Steps | ForEach-Object { [string]$_.Name })

    if ($ApplyAction) {
        $previewActionIndex = -1
        $applyActionIndex = $Steps.Count
        $exitActionName = 'Exit without applying changes'
        $menuStepNames = @($stepNames)
        if ($PreviewAction) {
            $previewActionIndex = $Steps.Count
            $applyActionIndex++
            $menuStepNames += $PreviewActionName
        }
        $menuStepNames += $ApplyActionName
        $exitActionIndex = -1
        if (-not $ReturnToCaller) {
            $exitActionIndex = $applyActionIndex + 1
            $menuStepNames += $exitActionName
        }
        $completedSteps = [bool[]]::new($Steps.Count)
        $lockedSteps = [bool[]]::new($Steps.Count)
        for ($stepIndex = 0; $stepIndex -lt $Steps.Count; $stepIndex++) {
            $stepProperties = @($Steps[$stepIndex].PSObject.Properties.Name)
            $lockedSteps[$stepIndex] = $stepProperties -contains 'IsLocked' -and [bool]$Steps[$stepIndex].IsLocked
            $completedSteps[$stepIndex] = (
                $lockedSteps[$stepIndex] -or
                ($stepProperties -contains 'IsComplete' -and [bool]$Steps[$stepIndex].IsComplete)
            )
        }
        $furthestStepIndex = -1
        while (($furthestStepIndex + 1) -lt $Steps.Count -and $completedSteps[$furthestStepIndex + 1]) {
            $furthestStepIndex++
        }
        $requireSequentialSteps = $IsNewRepository -or $RequireSequentialSteps
        $currentStepIndex = 0

        try {
            while ($true) {
                $stepMenuItems = @()
                $stepMenuIndexes = @()
                $stepMenuTargets = @()
                $hasSubItems = $false
                for ($stepIndex = 0; $stepIndex -lt $Steps.Count; $stepIndex++) {
                    $completionLabel = if ($completedSteps[$stepIndex]) { '[✓]' } else { '[ ]' }
                    $stepProperties = @($Steps[$stepIndex].PSObject.Properties.Name)
                    $subItems = @()
                    if ($stepProperties -contains 'SubItems') {
                        $subItemsValue = $Steps[$stepIndex].SubItems
                        if ($subItemsValue -is [scriptblock]) {
                            $subItems = @(& $subItemsValue)
                        }
                        elseif ($null -ne $subItemsValue) {
                            $subItems = @($subItemsValue)
                        }
                    }

                    $summaryText = 'Not configured'
                    if ($stepProperties -contains 'Summary' -and $subItems.Count -eq 0) {
                        $summaryValue = $Steps[$stepIndex].Summary
                        if ($summaryValue -is [scriptblock]) {
                            $summaryValue = @(& $summaryValue) -join ', '
                        }
                        elseif ($summaryValue -is [array]) {
                            $summaryValue = $summaryValue -join ', '
                        }

                        if (-not [string]::IsNullOrWhiteSpace([string]$summaryValue)) {
                            $summaryText = [string]$summaryValue
                        }
                    }
                    elseif ($completedSteps[$stepIndex] -and $subItems.Count -eq 0) {
                        $summaryText = 'Complete'
                    }
                    $summaryText = ($summaryText -replace '\s+', ' ').Trim()
                    if ([string]::IsNullOrWhiteSpace($summaryText)) {
                        $summaryText = if ($completedSteps[$stepIndex]) { 'Complete' } else { 'Not configured' }
                    }

                    $lockedAfterCompletion = (
                        $stepProperties -contains 'LockAfterCompletion' -and
                        [bool]$Steps[$stepIndex].LockAfterCompletion -and
                        $completedSteps[$stepIndex]
                    )
                    $lockedLabel = if ($lockedSteps[$stepIndex] -or $lockedAfterCompletion) {
                        ' (locked)'
                    }
                    elseif ($requireSequentialSteps -and $stepIndex -gt ($furthestStepIndex + 1)) {
                        ' (locked; complete earlier steps first)'
                    }
                    else {
                        ''
                    }
                    $stepMenuItems += if ($subItems.Count -gt 0) {
                        "$completionLabel $($stepNames[$stepIndex])$lockedLabel"
                    }
                    else {
                        "$completionLabel $($stepNames[$stepIndex]) - $summaryText$lockedLabel"
                    }
                    $stepMenuIndexes += $stepIndex
                    $stepMenuTargets += [pscustomobject]@{
                        HasTarget = $false
                        Target    = $null
                    }

                    foreach ($subItem in $subItems) {
                        if ($null -eq $subItem) {
                            throw "Setup step '$($stepNames[$stepIndex])' returned a null SubItems entry."
                        }

                        $subItemProperties = @($subItem.PSObject.Properties.Name)
                        if (
                            $subItemProperties -notcontains 'Label' -or
                            $subItemProperties -notcontains 'Depth' -or
                            $subItemProperties -notcontains 'Target'
                        ) {
                            throw "Setup step '$($stepNames[$stepIndex])' SubItems must have Label, Depth, and Target properties."
                        }

                        $subItemLabel = [string]$subItem.Label
                        $subItemDepth = [int]$subItem.Depth
                        if ([string]::IsNullOrWhiteSpace($subItemLabel) -or $subItemDepth -lt 1 -or $null -eq $subItem.Target) {
                            throw "Setup step '$($stepNames[$stepIndex])' returned an invalid SubItems entry."
                        }

                        $stepMenuItems += ('  ' * $subItemDepth) + $subItemLabel
                        $stepMenuIndexes += $stepIndex
                        $stepMenuTargets += [pscustomobject]@{
                            HasTarget = $true
                            Target    = $subItem.Target
                        }
                        $hasSubItems = $true
                    }
                }

                $allStepsCompleted = -not ($completedSteps -contains $false)
                $applyMenuLabel = if ($allStepsCompleted) {
                    "$ApplyActionName - Ready"
                }
                else {
                    "$ApplyActionName (finish all setup steps first) - Not ready"
                }
                $previewMenuLabel = if ($allStepsCompleted) {
                    $PreviewActionName
                }
                else {
                    "$PreviewActionName (finish all setup steps first) - Not ready"
                }
                $actionMenuItems = @()
                if ($PreviewAction) {
                    $actionMenuItems += $previewMenuLabel
                }
                $actionMenuItems += $applyMenuLabel
                if (-not $ReturnToCaller) {
                    $actionMenuItems += $exitActionName
                }
                $nextStepIndex = [Array]::IndexOf($completedSteps, $false)
                if ($allStepsCompleted) {
                    $menuItems = @($applyMenuLabel)
                    $menuStepIndexes = @($applyActionIndex)
                    $menuActionTargets = @([pscustomobject]@{ HasTarget = $false; Target = $null })
                    if ($PreviewAction) {
                        $menuItems += $previewMenuLabel
                        $menuStepIndexes += $previewActionIndex
                        $menuActionTargets += [pscustomobject]@{ HasTarget = $false; Target = $null }
                    }
                    if (-not $ReturnToCaller) {
                        $menuItems += $exitActionName
                        $menuStepIndexes += $exitActionIndex
                        $menuActionTargets += [pscustomobject]@{ HasTarget = $false; Target = $null }
                    }
                    $menuItems += $stepMenuItems
                    $menuStepIndexes += $stepMenuIndexes
                    $menuActionTargets += $stepMenuTargets
                    $currentStepIndex = $applyActionIndex
                }
                else {
                    $menuItems = @($stepMenuItems)
                    $menuStepIndexes = @($stepMenuIndexes)
                    $menuActionTargets = @($stepMenuTargets)
                    if ($PreviewAction) {
                        $menuItems += $previewMenuLabel
                        $menuStepIndexes += $previewActionIndex
                        $menuActionTargets += [pscustomobject]@{ HasTarget = $false; Target = $null }
                    }
                    $menuItems += $applyMenuLabel
                    $menuStepIndexes += $applyActionIndex
                    $menuActionTargets += [pscustomobject]@{ HasTarget = $false; Target = $null }
                    if (-not $ReturnToCaller) {
                        $menuItems += $exitActionName
                        $menuStepIndexes += $exitActionIndex
                        $menuActionTargets += [pscustomobject]@{ HasTarget = $false; Target = $null }
                    }
                    $currentStepIndex = $nextStepIndex
                }

                Set-SetupWizardContext `
                    -Title $Title `
                    -StepNames $menuStepNames `
                    -CurrentStepIndex $currentStepIndex `
                    -IsNavigationMenu `
                    -HelpDocRelativePath $HelpDocRelativePath `
                    -HelpRef $HelpRef

                $promptGuidanceLines = @(
                    'Work through each setup step, or select any available step to revisit it.'
                )
                if ($hasSubItems) {
                    $promptGuidanceLines += 'Select an indented branch or environment to jump to its configuration.'
                }
                if ($PreviewAction) {
                    $promptGuidanceLines += "$PreviewActionName is optional, is available after every setup step is complete, and does not complete a setup step."
                }
                $promptGuidanceLines += "$ApplyActionName is available after every setup step has been completed."
                if (-not $ReturnToCaller) {
                    $promptGuidanceLines += "$exitActionName asks for confirmation before ending setup without applying the pending changes."
                }

                $selection = Select-FromMenu `
                    -Title "$Title menu" `
                    -Items $menuItems `
                    -ActionItems $actionMenuItems `
                    -ActionSectionTitle '---' `
                    -ActionSectionFirst:$allStepsCompleted `
                    -PromptGuidanceLines $promptGuidanceLines

                if ($null -eq $selection) {
                    if ($ReturnToCaller) {
                        return $null
                    }
                    throw 'Setup cancelled before changes were applied.'
                }

                $selectedStepIndex = $menuStepIndexes[$selection]
                $selectedMenuTarget = $menuActionTargets[$selection]
                if ($selectedStepIndex -eq $exitActionIndex) {
                    $currentStepIndex = $exitActionIndex
                    Set-SetupWizardContext `
                        -Title $Title `
                        -StepNames $menuStepNames `
                        -CurrentStepIndex $currentStepIndex `
                        -HelpDocRelativePath $HelpDocRelativePath `
                        -HelpRef $HelpRef
                    try {
                        $exitWithoutApplying = Read-YesNo `
                            -Prompt 'Exit setup without applying changes?' `
                            -PromptGuidanceLines @(
                                'Your current setup selections will not be applied.',
                                'Resources created during earlier setup prerequisites are not rolled back.'
                            ) `
                            -DefaultNo
                    }
                    catch {
                        if (Test-IsSetupWizardBackException -Exception $_.Exception) {
                            continue
                        }
                        throw
                    }

                    if ($exitWithoutApplying) {
                        Write-Host 'Exiting setup without applying changes.' -ForegroundColor Yellow
                        throw 'Setup exited without applying changes.'
                    }

                    continue
                }

                if ($selectedStepIndex -eq $applyActionIndex) {
                    if (-not $allStepsCompleted) {
                        Write-Host 'Complete every setup step before applying changes.' -ForegroundColor Yellow
                        continue
                    }

                    try {
                        $currentStepIndex = $applyActionIndex
                        Set-SetupWizardContext `
                            -Title $Title `
                            -StepNames $menuStepNames `
                            -CurrentStepIndex $applyActionIndex `
                            -HelpDocRelativePath $HelpDocRelativePath `
                            -HelpRef $HelpRef
                        return (& $ApplyAction)
                    }
                    catch {
                        if (Test-IsSetupWizardBackException -Exception $_.Exception) {
                            continue
                        }
                        if (Test-IsUserInterruptException -Exception $_.Exception) {
                            throw
                        }

                        Write-SetupWizardApplyFailure -OperationName $ApplyActionName -ErrorRecord $_
                        continue
                    }
                }

                if ($selectedStepIndex -eq $previewActionIndex) {
                    if (-not $allStepsCompleted) {
                        Write-Host 'Complete every setup step before previewing changes.' -ForegroundColor Yellow
                        continue
                    }

                    $currentStepIndex = $previewActionIndex
                    Set-SetupWizardContext `
                        -Title $Title `
                        -StepNames $menuStepNames `
                        -CurrentStepIndex $currentStepIndex `
                        -HelpDocRelativePath $HelpDocRelativePath `
                        -HelpRef $HelpRef
                    try {
                        & $PreviewAction | Out-Null
                    }
                    catch {
                        if (Test-IsSetupWizardBackException -Exception $_.Exception) {
                            continue
                        }
                        throw
                    }
                    continue
                }

                $selectedStepProperties = @($Steps[$selectedStepIndex].PSObject.Properties.Name)
                $lockedAfterCompletion = (
                    $selectedStepProperties -contains 'LockAfterCompletion' -and
                    [bool]$Steps[$selectedStepIndex].LockAfterCompletion -and
                    $completedSteps[$selectedStepIndex]
                )
                if ($lockedSteps[$selectedStepIndex] -or $lockedAfterCompletion) {
                    Write-Host 'This setup step is locked because it has already been completed.' -ForegroundColor Yellow
                    continue
                }

                if ($requireSequentialSteps -and $selectedStepIndex -gt ($furthestStepIndex + 1)) {
                    Write-Host 'Complete the earlier setup steps before moving forward.' -ForegroundColor Yellow
                    continue
                }

                $currentStepIndex = $selectedStepIndex
                $stepHelpDocRelativePath = $HelpDocRelativePath
                $stepHelpRef = $HelpRef
                if (
                    $selectedStepProperties -contains 'HelpDocRelativePath' -and
                    -not [string]::IsNullOrWhiteSpace([string]$Steps[$selectedStepIndex].HelpDocRelativePath)
                ) {
                    $stepHelpDocRelativePath = [string]$Steps[$selectedStepIndex].HelpDocRelativePath
                }
                if (
                    $selectedStepProperties -contains 'HelpRef' -and
                    -not [string]::IsNullOrWhiteSpace([string]$Steps[$selectedStepIndex].HelpRef)
                ) {
                    $stepHelpRef = [string]$Steps[$selectedStepIndex].HelpRef
                }
                Set-SetupWizardContext `
                    -Title $Title `
                    -StepNames $menuStepNames `
                    -CurrentStepIndex $currentStepIndex `
                    -HelpDocRelativePath $stepHelpDocRelativePath `
                    -HelpRef $stepHelpRef
                try {
                    if ($selectedMenuTarget.HasTarget) {
                        & $Steps[$selectedStepIndex].Action $selectedMenuTarget.Target | Out-Null
                    }
                    else {
                        & $Steps[$selectedStepIndex].Action | Out-Null
                    }
                }
                catch {
                    if (Test-IsSetupWizardBackException -Exception $_.Exception) {
                        continue
                    }
                    throw
                }

                $completedSteps[$selectedStepIndex] = $true
                if ($selectedStepIndex -gt $furthestStepIndex) {
                    $furthestStepIndex = $selectedStepIndex
                }
                for ($laterStepIndex = $selectedStepIndex + 1; $laterStepIndex -lt $Steps.Count; $laterStepIndex++) {
                    if (-not $lockedSteps[$laterStepIndex]) {
                        $completedSteps[$laterStepIndex] = $false
                    }
                }
            }
        }
        finally {
            Clear-SetupWizardContext
        }
    }

    $currentStepIndex = 0
    try {
        while ($currentStepIndex -lt $Steps.Count) {
            try {
                $stepProperties = @($Steps[$currentStepIndex].PSObject.Properties.Name)
                $stepHelpDocRelativePath = $HelpDocRelativePath
                $stepHelpRef = $HelpRef
                if (
                    $stepProperties -contains 'HelpDocRelativePath' -and
                    -not [string]::IsNullOrWhiteSpace([string]$Steps[$currentStepIndex].HelpDocRelativePath)
                ) {
                    $stepHelpDocRelativePath = [string]$Steps[$currentStepIndex].HelpDocRelativePath
                }
                if (
                    $stepProperties -contains 'HelpRef' -and
                    -not [string]::IsNullOrWhiteSpace([string]$Steps[$currentStepIndex].HelpRef)
                ) {
                    $stepHelpRef = [string]$Steps[$currentStepIndex].HelpRef
                }
                Set-SetupWizardContext `
                    -Title $Title `
                    -StepNames $stepNames `
                    -CurrentStepIndex $currentStepIndex `
                    -HelpDocRelativePath $stepHelpDocRelativePath `
                    -HelpRef $stepHelpRef
                & $Steps[$currentStepIndex].Action
                $currentStepIndex++
            }
            catch {
                if (Test-IsSetupWizardBackException -Exception $_.Exception) {
                    if ($currentStepIndex -gt 0) {
                        $currentStepIndex--
                        continue
                    }

                    throw ([System.OperationCanceledException]::new('Setup cancelled by user.'))
                }

                throw
            }
        }
    }
    finally {
        Clear-SetupWizardContext
    }
}

function Write-SetupWizardApplyFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OperationName,
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    Initialize-SpectreConsole
    $errorMessage = [string]$ErrorRecord.Exception.Message
    $errorType = [string]$ErrorRecord.Exception.GetType().Name
    [Spectre.Console.AnsiConsole]::MarkupLine("[bold red]$([string](ConvertTo-SpectreMarkupLiteral -Text "Apply failed: $OperationName"))[/]")
    [Spectre.Console.AnsiConsole]::MarkupLine("[yellow]$([string](ConvertTo-SpectreMarkupLiteral -Text $errorType)): $([string](ConvertTo-SpectreMarkupLiteral -Text $errorMessage))[/]")
    [Spectre.Console.AnsiConsole]::MarkupLine('[grey]Your setup selections are still available. Edit a step or select Apply changes to retry.[/]')

    if ($ErrorRecord.InvocationInfo.PositionMessage) {
        [Spectre.Console.AnsiConsole]::MarkupLine("[grey]$([string](ConvertTo-SpectreMarkupLiteral -Text $ErrorRecord.InvocationInfo.PositionMessage.Trim()))[/]")
    }
}

function Confirm-SetupReviewAction {
    # Returns no value on approval; cancellation, including a null menu result, throws.
    [CmdletBinding()]
    param(
        [Parameter()][string]$ApplyLabel = 'Apply changes',
        [Parameter()][string]$CancelLabel = 'Cancel setup',
        [Parameter()][string]$Title = 'Review complete. Apply the configuration or cancel setup.'
    )

    $selection = Select-FromMenu -Title $Title -Items @($ApplyLabel, $CancelLabel) -PromptGuidanceLines @(
                'Are you ready to apply the changes?'
            ) `
            -PromptGuidanceDocRelativePath 'docs/config/alm-config.md'

    if ($null -eq $selection) {
        throw 'Setup cancelled by user.'
    }

    if ($selection -ne 0) {
        throw 'Setup cancelled by user.'
    }
}
