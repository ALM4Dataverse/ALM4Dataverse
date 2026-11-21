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

function Test-ApplicationOwnedScaffoldPath {
    # Scaffold files that applications are told to customize (agent instructions and
    # example data hooks) are created when missing but never overwritten by a re-run.
    # RelativePath uses forward slashes, relative to the copy-to-your-repo root.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$RelativePath)

    return ($RelativePath -ieq 'AGENTS.md' -or $RelativePath -like 'data/*')
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

function Initialize-SetupConsoleEscapeNavigationSupport {
    <#
    .SYNOPSIS
        Returns the process-wide console proxy for Escape navigation and F1 help.
    .DESCRIPTION
        The proxy is compiled once and decorates Spectre's console input at runtime.
        Escape requests navigation; F1 opens the active documentation URL and resumes
        the prompt. Compilation and browser-launch failures propagate.
    #>
    [CmdletBinding()]
    param()

    $typeName = 'ALM4Dataverse.SetupConsoleHelpDispatchProxy'
    $proxyType = ([System.Management.Automation.PSTypeName]$typeName).Type
    if ($null -ne $proxyType) {
        return $proxyType
    }

    $typeDefinition = @(
        'using System;'
        'using System.Diagnostics;'
        'using System.Reflection;'
        'using System.Runtime.ExceptionServices;'
        'using System.Threading.Tasks;'
        'namespace ALM4Dataverse {'
        '    public class SetupConsoleHelpDispatchProxy : DispatchProxy {'
        '        public object Inner { get; set; }'
        '        public object ReplacementInput { get; set; }'
        '        public string HelpUrl { get; set; }'
        '        public Action<string> HelpLauncher { get; set; }'
        ''
        '        protected override object Invoke(MethodInfo targetMethod, object[] args) {'
        '            if (ReplacementInput != null && targetMethod.Name == "get_Input") {'
        '                return ReplacementInput;'
        '            }'
        ''
        '            object result = InvokeInner(targetMethod, args);'
        ''
        '            if (targetMethod.Name == "ReadKey") {'
        '                return ReadKeyWithHelp(targetMethod, args, result);'
        '            }'
        ''
        '            if (targetMethod.Name == "ReadKeyAsync" && result != null) {'
        '                Type resultType = targetMethod.ReturnType.GetGenericArguments()[0];'
        '                MethodInfo wrapperMethod = typeof(SetupConsoleHelpDispatchProxy).GetMethod('
        '                    "WrapReadKeyAsync",'
        '                    BindingFlags.NonPublic | BindingFlags.Instance'
        '                );'
        '                return wrapperMethod.MakeGenericMethod(resultType).Invoke(this, new object[] { result, targetMethod, args });'
        '            }'
        ''
        '            return result;'
        '        }'
        ''
        '        private object InvokeInner(MethodInfo targetMethod, object[] args) {'
        '            try {'
        '                return targetMethod.Invoke(Inner, args);'
        '            }'
        '            catch (TargetInvocationException exception) {'
        '                if (exception.InnerException != null) {'
        '                    ExceptionDispatchInfo.Capture(exception.InnerException).Throw();'
        '                }'
        '                throw;'
        '            }'
        '        }'
        ''
        '        private object ReadKeyWithHelp(MethodInfo targetMethod, object[] args, object key) {'
        '            while (IsF1Key(key) && !String.IsNullOrWhiteSpace(HelpUrl)) {'
        '                OpenHelp();'
        '                key = InvokeInner(targetMethod, args);'
        '            }'
        '            ThrowIfEscapeKey(key);'
        '            return key;'
        '        }'
        ''
        '        private async Task<T> WrapReadKeyAsync<T>(Task<T> task, MethodInfo targetMethod, object[] args) {'
        '            T key = await task.ConfigureAwait(false);'
        '            while (IsF1Key(key) && !String.IsNullOrWhiteSpace(HelpUrl)) {'
        '                OpenHelp();'
        '                key = await ((Task<T>)InvokeInner(targetMethod, args)).ConfigureAwait(false);'
        '            }'
        '            ThrowIfEscapeKey(key);'
        '            return key;'
        '        }'
        ''
        '        private static bool IsF1Key(object value) {'
        '            return value is ConsoleKeyInfo && ((ConsoleKeyInfo)value).Key == ConsoleKey.F1;'
        '        }'
        ''
        '        private void OpenHelp() {'
        '            if (HelpLauncher != null) {'
        '                HelpLauncher(HelpUrl);'
        '                return;'
        '            }'
        '            Process process = Process.Start(new ProcessStartInfo { FileName = HelpUrl, UseShellExecute = true });'
        '            if (process == null) {'
        '                throw new InvalidOperationException("The operating system did not start a browser for setup help.");'
        '            }'
        '            process.Dispose();'
        '        }'
        ''
        '        private static void ThrowIfEscapeKey(object value) {'
        '            if (value is ConsoleKeyInfo && ((ConsoleKeyInfo)value).Key == ConsoleKey.Escape) {'
        '                throw new InvalidOperationException("__ALM4DATAVERSE_WIZARD_BACK__");'
        '            }'
        '        }'
        '    }'
        '}'
    ) -join [Environment]::NewLine

    Add-Type -TypeDefinition $typeDefinition -ErrorAction Stop
    $proxyType = ([System.Management.Automation.PSTypeName]$typeName).Type
    if ($null -eq $proxyType) {
        throw "Could not initialize setup console F1 help type '$typeName'."
    }

    return $proxyType
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

function Show-SetupFilePreview {
    <#
    .SYNOPSIS
        Displays generated file content in a setup preview panel.
    .DESCRIPTION
        Treats the file content as literal text so YAML and PowerShell markup
        characters are displayed without being interpreted by Spectre.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )

    Initialize-SpectreConsole
    $markup = [Spectre.Console.Markup]::new((ConvertTo-SpectreMarkupLiteral -Text $Content.TrimEnd("`r", "`n")))
    [Spectre.Console.AnsiConsole]::Write((New-SpectrePanel -Content $markup -Header $Path -BorderColor 'deepskyblue1' -Expand))
    [Spectre.Console.AnsiConsole]::WriteLine()
}
