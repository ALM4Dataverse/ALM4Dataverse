function New-DirectoryIfMissing {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Initialize-SpectreConsole {
    [CmdletBinding()]
    param()

    if (Get-Variable -Name 'SpectreConsoleInitialized' -Scope Script -ErrorAction SilentlyContinue) {
        return
    }

    try {
        [void][Spectre.Console.AnsiConsole]
        $script:SpectreConsoleInitialized = $true
        return
    }
    catch {
        # Continue and load the assembly from the NuGet package.
    }

    $spectreVersion = '0.53.1'
    $packageRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'ALM4Dataverse\SpectreConsole'
    $expandedRoot = Join-Path $packageRoot $spectreVersion
    $packagePath = Join-Path $packageRoot "Spectre.Console.$spectreVersion.nupkg"

    New-DirectoryIfMissing -Path $packageRoot

    if (-not (Test-Path -LiteralPath $expandedRoot)) {
        if (-not (Test-Path -LiteralPath $packagePath)) {
            try {
                if ($PSVersionTable.PSVersion.Major -lt 6) {
                    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                }
            }
            catch {
                # Non-fatal; continue.
            }

            $packageUrl = "https://www.nuget.org/api/v2/package/Spectre.Console/$spectreVersion"
            Invoke-WebRequest -Uri $packageUrl -OutFile $packagePath -UseBasicParsing
        }

        Expand-Archive -LiteralPath $packagePath -DestinationPath $expandedRoot -Force
    }

    $candidateFrameworks = if ($PSVersionTable.PSEdition -eq 'Core') {
        @('net8.0', 'netstandard2.0')
    }
    else {
        @('netstandard2.0')
    }

    $spectreAssemblyPath = $null
    foreach ($candidateFramework in $candidateFrameworks) {
        $candidatePath = Join-Path $expandedRoot "lib\$candidateFramework\Spectre.Console.dll"
        if (Test-Path -LiteralPath $candidatePath) {
            $spectreAssemblyPath = $candidatePath
            break
        }
    }

    if (-not $spectreAssemblyPath) {
        $spectreAssemblyPath = Get-ChildItem -Path $expandedRoot -Recurse -Filter 'Spectre.Console.dll' -File |
            Select-Object -ExpandProperty FullName -First 1
    }

    if (-not $spectreAssemblyPath) {
        throw "Could not locate Spectre.Console.dll after extracting package version $spectreVersion."
    }

    Add-Type -Path $spectreAssemblyPath -ErrorAction Stop
    $script:SpectreConsoleInitialized = $true
    $script:SpectreConsoleAssemblyPath = $spectreAssemblyPath
}

function ConvertTo-SpectreMarkupLiteral {
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][string]$Text
    )

    if ($null -eq $Text) {
        return ''
    }

    return ([string]$Text).Replace('[', '[[').Replace(']', ']]')
}

function Invoke-GenericStaticMethod {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Type]$Type,
        [Parameter(Mandatory)][string]$MethodName,
        [Parameter(Mandatory)][Type[]]$GenericTypeArguments,
        [Parameter()][object[]]$Arguments = @()
    )

    $bindingFlags = [System.Reflection.BindingFlags]::Public -bor [System.Reflection.BindingFlags]::Static
    $candidateMethods = @(
        $Type.GetMethods($bindingFlags) | Where-Object {
            $_.Name -eq $MethodName -and
            $_.IsGenericMethodDefinition -and
            $_.GetGenericArguments().Count -eq $GenericTypeArguments.Count -and
            $_.GetParameters().Count -eq $Arguments.Count
        }
    )

    if ($candidateMethods.Count -eq 0) {
        throw "Could not find generic static method '$MethodName' on type '$($Type.FullName)' that accepts $($Arguments.Count) argument(s)."
    }

    $firstInvocationError = $null
    foreach ($method in $candidateMethods) {
        try {
            $closedMethod = $method.MakeGenericMethod($GenericTypeArguments)
            return $closedMethod.Invoke($null, $Arguments)
        }
        catch {
            if (-not $firstInvocationError) {
                $firstInvocationError = $_.Exception
            }
        }
    }

    if ($firstInvocationError) {
        throw $firstInvocationError
    }

    throw "Unable to invoke generic static method '$MethodName' on type '$($Type.FullName)'."
}

function Test-SetupDebugEnabled {
    [CmdletBinding()]
    param()

    $debugValue = $env:ALM4DATAVERSE_DEBUG
    if ([string]::IsNullOrWhiteSpace($debugValue)) {
        return $false
    }

    return @('1', 'true', 'yes', 'on') -contains $debugValue.Trim().ToLowerInvariant()
}

function Write-SetupDebug {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message
    )

    if (-not (Test-SetupDebugEnabled)) {
        return
    }

    Write-Host "[DEBUG] $Message" -ForegroundColor DarkGray
}

function New-SpectreTable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Columns
    )

    Initialize-SpectreConsole

    $table = [Spectre.Console.Table]::new()
    foreach ($column in $Columns) {
        [void]$table.AddColumn([Spectre.Console.TableColumn]::new("[grey]$(ConvertTo-SpectreMarkupLiteral -Text $column)[/]"))
    }

    return $table
}

function Add-SpectreTableRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Table,
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Cells
    )

    Initialize-SpectreConsole

    $renderables = [Spectre.Console.Rendering.IRenderable[]]@(
        foreach ($cell in $Cells) {
            $cellText = if ($null -eq $cell) { '' } else { [string]$cell }
            [Spectre.Console.Markup]::new((ConvertTo-SpectreMarkupLiteral -Text $cellText))
        }
    )

    [void]$Table.Rows.Add($renderables)
}

function New-SpectrePanel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Content,
        [Parameter()][string]$Header,
        [Parameter()][string]$HeaderMarkup,
        [Parameter()][string]$BorderColor = 'grey35',
        [Parameter()][switch]$Expand,
        [Parameter()][int]$PaddingX = 1,
        [Parameter()][int]$PaddingY = 0
    )

    Initialize-SpectreConsole

    $panel = [Spectre.Console.Panel]::new($Content)
    $panel.Border = [Spectre.Console.BoxBorder]::Rounded
    $panel.BorderStyle = [Spectre.Console.Style]::Parse($BorderColor)
    $panel.Padding = [Spectre.Console.Padding]::new($PaddingX, $PaddingY, $PaddingX, $PaddingY)
    $panel.Expand = $Expand.IsPresent

    if (-not [string]::IsNullOrWhiteSpace($HeaderMarkup)) {
        $panel.Header = [Spectre.Console.PanelHeader]::new($HeaderMarkup)
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Header)) {
        $panel.Header = [Spectre.Console.PanelHeader]::new("[bold]$(ConvertTo-SpectreMarkupLiteral -Text $Header)[/]")
    }

    return $panel
}

function New-SpectreInfoGrid {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Values,
        [Parameter()][int]$LabelWidth = 18
    )

    Initialize-SpectreConsole

    $grid = [Spectre.Console.Grid]::new()
    $grid.Expand = $true

    $labelColumn = [Spectre.Console.GridColumn]::new()
    $labelColumn.NoWrap = $true
    $labelColumn.Width = $LabelWidth
    $labelColumn.Padding = [Spectre.Console.Padding]::new(0, 0, 2, 0)

    [void]$grid.AddColumn($labelColumn)
    [void]$grid.AddColumn()

    foreach ($entry in $Values.GetEnumerator()) {
        [void]$grid.AddRow([Spectre.Console.Rendering.IRenderable[]]@(
            [Spectre.Console.Markup]::new("[grey]$(ConvertTo-SpectreMarkupLiteral -Text ([string]$entry.Key))[/]"),
            [Spectre.Console.Markup]::new("[white]$(ConvertTo-SpectreMarkupLiteral -Text ([string]$entry.Value))[/]")
        ))
    }

    return $grid
}

function New-SpectreMetricColumns {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][array]$Cards
    )

    Initialize-SpectreConsole

    $renderables = [Spectre.Console.Rendering.IRenderable[]]@(
        foreach ($card in @($Cards)) {
            if ($null -eq $card) {
                continue
            }

            $label = ''
            $value = ''
            $detail = ''
            $accentColor = 'deepskyblue1'

            if ($card -is [hashtable]) {
                $label = [string]$card.Label
                $value = [string]$card.Value
                $detail = [string]$card.Detail
                if ($card.ContainsKey('AccentColor') -and -not [string]::IsNullOrWhiteSpace($card.AccentColor)) {
                    $accentColor = [string]$card.AccentColor
                }
            }
            else {
                if ($card.PSObject.Properties.Name -contains 'Label') { $label = [string]$card.Label }
                if ($card.PSObject.Properties.Name -contains 'Value') { $value = [string]$card.Value }
                if ($card.PSObject.Properties.Name -contains 'Detail') { $detail = [string]$card.Detail }
                if ($card.PSObject.Properties.Name -contains 'AccentColor' -and -not [string]::IsNullOrWhiteSpace($card.AccentColor)) {
                    $accentColor = [string]$card.AccentColor
                }
            }

            $lines = @(
                "[bold $accentColor]$(ConvertTo-SpectreMarkupLiteral -Text $value)[/]",
                "[grey]$(ConvertTo-SpectreMarkupLiteral -Text $label)[/]"
            )
            if (-not [string]::IsNullOrWhiteSpace($detail)) {
                $lines += "[dim]$(ConvertTo-SpectreMarkupLiteral -Text $detail)[/]"
            }

            New-SpectrePanel -Content ([Spectre.Console.Markup]::new(($lines -join [Environment]::NewLine))) -BorderColor $accentColor -Expand
        }
    )

    $columns = [Spectre.Console.Columns]::new($renderables)
    $columns.Expand = $true
    $columns.Padding = [Spectre.Console.Padding]::new(1, 0, 1, 0)
    return $columns
}

function Show-SpectreMetricCards {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][array]$Cards
    )

    $filteredCards = @($Cards | Where-Object { $null -ne $_ })
    if ($filteredCards.Count -eq 0) {
        return
    }

    Initialize-SpectreConsole
    [Spectre.Console.AnsiConsole]::Write((New-SpectreMetricColumns -Cards $filteredCards))
    [Spectre.Console.AnsiConsole]::WriteLine()
}

function Show-SolutionSelectionOverview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$SelectedCount,
        [Parameter(Mandatory)][int]$AvailableCount
    )

    $remainingCount = [Math]::Max($AvailableCount - $SelectedCount, 0)
    Show-SpectreMetricCards -Cards @(
        @{ Label = 'Selected'; AccentColor = 'green3_1'; Value = [string]$SelectedCount; Detail = 'Chosen for source control' },
        @{ Label = 'Remaining'; AccentColor = $(if ($remainingCount -gt 0) { 'deepskyblue1' } else { 'grey42' }); Value = [string]$remainingCount; Detail = 'Still available to add' },
        @{ Label = 'Available total'; AccentColor = 'mediumpurple3'; Value = [string]$AvailableCount; Detail = 'Detected in the environment' }
    )
}

function Show-EnvironmentConfigurationOverview {
    [CmdletBinding()]
    param(
        [Parameter()][array]$EnvironmentConfigurations
    )

    $items = @($EnvironmentConfigurations)
    $pendingCount = 0
    $wifCount = 0
    $secretCount = 0
    $uniqueServiceAccounts = @()

    foreach ($env in $items) {
        $hasCredential = ($env.PSObject.Properties.Name -contains 'Credentials' -and $null -ne $env.Credentials)
        $hasServiceAccount = ($env.PSObject.Properties.Name -contains 'ServiceAccountUPN' -and -not [string]::IsNullOrWhiteSpace($env.ServiceAccountUPN))
        $isPending = ($env.PSObject.Properties.Name -contains 'ConfigurationPending' -and $env.ConfigurationPending) -or -not $hasCredential -or -not $hasServiceAccount
        if ($isPending) {
            $pendingCount++
        }

        if ($hasCredential -and $env.Credentials.PSObject.Properties.Name -contains 'AuthType') {
            switch ([string]$env.Credentials.AuthType) {
                'WIF' { $wifCount++ }
                'Secret' { $secretCount++ }
            }
        }

        if ($hasServiceAccount) {
            $uniqueServiceAccounts += [string]$env.ServiceAccountUPN
        }
    }

    $uniqueServiceAccounts = @($uniqueServiceAccounts | Select-Object -Unique)
    $authMix = if (($wifCount + $secretCount) -eq 0) {
        'Unassigned'
    }
    elseif ($wifCount -gt 0 -and $secretCount -gt 0) {
        'Mixed'
    }
    elseif ($wifCount -gt 0) {
        'WIF'
    }
    else {
        'Secret'
    }

    Show-SpectreMetricCards -Cards @(
        @{ Label = 'Environments'; AccentColor = 'yellow3'; Value = [string]$items.Count; Detail = 'Configured stages' },
        @{ Label = 'Pending setup'; AccentColor = $(if ($pendingCount -gt 0) { 'red3_1' } else { 'green3_1' }); Value = [string]$pendingCount; Detail = $(if ($pendingCount -gt 0) { 'Need credentials or service accounts' } else { 'Ready for apply' }) },
        @{ Label = 'Auth mode'; AccentColor = 'deepskyblue1'; Value = $authMix; Detail = "WIF: $wifCount - Secret: $secretCount" },
        @{ Label = 'Service accounts'; AccentColor = 'mediumpurple3'; Value = [string]$uniqueServiceAccounts.Count; Detail = 'Unique automation owners' }
    )
}

function Show-KeyValueSummaryTable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Values,
        [Parameter()][string]$Heading = 'Summary'
    )

    Initialize-SpectreConsole

    $table = New-SpectreTable -Columns @('Setting', 'Value')
    foreach ($entry in $Values.GetEnumerator()) {
        Add-SpectreTableRow -Table $table -Cells @([string]$entry.Key, [string]$entry.Value)
    }

    [Spectre.Console.AnsiConsole]::Write((New-SpectrePanel -Content $table -Header $Heading -BorderColor 'mediumspringgreen' -Expand))
    [Spectre.Console.AnsiConsole]::WriteLine()
}

function Set-SetupWizardContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string[]]$StepNames,
        [Parameter(Mandatory)][int]$CurrentStepIndex
    )

    $script:SetupWizardContext = [pscustomobject]@{
        Title            = $Title
        StepNames        = @($StepNames)
        CurrentStepIndex = $CurrentStepIndex
    }
}

function Set-SetupPhaseContext {
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
    [CmdletBinding()]
    param(
        [Parameter()][string]$DocRelativePath,
        [Parameter()][string]$Ref,
        [Parameter()][string]$LinkLabel = 'Click for docs'
    )

    $script:SetupPromptDocContext = [pscustomobject]@{
        DocRelativePath = $DocRelativePath
        Ref             = $Ref
        LinkLabel       = $LinkLabel
    }
}

function Clear-SetupPromptDocContext {
    [CmdletBinding()]
    param()

    Remove-Variable -Name 'SetupPromptDocContext' -Scope Script -ErrorAction SilentlyContinue
}

function Get-SetupPromptDocContext {
    [CmdletBinding()]
    param()

    return (Get-Variable -Name 'SetupPromptDocContext' -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
}

function Request-SetupWizardBack {
    [CmdletBinding()]
    param()

    throw ([System.InvalidOperationException]::new('__ALM4DATAVERSE_WIZARD_BACK__'))
}

function Test-IsSetupWizardBackException {
    [CmdletBinding()]
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
    [CmdletBinding()]
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
        '- Longer lists automatically enable search so you can type to filter.',
        '- The wizard navigation menu appears after each step so you can go back before applying changes.'
    )

    return (New-SpectrePanel -Content ([Spectre.Console.Markup]::new(('[grey]' + (($tipLines | ForEach-Object { ConvertTo-SpectreMarkupLiteral -Text $_ }) -join '[/]' + [Environment]::NewLine + '[grey]') + '[/]'))) -Header 'Controls and flow' -BorderColor 'grey42' -Expand)
}

function Write-SetupDashboard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [Parameter()][switch]$IncludeTrailingSpacer
    )

    Initialize-SpectreConsole

    if (-not (Write-SetupConsoleBar -Text (New-SetupHeroPanel -Message $Message) -ForegroundColor ([ConsoleColor]::Black) -BackgroundColor ([ConsoleColor]::Gray) -AdvanceCursor)) {
        $heroText = "[black on grey]$(ConvertTo-SpectreMarkupLiteral -Text (New-SetupHeroPanel -Message $Message))[/]"
        [Spectre.Console.AnsiConsole]::MarkupLine($heroText)
    }

    if ($IncludeTrailingSpacer) {
        [Spectre.Console.AnsiConsole]::WriteLine()
    }
}

function Test-IsUserInterruptException {
    [CmdletBinding()]
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
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][array]$Steps
    )

    if ($Steps.Count -eq 0) {
        return
    }

    $currentStepIndex = 0
    $stepNames = @($Steps | ForEach-Object { [string]$_.Name })

    try {
        while ($currentStepIndex -lt $Steps.Count) {
            try {
                Set-SetupWizardContext -Title $Title -StepNames $stepNames -CurrentStepIndex $currentStepIndex
                & $Steps[$currentStepIndex].Action
                $currentStepIndex++
            }
            catch {
                if (Test-IsSetupWizardBackException -Exception $_.Exception) {
                    if ($currentStepIndex -gt 0) {
                        $currentStepIndex--
                    }

                    continue
                }

                throw
            }
        }
    }
    finally {
        Clear-SetupWizardContext
    }
}

function Confirm-SetupReviewAction {
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


function Show-SetupPromptGuidance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Menu', 'Text', 'YesNo', 'Secret')][string]$PromptKind,
        [Parameter(Mandatory)][string]$PromptText,
        [Parameter()][string[]]$GuidanceLines,
        [Parameter()][string]$DocRelativePath,
        [Parameter()][string]$Ref,
        [Parameter()][string]$LinkLabel = 'Click for docs',
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
        -LinkLabel $LinkLabel `
        -Header $guidanceHeader `
        -SkipContextUpdate `
        -OmitTrailingSpacer:$OmitTrailingSpacer
}

function Get-SetupPromptInlineText {
    [CmdletBinding()]
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
    [CmdletBinding()]
    param(
        [Parameter()][string]$Text,
        [Parameter()][ConsoleColor]$ForegroundColor = [ConsoleColor]::Black,
        [Parameter()][ConsoleColor]$BackgroundColor = [ConsoleColor]::Gray,
        [Parameter()][int]$TargetRow = -1,
        [Parameter()][switch]$RestoreCursorPosition,
        [Parameter()][switch]$AdvanceCursor
    )

    try {
        $windowWidth = [Console]::WindowWidth
        $windowHeight = [Console]::WindowHeight
        if ($windowWidth -le 0 -or $windowHeight -le 0) {
            return $false
        }

        $resolvedRow = if ($TargetRow -lt 0) {
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
    [CmdletBinding()]
    param(
        [Parameter()][ValidateSet('Menu', 'Text', 'YesNo', 'Secret')][string]$PromptKind = 'Text',
        [Parameter()][switch]$SearchEnabled
    )

    Initialize-SpectreConsole

    $segments = switch ($PromptKind) {
        'Menu' {
            @(
                'Up/Down=move',
                'Enter=select',
                $(if ($SearchEnabled) { 'Type=filter' } else { $null }),
                'Ctrl+C=exit'
            )
        }
        'YesNo' {
            @(
                'Y/N=choose',
                'Enter=confirm',
                'Ctrl+C=exit'
            )
        }
        'Secret' {
            @(
                'Enter=confirm',
                'Ctrl+C=exit'
            )
        }
        default {
            @(
                'Enter=confirm',
                'Ctrl+C=exit'
            )
        }
    }

    $segments = @($segments | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($segments.Count -eq 0) {
        return
    }

    $statusText = ($segments -join '  -  ')

    if (-not (Write-SetupConsoleBar -Text $statusText -ForegroundColor ([ConsoleColor]::Black) -BackgroundColor ([ConsoleColor]::Gray) -TargetRow ([Math]::Max([Console]::WindowHeight - 1, 0)) -RestoreCursorPosition)) {
        $markup = '[black on grey]' + (($segments | ForEach-Object { ConvertTo-SpectreMarkupLiteral -Text $_ }) -join '  -  ') + '[/]'
        [Spectre.Console.AnsiConsole]::MarkupLine($markup)
    }
}

function Clear-SetupStatusBarAtBottom {
    [CmdletBinding()]
    param()

    [void](Write-SetupConsoleBar -Text '' -TargetRow ([Math]::Max([Console]::WindowHeight - 1, 0)) -RestoreCursorPosition)
}

function Add-SetupConsoleCancelHandler {
    [CmdletBinding()]
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
            # Some hosts do not expose a usable console cancel event. Continue without explicit Ctrl+C interception.
        }
    }

    return $false
}

function Remove-SetupConsoleCancelHandler {
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
            # Ignore cleanup failures when the host does not support console cancel events.
        }
    }
}

function Show-SelectionPromptWithInterruptHandling {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Prompt
    )

    Initialize-SpectreConsole

    $cancellationTokenSource = [System.Threading.CancellationTokenSource]::new()
    $cancellationState = [pscustomobject]@{
        Cancelled           = $false
        TokenSourceDisposed = $false
    }

    $cancelHandler = [System.ConsoleCancelEventHandler]{
        param($sender, $eventArgs)

        $eventArgs.Cancel = $true
        $cancellationState.Cancelled = $true

        if (-not $cancellationState.TokenSourceDisposed -and -not $cancellationTokenSource.IsCancellationRequested) {
            $cancellationTokenSource.Cancel()
        }
    }

    $handlerAttached = $false
    try {
        $handlerAttached = Add-SetupConsoleCancelHandler -Handler $cancelHandler

        return $Prompt.ShowAsync([Spectre.Console.AnsiConsole]::Console, $cancellationTokenSource.Token).GetAwaiter().GetResult()
    }
    catch {
        if ($cancellationState.Cancelled -or (Test-IsUserInterruptException -Exception $_.Exception)) {
            throw ([System.OperationCanceledException]::new('Setup cancelled by user.'))
        }

        throw
    }
    finally {
        if ($handlerAttached) {
            try {
                Remove-SetupConsoleCancelHandler -Handler $cancelHandler
            }
            catch {
                # Ignore cleanup failures.
            }
        }

        $cancellationState.TokenSourceDisposed = $true
        $cancellationTokenSource.Dispose()
    }
}

function Write-SetupPromptFrame {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Menu', 'Text', 'YesNo', 'Secret')][string]$PromptKind,
        [Parameter(Mandatory)][string]$PromptText,
        [Parameter()][string[]]$PromptGuidanceLines,
        [Parameter()][string]$PromptGuidanceDocRelativePath,
        [Parameter()][string]$PromptGuidanceRef,
        [Parameter()][string]$PromptGuidanceLinkLabel = 'Click for docs',
        [Parameter()][switch]$PreserveExistingContent,
        [Parameter()][switch]$SkipPromptGuidance
    )

    Initialize-SpectreConsole

    $currentSectionMessage = Get-SetupCurrentSectionMessage
    if (-not $PreserveExistingContent -and -not [string]::IsNullOrWhiteSpace($currentSectionMessage)) {
        [Spectre.Console.AnsiConsole]::Clear()
        Write-SetupDashboard -Message $currentSectionMessage
        [Spectre.Console.AnsiConsole]::WriteLine()
    }

    if (-not $SkipPromptGuidance) {
        Show-SetupPromptGuidance `
            -PromptKind $PromptKind `
            -PromptText $PromptText `
            -GuidanceLines $PromptGuidanceLines `
            -DocRelativePath $PromptGuidanceDocRelativePath `
            -Ref $PromptGuidanceRef `
            -LinkLabel $PromptGuidanceLinkLabel `
            -OmitTrailingSpacer
        [Spectre.Console.AnsiConsole]::WriteLine()
    }
}

function Wait-ForUserAcknowledgement {
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

function Read-SecretText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter()][string[]]$PromptGuidanceLines,
        [Parameter()][string]$PromptGuidanceDocRelativePath,
        [Parameter()][string]$PromptGuidanceRef,
        [Parameter()][string]$PromptGuidanceLinkLabel = 'Click for docs',
        [Parameter()][switch]$AllowEmpty
    )

    Initialize-SpectreConsole

    while ($true) {
        if ([string]::IsNullOrWhiteSpace($Prompt)) {
            throw 'Read-SecretText received an empty prompt label. This would create an ambiguous input prompt.'
        }

        Write-SetupPromptFrame -PromptKind 'Secret' -PromptText $Prompt -PromptGuidanceLines $PromptGuidanceLines -PromptGuidanceDocRelativePath $PromptGuidanceDocRelativePath -PromptGuidanceRef $PromptGuidanceRef -PromptGuidanceLinkLabel $PromptGuidanceLinkLabel
        Show-SetupStatusBarAtBottom -PromptKind 'Secret'
        $textPrompt = [Spectre.Console.TextPrompt[string]]::new((Get-SetupPromptInlineText -PromptKind 'Secret' -PromptText $Prompt))
        $textPrompt.IsSecret = $true
        if ($AllowEmpty) {
            $textPrompt.AllowEmpty = $true
        }

        try {
            $value = $textPrompt.Show([Spectre.Console.AnsiConsole]::Console)
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
    param(
        [Parameter(Mandatory)][string]$Message,
        [Parameter()][string[]]$GuidanceLines,
        [Parameter()][string]$GuidanceDocRelativePath,
        [Parameter()][string]$GuidanceRef,
        [Parameter()][string]$GuidanceLinkLabel = 'Click for docs'
    )

    Initialize-SpectreConsole
    $script:SetupCurrentSectionMessage = $Message
    Clear-SetupPromptDocContext
    [Spectre.Console.AnsiConsole]::Clear()
    Write-SetupDashboard -Message $Message

    if ($GuidanceLines -and @($GuidanceLines).Count -gt 0) {
        Write-SetupGuidance -Lines @($GuidanceLines) -DocRelativePath $GuidanceDocRelativePath -Ref $GuidanceRef -LinkLabel $GuidanceLinkLabel -Header "$Message guidance" -SkipContextUpdate
    }
}

function Select-FromMenu {
    <#
    .SYNOPSIS
        Interactive console menu selection using Spectre.Console.

    .DESCRIPTION
        Arrow keys move, Enter selects, and search is enabled automatically for long lists.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string[]]$Items,
        [Parameter()][string[]]$PromptGuidanceLines,
        [Parameter()][string]$PromptGuidanceDocRelativePath,
        [Parameter()][string]$PromptGuidanceRef,
        [Parameter()][string]$PromptGuidanceLinkLabel = 'Click for docs',
        [Parameter()][switch]$PreserveExistingContent,
        [Parameter()][switch]$SkipPromptGuidance
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

    Write-SetupPromptFrame -PromptKind 'Menu' -PromptText $Title -PromptGuidanceLines $PromptGuidanceLines -PromptGuidanceDocRelativePath $PromptGuidanceDocRelativePath -PromptGuidanceRef $PromptGuidanceRef -PromptGuidanceLinkLabel $PromptGuidanceLinkLabel -PreserveExistingContent:$PreserveExistingContent -SkipPromptGuidance:$SkipPromptGuidance

    $effectiveItems = @($Items)
    $wizardContext = Get-SetupWizardContext
    $hasGenericBack = $false
    $singleChoiceCancelLabel = $null
    if (
        $wizardContext -and
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

    $prompt.PageSize = [Math]::Min([Math]::Max($effectiveItems.Count, 1), $availableMenuRows)

    if ($effectiveItems.Count -gt 8) {
        $prompt.SearchEnabled = $true
        $prompt.SearchPlaceholderText = '[grey]Start typing to filter options[/]'
    }

    foreach ($item in $effectiveItems) {
        [void]$prompt.AddChoice($item)
    }

    Show-SetupStatusBarAtBottom -PromptKind 'Menu' -SearchEnabled:$prompt.SearchEnabled

    try {
        $selectedValue = Show-SelectionPromptWithInterruptHandling -Prompt $prompt
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
                # Ignore cleanup failures.
            }
        }
    }
}

function Read-YesNo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter()][string[]]$PromptGuidanceLines,
        [Parameter()][string]$PromptGuidanceDocRelativePath,
        [Parameter()][string]$PromptGuidanceRef,
        [Parameter()][string]$PromptGuidanceLinkLabel = 'Click for docs',
        [Parameter()][switch]$DefaultNo
    )

    Initialize-SpectreConsole
    if ([string]::IsNullOrWhiteSpace($Prompt)) {
        throw 'Read-YesNo received an empty prompt label. This would create an ambiguous input prompt.'
    }

    Write-SetupPromptFrame -PromptKind 'YesNo' -PromptText $Prompt -PromptGuidanceLines $PromptGuidanceLines -PromptGuidanceDocRelativePath $PromptGuidanceDocRelativePath -PromptGuidanceRef $PromptGuidanceRef -PromptGuidanceLinkLabel $PromptGuidanceLinkLabel
    Show-SetupStatusBarAtBottom -PromptKind 'YesNo'
    try {
        return [Spectre.Console.AnsiConsole]::Confirm((Get-SetupPromptInlineText -PromptKind 'YesNo' -PromptText $Prompt), (-not $DefaultNo))
    }
    finally {
        Clear-SetupStatusBarAtBottom
    }
}

function ConvertFrom-GitRefToBranchName {
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

function Get-Alm4DataverseRefForDocs {
    [CmdletBinding()]
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
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter()][string]$Ref
    )

    $effectiveRef = Get-Alm4DataverseRefForDocs -Ref $Ref
    $normalizedPath = $RelativePath.TrimStart('/').Replace('\', '/')
    return "https://github.com/ALM4Dataverse/ALM4Dataverse/tree/$effectiveRef/$normalizedPath"
}

function Get-SetupGuidanceHeaderMarkup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Header,
        [Parameter()][string]$DocUrl,
        [Parameter()][string]$LinkLabel = 'Click for docs'
    )

    Initialize-SpectreConsole

    $leftMarkup = "[bold]$(ConvertTo-SpectreMarkupLiteral -Text $Header)[/]"
    return $leftMarkup
}

function Write-SetupPanelBottomBorderOverlay {
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
        # Ignore overlay failures in hosts that do not expose reliable cursor positioning.
    }
}

function Write-SetupGuidance {
    [CmdletBinding()]
    param(
        [Parameter()][string[]]$Lines,
        [Parameter()][string]$DocRelativePath,
        [Parameter()][string]$Ref,
        [Parameter()][string]$LinkLabel = 'Full docs',
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Header,
        [Parameter()][switch]$SkipContextUpdate,
        [Parameter()][switch]$OmitTrailingSpacer
    )

    Initialize-SpectreConsole

    if (-not $SkipContextUpdate) {
        Set-SetupPromptDocContext -DocRelativePath $DocRelativePath -Ref $Ref -LinkLabel $LinkLabel
    }

    $contentLines = @()
    foreach ($line in @($Lines)) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            $contentLines += "- $(ConvertTo-SpectreMarkupLiteral -Text $line)"
        }
    }

    $docUrl = $null
    if (-not [string]::IsNullOrWhiteSpace($DocRelativePath)) {
        $docUrl = Get-Alm4DataverseDocUrl -RelativePath $DocRelativePath -Ref $Ref
    }

    if ($contentLines.Count -eq 0 -and [string]::IsNullOrWhiteSpace($docUrl)) {
        return
    }

    $effectiveHeader = $Header.Trim()

    if ([string]::IsNullOrWhiteSpace($effectiveHeader)) {
        throw 'Write-SetupGuidance requires a specific non-empty header.'
    }

    $panelContentText = if ($contentLines.Count -gt 0) { $contentLines -join [Environment]::NewLine } else { '[grey][/]' }
    $panelHeaderMarkup = Get-SetupGuidanceHeaderMarkup -Header $effectiveHeader -DocUrl $docUrl -LinkLabel $LinkLabel
    $panelWriteStartTop = 0
    try {
        $panelWriteStartTop = [Console]::CursorTop
    }
    catch {
        $panelWriteStartTop = 0
    }

    [Spectre.Console.AnsiConsole]::Write((New-SpectrePanel -Content ([Spectre.Console.Markup]::new($panelContentText)) -HeaderMarkup $panelHeaderMarkup -BorderColor 'springgreen3' -Expand))

    if (-not [string]::IsNullOrWhiteSpace($docUrl)) {
        $overlayLabelText = if ([string]::IsNullOrWhiteSpace($LinkLabel)) { 'Click for docs' } else { $LinkLabel }
        $overlayVisibleText = " $overlayLabelText "
        $overlayMarkup = "[grey][link=$docUrl]$(ConvertTo-SpectreMarkupLiteral -Text $overlayVisibleText)[/][/]"
        Write-SetupPanelBottomBorderOverlay -VisibleText $overlayVisibleText -MarkupText $overlayMarkup -PanelWriteStartTop $panelWriteStartTop
    }

    if (-not $OmitTrailingSpacer) {
        [Spectre.Console.AnsiConsole]::WriteLine()
    }
}

function Read-TextWithDefault {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter()][string]$DefaultValue,
        [Parameter()][string[]]$PromptGuidanceLines,
        [Parameter()][string]$PromptGuidanceDocRelativePath,
        [Parameter()][string]$PromptGuidanceRef,
        [Parameter()][string]$PromptGuidanceLinkLabel = 'Click for docs',
        [Parameter()][switch]$AllowEmpty
    )

    Initialize-SpectreConsole

    while ($true) {
        if ([string]::IsNullOrWhiteSpace($Prompt)) {
            throw 'Read-TextWithDefault received an empty prompt label. This would create an ambiguous input prompt.'
        }

        $value = $null
        Write-SetupPromptFrame -PromptKind 'Text' -PromptText $Prompt -PromptGuidanceLines $PromptGuidanceLines -PromptGuidanceDocRelativePath $PromptGuidanceDocRelativePath -PromptGuidanceRef $PromptGuidanceRef -PromptGuidanceLinkLabel $PromptGuidanceLinkLabel
        if (-not [string]::IsNullOrWhiteSpace($DefaultValue)) {
            Show-SetupStatusBarAtBottom -PromptKind 'Text'
            try {
                $value = Invoke-GenericStaticMethod `
                    -Type ([Spectre.Console.AnsiConsole]) `
                    -MethodName 'Ask' `
                    -GenericTypeArguments ([Type[]]@([string])) `
                    -Arguments @((Get-SetupPromptInlineText -PromptKind 'Text' -PromptText $Prompt), $DefaultValue)
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
                $value = $textPrompt.Show([Spectre.Console.AnsiConsole]::Console)
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

function Get-DefaultSetupBranchName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseBranch,
        [Parameter()][string]$Context = 'setup'
    )

    $safeContext = ConvertTo-UrlSafeName -Name $Context
    if ([string]::IsNullOrWhiteSpace($safeContext)) {
        $safeContext = 'setup'
    }

    $safeBaseBranch = ConvertTo-UrlSafeName -Name $BaseBranch
    if ([string]::IsNullOrWhiteSpace($safeBaseBranch)) {
        $safeBaseBranch = 'main'
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
    return "alm4dataverse/$safeContext-$safeBaseBranch-$timestamp"
}

function Get-RepoChangePublishPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProviderName,
        [Parameter(Mandatory)][string]$RepositoryName,
        [Parameter(Mandatory)][string]$BaseBranch,
        [Parameter(Mandatory)][string]$DefaultCommitMessage,
        [Parameter(Mandatory)][string]$DefaultPullRequestTitle,
        [Parameter()][string]$DefaultPullRequestDescription,
        [Parameter()][string[]]$GuidanceLines,
        [Parameter()][string]$DocRelativePath,
        [Parameter()][string]$Ref
    )

    $defaultGuidance = @(
        "Choose how setup should publish generated updates to '$RepositoryName'.",
        "Direct commit applies changes immediately and is best when fast activation matters more than review.",
        "Branch + pull request adds review/check gates and is best when governance or branch protection is required."
    )

    Write-Host ""
    Write-SetupGuidance -Lines @($defaultGuidance + @($GuidanceLines)) -DocRelativePath $DocRelativePath -Ref $Ref -Header 'Repository publication guidance'

    $menuItems = @(
        "Commit directly to '$BaseBranch'",
        'Commit directly to another branch',
        "Push a branch and open a pull request into '$BaseBranch'"
    )

    $selection = Select-FromMenu `
        -Title "How should the $ProviderName repository changes be published?" `
        -Items $menuItems `
        -PromptGuidanceLines @(
            "Choose whether to apply $ProviderName repository changes directly or through a pull request.",
            "Use direct commit for immediate activation, or branch + PR when review/approval is required."
        ) `
        -PromptGuidanceDocRelativePath $DocRelativePath `
        -PromptGuidanceRef $Ref
    if ($null -eq $selection) {
        throw "No repository publish option selected."
    }

    switch ($selection) {
        0 {
            return [pscustomobject]@{
                Mode                   = 'Direct'
                BranchName             = $BaseBranch
                TargetBranch           = $BaseBranch
                CommitMessage          = $DefaultCommitMessage
                PullRequestTitle       = $null
                PullRequestDescription = $null
            }
        }
        1 {
            $directBranch = Read-TextWithDefault -Prompt 'Branch to commit to' -DefaultValue $BaseBranch
            return [pscustomobject]@{
                Mode                   = 'Direct'
                BranchName             = $directBranch
                TargetBranch           = $directBranch
                CommitMessage          = $DefaultCommitMessage
                PullRequestTitle       = $null
                PullRequestDescription = $null
            }
        }
        2 {
            $defaultBranchName = Get-DefaultSetupBranchName -BaseBranch $BaseBranch -Context $RepositoryName
            $sourceBranch = Read-TextWithDefault -Prompt 'Branch to push for the pull request' -DefaultValue $defaultBranchName
            $prTitle = Read-TextWithDefault -Prompt 'Pull request title' -DefaultValue $DefaultPullRequestTitle

            return [pscustomobject]@{
                Mode                   = 'PullRequest'
                BranchName             = $sourceBranch
                TargetBranch           = $BaseBranch
                CommitMessage          = $DefaultCommitMessage
                PullRequestTitle       = $prTitle
                PullRequestDescription = $DefaultPullRequestDescription
            }
        }
    }
}

function Get-BranchTargetedRepoChangePublishPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProviderName,
        [Parameter(Mandatory)][string]$RepositoryName,
        [Parameter(Mandatory)][string]$TargetBranch,
        [Parameter(Mandatory)][string]$DefaultCommitMessage,
        [Parameter(Mandatory)][string]$DefaultPullRequestTitle,
        [Parameter()][string]$DefaultPullRequestDescription,
        [Parameter()][string[]]$GuidanceLines,
        [Parameter()][string]$DocRelativePath,
        [Parameter()][string]$Ref
    )

    $defaultGuidance = @(
        "Choose how setup should publish branch-specific updates for '$TargetBranch' in '$RepositoryName'.",
        "Direct commit updates '$TargetBranch' immediately and is best when instant activation is intended.",
        "Branch + pull request adds review/check gates and is best when '$TargetBranch' must be controlled before changes land."
    )

    Write-Host ""
    Write-SetupGuidance -Lines @($defaultGuidance + @($GuidanceLines)) -DocRelativePath $DocRelativePath -Ref $Ref -Header 'Branch publication guidance'

    $menuItems = @(
        "Commit directly to '$TargetBranch'",
        "Push a branch and open a pull request into '$TargetBranch'"
    )

    $selection = Select-FromMenu `
        -Title "How should the $ProviderName changes for branch '$TargetBranch' be published?" `
        -Items $menuItems `
        -PromptGuidanceLines @(
            "Choose whether branch '$TargetBranch' updates should be applied directly or via a pull request.",
            "Use direct commit for immediate branch updates, or branch + PR when checks and review gates are needed."
        ) `
        -PromptGuidanceDocRelativePath $DocRelativePath `
        -PromptGuidanceRef $Ref
    if ($null -eq $selection) {
        throw "No repository publish option selected for branch '$TargetBranch'."
    }

    switch ($selection) {
        0 {
            return [pscustomobject]@{
                Mode                   = 'Direct'
                BranchName             = $TargetBranch
                TargetBranch           = $TargetBranch
                CommitMessage          = $DefaultCommitMessage
                PullRequestTitle       = $null
                PullRequestDescription = $null
            }
        }
        1 {
            $defaultBranchName = Get-DefaultSetupBranchName -BaseBranch $TargetBranch -Context $RepositoryName
            $sourceBranch = Read-TextWithDefault -Prompt 'Branch to push for the pull request' -DefaultValue $defaultBranchName
            $prTitle = Read-TextWithDefault -Prompt 'Pull request title' -DefaultValue $DefaultPullRequestTitle

            return [pscustomobject]@{
                Mode                   = 'PullRequest'
                BranchName             = $sourceBranch
                TargetBranch           = $TargetBranch
                CommitMessage          = $DefaultCommitMessage
                PullRequestTitle       = $prTitle
                PullRequestDescription = $DefaultPullRequestDescription
            }
        }
    }
}

function Get-CredentialSummaryText {
    [CmdletBinding()]
    param(
        [Parameter()]$Credentials
    )

    if ($null -eq $Credentials) {
        return ''
    }

    $name = ''
    if ($Credentials.PSObject.Properties.Name -contains 'Name' -and -not [string]::IsNullOrWhiteSpace($Credentials.Name)) {
        $name = [string]$Credentials.Name
    }
    elseif ($Credentials.PSObject.Properties.Name -contains 'ApplicationId' -and -not [string]::IsNullOrWhiteSpace($Credentials.ApplicationId)) {
        $name = [string]$Credentials.ApplicationId
    }

    if ($Credentials.PSObject.Properties.Name -contains 'IsExistingServiceConnection' -and $Credentials.IsExistingServiceConnection) {
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            return "Existing service connection - $name"
        }
        return 'Existing service connection'
    }

    $authType = 'Credential'
    if ($Credentials.PSObject.Properties.Name -contains 'AuthType' -and -not [string]::IsNullOrWhiteSpace($Credentials.AuthType)) {
        $authType = [string]$Credentials.AuthType
    }

    if (-not [string]::IsNullOrWhiteSpace($name)) {
        return "$authType - $name"
    }

    return $authType
}

function Show-EnvironmentConfigurationTable {
    [CmdletBinding()]
    param(
        [Parameter()][array]$EnvironmentConfigurations
    )

    Initialize-SpectreConsole

    $items = @($EnvironmentConfigurations)
    if ($items.Count -eq 0) {
        [Spectre.Console.AnsiConsole]::MarkupLine('[grey]No environments selected yet.[/]')
        return
    }

    [Spectre.Console.AnsiConsole]::MarkupLine('[bold yellow]Environment plan[/]')
    $table = New-SpectreTable -Columns @('Short name', 'Friendly name', 'Dataverse URL', 'Credential', 'Service account')
    foreach ($env in $items) {
        $serviceAccountUPN = ''
        if ($env.PSObject.Properties.Name -contains 'ServiceAccountUPN' -and -not [string]::IsNullOrWhiteSpace($env.ServiceAccountUPN)) {
            $serviceAccountUPN = [string]$env.ServiceAccountUPN
        }

        Add-SpectreTableRow -Table $table -Cells @(
            [string]$env.ShortName,
            [string]$env.FriendlyName,
            [string]$env.Url,
            (Get-CredentialSummaryText -Credentials $env.Credentials),
            $serviceAccountUPN
        )
    }

    [Spectre.Console.AnsiConsole]::Write($table)
}

function Select-OrderedSolutions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][array]$AvailableSolutions,
        [Parameter()][array]$InitiallySelectedSolutions
    )

    $selectedSolutions = @()
    if ($InitiallySelectedSolutions) {
        $selectedSolutions += @($InitiallySelectedSolutions)
    }

    while ($true) {
        Write-Section `
            -Message 'Configure solution order' `
            -GuidanceLines @(
                'Select the solution(s) you want to manage in this repo.',
                'Order is important. If solution A depends on solution B, then B should be earlier in the list than A. This ensures that deployment processes them in the correct sequence.'
            ) `
            -GuidanceDocRelativePath 'docs/config/alm-config.md'

        if ($selectedSolutions.Count -eq 0) {
            [Spectre.Console.AnsiConsole]::MarkupLine('[grey]No solutions selected yet.[/]')
        }
        else {
            [Spectre.Console.AnsiConsole]::MarkupLine('[bold green]Selected solutions (dependency order)[/]')
            $table = New-SpectreTable -Columns @('#', 'Friendly name', 'Unique name')
            for ($solutionIndex = 0; $solutionIndex -lt $selectedSolutions.Count; $solutionIndex++) {
                $solution = $selectedSolutions[$solutionIndex]
                Add-SpectreTableRow -Table $table -Cells @(
                    [string]($solutionIndex + 1),
                    [string]$solution.friendlyname,
                    [string]$solution.uniquename
                )
            }

            [Spectre.Console.AnsiConsole]::Write($table)
        }

        [Spectre.Console.AnsiConsole]::WriteLine()

        $menuItems = @('Add a solution')
        if ($selectedSolutions.Count -gt 0) {
            $menuItems += 'Remove a solution'
            if ($selectedSolutions.Count -gt 1) {
                $menuItems += 'Move a solution earlier'
                $menuItems += 'Move a solution later'
            }
            $menuItems += 'Clear list'
            $menuItems += 'Done'
        }
        else {
            $menuItems += 'Done'
        }

        $selection = Select-FromMenu -Title 'Manage solutions' -Items $menuItems -PreserveExistingContent -SkipPromptGuidance

        if ($null -eq $selection) {
            return @($selectedSolutions)
        }

        switch ($menuItems[$selection]) {
            'Add a solution' {
                $available = @($AvailableSolutions | Where-Object {
                    $uniqueName = $_.uniquename
                    -not ($selectedSolutions | Where-Object { $_.uniquename -eq $uniqueName })
                })

                if ($available.Count -eq 0) {
                    [Spectre.Console.AnsiConsole]::MarkupLine('[yellow]All available solutions are already selected.[/]')
                    continue
                }

                $solMenu = @($available | ForEach-Object { "$($_.friendlyname) ($($_.uniquename))" })

                $solIndex = Select-FromMenu -Title 'Select a solution to add' -Items $solMenu -PromptGuidanceLines @(
                    'Choose the next unmanaged solution to add to the list.'
                ) -PromptGuidanceDocRelativePath 'docs/config/alm-config.md'
                if ($null -ne $solIndex -and $solIndex -lt $available.Count) {
                    $selectedSolutions += $available[$solIndex]
                }
            }
            'Remove a solution' {
                $solMenu = @($selectedSolutions | ForEach-Object { "$($_.friendlyname) ($($_.uniquename))" })
                $solIndex = Select-FromMenu -Title 'Select a solution to remove' -Items $solMenu
                if ($null -ne $solIndex -and $solIndex -lt $selectedSolutions.Count) {
                    $selectedSolutions = @(
                        for ($selectedIndex = 0; $selectedIndex -lt $selectedSolutions.Count; $selectedIndex++) {
                            if ($selectedIndex -ne $solIndex) {
                                $selectedSolutions[$selectedIndex]
                            }
                        }
                    )
                }
            }
            'Move a solution earlier' {
                $solMenu = @($selectedSolutions | ForEach-Object { "$($_.friendlyname) ($($_.uniquename))" })
                $solIndex = Select-FromMenu -Title 'Select a solution to move earlier' -Items $solMenu
                if ($null -ne $solIndex -and $solIndex -gt 0) {
                    $temp = $selectedSolutions[$solIndex - 1]
                    $selectedSolutions[$solIndex - 1] = $selectedSolutions[$solIndex]
                    $selectedSolutions[$solIndex] = $temp
                }
            }
            'Move a solution later' {
                $solMenu = @($selectedSolutions | ForEach-Object { "$($_.friendlyname) ($($_.uniquename))" })
                $solIndex = Select-FromMenu -Title 'Select a solution to move later' -Items $solMenu
                if ($null -ne $solIndex -and $solIndex -lt ($selectedSolutions.Count - 1)) {
                    $temp = $selectedSolutions[$solIndex + 1]
                    $selectedSolutions[$solIndex + 1] = $selectedSolutions[$solIndex]
                    $selectedSolutions[$solIndex] = $temp
                }
            }
            'Clear list' {
                $selectedSolutions = @()
                [Spectre.Console.AnsiConsole]::MarkupLine('[yellow]Solution list cleared.[/]')
            }
            'Done' {
                return @($selectedSolutions)
            }
        }
    }
}

function Set-AlmConfigSolutionsInFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][array]$Solutions,
        [Parameter()][switch]$CreateIfMissing,
        [Parameter()][string]$TemplatePath
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        if (-not $CreateIfMissing) {
            throw "alm-config.psd1 not found: $ConfigPath"
        }

        if (-not [string]::IsNullOrWhiteSpace($TemplatePath) -and (Test-Path -LiteralPath $TemplatePath)) {
            Copy-Item -LiteralPath $TemplatePath -Destination $ConfigPath -Force
        }
        else {
            $initialContent = "@{`n    solutions = @(`n    )`n}`n"
            Set-Content -LiteralPath $ConfigPath -Value $initialContent -NoNewline
        }
    }

    $configContent = Get-Content -LiteralPath $ConfigPath -Raw

    $solutionsArray = "@("
    if ($Solutions.Count -gt 0) {
        $solutionsArray += "`n"
        foreach ($solution in $Solutions) {
            $escapedSolutionName = ([string]$solution.name).Replace("'", "''")
            $solutionsArray += "        @{`n"
            $solutionsArray += "            name = '$escapedSolutionName'`n"
            if ($solution.deployUnmanaged) {
                $solutionsArray += "            deployUnmanaged = `$true`n"
            }
            $solutionsArray += "        }`n"
        }
        $solutionsArray += "    )"
    }
    else {
        $solutionsArray += "`n    )"
    }

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($configContent, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        throw "Could not parse existing alm-config.psd1 '$ConfigPath': $($parseErrors[0].Message)"
    }

    $rootHashtable = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.HashtableAst]
    }, $false)

    if (-not $rootHashtable) {
        throw "Could not find the root hashtable in '$ConfigPath'."
    }

    $solutionsEntry = $rootHashtable.KeyValuePairs | Where-Object {
        $keyText = $_.Item1.Extent.Text.Trim()
        $keyText -in @('solutions', "'solutions'", '"solutions"')
    } | Select-Object -First 1

    if ($solutionsEntry) {
        $valueExtent = $solutionsEntry.Item2.Extent
        $updatedContent = $configContent.Substring(0, $valueExtent.StartOffset) + $solutionsArray + $configContent.Substring($valueExtent.EndOffset)
    }
    else {
        $insertOffset = $rootHashtable.Extent.EndOffset - 1
        $lineEnding = if ($configContent -match "`r`n") { "`r`n" } else { "`n" }
        $insertText = "$lineEnding    solutions = $solutionsArray$lineEnding"
        $updatedContent = $configContent.Substring(0, $insertOffset) + $insertText + $configContent.Substring($insertOffset)
    }

    $hasChanges = ($updatedContent -ne $configContent)
    if ($hasChanges) {
        Set-Content -LiteralPath $ConfigPath -Value $updatedContent -NoNewline
    }

    return $hasChanges
}

function Select-ConfiguredDeploymentEnvironments {
    [CmdletBinding()]
    param(
        [Parameter()][array]$InitialEnvironments,
        [Parameter(Mandatory)][scriptblock]$AddEnvironmentScriptBlock,
        [Parameter()][scriptblock]$EditEnvironmentScriptBlock,
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

        $menuItems = @('Add an environment')
        if ($selectedEnvironments.Count -gt 0) {
            if ($EditEnvironmentScriptBlock) {
                $menuItems += 'Edit an environment'
            }
            $menuItems += 'Remove an environment'
            $menuItems += 'Clear list'
            $menuItems += 'Done'
        }
        else {
            $menuItems += 'Done'
        }

        $selection = Select-FromMenu -Title $Title -Items $menuItems -PreserveExistingContent -SkipPromptGuidance
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
            'Remove an environment' {
                $environmentMenuItems = @()
                for ($i = 0; $i -lt $selectedEnvironments.Count; $i++) {
                    $environment = $selectedEnvironments[$i]
                    $shortName = [string]$environment.ShortName
                    $friendlyName = if ([string]::IsNullOrWhiteSpace($environment.FriendlyName)) { $shortName } else { [string]$environment.FriendlyName }
                    $url = if ([string]::IsNullOrWhiteSpace($environment.Url)) { '<not set>' } else { [string]$environment.Url }
                    $environmentMenuItems += "$shortName - $friendlyName ($url)"
                }

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
                $environmentMenuItems = @()
                for ($i = 0; $i -lt $selectedEnvironments.Count; $i++) {
                    $environment = $selectedEnvironments[$i]
                    $shortName = [string]$environment.ShortName
                    $friendlyName = if ([string]::IsNullOrWhiteSpace($environment.FriendlyName)) { $shortName } else { [string]$environment.FriendlyName }
                    $url = if ([string]::IsNullOrWhiteSpace($environment.Url)) { '<not set>' } else { [string]$environment.Url }
                    $environmentMenuItems += "$shortName - $friendlyName ($url)"
                }

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
    [CmdletBinding()]
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

function Test-BranchEnvironmentMappingsHaveDuplicates {
    [CmdletBinding()]
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

    $table = New-SpectreTable -Columns @('Branch', 'DEV environment', 'Deployment environments')
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

        Add-SpectreTableRow -Table $table -Cells @(
            $branchName,
            $devEnvironmentLabel,
            $(if ($environmentNames.Count -gt 0) { $environmentNames -join ', ' } else { '<none>' })
        )
    }

    [Spectre.Console.AnsiConsole]::Write($table)
}

function Select-BranchEnvironmentMappings {
    [CmdletBinding()]
    param(
        [Parameter()][AllowEmptyCollection()][array]$EnvironmentConfigurations = @(),
        [Parameter()][array]$InitialBranchMappings,
        [Parameter()][string]$Title = 'Manage deployment branches and environment mappings',
        [Parameter()][string[]]$GuidanceLines,
        [Parameter()][string]$DocRelativePath,
        [Parameter()][string]$Ref,
        [Parameter()][switch]$BranchOnly,
        [Parameter()][scriptblock]$EditDevEnvironmentScriptBlock,
        [Parameter()][scriptblock]$EditDeploymentEnvironmentsScriptBlock
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
        }
    }

    $isNewRepositoryBootstrapState = (
        $branchMappings.Count -eq 1 -and
        ([string]$branchMappings[0].BranchName -ieq 'main') -and
        ($null -eq $branchMappings[0].DevEnvironmentConfiguration) -and
        ($null -eq $branchMappings[0].ExistingDevEnvironment) -and
        (@($branchMappings[0].Environments).Count -eq 0)
    )

    if ($isNewRepositoryBootstrapState) {
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
                },
                [pscustomobject]@{
                    BranchName                  = 'develop'
                    DevEnvironmentConfiguration = $null
                    ExistingDevEnvironment      = $null
                    Environments                = @()
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
    }

    while ($true) {
        Write-Section `
            -Message 'Configure deployment branch mappings' `
            -GuidanceLines @(
                'Define which branches setup manages, and map each branch to DEV and deployment targets.',
                'These mappings control generated pipelines/workflows, so clear ownership prevents ambiguous promotion paths.'
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

        switch ($menuItems[$selection]) {
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
                $editIndex = Select-FromMenu -Title 'Select branch mapping to edit' -Items $branchMenu
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
                if (-not $BranchOnly) {
                    $mappingMenuItems += 'Assign environments'
                    $mappingMenuItems += 'Clear all assigned environments'
                }
                $mappingMenuItems += 'Done'

                while ($true) {
                    $mappingAction = Select-FromMenu -Title "Edit branch '$($currentMapping.BranchName)'" -Items $mappingMenuItems -PreserveExistingContent
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
                            $currentMapping.DevEnvironmentConfiguration = & $EditDevEnvironmentScriptBlock @($branchMappings) $currentMapping
                            $branchMappings[$editIndex] = $currentMapping
                        }
                        'Edit deployment environments' {
                            $updatedDeploymentEnvironments = @(& $EditDeploymentEnvironmentsScriptBlock @($branchMappings) $currentMapping)
                            $currentMapping.Environments = @($updatedDeploymentEnvironments | Where-Object { $null -ne $_ })
                            $branchMappings[$editIndex] = $currentMapping
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
                }
            }
            'Done' {
                if (Test-BranchEnvironmentMappingsHaveDuplicates -BranchMappings $branchMappings) {
                    [Spectre.Console.AnsiConsole]::MarkupLine('[red]Each environment can only be assigned to one branch. Resolve duplicates before continuing.[/]')
                    continue
                }

                return @($branchMappings)
            }
        }
    }
}

function Get-ModulePathDelimiter {
    return [System.IO.Path]::PathSeparator
}

function Install-NuGetProviderIfMissing {
    $nuget = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
    if (-not $nuget) {
        Write-Host "Installing NuGet package provider (required for Save-Module)..." -ForegroundColor Yellow
        Install-PackageProvider -Name NuGet -Force -Scope CurrentUser | Out-Null
    }
}

function Get-ModuleAvailableExact {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$RequiredVersion
    )

    $mods = Get-Module -Name $Name -ListAvailable -ErrorAction SilentlyContinue
    if (-not $mods) { return $null }

    return $mods | Where-Object { $_.Version -eq [version]$RequiredVersion } | Select-Object -First 1
}

function Save-ModuleExact {
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
    [CmdletBinding()]
    param(
        [Parameter()][string]$PrimaryRepositoryPath,
        [Parameter()][string]$FallbackRef = 'stable'
    )

    $candidateRepos = @()
    foreach ($candidate in @($PrimaryRepositoryPath, $PSScriptRoot)) {
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

                $branch = (& git -C $repoPath branch --show-current 2>$null).Trim()
                if (-not [string]::IsNullOrWhiteSpace($branch)) {
                    Write-Host "Development mode: Using current local branch '$branch' as ALM4DataverseRef" -ForegroundColor Yellow
                    return $branch
                }

                $commit = (& git -C $repoPath rev-parse HEAD 2>$null).Trim()
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

function ConvertTo-SetupActivityOutputLine {
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Entry
    )

    if ($null -eq $Entry) {
        return $null
    }

    $style = 'white'
    $text = $null

    if ($Entry -is [System.Management.Automation.InformationRecord]) {
        $text = [string]$Entry.MessageData
        $style = 'grey'
    }
    elseif ($Entry -is [System.Management.Automation.WarningRecord]) {
        $text = [string]$Entry.Message
        $style = 'yellow'
    }
    elseif ($Entry -is [System.Management.Automation.VerboseRecord]) {
        $text = [string]$Entry.Message
        $style = 'deepskyblue1'
    }
    elseif ($Entry -is [System.Management.Automation.DebugRecord]) {
        $text = [string]$Entry.Message
        $style = 'mediumpurple3'
    }
    elseif ($Entry -is [System.Management.Automation.ErrorRecord]) {
        $text = [string]$Entry.ToString()
        $style = 'red3_1'
    }
    else {
        $text = [string]$Entry
    }

    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    return "[$style]$(ConvertTo-SpectreMarkupLiteral -Text $text.Trim())[/]"
}

function Show-SetupActivityOutputPanel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Heading,
        [Parameter()][string[]]$Lines,
        [Parameter()][int]$MaxLines = 12
    )

    Initialize-SpectreConsole

    $effectiveLines = @($Lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($effectiveLines.Count -eq 0) {
        $effectiveLines = @('[grey]No additional output was produced for this action.[/]')
    }
    elseif ($effectiveLines.Count -gt $MaxLines) {
        $hiddenCount = $effectiveLines.Count - $MaxLines
        $effectiveLines = @("[grey]... $hiddenCount earlier line(s) omitted ...[/]") + $effectiveLines[($effectiveLines.Count - $MaxLines)..($effectiveLines.Count - 1)]
    }

    $content = [Spectre.Console.Markup]::new(($effectiveLines -join [Environment]::NewLine))
    [Spectre.Console.AnsiConsole]::Write((New-SpectrePanel -Content $content -Header $Heading -BorderColor 'grey42' -Expand))
    [Spectre.Console.AnsiConsole]::WriteLine()
}

function Invoke-WithSpectreStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [Parameter()][switch]$CaptureOutputInPanel
    )

    Initialize-SpectreConsole

    $scriptExecutionStarted = $false
    $scriptExecutionCompleted = $false
    $scriptExecutionResult = $null

    try {
        $statusDisplay = [Spectre.Console.AnsiConsole]::Status()
        $statusDisplay.AutoRefresh = $true
        $statusDisplay.SpinnerStyle = [Spectre.Console.Style]::Parse('bold deepskyblue1')

        if (-not $CaptureOutputInPanel) {
            return $statusDisplay.Start(
                "[bold deepskyblue1]$(ConvertTo-SpectreMarkupLiteral -Text $Status)[/]",
                [System.Func[Spectre.Console.StatusContext, object]]{
                    param($context)
                    & $ScriptBlock $context
                }
            )
        }

        $capturedLines = [System.Collections.Generic.List[string]]::new()

        $result = $statusDisplay.Start(
            "[bold deepskyblue1]$(ConvertTo-SpectreMarkupLiteral -Text $Status)[/]",
            [System.Func[Spectre.Console.StatusContext, object]]{
                param($context)

                $scriptExecutionStarted = $true
                $capturedOutput = @(& { & $ScriptBlock $context } 6>&1 5>&1 4>&1 3>&1 2>&1)
                $capturedResult = $null
                foreach ($entry in $capturedOutput) {
                    if (
                        $entry -is [System.Management.Automation.InformationRecord] -or
                        $entry -is [System.Management.Automation.WarningRecord] -or
                        $entry -is [System.Management.Automation.VerboseRecord] -or
                        $entry -is [System.Management.Automation.DebugRecord] -or
                        $entry -is [System.Management.Automation.ErrorRecord] -or
                        $entry -is [string]
                    ) {
                        $line = ConvertTo-SetupActivityOutputLine -Entry $entry
                        if (-not [string]::IsNullOrWhiteSpace($line)) {
                            $capturedLines.Add($line)
                        }
                    }
                    else {
                        $capturedResult = $entry
                    }
                }

                $scriptExecutionCompleted = $true
                $scriptExecutionResult = $capturedResult
                return $capturedResult
            }
        )

        Show-SetupActivityOutputPanel -Heading $Status -Lines $capturedLines
        return $result
    }
    catch {
        if (Test-IsSetupWizardBackException -Exception $_.Exception) {
            throw
        }

        if (Test-IsUserInterruptException -Exception $_.Exception) {
            throw
        }

        if ($CaptureOutputInPanel -and ($scriptExecutionStarted -or $scriptExecutionCompleted)) {
            if ($scriptExecutionCompleted) {
                return $scriptExecutionResult
            }

            throw
        }

        return & $ScriptBlock $null
    }
}

function Invoke-WithErrorHandling {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [Parameter(Mandatory)][string]$OperationName,
        [Parameter()][switch]$AllowSkip,
        [Parameter()][string]$StatusMessage,
        [Parameter()][switch]$CaptureOutputInPanel
    )

    while ($true) {
        try {
            if ([string]::IsNullOrWhiteSpace($StatusMessage)) {
                return & $ScriptBlock
            }

            return Invoke-WithSpectreStatus -Status $StatusMessage -ScriptBlock $ScriptBlock -CaptureOutputInPanel:$CaptureOutputInPanel
        }
        catch {
            if (Test-IsSetupWizardBackException -Exception $_.Exception) {
                throw
            }

            if (Test-IsUserInterruptException -Exception $_.Exception) {
                throw
            }

            Initialize-SpectreConsole

            $errorLines = @(
                "[bold red]ERROR in $(ConvertTo-SpectreMarkupLiteral -Text $OperationName)[/]",
                "[yellow]Error Type:[/] $(ConvertTo-SpectreMarkupLiteral -Text $_.Exception.GetType().Name)",
                "[yellow]Error Message:[/] $(ConvertTo-SpectreMarkupLiteral -Text $_.Exception.Message)"
            )

            if ($_.InvocationInfo.PositionMessage) {
                $errorLines += "[grey]Location:[/] $(ConvertTo-SpectreMarkupLiteral -Text $_.InvocationInfo.PositionMessage.Trim())"
            }

            if ($_.ScriptStackTrace) {
                $errorLines += "[grey]Stack Trace:[/] $(ConvertTo-SpectreMarkupLiteral -Text $_.ScriptStackTrace.Trim())"
            }

            [Spectre.Console.AnsiConsole]::WriteLine()
            [Spectre.Console.AnsiConsole]::Write((New-SpectrePanel -Content ([Spectre.Console.Markup]::new(($errorLines -join [Environment]::NewLine))) -Header 'Setup error' -BorderColor 'red3_1' -Expand -PaddingY 1))
            [Spectre.Console.AnsiConsole]::WriteLine()

            $options = @('Retry')
            if ($AllowSkip) {
                $options += 'Skip (Not Recommended)'
            }
            $options += 'Abort Setup'

            $choice = Select-FromMenu -Title "How would you like to proceed?" -Items $options -PreserveExistingContent

            if ($null -eq $choice) {
                Write-Host "Setup aborted by user." -ForegroundColor Yellow
                throw "Setup aborted by user."
            }

            switch ($options[$choice]) {
                'Retry' {
                    Initialize-SpectreConsole
                    [Spectre.Console.AnsiConsole]::Clear()
                    Write-Host "Retrying $OperationName..." -ForegroundColor Cyan
                    continue
                }
                'Skip (Not Recommended)' {
                    Write-Host "Skipping $OperationName. This may cause issues later." -ForegroundColor Yellow
                    return $null
                }
                'Abort Setup' {
                    Write-Host "Setup aborted by user." -ForegroundColor Yellow
                    throw "Setup aborted by user after error in $OperationName"
                }
            }
        }
    }
}

function Show-SetupCompletionScreen {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Heading,
        [Parameter(Mandatory)][string]$AccessLabel,
        [Parameter(Mandatory)][string]$AccessUrl,
        [Parameter()][array]$MetricCards,
        [Parameter()][hashtable]$SummaryValues,
        [Parameter()][array]$NextStepLinks,
        [Parameter()][string[]]$Notes
    )

    Initialize-SpectreConsole
    [Spectre.Console.AnsiConsole]::Clear()

    Write-SetupDashboard -Message $Heading -IncludeTrailingSpacer

    if ($SummaryValues -and $SummaryValues.Count -gt 0) {
        [Spectre.Console.AnsiConsole]::Write((New-SpectrePanel -Content (New-SpectreInfoGrid -Values $SummaryValues -LabelWidth 18) -Header 'Result summary' -BorderColor 'deepskyblue1' -Expand))
        [Spectre.Console.AnsiConsole]::WriteLine()
    }

    $heroLines = @(
        '[grey]The guided setup has finished and the generated automation assets are ready for review.[/]',
        "[grey]$([string](ConvertTo-SpectreMarkupLiteral -Text $AccessLabel)):[/] [link=$AccessUrl]$AccessUrl[/]"
    )

    [Spectre.Console.AnsiConsole]::Write((New-SpectrePanel -Content ([Spectre.Console.Markup]::new(($heroLines -join [Environment]::NewLine))) -Header 'Ready to open' -BorderColor 'green3_1' -Expand -PaddingY 1))
    [Spectre.Console.AnsiConsole]::WriteLine()

    if ($NextStepLinks -and $NextStepLinks.Count -gt 0) {
        $linkMarkup = @(
            foreach ($nextStep in $NextStepLinks) {
                $nextStepUrl = $null
                $nextStepLabel = $null

                if ($nextStep -is [string]) {
                    $nextStepUrl = $nextStep
                    $nextStepLabel = $nextStep
                }
                elseif ($nextStep -is [System.Collections.IDictionary]) {
                    if ($nextStep.Contains('Url')) {
                        $nextStepUrl = [string]$nextStep['Url']
                    }

                    if ($nextStep.Contains('Label') -and -not [string]::IsNullOrWhiteSpace($nextStep['Label'])) {
                        $nextStepLabel = [string]$nextStep['Label']
                    }
                    elseif ($nextStep.Contains('Description') -and -not [string]::IsNullOrWhiteSpace($nextStep['Description'])) {
                        $nextStepLabel = [string]$nextStep['Description']
                    }
                    elseif ($nextStep.Contains('Text') -and -not [string]::IsNullOrWhiteSpace($nextStep['Text'])) {
                        $nextStepLabel = [string]$nextStep['Text']
                    }
                }
                elseif ($nextStep -is [pscustomobject]) {
                    if ($nextStep.PSObject.Properties.Name -contains 'Url') {
                        $nextStepUrl = [string]$nextStep.Url
                    }

                    if ($nextStep.PSObject.Properties.Name -contains 'Label' -and -not [string]::IsNullOrWhiteSpace($nextStep.Label)) {
                        $nextStepLabel = [string]$nextStep.Label
                    }
                    elseif ($nextStep.PSObject.Properties.Name -contains 'Description' -and -not [string]::IsNullOrWhiteSpace($nextStep.Description)) {
                        $nextStepLabel = [string]$nextStep.Description
                    }
                    elseif ($nextStep.PSObject.Properties.Name -contains 'Text' -and -not [string]::IsNullOrWhiteSpace($nextStep.Text)) {
                        $nextStepLabel = [string]$nextStep.Text
                    }
                }

                if ([string]::IsNullOrWhiteSpace($nextStepUrl)) {
                    continue
                }

                if ([string]::IsNullOrWhiteSpace($nextStepLabel)) {
                    $nextStepLabel = $nextStepUrl
                }

                "- [link=$nextStepUrl]$(ConvertTo-SpectreMarkupLiteral -Text $nextStepLabel)[/]"
            }
        ) -join [Environment]::NewLine

        [Spectre.Console.AnsiConsole]::Write((New-SpectrePanel -Content ([Spectre.Console.Markup]::new($linkMarkup)) -Header 'Next steps' -BorderColor 'yellow3' -Expand))
        [Spectre.Console.AnsiConsole]::WriteLine()
    }
}

function Get-AuthToken {
    param(
        [Parameter(Mandatory)][string]$ResourceUrl,
        [Parameter()][string]$TenantId,
        [Parameter()][string]$ClientId = '1950a258-227b-4e31-a9cf-717495945fc2',
        [Parameter()][switch]$ForceInteractive,
        [Parameter()][string]$PreferredUsername,
        [Parameter()][switch]$ListAccountsOnly
    )

    [void][System.Reflection.Assembly]::LoadWithPartialName("Microsoft.Identity.Client")

    try {
        [void][Microsoft.Identity.Client.PublicClientApplicationBuilder]
    }
    catch {
        $module = Get-Module -Name "Rnwood.Dataverse.Data.PowerShell"
        if ($module) {
            $base = $module.ModuleBase
            $dllPath = $null

            if ($PSVersionTable.PSEdition -eq 'Core') {
                $dllPath = Join-Path $base "cmdlets\net8.0\Microsoft.Identity.Client.dll"
                if (-not (Test-Path $dllPath)) {
                    $dllPath = Join-Path $base "cmdlets\netcoreapp3.1\Microsoft.Identity.Client.dll"
                }
            }
            else {
                $dllPath = Join-Path $base "cmdlets\net462\Microsoft.Identity.Client.dll"
            }

            if ($dllPath -and (Test-Path $dllPath)) {
                Add-Type -Path $dllPath
            }
            else {
                $allDlls = Get-ChildItem $base -Recurse -Filter "Microsoft.Identity.Client.dll"
                $found = $null
                if ($PSVersionTable.PSEdition -eq 'Core') {
                    $found = $allDlls | Where-Object { $_.FullName -match 'netcore|netstandard|net\d\.\d' } | Select-Object -First 1
                }
                else {
                    $found = $allDlls | Where-Object { $_.FullName -match 'net4' } | Select-Object -First 1
                }

                if ($found) {
                    Add-Type -Path $found.FullName
                }
            }
        }
    }

    $ResourceUrl = $ResourceUrl.TrimEnd('/')
    $scopes = [string[]]@("$ResourceUrl/.default")

    $app = $null
    try {
        $app = Get-Variable -Name "MsalApp" -Scope Script -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Value
    }
    catch {
        $app = $null
    }

    if (-not $app) {
        $builder = [Microsoft.Identity.Client.PublicClientApplicationBuilder]::Create($ClientId)

        $authority = "https://login.microsoftonline.com/common"
        if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
            $authority = "https://login.microsoftonline.com/$TenantId"
        }

        $builder = $builder.WithAuthority($authority)
        $builder = $builder.WithRedirectUri("http://localhost")
        $app = $builder.Build()

        Set-Variable -Name "MsalApp" -Value $app -Scope Script
    }

    $msalCacheDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ALM4Dataverse'
    New-DirectoryIfMissing -Path $msalCacheDir
    $msalCachePath = Join-Path $msalCacheDir 'msal-token-cache.bin'

    try {
        if (Test-Path -LiteralPath $msalCachePath) {
            $cacheBytes = [System.IO.File]::ReadAllBytes($msalCachePath)
            if ($cacheBytes -and $cacheBytes.Length -gt 0) {
                $app.UserTokenCache.DeserializeMsalV3($cacheBytes, $true)
            }
        }
    }
    catch {
        Write-Warning "Failed to load MSAL token cache from '$msalCachePath': $($_.Exception.Message)"
    }

    $accounts = @($app.GetAccountsAsync().GetAwaiter().GetResult())

    if ($ListAccountsOnly) {
        return @($accounts | ForEach-Object { $_.Username } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    }

    $account = $null
    if (-not [string]::IsNullOrWhiteSpace($PreferredUsername)) {
        $account = $accounts | Where-Object { $_.Username -ieq $PreferredUsername } | Select-Object -First 1
        if (-not $account) {
            Write-Host "Preferred cached Azure login '$PreferredUsername' was not found; using the default cached account selection." -ForegroundColor Yellow
        }
    }

    if (-not $account) {
        $account = $accounts | Select-Object -First 1
    }

    $authResult = $null

    try {
        if (-not $ForceInteractive -and $account) {
            $authResult = $app.AcquireTokenSilent($scopes, $account).ExecuteAsync().GetAwaiter().GetResult()
        }
    }
    catch {
        # Silent acquisition failed, try interactive.
    }

    if (-not $authResult) {
        try {
            $interactiveBuilder = $app.AcquireTokenInteractive($scopes)

            if ($ForceInteractive) {
                $interactiveBuilder = $interactiveBuilder.WithPrompt([Microsoft.Identity.Client.Prompt]::SelectAccount)
            }

            if (-not [string]::IsNullOrWhiteSpace($PreferredUsername)) {
                $interactiveBuilder = $interactiveBuilder.WithLoginHint($PreferredUsername)
            }

            $authResult = $interactiveBuilder.ExecuteAsync().GetAwaiter().GetResult()
        }
        catch {
            Write-Error "Failed to acquire token interactively: $_"
            throw
        }
    }

    try {
        $updatedCacheBytes = $app.UserTokenCache.SerializeMsalV3()
        if ($updatedCacheBytes -and $updatedCacheBytes.Length -gt 0) {
            [System.IO.File]::WriteAllBytes($msalCachePath, $updatedCacheBytes)
        }
    }
    catch {
        Write-Warning "Failed to save MSAL token cache to '$msalCachePath': $($_.Exception.Message)"
    }

    return $authResult
}

function New-EntraIdApplicationSecret {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ApplicationObjectId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter()][string]$DisplayName = 'ALM4Dataverse Setup'
    )

    $graphToken = Get-AuthToken -ResourceUrl 'https://graph.microsoft.com' -TenantId $TenantId
    $headers = @{
        Authorization  = "Bearer $($graphToken.AccessToken)"
        'Content-Type' = 'application/json'
    }

    $secretBody = @{
        passwordCredential = @{
            displayName = $DisplayName
        }
    }

    $secretUri = "https://graph.microsoft.com/v1.0/applications/$ApplicationObjectId/addPassword"
    $secretResponse = Invoke-RestMethod -Uri $secretUri -Headers $headers -Method Post -Body ($secretBody | ConvertTo-Json)
    return $secretResponse.secretText
}

function Resolve-DataverseEnvironmentFriendlyName {
    [CmdletBinding()]
    param(
        [Parameter()][string]$EnvironmentUrl,
        [Parameter()][string]$FallbackName
    )

    $normalizedEnvironmentUrl = ConvertTo-NormalizedEnvironmentUrl -Url $EnvironmentUrl
    if ([string]::IsNullOrWhiteSpace($normalizedEnvironmentUrl)) {
        return $FallbackName
    }

    try {
        $matchingEnvironment = Get-DataverseEnvironmentCatalog | Where-Object {
            (ConvertTo-NormalizedEnvironmentUrl -Url $_.Endpoints['WebApplication']) -eq $normalizedEnvironmentUrl
        } | Select-Object -First 1

        if ($matchingEnvironment -and -not [string]::IsNullOrWhiteSpace($matchingEnvironment.FriendlyName)) {
            return [string]$matchingEnvironment.FriendlyName
        }
    }
    catch {
        Write-Host "Could not resolve Dataverse environment name for '$normalizedEnvironmentUrl'. Falling back to '$FallbackName'." -ForegroundColor DarkGray
    }

    return $FallbackName
}

function Resolve-EntraIdApplicationByAppId {
    [CmdletBinding()]
    param(
        [Parameter()][string]$ApplicationId,
        [Parameter()][string]$TenantId
    )

    if ([string]::IsNullOrWhiteSpace($ApplicationId) -or [string]::IsNullOrWhiteSpace($TenantId)) {
        return $null
    }

    if (-not (Get-Variable -Name 'entraApplicationCache' -Scope Script -ErrorAction SilentlyContinue)) {
        $script:entraApplicationCache = @{}
    }

    $cacheKey = "$TenantId|$ApplicationId"
    if ($script:entraApplicationCache.ContainsKey($cacheKey)) {
        return $script:entraApplicationCache[$cacheKey]
    }

    $graphToken = Get-AuthToken -ResourceUrl 'https://graph.microsoft.com' -TenantId $TenantId
    $headers = @{ Authorization = "Bearer $($graphToken.AccessToken)" }
    $uri = "https://graph.microsoft.com/v1.0/applications?`$filter=appId eq '$ApplicationId'&`$select=id,appId,displayName"

    try {
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
        $application = $response.value | Select-Object -First 1
        $script:entraApplicationCache[$cacheKey] = $application
        return $application
    }
    catch {
        Write-Warning "Failed to resolve App Registration '$ApplicationId' from Entra ID: $($_.Exception.Message)"
        $script:entraApplicationCache[$cacheKey] = $null
        return $null
    }
}
