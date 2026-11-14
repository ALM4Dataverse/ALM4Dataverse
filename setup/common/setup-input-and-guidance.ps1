function Read-SecretText {
    <#
    .SYNOPSIS
        Reads masked input and returns its plaintext string.
    .DESCRIPTION
        Masking is display-only, not SecureString storage. Nonblank input retains
        whitespace. Blank input retries unless AllowEmpty, which returns an empty
        string even for whitespace-only input. Prompt failures propagate after
        status-bar cleanup. Escape returns to the current setup menu or cancels when
        no previous menu or step exists. A single guidance panel is always shown;
        prompts without specific guidance receive concise input help.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter()][string[]]$PromptGuidanceLines,
        [Parameter()][string]$PromptGuidanceDocRelativePath,
        [Parameter()][string]$PromptGuidanceRef,
        [Parameter()][switch]$AllowEmpty
    )

    Initialize-SpectreConsole

    while ($true) {
        if ([string]::IsNullOrWhiteSpace($Prompt)) {
            throw 'Read-SecretText received an empty prompt label. This would create an ambiguous input prompt.'
        }

        Write-SetupPromptFrame `
            -PromptText $Prompt `
            -PromptKind 'Secret' `
            -PromptGuidanceLines $PromptGuidanceLines `
            -PromptGuidanceDocRelativePath $PromptGuidanceDocRelativePath `
            -PromptGuidanceRef $PromptGuidanceRef
        Show-SetupStatusBarAtBottom -PromptKind 'Secret'
        $textPrompt = [Spectre.Console.TextPrompt[string]]::new((Get-SetupPromptInlineText -PromptKind 'Secret' -PromptText $Prompt))
        $textPrompt.IsSecret = $true
        if ($AllowEmpty) {
            $textPrompt.AllowEmpty = $true
        }

        try {
            $value = Invoke-SetupPromptWithEscapeNavigation -ArgumentList @($textPrompt) -ScriptBlock {
                param($promptObject)
                $promptObject.Show([Spectre.Console.AnsiConsole]::Console)
            }
        }
        finally {
            Clear-SetupStatusBarAtBottom
        }

        if ([string]::IsNullOrWhiteSpace($value)) {
            if ($AllowEmpty) {
                return ''
            }

            [Spectre.Console.AnsiConsole]::MarkupLine('[red]A value is required. Please try again.[/]')
            continue
        }

        return $value
    }
}

function Write-Section {
    # Starts a new display section, discarding stale prompt-document context and
    # storing the section's documentation page for the next prompt's F1 help.
    param(
        [Parameter(Mandatory)][string]$Message,
        [Parameter()][string[]]$GuidanceLines,
        [Parameter()][string]$GuidanceDocRelativePath,
        [Parameter()][string]$GuidanceRef
    )

    Initialize-SpectreConsole
    $script:SetupCurrentSectionMessage = $Message
    Clear-SetupPromptDocContext
    $script:SetupGuidancePanelVisible = $false
    [Spectre.Console.AnsiConsole]::Clear()
    Write-SetupDashboard -Message $Message

    if (
        ($GuidanceLines -and @($GuidanceLines).Count -gt 0) -or
        -not [string]::IsNullOrWhiteSpace($GuidanceDocRelativePath)
    ) {
        Write-SetupGuidance `
            -Lines @($GuidanceLines) `
            -DocRelativePath $GuidanceDocRelativePath `
            -Ref $GuidanceRef `
            -Header "$Message guidance"
    }
}

function Select-FromMenu {
    <#
    .SYNOPSIS
        Interactive console menu selection using Spectre.Console.

    .DESCRIPTION
        Arrow keys move, Enter selects, and search is enabled automatically for long lists.
        Returns a zero-based index into Items, or null for no items, the injected
        cancel choice, or an unrecognized prompt result. Back choices throw the
        wizard navigation marker rather than returning an index. Escape returns to the
        previous setup menu or step, or cancels when there is no parent. Literal labels
        are escaped for display; duplicate labels resolve to their first match. A
        single guidance panel is always visible; nested menus preserve an existing panel.
        Console input mode restoration is attempted after selection, including prompt failure.
    .PARAMETER ShowProductBrand
        Displays the green Unicode-art product mark beside the ALM4Dataverse name and
        version below the setup header. The name and version are on separate lines
        with a blank line between. Source-checkout runs display Development when no
        release version is injected.
    .PARAMETER PreserveExistingContent
        Prevents the usual section redraw before showing this prompt.
    .PARAMETER SkipPromptGuidance
        Skips prompt-specific guidance when a section panel is already visible. If no
        panel is present, concise default menu guidance is still shown.
    .PARAMETER ActionItems
        Places matching choices in a separate, bold cyan action group. The choices
        remain selectable and results still map to their original Items indexes.
    .PARAMETER ActionSectionTitle
        Heading for the optional action group.
    .PARAMETER ActionSectionFirst
        Renders the action group before the normal choices.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Items,
        [Parameter()][string[]]$PromptGuidanceLines,
        [Parameter()][string]$PromptGuidanceDocRelativePath,
        [Parameter()][string]$PromptGuidanceRef,
        [Parameter()][switch]$ShowProductBrand,
        [Parameter()][switch]$PreserveExistingContent,
        [Parameter()][switch]$SkipPromptGuidance,
        [Parameter()][string[]]$ActionItems = @(),
        [Parameter()][string]$ActionSectionTitle = 'Actions',
        [Parameter()][switch]$ActionSectionFirst
    )

    if ($Items.Count -eq 0) { return $null }

    Initialize-SpectreConsole

    $originalTreatControlCAsInput = $null
    $canRestoreTreatControlCAsInput = $false
    try {
        $originalTreatControlCAsInput = [Console]::TreatControlCAsInput
        [Console]::TreatControlCAsInput = $false
        $canRestoreTreatControlCAsInput = $true
    }
    catch {
        $canRestoreTreatControlCAsInput = $false
    }

    Write-SetupPromptFrame `
        -PromptText $Title `
        -PromptKind 'Menu' `
        -PromptGuidanceLines $PromptGuidanceLines `
        -PromptGuidanceDocRelativePath $PromptGuidanceDocRelativePath `
        -PromptGuidanceRef $PromptGuidanceRef `
        -ShowProductBrand:$ShowProductBrand `
        -PreserveExistingContent:$PreserveExistingContent `
        -SkipPromptGuidance:$SkipPromptGuidance

    $effectiveItems = @($Items)
    $wizardContext = Get-SetupWizardContext
    $hasGenericBack = $false
    $singleChoiceCancelLabel = $null
    if (
        $wizardContext -and
        -not $wizardContext.IsNavigationMenu -and
        $wizardContext.CurrentStepIndex -gt 0 -and
        -not ($effectiveItems -contains 'Back') -and
        -not ($effectiveItems -contains '< Back to previous step')
    ) {
        $effectiveItems += '< Back to previous step'
        $hasGenericBack = $true
    }

    # Some hosts render a one-item SelectionPrompt incorrectly (duplicate highlighted rows).
    # Keep the standard menu interaction by injecting an explicit cancel option when only one item exists.
    if ($effectiveItems.Count -eq 1 -and $Items.Count -eq 1 -and -not $hasGenericBack) {
        $singleChoiceCancelLabel = '< Cancel setup'
        $effectiveItems += $singleChoiceCancelLabel
        Write-SetupDebug -Message "Single-item menu workaround active for title='$Title'; added '$singleChoiceCancelLabel'."
    }

    Write-SetupDebug -Message "Select-FromMenu title='$Title' items=$($Items.Count) effectiveItems=$($effectiveItems.Count) hasGenericBack=$hasGenericBack"
    if (Test-SetupDebugEnabled) {
        for ($debugIndex = 0; $debugIndex -lt $effectiveItems.Count; $debugIndex++) {
            Write-SetupDebug -Message "  [$debugIndex] $($effectiveItems[$debugIndex])"
        }
    }

    $prompt = [Spectre.Console.SelectionPrompt[string]]::new()
    $prompt.MoreChoicesText = ''
    $prompt.WrapAround = ($effectiveItems.Count -gt 1)
    $hasActionSection = @($effectiveItems | Where-Object { $ActionItems -contains $_ }).Count -gt 0
    $hasSetupSection = $hasActionSection -and @($effectiveItems | Where-Object { $ActionItems -notcontains $_ }).Count -gt 0
    $sectionCount = if ($hasActionSection) {
        1 + [int]$hasSetupSection
    }
    else {
        0
    }
    $displayItemCount = $effectiveItems.Count + $sectionCount

    $availableMenuRows = 10
    try {
        $windowTop = [Console]::WindowTop
        $windowHeight = [Console]::WindowHeight
        $cursorTop = [Console]::CursorTop
        $visibleWindowBottom = $windowTop + [Math]::Max($windowHeight, 1)
        $reservedRows = 4
        $availableMenuRows = [Math]::Max($visibleWindowBottom - $cursorTop - $reservedRows, 1)
    }
    catch {
        $availableMenuRows = 10
    }

    $prompt.PageSize = [Math]::Min([Math]::Max($displayItemCount, 1), $availableMenuRows)

    if ($effectiveItems.Count -gt 8) {
        $prompt.SearchEnabled = $true
        $prompt.SearchPlaceholderText = '[grey]Start typing to filter options[/]'
    }

    $effectiveDisplayItems = @()
    $setupDisplayItems = @()
    $actionDisplayItems = @()
    foreach ($item in $effectiveItems) {
        $displayItem = [string](ConvertTo-SpectreMarkupLiteral -Text $item)
        if ($hasActionSection -and $ActionItems -contains $item) {
            $displayItem = "[bold deepskyblue1]$displayItem[/]"
            $actionDisplayItems += $displayItem
        }
        else {
            $setupDisplayItems += $displayItem
        }
        $effectiveDisplayItems += $displayItem
    }

    if ($hasActionSection) {
        $actionGroupTitle = "[bold deepskyblue1]$(ConvertTo-SpectreMarkupLiteral -Text $ActionSectionTitle)[/]"
        $setupGroupTitle = '[bold]Setup steps[/]'
        if ($ActionSectionFirst) {
            $actionGroup = $prompt.AddChoice($actionGroupTitle)
            foreach ($displayItem in $actionDisplayItems) {
                [void]$actionGroup.AddChild($displayItem)
            }
            if ($hasSetupSection) {
                $setupGroup = $prompt.AddChoice($setupGroupTitle)
                foreach ($displayItem in $setupDisplayItems) {
                    [void]$setupGroup.AddChild($displayItem)
                }
            }
        }
        else {
            if ($hasSetupSection) {
                $setupGroup = $prompt.AddChoice($setupGroupTitle)
                foreach ($displayItem in $setupDisplayItems) {
                    [void]$setupGroup.AddChild($displayItem)
                }
            }
            $actionGroup = $prompt.AddChoice($actionGroupTitle)
            foreach ($displayItem in $actionDisplayItems) {
                [void]$actionGroup.AddChild($displayItem)
            }
        }
    }
    else {
        foreach ($displayItem in $effectiveDisplayItems) {
            [void]$prompt.AddChoice($displayItem)
        }
    }

    Show-SetupStatusBarAtBottom -PromptKind 'Menu' -SearchEnabled:$prompt.SearchEnabled

    try {
        $selectedDisplayValue = Show-SelectionPromptWithInterruptHandling `
            -Prompt $prompt `
            -ReturnNullAtNavigationMenuOnEscape
        Write-SetupDebug -Message "SelectionPrompt selected display value: '$selectedDisplayValue'"

        $selectedEffectiveIndex = -1
        for ($effectiveIndex = 0; $effectiveIndex -lt $effectiveDisplayItems.Count; $effectiveIndex++) {
            if ($effectiveDisplayItems[$effectiveIndex] -ceq $selectedDisplayValue) {
                $selectedEffectiveIndex = $effectiveIndex
                break
            }
        }

        if ($selectedEffectiveIndex -lt 0) {
            Write-SetupDebug -Message "SelectionPrompt display value '$selectedDisplayValue' did not map to a known item."
            return $null
        }

        $selectedValue = [string]$effectiveItems[$selectedEffectiveIndex]
        Write-SetupDebug -Message "SelectionPrompt selected value: '$selectedValue'"

        if ($singleChoiceCancelLabel -and $selectedValue -ceq $singleChoiceCancelLabel) {
            Write-SetupDebug -Message "Single-item menu cancel option selected; returning null."
            return $null
        }

        $isBackSelection = ($selectedValue -eq 'Back' -or $selectedValue -like '< Back*')
        if ($isBackSelection -and ($effectiveItems -contains '< Back to previous step' -or $effectiveItems -contains 'Back')) {
            Request-SetupWizardBack
        }

        if ($null -eq $selectedValue) {
            return $null
        }

        for ($itemIndex = 0; $itemIndex -lt $Items.Count; $itemIndex++) {
            if ($Items[$itemIndex] -ceq $selectedValue) {
                Write-SetupDebug -Message "Returning menu index $itemIndex for value '$selectedValue'"
                return $itemIndex
            }
        }

        $fallbackIndex = [Array]::IndexOf($Items, $selectedValue)
        Write-SetupDebug -Message "Fallback menu index resolution returned $fallbackIndex for value '$selectedValue'"
        return $fallbackIndex
    }
    finally {
        Clear-SetupStatusBarAtBottom

        if ($canRestoreTreatControlCAsInput) {
            try {
                [Console]::TreatControlCAsInput = $originalTreatControlCAsInput
            }
            catch {
                Write-Verbose 'Could not restore console input settings; continuing cleanup.'
            }
        }
    }
}

function Read-YesNo {
    # Returns a boolean with Yes as the default unless DefaultNo; Escape navigates
    # back and the status bar is cleared on prompt failure.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter()][string[]]$PromptGuidanceLines,
        [Parameter()][string]$PromptGuidanceDocRelativePath,
        [Parameter()][string]$PromptGuidanceRef,
        [Parameter()][switch]$DefaultNo
    )

    Initialize-SpectreConsole
    if ([string]::IsNullOrWhiteSpace($Prompt)) {
        throw 'Read-YesNo received an empty prompt label. This would create an ambiguous input prompt.'
    }

    Write-SetupPromptFrame `
        -PromptText $Prompt `
        -PromptKind 'YesNo' `
        -PromptGuidanceLines $PromptGuidanceLines `
        -PromptGuidanceDocRelativePath $PromptGuidanceDocRelativePath `
        -PromptGuidanceRef $PromptGuidanceRef
    Show-SetupStatusBarAtBottom -PromptKind 'YesNo'
    try {
        $promptText = Get-SetupPromptInlineText -PromptKind 'YesNo' -PromptText $Prompt
        $defaultValue = -not $DefaultNo
        return Invoke-SetupPromptWithEscapeNavigation -ArgumentList @($promptText, $defaultValue) -ScriptBlock {
            param($confirmPromptText, $confirmDefaultValue)
            [Spectre.Console.AnsiConsole]::Confirm($confirmPromptText, $confirmDefaultValue)
        }
    }
    finally {
        Clear-SetupStatusBarAtBottom
    }
}

function ConvertFrom-GitRefToBranchName {
    # Only local-head refs are shortened; tags, remote refs and plain names pass through.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Ref
    )

    if ($Ref -match '^refs/heads/(.+)$') {
        return $Matches[1]
    }
    return $Ref
}

function ConvertTo-UrlSafeName {
    <#
    .SYNOPSIS
        Converts a name to a URL-safe format for use in federated identity credential names.

    .DESCRIPTION
        Replaces characters that are not safe in URL segments with hyphens.
        Allowed characters are: A-Z, a-z, 0-9, and hyphens.
        Collapses repeated hyphens and trims edge hyphens. The result may be empty
        and is not guaranteed unique; this helper does not validate provider limits.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name
    )

    $safeName = $Name -replace '[^a-zA-Z0-9-]', '-'
    $safeName = $safeName -replace '-+', '-'
    $safeName = $safeName.Trim('-')

    return $safeName
}

function ConvertTo-NormalizedEnvironmentUrl {
    <#
    .SYNOPSIS
        Produces an authority-only HTTP(S) environment URL for identity comparisons.
    .DESCRIPTION
        Blank input returns null. Absolute HTTP(S) URLs lose path, query and fragment.
        Invalid URLs or other schemes are only trimmed, including trailing slashes;
        this normalization is deliberately not URL validation.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][string]$Url
    )

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return $null
    }

    $trimmedUrl = $Url.Trim()
    $uri = $null
    if (-not [System.Uri]::TryCreate($trimmedUrl, [System.UriKind]::Absolute, [ref]$uri)) {
        return $trimmedUrl.TrimEnd('/')
    }

    if ($uri.Scheme -notin @('http', 'https')) {
        return $trimmedUrl.TrimEnd('/')
    }

    return $uri.GetLeftPart([System.UriPartial]::Authority)
}

function Test-IsValidTenantIdentifier {
    <#
    .SYNOPSIS
        Validates an Entra tenant identifier.

    .DESCRIPTION
        Accepts either a tenant GUID or a tenant domain name
        (for example contoso.onmicrosoft.com).
        This is a local syntax check after trimming, not DNS resolution or tenant
        discovery. The domain pattern is permissive rather than full DNS validation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantIdentifier
    )

    $value = $TenantIdentifier.Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $false
    }

    $isGuid = $value -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
    $isDns = $value -match '^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}$'

    return ($isGuid -or $isDns)
}

function Assert-ValidTenantIdentifier {
    <#
    .SYNOPSIS
        Throws when an Entra tenant identifier is invalid.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantIdentifier,
        [Parameter()][string]$Source = 'TenantId'
    )

    if (-not (Test-IsValidTenantIdentifier -TenantIdentifier $TenantIdentifier)) {
        throw "$Source value '$TenantIdentifier' is invalid. Use a tenant GUID or tenant domain (for example, contoso.onmicrosoft.com)."
    }
}

function Get-Alm4DataverseDocumentationRef {
    # Explicit Ref wins over script ALM4DataverseRef; blank/missing state uses stable.
    # Refs are returned as supplied, without trimming, validation or URL encoding.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][string]$Ref
    )

    if (-not [string]::IsNullOrWhiteSpace($Ref)) {
        return $Ref
    }

    $resolvedRef = $null
    try {
        $resolvedRef = Get-Variable -Name 'ALM4DataverseRef' -Scope Script -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Value
    }
    catch {
        $resolvedRef = $null
    }

    if ([string]::IsNullOrWhiteSpace($resolvedRef)) {
        return 'stable'
    }

    return $resolvedRef
}

function Get-Alm4DataverseDocUrl {
    # Builds a repository tree link, not a raw-content URL. Path separators are
    # normalized but refs and paths are not URL-encoded; callers supply trusted paths.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter()][string]$Ref
    )

    $effectiveRef = Get-Alm4DataverseDocumentationRef -Ref $Ref
    $normalizedPath = $RelativePath.TrimStart('/').Replace('\', '/')
    return "https://github.com/ALM4Dataverse/ALM4Dataverse/tree/$effectiveRef/$normalizedPath"
}

function Get-SetupGuidanceHeaderMarkup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Header
    )

    Initialize-SpectreConsole

    $leftMarkup = "[bold]$(ConvertTo-SpectreMarkupLiteral -Text $Header)[/]"
    return $leftMarkup
}

function Write-SetupPanelBottomBorderOverlay {
    <#
    .SYNOPSIS
        Best-effort placement of a markup label over the last rendered panel border.
    .PARAMETER VisibleText
        Plain-text counterpart of MarkupText, used for horizontal placement.
    .PARAMETER PanelWriteStartTop
        Cursor row captured before the panel write, used to infer its bottom border.
    .DESCRIPTION
        Assumes character count approximates display width. Unsupported cursor APIs
        or rendering errors are verbose-only; cursor restoration occurs on success.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][string]$VisibleText,
        [Parameter()][string]$MarkupText,
        [Parameter(Mandatory)][int]$PanelWriteStartTop
    )

    if ([string]::IsNullOrWhiteSpace($VisibleText) -or [string]::IsNullOrWhiteSpace($MarkupText)) {
        return
    }

    try {
        $savedLeft = [Console]::CursorLeft
        $savedTop = [Console]::CursorTop
        $windowWidth = [Console]::WindowWidth

        if ($windowWidth -le 0) {
            return
        }

        $overlayRow = if ($savedLeft -eq 0 -and $savedTop -gt $PanelWriteStartTop) {
            $savedTop - 1
        }
        else {
            $savedTop
        }

        $overlayColumn = [Math]::Max($windowWidth - $VisibleText.Length - 2, 1)
        [Console]::SetCursorPosition($overlayColumn, $overlayRow)
        [Spectre.Console.AnsiConsole]::Write([Spectre.Console.Markup]::new($MarkupText))
        [Console]::SetCursorPosition($savedLeft, $savedTop)
    }
    catch {
        Write-Verbose 'The console host could not display the guidance overlay; continuing without the overlay.'
    }
}

function Write-SetupGuidance {
    <#
    .SYNOPSIS
        Displays escaped guidance with an F1 help hint when a documentation page is available.
    .DESCRIPTION
        Blank lines are omitted; a documentation page alone can produce a panel.
        Updates the script prompt-document context even when there is nothing to
        render, unless SkipContextUpdate is set. A rendered panel requires a nonblank
        trimmed header. The F1 hint placement is best-effort; other console failures
        propagate.
    .PARAMETER Ref
        Documentation revision, falling back to script ALM4DataverseRef then stable.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][string[]]$Lines,
        [Parameter()][string]$DocRelativePath,
        [Parameter()][string]$Ref,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Header,
        [Parameter()][switch]$SkipContextUpdate,
        [Parameter()][switch]$OmitTrailingSpacer
    )

    Initialize-SpectreConsole

    if (-not $SkipContextUpdate) {
        Set-SetupPromptDocContext -DocRelativePath $DocRelativePath -Ref $Ref
    }

    $contentLines = @()
    foreach ($line in @($Lines)) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            $contentLines += "- $(ConvertTo-SpectreMarkupLiteral -Text $line)"
        }
    }

    $docUrl = Get-SetupPromptHelpUrl -DocRelativePath $DocRelativePath -Ref $Ref
    if ([string]::IsNullOrWhiteSpace($docUrl)) {
        Remove-Variable -Name 'SetupActivePromptHelpUrl' -Scope Script -ErrorAction SilentlyContinue
    }
    else {
        $script:SetupActivePromptHelpUrl = $docUrl
    }

    if ($contentLines.Count -eq 0 -and [string]::IsNullOrWhiteSpace($docUrl)) {
        return
    }

    $effectiveHeader = $Header.Trim()

    if ([string]::IsNullOrWhiteSpace($effectiveHeader)) {
        throw 'Write-SetupGuidance requires a specific non-empty header.'
    }

    $panelContentText = if ($contentLines.Count -gt 0) { $contentLines -join [Environment]::NewLine } else { '[grey][/]' }
    $panelHeaderMarkup = Get-SetupGuidanceHeaderMarkup -Header $effectiveHeader
    $panelWriteStartTop = 0
    try {
        $panelWriteStartTop = [Console]::CursorTop
    }
    catch {
        $panelWriteStartTop = 0
    }

    [Spectre.Console.AnsiConsole]::Write((New-SpectrePanel -Content ([Spectre.Console.Markup]::new($panelContentText)) -HeaderMarkup $panelHeaderMarkup -BorderColor 'springgreen3' -Expand))
    $script:SetupGuidancePanelVisible = $true

    if (-not [string]::IsNullOrWhiteSpace($docUrl)) {
        $overlayVisibleText = ' F1 for help '
        $overlayMarkup = "[grey]$(ConvertTo-SpectreMarkupLiteral -Text $overlayVisibleText)[/]"
        Write-SetupPanelBottomBorderOverlay -VisibleText $overlayVisibleText -MarkupText $overlayMarkup -PanelWriteStartTop $panelWriteStartTop
    }

    if (-not $OmitTrailingSpacer) {
        [Spectre.Console.AnsiConsole]::WriteLine()
    }
}

function Read-TextWithDefault {
    <#
    .SYNOPSIS
        Reads trimmed text, with optional default or explicitly empty input.
    .DESCRIPTION
        Blank input returns a nonblank DefaultValue unchanged before considering
        AllowEmpty; otherwise AllowEmpty returns an empty string and required input
        retries. Nonblank typed values are trimmed. Prompt errors propagate after
        status-bar cleanup. A blank prompt label is rejected. Escape returns to the
        previous setup menu or step, or cancels when there is no parent.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter()][string]$DefaultValue,
        [Parameter()][string[]]$PromptGuidanceLines,
        [Parameter()][string]$PromptGuidanceDocRelativePath,
        [Parameter()][string]$PromptGuidanceRef,
        [Parameter()][switch]$AllowEmpty
    )

    Initialize-SpectreConsole

    while ($true) {
        if ([string]::IsNullOrWhiteSpace($Prompt)) {
            throw 'Read-TextWithDefault received an empty prompt label. This would create an ambiguous input prompt.'
        }

        $value = $null
        Write-SetupPromptFrame `
            -PromptText $Prompt `
            -PromptKind 'Text' `
            -PromptGuidanceLines $PromptGuidanceLines `
            -PromptGuidanceDocRelativePath $PromptGuidanceDocRelativePath `
            -PromptGuidanceRef $PromptGuidanceRef
        if (-not [string]::IsNullOrWhiteSpace($DefaultValue)) {
            Show-SetupStatusBarAtBottom -PromptKind 'Text'
            try {
                $promptText = Get-SetupPromptInlineText -PromptKind 'Text' -PromptText $Prompt
                $defaultValue = $DefaultValue
                $value = Invoke-SetupPromptWithEscapeNavigation -ArgumentList @($promptText, $defaultValue) -ScriptBlock {
                    param($textPrompt, $textDefaultValue)
                    Invoke-GenericStaticMethod `
                        -Type ([Spectre.Console.AnsiConsole]) `
                        -MethodName 'Ask' `
                        -GenericTypeArguments ([Type[]]@([string])) `
                        -Arguments @($textPrompt, $textDefaultValue)
                }
            }
            finally {
                Clear-SetupStatusBarAtBottom
            }
        }
        else {
            Show-SetupStatusBarAtBottom -PromptKind 'Text'
            $textPrompt = [Spectre.Console.TextPrompt[string]]::new((Get-SetupPromptInlineText -PromptKind 'Text' -PromptText $Prompt))
            if ($AllowEmpty) {
                $textPrompt.AllowEmpty = $true
            }

            try {
                $value = Invoke-SetupPromptWithEscapeNavigation -ArgumentList @($textPrompt) -ScriptBlock {
                    param($promptObject)
                    $promptObject.Show([Spectre.Console.AnsiConsole]::Console)
                }
            }
            finally {
                Clear-SetupStatusBarAtBottom
            }
        }

        if ([string]::IsNullOrWhiteSpace($value)) {
            if (-not [string]::IsNullOrWhiteSpace($DefaultValue)) {
                return $DefaultValue
            }
            if ($AllowEmpty) {
                return ''
            }

            [Spectre.Console.AnsiConsole]::MarkupLine('[red]A value is required. Please try again.[/]')
            continue
        }

        return $value.Trim()
    }
}
