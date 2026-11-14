function Select-OrderedSolution {
    <#
    .SYNOPSIS
        Edits an ordered selection while retaining the supplied solution objects.
    .DESCRIPTION
        Objects need friendlyname and uniquename. Adds exclude already-selected
        unique names; initial selections are accepted as supplied. Moves are manual,
        not dependency resolution. Done or a null management selection returns the
        current objects in order; a wizard back exception still propagates.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
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
    <#
    .SYNOPSIS
        Replaces or inserts the solutions value in a PowerShell data file.
    .PARAMETER Solutions
        Objects or hashtables with name and optional truthy deployUnmanaged. Other
        incoming fields are ignored; names are single-quote escaped. For each name,
        the first case-insensitive existing match contributes its other properties,
        except legacy mappingFile/buildCommands, when its source hashtable is found.
    .DESCRIPTION
        ShouldProcess precedes reads and writes; rejection returns false. A missing
        file requires CreateIfMissing and uses an existing TemplatePath or a minimal
        root hashtable. Parses source and, when solutions already exists, imports
        restricted PowerShell data to match names to source entries. Replaces only
        the solutions value, preserving unrelated source. Parse/root/import errors throw.
        Returns whether the resulting text differs from the text read after creation,
        not whether a file was created. Writes are not transactional.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][array]$Solutions,
        [Parameter()][switch]$CreateIfMissing,
        [Parameter()][string]$TemplatePath
    )

    if (-not $PSCmdlet.ShouldProcess($ConfigPath, 'Update configured solutions')) { return $false }

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
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($configContent, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        throw "Could not parse existing alm-config.psd1 '$ConfigPath': $($parseErrors[0].Message)"
    }

    # Extent offsets preserve unrelated source rather than reserializing the file.
    # The first non-nested hashtable is treated as the root configuration contract.
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

    $existingSolutions = @()
    $existingSolutionAsts = @()
    if ($solutionsEntry) {
        # Imported names identify selections; source extents preserve retained values
        # without reserializing nested mapping/buildCommand objects or custom settings.
        $existingConfig = Import-PowerShellDataFile -LiteralPath $ConfigPath
        $existingSolutions = @($existingConfig.solutions)
        $solutionArrayAst = $solutionsEntry.Item2.Find({
            param($node)
            $node -is [System.Management.Automation.Language.ArrayExpressionAst] -and
                $node.Parent -is [System.Management.Automation.Language.CommandExpressionAst] -and
                $node.Parent.Parent -eq $solutionsEntry.Item2
        }, $true)
        if ($solutionArrayAst) {
            # Only direct solution records belong in this positional lookup. Nested
            # hashtables/arrays are property data, not additional selected solutions.
            $existingSolutionAsts = @($solutionArrayAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.HashtableAst]
            }, $true) | Where-Object {
                $ancestor = $_.Parent
                while ($ancestor -and $ancestor -ne $solutionArrayAst -and
                    $ancestor -isnot [System.Management.Automation.Language.HashtableAst] -and
                    $ancestor -isnot [System.Management.Automation.Language.ArrayExpressionAst]) {
                    $ancestor = $ancestor.Parent
                }
                $ancestor -eq $solutionArrayAst
            })
        }
    }

    $solutionsArray = "@("
    if ($Solutions.Count -gt 0) {
        $solutionsArray += "`n"
        foreach ($solution in $Solutions) {
            $solutionName = [string]$solution.name
            $escapedSolutionName = $solutionName.Replace("'", "''")
            $solutionsArray += "        @{`n"
            $solutionsArray += "            name = '$escapedSolutionName'`n"
            if (Get-OptionalObjectPropertyValue -InputObject $solution -PropertyName 'deployUnmanaged') {
                $solutionsArray += "            deployUnmanaged = `$true`n"
            }

            $existingSolutionIndex = -1
            for ($index = 0; $index -lt $existingSolutions.Count; $index++) {
                if ([string]$existingSolutions[$index].name -ieq $solutionName) {
                    $existingSolutionIndex = $index
                    break
                }
            }
            if ($existingSolutionIndex -ge 0 -and $existingSolutionIndex -lt $existingSolutionAsts.Count) {
                # Setup owns name/deployUnmanaged and retires the old external-mapping
                # and solution-wide command keys; inline mappings/custom keys survive.
                foreach ($property in $existingSolutionAsts[$existingSolutionIndex].KeyValuePairs) {
                    $propertyName = [string]$property.Item1.SafeGetValue()
                    if ($propertyName -in @('name', 'deployUnmanaged', 'mappingFile', 'buildCommands')) { continue }
                    $solutionsArray += "            $($property.Item1.Extent.Text) = $($property.Item2.Extent.Text)`n"
                }
            }
            $solutionsArray += "        }`n"
        }
        $solutionsArray += "    )"
    }
    else {
        $solutionsArray += "`n    )"
    }

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

function Get-SolutionCheckEnabledFromConfigContent {
    # Inspect the syntax tree without executing repository data; commented examples are excluded.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][AllowEmptyString()][string]$ConfigContent
    )

    if ([string]::IsNullOrWhiteSpace($ConfigContent)) {
        return $false
    }

    $tokens = $null
    $parseErrors = $null
    $configAst = [System.Management.Automation.Language.Parser]::ParseInput($ConfigContent, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw "Unable to inspect alm-config.psd1 for BUILD solution-check settings: $($parseErrors[0].Message)"
    }

    foreach ($configurationHashtable in $configAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.HashtableAst]
    }, $true)) {
        foreach ($configurationEntry in $configurationHashtable.KeyValuePairs) {
            if (
                $configurationEntry.Item1 -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -or
                $configurationEntry.Item1.Value -ine 'solutionCheck'
            ) {
                continue
            }

            $solutionCheckHashtable = $configurationEntry.Item2.Find({
                param($node)
                $node -is [System.Management.Automation.Language.HashtableAst]
            }, $true)
            if ($null -eq $solutionCheckHashtable) {
                continue
            }

            foreach ($setting in $solutionCheckHashtable.KeyValuePairs) {
                if (
                    $setting.Item1 -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                    $setting.Item1.Value -ieq 'enabled' -and
                    $setting.Item2.Extent.Text.Trim() -ieq '$true'
                ) {
                    return $true
                }
            }
        }
    }

    return $false
}

function Set-AlmConfigSolutionCheckEnabledInFile {
    <#
    .SYNOPSIS
        Writes a solutionCheck hashtable containing the requested enabled flag.
    .DESCRIPTION
        Replaces the entire solutionCheck value, not just enabled; existing checker
        subsettings are discarded. Other root settings are preserved by AST offsets.
        ShouldProcess rejection returns false before I/O. Missing files require
        CreateIfMissing and use an existing template or minimal hashtable.
        Parse/root errors throw. Returns text-change status after any initial
        creation; file writes are not transactional.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][bool]$Enabled,
        [Parameter()][switch]$CreateIfMissing,
        [Parameter()][string]$TemplatePath
    )

    if (-not $PSCmdlet.ShouldProcess($ConfigPath, 'Update solution checker configuration')) { return $false }

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        if (-not $CreateIfMissing) {
            throw "alm-config.psd1 not found: $ConfigPath"
        }

        if (-not [string]::IsNullOrWhiteSpace($TemplatePath) -and (Test-Path -LiteralPath $TemplatePath)) {
            Copy-Item -LiteralPath $TemplatePath -Destination $ConfigPath -Force
        }
        else {
            Set-Content -LiteralPath $ConfigPath -Value "@{`n}`n" -NoNewline
        }
    }

    $configContent = Get-Content -LiteralPath $ConfigPath -Raw
    $enabledLiteral = if ($Enabled) { '$true' } else { '$false' }
    $solutionCheckBlock = "@{`n        enabled = $enabledLiteral`n    }"

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

    $solutionCheckEntry = $rootHashtable.KeyValuePairs | Where-Object {
        $keyText = $_.Item1.Extent.Text.Trim()
        $keyText -in @('solutionCheck', "'solutionCheck'", '"solutionCheck"')
    } | Select-Object -First 1

    if ($solutionCheckEntry) {
        $valueExtent = $solutionCheckEntry.Item2.Extent
        $updatedContent = $configContent.Substring(0, $valueExtent.StartOffset) + $solutionCheckBlock + $configContent.Substring($valueExtent.EndOffset)
    }
    else {
        $insertOffset = $rootHashtable.Extent.EndOffset - 1
        $lineEnding = if ($configContent -match "`r`n") { "`r`n" } else { "`n" }
        $insertText = "$lineEnding    solutionCheck = $solutionCheckBlock$lineEnding"
        $updatedContent = $configContent.Substring(0, $insertOffset) + $insertText + $configContent.Substring($insertOffset)
    }

    $hasChanges = ($updatedContent -ne $configContent)
    if ($hasChanges) {
        Set-Content -LiteralPath $ConfigPath -Value $updatedContent -NoNewline
    }

    return $hasChanges
}

function Set-AlmConfigBuildValidationBaselineReleaseInFile {
    <#
    .SYNOPSIS
        Inserts or updates buildValidation.baselineRelease while retaining sibling settings.
    .PARAMETER BaselineRelease
        Literal selector text; empty is allowed and quotes are escaped. No selector
        resolution or validation occurs here.
    .DESCRIPTION
        Parses source without execution and edits AST extents. Existing buildValidation
        must contain a hashtable. Missing files require CreateIfMissing and use an
        existing template or a minimal root. ShouldProcess rejection returns false
        before I/O; parse/shape errors throw. Returns text-change status after any
        creation, not file-creation status. Writes are not transactional.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$BaselineRelease,
        [Parameter()][switch]$CreateIfMissing,
        [Parameter()][string]$TemplatePath
    )

    if (-not $PSCmdlet.ShouldProcess($ConfigPath, 'Update BUILD validation baseline')) { return $false }

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        if (-not $CreateIfMissing) {
            throw "alm-config.psd1 not found: $ConfigPath"
        }

        if (-not [string]::IsNullOrWhiteSpace($TemplatePath) -and (Test-Path -LiteralPath $TemplatePath)) {
            Copy-Item -LiteralPath $TemplatePath -Destination $ConfigPath -Force
        }
        else {
            Set-Content -LiteralPath $ConfigPath -Value "@{`n}`n" -NoNewline
        }
    }

    $configContent = Get-Content -LiteralPath $ConfigPath -Raw
    $escapedBaselineRelease = $BaselineRelease.Replace("'", "''")
    $baselineBlock = "@{`n        baselineRelease = '$escapedBaselineRelease'`n    }"

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

    $buildValidationEntry = $rootHashtable.KeyValuePairs | Where-Object {
        $keyText = $_.Item1.Extent.Text.Trim()
        $keyText -in @('buildValidation', "'buildValidation'", '"buildValidation"')
    } | Select-Object -First 1

    if ($buildValidationEntry) {
        $buildValidationHashtable = $buildValidationEntry.Item2.Find({
            param($node)
            $node -is [System.Management.Automation.Language.HashtableAst]
        }, $false)
        if (-not $buildValidationHashtable) {
            throw "The buildValidation setting in '$ConfigPath' must be a hashtable."
        }

        $baselineEntry = $buildValidationHashtable.KeyValuePairs | Where-Object {
            $keyText = $_.Item1.Extent.Text.Trim()
            $keyText -in @('baselineRelease', "'baselineRelease'", '"baselineRelease"')
        } | Select-Object -First 1

        if ($baselineEntry) {
            $valueExtent = $baselineEntry.Item2.Extent
            $updatedContent = $configContent.Substring(0, $valueExtent.StartOffset) + "'$escapedBaselineRelease'" + $configContent.Substring($valueExtent.EndOffset)
        }
        else {
            $insertOffset = $buildValidationHashtable.Extent.EndOffset - 1
            $lineEnding = if ($configContent -match "`r`n") { "`r`n" } else { "`n" }
            $insertText = "$lineEnding        baselineRelease = '$escapedBaselineRelease'$lineEnding    "
            $updatedContent = $configContent.Substring(0, $insertOffset) + $insertText + $configContent.Substring($insertOffset)
        }
    }
    else {
        $insertOffset = $rootHashtable.Extent.EndOffset - 1
        $lineEnding = if ($configContent -match "`r`n") { "`r`n" } else { "`n" }
        $insertText = "$lineEnding    buildValidation = $baselineBlock$lineEnding"
        $updatedContent = $configContent.Substring(0, $insertOffset) + $insertText + $configContent.Substring($insertOffset)
    }

    $hasChanges = ($updatedContent -ne $configContent)
    if ($hasChanges) {
        Set-Content -LiteralPath $ConfigPath -Value $updatedContent -NoNewline
    }

    return $hasChanges
}

function ConvertTo-SetupPowerShellDataLiteral {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()][object]$Value,
        [Parameter()][int]$Indent = 0
    )

    if ($null -eq $Value) {
        return '$null'
    }

    if ($Value -is [string]) {
        return "'" + $Value.Replace("'", "''") + "'"
    }

    if ($Value -is [bool]) {
        return $(if ($Value) { '$true' } else { '$false' })
    }

    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Count -eq 0) {
            return '@{}'
        }

        $lineEnding = [Environment]::NewLine
        $childIndent = $Indent + 4
        $childPrefix = ' ' * $childIndent
        $lines = @('@{')
        foreach ($entry in $Value.GetEnumerator()) {
            $escapedKey = ([string]$entry.Key).Replace("'", "''")
            $serializedValue = ConvertTo-SetupPowerShellDataLiteral -Value $entry.Value -Indent $childIndent
            $lines += "$childPrefix'$escapedKey' = $serializedValue"
        }
        $lines += (' ' * $Indent) + '}'
        return ($lines -join $lineEnding)
    }

    if ($Value -is [System.Array] -or $Value -is [System.Collections.IList]) {
        $items = @($Value)
        if ($items.Count -eq 0) {
            return '@()'
        }

        $lineEnding = [Environment]::NewLine
        $childIndent = $Indent + 4
        $childPrefix = ' ' * $childIndent
        $lines = @('@(')
        foreach ($item in $items) {
            $lines += $childPrefix + (ConvertTo-SetupPowerShellDataLiteral -Value $item -Indent $childIndent)
        }
        $lines += (' ' * $Indent) + ')'
        return ($lines -join $lineEnding)
    }

    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or $Value -is [decimal]) {
        return ([System.IFormattable]$Value).ToString($null, [System.Globalization.CultureInfo]::InvariantCulture)
    }

    throw "Unsupported ALM configuration data value type '$($Value.GetType().FullName)'."
}
