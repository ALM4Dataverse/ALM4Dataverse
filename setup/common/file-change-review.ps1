function Get-SetupRepositoryFileChange {
    <#
    .SYNOPSIS
        Compares generated setup files with the selected repository tree.
    .DESCRIPTION
        Only inspects the supplied relative paths and returns added, modified, and
        deleted text files with their before and after contents.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$PreviewRoot,
        [Parameter(Mandatory)][string[]]$RelativePaths
    )

    foreach ($root in @($RepositoryRoot, $PreviewRoot)) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            throw "Setup comparison root not found: $root"
        }
    }

    $repositoryPrefix = [System.IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $previewPrefix = [System.IO.Path]::GetFullPath($PreviewRoot).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $repositoryFiles = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    $previewFiles = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)

    foreach ($relativeRoot in $RelativePaths) {
        if ([string]::IsNullOrWhiteSpace($relativeRoot) -or
            [System.IO.Path]::IsPathRooted($relativeRoot) -or
            $relativeRoot -match '(^|[\\/])\.\.([\\/]|$)') {
            throw "Invalid setup comparison path: '$relativeRoot'"
        }

        foreach ($rootDefinition in @(
                [pscustomobject]@{ BasePath = $RepositoryRoot; Prefix = $repositoryPrefix; Files = $repositoryFiles }
                [pscustomobject]@{ BasePath = $PreviewRoot; Prefix = $previewPrefix; Files = $previewFiles }
            )) {
            $path = Join-Path $rootDefinition.BasePath $relativeRoot
            $items = if (Test-Path -LiteralPath $path -PathType Leaf) {
                @(Get-Item -LiteralPath $path -ErrorAction Stop)
            }
            elseif (Test-Path -LiteralPath $path -PathType Container) {
                @(Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction Stop)
            }
            else {
                @()
            }

            foreach ($item in $items) {
                $relativePath = $item.FullName.Substring($rootDefinition.Prefix.Length).Replace('\', '/')
                $rootDefinition.Files[$relativePath] = $item.FullName
            }
        }
    }

    $allPaths = @($repositoryFiles.Keys) + @($previewFiles.Keys)
    $changes = [System.Collections.Generic.List[object]]::new()
    foreach ($relativePath in @($allPaths | Sort-Object -Unique -CaseSensitive)) {
        $hasBefore = $repositoryFiles.ContainsKey($relativePath)
        $hasAfter = $previewFiles.ContainsKey($relativePath)
        $beforePath = if ($hasBefore) { $repositoryFiles[$relativePath] } else { $null }
        $afterPath = if ($hasAfter) { $previewFiles[$relativePath] } else { $null }
        $status = if (-not $hasBefore) {
            'Added'
        }
        elseif (-not $hasAfter) {
            'Deleted'
        }
        else {
            $beforeHash = (Get-FileHash -LiteralPath $beforePath -Algorithm SHA256 -ErrorAction Stop).Hash
            $afterHash = (Get-FileHash -LiteralPath $afterPath -Algorithm SHA256 -ErrorAction Stop).Hash
            if ($beforeHash -ceq $afterHash) {
                continue
            }
            'Modified'
        }

        $beforeContent = if ($hasBefore) { [System.IO.File]::ReadAllText($beforePath) } else { $null }
        $afterContent = if ($hasAfter) { [System.IO.File]::ReadAllText($afterPath) } else { $null }
        $changes.Add([pscustomobject]@{
                Path          = $relativePath
                Status        = $status
                BeforeContent = $beforeContent
                AfterContent  = $afterContent
            })
    }

    return $changes.ToArray()
}

function Add-SetupSideBySideChangeBlock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Rows,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$DeletedLines,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AddedLines
    )

    $pairedCount = [Math]::Min($DeletedLines.Count, $AddedLines.Count)
    for ($index = 0; $index -lt $pairedCount; $index++) {
        $Rows.Add([pscustomobject]@{
                Type      = 'Modified'
                LeftText  = $DeletedLines[$index]
                RightText = $AddedLines[$index]
            })
    }

    for ($index = $pairedCount; $index -lt $DeletedLines.Count; $index++) {
        $Rows.Add([pscustomobject]@{
                Type      = 'Deleted'
                LeftText  = $DeletedLines[$index]
                RightText = ''
            })
    }

    for ($index = $pairedCount; $index -lt $AddedLines.Count; $index++) {
        $Rows.Add([pscustomobject]@{
                Type      = 'Added'
                LeftText  = ''
                RightText = $AddedLines[$index]
            })
    }
}

function Get-SetupSideBySideDiffRow {
    <#
    .SYNOPSIS
        Aligns two file contents into side-by-side context and change rows.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter()][AllowNull()][string]$BeforeContent,
        [Parameter()][AllowNull()][string]$AfterContent
    )

    $beforeLines = [string[]]@()
    if ($null -ne $BeforeContent -and $BeforeContent.Length -gt 0) {
        $beforeLines = [System.Text.RegularExpressions.Regex]::Split($BeforeContent, '\r\n|\n|\r')
    }
    $afterLines = [string[]]@()
    if ($null -ne $AfterContent -and $AfterContent.Length -gt 0) {
        $afterLines = [System.Text.RegularExpressions.Regex]::Split($AfterContent, '\r\n|\n|\r')
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    $prefixCount = 0
    while (
        $prefixCount -lt $beforeLines.Count -and
        $prefixCount -lt $afterLines.Count -and
        [string]::Equals($beforeLines[$prefixCount], $afterLines[$prefixCount], [StringComparison]::Ordinal)
    ) {
        $rows.Add([pscustomobject]@{
                Type      = 'Context'
                LeftText  = $beforeLines[$prefixCount]
                RightText = $afterLines[$prefixCount]
            })
        $prefixCount++
    }

    $suffixCount = 0
    while (
        $suffixCount -lt ($beforeLines.Count - $prefixCount) -and
        $suffixCount -lt ($afterLines.Count - $prefixCount) -and
        [string]::Equals(
            $beforeLines[$beforeLines.Count - $suffixCount - 1],
            $afterLines[$afterLines.Count - $suffixCount - 1],
            [StringComparison]::Ordinal
        )
    ) {
        $suffixCount++
    }

    $beforeMiddleCount = $beforeLines.Count - $prefixCount - $suffixCount
    $afterMiddleCount = $afterLines.Count - $prefixCount - $suffixCount
    $matrixCellCount = ([long]$beforeMiddleCount + 1) * ([long]$afterMiddleCount + 1)
    if ($matrixCellCount -le 4000000) {
        $lengths = [int[,]]::new($beforeMiddleCount + 1, $afterMiddleCount + 1)
        for ($beforeIndex = $beforeMiddleCount - 1; $beforeIndex -ge 0; $beforeIndex--) {
            for ($afterIndex = $afterMiddleCount - 1; $afterIndex -ge 0; $afterIndex--) {
                $beforeLine = $beforeLines[$prefixCount + $beforeIndex]
                $afterLine = $afterLines[$prefixCount + $afterIndex]
                if ([string]::Equals($beforeLine, $afterLine, [StringComparison]::Ordinal)) {
                    $lengths[$beforeIndex, $afterIndex] = $lengths[($beforeIndex + 1), ($afterIndex + 1)] + 1
                }
                else {
                    $lengths[$beforeIndex, $afterIndex] = [Math]::Max(
                        $lengths[($beforeIndex + 1), $afterIndex],
                        $lengths[$beforeIndex, ($afterIndex + 1)]
                    )
                }
            }
        }

        $operations = [System.Collections.Generic.List[object]]::new()
        $beforeIndex = 0
        $afterIndex = 0
        while ($beforeIndex -lt $beforeMiddleCount -or $afterIndex -lt $afterMiddleCount) {
            if (
                $beforeIndex -lt $beforeMiddleCount -and
                $afterIndex -lt $afterMiddleCount -and
                [string]::Equals(
                    $beforeLines[$prefixCount + $beforeIndex],
                    $afterLines[$prefixCount + $afterIndex],
                    [StringComparison]::Ordinal
                )
            ) {
                $operations.Add([pscustomobject]@{
                        Type      = 'Context'
                        LeftText  = $beforeLines[$prefixCount + $beforeIndex]
                        RightText = $afterLines[$prefixCount + $afterIndex]
                    })
                $beforeIndex++
                $afterIndex++
            }
            elseif (
                $afterIndex -lt $afterMiddleCount -and
                (
                    $beforeIndex -ge $beforeMiddleCount -or
                    $lengths[$beforeIndex, ($afterIndex + 1)] -ge $lengths[($beforeIndex + 1), $afterIndex]
                )
            ) {
                $operations.Add([pscustomobject]@{
                        Type      = 'Added'
                        LeftText  = ''
                        RightText = $afterLines[$prefixCount + $afterIndex]
                    })
                $afterIndex++
            }
            else {
                $operations.Add([pscustomobject]@{
                        Type      = 'Deleted'
                        LeftText  = $beforeLines[$prefixCount + $beforeIndex]
                        RightText = ''
                    })
                $beforeIndex++
            }
        }

        $deletedLines = [System.Collections.Generic.List[string]]::new()
        $addedLines = [System.Collections.Generic.List[string]]::new()
        foreach ($operation in $operations) {
            if ($operation.Type -eq 'Context') {
                Add-SetupSideBySideChangeBlock -Rows $rows -DeletedLines $deletedLines.ToArray() -AddedLines $addedLines.ToArray()
                $deletedLines.Clear()
                $addedLines.Clear()
                $rows.Add($operation)
            }
            elseif ($operation.Type -eq 'Deleted') {
                $deletedLines.Add([string]$operation.LeftText)
            }
            else {
                $addedLines.Add([string]$operation.RightText)
            }
        }
        Add-SetupSideBySideChangeBlock -Rows $rows -DeletedLines $deletedLines.ToArray() -AddedLines $addedLines.ToArray()
    }
    else {
        $deletedLines = [string[]]@()
        if ($beforeMiddleCount -gt 0) {
            $deletedLines = $beforeLines[$prefixCount..($prefixCount + $beforeMiddleCount - 1)]
        }
        $addedLines = [string[]]@()
        if ($afterMiddleCount -gt 0) {
            $addedLines = $afterLines[$prefixCount..($prefixCount + $afterMiddleCount - 1)]
        }
        Add-SetupSideBySideChangeBlock -Rows $rows -DeletedLines $deletedLines -AddedLines $addedLines
    }

    for ($suffixIndex = $suffixCount; $suffixIndex -gt 0; $suffixIndex--) {
        $beforeLine = $beforeLines[$beforeLines.Count - $suffixIndex]
        $afterLine = $afterLines[$afterLines.Count - $suffixIndex]
        $rows.Add([pscustomobject]@{
                Type      = 'Context'
                LeftText  = $beforeLine
                RightText = $afterLine
            })
    }

    return $rows.ToArray()
}

function Get-SetupDiffTextSegment {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter()][AllowEmptyString()][string]$Text = '',
        [Parameter(Mandatory)][ValidateRange(1, 10000)][int]$Width
    )

    $expandedText = $Text.Replace("`t", '    ')
    $segments = [System.Collections.Generic.List[string]]::new()
    if ($expandedText.Length -eq 0) {
        $segments.Add('')
    }
    else {
        for ($offset = 0; $offset -lt $expandedText.Length; $offset += $Width) {
            $segmentLength = [Math]::Min($Width, $expandedText.Length - $offset)
            $segments.Add($expandedText.Substring($offset, $segmentLength))
        }
    }

    return $segments.ToArray()
}

function Read-SetupDiffViewerKey {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return [string]([Console]::ReadKey($true).Key)
}

function Get-SetupDiffNextStartIndex {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][int]$CurrentStartIndex,
        [Parameter(Mandatory)][int]$PageSize,
        [Parameter(Mandatory)][int]$RowCount,
        [Parameter(Mandatory)][string]$Key
    )

    $maximumStartIndex = [Math]::Max($RowCount - $PageSize, 0)
    switch ($Key) {
        'UpArrow' { return [Math]::Max($CurrentStartIndex - 1, 0) }
        'DownArrow' { return [Math]::Min($CurrentStartIndex + 1, $maximumStartIndex) }
        'PageUp' { return [Math]::Max($CurrentStartIndex - $PageSize, 0) }
        'PageDown' { return [Math]::Min($CurrentStartIndex + $PageSize, $maximumStartIndex) }
        'Home' { return 0 }
        'End' { return $maximumStartIndex }
        default { return [Math]::Min([Math]::Max($CurrentStartIndex, 0), $maximumStartIndex) }
    }
}

function Show-SetupFileChangeSummary {
    [CmdletBinding()]
    param(
        [Parameter()][AllowEmptyCollection()][object[]]$FileChanges = @()
    )

    Initialize-SpectreConsole
    $addedCount = @($FileChanges | Where-Object { $_.Status -eq 'Added' }).Count
    $modifiedCount = @($FileChanges | Where-Object { $_.Status -eq 'Modified' }).Count
    $deletedCount = @($FileChanges | Where-Object { $_.Status -eq 'Deleted' }).Count
    [Spectre.Console.AnsiConsole]::MarkupLine(
        "[bold]Repository files:[/] [green]$addedCount added[/], [yellow]$modifiedCount modified[/], [red]$deletedCount deleted[/]"
    )

    if ($FileChanges.Count -eq 0) {
        [Spectre.Console.AnsiConsole]::MarkupLine('[green]No repository files need changes.[/]')
        return
    }

    foreach ($change in @($FileChanges | Sort-Object Path -CaseSensitive)) {
        $statusColor = switch ($change.Status) {
            'Added' { 'green' }
            'Modified' { 'yellow' }
            'Deleted' { 'red' }
            default { 'grey' }
        }
        $literalPath = ConvertTo-SpectreMarkupLiteral -Text ([string]$change.Path)
        [Spectre.Console.AnsiConsole]::MarkupLine("[$statusColor]$($change.Status): $literalPath[/]")
    }
}

function Show-SetupResourceChangeSummary {
    <#
    .SYNOPSIS
        Lists the external resource changes deferred until setup is applied.
    .DESCRIPTION
        Details are descriptive plans; sensitive credential values must never be included.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowEmptyCollection()][object[]]$ResourceChanges = @(),
        [Parameter()][string]$Note = 'Resources already provisioned earlier to support setup are excluded.'
    )

    Initialize-SpectreConsole
    [Spectre.Console.AnsiConsole]::MarkupLine("[bold]Deferred external resource changes: $($ResourceChanges.Count)[/]")
    if ($ResourceChanges.Count -eq 0) {
        [Spectre.Console.AnsiConsole]::MarkupLine('[green]No external resources will be modified by this operation.[/]')
    }

    for ($index = 0; $index -lt $ResourceChanges.Count; $index++) {
        $change = $ResourceChanges[$index]
        foreach ($propertyName in @('Action', 'Resource', 'Target')) {
            if ($change.PSObject.Properties.Name -notcontains $propertyName -or [string]::IsNullOrWhiteSpace([string]$change.$propertyName)) {
                throw "Resource change at index $index is missing required '$propertyName' text."
            }
        }

        $action = ConvertTo-SpectreMarkupLiteral -Text ([string]$change.Action)
        $resource = ConvertTo-SpectreMarkupLiteral -Text ([string]$change.Resource)
        $target = ConvertTo-SpectreMarkupLiteral -Text ([string]$change.Target)
        [Spectre.Console.AnsiConsole]::MarkupLine("[cyan]$action[/] [bold]$resource[/] [grey]($target)[/]")
        if (-not [string]::IsNullOrWhiteSpace([string]$change.Details)) {
            $details = ConvertTo-SpectreMarkupLiteral -Text ([string]$change.Details)
            [Spectre.Console.AnsiConsole]::MarkupLine("  $details")
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Note)) {
        $noteLiteral = ConvertTo-SpectreMarkupLiteral -Text $Note
        [Spectre.Console.AnsiConsole]::MarkupLine("[grey]$noteLiteral[/]")
    }
}

function Show-SetupSideBySideDiff {
    <#
    .SYNOPSIS
        Displays one file as a colored before/after side-by-side diff.
    .DESCRIPTION
        Interactive terminals support arrow keys, Page Up/Down, Home/End and Q/Esc.
        NoPaging writes the full view once for command-line preview output.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowEmptyCollection()][object[]]$FileChanges = @(),
        [Parameter()][string]$Title = 'Repository file changes',
        [Parameter()][switch]$NoPaging
    )

    if ($FileChanges.Count -gt 1) {
        throw 'The side-by-side diff viewer displays one file at a time.'
    }

    Initialize-SpectreConsole
    if ($FileChanges.Count -eq 0) {
        [Spectre.Console.AnsiConsole]::MarkupLine('[green]No file changes to display.[/]')
        return
    }

    $terminalWidth = 120
    $terminalHeight = 24
    $interactive = $false
    if (-not $NoPaging) {
        try {
            $terminalWidth = [Math]::Max([Console]::WindowWidth, 1)
            $terminalHeight = [Math]::Max([Console]::WindowHeight, 1)
            $interactive = -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected
        }
        catch {
            $interactive = $false
        }
    }
    else {
        try {
            $terminalWidth = [Math]::Max([Console]::WindowWidth, 1)
        }
        catch {
            $terminalWidth = 120
        }
    }

    $columnWidth = [Math]::Max([Math]::Floor(($terminalWidth - 5) / 2), 8)
    $textWidth = [Math]::Max($columnWidth - 2, 1)
    $displayRows = [System.Collections.Generic.List[object]]::new()
    foreach ($change in @($FileChanges | Sort-Object Path -CaseSensitive)) {
        $displayRows.Add([pscustomobject]@{
                Kind   = 'Header'
                Status = [string]$change.Status
                Text   = [string]$change.Path
            })
        $diffRows = @(Get-SetupSideBySideDiffRow -BeforeContent $change.BeforeContent -AfterContent $change.AfterContent)
        $hasTextChanges = @($diffRows | Where-Object { $_.Type -ne 'Context' }).Count -gt 0
        if (-not $hasTextChanges) {
            $notice = if ($change.Status -eq 'Modified') {
                'Text is unchanged; only file encoding or line endings differ.'
            }
            elseif ($change.Status -eq 'Added') {
                '(empty file)'
            }
            else {
                '(empty file)'
            }
            $diffRows = @([pscustomobject]@{
                    Type      = 'Notice'
                    LeftText  = if ($change.Status -eq 'Deleted') { $notice } else { '' }
                    RightText = if ($change.Status -eq 'Deleted') { '' } else { $notice }
                })
        }

        foreach ($diffRow in $diffRows) {
            $leftSegments = @(Get-SetupDiffTextSegment -Text ([string]$diffRow.LeftText) -Width $textWidth)
            $rightSegments = @(Get-SetupDiffTextSegment -Text ([string]$diffRow.RightText) -Width $textWidth)
            $segmentCount = [Math]::Max($leftSegments.Count, $rightSegments.Count)
            for ($segmentIndex = 0; $segmentIndex -lt $segmentCount; $segmentIndex++) {
                $leftSegment = if ($segmentIndex -lt $leftSegments.Count) { $leftSegments[$segmentIndex] } else { '' }
                $rightSegment = if ($segmentIndex -lt $rightSegments.Count) { $rightSegments[$segmentIndex] } else { '' }
                $displayRows.Add([pscustomobject]@{
                        Kind         = 'Diff'
                        Type         = [string]$diffRow.Type
                        LeftText     = [string]$leftSegment
                        RightText    = [string]$rightSegment
                        IsContinuation = ($segmentIndex -gt 0)
                    })
            }
        }
    }

    $pageSize = if ($interactive) { [Math]::Max($terminalHeight - 6, 1) } else { $displayRows.Count }
    $startIndex = 0
    while ($true) {
        if ($interactive) {
            $script:SetupGuidancePanelVisible = $false
            [Spectre.Console.AnsiConsole]::Clear()
        }
        Write-SetupDashboard -Message $Title -IncludeTrailingSpacer
        $titleLiteral = ConvertTo-SpectreMarkupLiteral -Text $Title
        [Spectre.Console.AnsiConsole]::MarkupLine("[bold deepskyblue1]$titleLiteral[/]")
        $leftHeading = ('BEFORE').PadRight($columnWidth)
        [Spectre.Console.AnsiConsole]::MarkupLine("[grey]$leftHeading | AFTER[/]")

        $endIndex = [Math]::Min($startIndex + $pageSize, $displayRows.Count)
        for ($rowIndex = $startIndex; $rowIndex -lt $endIndex; $rowIndex++) {
            $displayRow = $displayRows[$rowIndex]
            if ($displayRow.Kind -eq 'Header') {
                $headerColor = switch ($displayRow.Status) {
                    'Added' { 'green' }
                    'Modified' { 'yellow' }
                    'Deleted' { 'red' }
                    default { 'grey' }
                }
                $literalHeader = ConvertTo-SpectreMarkupLiteral -Text "$($displayRow.Status): $($displayRow.Text)"
                [Spectre.Console.AnsiConsole]::MarkupLine("[$headerColor]$literalHeader[/]")
                continue
            }

            $leftColor = switch ($displayRow.Type) {
                { $_ -in @('Deleted', 'Modified') } { 'red3_1' }
                'Notice' { 'yellow' }
                'Context' { 'grey' }
                default { 'grey' }
            }
            $rightColor = switch ($displayRow.Type) {
                { $_ -in @('Added', 'Modified') } { 'green3_1' }
                'Notice' { 'yellow' }
                'Context' { 'grey' }
                default { 'grey' }
            }
            $leftPrefix = if ($displayRow.IsContinuation) { '  ' } elseif ($displayRow.Type -in @('Deleted', 'Modified')) { '- ' } else { '  ' }
            $rightPrefix = if ($displayRow.IsContinuation) { '  ' } elseif ($displayRow.Type -in @('Added', 'Modified')) { '+ ' } else { '  ' }
            $leftCell = ($leftPrefix + $displayRow.LeftText).PadRight($columnWidth)
            $rightCell = $rightPrefix + $displayRow.RightText
            $leftLiteral = ConvertTo-SpectreMarkupLiteral -Text $leftCell
            $rightLiteral = ConvertTo-SpectreMarkupLiteral -Text $rightCell
            [Spectre.Console.AnsiConsole]::MarkupLine("[$leftColor]$leftLiteral[/] [grey]|[/] [$rightColor]$rightLiteral[/]")
        }

        if (-not $interactive) {
            break
        }

        $firstVisibleRow = $startIndex + 1
        $lastVisibleRow = $endIndex
        [Spectre.Console.AnsiConsole]::MarkupLine(
            "[grey]Rows $firstVisibleRow-$lastVisibleRow of $($displayRows.Count) | Up/Down scroll | PgUp/PgDn page | Home/End | Q/Esc close[/]"
        )
        $key = Read-SetupDiffViewerKey
        if ($key -in @('Q', 'Escape', 'Enter')) {
            break
        }
        $startIndex = Get-SetupDiffNextStartIndex `
            -CurrentStartIndex $startIndex `
            -PageSize $pageSize `
            -RowCount $displayRows.Count `
            -Key $key
    }
}

function Show-SetupChangeReview {
    <#
    .SYNOPSIS
        Shows the setup summary and deferred resource plan, then offers selectable, single-file diffs.
    .DESCRIPTION
        Resource changes describe deferred external mutations and must not contain secrets.
        PreviewOnly uses the same file picker but writes each selected file diff without paging.
        SummaryAction runs synchronously in the caller's scope so it can resolve setup
        helpers and access the current setup-step state.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowEmptyCollection()][object[]]$FileChanges = @(),
        [Parameter()][AllowEmptyCollection()][object[]]$ResourceChanges = @(),
        [Parameter()][string]$ResourceChangeNote = 'Resources already provisioned earlier to support setup are excluded.',
        [Parameter(Mandatory)][scriptblock]$SummaryAction,
        [Parameter()][switch]$PreviewOnly
    )

    while ($true) {
        & $SummaryAction
        Show-SetupResourceChangeSummary -ResourceChanges $ResourceChanges -Note $ResourceChangeNote
        Show-SetupFileChangeSummary -FileChanges $FileChanges
        $repositoryFileChanges = @(
            $FileChanges |
                Where-Object { $_.Path -ine 'alm-config.psd1' } |
                Sort-Object Path -CaseSensitive
        )
        $reviewMenuItems = [System.Collections.Generic.List[string]]::new()
        $reviewMenuItems.Add('View alm-config.psd1 diff')
        foreach ($change in $repositoryFileChanges) {
            $reviewMenuItems.Add("$($change.Status): $($change.Path)")
        }
        $reviewMenuItems.Add('Done reviewing')
        $selection = Select-FromMenu `
            -Title 'Review setup changes' `
            -Items $reviewMenuItems.ToArray() `
            -PromptGuidanceLines @(
                'Each file is listed with its add, modify, or delete status.',
                'Select one file to view its diff; alm-config.psd1 has a separate option.'
            )

        if ($null -eq $selection) {
            throw 'Setup change review was cancelled.'
        }

        switch ($selection) {
            0 {
                $configChanges = @($FileChanges | Where-Object { $_.Path -ieq 'alm-config.psd1' })
                if ($configChanges.Count -eq 0) {
                    Show-SetupSideBySideDiff `
                        -Title 'alm-config.psd1 diff' `
                        -FileChanges @() `
                        -NoPaging:$PreviewOnly
                }
                else {
                    Show-SetupSideBySideDiff `
                        -Title 'alm-config.psd1 diff' `
                        -FileChanges @($configChanges[0]) `
                        -NoPaging:$PreviewOnly
                }
            }
            default {
                $selectedFileIndex = $selection - 1
                if ($selectedFileIndex -lt $repositoryFileChanges.Count) {
                    $selectedChange = $repositoryFileChanges[$selectedFileIndex]
                    Show-SetupSideBySideDiff `
                        -Title "$($selectedChange.Status): $($selectedChange.Path)" `
                        -FileChanges @($selectedChange) `
                        -NoPaging:$PreviewOnly
                }
                elseif ($selection -eq ($repositoryFileChanges.Count + 1)) {
                    return
                }
                else {
                    throw "Unrecognized setup change review selection: $selection"
                }
            }
        }
    }
}

function New-SetupPreviewRoot {
    <#
    .SYNOPSIS
        Creates a temporary tree containing only inputs needed for artifact preview.
    .DESCRIPTION
        Copies the listed existing repository paths while excluding Git metadata.
        The caller owns cleanup of the uniquely named temporary directory.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates a disposable preview tree outside the repository and removes it after display.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$BaseRoot,
        [Parameter(Mandatory)][string[]]$RelativePaths
    )

    if (-not (Test-Path -LiteralPath $BaseRoot -PathType Container)) {
        throw "Setup preview source directory not found: $BaseRoot"
    }

    $previewRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("alm-setup-preview-" + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $previewRoot -Force | Out-Null
    foreach ($relativePath in $RelativePaths) {
        $sourcePath = Join-Path $BaseRoot $relativePath
        if (-not (Test-Path -LiteralPath $sourcePath)) {
            continue
        }

        $destinationPath = Join-Path $previewRoot $relativePath
        $destinationDirectory = Split-Path -Parent $destinationPath
        if (-not (Test-Path -LiteralPath $destinationDirectory)) {
            New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        }
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Recurse -Force
    }

    return $previewRoot
}
