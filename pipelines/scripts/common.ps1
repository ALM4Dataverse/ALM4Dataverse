<#
.SYNOPSIS
    Common functions for pipelines scripts.
.DESCRIPTION
    This script contains common functions used across various pipeline scripts
    such as build.ps1, deploy.ps1, and export.ps1.
#>

function Get-SolutionPackagerMappingEntry {
    <#
    .SYNOPSIS
        Validates inline solution mappings and returns ordered normalized entries.
    .DESCRIPTION
        Missing/null mappings emits no entries. Otherwise requires an array of
        hashtables with Folder, FileToFile or FileToPath type and nonblank source/
        destination strings; unknown mapping/build-command keys throw. Rejects the
        removed mappingFile and solution-level buildCommands keys even if empty.
        Normalizes type casing and returns Type, Source, Destination and BuildCommand.
        BuildCommand is the original optional hashtable, not a copy: its executable,
        argument and working-directory values are validated later by the build planner.
        This helper neither resolves paths nor executes commands.
    #>
    [OutputType([object[]])]
    param([Parameter(Mandatory)][hashtable]$Solution)

    $solutionName = [string]$Solution.name
    if ($Solution.ContainsKey('mappingFile')) {
        throw "mappingFile for solution '$solutionName' is no longer supported. Define mappings directly in the solution configuration."
    }
    if ($Solution.ContainsKey('buildCommands')) {
        throw "buildCommands for solution '$solutionName' are no longer supported as a separate setting. Put buildCommand on each mapping entry instead."
    }
    if (-not $Solution.ContainsKey('mappings') -or $null -eq $Solution.mappings) {
        return @()
    }
    if ($Solution.mappings -isnot [array]) {
        throw "mappings for solution '$solutionName' must be an array of mapping entries."
    }

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($mapping in $Solution.mappings) {
        if ($mapping -isnot [hashtable]) {
            throw "Each mappings entry for solution '$solutionName' must be a hashtable."
        }

        $unknownProperties = @($mapping.Keys | Where-Object { $_ -notin @('type', 'source', 'destination', 'buildCommand') })
        if ($unknownProperties.Count -gt 0) {
            throw "Unknown property in mappings entry for solution '$solutionName': $($unknownProperties -join ', ')."
        }
        if ($mapping.type -isnot [string] -or [string]::IsNullOrWhiteSpace($mapping.type)) {
            throw "Each mappings entry for solution '$solutionName' must have a type of Folder, FileToFile, or FileToPath."
        }
        $type = switch ($mapping.type.ToLowerInvariant()) {
            'folder' { 'Folder' }
            'filetofile' { 'FileToFile' }
            'filetopath' { 'FileToPath' }
            default { throw "Unsupported mappings type '$($mapping.type)' for solution '$solutionName'. Use Folder, FileToFile, or FileToPath." }
        }
        foreach ($propertyName in @('source', 'destination')) {
            if (-not $mapping.ContainsKey($propertyName) -or $mapping[$propertyName] -isnot [string] -or [string]::IsNullOrWhiteSpace($mapping[$propertyName])) {
                throw "Each mappings entry for solution '$solutionName' must have a non-empty $propertyName string."
            }
        }
        if ($mapping.ContainsKey('buildCommand') -and $null -ne $mapping.buildCommand) {
            if ($mapping.buildCommand -isnot [hashtable]) {
                throw "buildCommand for a mappings entry in solution '$solutionName' must be a hashtable."
            }
            $unknownBuildCommandProperties = @($mapping.buildCommand.Keys | Where-Object { $_ -notin @('name', 'executable', 'arguments', 'workingDirectory', 'parallel') })
            if ($unknownBuildCommandProperties.Count -gt 0) {
                throw "Unknown property in buildCommand for solution '$solutionName': $($unknownBuildCommandProperties -join ', ')."
            }
        }

        $entries.Add([pscustomobject]@{
            Type         = $type
            Source       = $mapping.source
            Destination  = $mapping.destination
            BuildCommand = if ($mapping.ContainsKey('buildCommand')) { $mapping.buildCommand } else { $null }
        })
    }

    return $entries.ToArray()
}

function ConvertTo-SolutionPackagerMappingXml {
    <#
    .SYNOPSIS
        Serializes normalized entries to SolutionPackager mapping XML without writing a file.
    .DESCRIPTION
        Expects Get-SolutionPackagerMappingEntry output. Source is the external path
        written as 'to'; Destination is the solution-tree path written as 'map'.
        Relative sources resolve under SourceDirectory and ordinary relative
        destinations under SolutionPath, preserving entry order and XML escaping.
        Paths containing %NAME% are left for the packager to expand, without source
        existence checks. Rooted destinations are preserved.
    .PARAMETER AllowMissingSource
        Skips ordinary source existence checks for export, where unpacking can create
        them. Otherwise FileToFile needs a file and Folder/FileToPath need a directory.
        Validation throws before returning XML; no buildCommand is run here.
    #>
    param(
        [Parameter(Mandatory)][object[]]$Entries,
        [Parameter(Mandatory)][string]$SourceDirectory,
        [Parameter(Mandatory)][string]$SolutionPath,
        [Parameter(Mandatory)][string]$SolutionName,
        [switch]$AllowMissingSource
    )

    $document = [System.Xml.XmlDocument]::new()
    $declaration = $document.CreateXmlDeclaration('1.0', 'utf-8', $null)
    [void]$document.AppendChild($declaration)
    $root = $document.CreateElement('Mappings')
    [void]$document.AppendChild($root)

    foreach ($entry in $Entries) {
        # Packager environment placeholders must survive serialization; resolving them
        # here would change the mapping contract and prematurely require export targets.
        $sourcePath = [string]$entry.Source
        if ($sourcePath -notmatch '%[^%]+%') {
            if (-not [System.IO.Path]::IsPathRooted($sourcePath)) {
                $sourcePath = Join-Path $SourceDirectory $sourcePath
            }
            $sourcePath = [System.IO.Path]::GetFullPath($sourcePath)
            if (-not $AllowMissingSource) {
                $expectedPathType = if ($entry.Type -eq 'FileToFile') { 'Leaf' } else { 'Container' }
                if (-not (Test-Path -LiteralPath $sourcePath -PathType $expectedPathType)) {
                    $expectedDescription = if ($expectedPathType -eq 'Leaf') { 'file' } else { 'folder' }
                    throw "Mapping source $expectedDescription not found for solution '$SolutionName': $sourcePath"
                }
            }
        }

        $destination = [string]$entry.Destination
        if (-not [System.IO.Path]::IsPathRooted($destination) -and $destination -notmatch '%[^%]+%') {
        $destination = Join-Path $SolutionPath ($destination.Replace('\', [string][System.IO.Path]::DirectorySeparatorChar))
        }

        $element = $document.CreateElement([string]$entry.Type)
        $element.SetAttribute('map', $destination)
        $element.SetAttribute('to', $sourcePath)
        [void]$root.AppendChild($element)
    }

    return $document.OuterXml
}

function Invoke-CheckedNativeCommand {
    <#
    .SYNOPSIS
        Captures native stdout/stderr as strings and rejects nonzero exit codes.
    .PARAMETER AllowFailure
        Returns captured output even on failure; the caller must interpret LASTEXITCODE.
    .NOTES
        Temporarily relaxes ErrorActionPreference so native stderr can be captured,
        then restores the caller's preference even if invocation throws.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Command,
        [string[]]$Arguments = @(),
        [switch]$AllowFailure
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $Command @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "Native command '$Command' failed with exit code $exitCode."
    }
    foreach ($entry in $output) {
        [string]$entry
    }
}

function Merge-AlmConfigValue {
    <#
    .SYNOPSIS
        Recursively merges configuration without treating false or zero as missing.
    .DESCRIPTION
        Null on either side selects the other value. Two arrays concatenate defaults
        first; two hashtables merge by key into a new table. All other pairs select
        the override, including empty strings and mismatched types.
    #>
    param(
        $DefaultValue,
        $OverrideValue
    )

    if ($null -eq $DefaultValue) {
        return $OverrideValue
    }

    if ($null -eq $OverrideValue) {
        return $DefaultValue
    }

    if ($DefaultValue -is [array] -and $OverrideValue -is [array]) {
        return @(@($DefaultValue) + @($OverrideValue))
    }

    if ($DefaultValue -is [hashtable] -and $OverrideValue -is [hashtable]) {
        $merged = @{}
        foreach ($key in ($DefaultValue.Keys + $OverrideValue.Keys | Select-Object -Unique)) {
            $merged[$key] = Merge-AlmConfigValue -DefaultValue $DefaultValue[$key] -OverrideValue $OverrideValue[$key]
        }

        return $merged
    }

    return $OverrideValue
}

function Get-AlmConfig {
    <#
    .SYNOPSIS
        Loads required repository configuration over the bundled defaults.
    .PARAMETER BaseDirectory
        Directory containing alm-config.psd1; absence of that file is an error.
    .PARAMETER LogConfig
        Writes the complete merged configuration to host diagnostics when true.
        Disable when configuration or hook context may contain sensitive values.
    .OUTPUTS
        Hashtable with merged keys plus _main and _defaults holding the imported
        tables before merging. Relative configuration paths are not rebased here.
    #>
    param(
        [string]$BaseDirectory = ".",
        [bool]$LogConfig = $true
    )

    $defaultConfigPath = Join-Path -Path $PSScriptRoot -ChildPath ".." -AdditionalChildPath "..", "alm-config-defaults.psd1" | Resolve-Path | Select-Object -ExpandProperty Path

    $config = @{}

    Write-Host "##[group] Loading default configuration from $defaultConfigPath"
    $defaultConfig = Import-PowerShellDataFile -Path $defaultConfigPath
    Write-Host "##[endgroup]"

    # Load main config and merge
    $configPath = Join-Path $BaseDirectory "alm-config.psd1"
    if (-not (Test-Path $configPath)) {
        Write-Host "##[error]Configuration file not found: $configPath"
        throw "alm-config.psd1 not found at $configPath"
    }

    $mainConfig = Import-PowerShellDataFile -Path $configPath

    # Merge configs: mainConfig overrides defaultConfig, arrays are concatenated
    foreach ($key in $mainConfig.Keys) {
        if ($defaultConfig.ContainsKey($key)) {
            $config[$key] = Merge-AlmConfigValue -DefaultValue $defaultConfig[$key] -OverrideValue $mainConfig[$key]
        }
        else {
            $config[$key] = $mainConfig[$key]
        }
    }

    # Preserve any keys from default config that are not in main config
    foreach ($key in $defaultConfig.Keys) {
        if (-not $mainConfig.ContainsKey($key)) {
            $config[$key] = $defaultConfig[$key]
        }
    }

    $config["_main"] = $mainConfig
    $config["_defaults"] = $defaultConfig

    if ($LogConfig) { Write-Host "##[debug]Loaded configuration: $($config | ConvertTo-Json -Depth 20)" }

    return $config
}

function Get-SolutionCodeAppPath {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Solution,

        [Parameter(Mandatory = $true)]
        [string]$BaseDirectory
    )

    if (-not $Solution.ContainsKey('codeApps') -or $null -eq $Solution.codeApps) {
        return @()
    }

    $configuredPaths = $Solution.codeApps
    if ($configuredPaths -is [string]) {
        $configuredPaths = @($configuredPaths)
    }
    elseif ($configuredPaths -isnot [array]) {
        throw "Solution '$($Solution.name)' codeApps must be a path or an array of paths."
    }

    $basePath = [System.IO.Path]::GetFullPath($BaseDirectory)
    $basePrefix = $basePath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    $resolvedPaths = @()

    foreach ($configuredPath in $configuredPaths) {
        if ($configuredPath -isnot [string] -or [string]::IsNullOrWhiteSpace($configuredPath)) {
            throw "Solution '$($Solution.name)' codeApps entries must be non-empty relative paths."
        }
        if ([System.IO.Path]::IsPathRooted($configuredPath) -or $configuredPath -split '[/\\]' -contains '..') {
            throw "Solution '$($Solution.name)' codeApps path '$configuredPath' must stay within the repository."
        }

        $resolvedPath = [System.IO.Path]::GetFullPath((Join-Path $basePath $configuredPath))
        if (-not $resolvedPath.StartsWith($basePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Solution '$($Solution.name)' codeApps path '$configuredPath' must stay within the repository."
        }
        if (-not (Test-Path -LiteralPath $resolvedPath -PathType Container)) {
            throw "Code app directory '$configuredPath' for solution '$($Solution.name)' does not exist under '$basePath'."
        }

        $resolvedPaths += $resolvedPath
    }

    return $resolvedPaths
}

function Update-SolutionCodeAppPackage {
    <#
    .SYNOPSIS
        Replaces an existing solution Code App package with the configured build output.
    .DESCRIPTION
        Matches the code app by its configured appDisplayName and requires a matching
        CanvasApp root component in the solution. The solution archive is replaced only
        after the updated archive has been written successfully. Supports -WhatIf; when
        the operation is declined, the solution archive is left unchanged.
    .PARAMETER SolutionFile
        Path to the managed or unmanaged solution ZIP to patch.
    .PARAMETER CodeAppPath
        Path to the built code app project containing power.config.json and build output.
    .PARAMETER SolutionName
        Solution unique name, used to identify the package in errors and logs.
    .OUTPUTS
        None. Updates SolutionFile in place; errors if the app or its build output is missing.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SolutionFile,

        [Parameter(Mandatory = $true)]
        [string]$CodeAppPath,

        [Parameter(Mandatory = $true)]
        [string]$SolutionName
    )

    $solutionFilePath = [System.IO.Path]::GetFullPath($SolutionFile)
    if (-not (Test-Path -LiteralPath $solutionFilePath -PathType Leaf)) {
        throw "Solution package '$solutionFilePath' was not found."
    }

    $codeAppRoot = [System.IO.Path]::GetFullPath($CodeAppPath)
    $powerConfigPath = Join-Path $codeAppRoot 'power.config.json'
    if (-not (Test-Path -LiteralPath $powerConfigPath -PathType Leaf)) {
        throw "Code app '$CodeAppPath' must contain power.config.json."
    }

    $powerConfig = Get-Content -LiteralPath $powerConfigPath -Raw | ConvertFrom-Json -AsHashtable
    $appDisplayName = [string]$powerConfig.appDisplayName
    if ([string]::IsNullOrWhiteSpace($appDisplayName)) {
        throw "Code app '$CodeAppPath' must define appDisplayName in power.config.json."
    }

    $buildPath = 'dist'
    if ($powerConfig.ContainsKey('buildPath') -and
        -not [string]::IsNullOrWhiteSpace([string]$powerConfig.buildPath)) {
        $buildPath = [string]$powerConfig.buildPath
    }
    if ([System.IO.Path]::IsPathRooted($buildPath) -or $buildPath -split '[/\\]' -contains '..') {
        throw "Code app '$appDisplayName' buildPath '$buildPath' must stay within its project directory."
    }

    $buildRoot = [System.IO.Path]::GetFullPath((Join-Path $codeAppRoot $buildPath))
    $codeAppPrefix = $codeAppRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) +
        [System.IO.Path]::DirectorySeparatorChar
    if (-not $buildRoot.StartsWith($codeAppPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $buildRoot -PathType Container)) {
        throw "Code app '$appDisplayName' buildPath '$buildPath' does not resolve to a directory inside the project."
    }

    $buildEntryPoint = 'index.html'
    if ($powerConfig.ContainsKey('buildEntryPoint') -and
        -not [string]::IsNullOrWhiteSpace([string]$powerConfig.buildEntryPoint)) {
        $buildEntryPoint = [string]$powerConfig.buildEntryPoint
    }
    if ([System.IO.Path]::IsPathRooted($buildEntryPoint) -or $buildEntryPoint -split '[/\\]' -contains '..') {
        throw "Code app '$appDisplayName' buildEntryPoint '$buildEntryPoint' must stay within buildPath."
    }
    $buildEntryPointPath = [System.IO.Path]::GetFullPath((Join-Path $buildRoot $buildEntryPoint))
    $buildRootPrefix = $buildRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) +
        [System.IO.Path]::DirectorySeparatorChar
    if (-not $buildEntryPointPath.StartsWith($buildRootPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $buildEntryPointPath -PathType Leaf)) {
        throw "Code app '$appDisplayName' buildEntryPoint '$buildEntryPoint' was not found under '$buildRoot'."
    }

    $buildFiles = @(Get-ChildItem -LiteralPath $buildRoot -File -Recurse -Force | Sort-Object FullName)
    if ($buildFiles.Count -eq 0) {
        throw "Code app '$appDisplayName' build output '$buildRoot' contains no files."
    }

    $filePlan = @(
        foreach ($file in $buildFiles) {
            if (($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Code app '$appDisplayName' build output contains a linked file '$($file.FullName)'."
            }

            $relativePath = [System.IO.Path]::GetRelativePath($buildRoot, $file.FullName)
            if ([System.IO.Path]::IsPathRooted($relativePath) -or $relativePath -split '[/\\]' -contains '..') {
                throw "Code app '$appDisplayName' build file '$($file.FullName)' is outside buildPath."
            }
            $archiveRelativePath = $relativePath -replace '\\', '/'
            $contentType = switch ([System.IO.Path]::GetExtension($relativePath).ToLowerInvariant()) {
                '.css' { 'text/css' }
                '.eot' { 'application/vnd.ms-fontobject' }
                '.gif' { 'image/gif' }
                '.htm' { 'text/html' }
                '.html' { 'text/html' }
                '.ico' { 'image/vnd.microsoft.icon' }
                '.jpeg' { 'image/jpeg' }
                '.jpg' { 'image/jpeg' }
                '.js' { 'application/javascript' }
                '.json' { 'application/json' }
                '.map' { 'application/json' }
                '.mjs' { 'application/javascript' }
                '.otf' { 'font/otf' }
                '.pdf' { 'application/pdf' }
                '.png' { 'image/png' }
                '.svg' { 'image/svg+xml' }
                '.svgz' { 'image/svg+xml' }
                '.txt' { 'text/plain' }
                '.ttf' { 'font/ttf' }
                '.wasm' { 'application/wasm' }
                '.webp' { 'image/webp' }
                '.woff' { 'font/woff' }
                '.woff2' { 'font/woff2' }
                '.xml' { 'application/xml' }
                default { 'application/octet-stream' }
            }
            [pscustomobject]@{
                FilePath = $file.FullName
                ArchivePath = $archiveRelativePath
                ContentType = $contentType
            }
        }
    )
    $entryPointRelativePath = ([System.IO.Path]::GetRelativePath($buildRoot, $buildEntryPointPath) -replace '\\', '/')
    if ($filePlan.ArchivePath -notcontains $entryPointRelativePath) {
        throw "Code app '$appDisplayName' buildEntryPoint '$buildEntryPoint' is not included in the build output."
    }

    if (-not $PSCmdlet.ShouldProcess(
        $solutionFilePath,
        "Patch Code App '$appDisplayName' into solution '$SolutionName'"
    )) {
        return
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $sourceArchive = [System.IO.Compression.ZipFile]::OpenRead($solutionFilePath)
    $temporaryArchivePath = Join-Path (Split-Path -Parent $solutionFilePath) ".$([guid]::NewGuid().ToString('N')).codeapp.zip"
    $outputArchive = $null
    $outputStream = $null
    try {
        $customizationsEntry = $sourceArchive.GetEntry('customizations.xml')
        $solutionEntry = $sourceArchive.GetEntry('solution.xml')
        if ($null -eq $customizationsEntry -or $null -eq $solutionEntry) {
            throw "Solution package '$solutionFilePath' is missing customizations.xml or solution.xml."
        }

        $customizationsStream = $customizationsEntry.Open()
        try {
            $customizationsReader = [System.IO.StreamReader]::new($customizationsStream, [System.Text.Encoding]::UTF8, $true)
            try {
                $customizationsText = $customizationsReader.ReadToEnd()
            }
            finally {
                $customizationsReader.Dispose()
            }
        }
        finally {
            $customizationsStream.Dispose()
        }
        $solutionStream = $solutionEntry.Open()
        try {
            $solutionReader = [System.IO.StreamReader]::new($solutionStream, [System.Text.Encoding]::UTF8, $true)
            try {
                $solutionText = $solutionReader.ReadToEnd()
            }
            finally {
                $solutionReader.Dispose()
            }
        }
        finally {
            $solutionStream.Dispose()
        }

        $customizations = [System.Xml.XmlDocument]::new()
        $customizations.PreserveWhitespace = $true
        $customizations.LoadXml($customizationsText)
        $canvasAppNodes = @($customizations.SelectNodes("//*[local-name()='CanvasApp']"))
        $matchingCanvasApps = @(
            foreach ($canvasAppNode in $canvasAppNodes) {
                $displayNameNode = $canvasAppNode.SelectSingleNode("./*[local-name()='DisplayName']")
                if ($null -ne $displayNameNode -and [string]::Equals(
                    $displayNameNode.InnerText,
                    $appDisplayName,
                    [System.StringComparison]::Ordinal
                )) {
                    $canvasAppNode
                }
            }
        )
        if ($matchingCanvasApps.Count -eq 0) {
            throw "Configured code app '$appDisplayName' is not present in solution '$SolutionName'. Add and export the app into the solution before configuring it in codeApps."
        }
        if ($matchingCanvasApps.Count -ne 1) {
            throw "Configured code app display name '$appDisplayName' matches multiple CanvasApp components in solution '$SolutionName'."
        }

        $canvasAppNode = $matchingCanvasApps[0]
        $nameNode = $canvasAppNode.SelectSingleNode("./*[local-name()='Name']")
        $typeNode = $canvasAppNode.SelectSingleNode("./*[local-name()='CanvasAppType']")
        $packageUrisNode = $canvasAppNode.SelectSingleNode("./*[local-name()='CodeAppPackageUris']")
        if ($null -eq $nameNode -or [string]::IsNullOrWhiteSpace($nameNode.InnerText) -or
            $null -eq $typeNode -or $typeNode.InnerText -ne '4' -or $null -eq $packageUrisNode) {
            throw "CanvasApp '$appDisplayName' in solution '$SolutionName' is not a complete Code App component."
        }

        $componentName = $nameNode.InnerText
        if ([System.IO.Path]::GetFileName($componentName) -ne $componentName -or $componentName -match '[/\\]') {
            throw "CanvasApp '$appDisplayName' in solution '$SolutionName' has an invalid component name '$componentName'."
        }
        [xml]$solutionMetadata = $solutionText
        $hasRootComponent = @(
            $solutionMetadata.SelectNodes("//*[local-name()='RootComponent']") |
                Where-Object {
                    $_.GetAttribute('type') -eq '300' -and
                    [string]::Equals($_.GetAttribute('schemaName'), $componentName, [System.StringComparison]::OrdinalIgnoreCase)
                }
        ).Count -gt 0
        if (-not $hasRootComponent) {
            throw "Code App '$appDisplayName' is not a root component of solution '$SolutionName'."
        }

        $packageDirectory = "CanvasApps/${componentName}_CodeAppPackages"
        $packagePrefix = "$packageDirectory/"
        foreach ($packageUriNode in $packageUrisNode.SelectNodes("./*[local-name()='CodeAppPackageUri']")) {
            if (-not $packageUriNode.InnerText.StartsWith("/$packagePrefix", [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Code App '$appDisplayName' in solution '$SolutionName' has an unsupported package URI '$($packageUriNode.InnerText)'."
            }
        }

        foreach ($packageUriNode in @($packageUrisNode.SelectNodes("./*[local-name()='CodeAppPackageUri']"))) {
            $null = $packageUrisNode.RemoveChild($packageUriNode)
        }
        $packageUrisPrefix = "/$packagePrefix"
        foreach ($file in $filePlan) {
            $uriNode = $customizations.CreateElement(
                $packageUrisNode.Prefix,
                'CodeAppPackageUri',
                $packageUrisNode.NamespaceURI
            )
            $uriNode.InnerText = "$packageUrisPrefix$($file.ArchivePath)_ContentType_$($file.ContentType)"
            $null = $packageUrisNode.AppendChild($uriNode)
        }

        $manifestStream = [System.IO.MemoryStream]::new()
        try {
            $customizations.Save($manifestStream)
            $manifestBytes = $manifestStream.ToArray()
        }
        finally {
            $manifestStream.Dispose()
        }

        $outputStream = [System.IO.File]::Open(
            $temporaryArchivePath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        $outputArchive = [System.IO.Compression.ZipArchive]::new(
            $outputStream,
            [System.IO.Compression.ZipArchiveMode]::Create,
            $false
        )
        foreach ($entry in $sourceArchive.Entries) {
            $normalizedEntryName = $entry.FullName -replace '\\', '/'
            if ($normalizedEntryName.StartsWith($packagePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            $newEntry = $outputArchive.CreateEntry($entry.FullName, [System.IO.Compression.CompressionLevel]::Optimal)
            $newEntry.LastWriteTime = $entry.LastWriteTime
            $newEntry.ExternalAttributes = $entry.ExternalAttributes
            $destinationStream = $newEntry.Open()
            try {
                if ($normalizedEntryName -eq 'customizations.xml') {
                    $destinationStream.Write($manifestBytes, 0, $manifestBytes.Length)
                }
                else {
                    $sourceStream = $entry.Open()
                    try {
                        $sourceStream.CopyTo($destinationStream)
                    }
                    finally {
                        $sourceStream.Dispose()
                    }
                }
            }
            finally {
                $destinationStream.Dispose()
            }
        }

        foreach ($file in $filePlan) {
            $entryPath = "$packagePrefix$($file.ArchivePath)"
            $newEntry = $outputArchive.CreateEntry($entryPath, [System.IO.Compression.CompressionLevel]::Optimal)
            $newEntry.LastWriteTime = (Get-Item -LiteralPath $file.FilePath).LastWriteTime
            $destinationStream = $newEntry.Open()
            try {
                $sourceStream = [System.IO.File]::OpenRead($file.FilePath)
                try {
                    $sourceStream.CopyTo($destinationStream)
                }
                finally {
                    $sourceStream.Dispose()
                }
            }
            finally {
                $destinationStream.Dispose()
            }
        }

        $outputArchive.Dispose()
        $outputArchive = $null
        $outputStream = $null
        $sourceArchive.Dispose()
        $sourceArchive = $null
        [System.IO.File]::Move($temporaryArchivePath, $solutionFilePath, $true)
        Write-Host "Patched Code App '$appDisplayName' into solution '$SolutionName'."
    }
    finally {
        if ($null -ne $outputArchive) {
            $outputArchive.Dispose()
        }
        if ($null -ne $outputStream) {
            $outputStream.Dispose()
        }
        if ($null -ne $sourceArchive) {
            $sourceArchive.Dispose()
        }
        if (Test-Path -LiteralPath $temporaryArchivePath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryArchivePath -Force
        }
    }
}

function Resolve-AlmBranchBaseVersion {
    <#
    .SYNOPSIS
        Resolves a branch's configured MAJOR.MINOR without changing configuration.
    .DESCRIPTION
        Accepts a short branch name or refs/heads ref, rejecting other refs.
        Overrides match the full branch name case-sensitively; otherwise default
        is used. Invalid SemVer integers or Int32 overflow throw.
    .OUTPUTS
        Object with Major, Build, MajorMinor, BranchName and HasBranchOverride.
        Build deliberately holds the second configured component for Dataverse's
        Major.Minor.Build.Revision layout, not its mutable Minor counter.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [string]$BranchName
    )

    if (-not $Config.ContainsKey('buildVersion') -or $Config.buildVersion -isnot [hashtable]) {
        throw "BUILD version configuration is missing. Add buildVersion.default and buildVersion.branches to alm-config-defaults.psd1 or alm-config.psd1."
    }

    $versionConfig = $Config.buildVersion
    if (-not $versionConfig.ContainsKey('default')) {
        throw "BUILD version configuration is missing buildVersion.default in alm-config-defaults.psd1 or alm-config.psd1."
    }

    $branch = $BranchName.Trim()
    if ($branch -match '^refs/heads/(?<name>.+)$') {
        $branch = $Matches.name
    }
    elseif ($branch -match '^refs/') {
        throw "BUILD versioning requires a branch ref; '$BranchName' is not a refs/heads branch."
    }
    if ([string]::IsNullOrWhiteSpace($branch)) {
        throw 'BUILD versioning requires a non-empty source branch.'
    }

    $majorMinor = [string]$versionConfig.default
    $hasBranchOverride = $false
    if ($versionConfig.ContainsKey('branches')) {
        if ($versionConfig.branches -isnot [hashtable]) {
            throw 'buildVersion.branches must be a hashtable of full branch names to MAJOR.MINOR values.'
        }

        foreach ($configuredBranch in $versionConfig.branches.Keys) {
            if ([string]$configuredBranch -ceq $branch) {
                $majorMinor = [string]$versionConfig.branches[$configuredBranch]
                $hasBranchOverride = $true
                break
            }
        }
    }

    if ($majorMinor -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
        throw "Invalid MAJOR.MINOR value '$majorMinor' for branch '$branch'. Use two non-negative SemVer integers, for example '1.4'."
    }

    $versionParts = $majorMinor.Split('.')
    [int]$major = 0
    [int]$minor = 0
    if (-not [int]::TryParse($versionParts[0], [ref]$major) -or
        -not [int]::TryParse($versionParts[1], [ref]$minor)) {
        throw "Invalid MAJOR.MINOR value '$majorMinor' for branch '$branch'. Dataverse solution version components must fit in a 32-bit integer."
    }

    return [pscustomobject]@{
        Major      = $major
        Build      = $minor
        MajorMinor = $majorMinor
        BranchName = $branch
        HasBranchOverride = $hasBranchOverride
    }
}

function Invoke-AlmGitCommand {
    <#
    .SYNOPSIS
        Runs Git in a repository and returns ExitCode and combined Output text.
    .DESCRIPTION
        Missing Git throws; a nonzero Git exit code is returned rather than thrown
        so reservation callers can distinguish missing refs from command failures.
        Restores ErrorActionPreference after capturing stderr.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'Git is required to reserve Dataverse solution versions.'
    }

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& git -C $RepositoryPath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        Output   = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    }
}

function Resolve-AlmDefaultBranchName {
    <#
    .SYNOPSIS
        Uses an explicit branch or queries origin's symbolic HEAD.
    .DESCRIPTION
        Strips refs/heads from explicit names and rejects other refs. Without an
        override, requires remote access and throws on lookup or parsing failure;
        it does not rely on a potentially stale local origin/HEAD.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath,

        [string]$DefaultBranchName
    )

    if (-not [string]::IsNullOrWhiteSpace($DefaultBranchName)) {
        $branch = $DefaultBranchName.Trim()
        if ($branch -match '^refs/heads/(?<name>.+)$') {
            return $Matches.name
        }
        if ($branch -match '^refs/') {
            throw "Default branch '$DefaultBranchName' is not a refs/heads branch."
        }
        return $branch
    }

    $result = Invoke-AlmGitCommand -RepositoryPath $RepositoryPath -Arguments @('ls-remote', '--symref', 'origin', 'HEAD')
    if ($result.ExitCode -ne 0) {
        throw "Could not determine the repository default branch from origin/HEAD. $($result.Output)"
    }

    $match = [regex]::Match($result.Output, '(?m)^ref:\s+refs/heads/(?<name>.+)\s+HEAD$')
    if (-not $match.Success) {
        throw "Could not determine the repository default branch from origin/HEAD. Output: $($result.Output)"
    }

    return $match.Groups['name'].Value
}

function Get-NextAlmSolutionVersion {
    <#
    .SYNOPSIS
        Advances a four-part Dataverse version while preserving Major and Build.
    .PARAMETER IsAdditive
        True increments Revision; false increments Minor and resets Revision.
        Incrementing a component beyond Int32.MaxValue throws.
    #>
    [CmdletBinding()]
    [OutputType([version])]
    param(
        [Parameter(Mandatory = $true)]
        [version]$Version,

        [Parameter(Mandatory = $true)]
        [bool]$IsAdditive
    )

    $minor = $Version.Minor
    $revision = $Version.Revision
    if ($IsAdditive) {
        if ($revision -ge [int]::MaxValue) {
            throw "Cannot increment solution revision beyond $([int]::MaxValue)."
        }
        $revision++
    }
    else {
        if ($minor -ge [int]::MaxValue) {
            throw "Cannot increment solution minor beyond $([int]::MaxValue)."
        }
        $minor++
        $revision = 0
    }

    return [version]::new($Version.Major, $minor, $Version.Build, $revision)
}

function Register-AlmSolutionVersion {
    <#
    .SYNOPSIS
        Reserves a solution version by pushing a unique lightweight tag to origin.
    .DESCRIPTION
        Tags point to local HEAD. Existing remote reservations advance the candidate
        using IsAdditive; success returns the reserved Version and keeps its local
        tag. A local-only collision, non-race push failure or exhausted attempts
        throws. This reserves the number before export updates Dataverse; it is not
        a transaction with the later environment update.
    .PARAMETER MaximumAttempts
        Maximum candidate attempts (1-1000), including remote collisions.
    #>
    [CmdletBinding()]
    [OutputType([version])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath,

        [Parameter(Mandatory = $true)]
        [string]$SolutionName,

        [Parameter(Mandatory = $true)]
        [version]$Version,

        [Parameter(Mandatory = $true)]
        [bool]$IsAdditive,

        [ValidateRange(1, 1000)]
        [int]$MaximumAttempts = 100
    )

    $candidateVersion = $Version
    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        $tagName = "alm4dv/solution-version/$SolutionName/$candidateVersion"
        $tagRef = "refs/tags/$tagName"
        $formatResult = Invoke-AlmGitCommand -RepositoryPath $RepositoryPath -Arguments @('check-ref-format', $tagRef)
        if ($formatResult.ExitCode -ne 0) {
            throw "Solution '$SolutionName' produced an invalid reservation tag '$tagName'. $($formatResult.Output)"
        }

        $remoteTag = Invoke-AlmGitCommand -RepositoryPath $RepositoryPath -Arguments @('ls-remote', '--refs', 'origin', $tagRef)
        if ($remoteTag.ExitCode -ne 0) {
            throw "Failed to check reservation tag '$tagName' on origin. $($remoteTag.Output)"
        }
        if (-not [string]::IsNullOrWhiteSpace($remoteTag.Output)) {
            Write-Host "[$SolutionName][Version] $candidateVersion is already reserved; selecting the next version."
            $candidateVersion = Get-NextAlmSolutionVersion -Version $candidateVersion -IsAdditive $IsAdditive
            continue
        }

        $localTag = Invoke-AlmGitCommand -RepositoryPath $RepositoryPath -Arguments @('show-ref', '--verify', '--quiet', $tagRef)
        if ($localTag.ExitCode -eq 0) {
            throw "Local reservation tag '$tagName' exists but is not present on origin. Remove or reconcile that local tag before exporting."
        }
        if ($localTag.ExitCode -ne 1) {
            throw "Failed to check local reservation tag '$tagName'. $($localTag.Output)"
        }

        $createTag = Invoke-AlmGitCommand -RepositoryPath $RepositoryPath -Arguments @('tag', $tagName, 'HEAD')
        if ($createTag.ExitCode -ne 0) {
            throw "Failed to create local reservation tag '$tagName'. $($createTag.Output)"
        }

        $refSpec = "${tagRef}:$tagRef"
        $pushTag = Invoke-AlmGitCommand -RepositoryPath $RepositoryPath -Arguments @('push', 'origin', $refSpec)
        if ($pushTag.ExitCode -eq 0) {
            return $candidateVersion
        }

        # A rejected push is a race only if the remote now owns the reservation.
        # Remove our local attempt before retrying; do not hide authentication or transport errors.
        $deleteTag = Invoke-AlmGitCommand -RepositoryPath $RepositoryPath -Arguments @('tag', '-d', $tagName)
        if ($deleteTag.ExitCode -ne 0) {
            throw "Failed to remove local reservation tag '$tagName' after a rejected push. Push output: $($pushTag.Output). Cleanup output: $($deleteTag.Output)"
        }

        $remoteTag = Invoke-AlmGitCommand -RepositoryPath $RepositoryPath -Arguments @('ls-remote', '--refs', 'origin', $tagRef)
        if ($remoteTag.ExitCode -ne 0) {
            throw "Failed to verify reservation tag '$tagName' after a rejected push. Push output: $($pushTag.Output). Check output: $($remoteTag.Output)"
        }
        if (-not [string]::IsNullOrWhiteSpace($remoteTag.Output)) {
            Write-Host "[$SolutionName][Version] Another export reserved $candidateVersion concurrently; selecting the next version."
            $candidateVersion = Get-NextAlmSolutionVersion -Version $candidateVersion -IsAdditive $IsAdditive
            continue
        }

        throw "Failed to push reservation tag '$tagName'. $($pushTag.Output)"
    }

    throw "Could not reserve a solution version for '$SolutionName' after $MaximumAttempts attempts."
}

function Resolve-AlmBuildVersion {
    <#
    .SYNOPSIS
        Builds branch-suffixed SemVer and tag metadata from a CI run number.
    .DESCRIPTION
        Uses configured MAJOR.MINOR and a non-negative, unpadded numeric PATCH.
        The branch is lowercased and sanitized for prerelease syntax; the original
        normalized branch name is retained for identity comparisons. Invalid input
        throws. Provider labels the output and does not alter version arithmetic.
    .OUTPUTS
        Object with Version, TagName, BranchName, Provider and RunNumber.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [string]$BranchName,

        [Parameter(Mandatory = $true)]
        [string]$RunNumber,

        [Parameter(Mandatory = $true)]
        [ValidateSet('github', 'azdo')]
        [string]$Provider
    )

    $branchBaseVersion = Resolve-AlmBranchBaseVersion -Config $Config -BranchName $BranchName
    $branch = $branchBaseVersion.BranchName
    $majorMinor = $branchBaseVersion.MajorMinor

    if ($RunNumber -notmatch '^(0|[1-9][0-9]*)$') {
        throw "CI run number '$RunNumber' cannot be used as a SemVer PATCH value."
    }

    $branchIdentifier = $branch.ToLowerInvariant() -replace '[^a-z0-9-]+', '-'
    $branchIdentifier = $branchIdentifier -replace '-{2,}', '-'
    $branchIdentifier = $branchIdentifier.Trim('-')
    if ([string]::IsNullOrWhiteSpace($branchIdentifier)) {
        throw "Source branch '$branch' cannot be converted to a SemVer prerelease identifier."
    }
    if ($branchIdentifier -match '^0[0-9]+$') {
        $branchIdentifier = "b$branchIdentifier"
    }

    $version = "$majorMinor.$RunNumber-$branchIdentifier"
    return [pscustomobject]@{
        Version       = $version
        TagName       = "v$version"
        BranchName    = $branch
        Provider      = $Provider
        RunNumber     = $RunNumber
    }
}

function Write-AlmBuildVersionInfo {
    <#
    .SYNOPSIS
        Overwrites build-version.json in an existing artifacts directory.
    .DESCRIPTION
        Consumes Resolve-AlmBuildVersion's result and returns the metadata path.
        Requires a numeric RunId and full 40-hex SourceCommit, stored lowercase;
        invalid identity or a missing artifacts directory throws before writing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArtifactsPath,

        [Parameter(Mandatory = $true)]
        [psobject]$BuildVersion,

        [Parameter(Mandatory = $true)]
        [string]$RunId,

        [Parameter(Mandatory = $true)]
        [string]$SourceCommit
    )

    if ($RunId -notmatch '^[0-9]+$') {
        throw "Build run ID '$RunId' must contain only digits."
    }
    if ($SourceCommit -notmatch '^[0-9a-fA-F]{40}$') {
        throw "Source commit '$SourceCommit' must be a 40-character Git SHA."
    }
    if (-not (Test-Path -LiteralPath $ArtifactsPath -PathType Container)) {
        throw "Artifacts directory '$ArtifactsPath' does not exist."
    }

    $metadata = [ordered]@{
        version       = $BuildVersion.Version
        tag            = $BuildVersion.TagName
        branch         = $BuildVersion.BranchName
        provider       = $BuildVersion.Provider
        runNumber      = $BuildVersion.RunNumber
        runId          = $RunId
        sourceCommit   = $SourceCommit.ToLowerInvariant()
    }
    $metadataPath = Join-Path $ArtifactsPath 'build-version.json'
    Set-Content -LiteralPath $metadataPath -Value ($metadata | ConvertTo-Json) -Encoding utf8
    return $metadataPath
}

    function Initialize-PacAuthentication {
        <#
        .SYNOPSIS
            Creates or selects a PAC profile using the existing Azure identity context.
        .DESCRIPTION
            Requires PAC on PATH and a non-interactive Azure sign-in context.
            When Url is provided, creates the profile for that environment and selects it as active.
            If profile creation fails, tries selection before validating auth who.
            Throws when neither setup path succeeds or identity validation fails.
        .PARAMETER Url
            Optional Dataverse environment URL to associate with and select in the PAC profile.
        .PARAMETER Quiet
            Suppresses auth who output, not group markers or authentication errors.
        #>
        param(
            [string]$ProfileName = 'ALM4Dataverse-SolutionCheck',
            [string]$Url = '',
            [switch]$Quiet
        )

        $pacCommand = Get-Command pac -ErrorAction SilentlyContinue
        if (-not $pacCommand) {
            throw "Power Apps CLI (pac) is not available on PATH. Ensure installdependencies.ps1 has run in this job before calling scripts that require PAC authentication."
        }

        $pacPath = $pacCommand.Source

        Write-Host "##[group]Authenticating Power Apps CLI using managed identity / Azure identity context"

        $createArgs = @('auth', 'create', '--managedIdentity', '--name', $ProfileName)
        if (-not [string]::IsNullOrWhiteSpace($Url)) {
            $createArgs += @('--environment', $Url)
        }
        $createOutput = @(& $pacPath @createArgs 2>&1)
        $createExitCode = $LASTEXITCODE

        if ($createExitCode -ne 0) {
            $selectOutput = @(& $pacPath auth select --name $ProfileName 2>&1)
            $selectExitCode = $LASTEXITCODE

            if ($selectExitCode -ne 0) {
                $createText = ($createOutput | ForEach-Object { [string]$_ }) -join "`n"
                $selectText = ($selectOutput | ForEach-Object { [string]$_ }) -join "`n"
                throw @(
                    "Failed to establish PAC authentication using the existing Azure identity context.",
                    "Expected an existing non-interactive Azure sign-in context (for example Azure CLI, managed identity, or workload identity).",
                    "pac auth create output:",
                    $createText,
                    "pac auth select output:",
                    $selectText
                ) -join "`n"
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($Url)) {
            $environmentOutput = @(& $pacPath env select --environment $Url 2>&1)
            if ($LASTEXITCODE -ne 0) {
                $environmentText = ($environmentOutput | ForEach-Object { [string]$_ }) -join "`n"
                throw "PAC environment selection failed for '$Url'.`n$environmentText"
            }
        }

        $whoOutput = @(& $pacPath auth who 2>&1)
        if ($LASTEXITCODE -ne 0) {
            $whoText = ($whoOutput | ForEach-Object { [string]$_ }) -join "`n"
            throw "PAC authentication validation failed (pac auth who).`n$whoText"
        }

        if (-not $Quiet) {
            foreach ($line in $whoOutput) {
                Write-Host $line
            }
        }

        Write-Host "##[endgroup]"
    }

function Invoke-Hook {
    <#
    .SYNOPSIS
        Invokes a configured hook path or ordered list with a Context hashtable.
    .DESCRIPTION
        Missing/empty hook configuration is a no-op. Replaces [alm] in each path
        with this library's repository root; other relative paths use the caller's
        current location, not BaseDirectory. AdditionalContext overwrites matching
        standard keys. Hook output flows through and missing scripts or failures
        stop execution; earlier hook side effects are not rolled back.
    .PARAMETER LogContext
        Controls diagnostic serialization of Context; disable for sensitive data.
    #>
    param(
        [string]$HookType,
        [string]$BaseDirectory,
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,
        [hashtable]$AdditionalContext = @{},
        [bool]$LogContext = $true
    )

    if ($Config.ContainsKey('hooks') -and $Config['hooks'] -is [hashtable] -and $Config['hooks'].ContainsKey($HookType) -and $Config['hooks'][$HookType]) {
        $hooks = $Config['hooks'][$HookType]
        if ($hooks -is [string]) {
            $hooks = @($hooks)
        }
        foreach ($hook in $hooks) {
            Write-Host "##[group] Executing $HookType hook: $hook"

            # Hooks receive the same configuration object, not an isolated copy.
            $context = @{
                HookType      = $HookType
                BaseDirectory = $BaseDirectory
                Config        = $Config
            }
            # Caller-supplied keys intentionally take precedence over the standard context.
            foreach ($key in $AdditionalContext.Keys) {
                $context[$key] = $AdditionalContext[$key]
            }

            # Replace [alm] placeholder with the absolute path of the ALM repo root
            $almRootPath = Join-Path -Path $PSScriptRoot -ChildPath ".." -AdditionalChildPath ".." | Resolve-Path | Select-Object -ExpandProperty Path
            $hookPath = $hook -replace '\[alm\]', $almRootPath

            if (Test-Path $hookPath) {

                if ($LogContext) { write-host "##[debug] Executing hook script at path: $hookPath with context: $($context | ConvertTo-Json -Depth 10)" }

                try {
                    & $hookPath -Context $context
                    if (-not $? ) { throw "Hook $hook failed" }
                } finally {
                    Write-Host "##[endgroup]"
                }

            }
            else {
                Write-Host "##[error]Hook script not found: $hookPath"
                Write-Host "##[endgroup]"
                throw "Hook script not found: $hookPath"
            }
        }
    }
}
