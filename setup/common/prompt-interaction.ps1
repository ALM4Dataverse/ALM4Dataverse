function Show-SetupPromptGuidance {
    # Prompt-local guidance must not replace the section's stored documentation context.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PromptText,
        [Parameter()][string[]]$GuidanceLines,
        [Parameter()][string]$DocRelativePath,
        [Parameter()][string]$Ref,
        [Parameter()][switch]$OmitTrailingSpacer
    )

    $effectiveGuidanceLines = @($GuidanceLines)

    if (
        @($effectiveGuidanceLines).Count -eq 0 -and
        [string]::IsNullOrWhiteSpace($DocRelativePath)
    ) {
        return
    }

    $guidanceHeader = if ([string]::IsNullOrWhiteSpace($PromptText)) { 'Prompt guidance' } else { $PromptText }

    Write-SetupGuidance `
        -Lines $effectiveGuidanceLines `
        -DocRelativePath $DocRelativePath `
        -Ref $Ref `
        -Header $guidanceHeader `
        -SkipContextUpdate `
        -OmitTrailingSpacer:$OmitTrailingSpacer
}

function Get-SetupPromptInlineText {
    # All prompt kinds currently share one escaped label format; this returns markup.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateSet('Text', 'YesNo', 'Secret')][string]$PromptKind,
        [Parameter()][string]$PromptText
    )

    $promptLabel = if ([string]::IsNullOrWhiteSpace($PromptText)) {
        'Input'
    }
    else {
        $PromptText.Trim()
    }

    $inlinePrefix = "[grey]$([string](ConvertTo-SpectreMarkupLiteral -Text $promptLabel)) >[/]"

    switch ($PromptKind) {
        'Text' { return $inlinePrefix }
        'YesNo' { return $inlinePrefix }
        'Secret' { return $inlinePrefix }
    }
}

function Write-SetupConsoleBar {
    <#
    .SYNOPSIS
        Attempts a native console row write and reports whether it succeeded.
    .DESCRIPTION
        Returns false on unavailable console APIs or write/restore failures so callers
        can render inline instead. Text is plain, not markup. AtBottom overrides
        TargetRow; negative TargetRow means the current row. Colors are restored.
    .PARAMETER RestoreCursorPosition
        Restores the saved position within current buffer bounds, taking precedence
        over AdvanceCursor. With neither switch, the cursor stays after the written text.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][string]$Text,
        [Parameter()][ConsoleColor]$ForegroundColor = [ConsoleColor]::Black,
        [Parameter()][ConsoleColor]$BackgroundColor = [ConsoleColor]::Gray,
        [Parameter()][int]$TargetRow = -1,
        [Parameter()][switch]$AtBottom,
        [Parameter()][switch]$RestoreCursorPosition,
        [Parameter()][switch]$AdvanceCursor
    )

    try {
        $windowWidth = [Console]::WindowWidth
        $windowHeight = [Console]::WindowHeight
        if ($windowWidth -le 0 -or $windowHeight -le 0) {
            return $false
        }

        $resolvedRow = if ($AtBottom) {
            [Math]::Max($windowHeight - 1, 0)
        }
        elseif ($TargetRow -lt 0) {
            [Console]::CursorTop
        }
        else {
            [Math]::Min($TargetRow, [Math]::Max($windowHeight - 1, 0))
        }

        $barText = if ($null -eq $Text) { '' } else { [string]$Text }
        $renderText = if ($barText.Length -ge $windowWidth) {
            $barText.Substring(0, [Math]::Max($windowWidth - 1, 0))
        }
        else {
            $barText.PadRight($windowWidth)
        }

        $originalForeground = [Console]::ForegroundColor
        $originalBackground = [Console]::BackgroundColor
        $originalCursorLeft = [Console]::CursorLeft
        $originalCursorTop = [Console]::CursorTop

        try {
            [Console]::SetCursorPosition(0, $resolvedRow)
            [Console]::ForegroundColor = $ForegroundColor
            [Console]::BackgroundColor = $BackgroundColor
            [Console]::Write($renderText)
        }
        finally {
            [Console]::ForegroundColor = $originalForeground
            [Console]::BackgroundColor = $originalBackground

            if ($RestoreCursorPosition) {
                $safeCursorTop = [Math]::Min($originalCursorTop, [Math]::Max([Console]::BufferHeight - 1, 0))
                $safeCursorLeft = [Math]::Min($originalCursorLeft, [Math]::Max([Console]::BufferWidth - 1, 0))
                [Console]::SetCursorPosition($safeCursorLeft, $safeCursorTop)
            }
            elseif ($AdvanceCursor) {
                $nextRow = [Math]::Min($resolvedRow + 1, [Math]::Max([Console]::BufferHeight - 1, 0))
                [Console]::SetCursorPosition(0, $nextRow)
            }
        }

        return $true
    }
    catch {
        return $false
    }
}

function Show-SetupStatusBarAtBottom {
    # Menu hints describe filtering only when enabled. F1 appears only when the
    # active prompt has a documentation URL; Escape follows wizard navigation.
    # Cursor-host failures render an inline line that cleanup cannot erase.
    [CmdletBinding()]
    param(
        [Parameter()][ValidateSet('Menu', 'Text', 'YesNo', 'Secret')][string]$PromptKind = 'Text',
        [Parameter()][switch]$SearchEnabled
    )

    Initialize-SpectreConsole

    $wizardContext = Get-SetupWizardContext
    $escapeHint = if ($wizardContext -and -not $wizardContext.IsNavigationMenu) {
        'Esc=back'
    }
    else {
        'Esc=cancel'
    }
    $helpHint = if (-not [string]::IsNullOrWhiteSpace((Get-SetupActivePromptHelpUrl))) {
        'F1=help'
    }
    else {
        $null
    }

    $segments = switch ($PromptKind) {
        'Menu' {
            @(
                'Up/Down=move',
                'Enter=select',
                $(if ($SearchEnabled) { 'Type=filter' } else { $null }),
                $helpHint,
                $escapeHint,
                'Ctrl+C=exit'
            )
        }
        'YesNo' {
            @(
                'Y/N=choose',
                'Enter=confirm',
                $helpHint,
                $escapeHint,
                'Ctrl+C=exit'
            )
        }
        'Secret' {
            @(
                'Enter=confirm',
                $helpHint,
                $escapeHint,
                'Ctrl+C=exit'
            )
        }
        default {
            @(
                'Enter=confirm',
                $helpHint,
                $escapeHint,
                'Ctrl+C=exit'
            )
        }
    }

    $segments = @($segments | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($segments.Count -eq 0) {
        return
    }

    $statusText = ($segments -join '  -  ')

    if (-not (Write-SetupConsoleBar -Text $statusText -ForegroundColor ([ConsoleColor]::Black) -BackgroundColor ([ConsoleColor]::Gray) -AtBottom -RestoreCursorPosition)) {
        $markup = '[black on grey]' + (($segments | ForEach-Object { ConvertTo-SpectreMarkupLiteral -Text $_ }) -join '  -  ') + '[/]'
        [Spectre.Console.AnsiConsole]::MarkupLine($markup)
    }
}

function Clear-SetupStatusBarAtBottom {
    # Best-effort native-row cleanup only; an unsupported host is not an error.
    [CmdletBinding()]
    param()

    [void](Write-SetupConsoleBar -Text '' -AtBottom -RestoreCursorPosition)
}

function Add-SetupConsoleCancelHandler {
    # Returns whether registration succeeded; reflection is a compatibility fallback.
    # The caller owns removal of the same delegate when this returns true.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][System.ConsoleCancelEventHandler]$Handler
    )

    try {
        [System.Console]::add_CancelKeyPress($Handler)
        return $true
    }
    catch {
        try {
            $cancelKeyPressEvent = [System.Console].GetEvent(
                'CancelKeyPress',
                [System.Reflection.BindingFlags]::Public -bor [System.Reflection.BindingFlags]::Static
            )
            if ($cancelKeyPressEvent) {
                $cancelKeyPressEvent.AddEventHandler($null, $Handler)
                return $true
            }
        }
        catch {
            Write-Verbose 'The console host does not support cancellation interception; continuing without a cancel handler.'
        }
    }

    return $false
}

function Remove-SetupConsoleCancelHandler {
    # Mirrors registration's accessor/reflection fallback; cleanup failure is verbose only.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.ConsoleCancelEventHandler]$Handler
    )

    try {
        [System.Console]::remove_CancelKeyPress($Handler)
        return
    }
    catch {
        try {
            $cancelKeyPressEvent = [System.Console].GetEvent(
                'CancelKeyPress',
                [System.Reflection.BindingFlags]::Public -bor [System.Reflection.BindingFlags]::Static
            )
            if ($cancelKeyPressEvent) {
                $cancelKeyPressEvent.RemoveEventHandler($null, $Handler)
            }
        }
        catch {
            Write-Verbose 'Could not remove the console cancel handler; continuing cleanup.'
        }
    }
}

function Show-SelectionPromptWithInterruptHandling {
    <#
    .SYNOPSIS
        Runs an async Spectre selection prompt synchronously with Escape and Ctrl+C handling.
    .DESCRIPTION
        Returns the prompt's selected value. Uses the compiled console-event bridge
        when supported, otherwise a local token source. Cancellation is normalized
        to OperationCanceledException; other failures propagate. The source and any
        attached handler are released in finally, including on prompt failure.
        Escape requests back-navigation, or cancels when no parent menu or step exists.
    .PARAMETER ReturnNullAtNavigationMenuOnEscape
        Returns null for Escape on the root wizard menu so the wizard can cancel cleanly.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Prompt,
        [Parameter()][switch]$ReturnNullAtNavigationMenuOnEscape
    )

    Initialize-SpectreConsole

    $cancellationSupportType = Initialize-SetupConsoleCancellationSupport
    $cancellationTokenSource = $null
    $handlerAttached = $false
    try {
        $startMethod = $cancellationSupportType.GetMethod(
            'Start',
            [System.Reflection.BindingFlags]::Public -bor [System.Reflection.BindingFlags]::Static
        )
        $cancellationTokenSource = $startMethod.Invoke($null, [object[]]@())
        $handlerAttached = $null -ne $cancellationTokenSource

        if ($null -eq $cancellationTokenSource) {
            $cancellationTokenSource = [System.Threading.CancellationTokenSource]::new()
        }

        return Invoke-SetupPromptWithEscapeNavigation `
            -ReturnNullAtNavigationMenuOnEscape:$ReturnNullAtNavigationMenuOnEscape `
            -ArgumentList @($Prompt, $cancellationTokenSource.Token) `
            -ScriptBlock {
                param($selectionPrompt, $promptToken)
                $selectionPrompt.ShowAsync([Spectre.Console.AnsiConsole]::Console, $promptToken).GetAwaiter().GetResult()
            }
    }
    catch {
        if (($cancellationTokenSource -and $cancellationTokenSource.IsCancellationRequested) -or (Test-IsUserInterruptException -Exception $_.Exception)) {
            throw ([System.OperationCanceledException]::new('Setup cancelled by user.'))
        }

        throw
    }
    finally {
        if ($handlerAttached) {
            try {
                $stopMethod = $cancellationSupportType.GetMethod(
                    'Stop',
                    [System.Reflection.BindingFlags]::Public -bor [System.Reflection.BindingFlags]::Static
                )
                [void]$stopMethod.Invoke($null, [object[]]@($cancellationTokenSource))
            }
            catch {
                Write-Verbose 'Could not stop the console cancellation handler; continuing cleanup.'
            }
        }
        elseif ($null -ne $cancellationTokenSource) {
            $cancellationTokenSource.Dispose()
        }
    }
}

function Get-SetupDispatchProxy {
    <#
    .SYNOPSIS
        Creates a DispatchProxy for an interface at runtime.
    .DESCRIPTION
        Uses the generic factory available across supported PowerShell runtimes.
        Factory or proxy construction failures propagate.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Type]$InterfaceType,
        [Parameter(Mandatory)][System.Type]$ProxyType
    )

    $createMethod = [System.Reflection.DispatchProxy].GetMethods(
        [System.Reflection.BindingFlags]::Public -bor [System.Reflection.BindingFlags]::Static
    ) | Where-Object {
        $_.Name -eq 'Create' -and $_.IsGenericMethodDefinition -and $_.GetGenericArguments().Count -eq 2
    } | Select-Object -First 1

    if ($null -eq $createMethod) {
        throw 'The current PowerShell runtime does not support creating the setup console proxy.'
    }

    $closedCreateMethod = $createMethod.MakeGenericMethod([System.Type[]]@($InterfaceType, $ProxyType))
    return $closedCreateMethod.Invoke($null, [object[]]@())
}

function Get-SetupEscapeAwareConsole {
    <#
    .SYNOPSIS
        Wraps Spectre input to route Escape and F1 without abandoning the prompt.
    .DESCRIPTION
        Replaces only the console Input property; all other calls delegate to the
        supplied console instance. F1 uses the active prompt help URL and resumes
        reading after the browser is launched.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Console
    )

    $proxyType = Initialize-SetupConsoleEscapeNavigationSupport
    $spectreAssembly = [Spectre.Console.AnsiConsole].Assembly
    $consoleInterfaceType = $spectreAssembly.GetType('Spectre.Console.IAnsiConsole', $true)
    $inputInterfaceType = $spectreAssembly.GetType('Spectre.Console.IAnsiConsoleInput', $true)

    $inputProxy = Get-SetupDispatchProxy -InterfaceType $inputInterfaceType -ProxyType $proxyType
    $inputProxy.Inner = $Console.Input
    $inputProxy.HelpUrl = Get-SetupActivePromptHelpUrl
    $helpLauncher = Get-Variable -Name 'SetupHelpLauncher' -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($helpLauncher -is [System.Action[string]]) {
        $inputProxy.HelpLauncher = $helpLauncher
    }

    $consoleProxy = Get-SetupDispatchProxy -InterfaceType $consoleInterfaceType -ProxyType $proxyType
    $consoleProxy.Inner = $Console
    $consoleProxy.ReplacementInput = $inputProxy

    return $consoleProxy
}

function Invoke-SetupPromptWithEscapeNavigation {
    <#
    .SYNOPSIS
        Runs one Spectre prompt with Escape navigation and F1 documentation help.
    .DESCRIPTION
        Temporarily decorates the process-wide Spectre console so both direct and
        static prompts observe Escape and F1. F1 opens the active help URL and resumes
        the prompt; the original console is always restored. In a step, Escape requests
        back-navigation; without a parent menu it cancels.
    .PARAMETER ReturnNullAtNavigationMenuOnEscape
        Returns null instead of cancelling when Escape is pressed on the root menu.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [Parameter()][object[]]$ArgumentList = @(),
        [Parameter()][switch]$ReturnNullAtNavigationMenuOnEscape
    )

    $originalConsole = [Spectre.Console.AnsiConsole]::Console
    if ($null -eq $originalConsole) {
        throw 'The Spectre console is not initialized.'
    }

    $escapeAwareConsole = Get-SetupEscapeAwareConsole -Console $originalConsole
    try {
        [Spectre.Console.AnsiConsole]::Console = $escapeAwareConsole
        return & $ScriptBlock @ArgumentList
    }
    catch {
        if (Test-IsSetupWizardBackException -Exception $_.Exception) {
            $wizardContext = Get-SetupWizardContext
            if ($wizardContext -and -not $wizardContext.IsNavigationMenu) {
                Request-SetupWizardBack
            }

            if ($ReturnNullAtNavigationMenuOnEscape -and $wizardContext -and $wizardContext.IsNavigationMenu) {
                return $null
            }

            throw ([System.OperationCanceledException]::new('Setup cancelled by user.'))
        }

        throw
    }
    finally {
        [Spectre.Console.AnsiConsole]::Console = $originalConsole
    }
}

function Write-SetupPromptFrame {
    # Every new prompt gets a setup banner; use its title when no section is active.
    # Preserved prompts keep the current view instead of accumulating guidance.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PromptText,
        [Parameter(Mandatory)][ValidateSet('Menu', 'Text', 'YesNo', 'Secret')][string]$PromptKind,
        [Parameter()][string[]]$PromptGuidanceLines,
        [Parameter()][string]$PromptGuidanceDocRelativePath,
        [Parameter()][string]$PromptGuidanceRef,
        [Parameter()][switch]$ShowProductBrand,
        [Parameter()][switch]$PreserveExistingContent,
        [Parameter()][switch]$SkipPromptGuidance
    )

    Initialize-SpectreConsole

    $currentSectionMessage = Get-SetupCurrentSectionMessage
    if (-not $PreserveExistingContent) {
        $dashboardMessage = if ([string]::IsNullOrWhiteSpace($currentSectionMessage)) {
            $PromptText
        }
        else {
            $currentSectionMessage
        }
        $script:SetupGuidancePanelVisible = $false
        [Spectre.Console.AnsiConsole]::Clear()
        Write-SetupDashboard -Message $dashboardMessage -ShowProductBrand:$ShowProductBrand
        [Spectre.Console.AnsiConsole]::MarkupLine('')
    }

    $guidancePanelVisible = [bool](Get-Variable -Name 'SetupGuidancePanelVisible' -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
    if (-not ($PreserveExistingContent -and $guidancePanelVisible)) {
        $helpUrl = Get-SetupPromptHelpUrl -DocRelativePath $PromptGuidanceDocRelativePath -Ref $PromptGuidanceRef
        if ([string]::IsNullOrWhiteSpace($helpUrl)) {
            Remove-Variable -Name 'SetupActivePromptHelpUrl' -Scope Script -ErrorAction SilentlyContinue
        }
        else {
            $script:SetupActivePromptHelpUrl = $helpUrl
        }
    }
    if (-not ($PreserveExistingContent -and $guidancePanelVisible)) {
        $effectiveGuidanceLines = if ($SkipPromptGuidance) {
            @()
        }
        else {
            @($PromptGuidanceLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }

        if (@($effectiveGuidanceLines).Count -eq 0) {
            $effectiveGuidanceLines = switch ($PromptKind) {
                'Menu' {
                    @(
                        'Use the arrow keys to select an option, then press Enter.',
                        'Esc returns to the previous menu or cancels at the first menu.'
                    )
                }
                'Text' {
                    @('Enter the requested value. Press Enter to accept the shown default, if one is available.')
                }
                'YesNo' {
                    @('Choose Yes or No. Press Enter to accept the default shown in the status bar.')
                }
                'Secret' {
                    @('Input is masked while typing and is not included in setup summaries.')
                }
            }
        }

        Show-SetupPromptGuidance `
            -PromptText $PromptText `
            -GuidanceLines $effectiveGuidanceLines `
            -DocRelativePath $PromptGuidanceDocRelativePath `
            -Ref $PromptGuidanceRef `
            -OmitTrailingSpacer
        [Spectre.Console.AnsiConsole]::WriteLine()
    }
}

function Wait-ForUserAcknowledgement {
    # The only successful result is choosing the first item; no value is emitted.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [Parameter()][string]$ContinueLabel = 'Continue'
    )

    $choice = Select-FromMenu -Title $Message -Items @($ContinueLabel, 'Cancel setup')
    if ($choice -ne 0) {
        throw 'Setup cancelled by user.'
    }
}
