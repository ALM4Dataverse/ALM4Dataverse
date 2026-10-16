# Shared library: dot-sourced by provider setup and embedded into release installers.
# Loading this file defines helpers only; console packages and service connections
# are initialized by callers, not at library load time.
function New-DirectoryIfMissing {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path) -and $PSCmdlet.ShouldProcess($Path, 'Create directory')) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Expand-SetupConsoleArchive {
    <#
    .SYNOPSIS
        Extracts a NuGet archive using the ZIP API available to Windows PowerShell.
    .DESCRIPTION
        Destination collisions and invalid archives propagate to the cache owner's
        retry logic. This helper neither clears the destination nor downloads files.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $DestinationPath)
}

function Get-SetupConsoleDependencyAssemblyPath {
    <#
    .SYNOPSIS
        Resolves one framework-specific DLL from a versioned NuGet cache.
    .DESCRIPTION
        Returns the DLL path, downloading and extracting under PackageRoot as needed.
        A failed extraction or missing DLL invalidates both cache entries before a
        fresh download. Final download/extraction failures, or an absent DLL, throw.
        PackageRoot must already exist; this does not load the returned assembly.
    .PARAMETER TargetFramework
        Exact lib subdirectory to inspect; no framework fallback is attempted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string]$PackageName,
        [Parameter(Mandatory)][string]$PackageVersion,
        [Parameter(Mandatory)][string]$TargetFramework,
        [Parameter(Mandatory)][string]$AssemblyName
    )

    $expandedRoot = Join-Path $PackageRoot "$PackageName.$PackageVersion"
    $packagePath = Join-Path $PackageRoot "$PackageName.$PackageVersion.nupkg"
    $assemblyPath = Join-Path $expandedRoot "lib\$TargetFramework\$AssemblyName.dll"
    $packageUrl = "https://www.nuget.org/api/v2/package/$PackageName/$PackageVersion"

    if (-not (Test-Path -LiteralPath $assemblyPath)) {
        if (Test-Path -LiteralPath $expandedRoot) {
            Remove-Item -LiteralPath $expandedRoot -Recurse -Force -ErrorAction SilentlyContinue
        }

        if (-not (Test-Path -LiteralPath $packagePath)) {
            try {
                if ($PSVersionTable.PSVersion.Major -lt 6) {
                    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                }
            }
            catch {
                Write-Verbose 'Could not set the legacy TLS preference; continuing with the current protocol settings.'
            }

            Invoke-WebRequest -Uri $packageUrl -OutFile $packagePath -UseBasicParsing
        }

        try {
            Expand-SetupConsoleArchive -ArchivePath $packagePath -DestinationPath $expandedRoot
        }
        catch {
            Remove-Item -LiteralPath $expandedRoot -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $packagePath -Force -ErrorAction SilentlyContinue
            Invoke-WebRequest -Uri $packageUrl -OutFile $packagePath -UseBasicParsing
            Expand-SetupConsoleArchive -ArchivePath $packagePath -DestinationPath $expandedRoot
        }

        if (-not (Test-Path -LiteralPath $assemblyPath)) {
            Remove-Item -LiteralPath $expandedRoot -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $packagePath -Force -ErrorAction SilentlyContinue
            Invoke-WebRequest -Uri $packageUrl -OutFile $packagePath -UseBasicParsing
            Expand-SetupConsoleArchive -ArchivePath $packagePath -DestinationPath $expandedRoot
        }
    }

    if (-not (Test-Path -LiteralPath $assemblyPath)) {
        throw "Could not locate $AssemblyName.dll after extracting package $PackageName version $PackageVersion."
    }

    return $assemblyPath
}

function Initialize-SetupConsoleFrameworkDependency {
    <#
    .SYNOPSIS
        Loads Spectre's supporting assemblies for Windows PowerShell only.
    .DESCRIPTION
        Uses the supplied package cache and loads dependencies in the listed order.
        An assembly already loaded by simple name is reused, regardless of version.
        Core editions return without work; package and assembly-load failures throw.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackageRoot
    )

    if ($PSVersionTable.PSEdition -eq 'Core') {
        return
    }

    # Spectre.Console 0.49.1 targets netstandard2.0 and depends on the .NET
    # Framework builds of these packages when running in Windows PowerShell.
    $dependencies = @(
        [pscustomobject]@{
            PackageName      = 'System.Runtime.CompilerServices.Unsafe'
            PackageVersion   = '4.5.3'
            TargetFramework  = 'net461'
            AssemblyName     = 'System.Runtime.CompilerServices.Unsafe'
        },
        [pscustomobject]@{
            PackageName      = 'System.Buffers'
            PackageVersion   = '4.5.1'
            TargetFramework  = 'net461'
            AssemblyName     = 'System.Buffers'
        },
        [pscustomobject]@{
            PackageName      = 'System.Numerics.Vectors'
            PackageVersion   = '4.5.0'
            TargetFramework  = 'net46'
            AssemblyName     = 'System.Numerics.Vectors'
        },
        [pscustomobject]@{
            PackageName      = 'System.Memory'
            PackageVersion   = '4.5.5'
            TargetFramework  = 'net461'
            AssemblyName     = 'System.Memory'
        }
    )

    foreach ($dependency in $dependencies) {
        $assemblyPath = Get-SetupConsoleDependencyAssemblyPath `
            -PackageRoot $PackageRoot `
            -PackageName $dependency.PackageName `
            -PackageVersion $dependency.PackageVersion `
            -TargetFramework $dependency.TargetFramework `
            -AssemblyName $dependency.AssemblyName

        $alreadyLoaded = [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object {
            $_.GetName().Name -eq $dependency.AssemblyName
        } | Select-Object -First 1

        if (-not $alreadyLoaded) {
            Add-Type -Path $assemblyPath -ErrorAction Stop
        }
    }
}

function Initialize-SetupConsoleCancellationSupport {
    <#
    .SYNOPSIS
        Returns the process-wide C# bridge for console cancellation.
    .DESCRIPTION
        Compiles the bridge once per process. Start owns a single active token source
        and throws on overlapping registrations; null means the host rejected the
        event subscription. Stop detaches the matching source and disposes it.
        Compilation failures propagate.
    #>
    [CmdletBinding()]
    param()

    $typeName = 'ALM4Dataverse.SetupConsoleCancellation'
    $cancellationType = ([System.Management.Automation.PSTypeName]$typeName).Type
    if ($null -ne $cancellationType) {
        return $cancellationType
    }

    # Console events run outside the PowerShell runspace, so cancellation stays in
    # compiled code. SyncRoot protects registration and source identity, not Cancel:
    # OnCancel releases the lock before invoking callbacks. A concurrent Stop can
    # dispose the captured source; that race is deliberately swallowed by OnCancel.
    # The event suppresses process termination only while an active source exists.
    # Keep this explanation outside the string array to preserve embedded source.
    $typeDefinition = @(
        'using System;'
        'using System.Threading;'
        'namespace ALM4Dataverse {'
        '    public static class SetupConsoleCancellation {'
        '        private static readonly object SyncRoot = new object();'
        '        private static readonly ConsoleCancelEventHandler CancelHandler = OnCancel;'
        '        private static CancellationTokenSource ActiveSource;'
        ''
        '        public static CancellationTokenSource Start() {'
        '            lock (SyncRoot) {'
        '                if (ActiveSource != null) {'
        '                    throw new InvalidOperationException("A setup console cancellation handler is already active.");'
        '                }'
        ''
        '                var source = new CancellationTokenSource();'
        '                ActiveSource = source;'
        '                try {'
        '                    Console.CancelKeyPress += CancelHandler;'
        '                }'
        '                catch {'
        '                    ActiveSource = null;'
        '                    source.Dispose();'
        '                    return null;'
        '                }'
        ''
        '                return source;'
        '            }'
        '        }'
        ''
        '        public static void Stop(CancellationTokenSource source) {'
        '            if (source == null) {'
        '                return;'
        '            }'
        ''
        '            lock (SyncRoot) {'
        '                if (object.ReferenceEquals(ActiveSource, source)) {'
        '                    ActiveSource = null;'
        '                    try {'
        '                        Console.CancelKeyPress -= CancelHandler;'
        '                    }'
        '                    catch {'
        '                    }'
        '                }'
        '            }'
        ''
        '            source.Dispose();'
        '        }'
        ''
        '        private static void OnCancel(object sender, ConsoleCancelEventArgs eventArgs) {'
        '            CancellationTokenSource source;'
        '            lock (SyncRoot) {'
        '                source = ActiveSource;'
        '            }'
        ''
        '            if (source == null) {'
        '                return;'
        '            }'
        ''
        '            eventArgs.Cancel = true;'
        '            try {'
        '                source.Cancel();'
        '            }'
        '            catch (ObjectDisposedException) {'
        '            }'
        '            catch {'
        '            }'
        '        }'
        '    }'
        '}'
    ) -join [Environment]::NewLine

    Add-Type -TypeDefinition $typeDefinition -ErrorAction Stop
    $cancellationType = ([System.Management.Automation.PSTypeName]$typeName).Type
    if ($null -eq $cancellationType) {
        throw "Could not initialize setup console cancellation support type '$typeName'."
    }

    return $cancellationType
}

function Initialize-SpectreConsole {
    <#
    .SYNOPSIS
        Makes the optional console assembly available in the current process.
    .DESCRIPTION
        Reuses an already loaded Spectre type or downloads an edition-specific
        package into the shared temporary cache. Incomplete cache entries are
        refreshed; unrecoverable download, extraction and load failures propagate.
        Records successful initialization in script scope. It emits no result.
    #>
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
        Write-Verbose 'The console assembly is not loaded; loading it from the configured package.'
    }

    # Spectre.Console 0.50+ uses a System.Memory build that references .NET 8
    # framework assemblies. That works in PowerShell 7, but Windows PowerShell
    # 5.1 runs on .NET Framework and cannot load those references. Keep the
    # historically compatible package for Windows PowerShell.
    $spectreVersion = if ($PSVersionTable.PSEdition -eq 'Core') { '0.53.1' } else { '0.49.1' }
    $packageRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'ALM4Dataverse\SpectreConsole'
    $expandedRoot = Join-Path $packageRoot $spectreVersion
    $packagePath = Join-Path $packageRoot "Spectre.Console.$spectreVersion.nupkg"

    New-DirectoryIfMissing -Path $packageRoot

    $hasExtractedAssembly = $false
    if (Test-Path -LiteralPath $expandedRoot) {
        $hasExtractedAssembly = $null -ne (Get-ChildItem -LiteralPath $expandedRoot -Recurse -Filter 'Spectre.Console.dll' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
    }

    if (-not $hasExtractedAssembly) {
        # An interrupted or otherwise incomplete extraction can leave the destination
        # directory behind. Do not treat that directory as a valid cache entry.
        if (Test-Path -LiteralPath $expandedRoot) {
            Remove-Item -LiteralPath $expandedRoot -Recurse -Force -ErrorAction SilentlyContinue
        }

        $packageUrl = "https://www.nuget.org/api/v2/package/Spectre.Console/$spectreVersion"
        if (-not (Test-Path -LiteralPath $packagePath)) {
            try {
                if ($PSVersionTable.PSVersion.Major -lt 6) {
                    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                }
            }
            catch {
                Write-Verbose 'Could not set the legacy TLS preference; continuing with the current protocol settings.'
            }

            Invoke-WebRequest -Uri $packageUrl -OutFile $packagePath -UseBasicParsing
        }

        try {
            Expand-SetupConsoleArchive -ArchivePath $packagePath -DestinationPath $expandedRoot
        }
        catch {
            # A partially downloaded archive can remain in the cache. Remove it and
            # retry once so a transient download does not permanently break setup.
            Remove-Item -LiteralPath $expandedRoot -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $packagePath -Force -ErrorAction SilentlyContinue
            Invoke-WebRequest -Uri $packageUrl -OutFile $packagePath -UseBasicParsing
            Expand-SetupConsoleArchive -ArchivePath $packagePath -DestinationPath $expandedRoot
        }

        $hasExtractedAssembly = $null -ne (Get-ChildItem -LiteralPath $expandedRoot -Recurse -Filter 'Spectre.Console.dll' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
        if (-not $hasExtractedAssembly) {
            Remove-Item -LiteralPath $expandedRoot -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $packagePath -Force -ErrorAction SilentlyContinue
            Invoke-WebRequest -Uri $packageUrl -OutFile $packagePath -UseBasicParsing
            Expand-SetupConsoleArchive -ArchivePath $packagePath -DestinationPath $expandedRoot
        }
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
        $spectreAssemblyPath = Get-ChildItem -LiteralPath $expandedRoot -Recurse -Filter 'Spectre.Console.dll' -File |
            Select-Object -ExpandProperty FullName -First 1
    }

    if (-not $spectreAssemblyPath) {
        throw "Could not locate Spectre.Console.dll after extracting package version $spectreVersion."
    }

    Initialize-SetupConsoleFrameworkDependency -PackageRoot $packageRoot
    Add-Type -Path $spectreAssemblyPath -ErrorAction Stop
    $script:SpectreConsoleInitialized = $true
    $script:SpectreConsoleAssemblyPath = $spectreAssemblyPath
}

function ConvertTo-SpectreMarkupLiteral {
    # Null becomes empty text; brackets are escaped rather than interpreted as styling.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()][string]$Text
    )

    if ($null -eq $Text) {
        return ''
    }

    return ([string]$Text).Replace('[', '[[').Replace(']', ']]')
}

function Get-OptionalObjectPropertyValue {
    <#
    .SYNOPSIS
        Reads a hashtable key or object property without requiring its presence.
    .DESCRIPTION
        Returns null for a missing property or null input. Present false, zero and
        empty values are preserved, so callers must not use truthiness as existence.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][object]$InputObject,
        [Parameter(Mandatory)][string]$PropertyName
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [hashtable]) {
        if ($InputObject.ContainsKey($PropertyName)) {
            return $InputObject[$PropertyName]
        }

        return $null
    }

    if ($InputObject.PSObject -and $null -ne $InputObject.PSObject.Properties[$PropertyName]) {
        return $InputObject.$PropertyName
    }

    return $null
}

function Test-SetupResourceNotFound {
    # Only an HTTP 404 on the exception chain means missing; permission and other
    # failures must remain failures rather than silently triggering resource creation.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        $response = Get-OptionalObjectPropertyValue -InputObject $exception -PropertyName 'Response'
        $statusCode = Get-OptionalObjectPropertyValue -InputObject $response -PropertyName 'StatusCode'
        if ($null -ne $statusCode -and [int]$statusCode -eq 404) {
            return $true
        }
        $exception = $exception.InnerException
    }
    return $false
}

function Invoke-GenericStaticMethod {
    <#
    .SYNOPSIS
        Invokes a public generic static method through reflection.
    .DESCRIPTION
        Tries overloads matching generic arity and argument count in reflection
        order, returning the first successful result. Type compatibility is left
        to reflection. If none succeeds, throws the first invocation error (or a
        missing-method error); candidates may already have executed before failure.
    #>
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
    # Opt-in values are trimmed and case-insensitive; an unset or other value is off.
    [CmdletBinding()]
    [OutputType([bool])]
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
    # Column labels are literal text; the returned table is not written to the console.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Optional console assembly is loaded inside the function; the string OutputType declares its return type without eager assembly resolution.')]
    [CmdletBinding()]
    [OutputType('Spectre.Console.Table')]
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
    # Mutates the supplied table without emitting it; cell markup is always escaped.
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
    <#
    .SYNOPSIS
        Builds a rounded panel without rendering it.
    .PARAMETER Content
        Spectre-compatible content; unlike Header, this is not escaped here.
    .PARAMETER HeaderMarkup
        Trusted Spectre markup, taking precedence over the literal Header text.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Optional console assembly is loaded inside the function; the string OutputType declares its return type without eager assembly resolution.')]
    [CmdletBinding()]
    [OutputType('Spectre.Console.Panel')]
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
    # Returns an expanded two-column grid; keys and values are literal text and
    # enumeration order is the supplied hashtable's order, not a sort order.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Optional console assembly is loaded inside the function; the string OutputType declares its return type without eager assembly resolution.')]
    [CmdletBinding()]
    [OutputType('Spectre.Console.Grid')]
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

function New-SpectreMetricColumn {
    <#
    .SYNOPSIS
        Builds metric panels from hashtables or objects without rendering them.
    .DESCRIPTION
        Cards may supply Label, Value, Detail and AccentColor; missing text is empty
        and missing color defaults to deepskyblue1. Null cards are skipped. Text is
        escaped, but AccentColor is trusted Spectre styling and may fail to parse.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Optional console assembly is loaded inside the function; the string OutputType declares its return type without eager assembly resolution.')]
    [CmdletBinding()]
    [OutputType('Spectre.Console.Columns')]
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

function Show-SpectreMetricCard {
    # No cards means no console initialization or output, rather than an empty panel.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][array]$Cards
    )

    $filteredCards = @($Cards | Where-Object { $null -ne $_ })
    if ($filteredCards.Count -eq 0) {
        return
    }

    Initialize-SpectreConsole
    [Spectre.Console.AnsiConsole]::Write((New-SpectreMetricColumn -Cards $filteredCards))
    [Spectre.Console.AnsiConsole]::WriteLine()
}

function Show-SolutionSelectionOverview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$SelectedCount,
        [Parameter(Mandatory)][int]$AvailableCount
    )

    $remainingCount = [Math]::Max($AvailableCount - $SelectedCount, 0)
    Show-SpectreMetricCard -Cards @(
        @{ Label = 'Selected'; AccentColor = 'green3_1'; Value = [string]$SelectedCount; Detail = 'Chosen for source control' },
        @{ Label = 'Remaining'; AccentColor = $(if ($remainingCount -gt 0) { 'deepskyblue1' } else { 'grey42' }); Value = [string]$remainingCount; Detail = 'Still available to add' },
        @{ Label = 'Available total'; AccentColor = 'mediumpurple3'; Value = [string]$AvailableCount; Detail = 'Detected in the environment' }
    )
}

function Show-EnvironmentConfigurationOverview {
    # Readiness here is a display heuristic, not validation: pending flags, missing
    # credentials or missing service-account UPNs count as pending. Auth counts only
    # recognize WIF/Secret, and service-account uniqueness uses Select-Object semantics.
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

    Show-SpectreMetricCard -Cards @(
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
    # Script-scoped display/navigation state; CurrentStepIndex is zero-based.
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
        Executes named setup steps with exception-based backward navigation.
    .PARAMETER Steps
        Ordered objects with Name and Action scriptblock properties. Action output
        passes through; actions own their state and may run again after going back.
    .DESCRIPTION
        A back marker repeats the preceding step (or the first step at index zero).
        Other errors propagate. Wizard context is cleared even after failure; no
        rollback of action side effects or restoration of an outer context occurs.
    #>
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


function Show-SetupPromptGuidance {
    # Prompt-local guidance must not replace the section's stored documentation context.
    [CmdletBinding()]
    param(
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
    # Menu hints describe filtering only when enabled. Cursor-host failures render
    # an inline status line, which Clear-SetupStatusBarAtBottom cannot erase.
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
        Runs an async Spectre selection prompt synchronously with Ctrl+C cancellation.
    .DESCRIPTION
        Returns the prompt's selected value. Uses the compiled console-event bridge
        when supported, otherwise a local token source. Cancellation is normalized
        to OperationCanceledException; other failures propagate. The source and any
        attached handler are released in finally, including on prompt failure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Prompt
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

        return $Prompt.ShowAsync([Spectre.Console.AnsiConsole]::Console, $cancellationTokenSource.Token).GetAwaiter().GetResult()
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

function Write-SetupPromptFrame {
    # Rebuild the current section unless preserving content; guidance suppression
    # does not suppress that redraw. Without a section, existing content stays.
    [CmdletBinding()]
    param(
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

function Read-SecretText {
    <#
    .SYNOPSIS
        Reads masked input and returns its plaintext string.
    .DESCRIPTION
        Masking is display-only, not SecureString storage. Nonblank input retains
        whitespace. Blank input retries unless AllowEmpty, which returns an empty
        string even for whitespace-only input. Prompt failures propagate after
        status-bar cleanup.
    #>
    [CmdletBinding()]
    [OutputType([string])]
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

        Write-SetupPromptFrame  -PromptText $Prompt -PromptGuidanceLines $PromptGuidanceLines -PromptGuidanceDocRelativePath $PromptGuidanceDocRelativePath -PromptGuidanceRef $PromptGuidanceRef -PromptGuidanceLinkLabel $PromptGuidanceLinkLabel
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
    # Starts a new display section, discarding prompt-document context and clearing
    # the console. Section guidance is display-only and needs nonempty GuidanceLines.
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
        Returns a zero-based index into Items, or null for no items, the injected
        cancel choice, or an unrecognized prompt result. Back choices throw the
        wizard navigation marker rather than returning an index. Literal labels
        are escaped for display; duplicate labels resolve to their first match.
        Console input mode restoration is attempted after selection, including prompt failure.
    .PARAMETER PreserveExistingContent
        Prevents the usual section redraw before showing this prompt.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Items,
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

    Write-SetupPromptFrame  -PromptText $Title -PromptGuidanceLines $PromptGuidanceLines -PromptGuidanceDocRelativePath $PromptGuidanceDocRelativePath -PromptGuidanceRef $PromptGuidanceRef -PromptGuidanceLinkLabel $PromptGuidanceLinkLabel -PreserveExistingContent:$PreserveExistingContent -SkipPromptGuidance:$SkipPromptGuidance

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

    $effectiveDisplayItems = @()
    foreach ($item in $effectiveItems) {
        $effectiveDisplayItems += [string](ConvertTo-SpectreMarkupLiteral -Text $item)
    }

    foreach ($displayItem in $effectiveDisplayItems) {
        [void]$prompt.AddChoice($displayItem)
    }

    Show-SetupStatusBarAtBottom -PromptKind 'Menu' -SearchEnabled:$prompt.SearchEnabled

    try {
        $selectedDisplayValue = Show-SelectionPromptWithInterruptHandling -Prompt $prompt
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
    # Returns a boolean with Yes as the default unless DefaultNo; the status bar
    # is cleared on prompt failure, which is allowed to propagate.
    [CmdletBinding()]
    [OutputType([bool])]
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

    Write-SetupPromptFrame  -PromptText $Prompt -PromptGuidanceLines $PromptGuidanceLines -PromptGuidanceDocRelativePath $PromptGuidanceDocRelativePath -PromptGuidanceRef $PromptGuidanceRef -PromptGuidanceLinkLabel $PromptGuidanceLinkLabel
    Show-SetupStatusBarAtBottom -PromptKind 'YesNo'
    try {
        return [Spectre.Console.AnsiConsole]::Confirm((Get-SetupPromptInlineText -PromptKind 'YesNo' -PromptText $Prompt), (-not $DefaultNo))
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
        Best-effort placement of a markup link over the last rendered panel border.
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
        Displays escaped guidance lines with an optional documentation-link overlay.
    .DESCRIPTION
        Blank lines are omitted; a link alone can produce a panel. Updates the
        script prompt-document context even when there is nothing to render, unless
        SkipContextUpdate is set. A rendered panel requires a nonblank trimmed header.
        The overlay is best-effort; other console failures propagate.
    .PARAMETER Ref
        Documentation revision, falling back to script ALM4DataverseRef then stable.
    #>
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
    $panelHeaderMarkup = Get-SetupGuidanceHeaderMarkup -Header $effectiveHeader
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
    <#
    .SYNOPSIS
        Reads trimmed text, with optional default or explicitly empty input.
    .DESCRIPTION
        Blank input returns a nonblank DefaultValue unchanged before considering
        AllowEmpty; otherwise AllowEmpty returns an empty string and required input
        retries. Nonblank typed values are trimmed. Prompt errors propagate after
        status-bar cleanup. A blank prompt label is rejected.
    #>
    [CmdletBinding()]
    [OutputType([string])]
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
        Write-SetupPromptFrame  -PromptText $Prompt -PromptGuidanceLines $PromptGuidanceLines -PromptGuidanceDocRelativePath $PromptGuidanceDocRelativePath -PromptGuidanceRef $PromptGuidanceRef -PromptGuidanceLinkLabel $PromptGuidanceLinkLabel
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
    # Sanitization can erase a name, so use setup/main fallbacks. UTC seconds make
    # readable suggestions, not collision-proof branch reservations.
    [CmdletBinding()]
    [OutputType([string])]
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
    <#
    .SYNOPSIS
        Collects a provider-neutral repository publication decision without publishing.
    .DESCRIPTION
        Returns Mode, BranchName, TargetBranch, CommitMessage, PullRequestTitle and
        PullRequestDescription. Direct mode can target BaseBranch or another entered
        branch and has null PR fields; PullRequest mode always targets BaseBranch.
        A cancelled menu throws. Branch existence/protection is not checked here.
    #>
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
    <#
    .SYNOPSIS
        Collects a direct-commit or PR plan for one fixed target branch.
    .DESCRIPTION
        Returns the publication fields used by Get-RepoChangePublishPlan, but never
        offers another target: TargetBranch stays fixed in both modes. BranchName
        is the direct target or the entered PR source. Cancellation throws; this
        helper prompts only and does not contact the provider or validate branches.
    #>
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
    # Only identity/type fields are read, never secret values. Name wins over
    # ApplicationId; existing connections have their own label; null returns empty.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]$Credentials
    )

    if ($null -eq $Credentials) {
        return ''
    }

    $name = ''
    if ($null -ne $Credentials.PSObject.Properties['Name'] -and -not [string]::IsNullOrWhiteSpace($Credentials.Name)) {
        $name = [string]$Credentials.Name
    }
    elseif ($null -ne $Credentials.PSObject.Properties['ApplicationId'] -and -not [string]::IsNullOrWhiteSpace($Credentials.ApplicationId)) {
        $name = [string]$Credentials.ApplicationId
    }

    if ($null -ne $Credentials.PSObject.Properties['IsExistingServiceConnection'] -and $Credentials.IsExistingServiceConnection) {
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            return "Existing service connection - $name"
        }
        return 'Existing service connection'
    }

    $authType = 'Credential'
    if ($null -ne $Credentials.PSObject.Properties['AuthType'] -and -not [string]::IsNullOrWhiteSpace($Credentials.AuthType)) {
        $authType = [string]$Credentials.AuthType
    }

    if (-not [string]::IsNullOrWhiteSpace($name)) {
        return "$authType - $name"
    }

    return $authType
}

function Show-EnvironmentConfigurationTable {
    # Expected rows have ShortName, FriendlyName, Url and Credentials; only the
    # ServiceAccountUPN field is optional here. Credential summaries omit secrets.
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

function Select-BuildValidationBaselineEnvironment {
    <#
    .SYNOPSIS
        Selects an @shortName deployment baseline distinct from the BUILD environment.
    .DESCRIPTION
        Deduplicates nonblank short names case-insensitively. Exclusions match either
        short name or URL ignoring case and trailing slashes, not full URL normalization.
        Returns empty for no eligible environments or an explicit no-baseline choice;
        a cancelled prompt throws. This chooses a selector, not a release artifact.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][array]$DeploymentEnvironments,
        [Parameter()][AllowEmptyString()][string]$ExcludedEnvironmentName = '',
        [Parameter()][AllowEmptyString()][string]$ExcludedEnvironmentUrl = ''
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

    $items = @('No baseline release') + @($uniqueEnvironments | ForEach-Object {
        $friendlyName = if ([string]::IsNullOrWhiteSpace($_.FriendlyName)) { $_.ShortName } else { $_.FriendlyName }
        "$friendlyName ($($_.ShortName))"
    })
    $selectedIndex = Select-FromMenu -Title 'Select the separate deployment environment whose latest successful deployment should be used as the BUILD validation baseline' -Items $items
    if ($null -eq $selectedIndex) {
        throw 'No BUILD validation baseline choice was selected.'
    }
    if ($selectedIndex -eq 0) {
        return ''
    }

    return "@$($uniqueEnvironments[$selectedIndex - 1].ShortName)"
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
    .DESCRIPTION
        Initial objects are retained, not deep-cloned. Done or a null management
        selection emits the current list. Callbacks own validation and side effects;
        exceptions, including wizard navigation, propagate without rollback.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
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

function Select-BranchEnvironmentMapping {
    <#
    .SYNOPSIS
        Edits branch/DEV/deployment mappings before provider publication.
    .PARAMETER BranchOnly
        Hides the built-in environment assignment editor; callback-based editors
        remain available.
    .PARAMETER EditDevEnvironmentScriptBlock
        Receives the complete mapping array as one argument, then the current mapping.
        Its result replaces DevEnvironmentConfiguration, including a null result.
    .PARAMETER EditDeploymentEnvironmentsScriptBlock
        Receives the complete mapping array and current mapping. Its non-null outputs
        replace Environments; no output clears that list.
    .DESCRIPTION
        Copies mapping records but shares nested environment objects. A sole empty
        main mapping triggers bootstrap strategy selection and environment callbacks.
        Built-in assignment excludes other branches' targets and sorts by ShortName.
        Done checks cross-branch deployment duplicates; a null management selection
        returns current mappings without that check. Callback failures/back navigation
        propagate; no resource changes made by callbacks are rolled back.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject], [object[]])]
    param(
        [Parameter()][AllowEmptyCollection()][array]$EnvironmentConfigurations = @(),
        [Parameter()][array]$InitialBranchMappings,
        [Parameter()][string]$Title = 'Manage deployment branches and environment mappings',
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

    # This exact empty-main shape is the bootstrap signal; existing configured
    # repositories must not have their branch strategy inferred again.
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
                if (Test-BranchEnvironmentMappingDuplicate -BranchMappings $branchMappings) {
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
    # Installs for the current user only when provider discovery returns nothing;
    # installation errors follow the caller's error preference.
    $nuget = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
    if (-not $nuget) {
        Write-Host "Installing NuGet package provider (required for Save-Module)..." -ForegroundColor Yellow
        Install-PackageProvider -Name NuGet -Force -Scope CurrentUser | Out-Null
    }
}

function Get-ModuleAvailableExact {
    # Returns the first discoverable exact-version PSModuleInfo, or null. This
    # checks disk availability on PSModulePath, not whether a module is loaded.
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$RequiredVersion
    )

    $mods = Get-Module -Name $Name -ListAvailable -ErrorAction SilentlyContinue
    if (-not $mods) { return $null }

    return $mods | Where-Object { $_.Version -eq [version]$RequiredVersion } | Select-Object -First 1
}

function Save-ModuleExact {
    # Downloads the pinned version (and Save-Module dependencies); Destination
    # must be made discoverable separately before Import-RequiredModuleVersion runs.
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
    <#
    .SYNOPSIS
        Imports and verifies an exact module version, downloading it if unavailable.
    .DESCRIPTION
        Destination must already be on PSModulePath; saving there does not amend
        the search path. Rechecks discoverability after download, then force-imports
        and verifies the loaded version. Failures throw. Host messages, not the
        loaded module object, are the normal output.
    #>
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
    <#
    .SYNOPSIS
        Chooses a local branch or detached commit for development setup.
    .DESCRIPTION
        Checks PrimaryRepositoryPath then this script's directory, skipping locations
        without .git. Returns a nonblank current branch or a 40-character lowercase
        commit; otherwise returns FallbackRef. Caught command/processing errors throw
        with repository context rather than silently falling back. Restores the
        caller's error preference after each probe.
    #>
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

                # Detached HEAD emits no output; join first so trimming is safe for an empty result.
                $branch = (@(& git -C $repoPath branch --show-current 2>$null) -join [Environment]::NewLine).Trim()
                if (-not [string]::IsNullOrWhiteSpace($branch)) {
                    Write-Host "Development mode: Using current local branch '$branch' as ALM4DataverseRef" -ForegroundColor Yellow
                    return $branch
                }

                $commit = (@(& git -C $repoPath rev-parse HEAD 2>$null) -join [Environment]::NewLine).Trim()
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
        menu throws a setup-aborted error.
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
    <#
    .SYNOPSIS
        Acquires an MSAL user authentication result, or lists cached usernames.
    .PARAMETER ResourceUrl
        Resource authority used to form its /.default scope after trimming slashes.
    .PARAMETER TenantId
        Authority tenant for initial client construction; blank uses common.
    .PARAMETER ForceInteractive
        Skips silent acquisition and requests account selection in the interactive flow.
    .PARAMETER PreferredUsername
        Case-insensitive cached-account preference and interactive login hint, not
        an enforced identity. Missing matches fall back to the first cached account.
    .PARAMETER ListAccountsOnly
        Returns distinct nonblank cached usernames instead of an authentication result;
        still loads MSAL, constructs/reuses the client and reads the disk cache.
    .DESCRIPTION
        Requires MSAL already available or discoverable inside the loaded Dataverse
        module. Script-scoped MsalApp is reused: ClientId and TenantId only affect
        its first construction. Loads/saves serialized MSAL V3 bytes under local app
        data without additional encryption here; cache read/write failures warn.
        Silent failure falls back interactively; interactive acquisition errors throw.
        The normal result is MSAL AuthenticationResult, not just its access-token text.
    #>
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
        Write-Verbose 'Silent token acquisition failed; retrying interactively.'
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
    <#
    .SYNOPSIS
        Requests a new password credential on an Entra application object.
    .PARAMETER ApplicationObjectId
        Graph application object ID, not the client/application ID.
    .DESCRIPTION
        ShouldProcess precedes authentication and the Graph write; rejection emits
        nothing. Returns the response's plaintext secretText; existing credentials
        are not removed. Graph/authentication failures propagate. This helper-level
        guard does not make an entire setup wizard a dry run.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$ApplicationObjectId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter()][string]$DisplayName = 'ALM4Dataverse Setup'
    )

    if (-not $PSCmdlet.ShouldProcess($ApplicationObjectId, 'Create Entra application secret')) { return }

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
    # Uses the provider-defined environment catalog and normalized WebApplication
    # endpoint identity. Blank URL, no match or catalog failure returns FallbackName;
    # lookup failures are informational and never block setup.
    [CmdletBinding()]
    [OutputType([string])]
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
    <#
    .SYNOPSIS
        Resolves an application/client ID to the first matching Graph application.
    .DESCRIPTION
        Blank tenant/application IDs return null. Script cache keys combine both IDs;
        successful results, missing results and REST failures (warning plus null) are
        cached for the session. Authentication occurs outside the REST catch and
        therefore propagates rather than becoming a cached miss. Returned fields
        are id, appId and displayName; no object is created.
    #>
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
