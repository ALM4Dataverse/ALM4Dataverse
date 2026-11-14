function ConvertTo-SetupActivityOutputLine {
    # Converts stream records/plain values into escaped, severity-colored markup.
    # Null/whitespace entries yield null; surrounding whitespace is intentionally lost.
    [CmdletBinding()]
    [OutputType([string])]
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
    <#
    .SYNOPSIS
        Displays the tail of preformatted activity markup in a panel.
    .PARAMETER Lines
        Trusted markup, normally produced by ConvertTo-SetupActivityOutputLine.
        These strings are not escaped again.
    .PARAMETER MaxLines
        Tail entry count, normally positive; embedded newlines are not split or
        counted. Omitted entries are reported and empty output gets a placeholder.
    #>
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
    <#
    .SYNOPSIS
        Runs a callback under a status spinner with optional output capture.
    .PARAMETER ScriptBlock
        Receives Spectre StatusContext, or null when falling back without a spinner.
    .PARAMETER CaptureOutputInPanel
        Merges streams 2-6, displays strings/stream records, and returns only the last
        non-string result object. With no such result returns null. Once execution
        starts it is never retried automatically in this mode; a post-completion
        display failure returns the stored result instead of repeating the operation.
    .DESCRIPTION
        Back/cancellation exceptions propagate. Without capture, other spinner or
        callback failures fall back to running ScriptBlock with null, which can
        repeat side effects; callers needing at-most-once execution should not rely
        on the uncaptured fallback as a transaction boundary.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'context', Justification = 'Status-context callback argument forwarded into the nested captured-output script block.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [Parameter()][switch]$CaptureOutputInPanel
    )

    Initialize-SpectreConsole

    $statusExecutionState = @{
        Started = $false
        Completed = $false
        Result = $null
    }

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

                $statusExecutionState.Started = $true
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

                $statusExecutionState.Completed = $true
                $statusExecutionState.Result = $capturedResult
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

        if ($CaptureOutputInPanel -and ($statusExecutionState.Started -or $statusExecutionState.Completed)) {
            if ($statusExecutionState.Completed) {
                return $statusExecutionState.Result
            }

            throw
        }

        return & $ScriptBlock $null
    }
}

function Invoke-WithErrorHandling {
    <#
    .SYNOPSIS
        Offers interactive retry, optional skip, or abort after an operation error.
    .DESCRIPTION
        Returns operation output or null when skipped. Retry invokes the operation
        again without rollback, so partial side effects must be handled by callers.
        Back/cancellation exceptions bypass the error menu. Abort or a cancelled
        menu throws a setup-aborted error. When a .NET callback wraps a PowerShell
        failure, the innermost error and its source location are shown when available.
    .PARAMETER StatusMessage
        Nonblank enables Invoke-WithSpectreStatus and its callback/output semantics;
        blank invokes ScriptBlock directly with no positional arguments.
    #>
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

            $innerException = $_.Exception.InnerException
            while ($null -ne $innerException -and $null -ne $innerException.InnerException) {
                $innerException = $innerException.InnerException
            }
            if ($innerException) {
                $errorLines += "[yellow]Inner Error Type:[/] $(ConvertTo-SpectreMarkupLiteral -Text $innerException.GetType().Name)"
                $errorLines += "[yellow]Inner Error Message:[/] $(ConvertTo-SpectreMarkupLiteral -Text $innerException.Message)"

                $innerInvocationInfo = $null
                $innerStackTrace = $null
                if ($innerException -is [System.Management.Automation.RuntimeException]) {
                    $innerErrorRecord = $innerException.ErrorRecord
                    if ($innerErrorRecord) {
                        $innerInvocationInfo = $innerErrorRecord.InvocationInfo
                        $innerStackTrace = $innerErrorRecord.ScriptStackTrace
                    }
                }
                if ($innerInvocationInfo -and $innerInvocationInfo.PositionMessage) {
                    $errorLines += "[grey]Inner Location:[/] $(ConvertTo-SpectreMarkupLiteral -Text $innerInvocationInfo.PositionMessage.Trim())"
                }
                if (-not $innerStackTrace) {
                    $innerStackTrace = $innerException.StackTrace
                }
                if ($innerStackTrace) {
                    $errorLines += "[grey]Inner Stack Trace:[/] $(ConvertTo-SpectreMarkupLiteral -Text $innerStackTrace.Trim())"
                }
            }

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
                    $script:SetupGuidancePanelVisible = $false
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
    <#
    .SYNOPSIS
        Clears the console and displays completion details and next-step links.
    .PARAMETER NextStepLinks
        URLs as strings, dictionaries or custom objects with Url and optional Label,
        Description or Text (in that precedence). Entries without URLs are skipped.
    .DESCRIPTION
        Summary and link labels are escaped; URLs are trusted markup targets supplied
        by callers, not validated here. This display does not verify setup success.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Heading,
        [Parameter(Mandatory)][string]$AccessLabel,
        [Parameter(Mandatory)][string]$AccessUrl,
        [Parameter()][hashtable]$SummaryValues,
        [Parameter()][array]$NextStepLinks
    )

    Initialize-SpectreConsole
    $script:SetupGuidancePanelVisible = $false
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
