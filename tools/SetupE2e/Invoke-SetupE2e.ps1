#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Drives the interactive setup scripts in a PTY and records a replayable session.
.PARAMETER Scenario
    Name of a scenario from the scenario file to run unattended.
.PARAMETER Interactive
    Reads commands from control.jsonl in the run directory while the terminal is
    live, so a person or agent can decide each keystroke from the visible screen.
.PARAMETER ListScenarios
    Lists scenario names and descriptions without starting a terminal.
.PARAMETER ConfigPath
    Configuration data file. Defaults to config.local.psd1 when present, otherwise
    the committed example.
.PARAMETER ScenarioPath
    Scenario data file. Defaults to scenarios.psd1 beside this script.
.PARAMETER RunRoot
    Parent directory for run artifacts. Defaults to TestResults/setup-e2e.
.PARAMETER Provider
    Setup provider used when a scenario does not name one: azdo or github.
.PARAMETER SetupArgument
    Additional arguments passed to the setup script.
.PARAMETER Columns
    Terminal columns. Defaults to 120.
.PARAMETER Rows
    Terminal rows. Defaults to 50.
.PARAMETER ScreenPollMilliseconds
    Interval between screen samples. Defaults to 100.
.PARAMETER CaptureImages
    Also saves a rendered PNG at each Capture step.
.DESCRIPTION
    Runs the real setup script with the real environment, records every keystroke
    and rendered screen state, and writes a synchronised transcript, an asciinema
    v2 cast, JSONL events and screen dumps under TestResults/setup-e2e/<run>.
    The terminal runtime is reused from the screenshot capture tool, so frames
    render headlessly without a display server.
.NOTES
    Run artifacts can contain tenant, organization, project and environment names.
    The default RunRoot is ignored by Git; do not publish raw recordings.
.EXAMPLE
    ./tools/SetupE2e/Invoke-SetupE2e.ps1 -ListScenarios
.EXAMPLE
    ./tools/SetupE2e/Invoke-SetupE2e.ps1 -Interactive -Provider azdo
.EXAMPLE
    ./tools/SetupE2e/Invoke-SetupE2e.ps1 -Scenario azdo-new-repository
#>
[CmdletBinding(DefaultParameterSetName = 'Scenario')]
param(
    [Parameter(ParameterSetName = 'Scenario')][string]$Scenario,
    [Parameter(ParameterSetName = 'Interactive')][switch]$Interactive,
    [Parameter(ParameterSetName = 'List')][switch]$ListScenarios,
    [Parameter()][string]$ConfigPath,
    [Parameter()][string]$ScenarioPath,
    [Parameter()][string]$RunRoot,
    [Parameter()][ValidateSet('azdo', 'github')][string]$Provider = 'azdo',
    [Parameter()][string[]]$SetupArgument = @(),
    [Parameter()][ValidateRange(40, 400)][int]$Columns = 120,
    [Parameter()][ValidateRange(20, 200)][int]$Rows = 50,
    [Parameter()][ValidateRange(20, 5000)][int]$ScreenPollMilliseconds = 100,
    [Parameter()][switch]$CaptureImages
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SetupE2eScriptRoot = $PSScriptRoot
. (Join-Path $PSScriptRoot '../SetupScreenshotCapture/Capture-SetupScreenshots.ps1')

$script:SetupE2eKeySequences = [ordered]@{
    '{ENTER}'     = "`r"
    '{TAB}'       = "`t"
    '{ESC}'       = [string][char]27
    '{SPACE}'     = ' '
    '{BACKSPACE}' = [string][char]127
    '{DELETE}'    = "$([char]27)[3~"
    '{UP}'        = "$([char]27)[A"
    '{DOWN}'      = "$([char]27)[B"
    '{RIGHT}'     = "$([char]27)[C"
    '{LEFT}'      = "$([char]27)[D"
    '{HOME}'      = "$([char]27)[H"
    '{END}'       = "$([char]27)[F"
    '{PGUP}'      = "$([char]27)[5~"
    '{PGDN}'      = "$([char]27)[6~"
}

function Get-SetupE2eConfigPath {
    <#
    .SYNOPSIS
        Chooses the configuration file for a run.
    .DESCRIPTION
        An explicit path wins. Otherwise config.local.psd1 is used when present so
        real identifiers stay out of source, and the reserved-example file is the
        fallback for a first review or a dry run.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][string]$Path
    )

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    }

    $localPath = Join-Path $script:SetupE2eScriptRoot 'config.local.psd1'
    if (Test-Path -LiteralPath $localPath -PathType Leaf) {
        return $localPath
    }

    return Join-Path $script:SetupE2eScriptRoot 'config.example.psd1'
}

function Import-SetupE2eConfig {
    <#
    .SYNOPSIS
        Loads and validates the run configuration.
    .DESCRIPTION
        Returns the data file contents plus the resolved path and a flat variable
        map used to expand {{placeholder}} tokens in scenarios. Required top-level
        keys and provider sections are validated here so a scenario cannot fail
        halfway through a signed-in run because of a typo.
    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][string]$Path
    )

    $resolvedPath = Get-SetupE2eConfigPath -Path $Path
    $config = Import-PowerShellDataFile -LiteralPath $resolvedPath

    foreach ($requiredName in @('azdo', 'github', 'dataverse', 'serviceAccount', 'solutionName')) {
        if (-not $config.Contains($requiredName)) {
            throw "Setup E2E configuration '$resolvedPath' is missing '$requiredName'."
        }
    }

    $variables = [ordered]@{}
    foreach ($sectionName in @('azdo', 'github', 'dataverse')) {
        $section = $config[$sectionName]
        if ($section -isnot [System.Collections.IDictionary]) {
            throw "Setup E2E configuration section '$sectionName' must be a hashtable."
        }
        foreach ($name in $section.Keys) {
            $value = $section[$name]
            if ($value -is [System.Collections.IDictionary]) {
                foreach ($nestedName in $value.Keys) {
                    $variables["$sectionName.$name.$nestedName"] = [string]$value[$nestedName]
                }
            }
            else {
                $variables["$sectionName.$name"] = [string]$value
            }
        }
    }
    $variables['serviceAccount'] = [string]$config['serviceAccount']
    $variables['solutionName'] = [string]$config['solutionName']

    return [pscustomobject]@{
        Path      = $resolvedPath
        Data      = $config
        Variables = $variables
    }
}

function Expand-SetupE2ePlaceholder {
    <#
    .SYNOPSIS
        Replaces {{section.key}} tokens in scenario text.
    .DESCRIPTION
        Unknown tokens throw so a mistyped placeholder cannot silently send the
        literal token to a prompt. Values are inserted verbatim; surrounding
        spaces in the scenario remain significant.
    .OUTPUTS
        System.String
    #>
    # The match evaluator runs the parameter inside a delegate, which the analyzer
    # cannot follow; the value is used for every replacement.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Variables', Justification = 'Captured by the regex match evaluator that performs replacements.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Variables
    )

    return [regex]::Replace($Text, '\{\{([^}]+)\}\}', {
            param($match)
            $name = $match.Groups[1].Value.Trim()
            if (-not $Variables.Contains($name)) {
                throw "Scenario placeholder '{{$name}}' is not defined in the configuration."
            }
            return [string]$Variables[$name]
        })
}

function ConvertTo-SetupE2eInputText {
    <#
    .SYNOPSIS
        Expands readable key tokens into the bytes a terminal expects.
    .DESCRIPTION
        Supports {ENTER}, {TAB}, {ESC}, {SPACE}, {BACKSPACE}, {DELETE}, arrows,
        {HOME}, {END}, {PGUP} and {PGDN}. Double braces ({{ and }}) emit literal
        braces so typed text can contain them. Unknown tokens throw.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Keys
    )

    $builder = [System.Text.StringBuilder]::new()
    $index = 0
    while ($index -lt $Keys.Length) {
        $character = $Keys[$index]
        if ($character -eq '{' -and $index + 1 -lt $Keys.Length -and $Keys[$index + 1] -eq '{') {
            [void]$builder.Append('{')
            $index += 2
            continue
        }
        if ($character -eq '}' -and $index + 1 -lt $Keys.Length -and $Keys[$index + 1] -eq '}') {
            [void]$builder.Append('}')
            $index += 2
            continue
        }
        if ($character -eq '{') {
            $endIndex = $Keys.IndexOf('}', $index + 1)
            if ($endIndex -lt 0) {
                throw "Unterminated key token in '$Keys'."
            }
            $token = $Keys.Substring($index, $endIndex - $index + 1).ToUpperInvariant()
            if (-not $script:SetupE2eKeySequences.Contains($token)) {
                throw "Unknown key token '$token'. Use {{{{ for a literal brace."
            }
            [void]$builder.Append($script:SetupE2eKeySequences[$token])
            $index = $endIndex + 1
            continue
        }

        [void]$builder.Append($character)
        $index++
    }

    return $builder.ToString()
}

function Get-SetupE2eReadableInput {
    <#
    .SYNOPSIS
        Converts one terminal input fragment into transcript text.
    .DESCRIPTION
        Control bytes and escape sequences become {TOKEN}; printable text is
        returned unchanged. Used for both the keystroke log and the cast input
        events so a reader can see exactly what was typed.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$InputText
    )

    foreach ($token in $script:SetupE2eKeySequences.Keys) {
        if ($script:SetupE2eKeySequences[$token] -ne '' -and $InputText -ceq $script:SetupE2eKeySequences[$token]) {
            return $token
        }
    }

    $builder = [System.Text.StringBuilder]::new()
    foreach ($character in $InputText.ToCharArray()) {
        $code = [int]$character
        if ($code -lt 32 -or $code -eq 127) {
            [void]$builder.Append(('<U+{0:X4}>' -f $code))
        }
        else {
            [void]$builder.Append($character)
        }
    }

    return $builder.ToString()
}

function Get-SetupE2eScenarioSet {
    <#
    .SYNOPSIS
        Loads scenario definitions.
    .DESCRIPTION
        Scenarios are a data file of named hashtables with Provider, Description,
        SetupArguments and Steps. Step actions are Wait, Type, Keys, Capture,
        Assert, Sleep and Note. Validation happens before any terminal starts.
    .OUTPUTS
        System.Collections.IDictionary
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter()][string]$Path
    )

    $resolvedPath = if ([string]::IsNullOrWhiteSpace($Path)) {
        Join-Path $script:SetupE2eScriptRoot 'scenarios.psd1'
    }
    else {
        (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    }

    return Import-PowerShellDataFile -LiteralPath $resolvedPath
}

function Resolve-SetupE2eScenario {
    <#
    .SYNOPSIS
        Returns one validated scenario by name.
    .DESCRIPTION
        Names are matched case-insensitively. Every step must name a supported
        action and the fields that action requires; invalid steps fail before the
        terminal starts so a recording never begins from a broken scenario.
    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter()][System.Collections.IDictionary]$ScenarioSet
    )

    $set = if ($null -ne $ScenarioSet) { $ScenarioSet } else { Get-SetupE2eScenarioSet -Path $ScenarioPath }
    $match = @($set.Keys | Where-Object { $_ -ieq $Name })
    if ($match.Count -eq 0) {
        throw "Unknown setup E2E scenario '$Name'. Known scenarios: $($set.Keys -join ', ')."
    }

    $definition = $set[$match[0]]
    if (-not $definition.Contains('Steps')) {
        throw "Setup E2E scenario '$Name' does not define Steps."
    }

    $supportedActions = @('Wait', 'Type', 'Keys', 'Select', 'AnswerIfPresent', 'Capture', 'Assert', 'Sleep', 'Note')
    $steps = @($definition['Steps'])
    for ($stepIndex = 0; $stepIndex -lt $steps.Count; $stepIndex++) {
        $step = $steps[$stepIndex]
        if ($step -isnot [System.Collections.IDictionary] -or -not $step.Contains('Action')) {
            throw "Scenario '$Name' step $($stepIndex + 1) must be a hashtable with an Action."
        }
        if ($step['Action'] -notin $supportedActions) {
            throw "Scenario '$Name' step $($stepIndex + 1) uses unsupported action '$($step['Action'])'."
        }
        switch ($step['Action']) {
            'Wait' { if (-not $step.Contains('Text')) { throw "Scenario '$Name' step $($stepIndex + 1) Wait requires Text." } }
            'Assert' { if (-not $step.Contains('Text')) { throw "Scenario '$Name' step $($stepIndex + 1) Assert requires Text." } }
            'Type' { if (-not $step.Contains('Text')) { throw "Scenario '$Name' step $($stepIndex + 1) Type requires Text." } }
            'Keys' { if (-not $step.Contains('Keys')) { throw "Scenario '$Name' step $($stepIndex + 1) Keys requires Keys." } }
            'Select' { if (-not $step.Contains('Text')) { throw "Scenario '$Name' step $($stepIndex + 1) Select requires Text." } }
            'AnswerIfPresent' { if (-not $step.Contains('Text')) { throw "Scenario '$Name' step $($stepIndex + 1) AnswerIfPresent requires Text." } }
            'Capture' { if (-not $step.Contains('Label')) { throw "Scenario '$Name' step $($stepIndex + 1) Capture requires Label." } }
            'Note' { if (-not $step.Contains('Text')) { throw "Scenario '$Name' step $($stepIndex + 1) Note requires Text." } }
        }
    }

    return [pscustomobject]@{
        Name           = $match[0]
        Provider       = if ($definition.Contains('Provider')) { [string]$definition['Provider'] } else { '' }
        Description    = if ($definition.Contains('Description')) { [string]$definition['Description'] } else { '' }
        SetupArguments = if ($definition.Contains('SetupArguments')) { [string[]]$definition['SetupArguments'] } else { [string[]]@() }
        Steps          = $steps
    }
}

function Initialize-SetupE2eRunDirectory {
    <#
    .SYNOPSIS
        Creates a unique run directory with its artifact subdirectories.
    .DESCRIPTION
        The directory name is the UTC start time plus the scenario or provider so
        runs sort chronologically. Screens hold prompt snapshots and images holds
        optional rendered PNGs.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Label
    )

    $safeLabel = ($Label -replace '[^A-Za-z0-9._-]', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($safeLabel)) {
        $safeLabel = 'run'
    }
    $runDirectory = Join-Path $Root ((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + '-' + $safeLabel)
    foreach ($subdirectory in @('screens', 'images')) {
        [System.IO.Directory]::CreateDirectory((Join-Path $runDirectory $subdirectory)) | Out-Null
    }

    return $runDirectory
}

function ConvertTo-SetupE2eAnsiFrame {
    <#
    .SYNOPSIS
        Builds ANSI bytes that reproduce a screen state from a previous one.
    .DESCRIPTION
        Only changed lines are rewritten, using absolute cursor positions and
        line clears. A missing or longer previous frame triggers a full clear so
        the cast replays exactly what the terminal showed.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
        [Parameter()][AllowEmptyCollection()][AllowEmptyString()][string[]]$PreviousLines
    )

    $builder = [System.Text.StringBuilder]::new()
    $hasPrevious = $null -ne $PreviousLines -and $PreviousLines.Count -gt 0
    if (-not $hasPrevious) {
        [void]$builder.Append("$([char]27)[2J$([char]27)[H")
    }

    for ($lineIndex = 0; $lineIndex -lt $Lines.Count; $lineIndex++) {
        $line = $Lines[$lineIndex]
        if ($hasPrevious -and $lineIndex -lt $PreviousLines.Count -and $PreviousLines[$lineIndex] -ceq $line) {
            continue
        }

        [void]$builder.Append("$([char]27)[$($lineIndex + 1);1H")
        [void]$builder.Append($line)
        [void]$builder.Append("$([char]27)[K")
    }

    if ($hasPrevious -and $PreviousLines.Count -gt $Lines.Count) {
        for ($lineIndex = $Lines.Count; $lineIndex -lt $PreviousLines.Count; $lineIndex++) {
            [void]$builder.Append("$([char]27)[$($lineIndex + 1);1H$([char]27)[K")
        }
    }

    return $builder.ToString()
}

function Initialize-SetupE2eRecorder {
    <#
    .SYNOPSIS
        Opens the artifacts that record one run.
    .DESCRIPTION
        Writes events.jsonl and an asciinema v2 cast, and keeps the previous frame
        so screen updates stay small. Complete-SetupE2eRecorder closes the writers
        and writes the synchronised transcript.
    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][int]$Columns,
        [Parameter(Mandatory)][int]$Rows,
        [Parameter(Mandatory)][string]$Title
    )

    $eventsWriter = [System.IO.StreamWriter]::new((Join-Path $RunDirectory 'events.jsonl'), $false, [System.Text.UTF8Encoding]::new($false))
    $eventsWriter.AutoFlush = $true
    $castWriter = [System.IO.StreamWriter]::new((Join-Path $RunDirectory 'session.cast'), $false, [System.Text.UTF8Encoding]::new($false))
    $castWriter.AutoFlush = $true

    $header = [ordered]@{
        version         = 2
        width           = $Columns
        height          = $Rows
        timestamp       = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        idle_time_limit = 2
        title           = $Title
        env             = @{ SHELL = '/bin/sh'; TERM = 'xterm-256color' }
    }
    $castWriter.WriteLine(($header | ConvertTo-Json -Compress -Depth 5))

    $recorder = [pscustomobject]@{
        RunDirectory  = $RunDirectory
        Columns       = $Columns
        Rows          = $Rows
        Stopwatch     = [System.Diagnostics.Stopwatch]::StartNew()
        EventsWriter  = $eventsWriter
        CastWriter    = $castWriter
        PreviousLines = [string[]]@()
        Events        = [System.Collections.Generic.List[object]]::new()
        Sequence      = 0
    }
    Add-SetupE2eRecorderEvent -Recorder $recorder -Kind 'start' -Text $Title
    return $recorder
}

function Add-SetupE2eRecorderEvent {
    <#
    .SYNOPSIS
        Appends one synchronised event to the run log.
    .DESCRIPTION
        Events carry the wall clock, elapsed seconds, kind and text. Input events
        also become asciinema input events; notes, captures and assertions stay in
        events.jsonl and the transcript. Text is stored verbatim, so callers must
        not pass secrets.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Recorder,
        [Parameter(Mandatory)][ValidateSet('start', 'input', 'screen', 'note', 'capture', 'assert', 'state', 'end')][string]$Kind,
        [Parameter()][AllowEmptyString()][string]$Text = '',
        [Parameter()][System.Collections.IDictionary]$Data
    )

    $elapsed = [Math]::Round($Recorder.Stopwatch.Elapsed.TotalSeconds, 3)
    $record = [ordered]@{
        ts      = (Get-Date).ToUniversalTime().ToString('o')
        elapsed = $elapsed
        kind    = $Kind
        text    = $Text
    }
    if ($null -ne $Data) {
        $record['data'] = $Data
    }
    $Recorder.EventsWriter.WriteLine(($record | ConvertTo-Json -Compress -Depth 6))
    $Recorder.Events.Add([pscustomobject]$record)

    if ($Kind -eq 'input' -and $Text.Length -gt 0) {
        $castEvent = ConvertTo-Json -Compress -Depth 3 -InputObject @($elapsed, 'i', $Text)
        $Recorder.CastWriter.WriteLine($castEvent)
    }
}

function Add-SetupE2eRecorderScreen {
    <#
    .SYNOPSIS
        Records a screen state when it differs from the previous sample.
    .DESCRIPTION
        Trailing blank lines and trailing spaces are dropped so unrelated redraws
        do not create events. The latest screen is always written to latest.txt so
        an interactive driver can read the current terminal state.
    .OUTPUTS
        System.Boolean
        True when the screen changed and was recorded.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Recorder,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
        [Parameter()][switch]$Force
    )

    $normalized = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $Lines) {
        $normalized.Add($line.TrimEnd())
    }
    while ($normalized.Count -gt 0 -and [string]::IsNullOrWhiteSpace($normalized[$normalized.Count - 1])) {
        $normalized.RemoveAt($normalized.Count - 1)
    }

    $current = [string[]]$normalized.ToArray()
    [System.IO.File]::WriteAllLines((Join-Path $Recorder.RunDirectory 'latest.txt'), $current)
    if (-not $Force -and $current.Count -eq $Recorder.PreviousLines.Count) {
        $unchanged = $true
        for ($lineIndex = 0; $lineIndex -lt $current.Count; $lineIndex++) {
            if ($current[$lineIndex] -cne $Recorder.PreviousLines[$lineIndex]) {
                $unchanged = $false
                break
            }
        }
        if ($unchanged) {
            return $false
        }
    }

    $ansi = ConvertTo-SetupE2eAnsiFrame -Lines $current -PreviousLines $Recorder.PreviousLines
    $elapsed = [Math]::Round($Recorder.Stopwatch.Elapsed.TotalSeconds, 3)
    $castEvent = ConvertTo-Json -Compress -Depth 3 -InputObject @($elapsed, 'o', $ansi)
    $Recorder.CastWriter.WriteLine($castEvent)
    Add-SetupE2eRecorderEvent -Recorder $Recorder -Kind 'screen' -Text ($current -join [Environment]::NewLine) -Data @{ lines = $current.Count }
    $Recorder.PreviousLines = $current
    return $true
}

function Complete-SetupE2eRecorder {
    <#
    .SYNOPSIS
        Closes the run artifacts and writes the synchronised transcript.
    .DESCRIPTION
        Writes transcript.md from the recorded events, including each input, note,
        capture and assertion against its elapsed time, and closes the cast and
        event writers. Safe to call once per recorder.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Recorder,
        [Parameter()][AllowEmptyString()][string]$Outcome = '',
        [Parameter()][AllowNull()][System.Nullable[int]]$ExitCode
    )

    Add-SetupE2eRecorderEvent -Recorder $Recorder -Kind 'end' -Text $Outcome -Data @{ exitCode = $ExitCode }
    $Recorder.EventsWriter.Dispose()
    $Recorder.CastWriter.Dispose()

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.AppendLine("# Setup E2E session: $([System.IO.Path]::GetFileName($Recorder.RunDirectory))")
    [void]$builder.AppendLine()
    [void]$builder.AppendLine("Recorded $(Get-Date -Format 'u'). Replay the session with any asciinema v2 player: session.cast.")
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('| Elapsed (s) | Event | Detail |')
    [void]$builder.AppendLine('| ---: | --- | --- |')
    foreach ($recordedEvent in $Recorder.Events) {
        if ($recordedEvent.kind -eq 'screen') {
            continue
        }
        $detail = ([string]$recordedEvent.text) -replace '\|', '\|'
        if ($recordedEvent.kind -eq 'input') {
            $detail = '`' + $detail + '`'
        }
        [void]$builder.AppendLine(('| {0:0.000} | {1} | {2} |' -f $recordedEvent.elapsed, $recordedEvent.kind, $detail))
    }
    if (-not [string]::IsNullOrWhiteSpace($Outcome)) {
        [void]$builder.AppendLine()
        [void]$builder.AppendLine("Outcome: $Outcome")
    }

    [System.IO.File]::WriteAllText((Join-Path $Recorder.RunDirectory 'transcript.md'), $builder.ToString())
}

function Get-SetupE2eScreen {
    <#
    .SYNOPSIS
        Returns the currently rendered terminal lines.
    .DESCRIPTION
        Drains queued UI work first so the returned screen reflects all pending
        PTY output, then records the state when it changed.
    .OUTPUTS
        System.String[]
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session
    )

    # Tests and other non-Avalonia hosts supply ReadScreen so the engine can run
    # without the headless terminal; live sessions read the rendered control.
    if ($Session.PSObject.Properties['ReadScreen'] -and $null -ne $Session.ReadScreen) {
        $lines = @(& $Session.ReadScreen)
    }
    else {
        Invoke-CaptureDispatcherQueue
        $lines = @($Session.Terminal.ReadScreenText())
    }
    [void](Add-SetupE2eRecorderScreen -Recorder $Session.Recorder -Lines $lines)
    return $lines
}

function Get-SetupE2eScrollback {
    <#
    .SYNOPSIS
        Returns the visible screen plus recent scrollback.
    .DESCRIPTION
        Error panels and long output can scroll past the visible screen, which
        hides the message that explains a failure. The terminal keeps scrollback
        when the harness raises its capacity, so recordings and snapshots can
        keep the complete text.
    .OUTPUTS
        System.String[]
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter()][int]$ScrollbackLines = 500
    )

    if ($Session.PSObject.Properties['ReadScreen'] -and $null -ne $Session.ReadScreen) {
        return @(& $Session.ReadScreen)
    }

    Invoke-CaptureDispatcherQueue
    return @($Session.Terminal.ReadScreenText($ScrollbackLines))
}

function Wait-SetupE2eScreenText {
    <#
    .SYNOPSIS
        Waits for text to appear on the terminal, or for the process to exit.
    .DESCRIPTION
        Samples the screen and records state changes until the expected ordinal
        text appears. On timeout the visible screen is included in the error so a
        failed scenario shows what the operator would have seen. UntilExit waits
        for the child process instead and returns whatever is on screen.
    .OUTPUTS
        System.String[]
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter()][AllowEmptyString()][string]$Text = '',
        [Parameter()][int]$TimeoutSeconds = 180,
        [Parameter()][switch]$UntilExit
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastLines = @()
    while ([DateTime]::UtcNow -lt $deadline) {
        $lastLines = Get-SetupE2eScreen -Session $Session
        if ($UntilExit -and -not $Session.Terminal.IsRunning) {
            return $lastLines
        }
        if (-not $UntilExit -and $Text.Length -gt 0 -and ($lastLines -join [Environment]::NewLine).Contains($Text, [StringComparison]::Ordinal)) {
            return $lastLines
        }
        Start-Sleep -Milliseconds $Session.ScreenPollMilliseconds
    }

    $tail = ($lastLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 25) -join [Environment]::NewLine
    if ($UntilExit) {
        throw "Timed out after $TimeoutSeconds seconds waiting for the process to exit. Current screen:$([Environment]::NewLine)$tail"
    }
    throw "Timed out after $TimeoutSeconds seconds waiting for '$Text'. Current screen:$([Environment]::NewLine)$tail"
}

function Send-SetupE2eInput {
    <#
    .SYNOPSIS
        Sends terminal input and records each keystroke.
    .DESCRIPTION
        Arrow and control sequences stay atomic while typed text is sent one
        character at a time so the recording shows an operator-like typing pace.
        Every fragment is written to events.jsonl and the cast input stream.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][AllowEmptyString()][string]$InputText,
        [Parameter()][int]$TypingDelayMilliseconds = 30
    )

    foreach ($inputAction in @(Get-CaptureInputAction -InputText $InputText)) {
        if (-not $Session.Terminal.SendText($inputAction.InputText)) {
            throw 'The terminal refused input; the setup process may have exited.'
        }
        Add-SetupE2eRecorderEvent -Recorder $Session.Recorder -Kind 'input' -Text (Get-SetupE2eReadableInput -InputText $inputAction.InputText)
        if ($inputAction.IsTypingCharacter) {
            Start-Sleep -Milliseconds $TypingDelayMilliseconds
        }
        [void](Get-SetupE2eScreen -Session $Session)
    }
}

function Write-SetupE2eHtmlViewer {
    <#
    .SYNOPSIS
        Builds a self-contained HTML replay from a recorded run directory.
    .DESCRIPTION
        Renders the captured terminal screens as a scrollable timeline with a
        scrubber, play/pause controls and the synchronised input transcript. The
        page embeds all data and needs no network access, so a recording that
        contains organization or environment names stays on the workstation.
    .OUTPUTS
        System.String
        The written HTML path.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter()][string]$OutputPath = ''
    )

    $eventsPath = Join-Path $RunDirectory 'events.jsonl'
    if (-not (Test-Path -LiteralPath $eventsPath -PathType Leaf)) {
        throw "Run directory '$RunDirectory' has no events.jsonl."
    }

    $frames = [System.Collections.Generic.List[object]]::new()
    $inputs = [System.Collections.Generic.List[object]]::new()
    $lastScreen = $null
    $mergedTyping = $false
    foreach ($line in [System.IO.File]::ReadAllLines($eventsPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $recordedEvent = $line | ConvertFrom-Json
        if ($recordedEvent.kind -eq 'input') {
            $inputText = [string]$recordedEvent.text
            $inputTime = [double]$recordedEvent.elapsed
            $isPrintableCharacter = $inputText.Length -eq 1 -and -not [char]::IsControl($inputText[0])
            if (
                $isPrintableCharacter -and
                $inputs.Count -gt 0 -and
                $mergedTyping -and
                ($inputTime - $inputs[$inputs.Count - 1].t) -le 1
            ) {
                # Typing is recorded one character at a time; present it as one entry.
                $inputs[$inputs.Count - 1].text = [string]$inputs[$inputs.Count - 1].text + $inputText
            }
            else {
                $inputs.Add([ordered]@{ t = $inputTime; text = $inputText })
            }
            $mergedTyping = $isPrintableCharacter
            continue
        }
        if ($recordedEvent.kind -ne 'screen') { continue }
        $text = [string]$recordedEvent.text
        if ([string]::IsNullOrWhiteSpace($text) -or $text -ceq $lastScreen) { continue }
        $lastScreen = $text
        $frames.Add([ordered]@{ t = [double]$recordedEvent.elapsed; text = $text })
    }

    if ($frames.Count -eq 0) {
        throw "Run directory '$RunDirectory' has no screen frames to display."
    }

    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $OutputPath = Join-Path $RunDirectory 'viewer.html'
    }

    $framesJson = ConvertTo-Json -InputObject $frames.ToArray() -Depth 4 -Compress
    $inputsJson = ConvertTo-Json -InputObject $inputs.ToArray() -Depth 4 -Compress
    # A literal closing script tag inside embedded JSON would end the script block.
    $framesJson = $framesJson.Replace('</', '<\/')
    $inputsJson = $inputsJson.Replace('</', '<\/')
    $title = [System.Net.WebUtility]::HtmlEncode((Split-Path $RunDirectory -Leaf))

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Setup recording - $title</title>
<style>
:root { color-scheme: dark; }
body { margin: 0; background: #101418; color: #d7dde3; font-family: ui-sans-serif, system-ui, sans-serif; }
header { padding: 1rem 1.25rem .5rem; }
h1 { font-size: 1.1rem; margin: 0 0 .25rem; font-weight: 600; }
p.meta { margin: 0; color: #8b98a5; font-size: .85rem; }
.controls { display: flex; gap: .75rem; align-items: center; flex-wrap: wrap; padding: .75rem 1.25rem; }
button, select { background: #1c2530; color: #d7dde3; border: 1px solid #33404d; border-radius: 6px; padding: .35rem .7rem; font: inherit; cursor: pointer; }
button:hover { background: #26323f; }
input[type=range] { flex: 1 1 18rem; accent-color: #4aa8ff; }
.time { font-variant-numeric: tabular-nums; color: #8b98a5; min-width: 7rem; text-align: right; }
main { display: grid; grid-template-columns: minmax(0, 3fr) minmax(16rem, 1fr); gap: 1rem; padding: 0 1.25rem 1.25rem; }
pre.screen { margin: 0; padding: 1rem; background: #0b0f13; border: 1px solid #1f2933; border-radius: 8px; overflow: auto; font-family: "Cascadia Mono", "DejaVu Sans Mono", Consolas, monospace; font-size: 12px; line-height: 1.22; min-height: 60vh; max-height: 80vh; white-space: pre; }
aside { background: #0f151b; border: 1px solid #1f2933; border-radius: 8px; padding: .75rem; max-height: 80vh; overflow: auto; }
aside h2 { font-size: .8rem; text-transform: uppercase; letter-spacing: .06em; color: #8b98a5; margin: 0 0 .5rem; }
ol { list-style: none; margin: 0; padding: 0; font-family: "Cascadia Mono", "DejaVu Sans Mono", Consolas, monospace; font-size: .78rem; }
li { padding: .18rem .3rem; border-radius: 4px; cursor: pointer; color: #aab6c2; }
li:hover { background: #1b2530; }
li.active { background: #23405c; color: #eaf3ff; }
li .stamp { color: #6f7d8a; margin-right: .5rem; }
.kbd { color: #ffd479; }
@media (max-width: 900px) { main { grid-template-columns: 1fr; } }
</style>
</head>
<body>
<header>
  <h1>ALM4Dataverse setup recording</h1>
  <p class="meta">$title &middot; rendered from captured terminal frames; no network access required.</p>
</header>
<div class="controls">
  <button id="play">Pause</button>
  <button id="restart">Restart</button>
  <select id="speed" title="Playback speed">
    <option value="1">1x</option>
    <option value="2">2x</option>
    <option value="4">4x</option>
    <option value="8">8x</option>
  </select>
  <input id="scrub" type="range" min="0" max="1000" value="0" step="1">
  <span class="time" id="clock">0:00 / 0:00</span>
</div>
<main>
  <pre class="screen" id="screen"></pre>
  <aside>
    <h2>Inputs</h2>
    <ol id="inputs"></ol>
  </aside>
</main>
<script id="frames" type="application/json">$framesJson</script>
<script id="inputs-data" type="application/json">$inputsJson</script>
<script>
const frames = JSON.parse(document.getElementById('frames').textContent);
const inputs = JSON.parse(document.getElementById('inputs-data').textContent);
const maxT = frames[frames.length - 1].t;
let index = 0;
let position = 0;
let playing = true;
let speed = 1;
let lastTick = 0;
const screen = document.getElementById('screen');
const scrub = document.getElementById('scrub');
const clock = document.getElementById('clock');
const playButton = document.getElementById('play');
const list = document.getElementById('inputs');

function fmt(seconds) {
  const total = Math.max(0, Math.round(seconds));
  return Math.floor(total / 60) + ':' + String(total % 60).padStart(2, '0');
}
function applyFrame(at) {
  let low = 0, high = frames.length - 1;
  while (low < high) {
    const mid = Math.ceil((low + high) / 2);
    if (frames[mid].t <= at) low = mid; else high = mid - 1;
  }
  index = low;
  screen.textContent = frames[index].text;
}
function highlightInput(at) {
  let active = null;
  for (const li of list.children) {
    li.classList.remove('active');
    if (Number(li.dataset.t) <= at + 0.001) active = li;
  }
  if (active) {
    active.classList.add('active');
    if (playing) active.scrollIntoView({ block: 'nearest' });
  }
}
function render(at) {
  position = Math.min(maxT, Math.max(0, at));
  applyFrame(position);
  highlightInput(position);
  scrub.value = maxT === 0 ? 0 : Math.round(position / maxT * 1000);
  clock.textContent = fmt(position) + ' / ' + fmt(maxT);
}
for (const input of inputs) {
  const li = document.createElement('li');
  li.dataset.t = input.t;
  const stamp = document.createElement('span');
  stamp.className = 'stamp';
  stamp.textContent = fmt(input.t);
  const key = document.createElement('span');
  key.className = 'kbd';
  key.textContent = input.text;
  li.append(stamp, key);
  li.addEventListener('click', () => { setPlaying(false); render(input.t); });
  list.append(li);
}
function setPlaying(value) {
  playing = value;
  playButton.textContent = playing ? 'Pause' : 'Play';
  lastTick = performance.now();
}
playButton.addEventListener('click', () => {
  if (!playing && position >= maxT) { render(0); }
  setPlaying(!playing);
});
document.getElementById('restart').addEventListener('click', () => { setPlaying(false); render(0); });
scrub.addEventListener('input', () => { setPlaying(false); render(scrub.value / 1000 * maxT); });
document.getElementById('speed').addEventListener('change', event => { speed = Number(event.target.value); });
function tick(now) {
  if (playing) {
    if (!lastTick) lastTick = now;
    position += ((now - lastTick) / 1000) * speed;
    lastTick = now;
    if (position >= maxT) { position = maxT; setPlaying(false); }
    render(position);
  } else {
    lastTick = now;
  }
  requestAnimationFrame(tick);
}
render(position);
requestAnimationFrame(tick);
</script>
</body>
</html>
"@

    [System.IO.File]::WriteAllText($OutputPath, $html)
    return $OutputPath
}

function Invoke-SetupE2eCapture {
    <#
    .SYNOPSIS
        Writes the current screen as a labelled text snapshot.
    .DESCRIPTION
        Snapshots are numbered so they sort in capture order. With CaptureImages
        the rendered window is also saved as a PNG; otherwise only text is kept.
    .OUTPUTS
        System.String
        The written text snapshot path.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][string]$Label,
        [Parameter()][switch]$CaptureImage
    )

    $lines = Get-SetupE2eScrollback -Session $Session
    $Session.Recorder.Sequence++
    $safeLabel = ($Label -replace '[^A-Za-z0-9._-]', '-').Trim('-')
    $fileName = '{0:D3}-{1}' -f $Session.Recorder.Sequence, $safeLabel
    $snapshotPath = Join-Path (Join-Path $Session.Recorder.RunDirectory 'screens') ($fileName + '.txt')
    [System.IO.File]::WriteAllLines($snapshotPath, $lines)

    if ($CaptureImage) {
        $imagePath = Join-Path (Join-Path $Session.Recorder.RunDirectory 'images') ($fileName + '.png')
        Save-CaptureFrame -Window $Session.Window -OutputPath $imagePath
    }

    Add-SetupE2eRecorderEvent -Recorder $Session.Recorder -Kind 'capture' -Text $Label -Data @{ snapshot = 'screens/' + $fileName + '.txt' }
    return $snapshotPath
}

function Select-SetupE2eMenuItem {
    <#
    .SYNOPSIS
        Moves a terminal menu highlight to an item and activates it.
    .DESCRIPTION
        A recorded scenario cannot rely on list order because repositories,
        environments and solutions differ per organization. Searchable menus are
        narrowed with their filter so the target does not depend on walking a long
        list while the terminal repaints. Other menus move the highlight with Down.
        Throws when the item never becomes highlighted so a scenario cannot silently
        activate the wrong menu entry.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][string]$Text,
        [Parameter()][ValidateRange(1, 500)][int]$MaxSteps = 80,
        [Parameter()][ValidateRange(0, 5000)][int]$SettleMilliseconds = 150,
        [Parameter()][ValidateRange(1, 600)][int]$TimeoutSeconds = 60
    )

    $escaped = [regex]::Escape($Text)
    $selectedPattern = '^\s*>\s+.*' + $escaped
    $downKeys = ConvertTo-SetupE2eInputText -Keys '{DOWN}'
    $backspaceKey = [string][char]127
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $navigated = 0
    $filterState = 'None'
    while ([DateTime]::UtcNow -lt $deadline) {
        $lines = @(Get-SetupE2eScreen -Session $Session)
        if (@($lines | Where-Object { $_ -match $selectedPattern }).Count -gt 0) {
            Send-SetupE2eInput -Session $Session -InputText (ConvertTo-SetupE2eInputText -Keys '{ENTER}')
            return $true
        }

        $hasMenuSelection = @($lines | Where-Object { $_ -match '^\s*>\s' }).Count -gt 0
        $targetOnScreen = @($lines | Where-Object { $_ -match $escaped }).Count -gt 0
        $searchable = @($lines | Where-Object { $_ -match 'Start typing to filter options|Type=filter' }).Count -gt 0

        # Filter only after the menu and the target have rendered. The filter redraws
        # one short list, so the final Enter has much less redraw lag than repeated Down
        # presses on a long menu with branch and environment sub-items.
        if ($filterState -eq 'None' -and $searchable -and $hasMenuSelection -and $targetOnScreen) {
            Send-SetupE2eInput -Session $Session -InputText $Text
            $filterState = 'Filtered'
            if ($SettleMilliseconds -gt 0) {
                Start-Sleep -Milliseconds $SettleMilliseconds
            }
            continue
        }

        # A filter can hide the target because the menu searches labels, not the text
        # typed for a parent prompt. Clear it and fall back to the visible list.
        if ($filterState -eq 'Filtered' -and -not $targetOnScreen) {
            for ($backspaceIndex = 0; $backspaceIndex -lt $Text.Length; $backspaceIndex++) {
                Send-SetupE2eInput -Session $Session -InputText $backspaceKey
            }
            $filterState = 'Cleared'
            if ($SettleMilliseconds -gt 0) {
                Start-Sleep -Milliseconds $SettleMilliseconds
            }
            continue
        }

        # Only navigate once the item is on screen and a menu highlight exists.
        # Pressing Down while an unrelated prompt is still rendering walks the wrong
        # menu and can activate anything; prompt text can also contain item words.
        if ($hasMenuSelection -and $targetOnScreen) {
            if ($navigated -ge $MaxSteps) {
                throw "Menu item '$Text' was not highlighted after $navigated navigation steps."
            }
            Send-SetupE2eInput -Session $Session -InputText $downKeys
            $navigated++
        }

        if ($SettleMilliseconds -gt 0) {
            Start-Sleep -Milliseconds $SettleMilliseconds
        }
    }

    throw "Menu item '$Text' did not appear within $TimeoutSeconds seconds."
}

function Invoke-SetupE2eSequence {
    <#
    .SYNOPSIS
        Executes scenario steps against a live session.
    .DESCRIPTION
        Wait and Assert sample until their text appears; Assert reports its label
        in the failure. Type, Keys and Select expand configuration placeholders
        first. Select moves the menu highlight to the item whose visible text
        matches, then activates it. Sleep and Note never touch the terminal.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][object[]]$Steps,
        [Parameter()][System.Collections.IDictionary]$Variables = @{}
    )

    foreach ($step in $Steps) {
        $action = [string]$step['Action']
        switch ($action) {
            'Wait' {
                $timeout = if ($step.Contains('TimeoutSeconds')) { [int]$step['TimeoutSeconds'] } else { 180 }
                [void](Wait-SetupE2eScreenText -Session $Session -Text (Expand-SetupE2ePlaceholder -Text ([string]$step['Text']) -Variables $Variables) -TimeoutSeconds $timeout)
            }
            'Assert' {
                $timeout = if ($step.Contains('TimeoutSeconds')) { [int]$step['TimeoutSeconds'] } else { 60 }
                Add-SetupE2eRecorderEvent -Recorder $Session.Recorder -Kind 'assert' -Text ([string]$step['Text'])
                [void](Wait-SetupE2eScreenText -Session $Session -Text (Expand-SetupE2ePlaceholder -Text ([string]$step['Text']) -Variables $Variables) -TimeoutSeconds $timeout)
            }
            'Type' {
                $text = Expand-SetupE2ePlaceholder -Text ([string]$step['Text']) -Variables $Variables
                $delay = if ($step.Contains('TypingDelayMilliseconds')) { [int]$step['TypingDelayMilliseconds'] } else { 30 }
                Send-SetupE2eInput -Session $Session -InputText $text -TypingDelayMilliseconds $delay
            }
            'Keys' {
                $keys = Expand-SetupE2ePlaceholder -Text ([string]$step['Keys']) -Variables $Variables
                Send-SetupE2eInput -Session $Session -InputText (ConvertTo-SetupE2eInputText -Keys $keys)
            }
            'Select' {
                $menuText = Expand-SetupE2ePlaceholder -Text ([string]$step['Text']) -Variables $Variables
                [void](Select-SetupE2eMenuItem -Session $Session -Text $menuText)
            }
            'AnswerIfPresent' {
                $promptText = Expand-SetupE2ePlaceholder -Text ([string]$step['Text']) -Variables $Variables
                $timeout = if ($step.Contains('TimeoutSeconds')) { [int]$step['TimeoutSeconds'] } else { 15 }
                $promptShown = $false
                try {
                    [void](Wait-SetupE2eScreenText -Session $Session -Text $promptText -TimeoutSeconds $timeout)
                    $promptShown = $true
                }
                catch {
                    if ($_.Exception.Message -notmatch '^Timed out') { throw }
                    Add-SetupE2eRecorderEvent -Recorder $Session.Recorder -Kind 'note' -Text "Optional prompt '$promptText' was not shown; continuing."
                }
                if ($promptShown) {
                    if ($step.Contains('Type')) {
                        $answer = Expand-SetupE2ePlaceholder -Text ([string]$step['Type']) -Variables $Variables
                        Send-SetupE2eInput -Session $Session -InputText $answer
                    }
                    $answerKeys = if ($step.Contains('Keys')) { [string]$step['Keys'] } else { '{ENTER}' }
                    Send-SetupE2eInput -Session $Session -InputText (ConvertTo-SetupE2eInputText -Keys $answerKeys)
                }
            }
            'Capture' {
                [void](Invoke-SetupE2eCapture -Session $Session -Label ([string]$step['Label']) -CaptureImage:$Session.CaptureImages)
            }
            'Sleep' {
                Start-Sleep -Milliseconds ([int]$step['Milliseconds'])
            }
            'Note' {
                Add-SetupE2eRecorderEvent -Recorder $Session.Recorder -Kind 'note' -Text ([string]$step['Text'])
            }
        }
    }
}

function Get-SetupE2eTerminalEnvironment {
    <#
    .SYNOPSIS
        Builds the environment for a live setup process.
    .DESCRIPTION
        A live run needs the caller's real identity context, module paths and
        service tokens, so every process variable is passed through and terminal
        capabilities are added. The screenshot allowlist is deliberately not used
        here because it would hide authentication caches from setup.
    .OUTPUTS
        System.Collections.Generic.Dictionary[string, string]
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.Dictionary[string, string]])]
    param()

    $environment = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($entry in [System.Environment]::GetEnvironmentVariables().GetEnumerator()) {
        if ($null -ne $entry.Key -and $null -ne $entry.Value) {
            $environment[[string]$entry.Key] = [string]$entry.Value
        }
    }
    $environment['TERM'] = 'xterm-256color'
    $environment['COLORTERM'] = 'truecolor'

    return $environment
}

function Write-SetupE2eLauncher {
    <#
    .SYNOPSIS
        Writes the wrapper that runs the setup script and reports its exit.
    .DESCRIPTION
        The wrapper keeps the setup process in the PTY while printing a stable
        SETUP-E2E-EXIT marker that the recorder can read. Setup scripts do not
        call exit, so the wrapper can still report after they return.
    .OUTPUTS
        System.String
        The launcher script path.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$SetupScriptPath,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter()][string[]]$SetupArguments = @()
    )

    $argumentLiterals = @($SetupArguments | ForEach-Object { ConvertTo-PowerShellLiteral -Value $_ }) -join ', '
    $invokeLine = if ($argumentLiterals.Length -gt 0) {
        "& $(ConvertTo-PowerShellLiteral -Value $SetupScriptPath) $argumentLiterals"
    }
    else {
        "& $(ConvertTo-PowerShellLiteral -Value $SetupScriptPath)"
    }

    $content = @"
`$ErrorActionPreference = 'Continue'
Set-Location -LiteralPath $(ConvertTo-PowerShellLiteral -Value $WorkingDirectory)
`$global:LASTEXITCODE = 0
`$setupExitCode = 0
try {
    $invokeLine
}
catch {
    Write-Host ''
    Write-Host ('SETUP-E2E-ERROR: ' + `$_.Exception.Message)
    `$setupExitCode = 1
}
Write-Host ''
Write-Host ('SETUP-E2E-EXIT:' + `$setupExitCode)
Start-Sleep -Seconds 3
exit `$setupExitCode
"@

    $launcherPath = Join-Path $RunDirectory 'launcher.ps1'
    [System.IO.File]::WriteAllText($launcherPath, $content)
    return $launcherPath
}

function Open-SetupE2eSession {
    <#
    .SYNOPSIS
        Starts a recorded terminal session for setup.
    .DESCRIPTION
        Opens the headless terminal window, connects it to a launcher that runs
        the real setup script, and returns the session object used by the engine.
        The caller owns completion via Complete-SetupE2eSession.
    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$SetupScriptPath,
        [Parameter()][string[]]$SetupArguments = @(),
        [Parameter()][int]$Columns = 120,
        [Parameter()][int]$Rows = 50,
        [Parameter()][int]$ScreenPollMilliseconds = 100,
        [Parameter()][switch]$CaptureImages,
        [Parameter()][string]$Title = 'Setup E2E',
        [Parameter()][string]$PowerShellExecutable,
        [Parameter()][string]$ConPtyLibraryPath
    )

    $recorder = Initialize-SetupE2eRecorder -RunDirectory $RunDirectory -Columns $Columns -Rows $Rows -Title $Title
    $launcherPath = Write-SetupE2eLauncher `
        -RunDirectory $RunDirectory `
        -SetupScriptPath $SetupScriptPath `
        -WorkingDirectory $RepositoryRoot `
        -SetupArguments $SetupArguments

    $capture = Open-CaptureTerminalWindow -Rows $Rows -FontFamilyName (Get-CaptureFontFamily -Platform (Get-CapturePlatformName))
    $scrollbackProperty = $capture.Terminal.GetType().GetProperty('ScrollbackCapacity')
    if ($null -ne $scrollbackProperty) {
        $scrollbackProperty.SetValue($capture.Terminal, 5000)
    }
    try {
        $setupPowerShell = if ([string]::IsNullOrWhiteSpace($PowerShellExecutable)) {
            Get-CapturePowerShellExecutable
        }
        else {
            $PowerShellExecutable
        }
        Connect-CaptureTerminal `
            -Terminal $capture.Terminal `
            -Command $setupPowerShell `
            -Arguments @('-NoLogo', '-NoProfile', '-File', $launcherPath) `
            -WorkingDirectory $RepositoryRoot `
            -Environment (Get-SetupE2eTerminalEnvironment) `
            -Columns $Columns `
            -Rows $Rows `
            -RepositoryRoot $RepositoryRoot `
            -ConPtyLibraryPath $ConPtyLibraryPath
    }
    catch {
        $capture.Terminal.Dispose()
        $capture.Window.Close()
        throw
    }

    return [pscustomobject]@{
        Terminal               = $capture.Terminal
        Window                 = $capture.Window
        Recorder               = $recorder
        CaptureImages          = [bool]$CaptureImages
        ScreenPollMilliseconds = $ScreenPollMilliseconds
        RunDirectory           = $RunDirectory
    }
}

function Complete-SetupE2eSession {
    <#
    .SYNOPSIS
        Finishes a session, records the outcome and releases the terminal.
    .DESCRIPTION
        Waits briefly for the launcher to print its exit marker, sends a final
        screen sample, completes the recorder and disposes the window even when
        an earlier step failed. Returns the exit code when it could be read.
    .OUTPUTS
        System.Nullable[int]
    #>
    [CmdletBinding()]
    [OutputType([System.Nullable[int]])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter()][int]$ExitTimeoutSeconds = 15,
        [Parameter()][switch]$Terminate
    )

    $exitCode = $null
    $outcome = ''
    $lines = @()
    try {
        if ($Terminate -and $Session.Terminal.IsRunning) {
            [void]$Session.Terminal.SendText("$([char]3)")
        }

        $deadline = [DateTime]::UtcNow.AddSeconds($ExitTimeoutSeconds)
        while ([DateTime]::UtcNow -lt $deadline) {
            $lines = Get-SetupE2eScreen -Session $Session
            if (-not $Session.Terminal.IsRunning) {
                break
            }
            Start-Sleep -Milliseconds $Session.ScreenPollMilliseconds
        }

        # Reading scrollback goes through the terminal UI dispatcher. Once the child
        # has exited that dispatcher can already be torn down, so keep the last
        # visible screen instead of blocking the whole run during cleanup.
        $allLines = if ($Session.Terminal.IsRunning) {
            Get-SetupE2eScrollback -Session $Session
        }
        else {
            @($lines)
        }
        [System.IO.File]::WriteAllLines((Join-Path $Session.Recorder.RunDirectory 'final.txt'), $allLines)
        $joined = $lines -join [Environment]::NewLine
        $match = [regex]::Match($joined, 'SETUP-E2E-EXIT:(-?\d+)')
        if ($match.Success) {
            $exitCode = [int]$match.Groups[1].Value
        }
        $outcome = if ($null -ne $exitCode -and $exitCode -eq 0) { 'Succeeded' } elseif ($null -ne $exitCode) { "Failed with exit code $exitCode" } else { 'Exit code not reported' }
    }
    finally {
        try {
            Complete-SetupE2eRecorder -Recorder $Session.Recorder -Outcome $outcome -ExitCode $exitCode
        }
        finally {
            $Session.Terminal.Dispose()
            if ($null -ne $Session.Window) {
                $Session.Window.Close()
                if ($Session.Terminal.IsRunning -and -not ($Session.PSObject.Properties['ReadScreen'] -and $null -ne $Session.ReadScreen)) {
                    Invoke-CaptureDispatcherQueue
                }
            }
        }
    }

    return $exitCode
}

function Write-SetupE2eState {
    <#
    .SYNOPSIS
        Writes the interactive state file atomically.
    .DESCRIPTION
        The driver polls state.json to decide the next action. The file is
        replaced through a temporary file so a reader never sees partial JSON.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][string]$Status,
        [Parameter()][int]$ProcessedSequence = 0,
        [Parameter()][string]$Detail = ''
    )

    $state = [ordered]@{
        elapsed           = [Math]::Round($Session.Recorder.Stopwatch.Elapsed.TotalSeconds, 3)
        status            = $Status
        processedSequence = $ProcessedSequence
        running           = [bool]$Session.Terminal.IsRunning
        detail            = $Detail
        updated           = (Get-Date).ToUniversalTime().ToString('o')
    }
    $path = Join-Path $Session.Recorder.RunDirectory 'state.json'
    $temporaryPath = $path + '.tmp'
    [System.IO.File]::WriteAllText($temporaryPath, ($state | ConvertTo-Json -Depth 4))
    [System.IO.File]::Move($temporaryPath, $path, $true)
}

function Read-SetupE2eControlCommand {
    <#
    .SYNOPSIS
        Reads newly appended interactive commands.
    .DESCRIPTION
        control.jsonl is append-only. Reading from the stored byte offset means a
        command is executed once even when the driver appends several at a time.
        Malformed lines fail the run rather than being skipped silently.
    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][ref]$Offset
    )

    $path = Join-Path $RunDirectory 'control.jsonl'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{ Commands = @(); Offset = $Offset.Value }
    }

    $commands = [System.Collections.Generic.List[object]]::new()
    $newOffset = $Offset.Value
    $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        if ($stream.Length -gt $Offset.Value) {
            [void]$stream.Seek($Offset.Value, [System.IO.SeekOrigin]::Begin)
            $reader = [System.IO.StreamReader]::new($stream, [System.Text.UTF8Encoding]::new($false), $false, 4096, $true)
            try {
                $content = $reader.ReadToEnd()
                $newOffset = $stream.Position
            }
            finally {
                $reader.Dispose()
            }

            foreach ($line in ($content -split "`n")) {
                if ([string]::IsNullOrWhiteSpace($line)) {
                    continue
                }
                try {
                    $commands.Add(($line | ConvertFrom-Json -ErrorAction Stop))
                }
                catch {
                    throw "Invalid interactive command '$line': $($_.Exception.Message)"
                }
            }
        }
    }
    finally {
        $stream.Dispose()
    }

    $Offset.Value = $newOffset
    return [pscustomobject]@{ Commands = $commands.ToArray(); Offset = $newOffset }
}

function Invoke-SetupE2eInteractiveSession {
    <#
    .SYNOPSIS
        Runs an interactive session driven by control.jsonl.
    .DESCRIPTION
        Polls the control file for {action, ...} commands and executes them in
        order while continuously sampling the screen. Supported actions are wait,
        type, keys, capture, assert, note, sleep and stop. The loop also ends when
        the setup process exits. state.json reports progress for the driver.
    .OUTPUTS
        System.Nullable[int]
    #>
    [CmdletBinding()]
    [OutputType([System.Nullable[int]])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter()][int]$MaxMinutes = 240
    )

    $offset = 0
    $processedSequence = 0
    $deadline = [DateTime]::UtcNow.AddMinutes($MaxMinutes)
    $stopRequested = $false
    $lastStateWrite = [DateTime]::MinValue

    Write-SetupE2eState -Session $Session -Status 'ready' -ProcessedSequence $processedSequence
    while (-not $stopRequested -and [DateTime]::UtcNow -lt $deadline) {
        [void](Get-SetupE2eScreen -Session $Session)
        $read = Read-SetupE2eControlCommand -RunDirectory $Session.RunDirectory -Offset ([ref]$offset)
        foreach ($command in $read.Commands) {
            $action = [string]$command.action
            switch ($action) {
                'wait' {
                    $timeout = if ($command.PSObject.Properties['timeoutSeconds']) { [int]$command.timeoutSeconds } else { 180 }
                    # A blocking wait would delay corrective input; interactive waits are
                    # short probes and the driver re-reads latest.txt between commands.
                    $timeout = [Math]::Min($timeout, 10)
                    try {
                        [void](Wait-SetupE2eScreenText -Session $Session -Text ([string]$command.text) -TimeoutSeconds $timeout)
                    }
                    catch {
                        # Interactive driving must survive a wrong guess about the next
                        # screen; the driver inspects latest.txt and corrects course.
                        Add-SetupE2eRecorderEvent -Recorder $Session.Recorder -Kind 'note' -Text ('Wait did not find ''' + [string]$command.text + '''; continuing.')
                    }
                }
                'type' {
                    $delay = if ($command.PSObject.Properties['typingDelayMilliseconds']) { [int]$command.typingDelayMilliseconds } else { 30 }
                    Send-SetupE2eInput -Session $Session -InputText ([string]$command.text) -TypingDelayMilliseconds $delay
                }
                'keys' {
                    Send-SetupE2eInput -Session $Session -InputText (ConvertTo-SetupE2eInputText -Keys ([string]$command.keys))
                }
                'select' {
                    [void](Select-SetupE2eMenuItem -Session $Session -Text ([string]$command.text))
                }
                'capture' {
                    [void](Invoke-SetupE2eCapture -Session $Session -Label ([string]$command.label) -CaptureImage:$Session.CaptureImages)
                }
                'assert' {
                    $timeout = if ($command.PSObject.Properties['timeoutSeconds']) { [int]$command.timeoutSeconds } else { 60 }
                    Add-SetupE2eRecorderEvent -Recorder $Session.Recorder -Kind 'assert' -Text ([string]$command.text)
                    try {
                        [void](Wait-SetupE2eScreenText -Session $Session -Text ([string]$command.text) -TimeoutSeconds $timeout)
                    }
                    catch {
                        Add-SetupE2eRecorderEvent -Recorder $Session.Recorder -Kind 'note' -Text ('Assertion did not find ''' + [string]$command.text + '''; continuing.')
                    }
                }
                'note' {
                    Add-SetupE2eRecorderEvent -Recorder $Session.Recorder -Kind 'note' -Text ([string]$command.text)
                }
                'sleep' {
                    Start-Sleep -Milliseconds ([int]$command.milliseconds)
                }
                'stop' {
                    $stopRequested = $true
                }
                default {
                    throw "Unsupported interactive action '$action'."
                }
            }

            if ($command.PSObject.Properties['sequence']) {
                $processedSequence = [int]$command.sequence
            }
            else {
                $processedSequence++
            }
            Write-SetupE2eState -Session $Session -Status 'ready' -ProcessedSequence $processedSequence
            if (-not $Session.Terminal.IsRunning) {
                $stopRequested = $true
                break
            }
        }

        if (-not $Session.Terminal.IsRunning) {
            break
        }
        if (([DateTime]::UtcNow - $lastStateWrite).TotalSeconds -ge 2) {
            Write-SetupE2eState -Session $Session -Status 'running' -ProcessedSequence $processedSequence
            $lastStateWrite = [DateTime]::UtcNow
        }
        Start-Sleep -Milliseconds $Session.ScreenPollMilliseconds
    }

    if (-not $stopRequested -and [DateTime]::UtcNow -ge $deadline) {
        Add-SetupE2eRecorderEvent -Recorder $Session.Recorder -Kind 'note' -Text "Interactive session reached its $MaxMinutes minute limit."
    }

    return Complete-SetupE2eSession -Session $Session -Terminate:$stopRequested
}

if ($MyInvocation.InvocationName -eq '.') {
    return
}

if (-not $Interactive -and -not $ListScenarios -and [string]::IsNullOrWhiteSpace($Scenario)) {
    throw 'Specify -Scenario <name>, -Interactive or -ListScenarios.'
}

$repositoryRoot = Get-RepositoryRoot -StartPath $PSScriptRoot
$scenarioSet = Get-SetupE2eScenarioSet -Path $ScenarioPath

if ($ListScenarios) {
    foreach ($name in $scenarioSet.Keys) {
        $description = if ($scenarioSet[$name].Contains('Description')) { [string]$scenarioSet[$name]['Description'] } else { '' }
        '{0} - {1}' -f $name, $description
    }
    return
}

$config = Import-SetupE2eConfig -Path $ConfigPath
# The pinned Dataverse module loads only on .NET 10 or earlier, so a run can
# point at a portable PowerShell while this harness keeps its current host.
$setupPowerShell = if ($config.Data.Contains('setupPowerShellPath') -and -not [string]::IsNullOrWhiteSpace([string]$config.Data['setupPowerShellPath'])) {
    [string]$config.Data['setupPowerShellPath']
}
else {
    Get-CapturePowerShellExecutable
}
$runRoot = if ([string]::IsNullOrWhiteSpace($RunRoot)) {
    Join-Path $repositoryRoot 'TestResults/setup-e2e'
}
else {
    $RunRoot
}

Assert-CaptureRuntimePrerequisite
$platformName = Get-CapturePlatformName
$architectureName = Get-CaptureArchitecture
$fontFamilyName = Get-CaptureFontFamily -Platform $platformName
$cacheRoot = Get-CaptureCacheRoot -Platform $platformName
$runtimeDirectory = Join-Path $cacheRoot (Join-Path 'runtime' (Join-Path $platformName.ToLowerInvariant() $architectureName))
$runtime = Install-CaptureRuntimeAsset `
    -CacheRoot $cacheRoot `
    -RuntimeDirectory $runtimeDirectory `
    -Platform $platformName `
    -Architecture $architectureName
Initialize-CaptureAvaloniaRuntime -ManagedAssemblyPaths $runtime.ManagedAssemblyPaths -FontFamilyName $fontFamilyName

if ($Interactive) {
    $runDirectory = Initialize-SetupE2eRunDirectory -Root $runRoot -Label "$Provider-interactive"
    $setupScriptPath = Join-Path $repositoryRoot "setup-$Provider.ps1"
    $session = Open-SetupE2eSession `
        -RunDirectory $runDirectory `
        -RepositoryRoot $repositoryRoot `
        -SetupScriptPath $setupScriptPath `
        -SetupArguments $SetupArgument `
        -Columns $Columns `
        -Rows $Rows `
        -ScreenPollMilliseconds $ScreenPollMilliseconds `
        -CaptureImages:$CaptureImages `
        -Title "Interactive $Provider setup" `
        -PowerShellExecutable $setupPowerShell `
        -ConPtyLibraryPath $runtime.ConPtyLibraryPath
    Write-Output "Run directory: $runDirectory"
    Write-Output "Control file: $(Join-Path $runDirectory 'control.jsonl')"
    Write-Output "State file:   $(Join-Path $runDirectory 'state.json')"
    Write-Output "Screen file:  $(Join-Path $runDirectory 'latest.txt')"
    $exitCode = Invoke-SetupE2eInteractiveSession -Session $session
    Write-Output "Setup exit code: $exitCode"
    return
}

$scenarioDefinition = Resolve-SetupE2eScenario -Name $Scenario -ScenarioSet $scenarioSet
$scenarioProvider = if ([string]::IsNullOrWhiteSpace($scenarioDefinition.Provider)) { $Provider } else { $scenarioDefinition.Provider }
$runDirectory = Initialize-SetupE2eRunDirectory -Root $runRoot -Label $Scenario
$setupScriptPath = Join-Path $repositoryRoot "setup-$scenarioProvider.ps1"
$session = Open-SetupE2eSession `
    -RunDirectory $runDirectory `
    -RepositoryRoot $repositoryRoot `
    -SetupScriptPath $setupScriptPath `
    -SetupArguments ($SetupArgument + $scenarioDefinition.SetupArguments) `
    -Columns $Columns `
    -Rows $Rows `
    -ScreenPollMilliseconds $ScreenPollMilliseconds `
    -CaptureImages:$CaptureImages `
    -Title "Scenario $Scenario" `
    -PowerShellExecutable $setupPowerShell `
    -ConPtyLibraryPath $runtime.ConPtyLibraryPath
try {
    Invoke-SetupE2eSequence -Session $session -Steps $scenarioDefinition.Steps -Variables $config.Variables
}
finally {
    $null = Complete-SetupE2eSession -Session $session
}
Write-Output "Run directory: $runDirectory"
