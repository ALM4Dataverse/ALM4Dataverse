#!/usr/bin/env pwsh
<#
.SYNOPSIS
Interactively configures Azure DevOps repositories, pipelines and Dataverse environments.
.DESCRIPTION
Requires an interactive Windows PowerShell 5.1 session on Windows or PowerShell 7 on
Windows or Linux, and identities allowed to administer the selected Azure DevOps project
and Dataverse environments. Downloads pinned modules and portable Git on Windows; on
Linux, uses system Git from PATH. Authenticates, then offers branch-aware setup and
publication choices. Remote resource provisioning can occur before repository changes
are published; cancelling publication does not roll back those resources.
ApplyConfig reads the selected existing repository's committed alm-config.psd1,
reviews generated changes and publishes them without editing settings or provisioning
Azure DevOps pipelines, permissions or environment resources.
.NOTES
Selected mutation helpers support ShouldProcess; the interactive installer as a whole
does not provide a dry run.
.PARAMETER TenantId
Optional tenant hint for the initial Azure DevOps token acquisition.
.PARAMETER UseDeviceAuthentication
Retained for invocation compatibility; the current authentication flow does not use it.
.PARAMETER ALM4DataverseRef
Upstream template ref. Releases supply a default; development resolves a local branch or
commit after Git is available, falling back to stable.
.PARAMETER ApplyConfig
Read the committed alm-config.psd1 from an existing repository, review the generated
changes and publish them without running the configuration editors.
.PARAMETER PreviewOnly
With ApplyConfig, display the generated change summary and select individual file
diffs to view without publishing. Selected diffs are written without paging.
Supplying AccessToken, OrganizationName, ProjectName and RepositoryName makes the
run unattended (used by the APPLY-CONFIG caller's preview option).
.EXAMPLE
.\setup-azdo.ps1 -TenantId contoso.onmicrosoft.com -ALM4DataverseRef stable
.EXAMPLE
.\setup-azdo.ps1 -ApplyConfig
.EXAMPLE
.\setup-azdo.ps1 -ApplyConfig -PreviewOnly
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'UseDeviceAuthentication', Justification = 'Legacy installer switch retained for invocation compatibility; current authentication does not consume it.')]
[CmdletBinding()]
param(
    [Parameter()]
    [string]$TenantId,

    [Parameter()]
    [switch]$UseDeviceAuthentication,

    [Parameter()]
    [string]$ALM4DataverseRef,

    [Parameter()]
    [switch]$ApplyConfig,

    [Parameter()]
    [switch]$PreviewOnly,

    [Parameter()]
    [switch]$Commit,

    [Parameter()]
    [string]$AccessToken,

    [Parameter()]
    [string]$OrganizationName,

    [Parameter()]
    [string]$ProjectName,

    [Parameter()]
    [string]$RepositoryName
)

$resolveDevRefAfterGitIsAvailable = $false

# ALM4DataverseRef default handling - injected during release, fallback for development
if (-not $ALM4DataverseRef) {
    $injectedRef = 'dev'
    if ($injectedRef -like '__*') {
        # Placeholders not replaced - development mode.
        # We resolve this after Git is available to support local branch/commit selection.
        $resolveDevRefAfterGitIsAvailable = $true
        Write-Host "Development mode: Will resolve ALM4DataverseRef from current branch/commit after Git is available (fallback: 'stable')." -ForegroundColor Yellow
        $ALM4DataverseRef = 'stable'
    } else {
        $ALM4DataverseRef = $injectedRef
    }
}

$script:SetupDefaultHelpDocRelativePath = 'docs/setup/azdo-automated-setup.md'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue' # Suppress progress bars

if ($PreviewOnly -and -not $ApplyConfig) {
    throw 'PreviewOnly requires ApplyConfig.'
}

if ($Commit -and -not $ApplyConfig) {
    throw 'Commit requires ApplyConfig.'
}

if ($Commit -and $PreviewOnly) {
    throw 'Commit cannot be combined with PreviewOnly.'
}

if ($Commit -and (@($AccessToken, $OrganizationName, $ProjectName, $RepositoryName) | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0) {
    throw 'Commit requires AccessToken, OrganizationName, ProjectName and RepositoryName so setup can resolve resources without prompts.'
}

# Fully supplied resource parameters make ApplyConfig run unattended for Commit
# and PreviewOnly (the apply-config caller uses this); without them, setup stays interactive.
$headlessMode = ($Commit -or $PreviewOnly) -and $ApplyConfig -and -not (@($AccessToken, $OrganizationName, $ProjectName, $RepositoryName) | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0

# Release preparation embeds the ordered helper source into this installer.
# Version numbers and the ALM4Dataverse ref are injected during release.

# Keep the user-facing setup steps aligned with docs/setup/azdo-automated-setup.md.

# Dot-sourced helper fragments share this script's state; release preparation embeds
# the same source so the published installer remains a single file.
$script:SetupRepositoryRoot = if ($PSScriptRoot) { $PSScriptRoot } else { $null }
$setupCommonPath = if ($script:SetupRepositoryRoot) { Join-Path $script:SetupRepositoryRoot 'setup/setup-common.ps1' } else { $null }
if ($setupCommonPath -and (Test-Path -LiteralPath $setupCommonPath)) {
    . $setupCommonPath
}
else {
    function Get-AlmSharedTemplateVersion {
    <#
    .SYNOPSIS
        Returns the shared template version embedded in generated caller files.
    .DESCRIPTION
        Shared templates and composite actions stop caller files that were generated
        for a different version. Bump this value whenever a shared template or action
        change requires callers to be regenerated, and update the expected literals in
        pipelines/templates/steps/validate-shared-template-version.yml and
        .github/actions/common/validate-caller-version.ps1 in the same change; the
        repository tests enforce that all three agree.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return '1'
}

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
        Interactive terminals support arrow keys, Page Up/Down, Home/End and Enter,
        Q or Esc to close. A centered filename heading and distinct BEFORE/AFTER labels
        identify the file and diff sides; the bottom status bar shows the visible row
        range and controls. NoPaging writes the full view once for command-line preview
        output.
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

    $fileChange = $FileChanges[0]
    $headerText = "$($fileChange.Status): $($fileChange.Path)"
    $headerColor = switch ($fileChange.Status) {
        'Added' { 'green' }
        'Modified' { 'yellow' }
        'Deleted' { 'red' }
        default { 'grey' }
    }
    $headerPadding = [Math]::Max([int][Math]::Floor(($terminalWidth - $headerText.Length) / 2), 0)
    $headerLiteral = ConvertTo-SpectreMarkupLiteral -Text $headerText

    $pageSize = if ($interactive) { [Math]::Max($terminalHeight - 6, 1) } else { $displayRows.Count }
    $startIndex = 0
    while ($true) {
        if ($interactive) {
            $script:SetupGuidancePanelVisible = $false
            [Spectre.Console.AnsiConsole]::Clear()
        }
        Write-SetupDashboard -Message $Title -IncludeTrailingSpacer
        [Spectre.Console.AnsiConsole]::MarkupLine((' ' * $headerPadding) + "[$headerColor]$headerLiteral[/]")
        $beforeHeaderPadding = ' ' * [Math]::Max($columnWidth - 6, 0)
        [Spectre.Console.AnsiConsole]::MarkupLine("[bold dodgerblue1]BEFORE[/]$beforeHeaderPadding [grey]|[/] [bold gold1]AFTER[/]")

        $endIndex = [Math]::Min($startIndex + $pageSize, $displayRows.Count)
        for ($rowIndex = $startIndex; $rowIndex -lt $endIndex; $rowIndex++) {
            $displayRow = $displayRows[$rowIndex]
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
        Show-SetupStatusBarAtBottom `
            -PromptKind 'Diff' `
            -StatusDetail "Rows $firstVisibleRow-$lastVisibleRow of $($displayRows.Count)"
        try {
            $key = Read-SetupDiffViewerKey
        }
        finally {
            Clear-SetupStatusBarAtBottom
        }
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
        All changed files, including alm-config.psd1, use the same status-labeled choices;
        Done reviewing is a separate action.
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
    $repositoryFileChanges = @($FileChanges | Sort-Object Path -CaseSensitive)
    $reviewMenuItems = [System.Collections.Generic.List[string]]::new()
    foreach ($change in $repositoryFileChanges) {
        $reviewMenuItems.Add("$($change.Status): $($change.Path)")
    }
        $reviewMenuItems.Add('Done reviewing')
        $selection = Select-FromMenu `
            -Title 'Review setup changes' `
            -Items $reviewMenuItems.ToArray() `
            -ActionItems @('Done reviewing') `
            -ActionSectionTitle '---' `
            -PromptGuidanceLines @(
                'Each file is listed with its add, modify, or delete status.',
                'Select a file to view its diff, then choose Done reviewing to return.'
            )

        if ($null -eq $selection) {
            throw 'Setup change review was cancelled.'
        }

        if ($selection -eq $repositoryFileChanges.Count) {
            return
        }
        if ($selection -lt 0 -or $selection -ge $repositoryFileChanges.Count) {
            throw "Unrecognized setup change review selection: $selection"
        }

        $selectedChange = $repositoryFileChanges[$selection]
        Show-SetupSideBySideDiff `
            -Title 'Repository file changes' `
            -FileChanges @($selectedChange) `
            -NoPaging:$PreviewOnly
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

function Set-SetupWizardContext {
    # Script-scoped navigation/help state; CurrentStepIndex is zero-based.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string[]]$StepNames,
        [Parameter(Mandatory)][int]$CurrentStepIndex,
        [Parameter()][switch]$IsNavigationMenu,
        [Parameter()][string]$HelpDocRelativePath,
        [Parameter()][string]$HelpRef
    )

    $script:SetupWizardContext = [pscustomobject]@{
        Title                 = $Title
        StepNames             = @($StepNames)
        CurrentStepIndex      = $CurrentStepIndex
        IsNavigationMenu      = [bool]$IsNavigationMenu
        HelpDocRelativePath   = $HelpDocRelativePath
        HelpRef               = $HelpRef
    }
    Clear-SetupPromptDocContext
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
        [Parameter()][string]$Ref
    )

    $script:SetupPromptDocContext = [pscustomobject]@{
        DocRelativePath = $DocRelativePath
        Ref             = $Ref
    }
}

function Clear-SetupPromptDocContext {
    [CmdletBinding()]
    param()

    Remove-Variable -Name 'SetupPromptDocContext' -Scope Script -ErrorAction SilentlyContinue
    Remove-Variable -Name 'SetupActivePromptHelpUrl' -Scope Script -ErrorAction SilentlyContinue
}

function Get-SetupPromptDocContext {
    [CmdletBinding()]
    param()

    return (Get-Variable -Name 'SetupPromptDocContext' -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
}

function Get-SetupPromptHelpContext {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][string]$DocRelativePath,
        [Parameter()][string]$Ref
    )

    $promptDocContext = Get-SetupPromptDocContext
    $wizardContext = Get-SetupWizardContext
    $effectiveDocRelativePath = $DocRelativePath
    $effectiveRef = $Ref

    if ([string]::IsNullOrWhiteSpace($effectiveDocRelativePath)) {
        if ($promptDocContext -and -not [string]::IsNullOrWhiteSpace($promptDocContext.DocRelativePath)) {
            $effectiveDocRelativePath = [string]$promptDocContext.DocRelativePath
            if ([string]::IsNullOrWhiteSpace($effectiveRef)) {
                $effectiveRef = [string]$promptDocContext.Ref
            }
        }
        elseif ($wizardContext -and -not [string]::IsNullOrWhiteSpace($wizardContext.HelpDocRelativePath)) {
            $effectiveDocRelativePath = [string]$wizardContext.HelpDocRelativePath
        }
        else {
            $defaultHelpDocRelativePath = Get-Variable -Name 'SetupDefaultHelpDocRelativePath' -Scope Script -ValueOnly -ErrorAction SilentlyContinue
            $effectiveDocRelativePath = [string]$defaultHelpDocRelativePath
        }
    }

    if ([string]::IsNullOrWhiteSpace($effectiveRef) -and $wizardContext) {
        $effectiveRef = [string]$wizardContext.HelpRef
    }
    if ([string]::IsNullOrWhiteSpace($effectiveRef) -and $promptDocContext) {
        $effectiveRef = [string]$promptDocContext.Ref
    }
    if ([string]::IsNullOrWhiteSpace($effectiveDocRelativePath)) {
        return $null
    }

    return [pscustomobject]@{
        DocRelativePath = $effectiveDocRelativePath
        Ref             = (Get-Alm4DataverseDocumentationRef -Ref $effectiveRef)
    }
}

function Get-SetupPromptHelpUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][string]$DocRelativePath,
        [Parameter()][string]$Ref
    )

    $helpContext = Get-SetupPromptHelpContext -DocRelativePath $DocRelativePath -Ref $Ref
    if (-not $helpContext) {
        return ''
    }

    return Get-Alm4DataverseDocUrl -RelativePath $helpContext.DocRelativePath -Ref $helpContext.Ref
}

function Get-SetupActivePromptHelpUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return [string](Get-Variable -Name 'SetupActivePromptHelpUrl' -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
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
        '- Press Esc to return to the setup menu; Esc on the main menu cancels setup.',
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
        [Parameter()][switch]$IncludeTrailingSpacer,
        [Parameter()][switch]$ShowProductBrand
    )

    Initialize-SpectreConsole

    if (-not (Write-SetupConsoleBar -Text (New-SetupHeroPanel -Message $Message) -ForegroundColor ([ConsoleColor]::Black) -BackgroundColor ([ConsoleColor]::Gray) -AdvanceCursor)) {
        $heroText = "[black on grey]$(ConvertTo-SpectreMarkupLiteral -Text (New-SetupHeroPanel -Message $Message))[/]"
        [Spectre.Console.AnsiConsole]::MarkupLine($heroText)
    }

    if ($ShowProductBrand) {
        $productVersion = [string](Get-Variable -Name 'ALM4DataverseVersion' -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
        if ([string]::IsNullOrWhiteSpace($productVersion)) {
            $productVersion = 'Development'
        }

        $brandIconRows = @(
            '⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀'
            '⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣠⣤⣶⣶⣶⣶⣶⣤⣄⡀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣠⣤⣶⣶⣶⣶⣦⣤⣀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀'
            '⠀⠀⠀⠀⠀⠀⠀⠀⣠⣶⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣦⣄⠀⠀⠀⠀⣠⣾⣿⣿⣿⣿⡿⢿⣿⣿⣿⣿⣿⣦⡄⠀⠀⠀⠀⠀⠀⠀⠀'
            '⠀⠀⠀⠀⠀⠀⠀⣴⡿⠟⠛⡛⠻⠿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣷⣄⢠⣾⣿⣿⣿⣿⡿⠟⠓⠀⠙⣿⣿⣿⣿⣿⣿⣦⠀⠀⠀⠀⠀⠀⠀'
            '⠀⠀⠀⠀⠀⠀⡜⡕⢌⠌⡂⡂⠅⠂⠀⠉⠻⢿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠋⣠⣶⣏⣠⣾⣿⣧⡈⢻⣿⣿⣿⣇⠀⠀⠀⠀⠀⠀'
            '⠀⠀⠀⠀⠀⠀⢕⢜⡔⡕⡕⡕⠀⠀⠀⠀⠀⠈⠻⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠇⢰⣿⣿⣿⣿⣿⣿⣿⣷⠀⢿⣿⣿⣿⠀⠀⠀⠀⠀⠀'
            '⠀⠀⠀⠀⠀⠐⣝⢮⡺⣜⢮⣂⠀⠀⠀⠀⠀⠀⠀⠈⠻⣿⣿⣿⣿⣿⣿⣿⣿⡿⢻⣿⣿⣿⣿⣿⣿⣿⣿⠿⣿⣿⣿⣿⠃⠀⠀⠀⠀⠀'
            '⠀⠀⠀⠀⠀⠀⢯⣗⣟⣮⣗⣗⡄⠀⠀⠀⠀⠀⢀⢄⠢⡊⡻⣿⣿⣿⣿⣿⣿⣧⠈⢿⣿⣿⣿⣿⣿⣿⠏⢠⣿⣿⣿⣿⠀⠀⠀⠀⠀⠀'
            '⠀⠀⠀⠀⠀⠀⠘⣷⣻⣾⢾⣳⡿⣵⢦⢤⣔⢖⡵⡱⡕⡕⡜⡜⣻⣿⣿⣿⣿⣿⣷⣄⡉⠛⠻⣿⡏⣁⣴⣿⣿⣿⣿⠃⠀⠀⠀⠀⠀⠀'
            '⠀⠀⠀⠀⠀⠀⠀⠘⢿⢿⣿⣿⣿⣟⣿⣽⣞⣯⢯⣻⢮⣫⢞⠮⠂⠈⢿⣿⣿⣿⣿⣿⣿⣿⣷⣿⣿⣿⣿⣿⣿⡿⠃⠀⠀⠀⠀⠀⠀⠀'
            '⠀⠀⠀⠀⠀⠀⠀⠀⠀⠙⠿⣿⣿⣿⣿⣿⣽⣯⣿⣽⣽⠞⠉⠀⠀⠀⠀⠈⠻⢿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠿⠋⠀⠀⠀⠀⠀⠀⠀⠀⠀'
            '⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠉⠙⠛⠛⠛⠛⠋⠉⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⠉⠛⠛⠛⠛⠛⠉⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀'
        )
        $brandNameRowIndex = 4
        $brandVersionRowIndex = 6
        $brandVersionMarkup = '[grey]' +
            (ConvertTo-SpectreMarkupLiteral -Text $productVersion) +
            '[/]'
        for ($brandRowIndex = 0; $brandRowIndex -lt $brandIconRows.Count; $brandRowIndex++) {
            $brandRowMarkup = '[bold green]' + $brandIconRows[$brandRowIndex] + '[/]'
            if ($brandRowIndex -eq $brandNameRowIndex) {
                $brandRowMarkup += '    [bold]ALM4Dataverse[/]'
            }
            elseif ($brandRowIndex -eq $brandVersionRowIndex) {
                $brandRowMarkup += "    $brandVersionMarkup"
            }
            [Spectre.Console.AnsiConsole]::MarkupLine($brandRowMarkup)
        }
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

function Get-SetupWizardStepInputSignature {
    # Only steps that opt in using an InputSignature property have a signature.
    # A scriptblock is evaluated on demand; a static value is returned as text.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][object]$Step
    )

    if (@($Step.PSObject.Properties.Name) -notcontains 'InputSignature') {
        return $null
    }

    $signature = $Step.InputSignature
    if ($signature -is [scriptblock]) {
        $signature = & $signature
    }
    if ($null -eq $signature) {
        return ''
    }

    return [string]$signature
}

function Invoke-SetupWizard {
    <#
    .SYNOPSIS
        Executes named setup steps linearly or through a guided navigation menu.
    .PARAMETER Steps
        Ordered objects with Name and Action scriptblock properties. Optional
        IsComplete and IsLocked properties represent completed prerequisite steps;
        LockAfterCompletion prevents repeating one-time setup actions. Summary may
        be a string or scriptblock; scriptblocks are evaluated each time the menu is
        rendered. SubItems may be a scriptblock returning ordered objects with Label,
        Depth, and Target properties. These rows appear indented beneath their parent,
        and selecting one passes Target as the Action's first argument. Steps may provide
        HelpDocRelativePath and HelpRef to select their own help page and documentation
        revision. InputSignature may be a scriptblock or value identifying the inputs a
        completed step depends on; when an earlier step changes, later completed steps
        with an unchanged signature remain complete. Steps without a summary show
        Complete or Not configured.
    .PARAMETER PreviewAction
        Adds an optional preview action, separate from required setup steps. It is
        available only after every setup step is complete and selecting it does not
        change setup completion.
    .PARAMETER PreviewActionName
        Label for the optional preview action.
    .PARAMETER ApplyAction
        When supplied, adds an Apply changes action in a separate menu group. It is
        ready only after all setup steps are complete. Failed applies are reported and
        return to the menu without discarding step state.
    .PARAMETER PreApplyAction
        Optional callback invoked immediately before ApplyAction, after the wizard
        context switches to the apply step. Use it to reconcile resources that setup
        must not change while the user is still reviewing the preview. A failure is
        reported like an apply failure and returns to the menu; a preview never runs it.
    .PARAMETER IsNewRepository
        Restricts new repositories to the furthest step reached, while still allowing
        users to revisit earlier steps.
    .PARAMETER RequireSequentialSteps
        Restricts navigation to the furthest step reached for workflows that must
        complete prerequisite steps in order. Later steps are dimmed; selecting one
        keeps the menu open and displays a reminder to complete earlier steps.
    .PARAMETER ReturnToCaller
        Requires ApplyAction, hides the whole-setup exit action, and returns null when
        the navigation menu is cancelled. Use this for nested editors.
    .PARAMETER HelpDocRelativePath
        Default help page for the wizard and steps without a step-specific page.
    .PARAMETER HelpRef
        Documentation revision used for wizard help links unless a prompt supplies
        another ref. F1 opens the current help page and resumes the prompt.
    .DESCRIPTION
        Without ApplyAction, a back marker repeats the preceding step; if the first
        step has no predecessor, setup is cancelled. With ApplyAction, step selection
        is menu-driven and all setup steps must complete before previewing or applying.
        PreviewAction is optional and does not change setup completion. Setup and action
        choices are grouped separately in the menu. Exit without applying changes is
        always available with ApplyAction and asks for confirmation before leaving.
        PreApplyAction runs only after the user chooses Apply, so reconciliation that
        depends on the final selection is deferred until then. Escape in a step returns
        to the navigation menu; Escape on that menu cancels
        setup. F1 opens the active help page without leaving the prompt. Re-running a
        step invalidates completion of later steps; locked prerequisite steps remain
        complete. Selecting an unavailable step or not-ready action keeps the menu open
        and displays guidance about its prerequisite or lock. No action side effects are
        rolled back.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][array]$Steps,
        [Parameter()][scriptblock]$PreviewAction,
        [Parameter()][string]$PreviewActionName = 'Preview changes',
        [Parameter()][scriptblock]$ApplyAction,
        [Parameter()][string]$ApplyActionName = 'Apply changes',
        [Parameter()][scriptblock]$PreApplyAction,
        [Parameter()][switch]$IsNewRepository,
        [Parameter()][switch]$RequireSequentialSteps,
        [Parameter()][switch]$ReturnToCaller,
        [Parameter()][string]$HelpDocRelativePath,
        [Parameter()][string]$HelpRef
    )

    if ($PreviewAction -and -not $ApplyAction) {
        throw 'PreviewAction requires ApplyAction.'
    }
    if ($ReturnToCaller -and -not $ApplyAction) {
        throw 'ReturnToCaller requires ApplyAction.'
    }

    if ($Steps.Count -eq 0 -and -not $ApplyAction) {
        return
    }

    $stepNames = @($Steps | ForEach-Object { [string]$_.Name })

    if ($ApplyAction) {
        $previewActionIndex = -1
        $applyActionIndex = $Steps.Count
        $exitActionName = 'Exit without applying changes'
        $menuStepNames = @($stepNames)
        if ($PreviewAction) {
            $previewActionIndex = $Steps.Count
            $applyActionIndex++
            $menuStepNames += $PreviewActionName
        }
        $menuStepNames += $ApplyActionName
        $exitActionIndex = -1
        if (-not $ReturnToCaller) {
            $exitActionIndex = $applyActionIndex + 1
            $menuStepNames += $exitActionName
        }
        $completedSteps = [bool[]]::new($Steps.Count)
        $lockedSteps = [bool[]]::new($Steps.Count)
        $completedStepSignatures = [object[]]::new($Steps.Count)
        for ($stepIndex = 0; $stepIndex -lt $Steps.Count; $stepIndex++) {
            $stepProperties = @($Steps[$stepIndex].PSObject.Properties.Name)
            $lockedSteps[$stepIndex] = $stepProperties -contains 'IsLocked' -and [bool]$Steps[$stepIndex].IsLocked
            $completedSteps[$stepIndex] = (
                $lockedSteps[$stepIndex] -or
                ($stepProperties -contains 'IsComplete' -and [bool]$Steps[$stepIndex].IsComplete)
            )
            if ($completedSteps[$stepIndex]) {
                $completedStepSignatures[$stepIndex] = Get-SetupWizardStepInputSignature -Step $Steps[$stepIndex]
            }
        }
        $furthestStepIndex = -1
        while (($furthestStepIndex + 1) -lt $Steps.Count -and $completedSteps[$furthestStepIndex + 1]) {
            $furthestStepIndex++
        }
        $requireSequentialSteps = $IsNewRepository -or $RequireSequentialSteps
        $currentStepIndex = 0
        $promptNotice = $null

        try {
            while ($true) {
                $stepMenuItems = @()
                $stepMenuIndexes = @()
                $stepMenuTargets = @()
                $dimMenuItems = @()
                $hasSubItems = $false
                for ($stepIndex = 0; $stepIndex -lt $Steps.Count; $stepIndex++) {
                    $completionLabel = if ($completedSteps[$stepIndex]) { '[✓]' } else { '[ ]' }
                    $stepProperties = @($Steps[$stepIndex].PSObject.Properties.Name)
                    $subItems = @()
                    if ($stepProperties -contains 'SubItems') {
                        $subItemsValue = $Steps[$stepIndex].SubItems
                        if ($subItemsValue -is [scriptblock]) {
                            $subItems = @(& $subItemsValue)
                        }
                        elseif ($null -ne $subItemsValue) {
                            $subItems = @($subItemsValue)
                        }
                    }

                    $summaryText = 'Not configured'
                    if ($stepProperties -contains 'Summary' -and $subItems.Count -eq 0) {
                        $summaryValue = $Steps[$stepIndex].Summary
                        if ($summaryValue -is [scriptblock]) {
                            $summaryValue = @(& $summaryValue) -join ', '
                        }
                        elseif ($summaryValue -is [array]) {
                            $summaryValue = $summaryValue -join ', '
                        }

                        if (-not [string]::IsNullOrWhiteSpace([string]$summaryValue)) {
                            $summaryText = [string]$summaryValue
                        }
                    }
                    elseif ($completedSteps[$stepIndex] -and $subItems.Count -eq 0) {
                        $summaryText = 'Complete'
                    }
                    $summaryText = ($summaryText -replace '\s+', ' ').Trim()
                    if ([string]::IsNullOrWhiteSpace($summaryText)) {
                        $summaryText = if ($completedSteps[$stepIndex]) { 'Complete' } else { 'Not configured' }
                    }

                    $lockedAfterCompletion = (
                        $stepProperties -contains 'LockAfterCompletion' -and
                        [bool]$Steps[$stepIndex].LockAfterCompletion -and
                        $completedSteps[$stepIndex]
                    )
                    $isStepUnavailable = (
                        $lockedSteps[$stepIndex] -or
                        $lockedAfterCompletion -or
                        ($requireSequentialSteps -and $stepIndex -gt ($furthestStepIndex + 1))
                    )
                    $stepMenuItem = if ($subItems.Count -gt 0) {
                        "$completionLabel $($stepNames[$stepIndex])"
                    }
                    else {
                        "$completionLabel $($stepNames[$stepIndex]) - $summaryText"
                    }
                    $stepMenuItems += $stepMenuItem
                    if ($isStepUnavailable) {
                        $dimMenuItems += $stepMenuItem
                    }
                    $stepMenuIndexes += $stepIndex
                    $stepMenuTargets += [pscustomobject]@{
                        HasTarget = $false
                        Target    = $null
                    }

                    foreach ($subItem in $subItems) {
                        if ($null -eq $subItem) {
                            throw "Setup step '$($stepNames[$stepIndex])' returned a null SubItems entry."
                        }

                        $subItemProperties = @($subItem.PSObject.Properties.Name)
                        if (
                            $subItemProperties -notcontains 'Label' -or
                            $subItemProperties -notcontains 'Depth' -or
                            $subItemProperties -notcontains 'Target'
                        ) {
                            throw "Setup step '$($stepNames[$stepIndex])' SubItems must have Label, Depth, and Target properties."
                        }

                        $subItemLabel = [string]$subItem.Label
                        $subItemDepth = [int]$subItem.Depth
                        if ([string]::IsNullOrWhiteSpace($subItemLabel) -or $subItemDepth -lt 1 -or $null -eq $subItem.Target) {
                            throw "Setup step '$($stepNames[$stepIndex])' returned an invalid SubItems entry."
                        }

                        $stepMenuItems += ('  ' * $subItemDepth) + $subItemLabel
                        if ($isStepUnavailable) {
                            $dimMenuItems += ('  ' * $subItemDepth) + $subItemLabel
                        }
                        $stepMenuIndexes += $stepIndex
                        $stepMenuTargets += [pscustomobject]@{
                            HasTarget = $true
                            Target    = $subItem.Target
                        }
                        $hasSubItems = $true
                    }
                }

                $allStepsCompleted = -not ($completedSteps -contains $false)
                $applyMenuLabel = if ($allStepsCompleted) {
                    "$ApplyActionName - Ready"
                }
                else {
                    "$ApplyActionName (finish all setup steps first) - Not ready"
                }
                $previewMenuLabel = if ($allStepsCompleted) {
                    $PreviewActionName
                }
                else {
                    "$PreviewActionName (finish all setup steps first) - Not ready"
                }
                $actionMenuItems = @()
                if ($PreviewAction) {
                    $actionMenuItems += $previewMenuLabel
                }
                $actionMenuItems += $applyMenuLabel
                if (-not $ReturnToCaller) {
                    $actionMenuItems += $exitActionName
                }
                $nextStepIndex = [Array]::IndexOf($completedSteps, $false)
                if ($allStepsCompleted) {
                    $menuItems = @($applyMenuLabel)
                    $menuStepIndexes = @($applyActionIndex)
                    $menuActionTargets = @([pscustomobject]@{ HasTarget = $false; Target = $null })
                    if ($PreviewAction) {
                        $menuItems += $previewMenuLabel
                        $menuStepIndexes += $previewActionIndex
                        $menuActionTargets += [pscustomobject]@{ HasTarget = $false; Target = $null }
                    }
                    if (-not $ReturnToCaller) {
                        $menuItems += $exitActionName
                        $menuStepIndexes += $exitActionIndex
                        $menuActionTargets += [pscustomobject]@{ HasTarget = $false; Target = $null }
                    }
                    $menuItems += $stepMenuItems
                    $menuStepIndexes += $stepMenuIndexes
                    $menuActionTargets += $stepMenuTargets
                    $currentStepIndex = $applyActionIndex
                }
                else {
                    $menuItems = @($stepMenuItems)
                    $menuStepIndexes = @($stepMenuIndexes)
                    $menuActionTargets = @($stepMenuTargets)
                    if ($PreviewAction) {
                        $menuItems += $previewMenuLabel
                        $menuStepIndexes += $previewActionIndex
                        $menuActionTargets += [pscustomobject]@{ HasTarget = $false; Target = $null }
                    }
                    $menuItems += $applyMenuLabel
                    $menuStepIndexes += $applyActionIndex
                    $menuActionTargets += [pscustomobject]@{ HasTarget = $false; Target = $null }
                    if (-not $ReturnToCaller) {
                        $menuItems += $exitActionName
                        $menuStepIndexes += $exitActionIndex
                        $menuActionTargets += [pscustomobject]@{ HasTarget = $false; Target = $null }
                    }
                    $currentStepIndex = $nextStepIndex
                }

                Set-SetupWizardContext `
                    -Title $Title `
                    -StepNames $menuStepNames `
                    -CurrentStepIndex $currentStepIndex `
                    -IsNavigationMenu `
                    -HelpDocRelativePath $HelpDocRelativePath `
                    -HelpRef $HelpRef

                $promptGuidanceLines = @(
                    'Work through each setup step, or select any available step to revisit it.'
                )
                if ($hasSubItems) {
                    $promptGuidanceLines += 'Select an indented branch or environment to jump to its configuration.'
                }
                if ($PreviewAction) {
                    $promptGuidanceLines += "$PreviewActionName is optional, is available after every setup step is complete, and does not complete a setup step."
                }
                $promptGuidanceLines += "$ApplyActionName is available after every setup step has been completed."
                if (-not $ReturnToCaller) {
                    $promptGuidanceLines += "$exitActionName asks for confirmation before ending setup without applying the pending changes."
                }
                if (-not [string]::IsNullOrWhiteSpace($promptNotice)) {
                    $promptGuidanceLines = @($promptNotice) + $promptGuidanceLines
                }

                $selection = Select-FromMenu `
                    -Title "$Title menu" `
                    -Items $menuItems `
                    -DimItems $dimMenuItems `
                    -ActionItems $actionMenuItems `
                    -ActionSectionTitle '---' `
                    -ActionSectionFirst:$allStepsCompleted `
                    -PromptGuidanceLines $promptGuidanceLines
                $promptNotice = $null

                if ($null -eq $selection) {
                    if ($ReturnToCaller) {
                        return $null
                    }
                    throw 'Setup cancelled before changes were applied.'
                }

                $selectedStepIndex = $menuStepIndexes[$selection]
                $selectedMenuTarget = $menuActionTargets[$selection]
                if ($selectedStepIndex -eq $exitActionIndex) {
                    $currentStepIndex = $exitActionIndex
                    Set-SetupWizardContext `
                        -Title $Title `
                        -StepNames $menuStepNames `
                        -CurrentStepIndex $currentStepIndex `
                        -HelpDocRelativePath $HelpDocRelativePath `
                        -HelpRef $HelpRef
                    try {
                        $exitWithoutApplying = Read-YesNo `
                            -Prompt 'Exit setup without applying changes?' `
                            -PromptGuidanceLines @(
                                'Your current setup selections will not be applied.',
                                'Resources created during earlier setup prerequisites are not rolled back.'
                            ) `
                            -DefaultNo
                    }
                    catch {
                        if (Test-IsSetupWizardBackException -Exception $_.Exception) {
                            continue
                        }
                        throw
                    }

                    if ($exitWithoutApplying) {
                        Write-Host 'Exiting setup without applying changes.' -ForegroundColor Yellow
                        throw 'Setup exited without applying changes.'
                    }

                    continue
                }

                if ($selectedStepIndex -eq $applyActionIndex) {
                    if (-not $allStepsCompleted) {
                        $promptNotice = 'Complete every setup step before applying changes.'
                        continue
                    }

                    try {
                        $currentStepIndex = $applyActionIndex
                        Set-SetupWizardContext `
                            -Title $Title `
                            -StepNames $menuStepNames `
                            -CurrentStepIndex $applyActionIndex `
                            -HelpDocRelativePath $HelpDocRelativePath `
                            -HelpRef $HelpRef
                        if ($PreApplyAction) {
                            & $PreApplyAction
                        }
                        return (& $ApplyAction)
                    }
                    catch {
                        if (Test-IsSetupWizardBackException -Exception $_.Exception) {
                            continue
                        }
                        if (Test-IsUserInterruptException -Exception $_.Exception) {
                            throw
                        }

                        Write-SetupWizardApplyFailure -OperationName $ApplyActionName -ErrorRecord $_
                        continue
                    }
                }

                if ($selectedStepIndex -eq $previewActionIndex) {
                    if (-not $allStepsCompleted) {
                        $promptNotice = 'Complete every setup step before previewing changes.'
                        continue
                    }

                    $currentStepIndex = $previewActionIndex
                    Set-SetupWizardContext `
                        -Title $Title `
                        -StepNames $menuStepNames `
                        -CurrentStepIndex $currentStepIndex `
                        -HelpDocRelativePath $HelpDocRelativePath `
                        -HelpRef $HelpRef
                    try {
                        & $PreviewAction | Out-Null
                    }
                    catch {
                        if (Test-IsSetupWizardBackException -Exception $_.Exception) {
                            continue
                        }
                        throw
                    }
                    continue
                }

                $selectedStepProperties = @($Steps[$selectedStepIndex].PSObject.Properties.Name)
                $lockedAfterCompletion = (
                    $selectedStepProperties -contains 'LockAfterCompletion' -and
                    [bool]$Steps[$selectedStepIndex].LockAfterCompletion -and
                    $completedSteps[$selectedStepIndex]
                )
                if ($lockedSteps[$selectedStepIndex] -or $lockedAfterCompletion) {
                    $promptNotice = 'This setup step is locked because it has already been completed.'
                    continue
                }

                if ($requireSequentialSteps -and $selectedStepIndex -gt ($furthestStepIndex + 1)) {
                    $promptNotice = 'Complete the earlier setup steps before moving forward.'
                    continue
                }

                $currentStepIndex = $selectedStepIndex
                $stepHelpDocRelativePath = $HelpDocRelativePath
                $stepHelpRef = $HelpRef
                if (
                    $selectedStepProperties -contains 'HelpDocRelativePath' -and
                    -not [string]::IsNullOrWhiteSpace([string]$Steps[$selectedStepIndex].HelpDocRelativePath)
                ) {
                    $stepHelpDocRelativePath = [string]$Steps[$selectedStepIndex].HelpDocRelativePath
                }
                if (
                    $selectedStepProperties -contains 'HelpRef' -and
                    -not [string]::IsNullOrWhiteSpace([string]$Steps[$selectedStepIndex].HelpRef)
                ) {
                    $stepHelpRef = [string]$Steps[$selectedStepIndex].HelpRef
                }
                Set-SetupWizardContext `
                    -Title $Title `
                    -StepNames $menuStepNames `
                    -CurrentStepIndex $currentStepIndex `
                    -HelpDocRelativePath $stepHelpDocRelativePath `
                    -HelpRef $stepHelpRef
                try {
                    if ($selectedMenuTarget.HasTarget) {
                        & $Steps[$selectedStepIndex].Action $selectedMenuTarget.Target | Out-Null
                    }
                    else {
                        & $Steps[$selectedStepIndex].Action | Out-Null
                    }
                }
                catch {
                    if (Test-IsSetupWizardBackException -Exception $_.Exception) {
                        continue
                    }
                    throw
                }

                $completedSteps[$selectedStepIndex] = $true
                $completedStepSignatures[$selectedStepIndex] = Get-SetupWizardStepInputSignature -Step $Steps[$selectedStepIndex]
                if ($selectedStepIndex -gt $furthestStepIndex) {
                    $furthestStepIndex = $selectedStepIndex
                }
                for ($laterStepIndex = $selectedStepIndex + 1; $laterStepIndex -lt $Steps.Count; $laterStepIndex++) {
                    if ($lockedSteps[$laterStepIndex]) {
                        continue
                    }

                    # A completed step with an unchanged input signature is independent
                    # of the edited step, so retain it. Steps without a signature keep the
                    # conservative invalidate-everything-after behavior.
                    $laterStepProperties = @($Steps[$laterStepIndex].PSObject.Properties.Name)
                    if ($laterStepProperties -contains 'InputSignature' -and $completedSteps[$laterStepIndex]) {
                        $currentSignature = Get-SetupWizardStepInputSignature -Step $Steps[$laterStepIndex]
                        if ($currentSignature -ceq [string]$completedStepSignatures[$laterStepIndex]) {
                            continue
                        }
                    }

                    $completedSteps[$laterStepIndex] = $false
                    $completedStepSignatures[$laterStepIndex] = $null
                }
            }
        }
        finally {
            Clear-SetupWizardContext
        }
    }

    $currentStepIndex = 0
    try {
        while ($currentStepIndex -lt $Steps.Count) {
            try {
                $stepProperties = @($Steps[$currentStepIndex].PSObject.Properties.Name)
                $stepHelpDocRelativePath = $HelpDocRelativePath
                $stepHelpRef = $HelpRef
                if (
                    $stepProperties -contains 'HelpDocRelativePath' -and
                    -not [string]::IsNullOrWhiteSpace([string]$Steps[$currentStepIndex].HelpDocRelativePath)
                ) {
                    $stepHelpDocRelativePath = [string]$Steps[$currentStepIndex].HelpDocRelativePath
                }
                if (
                    $stepProperties -contains 'HelpRef' -and
                    -not [string]::IsNullOrWhiteSpace([string]$Steps[$currentStepIndex].HelpRef)
                ) {
                    $stepHelpRef = [string]$Steps[$currentStepIndex].HelpRef
                }
                Set-SetupWizardContext `
                    -Title $Title `
                    -StepNames $stepNames `
                    -CurrentStepIndex $currentStepIndex `
                    -HelpDocRelativePath $stepHelpDocRelativePath `
                    -HelpRef $stepHelpRef
                & $Steps[$currentStepIndex].Action
                $currentStepIndex++
            }
            catch {
                if (Test-IsSetupWizardBackException -Exception $_.Exception) {
                    if ($currentStepIndex -gt 0) {
                        $currentStepIndex--
                        continue
                    }

                    throw ([System.OperationCanceledException]::new('Setup cancelled by user.'))
                }

                throw
            }
        }
    }
    finally {
        Clear-SetupWizardContext
    }
}

function Write-SetupWizardApplyFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OperationName,
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    Initialize-SpectreConsole
    $errorMessage = [string]$ErrorRecord.Exception.Message
    $errorType = [string]$ErrorRecord.Exception.GetType().Name
    [Spectre.Console.AnsiConsole]::MarkupLine("[bold red]$([string](ConvertTo-SpectreMarkupLiteral -Text "Apply failed: $OperationName"))[/]")
    [Spectre.Console.AnsiConsole]::MarkupLine("[yellow]$([string](ConvertTo-SpectreMarkupLiteral -Text $errorType)): $([string](ConvertTo-SpectreMarkupLiteral -Text $errorMessage))[/]")
    [Spectre.Console.AnsiConsole]::MarkupLine('[grey]Your setup selections are still available. Edit a step or select Apply changes to retry.[/]')

    if ($ErrorRecord.InvocationInfo.PositionMessage) {
        [Spectre.Console.AnsiConsole]::MarkupLine("[grey]$([string](ConvertTo-SpectreMarkupLiteral -Text $ErrorRecord.InvocationInfo.PositionMessage.Trim()))[/]")
    }
}

function Confirm-SetupReviewAction {
    # Returns no value on approval; declining the confirmation throws.
    [CmdletBinding()]
    param(
        [Parameter()][string]$ApplyLabel = 'Apply changes',
        [Parameter()][string]$Title = 'Review complete. Apply the configuration?'
    )

    $selection = Select-FromMenu `
        -Title $Title `
        -Items @($ApplyLabel) `
        -ActionItems @($ApplyLabel) `
        -ActionSectionTitle '---' `
        -PromptGuidanceLines @('Are you ready to apply the changes?') `
        -PromptGuidanceDocRelativePath 'docs/config/alm-config.md'

    if ($null -eq $selection) {
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
    # Menu hints describe filtering only when enabled. Diff controls and optional
    # row-range details share the same bottom bar as other prompt hints.
    [CmdletBinding()]
    param(
        [Parameter()][ValidateSet('Menu', 'Text', 'YesNo', 'Secret', 'Diff')][string]$PromptKind = 'Text',
        [Parameter()][switch]$SearchEnabled,
        [Parameter()][string]$StatusDetail
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
        'Diff' {
            @(
                'Up/Down=scroll',
                'PgUp/PgDn=page',
                'Home/End=jump',
                'Enter/Q/Esc=close',
                'Ctrl+C=exit'
            )
        }
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
    if (-not [string]::IsNullOrWhiteSpace($StatusDetail)) {
        $segments = @($StatusDetail) + $segments
    }
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

function Show-SetupPromptWithInterruptHandling {
    <#
    .SYNOPSIS
        Runs an async Spectre prompt synchronously with Escape and Ctrl+C handling.
    .DESCRIPTION
        Returns the prompt's result. Uses the compiled console-event bridge when
        supported, otherwise a local token source. Cancellation is normalized to
        OperationCanceledException; other failures propagate. The source and any
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
        if (-not $ShowProductBrand) {
            [Spectre.Console.AnsiConsole]::MarkupLine('')
        }
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
                    @('Choose Yes or No. Press Enter to accept the displayed default.')
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
    # A default-yes confirmation keeps the acknowledgement dismissible without a cancel menu item.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [Parameter()][string]$ContinueLabel = 'Continue'
    )

    $choice = Select-FromMenu -Title $Message -Items @($ContinueLabel)
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
        Returns a zero-based index into Items, or null for no items, a declined
        single-item confirmation, or an unrecognized prompt result. Explicit Back
        choices throw the wizard navigation marker rather than returning an index.
        Escape returns to the previous setup menu or step, or cancels when there is no
        parent. Literal labels are escaped for display; duplicate labels resolve to
        their first match. A single guidance panel is always visible; nested menus
        preserve an existing panel. Console input mode restoration is attempted after
        selection, including prompt failure.
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
        Places matching choices in a separate, bold cyan action group after a grey
        separator. The choices remain selectable and results still map to their
        original Items indexes.
    .PARAMETER DimItems
        Displays matching choices in grey. Callers remain responsible for preventing
        unavailable choices from running.
    .PARAMETER ActionSectionTitle
        Separator text preceding the optional action group.
    .PARAMETER ActionSectionFirst
        Renders the action group before the normal choices.
    #>

    [CmdletBinding()]
    [OutputType([int])]
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
        [Parameter()][string]$ActionSectionTitle = '---',
        [Parameter()][switch]$ActionSectionFirst,
        [Parameter()][string[]]$DimItems = @()
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

    $isSingleChoiceConfirmation = $Items.Count -eq 1
    $promptKind = if ($isSingleChoiceConfirmation) { 'YesNo' } else { 'Menu' }
    Write-SetupPromptFrame `
        -PromptText $Title `
        -PromptKind $promptKind `
        -PromptGuidanceLines $PromptGuidanceLines `
        -PromptGuidanceDocRelativePath $PromptGuidanceDocRelativePath `
        -PromptGuidanceRef $PromptGuidanceRef `
        -ShowProductBrand:$ShowProductBrand `
        -PreserveExistingContent:$PreserveExistingContent `
        -SkipPromptGuidance:$SkipPromptGuidance

    $effectiveItems = @($Items)
    Write-SetupDebug -Message "Select-FromMenu title='$Title' items=$($Items.Count) singleChoiceConfirmation=$isSingleChoiceConfirmation"
    if (Test-SetupDebugEnabled) {
        for ($debugIndex = 0; $debugIndex -lt $effectiveItems.Count; $debugIndex++) {
            Write-SetupDebug -Message "  [$debugIndex] $($effectiveItems[$debugIndex])"
        }
    }

    if ($isSingleChoiceConfirmation) {
        $confirmationLabel = [string](ConvertTo-SpectreMarkupLiteral -Text $effectiveItems[0])
        if ($DimItems -contains $effectiveItems[0]) {
            $confirmationLabel = "[grey]$confirmationLabel[/]"
        }
        elseif ($ActionItems -contains $effectiveItems[0]) {
            [Spectre.Console.AnsiConsole]::MarkupLine('[grey]---[/]')
            $confirmationLabel = "[bold deepskyblue1]$confirmationLabel[/]"
        }

        $prompt = [Spectre.Console.ConfirmationPrompt]::new($confirmationLabel)
        $prompt.DefaultValue = $true
    }
    else {
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
            if ($DimItems -contains $item) {
                $displayItem = "[grey]$displayItem[/]"
            }
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
            $actionGroupTitle = "[grey]$(ConvertTo-SpectreMarkupLiteral -Text $ActionSectionTitle)[/]"
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
    }

    if ($isSingleChoiceConfirmation) {
        Show-SetupStatusBarAtBottom -PromptKind 'YesNo'
    }
    else {
        Show-SetupStatusBarAtBottom -PromptKind 'Menu' -SearchEnabled:$prompt.SearchEnabled
    }

    try {
        $selectedDisplayValue = Show-SetupPromptWithInterruptHandling `
            -Prompt $prompt `
            -ReturnNullAtNavigationMenuOnEscape
        Write-SetupDebug -Message "Interactive setup prompt returned: '$selectedDisplayValue'"

        if ($isSingleChoiceConfirmation) {
            if ($selectedDisplayValue) {
                return 0
            }
            return $null
        }

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

        $isBackSelection = ($selectedValue -eq 'Back' -or $selectedValue -like '< Back*')
        if ($isBackSelection) {
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
    [OutputType([string])]
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

    $menuItems = @(
        "Commit directly to '$BaseBranch'",
        'Commit directly to another branch',
        "Push a branch and open a pull request into '$BaseBranch'"
    )

    $selection = Select-FromMenu `
        -Title "How should the $ProviderName repository changes be published?" `
        -Items $menuItems `
        -PromptGuidanceLines @($defaultGuidance + @($GuidanceLines) + @(
                "Choose whether to apply $ProviderName repository changes directly or through a pull request.",
                'Use direct commit for immediate activation, or branch + PR when review/approval is required.'
            )) `
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
        is the direct target or the entered PR source. When ExistingPlan supplies a
        current mode, that choice is listed first and marked current while its branch
        and title values seed the editable defaults. Cancellation throws; this helper
        prompts only and does not contact the provider or validate branches.
    .PARAMETER ExistingPlan
        A previously selected publication plan, or null when no choice has been made.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProviderName,
        [Parameter(Mandatory)][string]$RepositoryName,
        [Parameter(Mandatory)][string]$TargetBranch,
        [Parameter(Mandatory)][string]$DefaultCommitMessage,
        [Parameter(Mandatory)][string]$DefaultPullRequestTitle,
        [Parameter()][string]$DefaultPullRequestDescription,
        [Parameter()][AllowNull()][object]$ExistingPlan,
        [Parameter()][string[]]$GuidanceLines,
        [Parameter()][string]$DocRelativePath,
        [Parameter()][string]$Ref
    )

    $defaultGuidance = @(
        "Choose how setup should publish branch-specific updates for '$TargetBranch' in '$RepositoryName'.",
        "Direct commit updates '$TargetBranch' immediately and is best when instant activation is intended.",
        "Branch + pull request adds review/check gates and is best when '$TargetBranch' must be controlled before changes land."
    )

    $existingMode = [string](Get-OptionalObjectPropertyValue -InputObject $ExistingPlan -PropertyName 'Mode')
    $existingBranchName = [string](Get-OptionalObjectPropertyValue -InputObject $ExistingPlan -PropertyName 'BranchName')
    $existingCommitMessage = [string](Get-OptionalObjectPropertyValue -InputObject $ExistingPlan -PropertyName 'CommitMessage')
    $existingPullRequestTitle = [string](Get-OptionalObjectPropertyValue -InputObject $ExistingPlan -PropertyName 'PullRequestTitle')
    $existingPullRequestDescription = [string](Get-OptionalObjectPropertyValue -InputObject $ExistingPlan -PropertyName 'PullRequestDescription')

    $effectiveCommitMessage = if ([string]::IsNullOrWhiteSpace($existingCommitMessage)) { $DefaultCommitMessage } else { $existingCommitMessage }
    $directLabel = "Commit directly to '$TargetBranch'"
    $pullRequestLabel = "Push a branch and open a pull request into '$TargetBranch'"

    # SelectionPrompt has no default-index API, so the current mode is placed first
    # and labeled instead. Steps without an existing plan keep the original order.
    $modeOptions = if ($existingMode -eq 'PullRequest') {
        @(
            [pscustomobject]@{ Mode = 'PullRequest'; Label = "$pullRequestLabel (current)" }
            [pscustomobject]@{ Mode = 'Direct'; Label = $directLabel }
        )
    }
    else {
        @(
            [pscustomobject]@{ Mode = 'Direct'; Label = $(if ($existingMode -eq 'Direct') { "$directLabel (current)" } else { $directLabel }) }
            [pscustomobject]@{ Mode = 'PullRequest'; Label = $pullRequestLabel }
        )
    }

    $selection = Select-FromMenu `
        -Title "How should the $ProviderName changes for branch '$TargetBranch' be published?" `
        -Items @($modeOptions.Label) `
        -PromptGuidanceLines @($defaultGuidance + @($GuidanceLines) + @(
                "Choose whether branch '$TargetBranch' updates should be applied directly or via a pull request.",
                'Use direct commit for immediate branch updates, or branch + PR when checks and review gates are needed.'
            )) `
        -PromptGuidanceDocRelativePath $DocRelativePath `
        -PromptGuidanceRef $Ref
    if ($null -eq $selection) {
        throw "No repository publish option selected for branch '$TargetBranch'."
    }

    $selectedMode = $modeOptions[$selection].Mode
    if ($selectedMode -eq 'Direct') {
        return [pscustomobject]@{
            Mode                   = 'Direct'
            BranchName             = $TargetBranch
            TargetBranch           = $TargetBranch
            CommitMessage          = $effectiveCommitMessage
            PullRequestTitle       = $null
            PullRequestDescription = $null
        }
    }

    $defaultBranchName = if ($existingMode -eq 'PullRequest' -and -not [string]::IsNullOrWhiteSpace($existingBranchName)) {
        $existingBranchName
    }
    else {
        Get-DefaultSetupBranchName -BaseBranch $TargetBranch -Context $RepositoryName
    }
    $defaultPullRequestTitle = if ($existingMode -eq 'PullRequest' -and -not [string]::IsNullOrWhiteSpace($existingPullRequestTitle)) {
        $existingPullRequestTitle
    }
    else {
        $DefaultPullRequestTitle
    }
    $defaultPullRequestDescription = if ($existingMode -eq 'PullRequest' -and -not [string]::IsNullOrWhiteSpace($existingPullRequestDescription)) {
        $existingPullRequestDescription
    }
    else {
        $DefaultPullRequestDescription
    }

    $sourceBranch = Read-TextWithDefault -Prompt 'Branch to push for the pull request' -DefaultValue $defaultBranchName
    $prTitle = Read-TextWithDefault -Prompt 'Pull request title' -DefaultValue $defaultPullRequestTitle

    return [pscustomobject]@{
        Mode                   = 'PullRequest'
        BranchName             = $sourceBranch
        TargetBranch           = $TargetBranch
        CommitMessage          = $effectiveCommitMessage
        PullRequestTitle       = $prTitle
        PullRequestDescription = $defaultPullRequestDescription
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

function Get-SetupSingleBranchPublishPlan {
    <#
    .SYNOPSIS
        Collects one publication plan: a target branch plus direct-commit or PR mode.
    .DESCRIPTION
        Setup publishes the generated files for every configured branch in a single
        change on the selected target branch. The default branch is offered first;
        branch choice and mode each prompt once, so guided setup no longer plans a
        separate publication per branch. ExistingPlan seeds the mode choice and
        editable defaults. Cancellation throws; this helper prompts only.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProviderName,
        [Parameter(Mandatory)][string]$RepositoryName,
        [Parameter(Mandatory)][string]$DefaultBranch,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$BranchStates,
        [Parameter(Mandatory)][string]$DefaultCommitMessage,
        [Parameter(Mandatory)][string]$DefaultPullRequestDescription,
        [Parameter()][AllowNull()][object]$ExistingPlan,
        [Parameter()][string]$DocRelativePath,
        [Parameter()][string]$Ref
    )

    $configuredBranchNames = @($BranchStates | ForEach-Object { [string]$_.BranchName })
    if (@($configuredBranchNames).Count -eq 0) {
        throw 'No configured branches are available to publish.'
    }

    $orderedBranchNames = @([string]$DefaultBranch) + @($configuredBranchNames | Where-Object { $_ -ine $DefaultBranch })
    $branchMenuItems = @($orderedBranchNames | ForEach-Object {
        if ($_ -ieq $DefaultBranch) { "Commit to '$_' (default branch)" } else { "Commit to '$_'" }
    })
    $branchSelection = Select-FromMenu `
        -Title "Which branch should receive the $ProviderName changes?" `
        -Items $branchMenuItems `
        -PromptGuidanceLines @(
            'Generated caller files for every configured branch are committed to the selected branch in a single change.',
            'Use a pull request when the selected branch is protected or review is required.'
        ) `
        -PromptGuidanceDocRelativePath $DocRelativePath `
        -PromptGuidanceRef $Ref
    if ($null -eq $branchSelection) {
        throw 'No publication branch selected.'
    }

    $targetBranch = [string]$orderedBranchNames[$branchSelection]
    return Get-BranchTargetedRepoChangePublishPlan `
        -ProviderName $ProviderName `
        -RepositoryName $RepositoryName `
        -TargetBranch $targetBranch `
        -DefaultCommitMessage $DefaultCommitMessage `
        -DefaultPullRequestTitle $DefaultCommitMessage `
        -DefaultPullRequestDescription $DefaultPullRequestDescription `
        -ExistingPlan $ExistingPlan `
        -GuidanceLines @(
            "The generated files for every configured branch are published to '$targetBranch' in a single change.",
            'Direct commit updates the target branch immediately; the pull-request path adds review before the change lands.'
        ) `
        -DocRelativePath $DocRelativePath `
        -Ref $Ref
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

        $selection = Select-FromMenu `
            -Title 'Manage solutions' `
            -Items $menuItems `
            -ActionItems @('Done') `
            -ActionSectionTitle '---' `
            -PreserveExistingContent `
            -SkipPromptGuidance

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
        Sets solutionCheck.enabled to the requested flag.
    .DESCRIPTION
        Updates only the enabled key of an existing solutionCheck hashtable, so checker
        subsettings such as geo, failThreshold and ruleSet are retained. The enabled key
        is inserted when absent. solutionCheck is written as a whole block only when it
        is missing or not a hashtable. Other root settings are preserved by AST offsets.
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

    $lineEnding = if ($configContent -match "`r`n") { "`r`n" } else { "`n" }

    $solutionCheckHashtable = $null
    if ($solutionCheckEntry) {
        $solutionCheckHashtable = $solutionCheckEntry.Item2.Find({
            param($node)
            $node -is [System.Management.Automation.Language.HashtableAst]
        }, $false)
    }

    if ($solutionCheckEntry -and -not $solutionCheckHashtable) {
        $valueExtent = $solutionCheckEntry.Item2.Extent
        $updatedContent = $configContent.Substring(0, $valueExtent.StartOffset) + $solutionCheckBlock + $configContent.Substring($valueExtent.EndOffset)
    }
    elseif ($solutionCheckHashtable) {
        $enabledEntry = $solutionCheckHashtable.KeyValuePairs | Where-Object {
            $keyText = $_.Item1.Extent.Text.Trim()
            $keyText -in @('enabled', "'enabled'", '"enabled"')
        } | Select-Object -First 1

        if ($enabledEntry) {
            $valueExtent = $enabledEntry.Item2.Extent
            $updatedContent = $configContent.Substring(0, $valueExtent.StartOffset) + $enabledLiteral + $configContent.Substring($valueExtent.EndOffset)
        }
        else {
            $insertOffset = $solutionCheckHashtable.Extent.EndOffset - 1
            $insertText = "$lineEnding        enabled = $enabledLiteral$lineEnding    "
            $updatedContent = $configContent.Substring(0, $insertOffset) + $insertText + $configContent.Substring($insertOffset)
        }
    }
    else {
        $insertOffset = $rootHashtable.Extent.EndOffset - 1
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

function Get-AlmConfigForSetup {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$ConfigPath
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        return @{}
    }

    try {
        return (Import-PowerShellDataFile -LiteralPath $ConfigPath)
    }
    catch {
        throw "Could not import ALM setup configuration '$ConfigPath': $($_.Exception.Message)"
    }
}

function ConvertFrom-AlmConfigContentForSetup {
    <#
    .SYNOPSIS
        Imports a committed alm-config.psd1 value without changing the repository.
    .DESCRIPTION
        Writes the supplied data-file text to a uniquely named temporary PSD1,
        imports it with Import-PowerShellDataFile, and removes the temporary file.
        Invalid data or filesystem failures throw with setup context.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowEmptyString()][string]$ConfigContent = ''
    )

    if ([string]::IsNullOrWhiteSpace($ConfigContent)) {
        return @{}
    }

    $temporaryPath = Join-Path ([System.IO.Path]::GetTempPath()) ("alm-config-setup-" + [guid]::NewGuid().ToString('n') + '.psd1')
    try {
        Set-Content -LiteralPath $temporaryPath -Value $ConfigContent -NoNewline
        $configuration = Import-PowerShellDataFile -LiteralPath $temporaryPath
        if ($configuration -isnot [System.Collections.IDictionary]) {
            throw 'The root value must be a hashtable.'
        }
        return $configuration
    }
    catch {
        throw "Could not import committed alm-config.psd1 content: $($_.Exception.Message)"
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction Stop
        }
    }
}

function ConvertTo-AlmLegacyBranchConfiguration {
    <#
    .SYNOPSIS
        Builds a branches map from facts discovered in a repository configured before branch settings were committed.
    .DESCRIPTION
        Each discovered branch becomes an entry, even when it has no settings, so its name is retained.
        Only non-empty settings are written. buildValidation is written only when BUILD names an
        environment, and it carries the legacy global baselineRelease when one is set. Providers decide
        which discovered facts count as evidence.
    .PARAMETER BranchFacts
        Objects with BranchName, DevEnvironmentName, DeploymentEnvironmentNames and BuildEnvironmentName.
    .PARAMETER LegacyBaselineRelease
        Global buildValidation.baselineRelease from the legacy file, or empty.
    .OUTPUTS
        System.Collections.Hashtable keyed by branch name.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$BranchFacts,
        [Parameter()][string]$LegacyBaselineRelease = ''
    )

    $branches = @{}
    foreach ($fact in $BranchFacts) {
        $branchEntry = @{}
        if (-not [string]::IsNullOrWhiteSpace([string]$fact.DevEnvironmentName)) {
            $branchEntry['developmentEnvironment'] = [string]$fact.DevEnvironmentName
        }

        $deploymentEnvironments = @($fact.DeploymentEnvironmentNames | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($deploymentEnvironments.Count -gt 0) {
            $branchEntry['deploymentEnvironments'] = $deploymentEnvironments
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$fact.BuildEnvironmentName)) {
            $buildValidation = @{ environmentName = [string]$fact.BuildEnvironmentName }
            if (-not [string]::IsNullOrWhiteSpace($LegacyBaselineRelease)) {
                $buildValidation['baselineRelease'] = $LegacyBaselineRelease
            }
            $branchEntry['buildValidation'] = $buildValidation
        }

        $branches[[string]$fact.BranchName] = $branchEntry
    }

    return $branches
}

function Get-AlmSetupBranchConfiguration {
    <#
    .SYNOPSIS
        Returns one branch's setup settings by case-insensitive branch name.
    .DESCRIPTION
        A missing branches map or branch returns an empty hashtable. Malformed branch
        maps and branch values throw rather than silently reverting to workflow discovery.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary], [System.Collections.Hashtable])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][string]$BranchName
    )

    if (-not $Config.Contains('branches') -or $null -eq $Config.branches) {
        return @{}
    }
    if ($Config.branches -isnot [System.Collections.IDictionary]) {
        throw 'The branches setting in alm-config.psd1 must be a hashtable keyed by branch name.'
    }

    foreach ($configuredBranchName in $Config.branches.Keys) {
        if ([string]$configuredBranchName -ieq $BranchName) {
            $branchConfiguration = $Config.branches[$configuredBranchName]
            if ($branchConfiguration -isnot [System.Collections.IDictionary]) {
                throw "Configuration for branch '$BranchName' in alm-config.psd1 must be a hashtable."
            }
            return $branchConfiguration
        }
    }

    return @{}
}

function Assert-AlmSetupConfigurationForApply {
    <#
    .SYNOPSIS
        Validates the minimum setup metadata required to generate repository artifacts.
    .DESCRIPTION
        ApplyConfig requires an explicit provider, shared repository/ref, and at least
        one branch. It never infers missing values from existing caller files.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Configuration,
        [Parameter(Mandatory)][ValidateSet('GitHub', 'azDO')][string]$Provider
    )

    if ([string](Get-OptionalObjectPropertyValue -InputObject $Configuration -PropertyName 'provider') -ine $Provider) {
        throw "ApplyConfig requires alm-config.psd1 to declare provider = '$Provider'."
    }

    foreach ($propertyName in @('repository', 'ref')) {
        if (
            -not $Configuration.Contains($propertyName) -or
            $Configuration[$propertyName] -isnot [string] -or
            [string]::IsNullOrWhiteSpace($Configuration[$propertyName])
        ) {
            throw "ApplyConfig requires a non-empty '$propertyName' string in alm-config.psd1."
        }
    }

    if (-not $Configuration.Contains('branches') -or $Configuration.branches -isnot [System.Collections.IDictionary] -or $Configuration.branches.Count -eq 0) {
        throw 'ApplyConfig requires a non-empty branches map in alm-config.psd1.'
    }

    foreach ($branchName in $Configuration.branches.Keys) {
        if ([string]::IsNullOrWhiteSpace([string]$branchName)) {
            throw 'ApplyConfig requires every branches map key to be a non-empty branch name.'
        }
        if ($Configuration.branches[$branchName] -isnot [System.Collections.IDictionary]) {
            throw "Configuration for branch '$branchName' in alm-config.psd1 must be a hashtable."
        }
    }

    return $Configuration
}

function Get-AlmSetupBuildValidationEnvironmentMap {
    <#
    .SYNOPSIS
        Builds a branch-to-environment map for generated BUILD callers.
    .DESCRIPTION
        Includes only enabled branches and throws when an enabled branch lacks a
        branch name or validation environment.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][array]$BranchStates
    )

    $environments = [ordered]@{}
    foreach ($branchState in $BranchStates) {
        if (-not [bool](Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'BuildValidationEnabled')) {
            continue
        }

        $branchName = [string](Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'BranchName')
        $environmentConfiguration = Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'BuildValidationEnvironmentConfiguration'
        $environmentName = [string](Get-OptionalObjectPropertyValue -InputObject $environmentConfiguration -PropertyName 'ShortName')
        if ([string]::IsNullOrWhiteSpace($environmentName)) {
            $environmentName = [string](Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'BuildValidationEnvironmentName')
        }
        if ([string]::IsNullOrWhiteSpace($branchName) -or [string]::IsNullOrWhiteSpace($environmentName)) {
            throw 'Enabled BUILD validation state must include a branch name and environment name.'
        }

        $environments[$branchName] = $environmentName
    }

    return $environments
}

function Get-AlmSetupConfiguration {
    <#
    .SYNOPSIS
        Builds the provider-neutral setup portion of alm-config.psd1.
    .DESCRIPTION
        Serializes shared provider/repository/ref keys, flat provider-specific options,
        and each branch's development, deployment and BUILD validation environments.
        A missing DevEnvironmentConfiguration falls back to ExistingDevEnvironment so a
        discovered or previously committed DEV target is not dropped from the file.
        Disabled BUILD validation is written explicitly to prevent legacy global
        selectors from being inherited by that branch.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][ValidateSet('GitHub', 'azDO')][string]$Provider,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Ref,
        [Parameter(Mandatory)][array]$BranchStates,
        [Parameter()][System.Collections.IDictionary]$ProviderOptions = @{}
    )

    $settings = [ordered]@{
        provider = $Provider
        repository = $Repository
        ref = $Ref
    }
    foreach ($option in $ProviderOptions.GetEnumerator()) {
        $settings[[string]$option.Key] = $option.Value
    }

    $branches = [ordered]@{}
    foreach ($branchState in $BranchStates) {
        $branchName = [string](Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'BranchName')
        if ([string]::IsNullOrWhiteSpace($branchName)) {
            throw 'Branch setup state must include a non-empty BranchName.'
        }

        $devEnvironment = Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'DevEnvironmentConfiguration'
        if ($null -eq $devEnvironment) {
            $devEnvironment = Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'ExistingDevEnvironment'
        }
        $developmentEnvironmentName = [string](Get-OptionalObjectPropertyValue -InputObject $devEnvironment -PropertyName 'ShortName')
        $deploymentEnvironmentNames = @(
            Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'DeploymentEnvironments' |
                ForEach-Object { [string](Get-OptionalObjectPropertyValue -InputObject $_ -PropertyName 'ShortName') } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )

        $buildValidationEnabled = [bool](Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'BuildValidationEnabled')
        $buildEnvironment = Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'BuildValidationEnvironmentConfiguration'
        $buildEnvironmentName = [string](Get-OptionalObjectPropertyValue -InputObject $buildEnvironment -PropertyName 'ShortName')
        if ([string]::IsNullOrWhiteSpace($buildEnvironmentName)) {
            $buildEnvironmentName = [string](Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'BuildValidationEnvironmentName')
        }
        if ($buildValidationEnabled -and [string]::IsNullOrWhiteSpace($buildEnvironmentName)) {
            throw "BUILD validation for branch '$branchName' is enabled but has no environment name."
        }

        $branches[$branchName] = [ordered]@{
            developmentEnvironment = $developmentEnvironmentName
            deploymentEnvironments = $deploymentEnvironmentNames
            buildValidation = [ordered]@{
                environmentName = $(if ($buildValidationEnabled) { $buildEnvironmentName } else { '' })
                baselineRelease = $(if ($buildValidationEnabled) { [string](Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'BuildValidationBaselineRelease') } else { '' })
            }
        }
    }
    $settings.branches = $branches
    return $settings
}

function Set-AlmConfigSetupSettingsInFile {
    <#
    .SYNOPSIS
        Updates selected top-level setup settings while preserving unrelated source.
    .PARAMETER Settings
        A hashtable of provider, repository, ref, provider options and branch settings.
        Values must be PowerShell data types; scriptblocks and arbitrary objects fail.
    .DESCRIPTION
        Replaces only the selected root values or inserts missing keys. Existing
        comments and unrelated configuration remain untouched. Missing files require
        CreateIfMissing. Parse, shape and unsupported-value errors throw; writes are
        not transactional. Returns whether the file text changed.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings,
        [Parameter()][switch]$CreateIfMissing,
        [Parameter()][string]$TemplatePath
    )

    if (-not $PSCmdlet.ShouldProcess($ConfigPath, 'Update ALM setup settings')) {
        return $false
    }

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

    $lineEnding = if ($configContent -match "`r`n") { "`r`n" } else { "`n" }
    $replacements = @()
    $insertions = @()
    foreach ($setting in $Settings.GetEnumerator()) {
        $keyName = [string]$setting.Key
        if ([string]::IsNullOrWhiteSpace($keyName)) {
            throw 'ALM setup setting names cannot be empty.'
        }

        $serializedValue = ConvertTo-SetupPowerShellDataLiteral -Value $setting.Value
        $settingEntry = $rootHashtable.KeyValuePairs | Where-Object {
            $keyText = $_.Item1.Extent.Text.Trim()
            $keyText.Trim("'").Trim('"') -ieq $keyName
        } | Select-Object -First 1

        if ($settingEntry) {
            $valueExtent = $settingEntry.Item2.Extent
            $replacements += [pscustomobject]@{
                StartOffset = $valueExtent.StartOffset
                EndOffset   = $valueExtent.EndOffset
                Value       = $serializedValue
            }
        }
        else {
            $escapedKey = $keyName.Replace("'", "''")
            $insertions += "    '$escapedKey' = $serializedValue"
        }
    }

    $updatedContent = $configContent
    if ($insertions.Count -gt 0) {
        $insertOffset = $rootHashtable.Extent.EndOffset - 1
        $prefix = if ($insertOffset -gt 0 -and $configContent.Substring(0, $insertOffset).EndsWith($lineEnding)) { '' } else { $lineEnding }
        $insertText = $prefix + ($insertions -join $lineEnding) + $lineEnding
        $replacements += [pscustomobject]@{
            StartOffset = $insertOffset
            EndOffset   = $insertOffset
            Value       = $insertText
        }
    }

    foreach ($replacement in @($replacements | Sort-Object StartOffset -Descending)) {
        $updatedContent = $updatedContent.Substring(0, $replacement.StartOffset) +
            $replacement.Value +
            $updatedContent.Substring($replacement.EndOffset)
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
        cancelling returns to the environment-detail menu. CurrentBaselineRelease marks
        the current choice, including an empty no-baseline choice, and lists it first
        because the selection prompt has no default-index setting. This chooses a
        selector, not a release artifact.
    .PARAMETER CurrentBaselineRelease
        The configured @shortName baseline, an empty string for no baseline, or null
        when no baseline has been configured yet.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][array]$DeploymentEnvironments,
        [Parameter()][AllowEmptyString()][string]$ExcludedEnvironmentName = '',
        [Parameter()][AllowEmptyString()][string]$ExcludedEnvironmentUrl = '',
        [Parameter()][AllowNull()][AllowEmptyString()][string]$CurrentBaselineRelease = $null
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

    $environmentEntries = @($uniqueEnvironments | ForEach-Object {
        $friendlyName = if ([string]::IsNullOrWhiteSpace($_.FriendlyName)) { $_.ShortName } else { $_.FriendlyName }
        [pscustomobject]@{
            Label     = "$friendlyName ($($_.ShortName))"
            ShortName = [string]$_.ShortName
            Value     = "@$($_.ShortName)"
        }
    })

    $currentBaselineShortName = ''
    if (-not [string]::IsNullOrWhiteSpace($CurrentBaselineRelease)) {
        $currentBaselineShortName = $CurrentBaselineRelease.Trim()
        if ($currentBaselineShortName.StartsWith('@')) {
            $currentBaselineShortName = $currentBaselineShortName.Substring(1)
        }
    }

    $entries = @()
    if ($null -ne $CurrentBaselineRelease) {
        $currentEntry = $environmentEntries | Where-Object { $_.ShortName -ieq $currentBaselineShortName } | Select-Object -First 1
        if ($currentEntry) {
            $entries += [pscustomobject]@{
                Label = "$($currentEntry.Label) (current)"
                Value = $currentEntry.Value
            }
        }
        elseif ([string]::IsNullOrWhiteSpace($currentBaselineShortName)) {
            $entries += [pscustomobject]@{
                Label = 'No baseline release (current)'
                Value = ''
            }
        }
    }

    if (@($entries | Where-Object { [string]::IsNullOrEmpty($_.Value) }).Count -eq 0) {
        $entries += [pscustomobject]@{
            Label = 'No baseline release'
            Value = ''
        }
    }

    foreach ($environmentEntry in $environmentEntries) {
        if (@($entries | Where-Object { $_.Value -eq $environmentEntry.Value }).Count -gt 0) {
            continue
        }
        $entries += [pscustomobject]@{
            Label = $environmentEntry.Label
            Value = $environmentEntry.Value
        }
    }

    $selectedIndex = Select-FromMenu -Title 'Select the separate deployment environment whose latest successful deployment should be used as the BUILD validation baseline' -Items @($entries.Label)
    if ($null -eq $selectedIndex) {
        Request-SetupWizardBack
    }

    return [string]$entries[$selectedIndex].Value
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
    .PARAMETER InitialEditEnvironmentName
        Opens the edit callback directly for the matching short or friendly name, then
        returns the updated list.
    .DESCRIPTION
        Initial objects are retained, not deep-cloned. Move earlier and later reorder
        existing entries without reopening their detail editor, so promotion order can
        change without re-entering credentials. Done or a null management selection
        emits the current list. Callbacks own validation and side effects; exceptions,
        including wizard navigation, propagate without rollback.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter()][array]$InitialEnvironments,
        [Parameter(Mandatory)][scriptblock]$AddEnvironmentScriptBlock,
        [Parameter()][scriptblock]$EditEnvironmentScriptBlock,
        [Parameter()][string]$InitialEditEnvironmentName,
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

    $formatEnvironmentMenuLabel = {
        param($Environment)
        $shortName = [string]$Environment.ShortName
        $friendlyName = if ([string]::IsNullOrWhiteSpace($Environment.FriendlyName)) { $shortName } else { [string]$Environment.FriendlyName }
        $url = if ([string]::IsNullOrWhiteSpace($Environment.Url)) { '<not set>' } else { [string]$Environment.Url }
        "$shortName - $friendlyName ($url)"
    }.GetNewClosure()

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

        if (-not [string]::IsNullOrWhiteSpace($InitialEditEnvironmentName)) {
            if (-not $EditEnvironmentScriptBlock) {
                throw 'An initial environment edit was requested but no edit callback is available.'
            }

            $editIndex = -1
            for ($environmentIndex = 0; $environmentIndex -lt $selectedEnvironments.Count; $environmentIndex++) {
                if ([string]$selectedEnvironments[$environmentIndex].ShortName -ieq $InitialEditEnvironmentName) {
                    $editIndex = $environmentIndex
                    break
                }
            }
            if ($editIndex -lt 0) {
                for ($environmentIndex = 0; $environmentIndex -lt $selectedEnvironments.Count; $environmentIndex++) {
                    if ([string]$selectedEnvironments[$environmentIndex].FriendlyName -ieq $InitialEditEnvironmentName) {
                        if ($editIndex -ge 0) {
                            throw "More than one deployment environment matches '$InitialEditEnvironmentName'."
                        }
                        $editIndex = $environmentIndex
                    }
                }
            }
            if ($editIndex -lt 0) {
                throw "No deployment environment matches '$InitialEditEnvironmentName'."
            }

            $updatedEnvironment = & $EditEnvironmentScriptBlock @($selectedEnvironments) $selectedEnvironments[$editIndex] $editIndex
            if ($null -ne $updatedEnvironment) {
                $selectedEnvironments[$editIndex] = $updatedEnvironment
            }
            return @($selectedEnvironments)
        }

        $menuItems = @('Add an environment')
        if ($selectedEnvironments.Count -gt 0) {
            if ($EditEnvironmentScriptBlock) {
                $menuItems += 'Edit an environment'
            }
            if ($selectedEnvironments.Count -gt 1) {
                $menuItems += 'Move an environment earlier'
                $menuItems += 'Move an environment later'
            }
            $menuItems += 'Remove an environment'
            $menuItems += 'Clear list'
            $menuItems += 'Done'
        }
        else {
            $menuItems += 'Done'
        }

        $selection = Select-FromMenu `
            -Title $Title `
            -Items $menuItems `
            -ActionItems @('Done') `
            -ActionSectionTitle '---' `
            -PreserveExistingContent `
            -SkipPromptGuidance
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
            'Move an environment earlier' {
                $moveIndexes = @(1..($selectedEnvironments.Count - 1))
                $environmentMenuItems = @($moveIndexes | ForEach-Object { & $formatEnvironmentMenuLabel $selectedEnvironments[$_] })
                $moveSelection = Select-FromMenu -Title 'Select the environment to move earlier' -Items $environmentMenuItems
                if ($null -ne $moveSelection) {
                    $moveIndex = $moveIndexes[$moveSelection]
                    $movedEnvironment = $selectedEnvironments[$moveIndex]
                    $selectedEnvironments[$moveIndex] = $selectedEnvironments[$moveIndex - 1]
                    $selectedEnvironments[$moveIndex - 1] = $movedEnvironment
                }
            }
            'Move an environment later' {
                $moveIndexes = @(0..($selectedEnvironments.Count - 2))
                $environmentMenuItems = @($moveIndexes | ForEach-Object { & $formatEnvironmentMenuLabel $selectedEnvironments[$_] })
                $moveSelection = Select-FromMenu -Title 'Select the environment to move later' -Items $environmentMenuItems
                if ($null -ne $moveSelection) {
                    $moveIndex = $moveIndexes[$moveSelection]
                    $movedEnvironment = $selectedEnvironments[$moveIndex]
                    $selectedEnvironments[$moveIndex] = $selectedEnvironments[$moveIndex + 1]
                    $selectedEnvironments[$moveIndex + 1] = $movedEnvironment
                }
            }
            'Remove an environment' {
                $environmentMenuItems = @($selectedEnvironments | ForEach-Object { & $formatEnvironmentMenuLabel $_ })

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
                $environmentMenuItems = @($selectedEnvironments | ForEach-Object { & $formatEnvironmentMenuLabel $_ })

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
    [OutputType([bool])]
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

    $table = New-SpectreTable -Columns @('Branch', 'DEV environment', 'Deployment environments', 'BUILD validation')
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

        $buildValidationLabel = 'Disabled'
        if ($mapping.PSObject.Properties.Name -contains 'BuildValidationEnabled' -and $mapping.BuildValidationEnabled) {
            $buildValidationLabel = [string]$mapping.BuildValidationEnvironmentName
            if ([string]::IsNullOrWhiteSpace($buildValidationLabel)) {
                $buildValidationLabel = 'Enabled'
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$mapping.BuildValidationBaselineRelease)) {
                $buildValidationLabel += " (baseline: $([string]$mapping.BuildValidationBaselineRelease))"
            }
        }

        Add-SpectreTableRow -Table $table -Cells @(
            $branchName,
            $devEnvironmentLabel,
            $(if ($environmentNames.Count -gt 0) { $environmentNames -join ', ' } else { '<none>' }),
            $buildValidationLabel
        )
    }

    [Spectre.Console.AnsiConsole]::Write($table)
}

function Get-SetupEnvironmentConfigurationSummary {
    <#
    .SYNOPSIS
        Summarizes environment configuration without displaying secrets.
    .DESCRIPTION
        Includes the selected Dataverse environment, credential metadata, service
        account and, when requested, the BUILD baseline selection.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()][object]$EnvironmentConfiguration,
        [Parameter()][switch]$IncludeBaseline,
        [Parameter()][AllowEmptyString()][string]$BaselineRelease = '',
        [Parameter()][switch]$BaselineConfigured
    )

    $friendlyName = [string](Get-OptionalObjectPropertyValue -InputObject $EnvironmentConfiguration -PropertyName 'FriendlyName')
    $environmentUrl = [string](Get-OptionalObjectPropertyValue -InputObject $EnvironmentConfiguration -PropertyName 'Url')
    $dataverseEnvironment = if (-not [string]::IsNullOrWhiteSpace($friendlyName) -and -not [string]::IsNullOrWhiteSpace($environmentUrl)) {
        "$friendlyName ($environmentUrl)"
    }
    elseif (-not [string]::IsNullOrWhiteSpace($friendlyName)) {
        $friendlyName
    }
    elseif (-not [string]::IsNullOrWhiteSpace($environmentUrl)) {
        $environmentUrl
    }
    else {
        'not configured'
    }

    $credentials = Get-OptionalObjectPropertyValue -InputObject $EnvironmentConfiguration -PropertyName 'Credentials'
    $credentialSummary = if ($credentials) {
        [string](Get-CredentialSummaryText -Credentials $credentials)
    }
    else {
        'not configured'
    }
    if ([string]::IsNullOrWhiteSpace($credentialSummary)) {
        $credentialSummary = 'configured'
    }

    $serviceAccount = [string](Get-OptionalObjectPropertyValue -InputObject $EnvironmentConfiguration -PropertyName 'ServiceAccountUPN')
    if ([string]::IsNullOrWhiteSpace($serviceAccount)) {
        $serviceAccount = 'not configured'
    }

    $summaryParts = @(
        "Dataverse: $dataverseEnvironment"
        "Credentials: $credentialSummary"
        "Service account: $serviceAccount"
    )
    if ($IncludeBaseline) {
        $baselineSummary = if (-not $BaselineConfigured) {
            'not configured'
        }
        elseif ([string]::IsNullOrWhiteSpace($BaselineRelease)) {
            'none'
        }
        else {
            $BaselineRelease
        }
        $summaryParts += "Baseline: $baselineSummary"
    }

    return ($summaryParts -join '; ')
}

function Invoke-SetupEnvironmentConfigurationWizard {
    <#
    .SYNOPSIS
        Edits the parts of one Dataverse environment configuration in order.
    .DESCRIPTION
        Uses a nested wizard so Dataverse selection, editable target names,
        credentials, service-account ownership, and an optional BUILD baseline
        have independent completion summaries. A generated target name is locked
        and pre-completed. Changing the Dataverse URL clears credentials and
        ownership selected for a different environment. Done returns the updated
        state; cancelling returns null to the calling editor.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'SelectDataverseEnvironmentAction', Justification = 'Captured by the nested Dataverse-environment step.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'SelectCredentialsAction', Justification = 'Captured by the nested credential step.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'SelectServiceAccountAction', Justification = 'Captured by the nested service-account step.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][scriptblock]$SelectDataverseEnvironmentAction,
        [Parameter()][AllowNull()][object]$InitialConfiguration,
        [Parameter()][AllowEmptyString()][string]$InitialTargetName = '',
        [Parameter()][string]$DataverseEnvironmentStepName = 'Dataverse environment',
        [Parameter()][scriptblock]$SelectTargetNameAction,
        [Parameter()][string]$TargetNameStepName = 'Target name',
        [Parameter()][switch]$TargetNameIsFixed,
        [Parameter(Mandatory)][scriptblock]$SelectCredentialsAction,
        [Parameter(Mandatory)][scriptblock]$SelectServiceAccountAction,
        [Parameter()][scriptblock]$SelectBaselineAction,
        [Parameter()][AllowEmptyString()][string]$InitialBaselineRelease = '',
        [Parameter()][switch]$BaselineConfigured,
        [Parameter()][string]$HelpDocRelativePath,
        [Parameter()][string]$HelpRef
    )

    $normalizeEnvironmentUrlScriptBlock = (Get-Command ConvertTo-NormalizedEnvironmentUrl -CommandType Function -ErrorAction Stop).ScriptBlock
    $credentialSummaryScriptBlock = (Get-Command Get-CredentialSummaryText -CommandType Function -ErrorAction Stop).ScriptBlock
    $targetName = [string](Get-OptionalObjectPropertyValue -InputObject $InitialConfiguration -PropertyName 'ShortName')
    if ([string]::IsNullOrWhiteSpace($targetName)) {
        $targetName = $InitialTargetName
    }

    $environmentState = [pscustomobject]@{
        ShortName         = $targetName
        FriendlyName      = [string](Get-OptionalObjectPropertyValue -InputObject $InitialConfiguration -PropertyName 'FriendlyName')
        Url               = ConvertTo-NormalizedEnvironmentUrl -Url ([string](Get-OptionalObjectPropertyValue -InputObject $InitialConfiguration -PropertyName 'Url'))
        Credentials       = Get-OptionalObjectPropertyValue -InputObject $InitialConfiguration -PropertyName 'Credentials'
        ServiceAccountUPN = [string](Get-OptionalObjectPropertyValue -InputObject $InitialConfiguration -PropertyName 'ServiceAccountUPN')
        BaselineRelease   = $InitialBaselineRelease
        BaselineConfigured = [bool]$BaselineConfigured
    }

    $steps = [System.Collections.Generic.List[object]]::new()
    $steps.Add([pscustomobject]@{
        Name = $DataverseEnvironmentStepName
        IsComplete = -not [string]::IsNullOrWhiteSpace($environmentState.Url)
        Summary = {
            if ([string]::IsNullOrWhiteSpace($environmentState.Url)) {
                return 'Not selected'
            }
            if ([string]::IsNullOrWhiteSpace($environmentState.FriendlyName)) {
                return $environmentState.Url
            }
            return "$($environmentState.FriendlyName) ($($environmentState.Url))"
        }.GetNewClosure()
        Action = {
            $selectedEnvironment = & $SelectDataverseEnvironmentAction $environmentState
            if ($null -eq $selectedEnvironment) {
                Request-SetupWizardBack
            }

            $selectedUrl = [string](& $normalizeEnvironmentUrlScriptBlock -Url ([string]$selectedEnvironment.Url))
            if ([string]::IsNullOrWhiteSpace($selectedUrl)) {
                Request-SetupWizardBack
            }

            if ($selectedUrl -ine $environmentState.Url) {
                $environmentState.Credentials = $null
                $environmentState.ServiceAccountUPN = ''
            }
            $environmentState.FriendlyName = [string]$selectedEnvironment.FriendlyName
            $environmentState.Url = $selectedUrl
        }.GetNewClosure()
    })

    if ($SelectTargetNameAction -or $TargetNameIsFixed) {
        $targetNameStep = [pscustomobject]@{
            Name = $TargetNameStepName
            IsComplete = -not [string]::IsNullOrWhiteSpace($environmentState.ShortName)
            IsLocked = [bool]$TargetNameIsFixed
            Summary = {
                if ([string]::IsNullOrWhiteSpace($environmentState.ShortName)) {
                    return 'Not configured'
                }
                if ($TargetNameIsFixed) {
                    return "$($environmentState.ShortName) (generated from branch)"
                }
                return $environmentState.ShortName
            }.GetNewClosure()
            Action = if ($SelectTargetNameAction) {
                {
                $selectedTargetName = [string](& $SelectTargetNameAction $environmentState)
                if ([string]::IsNullOrWhiteSpace($selectedTargetName)) {
                    Request-SetupWizardBack
                }
                $environmentState.ShortName = $selectedTargetName.Trim()
                }.GetNewClosure()
            }
            else {
                { Request-SetupWizardBack }.GetNewClosure()
            }
        }
        $steps.Add($targetNameStep)
    }

    $steps.Add([pscustomobject]@{
        Name = 'Credentials'
        IsComplete = $null -ne $environmentState.Credentials
        Summary = {
            if ($null -eq $environmentState.Credentials) {
                return 'Not configured'
            }
            $summary = [string](& $credentialSummaryScriptBlock -Credentials $environmentState.Credentials)
            if ([string]::IsNullOrWhiteSpace($summary)) {
                return 'Configured'
            }
            return $summary
        }.GetNewClosure()
        Action = {
            $selectedCredentials = & $SelectCredentialsAction $environmentState
            if ($null -eq $selectedCredentials) {
                Request-SetupWizardBack
            }
            $environmentState.Credentials = $selectedCredentials
        }.GetNewClosure()
    })
    $steps.Add([pscustomobject]@{
        Name = 'Service account'
        IsComplete = -not [string]::IsNullOrWhiteSpace($environmentState.ServiceAccountUPN)
        Summary = {
            if ([string]::IsNullOrWhiteSpace($environmentState.ServiceAccountUPN)) {
                return 'Not configured'
            }
            return $environmentState.ServiceAccountUPN
        }.GetNewClosure()
        Action = {
            $selectedServiceAccount = [string](& $SelectServiceAccountAction $environmentState)
            if ([string]::IsNullOrWhiteSpace($selectedServiceAccount)) {
                Request-SetupWizardBack
            }
            $environmentState.ServiceAccountUPN = $selectedServiceAccount.Trim()
        }.GetNewClosure()
    })

    if ($SelectBaselineAction) {
        $steps.Add([pscustomobject]@{
            Name = 'BUILD baseline'
            IsComplete = [bool]$environmentState.BaselineConfigured
            Summary = {
                if (-not $environmentState.BaselineConfigured) {
                    return 'Not configured'
                }
                if ([string]::IsNullOrWhiteSpace($environmentState.BaselineRelease)) {
                    return 'No baseline'
                }
                return $environmentState.BaselineRelease
            }.GetNewClosure()
            Action = {
                $selectedBaseline = & $SelectBaselineAction $environmentState
                if ($null -eq $selectedBaseline) {
                    Request-SetupWizardBack
                }
                $environmentState.BaselineRelease = [string]$selectedBaseline
                $environmentState.BaselineConfigured = $true
            }.GetNewClosure()
        })
    }

    $applyAction = { return $environmentState }.GetNewClosure()
    return Invoke-SetupWizard `
        -Title $Title `
        -Steps @($steps.ToArray()) `
        -ApplyAction $applyAction `
        -ApplyActionName 'Done' `
        -RequireSequentialSteps `
        -ReturnToCaller `
        -HelpDocRelativePath $HelpDocRelativePath `
        -HelpRef $HelpRef
}

function Get-SetupBranchMenuItem {
    <#
    .SYNOPSIS
        Creates selectable branch and environment rows for the guided setup menu.
    .DESCRIPTION
        Emits each configured branch and its DEV, deployment, and enabled BUILD-validation
        environments as indented menu entries with targets for focused editing.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter()][AllowNull()][object[]]$BranchStates
    )

    $menuItems = @()
    foreach ($branchState in @($BranchStates)) {
        if ($null -eq $branchState) {
            continue
        }

        $branchName = [string](Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'BranchName')
        if ([string]::IsNullOrWhiteSpace($branchName)) {
            continue
        }

        $menuItems += [pscustomobject]@{
            Label  = $branchName
            Depth  = 1
            Target = [pscustomobject]@{
                Kind       = 'Branch'
                BranchName = $branchName
            }
        }

        $devEnvironment = Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'DevEnvironmentConfiguration'
        if (-not $devEnvironment) {
            $devEnvironment = Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'ExistingDevEnvironment'
        }
        if ($devEnvironment) {
            $devName = [string](Get-OptionalObjectPropertyValue -InputObject $devEnvironment -PropertyName 'ShortName')
            if ([string]::IsNullOrWhiteSpace($devName)) {
                $devName = [string](Get-OptionalObjectPropertyValue -InputObject $devEnvironment -PropertyName 'FriendlyName')
            }
            if ([string]::IsNullOrWhiteSpace($devName)) {
                $devName = 'Configured'
            }
            $devSummary = Get-SetupEnvironmentConfigurationSummary -EnvironmentConfiguration $devEnvironment
            $menuItems += [pscustomobject]@{
                Label  = "DEV: $devName ($branchName) - $devSummary"
                Depth  = 2
                Target = [pscustomobject]@{
                    Kind            = 'DevEnvironment'
                    BranchName      = $branchName
                    EnvironmentName = $devName
                }
            }
        }

        $deploymentEnvironments = Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'DeploymentEnvironments'
        if ($null -eq $deploymentEnvironments) {
            $deploymentEnvironments = Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'Environments'
        }
        $deploymentIndex = 0
        foreach ($environment in @($deploymentEnvironments)) {
            if ($null -eq $environment) {
                continue
            }

            $deploymentIndex++
            $environmentName = [string](Get-OptionalObjectPropertyValue -InputObject $environment -PropertyName 'ShortName')
            if ([string]::IsNullOrWhiteSpace($environmentName)) {
                $environmentName = [string](Get-OptionalObjectPropertyValue -InputObject $environment -PropertyName 'FriendlyName')
            }
            if ([string]::IsNullOrWhiteSpace($environmentName)) {
                $environmentName = "Environment $deploymentIndex"
            }
            $environmentSummary = Get-SetupEnvironmentConfigurationSummary -EnvironmentConfiguration $environment
            $menuItems += [pscustomobject]@{
                Label  = "Deployment: $environmentName ($branchName) - $environmentSummary"
                Depth  = 2
                Target = [pscustomobject]@{
                    Kind            = 'DeploymentEnvironment'
                    BranchName      = $branchName
                    EnvironmentName = $environmentName
                }
            }
        }

        if ([bool](Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'BuildValidationEnabled')) {
            $buildValidationName = [string](Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'BuildValidationEnvironmentName')
            if ([string]::IsNullOrWhiteSpace($buildValidationName)) {
                $buildValidationEnvironment = Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'BuildValidationEnvironmentConfiguration'
                if (-not $buildValidationEnvironment) {
                    $buildValidationEnvironment = Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'ExistingBuildValidationEnvironment'
                }
                $buildValidationName = [string](Get-OptionalObjectPropertyValue -InputObject $buildValidationEnvironment -PropertyName 'ShortName')
            }
            if ([string]::IsNullOrWhiteSpace($buildValidationName)) {
                $buildValidationName = 'Configured'
            }
            $buildValidationEnvironment = Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'BuildValidationEnvironmentConfiguration'
            if (-not $buildValidationEnvironment) {
                $buildValidationEnvironment = Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'ExistingBuildValidationEnvironment'
            }
            $buildValidationSummary = Get-SetupEnvironmentConfigurationSummary `
                -EnvironmentConfiguration $buildValidationEnvironment `
                -IncludeBaseline `
                -BaselineRelease ([string](Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'BuildValidationBaselineRelease')) `
                -BaselineConfigured
            $menuItems += [pscustomobject]@{
                Label  = "BUILD validation: $buildValidationName ($branchName) - $buildValidationSummary"
                Depth  = 2
                Target = [pscustomobject]@{
                    Kind            = 'BuildValidation'
                    BranchName      = $branchName
                    EnvironmentName = $buildValidationName
                }
            }
        }
        else {
            # An empty target name opens the BUILD editor's enable prompt rather than the environment editor.
            $menuItems += [pscustomobject]@{
                Label  = "BUILD validation: Disabled ($branchName) - select to enable"
                Depth  = 2
                Target = [pscustomobject]@{
                    Kind            = 'BuildValidation'
                    BranchName      = $branchName
                    EnvironmentName = ''
                }
            }
        }
    }

    return @($menuItems)
}

function Get-SetupSinglePublishPlanSummary {
    <#
    .SYNOPSIS
        Formats the single repository publication plan for a guided setup menu.
    .DESCRIPTION
        Setup publishes generated files for every configured branch in one change on
        the selected target branch. Returns 'Not configured' when no plan exists.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()][object]$PublishPlan
    )

    if ($null -eq $PublishPlan) {
        return 'Not configured'
    }

    $targetBranch = [string](Get-OptionalObjectPropertyValue -InputObject $PublishPlan -PropertyName 'TargetBranch')
    $mode = [string](Get-OptionalObjectPropertyValue -InputObject $PublishPlan -PropertyName 'Mode')
    if ($mode -eq 'PullRequest') {
        $sourceBranch = [string](Get-OptionalObjectPropertyValue -InputObject $PublishPlan -PropertyName 'BranchName')
        if ([string]::IsNullOrWhiteSpace($sourceBranch)) {
            return "$targetBranch`: pull request for all branches"
        }
        return "$targetBranch`: PR from $sourceBranch for all branches"
    }

    if ($mode -eq 'Direct') {
        return "$targetBranch`: direct commit for all branches"
    }

    if ([string]::IsNullOrWhiteSpace($targetBranch)) {
        return 'Not configured'
    }
    return "$targetBranch`: not configured"
}

function Get-SetupSolutionMenuSummary {
    <#
    .SYNOPSIS
        Formats selected solution names for a guided setup menu.
    .DESCRIPTION
        Shows the source branch and at most three configured solution names. A null
        selection means solution setup has not run; an empty list is a valid selection.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()][object]$SolutionData,
        [Parameter()][string]$SourceBranch
    )

    if ($null -eq $SolutionData) {
        return 'Not configured'
    }

    $solutionNames = @()
    foreach ($solution in @(Get-OptionalObjectPropertyValue -InputObject $SolutionData -PropertyName 'Solutions')) {
        if ($null -eq $solution) {
            continue
        }

        $solutionName = [string](Get-OptionalObjectPropertyValue -InputObject $solution -PropertyName 'name')
        if ([string]::IsNullOrWhiteSpace($solutionName)) {
            $solutionName = [string](Get-OptionalObjectPropertyValue -InputObject $solution -PropertyName 'UniqueName')
        }
        if ([string]::IsNullOrWhiteSpace($solutionName)) {
            $solutionName = [string](Get-OptionalObjectPropertyValue -InputObject $solution -PropertyName 'uniquename')
        }
        if ([string]::IsNullOrWhiteSpace($solutionName)) {
            $solutionName = [string](Get-OptionalObjectPropertyValue -InputObject $solution -PropertyName 'FriendlyName')
        }
        if ([string]::IsNullOrWhiteSpace($solutionName) -and $solution -is [string]) {
            $solutionName = $solution
        }
        if (-not [string]::IsNullOrWhiteSpace($solutionName)) {
            $solutionNames += $solutionName
        }
    }

    $solutionSummary = if ($solutionNames.Count -eq 0) {
        'No solutions selected'
    }
    else {
        $visibleNames = @($solutionNames | Select-Object -First 3)
        if ($solutionNames.Count -gt $visibleNames.Count) {
            $visibleNames += "+$($solutionNames.Count - $visibleNames.Count)"
        }
        $visibleNames -join ', '
    }

    if (-not [string]::IsNullOrWhiteSpace($SourceBranch)) {
        $solutionSummary = '{0}: {1}' -f $SourceBranch, $solutionSummary
    }
    if ($solutionSummary.Length -gt 100) {
        $solutionSummary = $solutionSummary.Substring(0, 97).TrimEnd() + '...'
    }
    return $solutionSummary
}

function Set-BranchBuildValidationMapping {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Updates an in-memory branch mapping record only.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$BranchMapping,
        [Parameter(Mandatory)][object]$BuildValidationSettings
    )

    $requiredProperties = @(
        'BuildValidationEnabled',
        'BuildValidationEnvironmentName',
        'BuildValidationBaselineRelease',
        'BuildValidationEnvironmentConfiguration',
        'ExistingBuildValidationEnvironment'
    )
    $settingsProperties = @($BuildValidationSettings.PSObject.Properties.Name)
    foreach ($propertyName in $requiredProperties) {
        if ($settingsProperties -notcontains $propertyName) {
            throw "Build validation editor result is missing required property '$propertyName'."
        }
    }

    foreach ($propertyName in $requiredProperties) {
        $BranchMapping.$propertyName = $BuildValidationSettings.$propertyName
    }

    $BranchMapping.BuildValidationEnabled = [bool]$BranchMapping.BuildValidationEnabled
    $BranchMapping.BuildValidationEnvironmentName = [string]$BranchMapping.BuildValidationEnvironmentName
    $BranchMapping.BuildValidationBaselineRelease = [string]$BranchMapping.BuildValidationBaselineRelease
    return $BranchMapping
}

function Write-AlmLegacyConfigurationConversionNotice {
    <#
    .SYNOPSIS
        Explains the one-time conversion of branch settings from existing pipeline or workflow files.
    .PARAMETER Conversion
        LegacyConfigurationConversion from the repository setup state. NotRequired writes nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][object]$Conversion
    )

    $status = [string](Get-OptionalObjectPropertyValue -InputObject $Conversion -PropertyName 'Status')
    if ($status -eq 'Converted') {
        $branchNames = @(Get-OptionalObjectPropertyValue -InputObject $Conversion -PropertyName 'BranchNames')
        Write-Host "Branch settings were read from this repository's existing pipeline or workflow files for: $($branchNames -join ', ')." -ForegroundColor Yellow
        Write-Host 'They are saved to alm-config.psd1 when setup completes; the file-change review shows the exact change.' -ForegroundColor Yellow
        Write-Host ''
    }
    elseif ($status -eq 'Failed') {
        $errorMessage = [string](Get-OptionalObjectPropertyValue -InputObject $Conversion -PropertyName 'ErrorMessage')
        Write-Warning "Sorry, setup could not read the existing branch settings automatically: $errorMessage"
        Write-Host 'Continue and re-enter the branch, DEV, deployment and BUILD-validation values for this repository.' -ForegroundColor Yellow
        Write-Host ''
    }
}

function Select-BranchEnvironmentMapping {
    <#
    .SYNOPSIS
        Edits branch, DEV, deployment and BUILD-validation mappings.
    .PARAMETER BranchOnly
        Hides the built-in environment assignment editor; callback-based editors
        remain available.
    .PARAMETER EditDevEnvironmentScriptBlock
        Receives the complete mapping array as one argument, then the current mapping.
        A focused DEV-environment edit also receives the target name as a third
        argument. A normal edit replaces DevEnvironmentConfiguration, including null;
        a null result from a focused edit leaves the current configuration unchanged.
    .PARAMETER EditDeploymentEnvironmentsScriptBlock
        Receives the complete mapping array and current mapping. Its non-null outputs
        replace Environments; no output clears that list.
    .PARAMETER EditBuildValidationScriptBlock
        Receives the complete mapping array and current mapping, and returns a record
        with BUILD-validation settings for the current branch. A focused edit also
        receives the target environment name as a third argument; a null result from
        that edit leaves the current settings unchanged.
    .PARAMETER InitialEditTarget
        Opens a branch editor or one of its environment editors directly before returning
        the updated mappings.
    .PARAMETER IsNewRepository
        Shows the branch-strategy prompt for a new repository only.
    .DESCRIPTION
        Copies mapping records but shares nested environment objects and retains any
        existing PublishPlan so publication choices survive branch edits. A sole empty
        main mapping is initialized with the default branch. The branch strategy is
        prompted only when IsNewRepository is set. Environment callbacks run for
        bootstrap and added branches; existing branches are edited from their menu.
        Each branch editor menu displays that branch's current mapping first.
        Built-in assignment excludes other branches' targets and sorts by ShortName.
        Done checks cross-branch deployment duplicates; a null management selection
        returns current mappings without that check. Callback failures/back navigation
        propagate; no resource changes made by callbacks are rolled back.
        InitialEditTarget skips the outer branch menu and opens the targeted editor.
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
        [Parameter()][switch]$IsNewRepository,
        [Parameter()][scriptblock]$EditDevEnvironmentScriptBlock,
        [Parameter()][scriptblock]$EditDeploymentEnvironmentsScriptBlock,
        [Parameter()][scriptblock]$EditBuildValidationScriptBlock,
        [Parameter()][AllowNull()][object]$InitialEditTarget
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
            BuildValidationEnabled = [bool]$(if ($mapping.PSObject.Properties.Name -contains 'BuildValidationEnabled') { $mapping.BuildValidationEnabled } else { $false })
            BuildValidationEnvironmentName = [string]$(if ($mapping.PSObject.Properties.Name -contains 'BuildValidationEnvironmentName') { $mapping.BuildValidationEnvironmentName } else { '' })
            BuildValidationBaselineRelease = [string]$(if ($mapping.PSObject.Properties.Name -contains 'BuildValidationBaselineRelease') { $mapping.BuildValidationBaselineRelease } else { '' })
            BuildValidationEnvironmentConfiguration = $(if ($mapping.PSObject.Properties.Name -contains 'BuildValidationEnvironmentConfiguration') { $mapping.BuildValidationEnvironmentConfiguration } else { $null })
            ExistingBuildValidationEnvironment = $(if ($mapping.PSObject.Properties.Name -contains 'ExistingBuildValidationEnvironment') { $mapping.ExistingBuildValidationEnvironment } else { $null })
            PublishPlan                 = $(if ($mapping.PSObject.Properties.Name -contains 'PublishPlan') { $mapping.PublishPlan } else { $null })
        }
    }

    if ($IsNewRepository) {
        if ($branchMappings.Count -eq 0) {
            $branchMappings = @(
                [pscustomobject]@{
                    BranchName = 'main'
                    DevEnvironmentConfiguration = $null
                    ExistingDevEnvironment = $null
                    Environments = @()
                    BuildValidationEnabled = $false
                    BuildValidationEnvironmentName = ''
                    BuildValidationBaselineRelease = ''
                    BuildValidationEnvironmentConfiguration = $null
                    ExistingBuildValidationEnvironment = $null
                    PublishPlan = $null
                }
            )
        }

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
                    BuildValidationEnabled = $false
                    BuildValidationEnvironmentName = ''
                    BuildValidationBaselineRelease = ''
                    BuildValidationEnvironmentConfiguration = $null
                    ExistingBuildValidationEnvironment = $null
                    PublishPlan = $null
                },
                [pscustomobject]@{
                    BranchName                  = 'develop'
                    DevEnvironmentConfiguration = $null
                    ExistingDevEnvironment      = $null
                    Environments                = @()
                    BuildValidationEnabled = $false
                    BuildValidationEnvironmentName = ''
                    BuildValidationBaselineRelease = ''
                    BuildValidationEnvironmentConfiguration = $null
                    ExistingBuildValidationEnvironment = $null
                    PublishPlan = $null
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

        if ($EditBuildValidationScriptBlock) {
            for ($bootstrapIndex = 0; $bootstrapIndex -lt $branchMappings.Count; $bootstrapIndex++) {
                $bootstrapMapping = $branchMappings[$bootstrapIndex]
                $buildValidationSettings = & $EditBuildValidationScriptBlock @($branchMappings) $bootstrapMapping
                [void](Set-BranchBuildValidationMapping -BranchMapping $bootstrapMapping -BuildValidationSettings $buildValidationSettings)
                $branchMappings[$bootstrapIndex] = $bootstrapMapping
            }
        }
    }

    $focusedBranchIndex = -1
    $focusedEditAction = ''
    $focusedEnvironmentName = ''
    $targetKind = ''
    if ($null -ne $InitialEditTarget) {
        $targetKind = [string](Get-OptionalObjectPropertyValue -InputObject $InitialEditTarget -PropertyName 'Kind')
        $targetBranchName = [string](Get-OptionalObjectPropertyValue -InputObject $InitialEditTarget -PropertyName 'BranchName')
        $focusedEnvironmentName = [string](Get-OptionalObjectPropertyValue -InputObject $InitialEditTarget -PropertyName 'EnvironmentName')
        for ($branchIndex = 0; $branchIndex -lt $branchMappings.Count; $branchIndex++) {
            if ([string]$branchMappings[$branchIndex].BranchName -ieq $targetBranchName) {
                $focusedBranchIndex = $branchIndex
                break
            }
        }

        if ($focusedBranchIndex -lt 0) {
            throw "Branch '$targetBranchName' is no longer configured."
        }

        $focusedEditAction = switch ($targetKind) {
            'Branch' { '' }
            'DevEnvironment' { 'Edit DEV environment' }
            'DeploymentEnvironment' { 'Edit deployment environments' }
            'BuildValidation' { 'Edit BUILD validation' }
            default { throw "Unsupported branch configuration target '$targetKind'." }
        }
    }

    while ($true) {
        if ($null -eq $InitialEditTarget) {
            Write-Section `
                -Message 'Configure deployment branch mappings' `
                -GuidanceLines @(
                    'Define which branches setup manages, and map each branch to DEV and deployment targets.',
                    'Use a branch edit menu to configure DEV, ordered deployment targets, and BUILD validation.',
                    'Each deployment target should belong to only one branch to avoid ambiguous promotion paths.'
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

            $selection = Select-FromMenu `
                -Title $Title `
                -Items $menuItems `
                -ActionItems @('Done') `
                -ActionSectionTitle '---' `
                -PreserveExistingContent `
                -SkipPromptGuidance
            if ($null -eq $selection) {
                return @($branchMappings)
            }

            $selectedMenuItem = $menuItems[$selection]
        }
        else {
            $selectedMenuItem = 'Edit a branch mapping'
        }

        switch ($selectedMenuItem) {
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
                    BuildValidationEnabled = $false
                    BuildValidationEnvironmentName = ''
                    BuildValidationBaselineRelease = ''
                    BuildValidationEnvironmentConfiguration = $null
                    ExistingBuildValidationEnvironment = $null
                    PublishPlan = $null
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

                if ($EditBuildValidationScriptBlock) {
                    $buildValidationSettings = & $EditBuildValidationScriptBlock @($branchMappings) $newBranchMapping
                    [void](Set-BranchBuildValidationMapping -BranchMapping $newBranchMapping -BuildValidationSettings $buildValidationSettings)
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
                $editIndex = if ($null -ne $InitialEditTarget) {
                    $focusedBranchIndex
                }
                else {
                    Select-FromMenu -Title 'Select branch mapping to edit' -Items $branchMenu
                }
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
                if ($EditBuildValidationScriptBlock) {
                    $mappingMenuItems += 'Edit BUILD validation'
                    if ([bool]$currentMapping.BuildValidationEnabled) {
                        $mappingMenuItems += 'Disable BUILD validation'
                    }
                }
                if (-not $BranchOnly) {
                    $mappingMenuItems += 'Assign environments'
                    $mappingMenuItems += 'Clear all assigned environments'
                }
                $mappingMenuItems += 'Done'

                while ($true) {
                    $isFocusedEnvironmentEdit = $null -ne $InitialEditTarget -and $targetKind -ne 'Branch'
                    if ($isFocusedEnvironmentEdit) {
                        $mappingAction = [Array]::IndexOf($mappingMenuItems, $focusedEditAction)
                        if ($mappingAction -lt 0) {
                            throw "The '$focusedEditAction' editor is not available for branch '$($currentMapping.BranchName)'."
                        }
                    }
                    else {
                        Show-BranchEnvironmentMappingTable -BranchMappings @($currentMapping)
                        [Spectre.Console.AnsiConsole]::WriteLine()
                        $mappingAction = Select-FromMenu `
                            -Title "Edit branch '$($currentMapping.BranchName)'" `
                            -Items $mappingMenuItems `
                            -ActionItems @('Done') `
                            -ActionSectionTitle '---' `
                            -PreserveExistingContent
                    }
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
                            if ($targetKind -eq 'DevEnvironment') {
                                $updatedDevEnvironment = & $EditDevEnvironmentScriptBlock @($branchMappings) $currentMapping $focusedEnvironmentName
                                if ($null -ne $updatedDevEnvironment) {
                                    $currentMapping.DevEnvironmentConfiguration = $updatedDevEnvironment
                                    $branchMappings[$editIndex] = $currentMapping
                                }
                            }
                            else {
                                $currentMapping.DevEnvironmentConfiguration = & $EditDevEnvironmentScriptBlock @($branchMappings) $currentMapping
                                $branchMappings[$editIndex] = $currentMapping
                            }
                        }
                        'Edit deployment environments' {
                            if ($targetKind -eq 'DeploymentEnvironment') {
                                $updatedDeploymentEnvironments = @(& $EditDeploymentEnvironmentsScriptBlock @($branchMappings) $currentMapping $focusedEnvironmentName)
                            }
                            else {
                                $updatedDeploymentEnvironments = @(& $EditDeploymentEnvironmentsScriptBlock @($branchMappings) $currentMapping)
                            }
                            $currentMapping.Environments = @($updatedDeploymentEnvironments | Where-Object { $null -ne $_ })
                            $branchMappings[$editIndex] = $currentMapping
                        }
                        'Edit BUILD validation' {
                            if ($targetKind -eq 'BuildValidation') {
                                $buildValidationSettings = & $EditBuildValidationScriptBlock @($branchMappings) $currentMapping $focusedEnvironmentName
                                if ($null -ne $buildValidationSettings) {
                                    [void](Set-BranchBuildValidationMapping -BranchMapping $currentMapping -BuildValidationSettings $buildValidationSettings)
                                    $branchMappings[$editIndex] = $currentMapping
                                }
                            }
                            else {
                                $buildValidationSettings = & $EditBuildValidationScriptBlock @($branchMappings) $currentMapping
                                [void](Set-BranchBuildValidationMapping -BranchMapping $currentMapping -BuildValidationSettings $buildValidationSettings)
                                $branchMappings[$editIndex] = $currentMapping
                            }
                        }
                        'Disable BUILD validation' {
                            [void](Set-BranchBuildValidationMapping -BranchMapping $currentMapping -BuildValidationSettings ([pscustomobject]@{
                                BuildValidationEnabled = $false
                                BuildValidationEnvironmentName = ''
                                BuildValidationBaselineRelease = ''
                                BuildValidationEnvironmentConfiguration = $null
                                ExistingBuildValidationEnvironment = $currentMapping.ExistingBuildValidationEnvironment
                            }))
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

                                $toggleSelection = Select-FromMenu `
                                    -Title "Select environments for branch '$($currentMapping.BranchName)' (toggle one at a time)" `
                                    -Items @($candidateItems + @('Done')) `
                                    -ActionItems @('Done') `
                                    -ActionSectionTitle '---' `
                                    -PromptGuidanceLines @(
                                        'Choose which configured environments should run in this branch-specific deploy pipeline/workflow.',
                                        'Environment assignments are exclusive across branches in this setup flow.'
                                    ) `
                                    -PreserveExistingContent
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

                    if ($isFocusedEnvironmentEdit) {
                        return @($branchMappings)
                    }
                }

                if ($null -ne $InitialEditTarget) {
                    return @($branchMappings)
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
    [OutputType([string])]
    param(
        [Parameter()][string]$PrimaryRepositoryPath,
        [Parameter()][string]$FallbackRef = 'stable'
    )

    $candidateRepos = @()
    foreach ($candidate in @($PrimaryRepositoryPath, $script:SetupRepositoryRoot)) {
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

function Get-SetupMsalAssemblyPath {
    <#
    .SYNOPSIS
        Resolves the Dataverse module's runtime-compatible MSAL assemblies.
    .DESCRIPTION
        Returns Core and optional Broker paths from one module target-framework
        directory. Core editions prefer the active .NET runtime target and fall
        back to older packaged targets; Desktop uses .NET Framework assemblies.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ModuleBase
    )

    if ($PSVersionTable.PSEdition -eq 'Core') {
        $runtimeMajor = [System.Environment]::Version.Major
        $runtimeTargetFramework = if ($runtimeMajor -ge 10) {
            "net$runtimeMajor.0"
        }
        elseif ($runtimeMajor -eq 9) {
            'net9.0'
        }
        else {
            'net8.0'
        }

        $targetFrameworks = @($runtimeTargetFramework, 'net8.0', 'netcoreapp3.1') | Select-Object -Unique
    }
    else {
        $targetFrameworks = @('net462')
    }

    foreach ($targetFramework in $targetFrameworks) {
        $directory = Join-Path (Join-Path $ModuleBase 'cmdlets') $targetFramework
        $corePath = Join-Path $directory 'Microsoft.Identity.Client.dll'
        if (Test-Path -LiteralPath $corePath -PathType Leaf) {
            $brokerPath = Join-Path $directory 'Microsoft.Identity.Client.Broker.dll'
            if (-not (Test-Path -LiteralPath $brokerPath -PathType Leaf)) {
                $brokerPath = $null
            }

            return [pscustomobject]@{
                CorePath   = $corePath
                BrokerPath = $brokerPath
            }
        }
    }

    $allCoreAssemblies = Get-ChildItem -LiteralPath $ModuleBase -Recurse -File -Filter 'Microsoft.Identity.Client.dll'
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $foundCoreAssembly = $allCoreAssemblies |
            Where-Object { $_.FullName -match 'netcore|netstandard|net\d\.\d' } |
            Sort-Object FullName |
            Select-Object -First 1
    }
    else {
        $foundCoreAssembly = $allCoreAssemblies |
            Where-Object { $_.FullName -match 'net4' } |
            Sort-Object FullName |
            Select-Object -First 1
    }

    if ($foundCoreAssembly) {
        $brokerPath = Join-Path $foundCoreAssembly.DirectoryName 'Microsoft.Identity.Client.Broker.dll'
        if (-not (Test-Path -LiteralPath $brokerPath -PathType Leaf)) {
            $brokerPath = $null
        }

        return [pscustomobject]@{
            CorePath   = $foundCoreAssembly.FullName
            BrokerPath = $brokerPath
        }
    }

    return $null
}

function Get-SetupDefaultContextAssembly {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name
    )

    $assemblies = if ($PSVersionTable.PSEdition -eq 'Core') {
        [System.Runtime.Loader.AssemblyLoadContext]::Default.Assemblies
    }
    else {
        [System.AppDomain]::CurrentDomain.GetAssemblies()
    }

    return $assemblies |
        Where-Object { $_.GetName().Name -eq $Name } |
        Select-Object -First 1
}

function Get-SetupAssemblyVersion {
    param(
        [Parameter(Mandatory)][string]$Path
    )

    return [System.Reflection.AssemblyName]::GetAssemblyName($Path).Version
}

function Initialize-SetupMsalAssembly {
    <#
    .SYNOPSIS
        Loads MSAL Core and Broker together for setup authentication.
    .DESCRIPTION
        Loads matching assemblies into the PowerShell default load context so
        setup's token helper and the Dataverse binary cmdlets share type identity.
        A preloaded assembly with an incompatible version throws. If module assets
        are unavailable, MSAL Core is resolved by its assembly name.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][string]$ModuleBase
    )

    $assemblyPaths = if (-not [string]::IsNullOrWhiteSpace($ModuleBase)) {
        Get-SetupMsalAssemblyPath -ModuleBase $ModuleBase
    }
    else {
        $null
    }

    if (-not $assemblyPaths) {
        [void][System.Reflection.Assembly]::LoadWithPartialName('Microsoft.Identity.Client')
        return
    }

    $expectedCoreVersion = Get-SetupAssemblyVersion -Path $assemblyPaths.CorePath
    if ($assemblyPaths.BrokerPath) {
        $expectedBrokerVersion = Get-SetupAssemblyVersion -Path $assemblyPaths.BrokerPath
        if ($expectedBrokerVersion -ne $expectedCoreVersion) {
            throw "The Dataverse module's MSAL Core ($expectedCoreVersion) and Broker ($expectedBrokerVersion) assemblies do not match."
        }
    }

    $loadedCoreAssembly = Get-SetupDefaultContextAssembly -Name 'Microsoft.Identity.Client'
    if ($loadedCoreAssembly -and $loadedCoreAssembly.GetName().Version -ne $expectedCoreVersion) {
        throw "An incompatible Microsoft.Identity.Client version '$($loadedCoreAssembly.GetName().Version)' is already loaded. The Dataverse module requires '$expectedCoreVersion'; restart PowerShell to load a consistent MSAL pair."
    }

    $loadedBrokerAssembly = Get-SetupDefaultContextAssembly -Name 'Microsoft.Identity.Client.Broker'
    if ($loadedBrokerAssembly -and $loadedBrokerAssembly.GetName().Version -ne $expectedCoreVersion) {
        throw "An incompatible Microsoft.Identity.Client.Broker version '$($loadedBrokerAssembly.GetName().Version)' is already loaded. The Dataverse module requires '$expectedCoreVersion'; restart PowerShell to load a consistent MSAL pair."
    }

    # The binary cmdlets run in the default context; keep Core and Broker together there.
    if (-not $loadedCoreAssembly) {
        Add-Type -Path $assemblyPaths.CorePath -ErrorAction Stop | Out-Null
    }
    if ($assemblyPaths.BrokerPath -and -not $loadedBrokerAssembly) {
        Add-Type -Path $assemblyPaths.BrokerPath -ErrorAction Stop | Out-Null
    }
}

function Get-SetupHostPlatform {
    <#
    .SYNOPSIS
        Identifies the host operating system for sign-in mode selection.
    .DESCRIPTION
        Returns Windows, macOS, Linux or Unknown. Windows PowerShell predates the
        $IsWindows family, so its desktop edition is reported as Windows first;
        the automatic variables are only read on PowerShell Core.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        return 'Windows'
    }
    if ($IsWindows) {
        return 'Windows'
    }
    if ($IsMacOS) {
        return 'macOS'
    }
    if ($IsLinux) {
        return 'Linux'
    }

    return 'Unknown'
}

function Get-SetupAuthenticationMode {
    <#
    .SYNOPSIS
        Chooses browser or device-code sign-in for setup MSAL requests.
    .DESCRIPTION
        MSAL opens the system browser on Windows and macOS. On Linux it starts a
        launcher found on PATH and does not check that a browser appeared, so a
        launcher alone cannot prove that sign-in is possible. Browser sign-in is
        selected only for a graphical session, or for WSL where wslview opens the
        Windows browser. Containers, SSH sessions and CI use device code, where
        the user enters a code in a browser on any device and the token arrives
        over outbound polling instead of a local redirect.
    .OUTPUTS
        System.String
        Interactive or DeviceCode.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $platform = Get-SetupHostPlatform

    if ($platform -in @('Windows', 'macOS')) {
        return 'Interactive'
    }

    if ($platform -ne 'Linux') {
        return 'DeviceCode'
    }

    $hasGraphicalSession =
        -not [string]::IsNullOrWhiteSpace($env:DISPLAY) -or
        -not [string]::IsNullOrWhiteSpace($env:WAYLAND_DISPLAY)

    # Mirrors the launchers MSAL probes before it starts the first one found.
    foreach ($launcher in @('xdg-open', 'gnome-open', 'kfmclient', 'microsoft-edge', 'wslview')) {
        if (-not (Get-Command -Name $launcher -CommandType Application -ErrorAction SilentlyContinue)) {
            continue
        }

        if ($hasGraphicalSession -or $launcher -eq 'wslview') {
            return 'Interactive'
        }
    }

    return 'DeviceCode'
}

function Test-SetupBrowserLaunchFailure {
    <#
    .SYNOPSIS
        Reports whether an interactive MSAL failure means no browser could start.
    .DESCRIPTION
        MSAL raises linux_xdg_open_failed when a launcher exists but cannot open
        the page. PowerShell can wrap the MSAL exception, and older releases only
        provide the message, so the complete exception chain is inspected before
        deciding whether a device-code retry is safe.
    .PARAMETER ErrorRecord
        Error raised while executing the interactive MSAL request.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]$ErrorRecord
    )

    $exception = $ErrorRecord.Exception
    while ($exception) {
        if ($exception.PSObject.Properties['ErrorCode'] -and $exception.ErrorCode -eq 'linux_xdg_open_failed') {
            return $true
        }
        if ($exception.Message -match 'Unable to open a web page using xdg-open|linux_xdg_open_failed') {
            return $true
        }

        $exception = $exception.InnerException
    }

    return $false
}

function Invoke-SetupDeviceCodeAuthentication {
    <#
    .SYNOPSIS
        Acquires a setup token with the OAuth device-code flow.
    .DESCRIPTION
        MSAL prints the verification URL and user code through the callback while
        setup waits for the browser session to complete. MSAL invokes that callback
        on a thread without a PowerShell runspace, where a ScriptBlock delegate
        fails, so the callback is compiled to write the message with Console.WriteLine
        and return a completed task.
    .PARAMETER Application
        MSAL public client used for the request.
    .PARAMETER Scopes
        Resource scopes for the requested token.
    .OUTPUTS
        Microsoft.Identity.Client.AuthenticationResult
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Application,
        [Parameter(Mandatory)][string[]]$Scopes
    )

    $deviceCodeParameter = [System.Linq.Expressions.Expression]::Parameter([Microsoft.Identity.Client.DeviceCodeResult], 'deviceCodeResult')
    $deviceCodeMessage = [System.Linq.Expressions.Expression]::Property($deviceCodeParameter, 'Message')
    $writeLineMethod = [System.Console].GetMethod('WriteLine', [Type[]]@([string]))
    $deviceCodeBody = [System.Linq.Expressions.Expression]::Block(
        [System.Linq.Expressions.Expression]::Call($writeLineMethod, [System.Linq.Expressions.Expression]::Constant('')),
        [System.Linq.Expressions.Expression]::Call($writeLineMethod, $deviceCodeMessage),
        [System.Linq.Expressions.Expression]::Call($writeLineMethod, [System.Linq.Expressions.Expression]::Constant('')),
        [System.Linq.Expressions.Expression]::Constant([System.Threading.Tasks.Task]::CompletedTask)
    )
    $deviceCodeLambda = [System.Linq.Expressions.Expression]::Lambda(
        [System.Func[Microsoft.Identity.Client.DeviceCodeResult, System.Threading.Tasks.Task]],
        $deviceCodeBody,
        $deviceCodeParameter
    )
    $deviceCodeCallback = [System.Func[Microsoft.Identity.Client.DeviceCodeResult, System.Threading.Tasks.Task]]($deviceCodeLambda.Compile())

    return $Application.AcquireTokenWithDeviceCode($Scopes, $deviceCodeCallback).ExecuteAsync().GetAwaiter().GetResult()
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
        Loads matching MSAL Core and optional Broker assemblies into the PowerShell
        default load context from the loaded Dataverse module. Script-scoped MsalApp
        is reused: ClientId and TenantId only affect its first construction.
        Loads/saves serialized MSAL V3 bytes under local app data without additional
        encryption here; cache read/write failures warn. Silent failure falls back
        to browser or device-code sign-in as the host allows, and a browser that
        cannot open retries with device code; other sign-in errors throw. The
        normal result is MSAL AuthenticationResult, not just its access-token text.
    #>
    param(
        [Parameter(Mandatory)][string]$ResourceUrl,
        [Parameter()][string]$TenantId,
        [Parameter()][string]$ClientId = '1950a258-227b-4e31-a9cf-717495945fc2',
        [Parameter()][switch]$ForceInteractive,
        [Parameter()][string]$PreferredUsername,
        [Parameter()][switch]$ListAccountsOnly
    )

    $module = Get-Module -Name 'Rnwood.Dataverse.Data.PowerShell' | Select-Object -First 1
    if ($module) {
        Initialize-SetupMsalAssembly -ModuleBase $module.ModuleBase
    }
    else {
        Initialize-SetupMsalAssembly
    }

    if (-not ('Microsoft.Identity.Client.PublicClientApplicationBuilder' -as [type])) {
        throw 'Microsoft.Identity.Client could not be loaded for setup authentication.'
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
            if ((Get-SetupAuthenticationMode) -eq 'DeviceCode') {
                Write-Host 'No browser is available on this host; setup will show a device code for sign-in.' -ForegroundColor Yellow
                $authResult = Invoke-SetupDeviceCodeAuthentication -Application $app -Scopes $scopes
            }
            else {
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
                    if (-not (Test-SetupBrowserLaunchFailure -ErrorRecord $_)) {
                        throw
                    }

                    Write-Warning 'The browser could not be opened; retrying with device-code sign-in.'
                    $authResult = Invoke-SetupDeviceCodeAuthentication -Application $app -Scopes $scopes
                }
            }
        }
        catch {
            Write-Error "Failed to acquire a sign-in token: $_"
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

function Get-SetupAccessToken {
    <#
    .SYNOPSIS
        Acquires an access token on the setup runspace for a Dataverse resource.
    .DESCRIPTION
        Normalizes ResourceUrl to its HTTP(S) authority and validates that MSAL
        returned a token. Call before invoking Dataverse cmdlets whose token
        callbacks run on worker tasks, so interactive authentication and assembly
        initialization happen on the setup runspace.
    .PARAMETER ResourceUrl
        Absolute HTTP(S) resource URL for which to acquire the token.
    .PARAMETER TenantId
        Optional tenant passed to the setup MSAL client.
    .OUTPUTS
        System.String
        The access token. Do not write it to logs or the terminal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ResourceUrl,
        [Parameter()][string]$TenantId
    )

    $resourceValue = $ResourceUrl.Trim()
    $resourceUri = $null
    if (
        -not [System.Uri]::TryCreate($resourceValue, [System.UriKind]::Absolute, [ref]$resourceUri) -or
        $resourceUri.Scheme -notin @('http', 'https')
    ) {
        throw 'A valid HTTP(S) resource URL is required for Dataverse authentication.'
    }

    $authenticationParameters = @{
        ResourceUrl = $resourceUri.GetLeftPart([System.UriPartial]::Authority)
    }
    if ($PSBoundParameters.ContainsKey('TenantId')) {
        $authenticationParameters.TenantId = $TenantId
    }

    $authentication = Get-AuthToken @authenticationParameters
    if (-not $authentication -or [string]::IsNullOrWhiteSpace($authentication.AccessToken)) {
        throw 'Authentication did not return an access token for the Dataverse resource.'
    }

    return [string]$authentication.AccessToken
}

function Get-SetupAccessTokenCallback {
    <#
    .SYNOPSIS
        Returns a worker-safe Dataverse access-token callback.
    .DESCRIPTION
        Acquires the token on the setup runspace and returns a closure that only
        returns that token. The callback validates requested resources but does
        not perform MSAL calls or refresh the token on the cmdlet's worker task.
    .PARAMETER ResourceUrl
        Absolute HTTP(S) URL for the Dataverse resource.
    .PARAMETER TenantId
        Optional tenant passed to the setup MSAL client.
    .OUTPUTS
        System.Management.Automation.ScriptBlock
        A callback returning the captured access token for the requested resource.
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param(
        [Parameter(Mandatory)][string]$ResourceUrl,
        [Parameter()][string]$TenantId
    )

    $authenticationParameters = @{ ResourceUrl = $ResourceUrl }
    if ($PSBoundParameters.ContainsKey('TenantId')) {
        $authenticationParameters.TenantId = $TenantId
    }

    $accessToken = Get-SetupAccessToken @authenticationParameters
    $expectedResourceAuthority = ([System.Uri]$ResourceUrl.Trim()).GetLeftPart([System.UriPartial]::Authority)
    $accessTokenProvider = {
        param($resource)
        if (-not [string]::IsNullOrWhiteSpace([string]$resource)) {
            $resourceUri = $null
            if (
                -not [System.Uri]::TryCreate([string]$resource, [System.UriKind]::Absolute, [ref]$resourceUri) -or
                $resourceUri.Scheme -notin @('http', 'https')
            ) {
                throw 'Dataverse authentication requested an invalid resource URL.'
            }

            $resourceAuthority = $resourceUri.GetLeftPart([System.UriPartial]::Authority)
            if ($resourceAuthority -ine $expectedResourceAuthority) {
                throw 'Dataverse authentication callback requested an unexpected resource.'
            }
        }

        return $accessToken
    }.GetNewClosure()

    return $accessTokenProvider
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

}

$setupAzDoBootstrapPath = if ($script:SetupRepositoryRoot) { Join-Path $script:SetupRepositoryRoot 'setup/setup-azdo-bootstrap.ps1' } else { $null }
if ($setupAzDoBootstrapPath -and (Test-Path -LiteralPath $setupAzDoBootstrapPath)) {
    . $setupAzDoBootstrapPath
}
else {
    function Install-PortableGit {
    <#
    .SYNOPSIS
    Returns the Git bin directory, using system Git off Windows or installing portable Git on Windows.
    .NOTES
    Non-Windows systems require Git on PATH. Windows reuses an existing bin\git.exe
    without version verification; download, extraction and missing-executable failures
    terminate setup. PATH is updated by the caller.
    .PARAMETER Platform
    Defaults to the current platform; overridable for testing the Windows installer path.
    #>
    param(
        [Parameter(Mandatory)][string]$Destination,
        [System.PlatformID]$Platform = [System.Environment]::OSVersion.Platform
    )

    if ($Platform -ne [System.PlatformID]::Win32NT) {
        $gitCommand = Get-Command git -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $gitCommand) {
            throw 'Git must be installed and available on PATH on non-Windows systems.'
        }

        $gitBinDir = Split-Path -Parent $gitCommand.Source
        Write-Host "Using system Git at: $($gitCommand.Source)"
        return $gitBinDir
    }

    $gitDir = Join-Path $Destination "Git"
    $gitBinDir = Join-Path $gitDir 'bin'
    $gitExe = Join-Path $gitBinDir 'git.exe'

    if (Test-Path -LiteralPath $gitExe -PathType Leaf) {
        Write-Host "Git already available at: $gitExe"
        return $gitBinDir
    }

    Write-Host "Downloading portable Git..." -ForegroundColor Yellow
    $gitUrl = "https://github.com/git-for-windows/git/releases/download/v2.52.0.windows.1/PortableGit-2.52.0-64-bit.7z.exe"
    $gitInstaller = Join-Path $Destination "PortableGit.exe"

    try {
        # PowerShell 5.1 sometimes needs TLS 1.2 explicitly.
        try {
            if ($PSVersionTable.PSVersion.Major -lt 6) {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            }
        }
        catch {
            Write-Verbose 'Could not set the legacy TLS preference; continuing with the current protocol settings.'
        }

        Invoke-WebRequest -Uri $gitUrl -OutFile $gitInstaller -UseBasicParsing

        if (-not (Test-Path $gitInstaller)) {
            throw "Failed to download Git installer"
        }

        Write-Host "Extracting portable Git to $gitDir..." -ForegroundColor Yellow
        New-DirectoryIfMissing -Path $gitDir

        # The .7z.exe is a self-extracting archive
        $extractArgs = @('-o"' + $gitDir + '"', '-y')
        $process = Start-Process -FilePath $gitInstaller -ArgumentList $extractArgs -Wait -NoNewWindow -PassThru

        if ($process.ExitCode -ne 0) {
            throw "Git extraction failed with exit code $($process.ExitCode)"
        }

        # Clean up installer
        Remove-Item $gitInstaller -Force -ErrorAction SilentlyContinue

        if (-not (Test-Path -LiteralPath $gitExe -PathType Leaf)) {
            throw "Git extraction completed but git.exe not found at expected location"
        }

        Write-Host "Git extracted successfully to: $gitDir"
        return $gitBinDir
    }
    catch {
        Write-Host "Failed to install portable Git: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

}

#region Initialization

Write-Section `
    -Message "Initialising setup"

$TempModuleRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ALM4Dataverse\Modules"
New-DirectoryIfMissing -Path $TempModuleRoot

$delim = Get-ModulePathDelimiter
if (-not ($env:PSModulePath -split [Regex]::Escape($delim) | Where-Object { $_ -eq $TempModuleRoot })) {
    $env:PSModulePath = "$TempModuleRoot$delim$env:PSModulePath"
}

Write-Host "Using temp module root: $TempModuleRoot"

# The product version is distinct from the upstream template ref.
$script:ALM4DataverseVersion = 'dev'
if ($script:ALM4DataverseVersion -like '__*') {
    $script:ALM4DataverseVersion = 'Development'
}

# Version numbers are injected during release process
# For development/testing, fall back to reading from config file if placeholders are present
$rnwoodDataverseVersion = '3.4.0'
if ($rnwoodDataverseVersion -like '__*') {
    # Placeholders not replaced - must be running from repository for development
    $configPath = Join-Path $PSScriptRoot 'alm-config-defaults.psd1'
    if (Test-Path $configPath) {
        Write-Host "Development mode: Reading version from $configPath" -ForegroundColor Yellow
        $config = Import-PowerShellDataFile -Path $configPath
        $rnwoodDataverseVersion = $config.scriptDependencies.'Rnwood.Dataverse.Data.PowerShell'
    } else {
        throw "This script appears to be running in development mode but alm-config-defaults.psd1 was not found at $configPath. Please download the released version from https://github.com/ALM4Dataverse/ALM4Dataverse/releases/latest/download/setup-azdo.ps1"
    }
}

# Upstream repository URL is injected during release process
# For development/testing, use local workspace path or fallback to GitHub
$upstreamRepo = 'https://github.com/ALM4Dataverse/ALM4Dataverse.git'
if ($upstreamRepo -like '__*') {
    # Placeholders not replaced - must be running from repository for development
    if ($PSScriptRoot) {
        Write-Host "Development mode: Using local workspace path as upstream repo" -ForegroundColor Yellow
        $upstreamRepo = $PSScriptRoot
    } else {
        Write-Host "Development mode: Using default GitHub URL as upstream repo" -ForegroundColor Yellow
        $upstreamRepo = 'https://github.com/ALM4Dataverse/ALM4Dataverse.git'
    }
}

$requiredModules = @{
    'VSTeam'                           = '7.15.2'
    'Rnwood.Dataverse.Data.PowerShell' = $rnwoodDataverseVersion
}

# Resolve exact module versions before importing; shared helpers handle dependency compatibility.
foreach ($modName in $requiredModules.Keys) {
    $version = $requiredModules[$modName]
    if (-not (Get-ModuleAvailableExact -Name $modName -RequiredVersion $version)) {
        Save-ModuleExact -Name $modName -RequiredVersion $version -Destination $TempModuleRoot
    }
}

foreach ($modName in $requiredModules.Keys) {
    $version = $requiredModules[$modName]
    Import-RequiredModuleVersion -Name $modName -RequiredVersion $version -Destination $TempModuleRoot
}

# Install portable Git on Windows or use system Git on non-Windows systems.
$gitBinDir = Install-PortableGit -Destination $TempModuleRoot

# Add Git to PATH for this session
if (-not ($env:PATH -split [Regex]::Escape($delim) | Where-Object { $_ -eq $gitBinDir })) {
    $env:PATH = "$gitBinDir$delim$env:PATH"
}

# Verify Git is now available
$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) {
    throw "Git was installed but is still not available in PATH"
}

Write-Host "Git is now available: $($git.Source)"
Write-Host "Version: $(git --version)"

if ($resolveDevRefAfterGitIsAvailable) {
    $ALM4DataverseRef = Resolve-DevelopmentDefaultAlm4DataverseRef -PrimaryRepositoryPath $upstreamRepo -FallbackRef $ALM4DataverseRef
    Write-Host "Development mode: Resolved ALM4DataverseRef to '$ALM4DataverseRef'" -ForegroundColor Yellow
}

if ($ApplyConfig) {
    $script:existingSetupMode = $true
}
else {
    $setupModeChoice = Select-FromMenu `
        -Title 'New or existing repository' `
        -ShowProductBrand `
        -Items @('Set up a new application repository', 'Configure an existing repository') `
        -PromptGuidanceLines @('Choose whether this run should create a new application repository or configure one that already exists.') `
        -PromptGuidanceDocRelativePath 'docs/setup/azdo-automated-setup.md' `
        -PromptGuidanceRef $ALM4DataverseRef
    if ($null -eq $setupModeChoice) {
        return
    }

    $script:existingSetupMode = $setupModeChoice -eq 1
}

$setupAzDoSourcePath = if ($script:SetupRepositoryRoot) { Join-Path $script:SetupRepositoryRoot "setup/setup-azdo.ps1" } else { $null }
if ($setupAzDoSourcePath -and (Test-Path -LiteralPath $setupAzDoSourcePath -PathType Leaf)) {
    . $setupAzDoSourcePath
}
else {
    function ConvertTo-AzDoOrganizationName {
    # This is permissive URL/name extraction, not organization existence or URL validation.
    param([Parameter(Mandatory)][string]$InputText)

    $text = $InputText.Trim()

    # Accept:
    # - myorg
    # - https://dev.azure.com/myorg
    # - https://dev.azure.com/myorg/
    # - dev.azure.com/myorg
    if ($text -match 'dev\.azure\.com/([^/]+)') {
        return $Matches[1]
    }

    # Also accept legacy Visual Studio URLs like https://myorg.visualstudio.com
    if ($text -match '^https?://([^\.]+)\.visualstudio\.com/?$') {
        return $Matches[1]
    }

    return $text
}

function New-AzDoProject {
    <#
    .SYNOPSIS
    Prompts for a process template and returns the newly created VSTeam project.
    .NOTES
    Uses the configured VSTeam organization; Organization labels the ShouldProcess
    target only. Cancellation of the process menu retains Agile, or the first template.
    WhatIf returns no project; empty names, unavailable processes and creation failures throw.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter()][string]$Visibility = 'private'
    )

    $ProjectName = $ProjectName.Trim()
    if ([string]::IsNullOrWhiteSpace($ProjectName)) {
        throw "Project name cannot be empty."
    }

    if (-not $PSCmdlet.ShouldProcess("$Organization/$ProjectName", 'Create Azure DevOps project')) { return }

    Write-Section `
        -Message "Creating new Azure DevOps project"
    Write-Host "Project: $ProjectName" -ForegroundColor Cyan

    $processes = @(Invoke-WithSpectreStatus -Status 'Retrieving Azure DevOps process templates...' -ScriptBlock {
        Get-VSTeamProcess
    })
    if ($processes.Count -eq 0) {
        throw "Unable to list Azure DevOps processes to create a project. Verify permissions in the organization."
    }

    # Prefer Agile if present, otherwise first.
    $defaultProcess = $processes | Where-Object { $_.name -eq 'Agile' } | Select-Object -First 1
    if (-not $defaultProcess) {
        $defaultProcess = $processes | Select-Object -First 1
    }

    $processNames = @($processes | Sort-Object -Property name | ForEach-Object { $_.name })
    $selectedProcessName = $defaultProcess.name

    # Let user choose the process template.
    $procIndex = Select-FromMenu -Title "Select a process (template) for the new project" -Items $processNames -PromptGuidanceLines @(
        'Choose the process template for work items, boards, and backlog behavior in the new project.',
        'Pick the template that best matches your team''s delivery process.'
    ) -PromptGuidanceDocRelativePath 'docs/setup/azdo-automated-setup.md' -PromptGuidanceRef $ALM4DataverseRef
    if ($null -ne $procIndex) {
        $selectedProcessName = $processNames[$procIndex]
    }

    $selectedProcess = $processes | Where-Object { $_.name -eq $selectedProcessName } | Select-Object -First 1
    if (-not $selectedProcess -or -not $selectedProcess.id) {
        throw "Unable to resolve selected process '$selectedProcessName'."
    }

    # Use VSTeam command to create project - it handles async operation polling automatically
    try {
        # Note: Add-VSTeamProject uses -ProjectName instead of -Name and doesn't have VersionControlSource
        $addParams = @{
            ProjectName     = $ProjectName
            ProcessTemplate = $selectedProcessName
            Visibility      = $Visibility
        }

        $created = Invoke-WithSpectreStatus -Status "Creating project '$ProjectName' using process template '$selectedProcessName'..." -ScriptBlock {
            Add-VSTeamProject @addParams
        }

        if ($created -and $created.name) {
            Write-Host "Project '$ProjectName' created successfully."
            return $created
        }
        else {
            throw "Project creation returned no result."
        }
    }
    catch {
        Write-Host "Failed to create project '$ProjectName': $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

function Initialize-AzDoOrganization {
    <#
    .SYNOPSIS
        Selects or resolves the Azure DevOps organization and connects VSTeam.
    .DESCRIPTION
        OrganizationName skips the discovery menu and connects VSTeam directly.
    #>
    [CmdletBinding()]
    param([Parameter()][string]$OrganizationName)

    Write-Section -Message "Select Azure DevOps organization"

    if (-not [string]::IsNullOrWhiteSpace($OrganizationName)) {
        $orgName = $OrganizationName
        $orgUri = "https://dev.azure.com/$orgName"
        $secureToken = ConvertTo-SecureString -String $adoAccessToken.Token -AsPlainText -Force
        Set-VSTeamAccount -Account $orgName -SecurePersonalAccessToken $secureToken -UseBearerToken -Force
        Write-Host "VSTeam configured for organization '$orgName' using a bearer token."
        return [pscustomobject]@{
            Name = $orgName
            Uri  = $orgUri
        }
    }

# Use direct REST API to get organizations (VSTeam requires an org to connect to first)
$orgData = Invoke-WithErrorHandling -OperationName "Discovering Azure DevOps Organizations" -ScriptBlock {
    $headers = @{
        Authorization = "Bearer $($adoAccessToken.Token)"
    }

    # Get current user profile to obtain member ID
    $profileUrl = "https://app.vssps.visualstudio.com/_apis/profile/profiles/me?api-version=6.0"
    $profileResponse = Invoke-RestMethod -Uri $profileUrl -Method Get -Headers $headers

    $memberId = $profileResponse.publicAlias
    if (-not $memberId) {
        $memberId = $profileResponse.id
    }
    if (-not $memberId) {
        throw "Unable to determine memberId from profile response."
    }

    $accountsUrl = "https://app.vssps.visualstudio.com/_apis/accounts?memberId=$memberId&api-version=6.0"
    $accountsResponse = Invoke-RestMethod -Uri $accountsUrl -Method Get -Headers $headers

    $orgs = @($accountsResponse.value)
    Write-SetupDebug -Message "Azure DevOps accounts API returned $($orgs.Count) rows for memberId '$memberId'."
    if (Test-SetupDebugEnabled) {
        for ($orgIndex = 0; $orgIndex -lt $orgs.Count; $orgIndex++) {
            $org = $orgs[$orgIndex]
            $debugName = [string]$org.accountName
            $debugId = [string]$org.accountId
            $debugUri = [string]$org.accountUri
            Write-SetupDebug -Message "  raw[$orgIndex] name='$debugName' id='$debugId' uri='$debugUri'"
        }
    }

    if ($orgs.Count -eq 0) {
        throw "No Azure DevOps organizations were returned for this user."
    }

    # The accounts API can occasionally return duplicate rows for the same organization.
    # De-duplicate primarily by accountId (stable), then by accountUri/accountName fallback.
    $orgByKey = @{}
    foreach ($org in $orgs) {
        if (-not $org) {
            continue
        }

        $orgKey = $null
        if ($org.PSObject.Properties.Name -contains 'accountId' -and -not [string]::IsNullOrWhiteSpace([string]$org.accountId)) {
            $orgKey = "id:$([string]$org.accountId)".ToLowerInvariant()
        }
        elseif ($org.PSObject.Properties.Name -contains 'accountUri' -and -not [string]::IsNullOrWhiteSpace([string]$org.accountUri)) {
            $orgKey = "uri:$([string]$org.accountUri)".ToLowerInvariant()
        }
        else {
            $orgKey = "name:$([string]$org.accountName)".ToLowerInvariant()
        }

        if (-not $orgByKey.ContainsKey($orgKey)) {
            $orgByKey[$orgKey] = $org
        }
    }

    $orgsSorted = @($orgByKey.Values | Sort-Object -Property accountName, accountUri)
    Write-SetupDebug -Message "Azure DevOps organizations after de-duplication: $($orgsSorted.Count) rows."
    if (Test-SetupDebugEnabled) {
        for ($orgIndex = 0; $orgIndex -lt $orgsSorted.Count; $orgIndex++) {
            $org = $orgsSorted[$orgIndex]
            Write-SetupDebug -Message "  dedup[$orgIndex] name='$([string]$org.accountName)' id='$([string]$org.accountId)' uri='$([string]$org.accountUri)'"
        }
    }

    # Keep labels concise when unique; add URI only when names collide.
    $nameCounts = @{}
    foreach ($org in $orgsSorted) {
        $nameKey = [string]$org.accountName
        if ($nameCounts.ContainsKey($nameKey)) {
            $nameCounts[$nameKey] = [int]$nameCounts[$nameKey] + 1
        }
        else {
            $nameCounts[$nameKey] = 1
        }
    }

    $orgLabels = @(
        $orgsSorted | ForEach-Object {
            $name = [string]$_.accountName
            if ($nameCounts[$name] -gt 1 -and -not [string]::IsNullOrWhiteSpace([string]$_.accountUri)) {
                "$name ($([string]$_.accountUri))"
            }
            else {
                $name
            }
        }
    )
    $orgNames = @($orgsSorted | ForEach-Object { [string]$_.accountName })

    return @{
        Orgs      = $orgsSorted
        OrgNames  = $orgNames
        OrgLabels = $orgLabels
    }
}

$orgsSorted = $orgData.Orgs
$orgNames = $orgData.OrgNames
$orgLabels = $orgData.OrgLabels

Write-SetupDebug -Message "Organization menu labels: $($orgLabels -join ' | ')"

$orgIndex = 0
$orgIndex = Select-FromMenu `
    -Title "Select an Azure DevOps organization" `
    -Items $orgLabels `
    -PromptGuidanceLines @(
        'Choose the Azure DevOps organization that owns the project, repositories, and pipelines for this setup.',
        'Select the organization where you have enough permissions to create and configure project resources.'
    ) `
    -PromptGuidanceDocRelativePath 'docs/setup/azdo-organisation-requirements.md' `
    -PromptGuidanceRef $ALM4DataverseRef
if ($null -eq $orgIndex) {
    Write-Host "No organization selected." -ForegroundColor Yellow
    return
}

$orgName = $orgNames[$orgIndex]
$orgUri = $orgsSorted[$orgIndex].accountUri
Write-Host "Selected organization: $orgName"
if ($orgUri) {
    Write-Host "Organization URI: $orgUri" -ForegroundColor DarkGray
}

# VSTeam expects -Account to be the org name (not the full URL).
Set-VSTeamAccount -Account $orgName -SecurePersonalAccessToken $secureToken -UseBearerToken -Force
Write-Host "VSTeam configured for organization '$orgName' using a bearer token."
return [pscustomobject]@{
    Name = $orgName
    Uri = $orgUri
}
}
function Test-AzDoGitRepositoryCommit {
    # False means no commit was observed, including lookup errors; it is not proof of emptiness.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$RepositoryId
    )

    # Use VSTeam command to get commits - if repo is empty, no commits are returned
    try {
        $commits = @(Get-VSTeamGitCommit -ProjectName $Project -RepositoryId $RepositoryId -Top 1 -ErrorAction SilentlyContinue)
        return ($commits.Count -gt 0)
    }
    catch {
        # If we can't get commits, assume empty repo
        return $false
    }
}

function Start-AzDoGitRepositoryImport {
    <#
    .SYNOPSIS
    Starts an Azure DevOps server-side Git import and returns its request response.
    .NOTES
    Uses the current VSTeam context. Completion is separate: pass the response to
    Wait-AzDoGitRepositoryImport. A declined ShouldProcess returns no response.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$RepositoryId,
        [Parameter(Mandatory)][string]$SourceGitUrl
    )

    # Use Invoke-VSTeamRequest since VSTeam doesn't support repository import directly
    if (-not $PSCmdlet.ShouldProcess($RepositoryId, 'Start repository import')) { return }

    $resource = "git/repositories/$RepositoryId/importRequests"
    $body = @{
        parameters = @{
            gitSource = @{
                url = $SourceGitUrl
            }
        }
    }
    return Invoke-VSTeamRequest -Method POST -Resource $resource -Body ($body | ConvertTo-Json -Depth 10) -ContentType 'application/json' -Version '7.1-preview.1'
}

function Wait-AzDoGitRepositoryImport {
    <#
    .SYNOPSIS
    Polls an import response's request ID until success, failure or the timeout in seconds.
    .OUTPUTS
    System.Object. The successful status response.
    .NOTES
    Accepts alternate request-ID and status field names. Polls every five seconds;
    missing IDs, terminal failure states and elapsed deadlines throw.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryId,
        [Parameter(Mandatory)][object]$ImportResponse,
        [Parameter()][int]$TimeoutSeconds = 600
    )

    $importId = $null
    foreach ($prop in @('importRequestId', 'id', 'ImportRequestId')) {
        if ($ImportResponse.PSObject.Properties.Name -contains $prop) {
            $importId = $ImportResponse.$prop
            if ($importId) { break }
        }
    }

    if (-not $importId) {
        throw "Unable to determine import request ID from response."
    }

    # Use Invoke-VSTeamRequest since VSTeam doesn't support repository import status directly
    $resource = "git/repositories/$RepositoryId/importRequests/$importId"
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5

        $status = Invoke-VSTeamRequest -Method GET -Resource $resource -Version '7.1-preview.1'

        if (-not $status) { continue }

        $state = $null
        foreach ($prop in @('status', 'state')) {
            if ($status.PSObject.Properties.Name -contains $prop) {
                $state = $status.$prop
                if ($state) { break }
            }
        }

        if ($state) {
            Write-Host "Import status: $state" -ForegroundColor DarkGray
        }

        if ($state -in @('completed', 'succeeded', 'success')) {
            return $status
        }
        if ($state -in @('failed', 'rejected', 'canceled', 'cancelled')) {
            $details = $status | ConvertTo-Json -Depth 20
            throw "Repository import did not succeed. Status: $state. Details: $details"
        }
    }

    throw "Timed out waiting for repository import to complete after $TimeoutSeconds seconds."
}

function Get-AzDoSharedRepositorySyncState {
    <#
    .SYNOPSIS
    Clones into WorkRoot and compares HEAD with an upstream ref without changing the remote.
    .OUTPUTS
    System.Management.Automation.PSCustomObject. UpstreamRef, LocalHash, UpstreamHash,
    CanFastForward and IsAhead; both flags are false for equal or divergent histories.
    .NOTES
    WorkRoot must be suitable for git clone. Branch refs resolve to upstream tracking
    refs, tags to the advertised SHA. The caller owns clone cleanup; preference state is restored.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRemoteUrl,
        [Parameter(Mandatory)][string]$WorkRoot,
        [Parameter(Mandatory)][string]$UpstreamGitSource,
        [Parameter(Mandatory)][string]$Reference,
        [Parameter(Mandatory)][string]$AccessToken
    )

    # Git can write progress to stderr on success. Use exit codes for native failures
    # and restore the caller's terminating-error policy after the comparison.
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'

        & git -c "http.extraheader=AUTHORIZATION: bearer $AccessToken" clone $RepositoryRemoteUrl $WorkRoot | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Git clone failed with exit code $LASTEXITCODE"
        }

        & git -C $WorkRoot remote add upstream $UpstreamGitSource | Out-Null
        & git -C $WorkRoot fetch upstream | Out-Null

        & git -C $WorkRoot ls-remote --exit-code upstream $Reference | Out-Null
        if ($LASTEXITCODE -eq 2) {
            throw "Could not resolve reference '$Reference' from upstream repository."
        }
        if ($LASTEXITCODE -ne 0) {
            throw "Git ls-remote failed with exit code $LASTEXITCODE"
        }

        $lsRemoteOutput = (& git -C $WorkRoot ls-remote upstream $Reference | Select-Object -First 1)
        if ($lsRemoteOutput -match '^([a-f0-9]+)\s+(.+)$') {
            $commitSha = $Matches[1]
            $fullRef = $Matches[2]
            if ($fullRef -match '^refs/heads/(.+)$') {
                $targetRef = "upstream/$($Matches[1])"
            }
            elseif ($fullRef -match '^refs/tags/') {
                $targetRef = $commitSha
            }
            else {
                $targetRef = $Reference
            }
        }
        else {
            $targetRef = $Reference
        }

        $localHash = (& git -C $WorkRoot rev-parse HEAD).Trim()
        $upstreamHash = (& git -C $WorkRoot rev-parse $targetRef).Trim()

        $canFastForward = $false
        $isAhead = $false
        if ($localHash -ne $upstreamHash) {
            & git -C $WorkRoot merge-base --is-ancestor HEAD $targetRef
            $canFastForward = ($LASTEXITCODE -eq 0)

            if (-not $canFastForward) {
                & git -C $WorkRoot merge-base --is-ancestor $targetRef HEAD
                $isAhead = ($LASTEXITCODE -eq 0)
            }
        }

        return [pscustomobject]@{
            UpstreamRef    = $targetRef
            LocalHash      = $localHash
            UpstreamHash   = $upstreamHash
            CanFastForward = $canFastForward
            IsAhead        = $isAhead
        }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Initialize-AzDoProjectAndRepository {
    <#
    .SYNOPSIS
    Selects project/repositories, prepares the main clone and optionally reconciles shared template history.
    .OUTPUTS
    System.Management.Automation.PSCustomObject. SelectedProject, MainRepo, MainRepoWorkingTree,
    MainRepoWorkingRoot, AzDevOpsAccessToken, SharedRepo, SharedRepoName and
    SharedRepositorySelectionError; null on project cancellation.
    .PARAMETER SharedRepositoryOnly
    Reuses supplied project and application-repository context for shared-repository operations;
    cannot be combined with ApplyConfig.
    .PARAMETER SkipSharedRepositoryVersionUpdate
    Selects the shared repository without checking or changing its version.
    .PARAMETER DeferSharedRepositorySelection
    Checks the configured shared repository without prompting and returns an unavailable
    reason for the guided menu when it cannot be selected. Requires ExistingSetupMode and
    SkipSharedRepositoryVersionUpdate.
    .PARAMETER UsePreferredSharedRepository
    Uses the preferred shared repository without prompting; requires SharedRepositoryOnly and
    fails if that repository is no longer accessible.
    .NOTES
    Depends on authenticated script context. Sets branch, DEV-name and extension-mode
    script state, may install extensions and push shared-repository history. Rebase/reset
    require an explicit menu choice; main-clone cleanup belongs to the outer setup flow.
    ExistingSetupMode restricts project and application-repository selection to existing
    resources. SharedRepositoryOnly reuses the selected project and application repository.
    The shared-repository selection and version-update operations can be run separately.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][switch]$ApplyConfig,
        [Parameter()][switch]$ExistingSetupMode,
        [Parameter()][switch]$SharedRepositoryOnly,
        [Parameter()][switch]$SkipSharedRepositoryVersionUpdate,
        [Parameter()][switch]$DeferSharedRepositorySelection,
        [Parameter()][switch]$UsePreferredSharedRepository,
        [Parameter()][object]$SelectedProjectForSharedRepository,
        [Parameter()][object]$MainRepoForSharedRepository,
        [Parameter()][object]$MainRepoWorkingTreeForSharedRepository,
        [Parameter()][string]$MainRepoWorkingRootForSharedRepository,
        [Parameter()][string]$AccessTokenForSharedRepository,
        [Parameter()][string]$PreferredSharedRepositoryName,
        [Parameter()][string]$PreferredSharedRepositoryRef,
        [Parameter()][string]$ProjectName,
        [Parameter()][string]$RepositoryName
    )

    if (
        $DeferSharedRepositorySelection -and
        (-not $ExistingSetupMode -or $ApplyConfig -or $SharedRepositoryOnly -or -not $SkipSharedRepositoryVersionUpdate)
    ) {
        throw 'DeferSharedRepositorySelection requires existing-repository setup with shared-repository version updates skipped.'
    }

    if ($SharedRepositoryOnly) {
        if ($ApplyConfig) {
            throw 'SharedRepositoryOnly cannot be used with ApplyConfig.'
        }
        if ($UsePreferredSharedRepository -and [string]::IsNullOrWhiteSpace($PreferredSharedRepositoryName)) {
            throw 'UsePreferredSharedRepository requires PreferredSharedRepositoryName.'
        }
        if (
            $null -eq $SelectedProjectForSharedRepository -or
            $null -eq $MainRepoForSharedRepository -or
            $null -eq $MainRepoWorkingTreeForSharedRepository -or
            [string]::IsNullOrWhiteSpace($MainRepoWorkingRootForSharedRepository) -or
            [string]::IsNullOrWhiteSpace($AccessTokenForSharedRepository)
        ) {
            throw 'SharedRepositoryOnly requires the selected project, application repository, working tree, and access token.'
        }

        $selectedProject = $SelectedProjectForSharedRepository
        $mainRepo = $MainRepoForSharedRepository
        $mainRepoWorkingTree = $MainRepoWorkingTreeForSharedRepository
        $mainRepoWorkingRoot = $MainRepoWorkingRootForSharedRepository
        $azDevOpsAccessToken = $AccessTokenForSharedRepository
        $applyConfiguration = $null
    }
    else {
    if ($UsePreferredSharedRepository) {
        throw 'UsePreferredSharedRepository can only be used with SharedRepositoryOnly.'
    }

    Write-Section `
        -Message "Select target Azure DevOps Project"

    $azDevOpsAccessToken = $adoAccessToken.Token

    $projects = @(Invoke-WithSpectreStatus -Status 'Retrieving Azure DevOps projects...' -ScriptBlock {
        Get-VSTeamProject
    })
    $projectNames = @()
    if ($projects) {
        $projectNames = @($projects | ForEach-Object { $_.Name })
    }

    $existingResourcesOnly = $ApplyConfig -or $ExistingSetupMode
    if ($existingResourcesOnly -and $projectNames.Count -eq 0) {
        if ($ApplyConfig) {
            throw 'ApplyConfig requires an existing Azure DevOps project containing the application repository.'
        }
        throw 'Existing-repository setup requires an existing Azure DevOps project containing the application repository.'
    }

    $menuItems = if ($existingResourcesOnly) { $projectNames } else { $projectNames + @('Create a new project') }
    $index = $null
    if (-not [string]::IsNullOrWhiteSpace($ProjectName)) {
        # Headless project selection: the caller supplies the project so the guided
        # setup menu is skipped.
        $matchingProjectIndexes = @(0..($projectNames.Count - 1) | Where-Object { $projectNames[$_] -ieq $ProjectName })
        if ($matchingProjectIndexes.Count -eq 0) {
            throw "Project '$ProjectName' is not accessible with the authenticated account or does not exist."
        }
        $index = $matchingProjectIndexes | Select-Object -First 1
    }
    else {
        $index = Select-FromMenu `
            -Title "Select the target Azure DevOps project" `
            -Items $menuItems `
            -PromptGuidanceLines @(
                'Choose the long-lived project that will host repositories, pipelines, service connections, and approvals.',
                'Avoid phase-specific project names so the setup can grow with the team.',
                'Use Create a new project only when no existing project should own this ALM setup.'
            ) `
            -PromptGuidanceDocRelativePath 'docs/setup/azdo-automated-setup.md' `
            -PromptGuidanceRef $ALM4DataverseRef
    }

    if ($null -eq $index) {
        Write-Host "No project selected." -ForegroundColor Yellow
        return $null
    }

    function Get-AzDoSharedRepositoryRefFromWorkingTree {
        <#
        .SYNOPSIS
        Reads the shared repository ref from setup config.
        .DESCRIPTION
        Missing configuration uses the shared repository's conventional main branch.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Branch', Justification = 'Retained for existing callers; shared repository configuration is not branch-specific.')]
        [CmdletBinding()]
        [OutputType([string])]
        param(
            [Parameter(Mandatory)][string]$RepoRoot,
            [Parameter(Mandatory)][string]$Branch
        )

        $configPath = Join-Path $RepoRoot 'alm-config.psd1'
        if (Test-Path -LiteralPath $configPath -PathType Leaf) {
            $config = ConvertFrom-AlmConfigContentForSetup -ConfigContent ([System.IO.File]::ReadAllText($configPath))
            if (
                [string](Get-OptionalObjectPropertyValue -InputObject $config -PropertyName 'provider') -ieq 'azDO' -and
                $config.Contains('ref') -and
                -not [string]::IsNullOrWhiteSpace([string]$config.ref)
            ) {
                return [string]$config.ref
            }
        }

        return 'main'
    }

    $createProjectSelected = -not $ApplyConfig -and -not $ExistingSetupMode -and $index -eq ($menuItems.Count - 1)
    if ($createProjectSelected) {
        $name = Read-TextWithDefault -Prompt 'Enter the name for the new Azure DevOps project'

        $created = New-AzDoProject -Organization $orgName -ProjectName $name -Visibility private

        $projects = @(Invoke-WithSpectreStatus -Status 'Refreshing Azure DevOps projects...' -ScriptBlock {
            Get-VSTeamProject
        })
        $selectedProject = $null

        if ($projects) {
            $selectedProject = $projects | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        }
        if (-not $selectedProject -and $created -and $created.name) {
            $selectedProject = [pscustomobject]@{ Name = $created.name; Id = $created.id }
        }
        if (-not $selectedProject) {
            throw "Project creation completed, but the project could not be resolved for selection."
        }

        Write-Host "Created and selected project: $($selectedProject.Name)"
    }
    else {
        $selectedProject = $projects[$index]
        Write-Host "Selected project: $($selectedProject.Name)"
    }

    if (-not $ApplyConfig -and (Get-Command -Name Set-VSTeamDefaultProject -ErrorAction SilentlyContinue)) {
        Set-VSTeamDefaultProject -Project $selectedProject.Name | Out-Null
        Write-Host "Default VSTeam project set to '$($selectedProject.Name)'."
    }

    $mainRepo = Select-AzDoMainRepository `
        -ProjectName $selectedProject.Name `
        -ExistingOnly:$existingResourcesOnly `
        -ApplyConfig:$ApplyConfig `
        -RepositoryName $RepositoryName

    $script:mainRepoBranch = 'main'
    if ($mainRepo.defaultBranch) {
        $script:mainRepoBranch = ConvertFrom-GitRefToBranchName -Ref $mainRepo.defaultBranch
    }

    $script:devEnvironmentShortName = "Dev-$script:mainRepoBranch"

    $mainRepoWorkingTree = New-AzDoRepoWorkingTree -TargetRepo $mainRepo -AccessToken $azDevOpsAccessToken -PreferredBranch 'main'
    $mainRepoWorkingRoot = $mainRepoWorkingTree.Path

    $applyConfiguration = $null
    if ($ApplyConfig) {
        $applyConfiguration = Get-AlmConfigForSetup -ConfigPath (Join-Path $mainRepoWorkingRoot 'alm-config.psd1')
        [void](Assert-AlmSetupConfigurationForApply -Configuration $applyConfiguration -Provider azDO)
    }

    if ($ApplyConfig) {
        $script:useAlm4DataverseExtension = if ($applyConfiguration.Contains('azDOUseAlm4DataverseExtension')) {
            if ($applyConfiguration.azDOUseAlm4DataverseExtension -isnot [bool]) {
                throw 'azDOUseAlm4DataverseExtension in alm-config.psd1 must be a Boolean.'
            }
            [bool]$applyConfiguration.azDOUseAlm4DataverseExtension
        }
        else {
            $true
        }
    }
    else {
        Write-Section `
            -Message "Ensuring Needed Extensions are Enabled"

        $existingExtensionMode = Get-AzDoExtensionModeFromWorkingTree -RepoRoot $mainRepoWorkingRoot -Branch $script:mainRepoBranch
        if ($existingExtensionMode.IsConfigured -and -not $existingExtensionMode.HasConflict) {
            $script:useAlm4DataverseExtension = $existingExtensionMode.UseAlm4DataverseExtension
            Write-Host "Detected existing ALM4Dataverse extension mode in alm-config.psd1: $($script:useAlm4DataverseExtension)" -ForegroundColor Cyan
        }
        else {
            $script:useAlm4DataverseExtension = Read-YesNo `
                -Prompt "Use ALM4Dataverse AzDO extension? (required for Workload Identity Federation)" `
                -PromptGuidanceLines @(
                    'The extension enables Workload Identity Federation and the ALM4Dataverse Set Connection Variables task.',
                    'Disable it only to use the Power Platform Build Tools secret-based fallback path.'
                ) `
                -PromptGuidanceDocRelativePath 'docs/config/azdo-environment-service-connection.md' `
                -PromptGuidanceRef $ALM4DataverseRef
        }
    }

    if (-not $script:useAlm4DataverseExtension) {
        Write-Host "ALM4Dataverse extension mode disabled. Setup will use the PPBT Set Connection Variables task for service-connection-based client secret auth." -ForegroundColor Yellow
    }

    if (-not $ApplyConfig) {
        $requiredExtensions = @(
            "microsoft-IsvExpTools.PowerPlatform-BuildTools"
        )

        if ($script:useAlm4DataverseExtension) {
            $requiredExtensions += "ALM4Dataverse.alm4dataverse-azdo-extensions"
        }

        foreach ($requiredExtension in $requiredExtensions) {
            $parts = $requiredExtension -split '\.'
            $publisherId = $parts[0]
            $extensionId = $parts[1..($parts.Length - 1)] -join '.'

            Invoke-WithErrorHandling -OperationName "Installing extension '$requiredExtension'" -ScriptBlock {
                $installedExtensions = Get-VSTeamExtension
                $installed = $installedExtensions | Where-Object { $_.publisherId -eq $publisherId -and $_.extensionId -eq $extensionId }

                if ($installed) {
                    Write-Host "Extension '$requiredExtension' is already installed (Version: $($installed.version))."
                }
                else {
                    if (-not (Read-YesNo -Prompt "Extension '$requiredExtension' not found. Install it?")) {
                        throw "Extension '$requiredExtension' is required. Setup cannot continue without it."
                    }
                    Write-Host "Extension '$requiredExtension' not found. Installing..." -ForegroundColor Yellow
                    Write-Host "This may require organization administrative permissions." -ForegroundColor Yellow

                    Add-VSTeamExtension -PublisherId $publisherId -ExtensionId $extensionId

                    $installedExtensions = Get-VSTeamExtension
                    $installed = $installedExtensions | Where-Object { $_.publisherId -eq $publisherId -and $_.extensionId -eq $extensionId }

                    if ($installed) {
                        Write-Host "Extension '$requiredExtension' installed successfully (Version: $($installed.version))."
                    }
                    else {
                        Write-Host "Please install the extension manually from:" -ForegroundColor Yellow
                        Write-Host "https://marketplace.visualstudio.com/acquisition?itemName=$requiredExtension" -ForegroundColor Yellow
                        throw "Failed to verify extension '$requiredExtension' installation after install command completed."
                    }
                }
            } | Out-Null
        }
    }

    }

    $sharedRepositorySelectionError = ''
    $existingSharedRepoName = if ($SharedRepositoryOnly) {
        $PreferredSharedRepositoryName
    }
    elseif ($ApplyConfig) {
        [string]$applyConfiguration.repository
    }
    else {
        Get-AzDoSharedRepositoryNameFromWorkingTree -RepoRoot $mainRepoWorkingRoot -Branch $script:mainRepoBranch
    }
    if (-not [string]::IsNullOrWhiteSpace($existingSharedRepoName)) {
        Write-Host "Existing shared repository detected from alm-config.psd1: $existingSharedRepoName" -ForegroundColor DarkGray
    }

    Write-Section `
        -Message "Selecting shared Git repository"

    if ($ApplyConfig) {
        $repo = @(Get-VSTeamGitRepository -ProjectName $selectedProject.Name) |
            Where-Object { $_.Name -ieq $existingSharedRepoName } |
            Select-Object -First 1
        if (-not $repo -or -not $repo.Id) {
            throw "The shared repository '$existingSharedRepoName' configured in alm-config.psd1 was not found in project '$($selectedProject.Name)'."
        }
    }
    elseif ($DeferSharedRepositorySelection) {
        if ([string]::IsNullOrWhiteSpace($existingSharedRepoName)) {
            $repo = $null
            $sharedRepositorySelectionError = 'No shared repository is configured in alm-config.psd1.'
        }
        else {
            try {
                $repo = Select-AzDoSharedRepository `
                    -ProjectName $selectedProject.Name `
                    -PreferredRepositoryName $existingSharedRepoName `
                    -ExcludeRepositoryName $mainRepo.Name `
                    -ValidatePreferredOnly
            }
            catch {
                if (Test-IsUserInterruptException -Exception $_.Exception) {
                    throw
                }

                $lookupError = ([string]$_.Exception.Message -replace '\s+', ' ').Trim()
                $sharedRepositorySelectionError = "Could not verify configured shared repository '$existingSharedRepoName' in project '$($selectedProject.Name)': $lookupError"
                $repo = $null
            }
            if (-not $repo) {
                if ([string]::IsNullOrWhiteSpace($sharedRepositorySelectionError)) {
                    $sharedRepositorySelectionError = "Configured shared repository '$existingSharedRepoName' was not found or accessible in project '$($selectedProject.Name)'."
                }
            }
        }
    }
    else {
        $usePreferredIfAvailable = -not $SharedRepositoryOnly -or $UsePreferredSharedRepository
        $repo = Select-AzDoSharedRepository `
            -ProjectName $selectedProject.Name `
            -PreferredRepositoryName $existingSharedRepoName `
            -ExcludeRepositoryName $mainRepo.Name `
            -UsePreferredIfAvailable:$usePreferredIfAvailable `
            -RequirePreferred:$UsePreferredSharedRepository
    }
    $sharedRepoName = [string](Get-OptionalObjectPropertyValue -InputObject $repo -PropertyName 'Name')
    $sharedRepoDefaultBranch = [string](Get-OptionalObjectPropertyValue -InputObject $repo -PropertyName 'defaultBranch')
    $sharedRepositoryRef = if ($ApplyConfig) {
        [string]$applyConfiguration.ref
    }
    elseif ($SharedRepositoryOnly) {
        if (
            $repo.Name -ieq $PreferredSharedRepositoryName -and
            -not [string]::IsNullOrWhiteSpace($PreferredSharedRepositoryRef)
        ) {
            $PreferredSharedRepositoryRef
        }
        elseif (-not [string]::IsNullOrWhiteSpace($sharedRepoDefaultBranch)) {
            ConvertFrom-GitRefToBranchName -Ref $sharedRepoDefaultBranch
        }
        else {
            'main'
        }
    }
    else {
        if (
            -not [string]::IsNullOrWhiteSpace($existingSharedRepoName) -and
            $sharedRepoName -ieq $existingSharedRepoName
        ) {
            Get-AzDoSharedRepositoryRefFromWorkingTree -RepoRoot $mainRepoWorkingRoot -Branch $script:mainRepoBranch
        }
        elseif (-not [string]::IsNullOrWhiteSpace($sharedRepoDefaultBranch)) {
            ConvertFrom-GitRefToBranchName -Ref $sharedRepoDefaultBranch
        }
        else {
            'main'
        }
    }
    if ([string]::IsNullOrWhiteSpace($sharedRepositoryRef)) {
        $sharedRepositoryRef = 'main'
    }

    try {
        [void]$Host.UI.RawUI
    }
    catch {
        throw "This script must be run in an interactive PowerShell session."
    }

    if (-not $ApplyConfig -and -not $SkipSharedRepositoryVersionUpdate) {
        Write-Section `
            -Message "Creating/updating shared repository '$sharedRepoName'"

    $hasCommits = Test-AzDoGitRepositoryCommit  -Project $selectedProject.Name -RepositoryId $repo.Id
    $justInitialized = $false
    if (-not $hasCommits) {
        $justInitialized = Invoke-WithErrorHandling -OperationName "Initializing Shared Repository" -ScriptBlock {
            $previousErrorActionPreference = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
            Write-Host "Repository '$sharedRepoName' has no commits. Seeding it from the upstream repo..." -ForegroundColor Yellow

            $sharedSourceUrl = $upstreamRepo
            $destUrl = $repo.remoteUrl
            if (-not $destUrl) {
                throw "Could not determine remoteUrl for repository '$sharedRepoName'."
            }

            $workRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ALM4Dataverse-Init-" + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $workRoot -Force | Out-Null

            try {
                Push-Location $workRoot

                & git init --initial-branch=main | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Git init failed with exit code $LASTEXITCODE" }

                & git remote add origin $sharedSourceUrl | Out-Null
                & git fetch origin | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Git fetch failed with exit code $LASTEXITCODE" }

                & git ls-remote --exit-code origin $ALM4DataverseRef | Out-Null
                if ($LASTEXITCODE -eq 2) {
                    throw "Could not resolve reference '$ALM4DataverseRef' from upstream repository."
                }
                if ($LASTEXITCODE -ne 0) {
                    throw "Git ls-remote failed with exit code $LASTEXITCODE"
                }

                $lsRemoteOutput = (& git ls-remote origin $ALM4DataverseRef | Select-Object -First 1)
                if ($lsRemoteOutput -match '^([a-f0-9]+)\s+(.+)$') {
                    $commitSha = $Matches[1]
                    $fullRef = $Matches[2]
                    if ($fullRef -match '^refs/heads/(.+)$') {
                        $targetRef = "origin/$($Matches[1])"
                    }
                    elseif ($fullRef -match '^refs/tags/') {
                        $targetRef = $commitSha
                    }
                    else {
                        $targetRef = $ALM4DataverseRef
                    }
                }
                else {
                    $targetRef = $ALM4DataverseRef
                }

                & git checkout -b main $targetRef | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Git checkout failed with exit code $LASTEXITCODE" }

                & git remote set-url origin $destUrl | Out-Null
                & git -c "http.extraheader=AUTHORIZATION: bearer $azDevOpsAccessToken" push -u origin main
                if ($LASTEXITCODE -ne 0) { throw "Git push failed with exit code $LASTEXITCODE" }

                Write-Host "Shared repository initialized successfully."
                return $true
            }
            finally {
                if ((Get-Location).Path -eq $workRoot) { Pop-Location }
                try { Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction Stop } catch { Write-Verbose 'Could not remove the temporary repository; continuing cleanup.' }
            }
            }
            finally {
                $ErrorActionPreference = $previousErrorActionPreference
            }
        } -StatusMessage "Initializing shared repository '$sharedRepoName'..." -CaptureOutputInPanel
    }

    if (-not $justInitialized) {
        $sharedSourceUrl = $upstreamRepo
        $destUrl = $repo.remoteUrl
        if (-not $destUrl) {
            throw "Could not determine remoteUrl for repository '$sharedRepoName'."
        }

        $workRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ALM4Dataverse-Check-" + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $workRoot -Force | Out-Null

        try {
            $sharedRepoSyncState = Invoke-WithSpectreStatus -Status "Checking shared repository '$sharedRepoName' against upstream..." -ScriptBlock {
                Get-AzDoSharedRepositorySyncState -RepositoryRemoteUrl $destUrl -WorkRoot $workRoot -UpstreamGitSource $sharedSourceUrl -Reference $ALM4DataverseRef -AccessToken $azDevOpsAccessToken
            }

            if ($sharedRepoSyncState.LocalHash -eq $sharedRepoSyncState.UpstreamHash) {
                Write-Host "Shared repository is already up to date."
            }
            else {
                if ($sharedRepoSyncState.CanFastForward) {
                    if (Read-YesNo -Prompt "Updates are available from the shared repo (fast-forward). Update '$sharedRepoName'?" ) {
                        Invoke-WithErrorHandling -OperationName "Fast-forwarding shared repository '$sharedRepoName'" -StatusMessage "Fast-forwarding shared repository '$sharedRepoName'..." -CaptureOutputInPanel -ScriptBlock {
                            $previousErrorActionPreference = $ErrorActionPreference
                            try {
                                $ErrorActionPreference = 'Continue'

                                & git -C $workRoot merge --ff-only $sharedRepoSyncState.UpstreamRef
                                if ($LASTEXITCODE -ne 0) { throw 'Git merge failed' }

                                & git -C $workRoot -c "http.extraheader=AUTHORIZATION: bearer $azDevOpsAccessToken" push origin
                                if ($LASTEXITCODE -ne 0) { throw 'Git push failed' }
                            }
                            finally {
                                $ErrorActionPreference = $previousErrorActionPreference
                            }
                        } | Out-Null

                        Write-Host "Repository updated successfully."
                    }
                }
                else {
                    if ($sharedRepoSyncState.IsAhead) {
                        Write-Host "Shared repository is ahead of the shared repo."
                    }
                    else {
                        $divergedMenuItems = @(
                            "Rebase '$sharedRepoName' onto ref '$ALM4DataverseRef'",
                            "Reset '$sharedRepoName' to ref '$ALM4DataverseRef' (force push)",
                            "Leave '$sharedRepoName' unchanged"
                        )
                        $divergedSelection = Select-FromMenu `
                            -Title "The shared repo '$sharedRepoName' has diverged. Choose how to update it." `
                            -Items $divergedMenuItems `
                            -PromptGuidanceLines @(
                                "Choose how to reconcile '$sharedRepoName' with upstream ALM4Dataverse template history.",
                                'Rebase preserves local commits, reset force-aligns to upstream, and leave unchanged keeps current state.'
                            ) `
                            -PromptGuidanceDocRelativePath 'docs/setup/azdo-automated-setup.md' `
                            -PromptGuidanceRef $ALM4DataverseRef

                        switch ($divergedSelection) {
                            0 {
                                Invoke-WithErrorHandling -OperationName "Rebasing shared repository '$sharedRepoName'" -StatusMessage "Rebasing shared repository '$sharedRepoName'..." -CaptureOutputInPanel -ScriptBlock {
                                    $previousErrorActionPreference = $ErrorActionPreference
                                    try {
                                        $ErrorActionPreference = 'Continue'

                                        & git -C $workRoot rebase $sharedRepoSyncState.UpstreamRef
                                        if ($LASTEXITCODE -ne 0) { throw "Git rebase failed - this script can't handle conflicts. You need to rebase your local changes manually." }

                                        & git -C $workRoot -c "http.extraheader=AUTHORIZATION: bearer $azDevOpsAccessToken" push --force-with-lease origin
                                        if ($LASTEXITCODE -ne 0) { throw 'Git push failed' }
                                    }
                                    finally {
                                        $ErrorActionPreference = $previousErrorActionPreference
                                    }
                                } | Out-Null

                                Write-Host "Repository updated successfully."
                            }
                            1 {
                                Invoke-WithErrorHandling -OperationName "Resetting shared repository '$sharedRepoName'" -StatusMessage "Resetting shared repository '$sharedRepoName' to '$ALM4DataverseRef'..." -CaptureOutputInPanel -ScriptBlock {
                                    $previousErrorActionPreference = $ErrorActionPreference
                                    try {
                                        $ErrorActionPreference = 'Continue'

                                        & git -C $workRoot reset --hard $sharedRepoSyncState.UpstreamRef
                                        if ($LASTEXITCODE -ne 0) { throw 'Git reset failed' }

                                        & git -C $workRoot -c "http.extraheader=AUTHORIZATION: bearer $azDevOpsAccessToken" push --force-with-lease origin
                                        if ($LASTEXITCODE -ne 0) { throw 'Git push failed' }
                                    }
                                    finally {
                                        $ErrorActionPreference = $previousErrorActionPreference
                                    }
                                } | Out-Null

                                Write-Host "Repository updated successfully."
                            }
                            default {
                                Write-Host "Leaving shared repository unchanged." -ForegroundColor Yellow
                            }
                        }
                    }
                }
            }
        }
        catch {
            Write-Host "Failed to check or update repository: $($_.Exception.Message)" -ForegroundColor Red
            throw
        }
        finally {
            if ((Get-Location).Path -eq $workRoot) { Pop-Location }
            try { Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction Stop } catch { Write-Verbose 'Could not remove the temporary repository; continuing cleanup.' }
        }
    }
    }

    return [pscustomobject]@{
        SelectedProject      = $selectedProject
        MainRepo             = $mainRepo
        MainRepoWorkingTree  = $mainRepoWorkingTree
        MainRepoWorkingRoot  = $mainRepoWorkingRoot
        MainRepoIsNew        = [bool](Get-OptionalObjectPropertyValue -InputObject $mainRepo -PropertyName 'IsNewRepository')
        AzDevOpsAccessToken  = $azDevOpsAccessToken
        SharedRepo           = $repo
        SharedRepoName       = $sharedRepoName
        SharedRepositoryRef  = $sharedRepositoryRef
        SharedRepositorySelectionError = $sharedRepositorySelectionError
    }
}

function Get-DataverseEnvironmentCatalog {
    <#
    .SYNOPSIS
    Returns discovery environments, reusing the script cache unless ForceRefresh is specified.
    .NOTES
    Acquires a Global Discovery token before calling the discovery cmdlet because
    its token callback runs on a worker task. The callback only returns that token.
    ShowStatus affects presentation only. An empty discovery result throws.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject], [object[]])]
    param(
        [Parameter()][switch]$ForceRefresh,
        [Parameter()][switch]$ShowStatus
    )

    $hasCachedCatalog = ($null -ne (Get-Variable -Name 'dataverseEnvironmentCatalog' -Scope Script -ErrorAction SilentlyContinue)) -and $null -ne $script:dataverseEnvironmentCatalog
    if (-not $ForceRefresh -and $hasCachedCatalog) {
        return @($script:dataverseEnvironmentCatalog)
    }

    $discoveryResource = 'https://globaldisco.crm.dynamics.com'
    if ($ShowStatus) {
        Write-Host 'Authenticating to retrieve Dataverse environments...' -ForegroundColor DarkGray
    }

    $discoveryAccessToken = Get-SetupAccessToken -ResourceUrl $discoveryResource
    $accessTokenProvider = {
        param($resource)
        if (-not [string]::IsNullOrWhiteSpace($resource)) {
            try {
                $resourceAuthority = ([System.Uri]$resource).GetLeftPart([System.UriPartial]::Authority)
            }
            catch {
                throw 'Dataverse environment discovery requested an invalid authentication resource.'
            }

            if ($resourceAuthority -ne $discoveryResource) {
                throw 'Dataverse environment discovery requested a token for an unexpected resource.'
            }
        }

        return $discoveryAccessToken
    }.GetNewClosure()

    $fetchCatalog = {
        @(Get-DataverseEnvironment -AccessToken $accessTokenProvider)
    }

    if ($ShowStatus) {
        $script:dataverseEnvironmentCatalog = @(Invoke-WithSpectreStatus -Status 'Retrieving Dataverse environments...' -ScriptBlock $fetchCatalog)
    }
    else {
        $script:dataverseEnvironmentCatalog = @(& $fetchCatalog)
    }

    if (-not $script:dataverseEnvironmentCatalog -or $script:dataverseEnvironmentCatalog.Count -eq 0) {
        throw 'No Dataverse environments found for this user.'
    }

    return @($script:dataverseEnvironmentCatalog)
}

function Select-DataverseEnvironment {
    <#
    .SYNOPSIS
    Returns a discovered environment selected from a URL-normalized menu, or null on cancellation.
    .NOTES
    ExcludeUrl removes a target before PreferredUrl is promoted to the first choice.
    No remaining environments is an error; PreferredUrl does not bypass discovery.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][string]$Prompt = "Select a Dataverse environment",
        [Parameter()][string]$ExcludeUrl,
        [Parameter()][string]$PreferredUrl,
        [Parameter()][string[]]$PromptGuidanceLines,
        [Parameter()][string]$PromptGuidanceDocRelativePath,
        [Parameter()][string]$PromptGuidanceRef
    )

    $environments = @(Get-DataverseEnvironmentCatalog -ShowStatus)

    $normalizedExcludeUrl = ConvertTo-NormalizedEnvironmentUrl -Url $ExcludeUrl
    $normalizedPreferredUrl = ConvertTo-NormalizedEnvironmentUrl -Url $PreferredUrl

    if ($ExcludeUrl) {
        $environments = @($environments | Where-Object {
            (ConvertTo-NormalizedEnvironmentUrl -Url $_.Endpoints["WebApplication"]) -ne $normalizedExcludeUrl
        })
        if ($environments.Count -eq 0) {
            throw "No environments available after filtering."
        }
    }

    $menuItems = @()
    $menuActions = @()

    if (-not [string]::IsNullOrWhiteSpace($normalizedPreferredUrl)) {
        $preferredEnvironment = $environments | Where-Object {
            (ConvertTo-NormalizedEnvironmentUrl -Url $_.Endpoints['WebApplication']) -eq $normalizedPreferredUrl
        } | Select-Object -First 1

        if ($preferredEnvironment) {
            $menuItems += "Use existing environment: $($preferredEnvironment.FriendlyName) - $($preferredEnvironment.UniqueName) ($($preferredEnvironment.Endpoints['WebApplication']))"
            $menuActions += $preferredEnvironment

            $environments = @($environments | Where-Object {
                (ConvertTo-NormalizedEnvironmentUrl -Url $_.Endpoints['WebApplication']) -ne $normalizedPreferredUrl
            })
        }
    }

    foreach ($env in $environments) {
        $webUrl = $env.Endpoints["WebApplication"]
        $menuItems += "$($env.FriendlyName) - $($env.UniqueName) ($webUrl)"
        $menuActions += $env
    }

    $selectedIndex = Select-FromMenu `
        -Title $Prompt `
        -Items $menuItems `
        -PromptGuidanceLines $PromptGuidanceLines `
        -PromptGuidanceDocRelativePath $PromptGuidanceDocRelativePath `
        -PromptGuidanceRef $PromptGuidanceRef
    if ($null -eq $selectedIndex) {
        return $null
    }

    return $menuActions[$selectedIndex]
}

function Get-OptionalObjectPropertyValue {
    # Missing objects/keys/properties return null under StrictMode; preserve false and zero values.
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

    if ($InputObject.PSObject -and $InputObject.PSObject.Properties.Name -contains $PropertyName) {
        return $InputObject.$PropertyName
    }

    return $null
}

function Select-AzDoMainRepository {
    <#
    .SYNOPSIS
    Selects or creates the application's repository in ProjectName and returns its VSTeam object.
    .NOTES
    SharedRepositoryName optionally excludes the template repository. Cancellation,
    blank new names and unresolved repository IDs throw rather than returning a partial choice.
    ExistingOnly disables repository creation for existing-repository setup and ApplyConfig.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter()][string]$SharedRepositoryName,
        [Parameter()][switch]$ExistingOnly,
        [Parameter()][switch]$ApplyConfig,
        [Parameter()][string]$RepositoryName
    )

    Write-Section `
        -Message "Selecting main Git repository"

    $repos = @(Invoke-WithSpectreStatus -Status "Retrieving repositories in '$ProjectName'..." -ScriptBlock {
        Get-VSTeamGitRepository -ProjectName $ProjectName
    })
    # 'Main' repo is the user's application repo (not the shared ALM4Dataverse repo)
    $reposSorted = @($repos | Sort-Object -Property Name)

    $repoNames = @($reposSorted | ForEach-Object { $_.Name })
    if (-not [string]::IsNullOrWhiteSpace($SharedRepositoryName)) {
        $repoNames = @($repoNames | Where-Object { $_ -ne $SharedRepositoryName })
    }
    if ($ExistingOnly -and $repoNames.Count -eq 0) {
        if ($ApplyConfig) {
            throw 'ApplyConfig requires an existing application repository.'
        }
        throw 'Existing-repository setup requires an existing application repository.'
    }
    $menu = if ($ExistingOnly) { @($repoNames) } else { @('Create a new repository') + @($repoNames) }

    Write-Host "Select the repository where you want to set up pipelines:" -ForegroundColor Green

    $selectedIndex = $null
    if (-not [string]::IsNullOrWhiteSpace($RepositoryName)) {
        # Headless repository selection: the caller supplies the repository so the
        # guided setup menu is skipped.
        $matchingRepoIndexes = @(0..($repoNames.Count - 1) | Where-Object { $repoNames[$_] -ieq $RepositoryName })
        if ($matchingRepoIndexes.Count -eq 0) {
            throw "Repository '$RepositoryName' does not exist in project '$ProjectName' or is not selectable."
        }
        $selectedIndex = $matchingRepoIndexes | Select-Object -First 1
    }
    else {
        $selectedIndex = Select-FromMenu `
            -Title "Select the main repository" `
            -Items $menu `
            -PromptGuidanceLines @(
                'Choose the primary application repository where your solutions and other assets will be stored.'
            ) `
            -PromptGuidanceDocRelativePath 'docs/setup/azdo-automated-setup.md' `
            -PromptGuidanceRef $ALM4DataverseRef
    }
    if ($null -eq $selectedIndex) {
        throw "No main repository selected."
    }

    if (-not $ExistingOnly -and $selectedIndex -eq 0) {
        $newRepoName = Read-TextWithDefault -Prompt 'Enter the name for the new main repository'
        $newRepoName = $newRepoName.Trim()
        if ([string]::IsNullOrWhiteSpace($newRepoName)) {
            throw "Repository name cannot be empty."
        }

        $created = Invoke-WithSpectreStatus -Status "Creating Git repository '$newRepoName' in project '$ProjectName'..." -ScriptBlock {
            Add-VSTeamGitRepository -ProjectName $ProjectName -Name $newRepoName
        }
        if (-not $created -or -not $created.Id) {
            throw "Failed to create Git repository '$newRepoName'."
        }
        $created | Add-Member -NotePropertyName IsNewRepository -NotePropertyValue $true -Force
        Write-Host "Created repository '$newRepoName'."
        return $created
    }

    $selectedName = $menu[$selectedIndex]
    $selected = $reposSorted | Where-Object { $_.Name -eq $selectedName } | Select-Object -First 1
    if (-not $selected -or -not $selected.Id) {
        throw "Failed to resolve selected repository '$selectedName'."
    }

    $selected | Add-Member -NotePropertyName IsNewRepository -NotePropertyValue $false -Force
    Write-Host "Selected main repository: $($selected.Name)"
    return $selected
}

function Get-AzDoSharedRepositoryNameFromWorkingTree {
    # Returns only the shared repository recorded in the Azure DevOps setup config.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Branch', Justification = 'Retained for existing callers; shared repository configuration is not branch-specific.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch
    )

    $configPath = Join-Path $RepoRoot 'alm-config.psd1'
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $config = ConvertFrom-AlmConfigContentForSetup -ConfigContent ([System.IO.File]::ReadAllText($configPath))
        if (
            [string](Get-OptionalObjectPropertyValue -InputObject $config -PropertyName 'provider') -ieq 'azDO' -and
            $config.Contains('repository') -and
            -not [string]::IsNullOrWhiteSpace([string]$config.repository)
        ) {
            return [string]$config.repository
        }
    }

    return $null
}

function Get-AzDoDeploymentEnvironmentNamesFromWorkingTree {
    # Returns only the ordered deployment environment names recorded for this branch.
    [CmdletBinding()]
    [OutputType([string], [object[]])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch
    )

    $configPath = Join-Path $RepoRoot 'alm-config.psd1'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        return @()
    }

    $config = ConvertFrom-AlmConfigContentForSetup -ConfigContent ([System.IO.File]::ReadAllText($configPath))
    if (-not $config.Contains('branches')) {
        return @()
    }
    if ($config.branches -isnot [System.Collections.IDictionary]) {
        throw 'The branches setting in alm-config.psd1 must be a hashtable keyed by branch name.'
    }

    $branchConfiguration = Get-AlmSetupBranchConfiguration -Config $config -BranchName $Branch
    $environmentNames = @()
    if ($branchConfiguration.Contains('deploymentEnvironments') -and $null -ne $branchConfiguration.deploymentEnvironments) {
        if ($branchConfiguration.deploymentEnvironments -isnot [array]) {
            throw "The deploymentEnvironments setting for branch '$Branch' must be an array of environment names."
        }
        $environmentNames = @($branchConfiguration.deploymentEnvironments)
    }

    foreach ($environmentName in $environmentNames) {
        if ($environmentName -isnot [string] -or [string]::IsNullOrWhiteSpace($environmentName)) {
            throw "The deploymentEnvironments setting for branch '$Branch' must contain non-empty environment names."
        }
    }
    return @($environmentNames)
}

function Get-AzDoExtensionModeFromWorkingTree {
    <#
    .SYNOPSIS
    Reads the configured extension mode from alm-config.psd1.
    .OUTPUTS
    System.Management.Automation.PSCustomObject. IsConfigured, HasConflict,
    UseAlm4DataverseExtension and SourceFiles. The mode is null when absent or conflicting.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Branch', Justification = 'Retained for existing callers; extension mode is repository-wide.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch
    )

    $configPath = Join-Path $RepoRoot 'alm-config.psd1'
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $config = ConvertFrom-AlmConfigContentForSetup -ConfigContent ([System.IO.File]::ReadAllText($configPath))
        if (
            [string](Get-OptionalObjectPropertyValue -InputObject $config -PropertyName 'provider') -ieq 'azDO' -and
            $config.Contains('azDOUseAlm4DataverseExtension')
        ) {
            if ($config.azDOUseAlm4DataverseExtension -isnot [bool]) {
                throw 'azDOUseAlm4DataverseExtension in alm-config.psd1 must be a Boolean.'
            }
            return [pscustomobject]@{
                IsConfigured              = $true
                HasConflict               = $false
                UseAlm4DataverseExtension = [bool]$config.azDOUseAlm4DataverseExtension
                SourceFiles               = @($configPath)
            }
        }
    }

    return [pscustomobject]@{
        IsConfigured                = $false
        HasConflict                 = $false
        UseAlm4DataverseExtension   = $null
        SourceFiles                 = @()
    }
}

function Select-AzDoSharedRepository {
    <#
    .SYNOPSIS
    Returns the selected or newly created template repository, excluding the application repository.
    .PARAMETER UsePreferredIfAvailable
    Uses PreferredRepositoryName directly when it is accessible; otherwise opens the selection menu.
    .PARAMETER RequirePreferred
    Fails instead of opening the selection menu when PreferredRepositoryName is inaccessible.
    .PARAMETER ValidatePreferredOnly
    Returns the preferred repository when accessible, or null without opening the selection menu.
    .NOTES
    PreferredRepositoryName is promoted when available and otherwise seeds the new-name
    prompt. UsePreferredIfAvailable avoids the prompt when the preferred repository exists.
    ValidatePreferredOnly checks accessibility without prompting. Creating a repository asks
    for explicit confirmation because the write happens during selection, before preview and
    Apply. Blank names are reprompted during selection; cancellation or a missing created ID
    throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter()][string]$PreferredRepositoryName,
        [Parameter()][string]$ExcludeRepositoryName,
        [Parameter()][switch]$UsePreferredIfAvailable,
        [Parameter()][switch]$RequirePreferred,
        [Parameter()][switch]$ValidatePreferredOnly
    )

    if ($ValidatePreferredOnly -and ($UsePreferredIfAvailable -or $RequirePreferred)) {
        throw 'ValidatePreferredOnly cannot be combined with UsePreferredIfAvailable or RequirePreferred.'
    }
    if ($RequirePreferred -and (-not $UsePreferredIfAvailable -or [string]::IsNullOrWhiteSpace($PreferredRepositoryName))) {
        throw 'RequirePreferred needs UsePreferredIfAvailable and a preferred repository name.'
    }

    Write-Section `
        -Message 'Selecting shared ALM4Dataverse repository'

    $repos = @(Invoke-WithSpectreStatus -Status "Retrieving shared repository options in '$ProjectName'..." -ScriptBlock {
        Get-VSTeamGitRepository -ProjectName $ProjectName
    })
    $reposSorted = @($repos | Sort-Object -Property Name)
    $candidateRepos = @($reposSorted | Where-Object {
        [string]::IsNullOrWhiteSpace($ExcludeRepositoryName) -or $_.Name -ne $ExcludeRepositoryName
    })

    if ($ValidatePreferredOnly) {
        if ([string]::IsNullOrWhiteSpace($PreferredRepositoryName)) {
            return $null
        }

        return $candidateRepos |
            Where-Object { $_.Name -eq $PreferredRepositoryName } |
            Select-Object -First 1
    }

    if ($UsePreferredIfAvailable -and -not [string]::IsNullOrWhiteSpace($PreferredRepositoryName)) {
        $preferredRepo = $candidateRepos | Where-Object { $_.Name -eq $PreferredRepositoryName } | Select-Object -First 1
        if ($preferredRepo) {
            Write-Host "Using existing shared repository: $($preferredRepo.Name)"
            return $preferredRepo
        }

        if ($RequirePreferred) {
            throw "The selected shared repository '$PreferredRepositoryName' is not accessible in project '$ProjectName'. Select a different shared repository."
        }

        Write-Warning "Configured shared repository '$PreferredRepositoryName' is not accessible in project '$ProjectName'. Select an accessible repository instead."
    }

    $menuItems = @()
    $menuActions = @()

    if (-not [string]::IsNullOrWhiteSpace($PreferredRepositoryName)) {
        $preferredRepo = $candidateRepos | Where-Object { $_.Name -eq $PreferredRepositoryName } | Select-Object -First 1
        if ($preferredRepo) {
            $menuItems += "Use current shared repository: $($preferredRepo.Name)"
            $menuActions += @{ Type = 'UseExisting'; Repo = $preferredRepo }
            $candidateRepos = @($candidateRepos | Where-Object { $_.Id -ne $preferredRepo.Id })
        }
    }

    foreach ($candidateRepo in $candidateRepos) {
        $menuItems += "Use existing repository: $($candidateRepo.Name)"
        $menuActions += @{ Type = 'UseExisting'; Repo = $candidateRepo }
    }

    $defaultNewName = if ([string]::IsNullOrWhiteSpace($PreferredRepositoryName)) { 'ALM4Dataverse' } else { $PreferredRepositoryName }
    $menuItems += 'Create a new repository'
    $menuActions += @{ Type = 'CreateNew'; DefaultName = $defaultNewName }

    $selection = Select-FromMenu `
        -Title 'Select the shared repository that will host the ALM4Dataverse templates' `
        -Items $menuItems `
        -PromptGuidanceLines @(
            'Choose the shared repository that will store reusable ALM4Dataverse templates for this project.',
            'Use the existing shared repository when one is already referenced by your main repo to keep template source consistent.'
        ) `
        -PromptGuidanceDocRelativePath 'docs/setup/azdo-automated-setup.md' `
        -PromptGuidanceRef $ALM4DataverseRef
    if ($null -eq $selection) {
        throw 'No shared repository selected.'
    }

    $selectedAction = $menuActions[$selection]
    if ($selectedAction.Type -eq 'UseExisting') {
        Write-Host "Selected shared repository: $($selectedAction.Repo.Name)"
        return $selectedAction.Repo
    }

    while ($true) {
        $newRepoName = Read-TextWithDefault -Prompt 'Enter the name for the shared repository' -DefaultValue $selectedAction.DefaultName

        $newRepoName = $newRepoName.Trim()
        if ([string]::IsNullOrWhiteSpace($newRepoName)) {
            Write-Warning 'Repository name cannot be empty.'
            continue
        }

        $confirmCreation = Read-YesNo `
            -Prompt "Create shared repository '$newRepoName' in project '$ProjectName' now?" `
            -PromptGuidanceLines @(
                'Creating the shared repository is an immediate write; it is not deferred until Apply.',
                'Choose No to enter a different repository name.'
            ) `
            -PromptGuidanceDocRelativePath 'docs/setup/azdo-automated-setup.md' `
            -PromptGuidanceRef $ALM4DataverseRef
        if (-not $confirmCreation) {
            continue
        }

        $createdRepo = Invoke-WithSpectreStatus -Status "Creating Git repository '$newRepoName' in project '$ProjectName'..." -ScriptBlock {
            Add-VSTeamGitRepository -ProjectName $ProjectName -Name $newRepoName
        }
        if (-not $createdRepo -or -not $createdRepo.Id) {
            throw "Failed to create Git repository '$newRepoName'."
        }

        $createdRepo | Add-Member -NotePropertyName CreatedDuringSetup -NotePropertyValue $true -Force
        Write-Host "Created shared repository '$newRepoName'."
        return $createdRepo
    }
}

function Get-AzDoCallerSecretVariableBlock {
    <#
    .SYNOPSIS
    Returns the template-level secretVariables block from an existing caller pipeline.
    .NOTES
    Recognizes the generated caller layout: the key at four spaces under the single
    template's parameters, followed by list items indented at four or more spaces.
    Returns the lines joined by the platform newline, or an empty string when the file
    or block is absent, so callers can append it to regenerated content verbatim.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return '' }

    $secretVariableLines = [System.Collections.Generic.List[string]]::new()
    $inSecretVariables = $false
    foreach ($existingLine in @(Get-Content -LiteralPath $Path)) {
        if ($existingLine -match '^\s{4}secretVariables:') {
            $inSecretVariables = $true
            $secretVariableLines.Add($existingLine)
        }
        elseif ($inSecretVariables -and ($existingLine -match '^\s{5,}\S' -or $existingLine -match '^\s{4}-\s')) {
            $secretVariableLines.Add($existingLine)
        }
        else {
            $inSecretVariables = $false
        }
    }

    return ($secretVariableLines -join [Environment]::NewLine)
}

function Sync-CopyToYourRepoIntoGitRepo {
    <#
    .SYNOPSIS
    Copies the scaffold into a working tree.
    .NOTES
    Pipeline callers generated from alm-config.psd1 (pipelines/BUILD.yml,
    DEPLOY-{branch}.yml, EXPORT.yml and IMPORT.yml) are skipped here. The static
    APPLY-CONFIG.yml caller is copied and its shared repository name and ref are
    rewritten to the selected values. Overwrites differing scaffold files but
    preserves existing alm-config.psd1 for the later merge and existing
    application-owned files (AGENTS.md and data/). Obsolete .template companions are
    removed for existing destinations.
    Does not commit.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter()][string]$SharedRepositoryName,
        [Parameter()][string]$SharedRepositoryRef = 'main'
    )

    if (-not (Test-Path -LiteralPath $SourceRoot)) {
        throw "Source folder not found: $SourceRoot"
    }

    Write-Section `
        -Message "Syncing pipeline files into main repository"
    Write-Host "Source: $SourceRoot" -ForegroundColor DarkGray
    Write-Host "Target: $TargetRoot" -ForegroundColor DarkGray

    $allSourceFiles = Get-ChildItem -LiteralPath $SourceRoot -Recurse -Force | Where-Object { -not $_.PSIsContainer }

    foreach ($file in $allSourceFiles) {
        $relativePath = $file.FullName.Substring($SourceRoot.Length).TrimStart('\', '/')
        $normalizedRelativePath = $relativePath -replace '\\', '/'
        $destPath = Join-Path $TargetRoot $relativePath

        if ($normalizedRelativePath -in @('pipelines/BUILD.yml', 'pipelines/DEPLOY-main.yml', 'pipelines/EXPORT.yml', 'pipelines/IMPORT.yml')) {
            continue
        }

        if ($normalizedRelativePath -eq 'alm-config.psd1' -and (Test-Path -LiteralPath $destPath)) {
            if (Test-Path -LiteralPath "$destPath.template") {
                Remove-Item -LiteralPath "$destPath.template" -Force
            }

            Write-Host 'Preserving existing alm-config.psd1 so current solution defaults and extended config can be merged later.' -ForegroundColor DarkGray
            continue
        }

        if ((Test-ApplicationOwnedScaffoldPath -RelativePath $normalizedRelativePath) -and (Test-Path -LiteralPath $destPath)) {
            Write-Host "Preserving existing $normalizedRelativePath." -ForegroundColor DarkGray
            continue
        }

        $destDir = Split-Path -Parent $destPath
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }

        $sourceFileToUse = $file.FullName
        $isTempFile = $false

        if ($normalizedRelativePath -eq 'pipelines/APPLY-CONFIG.yml') {
            $content = Get-Content -LiteralPath $file.FullName -Raw
            if (-not [string]::IsNullOrWhiteSpace($SharedRepositoryName)) {
                $content = $content -replace '(?m)^(\s*name:\s*)ALM4Dataverse\s*$', "`${1}$SharedRepositoryName"
            }
            $escapedRef = ([string]$SharedRepositoryRef).Replace("'", "''")
            $content = [regex]::Replace($content, '(?m)^(?<indent>\s*ref:\s*)[^\r\n]*$', {
                param($match)
                return $match.Groups['indent'].Value + "'refs/heads/$escapedRef'"
            })

            $tempFile = [System.IO.Path]::GetTempFileName()
            $content | Set-Content -LiteralPath $tempFile -NoNewline
            $sourceFileToUse = $tempFile
            $isTempFile = $true
        }

        try {
            if (Test-Path -LiteralPath $destPath) {
                $srcHash = Get-FileHash -LiteralPath $sourceFileToUse -Algorithm SHA256
                $dstHash = Get-FileHash -LiteralPath $destPath -Algorithm SHA256

                if ($srcHash.Hash -ne $dstHash.Hash) {
                    Copy-Item -LiteralPath $sourceFileToUse -Destination $destPath -Force
                    if (Test-Path -LiteralPath "$destPath.template") {
                        Remove-Item -LiteralPath "$destPath.template" -Force
                    }
                }
                else {
                    if (Test-Path -LiteralPath "$destPath.template") {
                        Remove-Item -LiteralPath "$destPath.template" -Force
                    }
                }
            }
            else {
                Copy-Item -LiteralPath $sourceFileToUse -Destination $destPath -Force
            }
        }
        finally {
            if ($isTempFile -and (Test-Path -LiteralPath $sourceFileToUse)) {
                Remove-Item -LiteralPath $sourceFileToUse -Force
            }
        }
    }

    Write-Host 'Pipeline files synced into the working tree.' -ForegroundColor Green
}

function New-AzDoRepoWorkingTree {
    <#
    .SYNOPSIS
    Clones an Azure DevOps repository and returns Path and BaseBranch for subsequent edits.
    .NOTES
    The repository default branch takes precedence over PreferredBranch. WorkBranch,
    when supplied, is reset/created from that base. Uses a per-command bearer header;
    restores location and error preference but leaves clone cleanup to the caller.
    WhatIf returns nothing; clone or branch preparation failures throw.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][object]$TargetRepo,
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter()][string]$PreferredBranch = 'main',
        [Parameter()][string]$WorkBranch
    )

    if (-not $PSCmdlet.ShouldProcess($TargetRepo.Name, 'Clone repository and prepare working branch')) { return }

    if (-not $TargetRepo.remoteUrl) {
        throw "Could not determine remoteUrl for repository '$($TargetRepo.Name)'."
    }

    $cloneRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ALM4Dataverse-MainRepo-" + [guid]::NewGuid().ToString('n'))
    if (Test-Path -LiteralPath $cloneRoot) {
        try { Remove-Item -LiteralPath $cloneRoot -Recurse -Force -ErrorAction Stop } catch { throw }
    }

    Write-Host "Cloning '$($TargetRepo.Name)' to a temp folder..." -ForegroundColor Yellow
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'

        $cloneOutput = @(& git -c "http.extraheader=AUTHORIZATION: bearer $AccessToken" clone $TargetRepo.remoteUrl $cloneRoot 2>&1)
        if ($LASTEXITCODE -ne 0) {
            $cloneErrorDetails = @($cloneOutput | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $cloneErrorMessage = if ($cloneErrorDetails.Count -gt 0) { $cloneErrorDetails[-1] } else { "Exit code: $LASTEXITCODE" }
            throw "Git clone failed. $cloneErrorMessage"
        }

        Push-Location $cloneRoot
        try {
            $branch = $PreferredBranch
            if ($TargetRepo.defaultBranch) {
                $branch = ConvertFrom-GitRefToBranchName -Ref $TargetRepo.defaultBranch
            }
            if ([string]::IsNullOrWhiteSpace($branch)) {
                $branch = 'main'
            }

            $hasCommits = $false
            try {
                & git rev-parse HEAD 2>$null | Out-Null
                $hasCommits = ($LASTEXITCODE -eq 0)
            }
            catch {
                $hasCommits = $false
            }

            if ($hasCommits) {
                & git checkout $branch 2>&1 | Out-Host
                if ($LASTEXITCODE -ne 0) {
                    & git checkout -b $branch 2>&1 | Out-Host
                    if ($LASTEXITCODE -ne 0) {
                        throw "Git checkout failed for branch '$branch'."
                    }
                }
            }
            else {
                & git checkout -b $branch 2>&1 | Out-Host
                if ($LASTEXITCODE -ne 0) {
                    throw "Git checkout -b failed with exit code $LASTEXITCODE"
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($WorkBranch) -and $WorkBranch -ne $branch) {
                & git checkout -B $WorkBranch 2>&1 | Out-Host
                if ($LASTEXITCODE -ne 0) {
                    throw "Git checkout failed for working branch '$WorkBranch'."
                }
            }

            return [pscustomobject]@{
                Path       = $cloneRoot
                BaseBranch = $branch
            }
        }
        finally {
            Pop-Location
        }
    }
    catch {
        try { Remove-Item -LiteralPath $cloneRoot -Recurse -Force -ErrorAction Stop } catch { Write-Verbose 'Could not remove the failed repository clone; preserving the original failure.' }
        throw
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Get-AzDoDefaultAgentQueueId {
    # Prefer hosted Azure Pipelines, then Default, then the first queue; no usable ID throws.
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$Project
    )

    $queues = @(Get-VSTeamQueue -ProjectName $Project)
    if ($queues.Count -eq 0) {
        throw "No agent queues found in project '$Project'."
    }

    $preferred = $queues | Where-Object { $_.name -eq 'Azure Pipelines' } | Select-Object -First 1
    if (-not $preferred) {
        $preferred = $queues | Where-Object { $_.name -eq 'Default' } | Select-Object -First 1
    }
    if (-not $preferred) {
        $preferred = $queues | Select-Object -First 1
    }

    if (-not $preferred -or -not $preferred.id) {
        throw "Unable to resolve an agent queue id."
    }

    return [int]$preferred.id
}

function Get-AzDoSecurityNamespaceByName {
    # Resolve either API name or display name; callers require a namespace with an ID.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name
    )

    $allNamespaces = Get-VSTeamSecurityNamespace
    $ns = $allNamespaces | Where-Object { $_.Name -eq $Name -or $_.DisplayName -eq $Name } | Select-Object -First 1
    if (-not $ns -or -not $ns.Id) {
        throw "Unable to resolve security namespace '$Name'."
    }
    return $ns
}

function Get-AzDoSecurityNamespaceActionBit {
    # Return a long mask bit by action name/display name; missing bit metadata is an error.
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory)][object]$Namespace,
        [Parameter(Mandatory)][string]$ActionName
    )

    $actions = @()
    if ($Namespace -and $Namespace.actions) {
        $actions = @($Namespace.actions)
    }

    $action = $actions | Where-Object {
        ($_.name -eq $ActionName) -or ($_.displayName -eq $ActionName)
    } | Select-Object -First 1

    if (-not $action -or -not ($action.PSObject.Properties.Name -contains 'bit')) {
        throw "Unable to resolve action '$ActionName' in security namespace '$($Namespace.name)'."
    }

    return [long]$action.bit
}

function Get-AzDoBuildServiceIdentity {
    <#
    .SYNOPSIS
    Returns the ACL identity descriptor for the project's Build Service, not its Graph descriptor.
    .NOTES
    Decodes svc. descriptors to match the Build:ProjectId suffix, avoiding display-name
    ambiguity. Malformed descriptors are skipped; no matching identity throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter()][string]$ProjectName
    )

    # Use VSTeam command to search for Build Service identity
    $serviceIdentities = @(Get-VSTeamUser -SubjectTypes svc)

    $buildServicePattern = "Build:$ProjectId"
    $buildIdentity = $null

    foreach ($identity in $serviceIdentities) {
        if ($identity.descriptor -and $identity.descriptor.StartsWith('svc.')) {
            try {
                # Remove "svc." prefix and base64 decode
                $encodedPart = $identity.descriptor.Substring(4)

                # Add padding if needed for proper base64 decoding
                $padding = (4 - ($encodedPart.Length % 4)) % 4
                if ($padding -gt 0) {
                    $encodedPart += '=' * $padding
                }

                $decodedBytes = [Convert]::FromBase64String($encodedPart)
                $decodedString = [Text.Encoding]::UTF8.GetString($decodedBytes)

                # Check if decoded string ends with "Build:$ProjectId"
                if ($decodedString.EndsWith($buildServicePattern)) {
                    $buildIdentity = $identity
                    $correctDescriptor = "Microsoft.TeamFoundation.ServiceIdentity;$decodedString"
                    break
                }
            }
            catch {
                # Skip if base64 decode fails
                continue
            }
        }
    }

    if (-not $buildIdentity) {
        throw "Unable to find Build Service identity with descriptor ending 'Build:$ProjectId' for project '$ProjectName'."
    }

    if (-not $correctDescriptor) {
        throw "Build Service identity found but correct descriptor could not be constructed."
    }

    Write-Host "Found Build Service identity: $($buildIdentity.displayName)"
    return $correctDescriptor
}

function Get-AzDoAccessControlEntry {
    # Null means absent OR unreadable ACL/ACE data; callers must not infer successful authorization.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$NamespaceId,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Descriptor
    )

    try {
        # Use VSTeam command to get access control list
        $acls = Get-VSTeamAccessControlList -SecurityNamespaceId $NamespaceId -Token $Token -Descriptors $Descriptor

        if (-not $acls -or $acls.Count -eq 0) {
            return $null
        }

        $acl = $acls | Select-Object -First 1
        if (-not $acl -or -not $acl.acesDictionary) {
            return $null
        }

        # Extract the ACE for the requested descriptor
        $ace = $null
        try {
            if ($acl.acesDictionary.PSObject.Properties.Name -contains $Descriptor) {
                $ace = $acl.acesDictionary.$Descriptor
            }
            elseif ($acl.acesDictionary.ContainsKey -and $acl.acesDictionary.ContainsKey($Descriptor)) {
                $ace = $acl.acesDictionary[$Descriptor]
            }
        }
        catch {
            $ace = $null
        }

        return $ace
    }
    catch {
        # Lookup failures share the absent-entry sentinel used by the provisioning caller.
        return $null
    }
}

function Set-AzDoAccessControlEntry {
    <#
    .SYNOPSIS
    Overwrites the descriptor's allow/deny masks for a security namespace token.
    .NOTES
    Callers must merge any bits they intend to retain before invoking this helper.
    Resolves the namespace object required by VSTeam; honors ShouldProcess.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$NamespaceId,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Descriptor,
        [Parameter(Mandatory)][long]$Allow,
        [Parameter(Mandatory)][long]$Deny
    )

    # Use VSTeam command to set access control entry
    # Note: Add-VSTeamAccessControlEntry requires a SecurityNamespace object, so we need to get it first
    if (-not $PSCmdlet.ShouldProcess($Descriptor, 'Update Azure DevOps access control entry')) { return }

    $ns = Get-VSTeamSecurityNamespace -Id $NamespaceId
    Add-VSTeamAccessControlEntry -SecurityNamespace $ns -Token $Token -Descriptor $Descriptor -AllowMask $Allow -DenyMask $Deny -OverwriteMask
}

function Initialize-AzDoBuildServiceRepositoryPermission {
    <#
    .SYNOPSIS
    Grants project Build Service Contribute on one repository.
    .NOTES
    Preserves observed unrelated mask bits and clears only the Contribute deny bit.
    An unreadable ACE is treated as zero masks by the lookup helper; this is not
    effective/inherited-permission evaluation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$RepositoryId
    )

    $descriptor = Get-AzDoBuildServiceIdentity  -ProjectId $ProjectId -ProjectName $ProjectName
    $descriptor = $descriptor.Trim()  # Clean any whitespace
    Write-Host "Found Build Service descriptor: $descriptor" -ForegroundColor DarkGray

    $ns = Get-AzDoSecurityNamespaceByName  -Name 'Git Repositories'
    $contributeBit = Get-AzDoSecurityNamespaceActionBit -Namespace $ns -ActionName 'Contribute'

    # Repo token format for Git Repositories namespace:
    #   repoV2/<projectId>/<repoId>
    $token = "repoV2/$ProjectId/$RepositoryId"

    $existing = Get-AzDoAccessControlEntry  -NamespaceId $ns.Id -Token $token -Descriptor $descriptor
    $existingAllow = 0L
    $existingDeny = 0L

    if ($existing) {
        if ($existing.PSObject.Properties.Name -contains 'allow') { $existingAllow = [long]$existing.allow }
        if ($existing.PSObject.Properties.Name -contains 'deny') { $existingDeny = [long]$existing.deny }
    }

    $alreadyAllowed = (($existingAllow -band $contributeBit) -ne 0)
    $isDenied = (($existingDeny -band $contributeBit) -ne 0)

    if ($alreadyAllowed -and -not $isDenied) {
        Write-Host "Build Service already has 'Contribute' on repo."
        return
    }

    $desiredAllow = ($existingAllow -bor $contributeBit)
    $desiredDeny = ($existingDeny -band (-bnot $contributeBit))

    Write-Host "Granting Build Service 'Contribute' on repo..." -ForegroundColor Yellow
    Set-AzDoAccessControlEntry  -NamespaceId $ns.Id -Token $token -Descriptor $descriptor -Allow $desiredAllow -Deny $desiredDeny | out-null
    Write-Host "Granted 'Contribute' to Build Service on repository."
}

function Initialize-AzDoYamlPipelineDefinition {
    <#
    .SYNOPSIS
    Creates or retargets a named YAML build definition in the specified folder.
    .NOTES
    DefinitionBranch accepts a branch name or refs/heads ref and must be nonempty.
    Creates CI triggers sourced from YAML; existing definitions are checked for
    YAML path, repository and default branch, not reconciled for every setting.
    Uses the current VSTeam REST project context for writes. Returns no definition.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][object]$Repository,
        [Parameter(Mandatory)][string]$DefinitionName,
        [Parameter(Mandatory)][string]$YamlPath,
        [Parameter(Mandatory)][string]$DefinitionBranch,
        [Parameter(Mandatory)][int]$QueueId,
        [Parameter()][string]$FolderPath = '\'
    )

    $YamlPath = $YamlPath.TrimStart('/')

    $normalizedDefinitionBranch = [string]$DefinitionBranch
    if ([string]::IsNullOrWhiteSpace($normalizedDefinitionBranch)) {
        throw "DefinitionBranch cannot be empty for pipeline '$DefinitionName'."
    }

    $normalizedDefinitionBranch = $normalizedDefinitionBranch.Trim()
    if ($normalizedDefinitionBranch -match '^refs/heads/(.+)$') {
        $normalizedDefinitionBranch = [string]$Matches[1]
    }

    if ([string]::IsNullOrWhiteSpace($normalizedDefinitionBranch)) {
        throw "DefinitionBranch cannot be empty for pipeline '$DefinitionName'."
    }

    $definitionBranchRef = "refs/heads/$normalizedDefinitionBranch"

    $existing = @(Get-VSTeamBuildDefinition -ProjectName $Project) | Where-Object { $_.name -eq $DefinitionName -and $_.path -eq $FolderPath }
    $def = $existing | Select-Object -First 1

    if (-not $def) {
        Write-Host "Creating pipeline '$DefinitionName' (YAML: $YamlPath)..." -ForegroundColor Yellow

        # Use Invoke-VSTeamRequest since VSTeam build definition commands require JSON files
        $body = @{
            name        = $DefinitionName
            path        = $FolderPath
            type        = 'build'
            queueStatus = 'enabled'
            queue       = @{ id = $QueueId }
            repository  = @{
                id            = $Repository.Id
                name          = $Repository.Name
                type          = 'TfsGit'
                defaultBranch = $definitionBranchRef
            }
            process     = @{
                type         = 2
                yamlFilename = $YamlPath
            }
            triggers    = @(
                @{
                    settingsSourceType = 2
                    triggerType        = 'continuousIntegration'
                }
            )
        }

        $resource = "build/definitions"
        [void](Invoke-VSTeamRequest -Method POST -Resource $resource -Body ($body | ConvertTo-Json -Depth 10) -ContentType 'application/json' -Version '7.1')
        Write-Host "Created pipeline '$DefinitionName'."
        return
    }

    # Ensure existing points at expected YAML + repo
    $full = Get-VSTeamBuildDefinition -ProjectName $Project -Id $def.id

    $needsUpdate = $false
    if (-not $full.process -or -not $full.process.type -or [int]$full.process.type -ne 2) {
        $needsUpdate = $true
    }
    elseif ($full.process.PSObject.Properties.Name -contains 'yamlFilename') {
        if ($full.process.yamlFilename -ne $YamlPath) { $needsUpdate = $true }
    }
    else {
        # If yamlFilename isn't present, treat as needs update.
        $needsUpdate = $true
    }

    if ($full.repository -and $full.repository.id -and ($full.repository.id -ne $Repository.Id)) {
        $needsUpdate = $true
    }

    if ($full.repository -and $full.repository.PSObject.Properties.Name -contains 'defaultBranch') {
        if ($full.repository.defaultBranch -ne $definitionBranchRef) {
            $needsUpdate = $true
        }
    }
    else {
        $needsUpdate = $true
    }

    if (-not $needsUpdate) {
        Write-Host "Pipeline '$DefinitionName' already exists and points at '$YamlPath'."
        return
    }

    Write-Host "Updating pipeline '$DefinitionName' to point at '$YamlPath'..." -ForegroundColor Yellow

    $def.repository.name = $Repository.Name
    $def.repository.id = $Repository.Id
    $def.repository.defaultBranch = $definitionBranchRef
    $def.process.yamlFilename = $YamlPath

    # Use Invoke-VSTeamRequest since VSTeam update commands require JSON files
    $resource = "build/definitions/$($def.id)"
    [void](Invoke-VSTeamRequest -Method PUT -Resource $resource -Body ($def | ConvertTo-Json -Depth 50) -ContentType 'application/json' -Version '7.1')
    Write-Host "Updated pipeline '$DefinitionName'."
}

function Initialize-AzDoMainRepositoryPipeline {
    # Registers filenames as pipeline names; only DEPLOY-<branch>.yml uses its suffix
    # as the definition branch. Other YAML uses the repository default (or main).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][object]$Repository,
        [Parameter(Mandatory)][string[]]$YamlFiles,
        [Parameter()][string]$FolderPath = '\\'
    )

    Write-Section `
        -Message "Ensuring Azure DevOps pipeline definitions exist"

    $queueId = Get-AzDoDefaultAgentQueueId  -Project $Project
    Write-Host "Using agent queue id: $queueId" -ForegroundColor DarkGray

    $defaultBranchName = 'main'
    if ($Repository.defaultBranch) {
        $defaultBranchName = ConvertFrom-GitRefToBranchName -Ref $Repository.defaultBranch
    }

    foreach ($yaml in $YamlFiles) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($yaml)
        $definitionBranchName = $defaultBranchName
        if ($yaml -match '^pipelines/DEPLOY-(.+)\.yml$') {
            $definitionBranchName = [string]$Matches[1]
        }

        Initialize-AzDoYamlPipelineDefinition  -Project $Project -Repository $Repository -DefinitionName $name -YamlPath $yaml -DefinitionBranch $definitionBranchName -QueueId $queueId -FolderPath $FolderPath
    }
}

function Initialize-AzDoDeploymentApproverTeam {
    <#
    .SYNOPSIS
    Returns the environment's deployment-approver team, creating it and adding the current user.
    .NOTES
    Membership requires resolving both profile email to a user and team name to a
    group descriptor; failure throws. This does not remove any existing members.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$EnvironmentName
    )

    $teamName = "$EnvironmentName deployment approvers"
    Write-Host "Ensuring team '$teamName' exists..." -ForegroundColor DarkGray

    $team = Get-VSTeam -ProjectName $ProjectName -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $teamName } | Select-Object -First 1

    if (-not $team) {
        Write-Host "Creating team '$teamName'..." -ForegroundColor Yellow
        Add-VSTeam -ProjectName $ProjectName -Name $teamName -Description "Approvers for $EnvironmentName deployment" | Out-Null
        $team = Get-VSTeam -ProjectName $ProjectName | Where-Object { $_.Name -eq $teamName } | Select-Object -First 1
    }

    # Add current user to the team

    $me = Invoke-VSTeamRequest -NoProject -Method GET -Url "https://app.vssps.visualstudio.com/_apis/profile/profiles/me" -Version "7.1"
    Write-Host "Adding current user ($($me.emailAddress)) to team '$teamName'..." -ForegroundColor Yellow

    $user = Get-VSTeamUser | Where-Object { $_.UniqueName -eq $me.emailAddress } | Select-Object -First 1
    $group = Get-VSTeamGroup -ProjectName $ProjectName | Where-Object { $_.DisplayName -eq $teamName } | Select-Object -First 1

    if ($user -and $group) {
        Add-VSTeamMembership -MemberDescriptor $user.Descriptor -ContainerDescriptor $group.Descriptor | Out-Null
    }
    else {
        throw "Could not resolve user or group to add membership."
    }


    return $team
}

function Initialize-AzDoVariableGroupApproval {
    # An existing Approval check is retained without reconciling its approvers/settings.
    # Otherwise resolve the team Graph identity and add a check; REST failures propagate.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$VariableGroupId,
        [Parameter(Mandatory)][string]$VariableGroupName,
        [Parameter(Mandatory)][object]$ApproverTeam
    )

    Write-Host "Ensuring Approval check on variable group '$VariableGroupName'..." -ForegroundColor DarkGray

    # Check for existing checks
    $uri = "https://dev.azure.com/$Organization/$Project/_apis/pipelines/checks/configurations?resourceType=variablegroup&resourceId=$VariableGroupId&api-version=7.1-preview.1"
    $headers = @{ Authorization = "Bearer $($adoAccessToken.Token)" }

    $existingChecks = $null

    $existingChecks = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers


    $hasApproval = $false
    if ($existingChecks -and $existingChecks.count -gt 0) {
        foreach ($check in $existingChecks.value) {
            if ($check.resource.type -eq 'variablegroup' -and [string]$check.resource.id -eq [string]$VariableGroupId -and $check.type -and $check.type.name -eq 'Approval') {
                $hasApproval = $true
                break
            }
        }
    }

    if ($hasApproval) {
        Write-Host "Approval check already exists on variable group '$VariableGroupName'."
        return
    }

    Write-Host "Adding Approval check to variable group '$VariableGroupName'..." -ForegroundColor Yellow

    # We need the descriptor for the team. Get-VSTeamTeam doesn't return it directly.
    # We can find the group identity using Get-VSTeamGroup.
    $teamIdentity = Get-VSTeamGroup -ProjectName $Project | Where-Object { $_.principalName -eq $ApproverTeam.name -or $_.displayName -eq $ApproverTeam.name } | Select-Object -First 1

    if (-not $teamIdentity) {
        throw "Could not resolve identity for team '$($ApproverTeam.name)' for approval check creation."
    }

    $body = @{
        type = @{
            id = "8C6F20A7-A545-4486-9777-F762FAFE0D4D"
            name = "Approval"
        }
        settings = @{
            approvers = @(
                @{
                    id = $teamIdentity.originId
                    descriptor = $teamIdentity.descriptor
                    displayName = $teamIdentity.displayName
                }
            )
            executionOrder = 1
            minRequiredApprovers = 0
            requesterCannotBeApprover = $false
        }
        resource = @{
            type = "variablegroup"
            id = [string]$VariableGroupId
            name = $VariableGroupName
        }
        timeout = 43200
    }

    $resource = "pipelines/checks/configurations"
    [void](Invoke-VSTeamRequest -Method POST -Resource $resource -Body ($body | ConvertTo-Json -Depth 10) -ContentType 'application/json' -Version '7.1-preview.1')
    Write-Host "Approval check added."
}

function Initialize-AzDoVariableGroupExclusiveLock {
    # Add the variable-group lock only if none is reported; existing checks are not rewritten.
    # The shared resource serializes consumers independently of branch-specific YAML names.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$VariableGroupId,
        [Parameter(Mandatory)][string]$VariableGroupName
    )

    Write-Host "Ensuring ExclusiveLock check on variable group '$VariableGroupName'..." -ForegroundColor DarkGray

    # Check for existing checks
    $uri = "https://dev.azure.com/$Organization/$Project/_apis/pipelines/checks/configurations?resourceType=variablegroup&resourceId=$VariableGroupId&api-version=7.1-preview.1"
    $headers = @{ Authorization = "Bearer $($adoAccessToken.Token)" }

    $existingChecks = $null
    $existingChecks = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers

    $hasExclusiveLock = $false
    if ($existingChecks -and $existingChecks.count -gt 0) {
        foreach ($check in $existingChecks.value) {
            if ($check.resource.type -eq 'variablegroup' -and [string]$check.resource.id -eq [string]$VariableGroupId -and $check.type -and $check.type.name -eq 'ExclusiveLock') {
                $hasExclusiveLock = $true
                break
            }
        }
    }

    if ($hasExclusiveLock) {
        Write-Host "ExclusiveLock check already exists on variable group '$VariableGroupName'."
        return
    }

    Write-Host "Adding ExclusiveLock check to variable group '$VariableGroupName'..." -ForegroundColor Yellow

    $body = @{
        type = @{
            id = "2EF31AD6-BAA0-403A-8B45-2CBC9B4E5563"
            name = "ExclusiveLock"
        }
        settings = @{}
        resource = @{
            type = "variablegroup"
            id = [string]$VariableGroupId
            name = $VariableGroupName
        }
        timeout = 43200
    }

    $resource = "pipelines/checks/configurations"
    [void](Invoke-VSTeamRequest -Method POST -Resource $resource -Body ($body | ConvertTo-Json -Depth 10) -ContentType 'application/json' -Version '7.1-preview.1')
    Write-Host "ExclusiveLock check added."
}

function Initialize-AzDoEnvironment {
    # Return the named Azure Pipelines environment, creating it if absent.
    # Existing descriptions are preserved; lookup/create failures terminate provisioning.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][string]$Description
    )

    Write-Host "Ensuring Environment '$EnvironmentName'..." -ForegroundColor DarkGray

    $headers = @{ Authorization = "Bearer $($adoAccessToken.Token)" }

    # List environments to check if it exists
    $uri = "https://dev.azure.com/$Organization/$Project/_apis/pipelines/environments?name=$EnvironmentName&api-version=7.2-preview.1"

    try {
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers
        $env = $response.value | Where-Object { $_.name -eq $EnvironmentName } | Select-Object -First 1

        if ($env) {
            Write-Host "Environment '$EnvironmentName' already exists (id: $($env.id))."
            return $env
        }

        Write-Host "Creating Environment '$EnvironmentName'..." -ForegroundColor Yellow

        $body = @{
            name = $EnvironmentName
            description = $Description
        }

        $createUri = "https://dev.azure.com/$Organization/$Project/_apis/pipelines/environments?api-version=7.2-preview.1"
        $created = Invoke-RestMethod -Uri $createUri -Method Post -Headers $headers -Body ($body | ConvertTo-Json) -ContentType "application/json"

        Write-Host "Created Environment '$EnvironmentName' (id: $($created.id))."
        return $created
    }
    catch {
        Write-Host "Failed to ensure environment: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

function Initialize-AzDoPipelinePermission {
    # Authorize one pipeline for the named resource, not all pipelines.
    # Failures warn and continue so the user can authorize the resource on first run.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$ResourceType, # endpoint, variablegroup, environment or repository
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)][int]$PipelineId
    )

    Write-Host "Ensuring pipeline $PipelineId has permission on $ResourceType $ResourceId..." -ForegroundColor DarkGray

    $headers = @{ Authorization = "Bearer $($adoAccessToken.Token)" }

    # Check existing permissions
    $uri = "https://dev.azure.com/$Organization/$Project/_apis/pipelines/pipelinePermissions/$ResourceType/$ResourceId`?api-version=7.1-preview.1"

    try {
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers

        $isAuthorized = $false
        if ($response.pipelines) {
            foreach ($p in $response.pipelines) {
                if ($p.id -eq $PipelineId -and $p.authorized -eq $true) {
                    $isAuthorized = $true
                    break
                }
            }
        }

        if ($isAuthorized) {
            Write-Host "Pipeline $PipelineId is already authorized."
            return
        }

        Write-Host "Authorizing pipeline $PipelineId..." -ForegroundColor Yellow

        $body = @{
            pipelines = @(
                @{
                    id = $PipelineId
                    authorized = $true
                }
            )
        }

        $patchUri = "https://dev.azure.com/$Organization/$Project/_apis/pipelines/pipelinePermissions/$ResourceType/$ResourceId`?api-version=7.1-preview.1"
        [void](Invoke-RestMethod -Uri $patchUri -Method Patch -Headers $headers -Body ($body | ConvertTo-Json) -ContentType "application/json")

        Write-Host "Pipeline authorized successfully."
    }
    catch {
        Write-Host "Failed to authorize pipeline: $($_.Exception.Message)" -ForegroundColor Red
        Write-Warning "Could not authorize pipeline. You may need to authorize it manually when running the pipeline."
    }
}

function Initialize-AzDoServiceEndpoint {
    <#
    .SYNOPSIS
    Returns a named Power Platform service connection, recreating it when its binding changes.
    .NOTES
    Compares normalized URL, application ID and auth type. Supplying a new secret
    forces recreation; an unchanged secret connection can be reused without its secret.
    Recreation removes the old endpoint before creating the replacement and is not
    transactional. Refetches after creation to obtain Azure DevOps WIF issuer/subject.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$ServiceEndpointName,
        [Parameter(Mandatory)][string]$EnvironmentUrl,
        [Parameter(Mandatory)][string]$ApplicationId,
        [Parameter()][string]$ClientSecret,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter()][string]$AuthType = 'Secret'
    )

    Write-Host "Ensuring Service Endpoint '$ServiceEndpointName'..." -ForegroundColor DarkGray

    # Get-VSTeamServiceEndpoint does not support -Name, so we filter client-side
    $endpoints = @(Get-VSTeamServiceEndpoint -ProjectName $ProjectName -ErrorAction SilentlyContinue)
    $existing = $endpoints | Where-Object { $_.name -eq $ServiceEndpointName } | Select-Object -First 1

    if ($existing) {
        $existingAuthParameters = $existing.authorization.parameters
        $existingApplicationId = $null
        if ($existingAuthParameters) {
            if ($existingAuthParameters.PSObject.Properties.Name -contains 'applicationId') {
                $existingApplicationId = $existingAuthParameters.applicationId
            }
            elseif ($existingAuthParameters.PSObject.Properties.Name -contains 'serviceprincipalid') {
                $existingApplicationId = $existingAuthParameters.serviceprincipalid
            }
        }

        $existingAuthType = 'Secret'
        if ($existing.authorization -and $existing.authorization.scheme -eq 'WorkloadIdentityFederation') {
            $existingAuthType = 'WIF'
        }

        $normalizedExistingUrl = ConvertTo-NormalizedEnvironmentUrl -Url $existing.url
        $normalizedTargetUrl = ConvertTo-NormalizedEnvironmentUrl -Url $EnvironmentUrl
        $requiresUpdate = ($normalizedExistingUrl -ne $normalizedTargetUrl) -or ($existingApplicationId -ne $ApplicationId) -or ($existingAuthType -ne $AuthType)

        if ($AuthType -eq 'Secret' -and -not [string]::IsNullOrWhiteSpace($ClientSecret)) {
            $requiresUpdate = $true
        }

        if (-not $requiresUpdate) {
            Write-Host "Service Endpoint '$ServiceEndpointName' already exists."
            return $existing
        }

        Write-Host "Service Endpoint '$ServiceEndpointName' already exists but needs to be refreshed. Recreating it..." -ForegroundColor Yellow
        Remove-VSTeamServiceEndpoint -ProjectName $ProjectName -Id $existing.id -Force | Out-Null
    }

    Write-Host "Creating Service Endpoint '$ServiceEndpointName'..." -ForegroundColor Yellow

    try {
        $payload = @{
            url = $EnvironmentUrl
            data = @{}
        }

        if ($AuthType -eq 'WIF') {
            # Workload Identity Federation
            $payload.authorization = @{
                parameters = @{
                    "serviceprincipalid" = $ApplicationId
                    "tenantid" = $TenantId
                }
                scheme = "WorkloadIdentityFederation"
            }
        }
        else {
            # Traditional Service Principal with Secret
            if ([string]::IsNullOrWhiteSpace($ClientSecret)) {
                throw "ClientSecret is required when AuthType is 'Secret'."
            }

            $payload.authorization = @{
                parameters = @{
                    "tenantId" = $TenantId
                    "applicationId" = $ApplicationId
                    "clientSecret" = $ClientSecret
                }
                scheme = "None"
            }
        }

        $response = Add-VSTeamServiceEndpoint -ProjectName $ProjectName `
            -EndpointName $ServiceEndpointName `
            -EndpointType "powerplatform-spn" `
            -Object $payload

        Write-Host "Service Endpoint '$ServiceEndpointName' created successfully."
        Start-Sleep -Seconds 5 # Wait a bit for SE to be fully available
        # Re-fetch to ensure we have all properties including WIF issuer/subject assigned by Azure DevOps
        $fetched = @(Get-VSTeamServiceEndpoint -ProjectName $ProjectName -ErrorAction SilentlyContinue) | Where-Object { $_.name -eq $ServiceEndpointName } | Select-Object -First 1
        if ($fetched) { return $fetched }
        return $response
    }
    catch {
        Write-Host "Failed to create Service Endpoint '$ServiceEndpointName': $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

function Initialize-EntraIdServicePrincipal {
    # Return the first appId match in the tenant or create its enterprise application.
    # Lookup failure warns but still attempts creation; creation failure propagates.
    param(
        [Parameter(Mandatory)][string]$ApplicationId,
        [Parameter(Mandatory)][string]$TenantId
    )

    $graphToken = Get-AuthToken -ResourceUrl "https://graph.microsoft.com" -TenantId $TenantId
    $headers = @{
        Authorization = "Bearer $($graphToken.AccessToken)"
        "Content-Type" = "application/json"
    }

    # Check if SP exists
    $uri = "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$ApplicationId'"
    try {
        $existing = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
        if ($existing.value.Count -gt 0) {
            Write-Host "Service Principal for App '$ApplicationId' already exists."
            return $existing.value[0]
        }
    }
    catch {
        Write-Warning "Failed to check for existing Service Principal: $($_.Exception.Message)"
    }

    # Create SP
    Write-Host "Creating Service Principal for App '$ApplicationId'..." -ForegroundColor Yellow
    $body = @{
        appId = $ApplicationId
    }

    try {
        $sp = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/servicePrincipals" -Headers $headers -Method Post -Body ($body | ConvertTo-Json)
        Write-Host "Created Service Principal ($($sp.id))."
        start-sleep -Seconds 10 # Wait a bit for SP to be fully available
        return $sp
    }
    catch {
        Write-Error "Failed to create Service Principal: $($_.Exception.Message)"
        throw
    }
}

function Add-EntraIdFederatedCredential {
    <#
    .SYNOPSIS
        Adds a federated identity credential to an Entra ID application for Workload Identity Federation.

    .DESCRIPTION
        Creates a federated identity credential that allows Azure DevOps to authenticate to Azure
        using Workload Identity Federation (WIF) without requiring client secrets.
        Reuses the first issuer/subject match, regardless of credential name.
        A failed lookup warns and proceeds to creation; a failed creation throws.
    .PARAMETER ApplicationObjectId
        Directory object ID of the application, not its client/application ID.
    #>
    param(
        [Parameter(Mandatory)][string]$ApplicationObjectId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$Issuer,
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$CredentialName
    )

    $graphToken = Get-AuthToken -ResourceUrl "https://graph.microsoft.com" -TenantId $TenantId
    $headers = @{
        Authorization = "Bearer $($graphToken.AccessToken)"
        "Content-Type" = "application/json"
    }

    $issuer = $Issuer
    $subject = $Subject
    $credentialName = $CredentialName

    Write-Host "Adding federated identity credential '$credentialName'..." -ForegroundColor Yellow

    # Check if credential already exists
    $listUri = "https://graph.microsoft.com/beta/applications/$ApplicationObjectId/federatedIdentityCredentials"
    try {
        $existing = Invoke-RestMethod -Uri $listUri -Headers $headers -Method Get
        $existingCred = $existing.value | Where-Object {
            $_.issuer -eq $issuer -and $_.subject -eq $subject
        } | Select-Object -First 1

        if ($existingCred) {
            Write-Host "Federated identity credential already exists for this issuer and subject."
            return $existingCred
        }
    }
    catch {
        Write-Warning "Failed to check for existing federated credentials: $($_.Exception.Message)"
    }

    # Create the federated credential
    $body = @{
        name = $credentialName
        issuer = $issuer
        subject = $subject
        audiences = @("api://AzureADTokenExchange")
        description = "Workload Identity Federation for Azure DevOps service connection"
    }

    try {
        $credential = Invoke-RestMethod -Uri $listUri -Headers $headers -Method Post -Body ($body | ConvertTo-Json)
        Write-Host "Created federated identity credential successfully."
        return $credential
    }
    catch {
        Write-Error "Failed to create federated identity credential: $($_.Exception.Message)"
        throw
    }
}

function New-EntraIdApplication {
    <#
    .SYNOPSIS
    Reuses the first display-name match or creates an application, and ensures its service principal.
    .OUTPUTS
    System.Management.Automation.PSCustomObject. Credential metadata including client ID,
    application object ID, tenant, auth type, CreatedDuringSetup and optional plaintext
    ClientSecret.
    .NOTES
    WIF leaves ClientSecret null; other auth types create a new secret even for an
    existing application. CreatedDuringSetup is true only when this call created the
    application. WhatIf returns nothing. Graph/secret failures propagate.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter()][string]$AuthType = 'Secret'
    )

    if (-not $PSCmdlet.ShouldProcess($DisplayName, 'Create or configure Entra application')) { return }

    # Get token for Graph
    $graphToken = Get-AuthToken -ResourceUrl "https://graph.microsoft.com" -TenantId $TenantId
    $headers = @{
        Authorization = "Bearer $($graphToken.AccessToken)"
        "Content-Type" = "application/json"
    }

    # Check if app exists
    $filter = "displayName eq '$DisplayName'"
    $uri = "https://graph.microsoft.com/v1.0/applications?`$filter=$filter"

    $existing = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get

    $app = $null
    $createdApplication = $false
    if ($existing.value.Count -gt 0) {
        $app = $existing.value[0]
        Write-Host "Found existing App Registration '$DisplayName' ($($app.appId))."
    }
    else {
        Write-Host "Creating App Registration '$DisplayName'..." -ForegroundColor Yellow
        $body = @{
            displayName = $DisplayName
            signInAudience = "AzureADMyOrg"
        }
        $app = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/applications" -Headers $headers -Method Post -Body ($body | ConvertTo-Json)
        $createdApplication = $true
        Write-Host "Created App Registration '$DisplayName' ($($app.appId))."
    }

    [void](Initialize-EntraIdServicePrincipal -ApplicationId $app.appId -TenantId $TenantId)

    $result = [pscustomobject]@{
        Name = $DisplayName
        ApplicationId = $app.appId
        ApplicationObjectId = $app.id
        ClientSecret = $null
        TenantId = $TenantId
        AuthType = $AuthType
        IsExistingServiceConnection = $false
        CreatedDuringSetup = $createdApplication
    }

    if ($AuthType -ne 'WIF') {
        # Create secret for traditional authentication
        Write-Host "Creating client secret..." -ForegroundColor Yellow
        $result.ClientSecret = New-EntraIdApplicationSecret -ApplicationObjectId $app.id -TenantId $TenantId
    }

    return $result
}

function Get-PowerPlatformSCCredential {
    <#
    .SYNOPSIS
    Interactively selects, creates or reuses deployment credentials for an environment.
    .NOTES
    Returns credential metadata, not necessarily a secret: existing endpoints can be
    represented by IsExistingServiceConnection with a null ClientSecret. Explicit
    rotation marks the credential for generation at Apply and clears that marker.
    Cached objects are reused; an existing environment credential is copied before
    rotation. Disabling extension mode limits new/manual choices to secret auth.
    Cancellation throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][array]$ExistingCredentials,
        [Parameter()][string]$TenantId,
        [Parameter()][string]$ProjectName,
        [Parameter()][string]$EnvironmentName,
        [Parameter()][bool]$UseAlm4DataverseExtension = $true,
        [Parameter()][object]$ExistingCredential
    )

    # 1. Try to find existing Service Connection to see if we can reuse its App ID
    $existingEndpoint = $null
    $existingScAppId = $null
    try {
        $endpoints = @(Get-VSTeamServiceEndpoint -ProjectName $ProjectName -ErrorAction Stop)
        $existingEndpoint = $endpoints | Where-Object { $_.name -eq $EnvironmentName } | Select-Object -First 1
        if ($existingEndpoint -and $existingEndpoint.authorization -and $existingEndpoint.authorization.parameters) {
            if ($existingEndpoint.authorization.parameters.PSObject.Properties.Name -contains 'applicationId') {
                $existingScAppId = $existingEndpoint.authorization.parameters.applicationId
            }
            elseif ($existingEndpoint.authorization.parameters.PSObject.Properties.Name -contains 'serviceprincipalid') {
                $existingScAppId = $existingEndpoint.authorization.parameters.serviceprincipalid
            }
        }
    }
    catch {
        if (-not (Test-SetupResourceNotFound -ErrorRecord $_)) { throw }
        Write-Verbose 'No service connection was found; continuing credential selection.'
    }

    if (-not $ExistingCredential -and $existingEndpoint -and -not [string]::IsNullOrWhiteSpace($existingScAppId)) {
        $existingAuthType = if ($existingEndpoint.authorization -and $existingEndpoint.authorization.scheme -eq 'WorkloadIdentityFederation') { 'WIF' } else { 'Secret' }
        $existingTenantId = $TenantId
        if ($existingEndpoint.authorization -and $existingEndpoint.authorization.parameters) {
            if ($existingEndpoint.authorization.parameters.PSObject.Properties.Name -contains 'tenantId' -and -not [string]::IsNullOrWhiteSpace($existingEndpoint.authorization.parameters.tenantId)) {
                $existingTenantId = $existingEndpoint.authorization.parameters.tenantId
            }
            elseif ($existingEndpoint.authorization.parameters.PSObject.Properties.Name -contains 'tenantid' -and -not [string]::IsNullOrWhiteSpace($existingEndpoint.authorization.parameters.tenantid)) {
                $existingTenantId = $existingEndpoint.authorization.parameters.tenantid
            }
        }

        $existingApplication = Resolve-EntraIdApplicationByAppId -ApplicationId $existingScAppId -TenantId $existingTenantId
        $ExistingCredential = [pscustomobject]@{
            Name                        = $(if ($existingApplication -and -not [string]::IsNullOrWhiteSpace($existingApplication.displayName)) { $existingApplication.displayName } else { "Existing-$EnvironmentName" })
            ApplicationId               = $existingScAppId
            ApplicationObjectId         = $(if ($existingApplication) { $existingApplication.id } else { $null })
            ClientSecret                = $null
            TenantId                    = $existingTenantId
            AuthType                    = $existingAuthType
            IsExistingServiceConnection = $true
            HasExistingSecret           = ($existingAuthType -eq 'Secret')
        }
    }

    # 2. Search Entra ID for relevant applications
    $foundApps = @()
    try {
        $graphToken = Get-AuthToken -ResourceUrl "https://graph.microsoft.com" -TenantId $TenantId
        $headers = @{ Authorization = "Bearer $($graphToken.AccessToken)" }

        # If we have an existing SC App ID, ensure it's in the list
        if ($existingScAppId) {
            $alreadyFound = $foundApps | Where-Object { $_.appId -eq $existingScAppId }
            if (-not $alreadyFound) {
                $filter = "appId eq '$existingScAppId'"
                $uri = "https://graph.microsoft.com/v1.0/applications?`$filter=$filter&`$select=appId,displayName,id"
                $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
                if ($response.value) {
                    $foundApps += $response.value
                }
            }
        }
    }
    catch {
        Write-Warning "Failed to list applications from Entra ID: $($_.Exception.Message)"
    }

    $menuItems = @()
    $menuActions = @() # To track what each item does

    if ($ExistingCredential -and -not [string]::IsNullOrWhiteSpace($ExistingCredential.ApplicationId)) {
        $existingLabel = "Use existing: $($ExistingCredential.Name) ($($ExistingCredential.ApplicationId))"
        if ($ExistingCredential.AuthType -eq 'Secret' -and $ExistingCredential.HasExistingSecret) {
            $existingLabel += ' [secret already configured]'
        }
        elseif ($ExistingCredential.AuthType -eq 'WIF') {
            $existingLabel += ' [workload identity federation]'
        }

        $menuItems += $existingLabel
        $menuActions += @{ Type = 'Existing'; Creds = $ExistingCredential }
    }

    # Recommend the application already bound to the existing service connection.
    $recommendedApp = $null

    if ($existingScAppId) {
        $recommendedApp = $foundApps | Where-Object { $_.appId -eq $existingScAppId } | Select-Object -First 1
    }

    if ($UseAlm4DataverseExtension -and $recommendedApp) {
        $menuItems += "Use existing: $($recommendedApp.displayName) ($($recommendedApp.appId))"
        $menuActions += @{ Type = 'ExistingSCApp'; App = $recommendedApp }

        # Remove from foundApps to avoid duplicate listing
        $foundApps = $foundApps | Where-Object { $_.appId -ne $recommendedApp.appId }
    }

    # Standard Options
    $menuItems += "Create new App Registration (Entra ID)"
    $menuActions += @{ Type = 'CreateNew' }

    $menuItems += "Enter existing Service Principal details"
    $menuActions += @{ Type = 'Manual' }

    # Cached Credentials
    foreach ($c in $ExistingCredentials) {
        $menuItems += "Reuse: $($c.Name) ($($c.ApplicationId))"
        $menuActions += @{ Type = 'Cached'; Creds = $c }
    }


    $selection = Select-FromMenu -Title "Select Service Principal credentials for '$EnvironmentName'" -Items $menuItems -PromptGuidanceLines @(
        'Service Principal credentials authenticate the pipeline to Dataverse.',
        'Use a separate App Registration per environment and prefer Workload Identity Federation when extension mode is enabled.',
        'Select existing credentials or create new Service Principal credentials for this environment.',
        'Prefer workload identity federation when available to reduce client secret management.'
    ) -PromptGuidanceDocRelativePath 'docs/config/azdo-environment-service-connection.md' -PromptGuidanceRef $ALM4DataverseRef
    if ($null -eq $selection) { throw "No credential selected." }

    $action = $menuActions[$selection]

    if ($action.Type -eq 'Existing') {
        $selectedCredential = $action.Creds.PSObject.Copy()

        if ($selectedCredential.AuthType -eq 'Secret' -and $selectedCredential.HasExistingSecret) {
            $secretHandlingItems = @(
                'Keep the existing client secret',
                'Generate a new client secret when changes are applied'
            )

            $secretHandlingSelection = Select-FromMenu -Title "How should setup handle the existing client secret for '$EnvironmentName'?" -Items $secretHandlingItems -PromptGuidanceLines @(
                'Choose whether to keep the existing secret or generate a new one when changes are applied.',
                'Rotation is deferred until Apply so the preview can list it before any credential changes.',
                'Rotate when policy requires renewal or when the existing secret is no longer trusted.'
            ) -PromptGuidanceDocRelativePath 'docs/config/azdo-environment-service-connection.md' -PromptGuidanceRef $ALM4DataverseRef
            if ($null -eq $secretHandlingSelection) {
                throw 'No client secret handling option selected.'
            }

            if ($secretHandlingSelection -eq 1) {
                if ([string]::IsNullOrWhiteSpace($selectedCredential.ApplicationObjectId)) {
                    $resolvedApplication = Resolve-EntraIdApplicationByAppId -ApplicationId $selectedCredential.ApplicationId -TenantId $selectedCredential.TenantId
                    if ($resolvedApplication) {
                        $selectedCredential.ApplicationObjectId = $resolvedApplication.id
                        if ([string]::IsNullOrWhiteSpace($selectedCredential.Name) -and -not [string]::IsNullOrWhiteSpace($resolvedApplication.displayName)) {
                            $selectedCredential.Name = $resolvedApplication.displayName
                        }
                    }
                }

                if ([string]::IsNullOrWhiteSpace($selectedCredential.ApplicationObjectId)) {
                    throw "Cannot generate a new client secret for '$($selectedCredential.ApplicationId)' because the App Registration object id could not be resolved."
                }

                # Defer the write to Apply so preview can list it and the user can
                # still change their mind before any credential is rotated.
                $selectedCredential | Add-Member -NotePropertyName RotateSecret -NotePropertyValue $true -Force
                Write-Host 'A new client secret will be generated when changes are applied.' -ForegroundColor Yellow
                $selectedCredential.IsExistingServiceConnection = $false
            }
            else {
                # Revisiting the step copies the previous credential, so clear any
                # rotation request the user has now declined.
                $selectedCredential | Add-Member -NotePropertyName RotateSecret -NotePropertyValue $false -Force
            }

            return $selectedCredential
        }

        return $selectedCredential
    }
    elseif ($action.Type -eq 'Cached') {
        return $action.Creds
    }
    elseif ($action.Type -eq 'CreateNew') {
        $authType = 'Secret'
        if ($UseAlm4DataverseExtension) {
            # Prompt for authentication type
            Write-Host ""
            $authTypeItems = @(
                "Workload Identity Federation (recommended, no secrets)",
                "Service Principal with Secret (traditional)"
            )
            $authTypeSelection = Select-FromMenu -Title "Select authentication type for the new service connection" -Items $authTypeItems -PromptGuidanceLines @(
                'Choose between workload identity federation and client-secret authentication.',
                'Workload identity federation is recommended when supported.'
            ) -PromptGuidanceDocRelativePath 'docs/config/azdo-environment-service-connection.md' -PromptGuidanceRef $ALM4DataverseRef
            if ($null -eq $authTypeSelection) { throw "No authentication type selected." }

            $authType = if ($authTypeSelection -eq 1) { 'Secret' } else { 'WIF' }
        }
        else {
            Write-Host "Using Service Principal with Secret authentication because ALM4Dataverse extension mode is disabled." -ForegroundColor Yellow
        }

        $appName = "$ProjectName - $EnvironmentName - deployment"

        if ($authType -eq 'WIF') {
            return New-EntraIdApplication `
                -DisplayName $appName `
                -TenantId $TenantId `
                -AuthType 'WIF'
        }
        else {
            return New-EntraIdApplication `
                -DisplayName $appName `
                -TenantId $TenantId `
                -AuthType 'Secret'
        }
    }
    elseif ($action.Type -eq 'ExistingSCApp') {
        if (-not $UseAlm4DataverseExtension) {
            throw "Reusing existing service connection credentials requires ALM4Dataverse extension mode. Enable extension mode or enter Service Principal details manually."
        }
        $app = $action.App
        Write-Host "Using existing service connection with App: $($app.displayName) ($($app.appId))" -ForegroundColor Cyan

        # Since the service connection already exists, we just return a marker object
        # The credentials are already configured in the existing service connection
        return [pscustomobject]@{
            Name = $app.displayName
            ApplicationId = $app.appId
            ApplicationObjectId = $app.id
            ClientSecret = $null
            TenantId = $TenantId
            AuthType = 'Unknown' # Existing SC, auth type already configured
            IsExistingServiceConnection = $true
        }
    }
    else { # Manual
        Write-Host "Enter Service Principal details:" -ForegroundColor Cyan
        $name = Read-TextWithDefault -Prompt 'Credential name (for reuse reference)' -AllowEmpty
        if ([string]::IsNullOrWhiteSpace($name)) { $name = "Credential-" + (Get-Date -Format "HHmm") }

        while ($true) {
            $appId = Read-TextWithDefault -Prompt 'Application ID (Client ID)'
            if ($appId -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
                break
            }
            else {
                Write-Warning "The Application ID must be a valid GUID. Please try again."
            }
        }

        $authType = 'Secret'
        if ($UseAlm4DataverseExtension) {
            # Prompt for authentication type
            Write-Host ""
            $authTypeItems = @(
                "Service Principal with Secret (traditional)",
                "Workload Identity Federation (recommended, no secrets)"
            )
            $authTypeSelection = Select-FromMenu -Title "Select authentication type" -Items $authTypeItems -PromptGuidanceLines @(
                'Choose the authentication mode for the supplied Service Principal details.',
                'Use secret-based auth only when workload identity federation is not the intended option.'
            ) -PromptGuidanceDocRelativePath 'docs/config/azdo-environment-service-connection.md' -PromptGuidanceRef $ALM4DataverseRef
            if ($null -eq $authTypeSelection) { throw "No authentication type selected." }

            $authType = if ($authTypeSelection -eq 0) { 'Secret' } else { 'WIF' }
        }
        else {
            Write-Host "Using Service Principal with Secret authentication because ALM4Dataverse extension mode is disabled." -ForegroundColor Yellow
        }

        $secret = $null
        if ($authType -eq 'Secret') {
            while ($true) {
                $secret = Read-SecretText -Prompt 'Client Secret'

                if ($secret -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
                    Write-Warning "The Client Secret looks like a GUID. You should enter the Secret VALUE, not the Secret ID."
                    if (Read-YesNo -Prompt "Are you sure this is the Secret Value?" -DefaultNo) {
                        break
                    }
                } else {
                    break
                }
            }
        }

        [void](Initialize-EntraIdServicePrincipal -ApplicationId $appId -TenantId $TenantId)

        return [pscustomobject]@{
            Name = $name
            ApplicationId = $appId
            ApplicationObjectId = $null
            ClientSecret = $secret
            TenantId = $TenantId
            AuthType = $authType
            IsExistingServiceConnection = $false
        }
    }
}

function Get-DataverseServiceAccountUPN {
    # Returns an existing/cached or manually entered ownership UPN; cancellation throws.
    # The manual check is format-only, not a directory, role or licensing verification.
    [CmdletBinding()]
    param(
        [Parameter()][array]$ExistingServiceAccounts,
        [Parameter()][string]$EnvironmentName,
        [Parameter()][string]$ExistingValue
    )

    $menuItems = @()
    $menuActions = @() # To track what each item does

    # Priority 1: Existing value from variable group (if provided)
    if (-not [string]::IsNullOrWhiteSpace($ExistingValue)) {
        $menuItems += "Use existing: $ExistingValue"
        $menuActions += @{ Type = 'Existing'; UPN = $ExistingValue }
    }

    # Standard Options
    $menuItems += "Enter a new service account UPN"
    $menuActions += @{ Type = 'Manual' }

    # Cached Service Accounts (exclude the existing value to avoid duplication)
    foreach ($sa in $ExistingServiceAccounts) {
        if ($sa -ne $ExistingValue) {
            $menuItems += "Reuse: $sa"
            $menuActions += @{ Type = 'Cached'; UPN = $sa }
        }
    }

    $selection = Select-FromMenu `
        -Title "Select Dataverse Service Account for '$EnvironmentName'" `
        -Items $menuItems `
        -PromptGuidanceLines @(
            'The service account owns flow activation and needs a license plus the System Administrator role.',
            'Keep it separate from a personal admin account so automation ownership stays stable.',
            "Choose the service account UPN that will own flow activation and runtime ownership for '$EnvironmentName'.",
            'Reusing an existing service account keeps ownership consistent across runs; entering a new one changes who owns activated processes.'
        ) `
        -PromptGuidanceDocRelativePath 'docs/config/azdo-environment-service-connection.md' `
        -PromptGuidanceRef $ALM4DataverseRef
    if ($null -eq $selection) { throw "No service account selected." }

    $action = $menuActions[$selection]

    if ($action.Type -eq 'Cached' -or $action.Type -eq 'Existing') {
        return $action.UPN
    }
    else { # Manual
        Write-Host ""
        Write-Host "IMPORTANT: The service account must be licenced with an appropriate D365/PowerApps/etc licence for your use-case." -ForegroundColor Yellow
        Write-Host ""

        while ($true) {
            $upn = Read-TextWithDefault -Prompt 'Service Account UPN (for example: serviceaccount@contoso.com)'
            if ([string]::IsNullOrWhiteSpace($upn)) {
                Write-Warning "Service Account UPN cannot be empty. Please try again."
                continue
            }
            # Basic UPN format validation
            if ($upn -match '^[^@]+@[^@]+\.[^@]+$') {
                return $upn
            }
            else {
                Write-Warning "The UPN does not appear to be in a valid UPN format. Please try again."
            }
        }
    }
}

function Get-AzDoVariableGroupByName {
    <#
    .SYNOPSIS
    Retrieves a variable group by name without applying VSTeam's user type decoration.
    .DESCRIPTION
    VSTeam 7.15.2 dereferences createdBy and modifiedBy while decorating results, but
    Azure DevOps can return either field as null. The raw request keeps the same lookup
    and error behavior without depending on optional user metadata.
    .PARAMETER ProjectName
    Azure DevOps project containing the variable group.
    .PARAMETER GroupName
    Name of the variable group to retrieve.
    .OUTPUTS
    The raw variable group object, or no output when no group matches.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$GroupName
    )

    $response = Invoke-VSTeamRequest `
        -Method GET `
        -ProjectName $ProjectName `
        -Area 'distributedtask' `
        -Resource 'variablegroups' `
        -Version '5.1-preview.1' `
        -QueryString @{ groupName = $GroupName } `
        -ErrorAction Stop

    return $response.value
}

function Initialize-AzDoVariableGroup {
    <#
    .SYNOPSIS
    Returns or creates a variable group and ensures locking plus optional deployment approval.
    .NOTES
    Variables seed new groups only; updates are handled separately. Only not-found
    lookup failures permit creation. Existing approval checks are not removed when
    RequireDeploymentApproval is false.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$GroupName,
        [Parameter(Mandatory)][hashtable]$Variables,
        [Parameter()][bool]$RequireDeploymentApproval = $true
    )

    $group = $null

    # Query the raw REST response because VSTeam's typed getter assumes user metadata is present.
    try {
        $existing = Get-AzDoVariableGroupByName -ProjectName $Project -GroupName $GroupName -ErrorAction Stop
        if ($existing) {
            Write-Host "Variable group '$GroupName' already exists (id: $($existing.id))."
            $group = $existing
        }
    }
    catch {
        if (-not (Test-SetupResourceNotFound -ErrorRecord $_)) { throw }
        Write-Verbose 'No variable group was found; continuing with creation.'
    }

    if (-not $group) {
        Write-Host "Creating variable group '$GroupName'..." -ForegroundColor Yellow

        $variablesPayload = @{}
        foreach ($k in $Variables.Keys) {
            $variablesPayload[$k] = @{ value = [string]$Variables[$k] }
        }

        $description = 'ALM4Dataverse environment variable group (created by setup-azdo.ps1)'
        $createPayload = @{
            name        = $GroupName
            description = $description
            type        = 'Vsts'
            variables   = $variablesPayload
        } | ConvertTo-Json -Depth 100

        # VSTeam's add command follows the POST with a typed GET that assumes user metadata exists.
        $created = Invoke-VSTeamRequest `
            -Method POST `
            -ProjectName $Project `
            -Area 'distributedtask' `
            -Resource 'variablegroups' `
            -Body $createPayload `
            -ContentType 'application/json' `
            -Version '5.1-preview.1' `
            -ErrorAction Stop

        if ($created -and $created.id) {
            $group = Get-AzDoVariableGroupByName -ProjectName $Project -GroupName $GroupName -ErrorAction Stop
            if (-not $group) {
                throw "Variable group '$GroupName' was created but could not be retrieved."
            }

            Write-Host "Created variable group '$GroupName' (id: $($created.id))."
        }
        else {
            throw "Azure DevOps did not return an ID when creating variable group '$GroupName'."
        }
    }

    if ($group -and $group.id) {
        Initialize-AzDoVariableGroupExclusiveLock -Organization $Organization -Project $Project -VariableGroupId $group.id -VariableGroupName $GroupName

        if ($RequireDeploymentApproval) {
            $envName = $GroupName -replace '^Environment-', ''
            $team = Initialize-AzDoDeploymentApproverTeam -ProjectName $Project -EnvironmentName $envName
            Initialize-AzDoVariableGroupApproval -Organization $Organization -Project $Project -VariableGroupId $group.id -VariableGroupName $GroupName -ApproverTeam $team

        }
    }

    return $group
}

function Update-AzDoVariableGroup {
    <#
    .SYNOPSIS
    Merges supplied string values over the existing group's values and submits an update.
    .NOTES
    Returns the pre-update group object on success, null on missing group or failure.
    Copies values only, not secret metadata; this helper is for setup's nonsecret
    environment variables. WhatIf skips lookup and mutation.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$GroupName,
        [Parameter(Mandatory)][hashtable]$Variables
    )

    if (-not $PSCmdlet.ShouldProcess("$ProjectName/$GroupName", 'Update Azure DevOps variable group')) { return }

    try {
        $group = Get-AzDoVariableGroupByName -ProjectName $ProjectName -GroupName $GroupName -ErrorAction SilentlyContinue
        if (-not $group) {
            Write-Warning "Variable group '$GroupName' not found. Cannot update."
            return $null
        }

        Write-Host "Updating variable group '$GroupName'..." -ForegroundColor DarkGray

        $variablesPayload = @{}

        # First, copy existing variables if the group has any
        if ($group.variables) {
            foreach ($key in $group.variables.PSObject.Properties.Name) {
                $variablesPayload[$key] = @{ value = $group.variables.$key.value }
            }
        }

        # Then add/update with new variables
        foreach ($k in $Variables.Keys) {
            $variablesPayload[$k] = @{ value = [string]$Variables[$k] }
        }

        $updatePayload = @{
            name        = $GroupName
            description = $group.description
            type        = 'Vsts'
            variables   = $variablesPayload
        } | ConvertTo-Json -Depth 100

        # VSTeam's update command also re-fetches and decorates the group after its PUT.
        Invoke-VSTeamRequest `
            -Method PUT `
            -ProjectName $ProjectName `
            -Area 'distributedtask' `
            -Resource 'variablegroups' `
            -Id ([string]$group.id) `
            -Body $updatePayload `
            -ContentType 'application/json' `
            -Version '5.1-preview.1' `
            -ErrorAction Stop | Out-Null

        Write-Host "Variable group '$GroupName' updated successfully."
        return $group
    }
    catch {
        Write-Warning "Failed to update variable group '$GroupName': $($_.Exception.Message)"
        return $null
    }
}

function Set-AzDoSharedRepositoryState {
    <#
    .SYNOPSIS
    Updates the selected shared repository and template source used by preview and apply.
    .DESCRIPTION
    Reuses the local scaffold when available; otherwise clones the selected repository.
    An unavailable configured repository also uses the upstream scaffold so setup can
    reach the menu and let the user select a replacement. An empty newly selected
    repository uses the upstream scaffold until its version-update step seeds it.
    Replaced temporary clones are removed after the new source is ready. Cloning and
    replacing the template source are gated by ShouldProcess.
    .PARAMETER RepositoryState
    Mutable selected repository and template-source state used by setup previews and apply.
    .PARAMETER Initialization
    Repository context returned by Initialize-AzDoProjectAndRepository.
    .PARAMETER AccessToken
    Bearer token used to authenticate shared and upstream repository clones.
    .PARAMETER UpstreamGitSource
    Git source used to seed template files when the selected repository is empty.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'AccessToken', Justification = 'Captured by the nested shared-repository clone script block.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'UpstreamGitSource', Justification = 'Captured by the nested upstream-template clone script block.')]
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$RepositoryState,
        [Parameter(Mandatory)][object]$Initialization,
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][string]$UpstreamGitSource
    )

    $selectedSharedRepository = Get-OptionalObjectPropertyValue -InputObject $Initialization -PropertyName 'SharedRepo'
    $selectedSharedRepositoryName = [string](Get-OptionalObjectPropertyValue -InputObject $Initialization -PropertyName 'SharedRepoName')
    $selectionError = [string](Get-OptionalObjectPropertyValue -InputObject $Initialization -PropertyName 'SharedRepositorySelectionError')
    if ($selectedSharedRepository -and [string]::IsNullOrWhiteSpace($selectedSharedRepositoryName)) {
        throw 'Shared repository initialization did not return a valid repository.'
    }
    if (-not $selectedSharedRepository -and [string]::IsNullOrWhiteSpace($selectionError)) {
        throw 'Shared repository initialization did not return a valid repository.'
    }
    if (-not $selectedSharedRepository -and [string]::IsNullOrWhiteSpace($selectedSharedRepositoryName)) {
        $selectedSharedRepositoryName = [string]$RepositoryState.Name
    }
    $preparationTarget = if ([string]::IsNullOrWhiteSpace($selectedSharedRepositoryName)) {
        'upstream templates'
    }
    else {
        $selectedSharedRepositoryName
    }
    if (-not $PSCmdlet.ShouldProcess($preparationTarget, 'Prepare shared-repository template source')) {
        return $RepositoryState
    }

    $newClonePath = $null
    $newCopyRoot = [string]$RepositoryState.CopyRoot
    if ([bool]$RepositoryState.UsesLocalCopyRoot) {
        if (-not (Test-Path -LiteralPath $newCopyRoot -PathType Container)) {
            throw "Local shared-repository template source was not found: $newCopyRoot"
        }
    }
    elseif (-not $selectedSharedRepository) {
        $newClonePath = Join-Path ([System.IO.Path]::GetTempPath()) ("ALM4Dataverse-UpstreamTemplates-" + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $newClonePath -Force | Out-Null
        try {
            Invoke-WithErrorHandling -OperationName 'Cloning upstream templates for shared repository selection' -StatusMessage 'Cloning upstream templates because the configured shared repository is unavailable...' -CaptureOutputInPanel -ScriptBlock {
                & git clone $UpstreamGitSource $newClonePath
                if ($LASTEXITCODE -ne 0) {
                    throw "Git clone of upstream templates failed with exit code $LASTEXITCODE"
                }
            } | Out-Null

            $newCopyRoot = Join-Path $newClonePath 'copy-to-your-repo'
            if (-not (Test-Path -LiteralPath $newCopyRoot -PathType Container)) {
                throw 'Upstream repository does not contain a copy-to-your-repo template directory.'
            }
        }
        catch {
            if ($newClonePath -and (Test-Path -LiteralPath $newClonePath)) {
                try {
                    Remove-Item -LiteralPath $newClonePath -Recurse -Force -ErrorAction Stop
                }
                catch {
                    Write-Verbose 'Could not remove the failed upstream template clone; continuing cleanup.'
                }
            }
            throw
        }
    }
    else {
        $repositoryRemoteUrl = [string](Get-OptionalObjectPropertyValue -InputObject $selectedSharedRepository -PropertyName 'remoteUrl')
        if ([string]::IsNullOrWhiteSpace($repositoryRemoteUrl)) {
            throw "Could not determine remoteUrl for repository '$selectedSharedRepositoryName'."
        }

        $newClonePath = Join-Path ([System.IO.Path]::GetTempPath()) ("ALM4Dataverse-SharedRepo-" + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $newClonePath -Force | Out-Null
        try {
            Invoke-WithErrorHandling -OperationName 'Cloning shared repository templates' -StatusMessage 'Cloning the shared repository to get template files...' -CaptureOutputInPanel -ScriptBlock {
                & git -c "http.extraheader=AUTHORIZATION: bearer $AccessToken" clone $repositoryRemoteUrl $newClonePath
                if ($LASTEXITCODE -ne 0) {
                    throw "Git clone of shared repository failed with exit code $LASTEXITCODE"
                }
            } | Out-Null

            $newCopyRoot = Join-Path $newClonePath 'copy-to-your-repo'
            if (-not (Test-Path -LiteralPath $newCopyRoot -PathType Container)) {
                $null = & git -C $newClonePath rev-parse --verify HEAD 2>$null
                $sharedRepositoryHasCommits = $LASTEXITCODE -eq 0
                if ($sharedRepositoryHasCommits) {
                    throw "Shared repository '$selectedSharedRepositoryName' does not contain a copy-to-your-repo template directory."
                }

                Remove-Item -LiteralPath $newClonePath -Recurse -Force -ErrorAction Stop
                $newClonePath = Join-Path ([System.IO.Path]::GetTempPath()) ("ALM4Dataverse-UpstreamTemplates-" + [guid]::NewGuid().ToString('n'))
                New-Item -ItemType Directory -Path $newClonePath -Force | Out-Null
                Invoke-WithErrorHandling -OperationName 'Cloning upstream templates' -StatusMessage 'Cloning upstream templates for the new shared repository...' -CaptureOutputInPanel -ScriptBlock {
                    & git clone $UpstreamGitSource $newClonePath
                    if ($LASTEXITCODE -ne 0) {
                        throw "Git clone of upstream templates failed with exit code $LASTEXITCODE"
                    }
                } | Out-Null

                $newCopyRoot = Join-Path $newClonePath 'copy-to-your-repo'
                if (-not (Test-Path -LiteralPath $newCopyRoot -PathType Container)) {
                    throw "Upstream repository does not contain a copy-to-your-repo template directory."
                }
            }
        }
        catch {
            if ($newClonePath -and (Test-Path -LiteralPath $newClonePath)) {
                try {
                    Remove-Item -LiteralPath $newClonePath -Recurse -Force -ErrorAction Stop
                }
                catch {
                    Write-Verbose 'Could not remove the failed shared repository clone; continuing cleanup.'
                }
            }
            throw
        }
    }

    $previousClonePath = [string]$RepositoryState.ClonePath
    $RepositoryState.Repository = $selectedSharedRepository
    $RepositoryState.Name = $selectedSharedRepositoryName
    $RepositoryState.Ref = [string]$Initialization.SharedRepositoryRef
    $RepositoryState.CopyRoot = $newCopyRoot
    $RepositoryState.ClonePath = $newClonePath
    if ($selectedSharedRepository) {
        $RepositoryState.ValidationError = ''
    }
    else {
        $RepositoryState.ValidationError = $selectionError
    }
    $script:repo = $selectedSharedRepository
    $script:sharedRepoName = $selectedSharedRepositoryName
    $script:sharedRepositoryRef = [string]$Initialization.SharedRepositoryRef
    $script:copyRoot = $newCopyRoot
    $script:sharedRepoClone = $newClonePath

    if (
        -not [string]::IsNullOrWhiteSpace($previousClonePath) -and
        $previousClonePath -ne $newClonePath -and
        (Test-Path -LiteralPath $previousClonePath)
    ) {
        try {
            Remove-Item -LiteralPath $previousClonePath -Recurse -Force -ErrorAction Stop
        }
        catch {
            Write-Verbose 'Could not remove the previous shared repository clone; continuing cleanup.'
        }
    }

    return $RepositoryState
}

function Initialize-AzDoAuthentication {
    <#
    .SYNOPSIS
        Authenticates Azure and returns the Azure DevOps access token.
    .DESCRIPTION
        Signs in with a browser when the host can open one and with a device code
        otherwise. HeadlessAccessToken skips all prompts and adapts a caller-supplied
        token to the standard result contract.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][string]$TenantId,
        [Parameter()][string]$HeadlessAccessToken
    )

    if (-not [string]::IsNullOrWhiteSpace($HeadlessAccessToken)) {
        $adoAccessToken = [pscustomobject]@{ Token = $HeadlessAccessToken }
        return [pscustomobject]@{
            AuthResult  = [pscustomobject]@{ AccessToken = $HeadlessAccessToken; TenantId = $TenantId }
            AccessToken = $adoAccessToken
            SecureToken = ConvertTo-SecureString -String $HeadlessAccessToken -AsPlainText -Force
        }
    }

    Write-Section -Message 'Authenticating'

    Write-Host "To enable automated setup setup, we need to authenticate with the necessary services." -ForegroundColor Green
    Write-Host ""
    Write-Host "When prompted, please log in with an account that has access to:" -ForegroundColor Green
    Write-Host "- Your Azure DevOps organization/project (PROJECT administrator role for existing project, ORGANISATION OWNER role if you want to create a new project)" -ForegroundColor Green
    Write-Host "- Your Dataverse DEV environment (SYSTEM ADMINISTRATOR role)" -ForegroundColor Green
    Write-Host ""

    $adoResourceUrl = '499b84ac-1321-427f-aa17-267ca6975798'
    $cachedAzureAccounts = @(Get-AuthToken -ResourceUrl $adoResourceUrl -TenantId $TenantId -ListAccountsOnly)
    $preferredAzureUsername = $null
    $forceAzureInteractive = $false

    if ($cachedAzureAccounts.Count -gt 0) {
        $azureAuthMenuItems = @($cachedAzureAccounts | ForEach-Object { "Use existing Azure login: $_" })
        $azureAuthMenuItems += "Sign in with a different Azure account"

        $azureAuthChoice = Select-FromMenu `
            -Title "Azure authentication" `
            -Items $azureAuthMenuItems `
            -PromptGuidanceLines @(
                'Choose whether to reuse an existing Azure login context or authenticate with a different identity.',
                'Use an identity with permissions to administer Azure DevOps resources and Dataverse setup prerequisites.'
            ) `
            -PromptGuidanceDocRelativePath 'docs/setup/azdo-automated-setup.md' `
            -PromptGuidanceRef $ALM4DataverseRef
        if ($null -eq $azureAuthChoice) {
            throw "No Azure authentication option selected."
        }

        if ($azureAuthChoice -lt $cachedAzureAccounts.Count) {
            $preferredAzureUsername = $cachedAzureAccounts[$azureAuthChoice]
        }
        else {
            $forceAzureInteractive = $true
            Wait-ForUserAcknowledgement -Message 'Open the browser for Azure authentication when you are ready.' -ContinueLabel 'Open browser'
        }
    }
    else {
        Wait-ForUserAcknowledgement -Message 'Open the browser for Azure authentication when you are ready.' -ContinueLabel 'Open browser'
    }

    $authResult = Invoke-WithErrorHandling -OperationName "Authentication" -ScriptBlock {
        $result = Get-AuthToken -ResourceUrl $adoResourceUrl -TenantId $TenantId -PreferredUsername $preferredAzureUsername -ForceInteractive:$forceAzureInteractive

        if (-not $result -or -not $result.AccessToken) {
            throw "Failed to acquire an Azure DevOps access token."
        }

        return $result
    }

    $adoAccessToken = [pscustomobject]@{ Token = $authResult.AccessToken }
    return [pscustomobject]@{
        AuthResult = $authResult
        AccessToken = $adoAccessToken
        SecureToken = ConvertTo-SecureString -String $adoAccessToken.Token -AsPlainText -Force
    }
}
function Get-DataverseSolutionsSelection {
    <#
    .SYNOPSIS
    Selects a DEV environment and an ordered list of its visible unmanaged user solutions.
    .OUTPUTS
    System.Management.Automation.PSCustomObject. Solutions (name/deployUnmanaged entries)
    and EnvironmentUrl; EnvironmentFriendlyName is present on selection-completion paths.
    .NOTES
    Existing config seeds only solutions still discoverable. An empty selection is a
    valid empty Solutions list; environment cancellation and connection failures throw.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][string]$ExistingConfigPath,
        [Parameter()][string]$ExistingEnvironmentUrl
    )

    try {
        # Select environment using the helper function
        $selectedEnv = Select-DataverseEnvironment `
            -Prompt "Select your DEV environment" `
            -PreferredUrl $ExistingEnvironmentUrl `
            -PromptGuidanceLines @(
                'Choose the DEV Dataverse environment used to discover unmanaged solutions for alm-config.psd1.',
                'Pick the environment that represents the source-controlled customization baseline.',
                'This environment supplies the solution list used by the selected branch.',
                'Solutions are stored in dependency order in alm-config.psd1.'
            ) `
            -PromptGuidanceDocRelativePath 'docs/config/alm-config.md' `
            -PromptGuidanceRef $ALM4DataverseRef
        if (-not $selectedEnv) {
            throw "No environment selected."
        }

        $devEnvUrl = ConvertTo-NormalizedEnvironmentUrl -Url $selectedEnv.Endpoints["WebApplication"]
        Write-Host "Selected environment: $($selectedEnv.FriendlyName) ($devEnvUrl)" -ForegroundColor Cyan

        Write-Host 'Authenticating to the selected DEV environment...' -ForegroundColor DarkGray
        $devAccessTokenCallback = Get-SetupAccessTokenCallback -ResourceUrl $devEnvUrl
        # Connect to the selected environment
        $connection = Invoke-WithSpectreStatus -Status 'Connecting to the selected DEV environment...' -ScriptBlock {
            Get-DataverseConnection -Url $devEnvUrl -AccessToken $devAccessTokenCallback
        }

        if (-not $connection) {
            throw "Failed to connect to Dataverse environment."
        }

        Write-Host "Connected to environment: $($connection.ConnectedOrgFriendlyName)"

        # Get all solutions (excluding system solutions)
        $allSolutions = Invoke-WithSpectreStatus -Status 'Retrieving unmanaged solutions from Dataverse...' -ScriptBlock {
            Get-DataverseRecord -Connection $connection -TableName 'solution' -Columns @('solutionid', 'uniquename', 'friendlyname', 'version', 'ismanaged', 'description') -FilterValues @{
                'isvisible' = $true
                'ismanaged' = $false
            }
        }

        if (-not $allSolutions -or $allSolutions.Count -eq 0) {
            Write-Host "No unmanaged solutions found in the environment." -ForegroundColor Yellow
            return [pscustomobject]@{ Solutions = @(); EnvironmentUrl = $devEnvUrl }
        }

        # Filter out system solutions and prepare for selection
        $userSolutions = $allSolutions | Where-Object {
            $_.uniquename -notmatch '^(Default|Active|Basic|msdyn_|ms|MicrosoftFlow|PowerPlatform)' -and
            $_.uniquename -ne 'System'
        } | Sort-Object friendlyname

        if (-not $userSolutions -or $userSolutions.Count -eq 0) {
            Write-Host "No user-created solutions found in the environment." -ForegroundColor Yellow
            return [pscustomobject]@{ Solutions = @(); EnvironmentUrl = $devEnvUrl }
        }

        $selectedSolutions = @()

        if ($ExistingConfigPath -and (Test-Path -LiteralPath $ExistingConfigPath)) {
            try {
                $existingConfig = Import-PowerShellDataFile -Path $ExistingConfigPath
                foreach ($existing in @($existingConfig.solutions)) {
                    $match = $userSolutions | Where-Object { $_.uniquename -eq $existing.name } | Select-Object -First 1
                    if ($match) {
                        $selectedSolutions += $match
                    }
                }
            }
            catch {
                Write-Warning "Failed to read existing alm-config.psd1 defaults: $($_.Exception.Message)"
            }
        }

        if ($selectedSolutions.Count -gt 0) {
            Write-Host "Pre-selected $($selectedSolutions.Count) solution(s) from existing configuration." -ForegroundColor Green
            Start-Sleep -Seconds 2
        }


        $selectedSolutions = @(Select-OrderedSolution -AvailableSolutions $userSolutions -InitiallySelectedSolutions $selectedSolutions)

        if ($selectedSolutions.Count -eq 0) {
            Write-Host "No solutions selected." -ForegroundColor Yellow
            return [pscustomobject]@{ Solutions = @(); EnvironmentUrl = $devEnvUrl; EnvironmentFriendlyName = $selectedEnv.FriendlyName }
        }

        Write-Host "Final selection:"
        foreach ($sol in $selectedSolutions) {
            Write-Host "  - $($sol.friendlyname) ($($sol.uniquename))"
        }

        # Convert to the format needed for alm-config.psd1
        $configSolutions = @()
        foreach ($sol in $selectedSolutions) {
            $configSolutions += @{
                name            = $sol.uniquename
                deployUnmanaged = $false
            }
        }

        return [pscustomobject]@{ Solutions = $configSolutions; EnvironmentUrl = $devEnvUrl; EnvironmentFriendlyName = $selectedEnv.FriendlyName }

    }
    catch {
        Write-Host "Error retrieving solutions from Dataverse: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

function Update-AlmConfigInWorkingTree {
    # Null Solutions preserves the list (discovery skipped); an empty array clears it.
    # Checker/baseline settings are always reconciled. Returns whether any helper changed
    # the file, or false under WhatIf; shared helpers preserve unrelated configuration.
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param(
        [Parameter()][AllowNull()][array]$Solutions,
        [Parameter(Mandatory)][bool]$BuildValidationEnabled,
        [Parameter()][AllowEmptyString()][string]$BuildValidationBaselineRelease = '',
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter()][System.Collections.IDictionary]$SetupSettings
    )

    if (-not $PSCmdlet.ShouldProcess($RepoRoot, 'Update ALM configuration')) { return $false }

    $configPath = Join-Path $RepoRoot 'alm-config.psd1'
    $templatePath = if ($script:SetupRepositoryRoot) { Join-Path $script:SetupRepositoryRoot 'copy-to-your-repo\alm-config.psd1' } else { $null }
    $solutionsChanged = $false
    if ($null -ne $Solutions) {
        $solutionsChanged = Set-AlmConfigSolutionsInFile -ConfigPath $configPath -Solutions @($Solutions) -CreateIfMissing -TemplatePath $templatePath
    }
    else {
        Write-Host 'Skipping solution list updates in alm-config.psd1 because solution selection was not run.' -ForegroundColor Yellow
    }
    if ($SetupSettings) {
        [void](Set-AlmConfigSetupSettingsInFile -ConfigPath $configPath -Settings $SetupSettings -CreateIfMissing -TemplatePath $templatePath)
    }
    $solutionCheckChanged = Set-AlmConfigSolutionCheckEnabledInFile -ConfigPath $configPath -Enabled $BuildValidationEnabled -CreateIfMissing -TemplatePath $templatePath
    $effectiveBaselineRelease = if ($SetupSettings) { '' } else { $BuildValidationBaselineRelease }
    $baselineChanged = Set-AlmConfigBuildValidationBaselineReleaseInFile -ConfigPath $configPath -BaselineRelease $effectiveBaselineRelease -CreateIfMissing -TemplatePath $templatePath
    $changed = ($solutionsChanged -or $solutionCheckChanged -or $baselineChanged)

    if ($changed) {
        Write-Host 'Updated alm-config.psd1 in the working tree.' -ForegroundColor Green
    }
    else {
        Write-Host 'No changes to alm-config.psd1; solutions already configured.' -ForegroundColor Green
    }

    return $changed
}

function Update-AzDoBuildPipelineInWorkingTree {
    <#
    .SYNOPSIS
    Writes the shared build-template invocation as pipelines/BUILD.yml.
    .NOTES
    Creates the file when the repository has no existing BUILD caller. The generated
    CI trigger includes every branch. BuildValidationEnvironments maps each source
    branch to its validation environment; BuildEnvironmentName remains a compatibility
    input when no map is supplied. This is a whole-file replacement, not a merge of
    custom YAML, except that an existing template-level secretVariables parameter block
    is carried over unchanged. The generated file starts with a notice that direct
    edits are unsupported, points at alm-config.psd1 plus setup, and passes the current
    shared template version.
    WhatIf skips the write.
    #>
        [CmdletBinding(SupportsShouldProcess = $true)]
        [OutputType([bool])]
        param(
                [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$SharedRepositoryName,
                [Parameter()][string]$SharedRepositoryRef = 'main',
                [Parameter(Mandatory)][AllowEmptyString()][string]$BuildEnvironmentName,
                [Parameter(Mandatory)][bool]$UseAlm4DataverseExtension,
                [Parameter()][System.Collections.IDictionary]$BuildValidationEnvironments = @{}
        )

        if (-not $PSCmdlet.ShouldProcess($RepoRoot, 'Update Azure DevOps BUILD pipeline')) { return $false }

        $buildPipelinePath = Join-Path $RepoRoot 'pipelines/BUILD.yml'

        $extensionLiteral = if ($UseAlm4DataverseExtension) { 'true' } else { 'false' }
        $escapedBuildEnvironmentName = ([string]$BuildEnvironmentName).Replace("'", "''")
        $escapedSharedRepositoryRef = ([string]$SharedRepositoryRef).Replace("'", "''")
        $templateVersion = Get-AlmSharedTemplateVersion
        $validationEnvironmentsJson = ConvertTo-Json -InputObject $BuildValidationEnvironments -Depth 5 -Compress

        $secretVariableBlock = Get-AzDoCallerSecretVariableBlock -Path $buildPipelinePath
        if ($secretVariableBlock) { $secretVariableBlock = [Environment]::NewLine + $secretVariableBlock }

        $newContent = @"
# Setup generates this file from alm-config.psd1: direct edits are not supported.
# Change alm-config.psd1, commit it, and apply it again (the APPLY-CONFIG pipeline
# or setup-azdo.ps1 -ApplyConfig) to regenerate this pipeline.

trigger:
  branches:
    include:
    - '*'  # Support any branch name

resources:
  repositories:
  - repository: ALM4Dataverse
    type: git
    name: $SharedRepositoryName
    ref: 'refs/heads/$escapedSharedRepositoryRef'

stages:
- template: pipelines/templates/build.yml@ALM4Dataverse
  parameters:
    useAlm4DataverseExtension: $extensionLiteral
    buildEnvironmentName: '$escapedBuildEnvironmentName'
    buildValidationEnvironments: $validationEnvironmentsJson
    sharedTemplateVersion: '$templateVersion'$secretVariableBlock
"@

        $buildPipelineDirectory = Split-Path -Parent $buildPipelinePath
        if (-not (Test-Path -LiteralPath $buildPipelineDirectory)) {
            New-Item -ItemType Directory -Path $buildPipelineDirectory -Force | Out-Null
        }
        Set-Content -LiteralPath $buildPipelinePath -Value $newContent.TrimStart("`r", "`n") -NoNewline
}

function Update-AzDoExportPipelineInWorkingTree {
    <#
    .SYNOPSIS
    Writes the shared export-template invocation as pipelines/EXPORT.yml.
    .NOTES
    Creates the file when the repository has no existing EXPORT caller. This is a
    whole-file replacement, not a merge of custom YAML, except that an existing
    template-level secretVariables parameter block is carried over unchanged. The
    generated file starts with a notice that direct edits are unsupported, points at
    alm-config.psd1 plus setup, and passes the current shared template version.
    WhatIf skips the write.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$SharedRepositoryName,
        [Parameter()][string]$SharedRepositoryRef = 'main',
        [Parameter()][bool]$UseAlm4DataverseExtension = $true
    )

    if (-not $PSCmdlet.ShouldProcess($RepoRoot, 'Update Azure DevOps EXPORT pipeline')) { return $false }

    $exportPipelinePath = Join-Path $RepoRoot 'pipelines/EXPORT.yml'

    $extensionLiteral = if ($UseAlm4DataverseExtension) { 'true' } else { 'false' }
    $escapedSharedRepositoryRef = ([string]$SharedRepositoryRef).Replace("'", "''")
    $templateVersion = Get-AlmSharedTemplateVersion

    $secretVariableBlock = Get-AzDoCallerSecretVariableBlock -Path $exportPipelinePath
    if ($secretVariableBlock) { $secretVariableBlock = [Environment]::NewLine + $secretVariableBlock }

    $newContent = @"
# Setup generates this file from alm-config.psd1: direct edits are not supported.
# Change alm-config.psd1, commit it, and apply it again (the APPLY-CONFIG pipeline
# or setup-azdo.ps1 -ApplyConfig) to regenerate this pipeline.

trigger: none # Run manually when you want to capture changes from dev
name: Export from Dev-`${{ variables['Build.SourceBranchName'] }}
appendCommitMessageToRunName: false

resources:
  repositories:
    - repository: ALM4Dataverse
      type: git
      name: $SharedRepositoryName
      ref: 'refs/heads/$escapedSharedRepositoryRef'

parameters:
- name: commitMessage
  type: string
  displayName: 'Commit message for exported changes'

variables:
# Keep the variable group and Dev service connection named for the selected branch.
# This convention uses Build.SourceBranchName, not the complete refs/heads/... ref.
- group: Environment-Dev-`${{ variables['Build.SourceBranchName'] }}

stages:
- template: pipelines/templates/export.yml@ALM4Dataverse
  parameters:
    commitMessage: `${{ parameters.commitMessage }}
    useAlm4DataverseExtension: $extensionLiteral
    sharedTemplateVersion: '$templateVersion'$secretVariableBlock
"@

    $exportPipelineDirectory = Split-Path -Parent $exportPipelinePath
    if (-not (Test-Path -LiteralPath $exportPipelineDirectory)) {
        New-Item -ItemType Directory -Path $exportPipelineDirectory -Force | Out-Null
    }
    Set-Content -LiteralPath $exportPipelinePath -Value $newContent.TrimStart("`r", "`n") -NoNewline
}

function Update-AzDoImportPipelineInWorkingTree {
    <#
    .SYNOPSIS
    Writes the shared import-template invocation as pipelines/IMPORT.yml.
    .NOTES
    Creates the file when the repository has no existing IMPORT caller. This is a
    whole-file replacement, not a merge of custom YAML, except that an existing
    template-level secretVariables parameter block is carried over unchanged. The
    generated file starts with a notice that direct edits are unsupported, points at
    alm-config.psd1 plus setup, and passes the current shared template version.
    WhatIf skips the write.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$SharedRepositoryName,
        [Parameter()][string]$SharedRepositoryRef = 'main',
        [Parameter()][bool]$UseAlm4DataverseExtension = $true
    )

    if (-not $PSCmdlet.ShouldProcess($RepoRoot, 'Update Azure DevOps IMPORT pipeline')) { return $false }

    $importPipelinePath = Join-Path $RepoRoot 'pipelines/IMPORT.yml'

    $extensionLiteral = if ($UseAlm4DataverseExtension) { 'true' } else { 'false' }
    $escapedSharedRepositoryRef = ([string]$SharedRepositoryRef).Replace("'", "''")
    $templateVersion = Get-AlmSharedTemplateVersion

    $secretVariableBlock = Get-AzDoCallerSecretVariableBlock -Path $importPipelinePath
    if ($secretVariableBlock) { $secretVariableBlock = [Environment]::NewLine + $secretVariableBlock }

    $newContent = @"
# Setup generates this file from alm-config.psd1: direct edits are not supported.
# Change alm-config.psd1, commit it, and apply it again (the APPLY-CONFIG pipeline
# or setup-azdo.ps1 -ApplyConfig) to regenerate this pipeline.

trigger: none # Run manually when you want to import changes from source control

name: Import to Dev-`${{ variables['Build.SourceBranchName'] }}

resources:
  repositories:
    - repository: ALM4Dataverse
      type: git
      name: $SharedRepositoryName
      ref: 'refs/heads/$escapedSharedRepositoryRef'

variables:
# Supplies branch-specific hook/settings values; the shared template chooses the
# matching Dev service connection and imports freshly built unmanaged packages.
- group: Environment-Dev-`${{ variables['Build.SourceBranchName'] }}

stages:
- template: pipelines/templates/import.yml@ALM4Dataverse
  parameters:
    useAlm4DataverseExtension: $extensionLiteral
    sharedTemplateVersion: '$templateVersion'$secretVariableBlock
"@

    $importPipelineDirectory = Split-Path -Parent $importPipelinePath
    if (-not (Test-Path -LiteralPath $importPipelineDirectory)) {
        New-Item -ItemType Directory -Path $importPipelineDirectory -Force | Out-Null
    }
    Set-Content -LiteralPath $importPipelinePath -Value $newContent.TrimStart("`r", "`n") -NoNewline
}

function Initialize-DataverseApplicationUser {
    # Ensure an app-ID systemuser and its root-business-unit System Administrator role.
    # Uses interactive tenant-scoped tokens, not the app's credentials; missing root BU,
    # role or connection throws. Existing user/role associations are retained.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EnvironmentUrl,
        [Parameter(Mandatory)][string]$ApplicationId,
        [Parameter(Mandatory)][string]$TenantId
    )

    Write-Host "Ensuring application user '$ApplicationId' exists in '$EnvironmentUrl'..." -ForegroundColor DarkGray

    $accessTokenCallback = Get-SetupAccessTokenCallback -ResourceUrl $EnvironmentUrl -TenantId $TenantId
    $conn = Get-DataverseConnection -Url $EnvironmentUrl -AccessToken $accessTokenCallback

    if (-not $conn) {
        throw "Failed to connect to Dataverse."
    }

    # 1. Get Root Business Unit
    $rootBu = Get-DataverseRecord -Connection $conn -TableName "businessunit" -FilterValues @{ parentbusinessunitid = $null } -Columns "businessunitid" | Select-Object -First 1
    if (-not $rootBu) { throw "Could not find root business unit." }
    $rootBuId = $rootBu.businessunitid

    # 2. Get System Administrator Role
    $roleName = "System Administrator"
    $role = Get-DataverseRecord -Connection $conn -TableName "role" -FilterValues @{ name = $roleName; businessunitid = $rootBuId } -Columns "roleid" | Select-Object -First 1
    if (-not $role) { throw "Could not find '$roleName' role in root business unit." }
    $roleId = $role.roleid

    # 3. Check/Create System User
    $user = Get-DataverseRecord -Connection $conn -TableName "systemuser" -FilterValues @{ applicationid = $ApplicationId } -Columns "systemuserid" | Select-Object -First 1
    $userId = $null

    if ($user) {
        Write-Host "User already exists. ID: $($user.systemuserid)"
        $userId = $user.systemuserid
    }
    else {
        Write-Host "Creating application user..."
        $userAttributes = @{
            "applicationid" = $ApplicationId
            "businessunitid" = $rootBuId
        }
        $createdUser = $userAttributes | Set-DataverseRecord -Connection $conn -TableName "systemuser" -CreateOnly -PassThru
        $userId = $createdUser.Id
        Write-Host "User created. ID: $userId"
    }

    # 4. Associate User with Role
    $existingAssociation = Get-DataverseRecord -Connection $conn -TableName "systemuserroles" -FilterValues @{ systemuserid = $userId; roleid = $roleId } -Top 1
    if (-not $existingAssociation) {
        Write-Host "Associating user with '$roleName' role..."
        @{
            systemuserid = $userId
            roleid = $roleId
        } | Set-DataverseRecord -Connection $conn -TableName "systemuserroles" -CreateOnly
        Write-Host "Association successful."
    }
    else {
        Write-Host "User is already associated with '$roleName' role."
    }
}

function Initialize-DataverseServiceAccountUser {
    # Resolve/create the UPN systemuser in the root BU and add System Administrator
    # if absent. This provisions Dataverse records/roles, not an Entra account or license.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EnvironmentUrl,
        [Parameter(Mandatory)][string]$ServiceAccountUPN,
        [Parameter(Mandatory)][string]$TenantId
    )

    Write-Host "Ensuring service account '$ServiceAccountUPN' has System Administrator role in '$EnvironmentUrl'..." -ForegroundColor DarkGray

    $accessTokenCallback = Get-SetupAccessTokenCallback -ResourceUrl $EnvironmentUrl -TenantId $TenantId
    $conn = Get-DataverseConnection -Url $EnvironmentUrl -AccessToken $accessTokenCallback

    if (-not $conn) {
        throw "Failed to connect to Dataverse."
    }

    # 1. Get Root Business Unit
    $rootBu = Get-DataverseRecord -Connection $conn -TableName "businessunit" -FilterValues @{ parentbusinessunitid = $null } -Columns "businessunitid" | Select-Object -First 1
    if (-not $rootBu) { throw "Could not find root business unit." }
    $rootBuId = $rootBu.businessunitid

    # 2. Get System Administrator Role
    $roleName = "System Administrator"
    $role = Get-DataverseRecord -Connection $conn -TableName "role" -FilterValues @{ name = $roleName; businessunitid = $rootBuId } -Columns "roleid" | Select-Object -First 1
    if (-not $role) { throw "Could not find '$roleName' role in root business unit." }
    $roleId = $role.roleid

    # 3. Find the System User by UPN
    $user = Get-DataverseRecord -Connection $conn -TableName "systemuser" -FilterValues @{
        domainname = $ServiceAccountUPN
    } -Columns "systemuserid","fullname" | Select-Object -First 1

    $userId = $null
    if ($user) {
        $userId = $user.systemuserid
        Write-Host "Found service account user: $($user.fullname) (ID: $userId)"
    }
    else {
        Write-Host "Service account user '$ServiceAccountUPN' not found. Creating..."
        $userAttributes = @{
            "domainname" = $ServiceAccountUPN
            "businessunitid" = $rootBuId
            "internalemailaddress" = $ServiceAccountUPN
            "firstname" = "Service"
            "lastname" = "Account"
        }
        $createdUser = $userAttributes | Set-DataverseRecord -Connection $conn -TableName "systemuser" -CreateOnly -PassThru
        $userId = $createdUser.Id
        Write-Host "Service account user created. ID: $userId"
    }

    # 4. Associate User with Role
    $existingAssociation = Get-DataverseRecord -Connection $conn -TableName "systemuserroles" -FilterValues @{ systemuserid = $userId; roleid = $roleId } -Top 1
    if (-not $existingAssociation) {
        Write-Host "Associating service account with '$roleName' role..."
        @{
            systemuserid = $userId
            roleid = $roleId
        } | Set-DataverseRecord -Connection $conn -TableName "systemuserroles" -CreateOnly
        Write-Host "Association successful."
    }
    else {
        Write-Host "Service account is already associated with '$roleName' role."
    }
}

function Get-ExistingEnvironmentsFromWorkingTree {
    [CmdletBinding()]
    [OutputType([string], [object[]])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch
    )

    return @(Get-AzDoDeploymentEnvironmentNamesFromWorkingTree -RepoRoot $RepoRoot -Branch $Branch)
}

function Get-AzDoExistingEnvironmentServiceAccountUPN {
    # Best-effort discovery: missing groups/variables and lookup failures all yield null.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$EnvironmentName
    )

    try {
        $existingVarGroup = Get-AzDoVariableGroupByName -ProjectName $ProjectName -GroupName "Environment-$EnvironmentName" -ErrorAction SilentlyContinue
        if ($existingVarGroup -and $existingVarGroup.variables -and $existingVarGroup.variables.PSObject.Properties.Name -contains 'DataverseServiceAccountUPN') {
            return $existingVarGroup.variables.DataverseServiceAccountUPN.value
        }
    }
    catch {
        return $null
    }

    return $null
}

function Get-AzDoExistingEnvironmentState {
    <#
    .SYNOPSIS
    Reconstructs environment URL, ownership and credential metadata from existing Azure DevOps resources.
    .NOTES
    Returns null only when URL, credentials and service-account UPN are all unavailable;
    otherwise fields can be partial. Endpoint tenant overrides the supplied hint.
    Secret values are not read: HasExistingSecret marks the configured authentication
    scheme, while ClientSecret remains null for subsequent keep-or-rotate selection.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter()][string]$TenantId
    )

    $serviceAccountUPN = Get-AzDoExistingEnvironmentServiceAccountUPN -ProjectName $ProjectName -EnvironmentName $EnvironmentName
    $endpoint = $null
    try {
        $endpoints = @(Get-VSTeamServiceEndpoint -ProjectName $ProjectName -ErrorAction SilentlyContinue)
        $endpoint = $endpoints | Where-Object { $_.name -eq $EnvironmentName } | Select-Object -First 1
    }
    catch {
        $endpoint = $null
    }

    $credentials = $null
    $environmentUrl = $null
    $friendlyName = $EnvironmentName
    if ($endpoint) {
        $environmentUrl = ConvertTo-NormalizedEnvironmentUrl -Url $endpoint.url
        $friendlyName = Resolve-DataverseEnvironmentFriendlyName -EnvironmentUrl $environmentUrl -FallbackName $EnvironmentName

        $applicationId = $null
        $resolvedTenantId = $TenantId
        if ($endpoint.authorization -and $endpoint.authorization.parameters) {
            if ($endpoint.authorization.parameters.PSObject.Properties.Name -contains 'applicationId') {
                $applicationId = $endpoint.authorization.parameters.applicationId
            }
            elseif ($endpoint.authorization.parameters.PSObject.Properties.Name -contains 'serviceprincipalid') {
                $applicationId = $endpoint.authorization.parameters.serviceprincipalid
            }

            if ($endpoint.authorization.parameters.PSObject.Properties.Name -contains 'tenantId' -and -not [string]::IsNullOrWhiteSpace($endpoint.authorization.parameters.tenantId)) {
                $resolvedTenantId = $endpoint.authorization.parameters.tenantId
            }
            elseif ($endpoint.authorization.parameters.PSObject.Properties.Name -contains 'tenantid' -and -not [string]::IsNullOrWhiteSpace($endpoint.authorization.parameters.tenantid)) {
                $resolvedTenantId = $endpoint.authorization.parameters.tenantid
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($applicationId)) {
            $application = Resolve-EntraIdApplicationByAppId -ApplicationId $applicationId -TenantId $resolvedTenantId
            $authType = if ($endpoint.authorization -and $endpoint.authorization.scheme -eq 'WorkloadIdentityFederation') { 'WIF' } else { 'Secret' }

            $credentials = [pscustomobject]@{
                Name                        = $(if ($application -and -not [string]::IsNullOrWhiteSpace($application.displayName)) { $application.displayName } else { "Existing-$EnvironmentName" })
                ApplicationId               = $applicationId
                ApplicationObjectId         = $(if ($application) { $application.id } else { $null })
                ClientSecret                = $null
                TenantId                    = $resolvedTenantId
                AuthType                    = $authType
                IsExistingServiceConnection = $true
                HasExistingSecret           = ($authType -eq 'Secret')
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($environmentUrl) -and -not $credentials -and [string]::IsNullOrWhiteSpace($serviceAccountUPN)) {
        return $null
    }

    return [pscustomobject]@{
        ShortName         = $EnvironmentName
        FriendlyName      = $friendlyName
        Url               = $environmentUrl
        Credentials       = $credentials
        ServiceAccountUPN = $serviceAccountUPN
    }
}

function Get-GitRepoFileContentFromRemoteBranch {
    # Inspect fetched origin first, then local branch without checkout or network fetch.
    # Missing refs/files and whitespace-only content share the null sentinel.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$RelativePath
    )

    $normalizedPath = $RelativePath.Replace('\\', '/')
    $normalizedBranch = ConvertTo-NormalizedGitBranchName -Branch $Branch
    $candidateRefs = @("origin/$normalizedBranch", $normalizedBranch) | Select-Object -Unique
    foreach ($candidateRef in $candidateRefs) {
        & git -C $RepoRoot rev-parse --verify --quiet "${candidateRef}^{commit}" 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            continue
        }

        $content = (& git -C $RepoRoot show "${candidateRef}:${normalizedPath}" 2>$null | Out-String)
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($content)) {
            return $content
        }
    }

    return $null
}

function ConvertTo-NormalizedGitBranchName {
    # Strip repeated origin/ tracking prefixes only; refs/heads is not normalized here.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Branch
    )

    $normalizedBranch = [string]$Branch
    while ($normalizedBranch -match '^origin/(.+)$') {
        $normalizedBranch = [string]$Matches[1]
    }

    return $normalizedBranch.Trim()
}

function Resolve-GitExistingBranchRef {
    # Return the first commit-resolving origin/local ref, or null; does not fetch.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch
    )

    $normalizedBranch = ConvertTo-NormalizedGitBranchName -Branch $Branch
    if ([string]::IsNullOrWhiteSpace($normalizedBranch)) {
        return $null
    }

    $candidateRefs = @("origin/$normalizedBranch", $normalizedBranch)
    foreach ($candidateRef in $candidateRefs) {
        & git -C $RepoRoot rev-parse --verify --quiet "${candidateRef}^{commit}" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            return $candidateRef
        }
    }

    return $null
}

function Get-AzDoDeploymentEnvironmentNamesFromPipelineContent {
    # Scaffold-only line parsing: distinct literal environmentName values in encounter
    # order, or no output for empty content. YAML expressions/structure are not evaluated.
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter()][string]$PipelineContent
    )

    if ([string]::IsNullOrWhiteSpace($PipelineContent)) {
        return @()
    }

    $envMatches = [regex]::Matches($PipelineContent, '(?mi)^\s*environmentName:\s*([^\s\r\n]+)\s*$')
    $environmentNames = @()
    foreach ($envMatch in $envMatches) {
        $environmentName = $envMatch.Groups[1].Value.Trim().Trim('"', "'")
        if (-not [string]::IsNullOrWhiteSpace($environmentName) -and $environmentNames -notcontains $environmentName) {
            $environmentNames += $environmentName
        }
    }

    return @($environmentNames)
}

function Get-AzDoBuildEnvironmentNameFromPipelineContent {
    # Return the first buildEnvironmentName scalar, trimming optional quotes/whitespace;
    # missing or empty association is null, not a default BUILD environment.
    [CmdletBinding()]
    param(
        [Parameter()][string]$PipelineContent
    )

    if ([string]::IsNullOrWhiteSpace($PipelineContent)) {
        return $null
    }

    $match = [regex]::Match($PipelineContent, '(?mi)^\s*buildEnvironmentName\s*:\s*[''\"]?(?<name>[^''\"\r\n]*)[''\"]?\s*$')
    if (-not $match.Success) {
        return $null
    }

    $value = [string]$match.Groups['name'].Value
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    return $value.Trim()
}

function Get-AzDoDeployPipelineBranchMappingsFromRepoClone {
    # Inspects fetched origin branches for DEPLOY YAML. BranchName comes from the filename;
    # SourceBranch is where that file was found. Duplicate copies collapse by BranchName.
    [CmdletBinding()]
    [OutputType([pscustomobject], [object[]])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $branchRefs = @(& git -C $RepoRoot for-each-ref --format='%(refname:short)' refs/remotes/origin 2>$null)
    $branches = @($branchRefs | ForEach-Object {
        ConvertTo-NormalizedGitBranchName -Branch ([string]$_)
    } | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and $_ -ne 'HEAD' -and $_ -ne 'origin'
    } | Select-Object -Unique)

    $mappings = @()
    foreach ($branch in $branches) {
        $branchRef = Resolve-GitExistingBranchRef -RepoRoot $RepoRoot -Branch $branch
        if ([string]::IsNullOrWhiteSpace($branchRef)) {
            continue
        }

        $pipelineFiles = @(& git -C $RepoRoot ls-tree -r --name-only $branchRef 'pipelines' 2>$null)
        foreach ($pipelineFile in $pipelineFiles) {
            if ($pipelineFile -notmatch '^pipelines/DEPLOY-(.+)\.yml$') {
                continue
            }

            $pipelineContent = Get-GitRepoFileContentFromRemoteBranch -RepoRoot $RepoRoot -Branch $branch -RelativePath $pipelineFile
            $mappings += [pscustomobject]@{
                BranchName       = [string]$Matches[1]
                SourceBranch     = $branch
                PipelinePath     = $pipelineFile
                EnvironmentNames = @(Get-AzDoDeploymentEnvironmentNamesFromPipelineContent -PipelineContent $pipelineContent)
            }
        }
    }

    return @($mappings | Sort-Object BranchName -Unique)
}

function Get-AzDoRegisteredDeployPipelineBranch {
    # Include branches named by project build definitions even if clone discovery misses
    # their YAML; DEPLOY definition names take precedence over their YAML filename.
    [CmdletBinding()]
    [OutputType([string], [object[]])]
    param(
        [Parameter(Mandatory)][string]$ProjectName
    )

    $branches = @()
    $definitions = @(Get-VSTeamBuildDefinition -ProjectName $ProjectName)
    foreach ($definition in @($definitions)) {
        if ($definition.name -match '^DEPLOY-(.+)$') {
            $branchName = [string]$Matches[1]
            if (-not [string]::IsNullOrWhiteSpace($branchName) -and $branches -notcontains $branchName) {
                $branches += $branchName
            }
        }
        elseif ($definition.process -and $definition.process.PSObject.Properties.Name -contains 'yamlFilename' -and $definition.process.yamlFilename -match '^pipelines/DEPLOY-(.+)\.yml$') {
            $branchName = [string]$Matches[1]
            if (-not [string]::IsNullOrWhiteSpace($branchName) -and $branches -notcontains $branchName) {
                $branches += $branchName
            }
        }
    }

    return @($branches | Sort-Object -Unique)
}

function Get-AzDoLegacyConfigurationConversion {
    # Derives branches from committed pipelines and registered DEPLOY definitions for
    # projects whose alm-config.psd1 has no branches map. Without legacy evidence the
    # repository is treated as new. Failures return Status Failed so setup can continue.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$DefaultBranch,
        [Parameter()][string]$TenantId,
        [Parameter()][string]$LegacyBaselineRelease = ''
    )

    try {
        $deployMappings = @(Get-AzDoDeployPipelineBranchMappingsFromRepoClone -RepoRoot $RepoRoot)
        $registeredBranches = @(Get-AzDoRegisteredDeployPipelineBranch -ProjectName $ProjectName)
        $defaultBuildContent = Get-GitRepoFileContentFromRemoteBranch -RepoRoot $RepoRoot -Branch $DefaultBranch -RelativePath 'pipelines/BUILD.yml'
        $defaultBuildEnvironmentName = Get-AzDoBuildEnvironmentNameFromPipelineContent -PipelineContent $defaultBuildContent

        if ($deployMappings.Count -eq 0 -and $registeredBranches.Count -eq 0 -and [string]::IsNullOrWhiteSpace($defaultBuildEnvironmentName)) {
            return [pscustomobject]@{ Status = 'NotRequired'; BranchNames = @(); ErrorMessage = ''; Branches = @{} }
        }

        $branchNames = @($DefaultBranch) + @($deployMappings | ForEach-Object { $_.BranchName }) + $registeredBranches | Select-Object -Unique
        $branchFacts = @()
        foreach ($branchName in $branchNames) {
            $deployMapping = $deployMappings | Where-Object { $_.BranchName -ieq $branchName } | Select-Object -First 1

            $buildEnvironmentName = $defaultBuildEnvironmentName
            if ($branchName -ine $DefaultBranch) {
                $buildContent = Get-GitRepoFileContentFromRemoteBranch -RepoRoot $RepoRoot -Branch $branchName -RelativePath 'pipelines/BUILD.yml'
                $buildEnvironmentName = Get-AzDoBuildEnvironmentNameFromPipelineContent -PipelineContent $buildContent
            }

            # The default branch always receives Dev-<default>; other branches only count if
            # that environment exists, so an unused name is not reintroduced.
            $devEnvironmentName = "Dev-$DefaultBranch"
            if ($branchName -ine $DefaultBranch) {
                $devEnvironmentName = ''
                if (Get-AzDoExistingEnvironmentState -ProjectName $ProjectName -EnvironmentName "Dev-$branchName" -TenantId $TenantId) {
                    $devEnvironmentName = "Dev-$branchName"
                }
            }

            $branchFacts += [pscustomobject]@{
                BranchName                 = $branchName
                DevEnvironmentName         = $devEnvironmentName
                DeploymentEnvironmentNames = @(if ($deployMapping) { $deployMapping.EnvironmentNames } else { @() })
                BuildEnvironmentName       = $(if ($null -eq $buildEnvironmentName) { '' } else { [string]$buildEnvironmentName })
            }
        }

        $branches = ConvertTo-AlmLegacyBranchConfiguration -BranchFacts $branchFacts -LegacyBaselineRelease $LegacyBaselineRelease
        return [pscustomobject]@{
            Status       = 'Converted'
            BranchNames  = @($branches.Keys | Sort-Object)
            ErrorMessage = ''
            Branches     = $branches
        }
    }
    catch {
        return [pscustomobject]@{ Status = 'Failed'; BranchNames = @(); ErrorMessage = $_.Exception.Message; Branches = @{} }
    }
}

function Get-AzDoRepositoryExistingSetupState {
    <#
    .SYNOPSIS
    Builds branch/environment setup defaults from alm-config.psd1 and optional remote state.
    .OUTPUTS
    System.Management.Automation.PSCustomObject. BranchStates plus default-branch BUILD
    validation flag, environment name and provider environment metadata.
    .NOTES
    Pipeline YAML and registered pipeline definitions are not configuration sources once
    alm-config.psd1 has a branches map. Legacy repositories without one are converted once
    from those sources in interactive setup; ApplyConfig skips the conversion and remote lookups.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$DefaultBranch,
        [Parameter()][string]$TenantId,
        [Parameter()][switch]$SkipProviderState
    )

    $committedConfigContent = Get-GitRepoFileContentFromRemoteBranch -RepoRoot $RepoRoot -Branch $DefaultBranch -RelativePath 'alm-config.psd1'
    $existingConfiguration = ConvertFrom-AlmConfigContentForSetup -ConfigContent ([string]$committedConfigContent)
    $configuredProvider = [string](Get-OptionalObjectPropertyValue -InputObject $existingConfiguration -PropertyName 'provider')
    if (-not [string]::IsNullOrWhiteSpace($configuredProvider) -and $configuredProvider -ine 'azDO') {
        throw "alm-config.psd1 specifies provider '$configuredProvider'; use the matching setup script."
    }

    $legacyConfigurationConversion = [pscustomobject]@{ Status = 'NotRequired'; BranchNames = @(); ErrorMessage = '' }
    $needsLegacyConversion = -not $SkipProviderState -and (-not $existingConfiguration.Contains('branches') -or ($existingConfiguration.branches -is [System.Collections.IDictionary] -and $existingConfiguration.branches.Count -eq 0))
    if ($needsLegacyConversion) {
        $legacyBaselineRelease = [string](Get-OptionalObjectPropertyValue -InputObject (Get-OptionalObjectPropertyValue -InputObject $existingConfiguration -PropertyName 'buildValidation') -PropertyName 'baselineRelease')
        $legacyConfigurationConversion = Get-AzDoLegacyConfigurationConversion -RepoRoot $RepoRoot -ProjectName $ProjectName -DefaultBranch $DefaultBranch -TenantId $TenantId -LegacyBaselineRelease $legacyBaselineRelease
        if ($legacyConfigurationConversion.Status -eq 'Converted') {
            $existingConfiguration['branches'] = $legacyConfigurationConversion.Branches
        }
    }

    $hasConfiguredBranches = $existingConfiguration.Contains('branches')
    if ($hasConfiguredBranches) {
        if ($existingConfiguration.branches -isnot [System.Collections.IDictionary]) {
            throw 'The branches setting in alm-config.psd1 must be a hashtable keyed by branch name.'
        }
    }

    if ($hasConfiguredBranches -and $existingConfiguration.branches.Count -gt 0) {
        $branchStates = @()
        $defaultBranchState = $null
        foreach ($branchName in @($existingConfiguration.branches.Keys | Sort-Object)) {
            $branchConfiguration = Get-AlmSetupBranchConfiguration -Config $existingConfiguration -BranchName ([string]$branchName)
            $devEnvironmentName = ''
            if ($branchConfiguration.Contains('developmentEnvironment')) {
                if ($branchConfiguration.developmentEnvironment -isnot [string]) {
                    throw "The developmentEnvironment setting for branch '$branchName' must be a string."
                }
                $devEnvironmentName = [string]$branchConfiguration.developmentEnvironment
            }

            $existingDevEnvironment = $null
            if (-not [string]::IsNullOrWhiteSpace($devEnvironmentName)) {
                if (-not $SkipProviderState) {
                    $existingDevEnvironment = Get-AzDoExistingEnvironmentState -ProjectName $ProjectName -EnvironmentName $devEnvironmentName -TenantId $TenantId
                }
                if (-not $existingDevEnvironment) {
                    $existingDevEnvironment = [pscustomobject]@{
                        ShortName         = $devEnvironmentName
                        FriendlyName      = $devEnvironmentName
                        Url               = $null
                        Credentials       = $null
                        ServiceAccountUPN = $null
                    }
                }
            }

            $deploymentEnvironmentNames = @()
            if ($branchConfiguration.Contains('deploymentEnvironments') -and $null -ne $branchConfiguration.deploymentEnvironments) {
                if ($branchConfiguration.deploymentEnvironments -isnot [array]) {
                    throw "The deploymentEnvironments setting for branch '$branchName' must be an array of environment names."
                }
                $deploymentEnvironmentNames = @($branchConfiguration.deploymentEnvironments)
            }
            $deploymentEnvironments = @()
            foreach ($environmentName in $deploymentEnvironmentNames) {
                if ($environmentName -isnot [string] -or [string]::IsNullOrWhiteSpace($environmentName)) {
                    throw "The deploymentEnvironments setting for branch '$branchName' must contain non-empty environment names."
                }
                $environmentState = $null
                if (-not $SkipProviderState) {
                    $environmentState = Get-AzDoExistingEnvironmentState -ProjectName $ProjectName -EnvironmentName $environmentName -TenantId $TenantId
                }
                if (-not $environmentState) {
                    $environmentState = [pscustomobject]@{
                        ShortName         = $environmentName
                        FriendlyName      = $environmentName
                        Url               = $null
                        Credentials       = $null
                        ServiceAccountUPN = $null
                    }
                }
                $deploymentEnvironments += $environmentState
            }

            $buildValidationConfiguration = @{}
            if ($branchConfiguration.Contains('buildValidation') -and $null -ne $branchConfiguration.buildValidation) {
                if ($branchConfiguration.buildValidation -isnot [System.Collections.IDictionary]) {
                    throw "The buildValidation setting for branch '$branchName' must be a hashtable."
                }
                $buildValidationConfiguration = $branchConfiguration.buildValidation
            }

            $buildEnvironmentName = ''
            if ($buildValidationConfiguration.Contains('environmentName')) {
                if ($buildValidationConfiguration.environmentName -isnot [string]) {
                    throw "The buildValidation.environmentName setting for branch '$branchName' must be a string."
                }
                $buildEnvironmentName = [string]$buildValidationConfiguration.environmentName
            }
            $buildValidationBaselineRelease = ''
            if ($buildValidationConfiguration.Contains('baselineRelease')) {
                $buildValidationBaselineRelease = [string]$buildValidationConfiguration.baselineRelease
            }
            $existingBuildValidationEnvironment = $null
            if (-not [string]::IsNullOrWhiteSpace($buildEnvironmentName)) {
                if (-not $SkipProviderState) {
                    $existingBuildValidationEnvironment = Get-AzDoExistingEnvironmentState -ProjectName $ProjectName -EnvironmentName $buildEnvironmentName -TenantId $TenantId
                }
                if (-not $existingBuildValidationEnvironment) {
                    $existingBuildValidationEnvironment = [pscustomobject]@{
                        ShortName         = $buildEnvironmentName
                        FriendlyName      = $buildEnvironmentName
                        Url               = $null
                        Credentials       = $null
                        ServiceAccountUPN = $null
                    }
                }
            }

            $branchState = [pscustomobject]@{
                BranchName                         = [string]$branchName
                ExistingDevEnvironment             = $existingDevEnvironment
                DeploymentEnvironments             = @($deploymentEnvironments)
                ExistingBuildValidationEnvironment = $existingBuildValidationEnvironment
                BuildValidationEnvironmentName     = $buildEnvironmentName
                BuildValidationBaselineRelease     = $buildValidationBaselineRelease
            }
            $branchStates += $branchState
            if ($branchName -ieq $DefaultBranch) {
                $defaultBranchState = $branchState
            }
        }

        return [pscustomobject]@{
            BranchStates = @($branchStates)
            BuildValidationEnabled = [bool](@($branchStates | Where-Object { -not [string]::IsNullOrWhiteSpace($_.BuildValidationEnvironmentName) }).Count -gt 0)
            BuildValidationEnvironmentName = $(if ($defaultBranchState) { [string]$defaultBranchState.BuildValidationEnvironmentName } else { '' })
            ExistingBuildValidationEnvironment = $(if ($defaultBranchState) { $defaultBranchState.ExistingBuildValidationEnvironment } else { $null })
            ExistingConfiguration = $existingConfiguration
            LegacyConfigurationConversion = $legacyConfigurationConversion
        }
    }

    return [pscustomobject]@{
        BranchStates = @()
        BuildValidationEnabled = $false
        BuildValidationEnvironmentName = ''
        ExistingBuildValidationEnvironment = $null
        ExistingConfiguration = $existingConfiguration
        LegacyConfigurationConversion = $legacyConfigurationConversion
    }
}

function Get-AzDoInitialBranchMapping {
    # Adapt config-backed states to the branch editor's BranchName/Environments contract.
    # Null targets are removed; no usable states gives one empty DefaultBranch mapping.
    [CmdletBinding()]
    [OutputType([pscustomobject], [object[]])]
    param(
        [Parameter(Mandatory)][object]$ExistingSetupState,
        [Parameter(Mandatory)][string]$DefaultBranch
    )

    $branchMappings = @()
    $existingConfiguration = Get-OptionalObjectPropertyValue -InputObject $ExistingSetupState -PropertyName 'ExistingConfiguration'
    $legacyBuildValidation = Get-OptionalObjectPropertyValue -InputObject $existingConfiguration -PropertyName 'buildValidation'
    $legacyBaselineRelease = [string](Get-OptionalObjectPropertyValue -InputObject $legacyBuildValidation -PropertyName 'baselineRelease')
    foreach ($branchState in @($ExistingSetupState.BranchStates)) {
        if ($null -eq $branchState -or [string]::IsNullOrWhiteSpace([string]$branchState.BranchName)) {
            continue
        }

        $branchProperties = @($branchState.PSObject.Properties.Name)
        $validationEnvironmentName = if ($branchProperties -contains 'BuildValidationEnvironmentName') {
            [string]$branchState.BuildValidationEnvironmentName
        }
        else {
            [string](Get-OptionalObjectPropertyValue -InputObject $ExistingSetupState -PropertyName 'BuildValidationEnvironmentName')
        }
        $validationEnvironment = if ($branchProperties -contains 'ExistingBuildValidationEnvironment') {
            $branchState.ExistingBuildValidationEnvironment
        }
        else {
            Get-OptionalObjectPropertyValue -InputObject $ExistingSetupState -PropertyName 'ExistingBuildValidationEnvironment'
        }
        $baselineRelease = if ($branchProperties -contains 'BuildValidationBaselineRelease') {
            [string]$branchState.BuildValidationBaselineRelease
        }
        else {
            $legacyBaselineRelease
        }

        $branchMappings += [pscustomobject]@{
            BranchName                         = [string]$branchState.BranchName
            Environments                       = @($branchState.DeploymentEnvironments | Where-Object { $null -ne $_ })
            ExistingDevEnvironment             = Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'ExistingDevEnvironment'
            ExistingBuildValidationEnvironment = $validationEnvironment
            BuildValidationEnvironmentName     = $validationEnvironmentName
            BuildValidationBaselineRelease     = $baselineRelease
        }
    }

    if ($branchMappings.Count -eq 0) {
        $branchMappings = @(
            [pscustomobject]@{
                BranchName                         = $DefaultBranch
                Environments                       = @()
                ExistingDevEnvironment             = $null
                ExistingBuildValidationEnvironment = Get-OptionalObjectPropertyValue -InputObject $ExistingSetupState -PropertyName 'ExistingBuildValidationEnvironment'
                BuildValidationEnvironmentName     = [string](Get-OptionalObjectPropertyValue -InputObject $ExistingSetupState -PropertyName 'BuildValidationEnvironmentName')
                BuildValidationBaselineRelease     = $legacyBaselineRelease
            }
        )
    }

    return @($branchMappings | Sort-Object BranchName -Unique)
}

function New-AzDoBranchSetupState {
    # Discovered DEV starts as the current configuration so revisit prompts retain known
    # values. Publication remains a separate wizard choice. Drop null deployment entries
    # but preserve the supplied environment objects and order.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BranchName,
        [Parameter()][object]$ExistingDevEnvironment,
        [Parameter()][array]$DeploymentEnvironments,
        [Parameter()][object]$PublishPlan,
        [Parameter()][object]$ExistingBuildValidationEnvironment,
        [Parameter()][AllowEmptyString()][string]$BuildValidationEnvironmentName = '',
        [Parameter()][AllowEmptyString()][string]$BuildValidationBaselineRelease = ''
    )

    $normalizedDeploymentEnvironments = @($DeploymentEnvironments | Where-Object { $null -ne $_ })

    return [pscustomobject]@{
        BranchName                  = $BranchName
        ExistingDevEnvironment      = $ExistingDevEnvironment
        DevEnvironmentConfiguration = $ExistingDevEnvironment
        DeploymentEnvironments      = $normalizedDeploymentEnvironments
        ExistingBuildValidationEnvironment = $ExistingBuildValidationEnvironment
        BuildValidationEnvironmentName = $BuildValidationEnvironmentName
        BuildValidationEnvironmentConfiguration = $ExistingBuildValidationEnvironment
        BuildValidationBaselineRelease = $BuildValidationBaselineRelease
        BuildValidationEnabled = -not [string]::IsNullOrWhiteSpace($BuildValidationEnvironmentName)
        PublishPlan                 = $PublishPlan
    }
}

function Get-AzDoEnvironmentConfiguration {
    # Collect credentials/ownership, normalize URL and return setup metadata with DEV/BUILD
    # role flags. This prompts (and may create credentials), but does not provision Dataverse roles.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][string]$EnvironmentUrl,
        [Parameter()][string]$FriendlyName,
        [Parameter()][array]$ExistingCredentials,
        [Parameter()][array]$ExistingServiceAccounts,
        [Parameter()][string]$TenantId,
        [Parameter()][string]$ProjectName,
        [Parameter()][bool]$UseAlm4DataverseExtension = $true,
        [Parameter()][object]$ExistingCredential,
        [Parameter()][string]$ExistingServiceAccountUPN,
        [Parameter()][bool]$IsDevelopmentEnvironment = $false,
        [Parameter()][bool]$IsBuildValidationEnvironment = $false
    )

    $creds = Get-PowerPlatformSCCredential `
        -ExistingCredentials $ExistingCredentials `
        -TenantId $TenantId `
        -ProjectName $ProjectName `
        -EnvironmentName $EnvironmentName `
        -UseAlm4DataverseExtension $UseAlm4DataverseExtension `
        -ExistingCredential $ExistingCredential

    $serviceAccountUPN = Get-DataverseServiceAccountUPN `
        -ExistingServiceAccounts $ExistingServiceAccounts `
        -EnvironmentName $EnvironmentName `
        -ExistingValue $ExistingServiceAccountUPN

    return [pscustomobject]@{
        ShortName            = $EnvironmentName
        FriendlyName         = $(if ([string]::IsNullOrWhiteSpace($FriendlyName)) { $EnvironmentName } else { $FriendlyName })
        Url                  = (ConvertTo-NormalizedEnvironmentUrl -Url $EnvironmentUrl)
        Credentials          = $creds
        ServiceAccountUPN    = $serviceAccountUPN
        IsDevelopmentEnvironment = $IsDevelopmentEnvironment
        IsBuildValidationEnvironment = $IsBuildValidationEnvironment
    }
}

function Invoke-AzDoEnvironmentConfigurationWizard {
    <#
    .SYNOPSIS
        Edits an Azure DevOps Dataverse target through the shared detail menu.
    .DESCRIPTION
        Dataverse selection, editable target names, credentials, service-account
        ownership, and an optional BUILD baseline are separate sequential steps.
        Changing the Dataverse environment invalidates credentials and ownership
        selected for a different URL.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'DataverseEnvironmentPrompt', Justification = 'Captured by the nested Dataverse-selection callback.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ExcludedUrl', Justification = 'Captured by the nested Dataverse-selection callback.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ExistingCredentials', Justification = 'Captured by the nested credential callback.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ExistingServiceAccounts', Justification = 'Captured by the nested service-account callback.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'TenantId', Justification = 'Captured by nested configuration callbacks.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ProjectName', Justification = 'Captured by nested configuration callbacks.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'UseAlm4DataverseExtension', Justification = 'Captured by the nested credential callback.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'PromptGuidanceLines', Justification = 'Captured by the nested Dataverse-selection callback.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'PromptGuidanceDocRelativePath', Justification = 'Captured by the nested Dataverse-selection callback.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'PromptGuidanceRef', Justification = 'Captured by the nested Dataverse-selection callback.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$DataverseEnvironmentPrompt,
        [Parameter()][AllowNull()][object]$InitialConfiguration,
        [Parameter()][AllowEmptyString()][string]$InitialTargetName = '',
        [Parameter()][string]$TargetNameStepName = 'Environment name',
        [Parameter()][scriptblock]$SelectTargetNameAction,
        [Parameter()][switch]$TargetNameIsFixed,
        [Parameter()][scriptblock]$SelectBaselineAction,
        [Parameter()][AllowEmptyString()][string]$InitialBaselineRelease = '',
        [Parameter()][switch]$BaselineConfigured,
        [Parameter()][AllowEmptyString()][string]$ExcludedUrl = '',
        [Parameter()][array]$ExistingCredentials,
        [Parameter()][array]$ExistingServiceAccounts,
        [Parameter()][string]$TenantId,
        [Parameter()][string]$ProjectName,
        [Parameter()][bool]$UseAlm4DataverseExtension = $true,
        [Parameter()][bool]$IsDevelopmentEnvironment = $false,
        [Parameter()][bool]$IsBuildValidationEnvironment = $false,
        [Parameter()][string[]]$PromptGuidanceLines,
        [Parameter()][string]$PromptGuidanceDocRelativePath,
        [Parameter()][string]$PromptGuidanceRef,
        [Parameter()][string]$HelpDocRelativePath,
        [Parameter()][string]$HelpRef
    )

    $selectDataverseEnvironment = {
        param($environmentState)
        $selectedEnvironment = Select-DataverseEnvironment `
            -Prompt $DataverseEnvironmentPrompt `
            -ExcludeUrl $ExcludedUrl `
            -PreferredUrl $environmentState.Url `
            -PromptGuidanceLines $PromptGuidanceLines `
            -PromptGuidanceDocRelativePath $PromptGuidanceDocRelativePath `
            -PromptGuidanceRef $PromptGuidanceRef
        if (-not $selectedEnvironment) {
            return $null
        }

        return [pscustomobject]@{
            FriendlyName = [string]$selectedEnvironment.FriendlyName
            Url = ConvertTo-NormalizedEnvironmentUrl -Url ([string]$selectedEnvironment.Endpoints['WebApplication'])
        }
    }.GetNewClosure()
    $selectCredentials = {
        param($environmentState)
        Get-PowerPlatformSCCredential `
            -ExistingCredentials $ExistingCredentials `
            -TenantId $TenantId `
            -ProjectName $ProjectName `
            -EnvironmentName $environmentState.ShortName `
            -UseAlm4DataverseExtension $UseAlm4DataverseExtension `
            -ExistingCredential $environmentState.Credentials
    }.GetNewClosure()
    $selectServiceAccount = {
        param($environmentState)
        Get-DataverseServiceAccountUPN `
            -ExistingServiceAccounts $ExistingServiceAccounts `
            -EnvironmentName $environmentState.ShortName `
            -ExistingValue $environmentState.ServiceAccountUPN
    }.GetNewClosure()

    $environmentConfiguration = Invoke-SetupEnvironmentConfigurationWizard `
        -Title $Title `
        -SelectDataverseEnvironmentAction $selectDataverseEnvironment `
        -InitialConfiguration $InitialConfiguration `
        -InitialTargetName $InitialTargetName `
        -SelectTargetNameAction $SelectTargetNameAction `
        -TargetNameStepName $TargetNameStepName `
        -TargetNameIsFixed:$TargetNameIsFixed `
        -SelectCredentialsAction $selectCredentials `
        -SelectServiceAccountAction $selectServiceAccount `
        -SelectBaselineAction $SelectBaselineAction `
        -InitialBaselineRelease $InitialBaselineRelease `
        -BaselineConfigured:$BaselineConfigured `
        -HelpDocRelativePath $HelpDocRelativePath `
        -HelpRef $HelpRef
    if ($null -eq $environmentConfiguration) {
        return $null
    }

    $resolvedFriendlyName = if ([string]::IsNullOrWhiteSpace($environmentConfiguration.FriendlyName)) {
        [string]$environmentConfiguration.ShortName
    }
    else {
        [string]$environmentConfiguration.FriendlyName
    }
    $result = [pscustomobject]@{
        ShortName = [string]$environmentConfiguration.ShortName
        FriendlyName = $resolvedFriendlyName
        Url = [string]$environmentConfiguration.Url
        Credentials = $environmentConfiguration.Credentials
        ServiceAccountUPN = [string]$environmentConfiguration.ServiceAccountUPN
        IsDevelopmentEnvironment = $IsDevelopmentEnvironment
        IsBuildValidationEnvironment = $IsBuildValidationEnvironment
        ConfigurationPending = $false
    }
    if ($SelectBaselineAction) {
        $result | Add-Member -NotePropertyName BaselineRelease -NotePropertyValue ([string]$environmentConfiguration.BaselineRelease)
    }

    return $result
}

function Get-DataverseEnvironmentsSelection {
    <#
    .SYNOPSIS
    Edits ordered deployment targets and completes missing URL, credential and ownership metadata.
    .NOTES
    InitialEnvironments and branch YAML can seed the editor. Add/edit callbacks receive
    the current selections (edit also receives the target and index); null leaves that
    action unchanged. Duplicate URL/short-name checks exclude the edited row.
    ExcludedUrl protects DEV from deployment selection, including final completion.
    Returns completed targets in promotion order; credentials/accounts become reusable
    within this selection.     Cancelling a required pre-existing environment resolution throws; cancelling a
    new or optional edit leaves the current selection unchanged.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject], [object[]])]
    param(
        [Parameter(Mandatory = $false)][string]$ExcludedUrl,
        [Parameter()][string]$RepoRoot,
        [Parameter()][string]$Branch,
        [Parameter()][string]$ProjectName,
        [Parameter()][array]$InitialEnvironments,
        [Parameter()][array]$ExistingCredentials,
        [Parameter()][array]$ExistingServiceAccounts,
        [Parameter()][string]$TenantId,
        [Parameter()][bool]$UseAlm4DataverseExtension = $true,
        [Parameter()][string]$InitialEditEnvironmentName
    )

    $selectedEnvironments = @($InitialEnvironments | Where-Object { $null -ne $_ })
    $credentialsForReuse = @($ExistingCredentials | Where-Object { $null -ne $_ })
    $serviceAccountsForReuse = @($ExistingServiceAccounts)
    $normalizedExcludedUrl = ConvertTo-NormalizedEnvironmentUrl -Url $ExcludedUrl

    if (-not [string]::IsNullOrWhiteSpace($RepoRoot) -and -not [string]::IsNullOrWhiteSpace($Branch) -and $ProjectName) {
        $existingNames = @(Get-ExistingEnvironmentsFromWorkingTree -RepoRoot $RepoRoot -Branch $Branch)

        if ($existingNames.Count -gt 0) {
            Write-Host "Found $($existingNames.Count) deployment environment(s) in alm-config.psd1. Pre-populating the deployment environment table..." -ForegroundColor Cyan

            $selectedEnvironments += @(Invoke-WithSpectreStatus -Status 'Inspecting existing deployment environment configuration...' -ScriptBlock {
                $resolvedExistingEnvironments = @()

                foreach ($name in $existingNames) {
                    if ($selectedEnvironments | Where-Object { $_.ShortName -ieq $name }) {
                        continue
                    }

                    $existingEnvironmentState = Get-AzDoExistingEnvironmentState -ProjectName $ProjectName -EnvironmentName $name -TenantId $TenantId

                    $existingEnvironmentUrl = ConvertTo-NormalizedEnvironmentUrl -Url $existingEnvironmentState.Url
                    if (-not [string]::IsNullOrWhiteSpace($normalizedExcludedUrl) -and $existingEnvironmentUrl -eq $normalizedExcludedUrl) {
                        Write-Warning "Skipping existing deployment stage '$name' because it points at the selected DEV environment URL."
                        continue
                    }

                    $resolvedExistingEnvironments += [pscustomobject]@{
                        ShortName            = $name
                        FriendlyName         = $(if (-not [string]::IsNullOrWhiteSpace($existingEnvironmentState.FriendlyName)) { $existingEnvironmentState.FriendlyName } else { "$name (Existing)" })
                        Url                  = $existingEnvironmentUrl
                        Credentials          = $existingEnvironmentState.Credentials
                        ServiceAccountUPN    = $existingEnvironmentState.ServiceAccountUPN
                        IsDevelopmentEnvironment = $false
                        ConfigurationPending = (($null -eq $existingEnvironmentState.Credentials) -or [string]::IsNullOrWhiteSpace($existingEnvironmentState.ServiceAccountUPN))
                    }
                }

                return @($resolvedExistingEnvironments)
            })
        }
    }

    $resolvedHeading = if ([string]::IsNullOrWhiteSpace($Branch)) { 'Target Deployment Environments' } else { "Target Deployment Environments for branch '$Branch'" }

    $selectedEnvironments = @(Select-ConfiguredDeploymentEnvironment `
        -InitialEnvironments $selectedEnvironments `
        -InitialEditEnvironmentName $InitialEditEnvironmentName `
        -Heading $resolvedHeading `
        -Title 'Manage deployment environments' `
        -GuidanceLines @(
            'Select each deployment environment together with the credential and service-account ownership that should be used there.',
            'Review URL, auth, and service-account values before continuing because setup applies them to service connections, variable groups, and DEPLOY YAML.',
            'Keep short names stable and the list in promotion order, because that order becomes the generated deployment stage sequence.'
        ) `
        -DocRelativePath 'docs/setup/azdo-manual-setup.md' `
        -Ref $ALM4DataverseRef `
        -AddEnvironmentScriptBlock {
            param($currentSelections)

            $currentCredentials = @($ExistingCredentials)
            $currentCredentials += @($currentSelections | ForEach-Object { $_.Credentials } | Where-Object { $null -ne $_ })
            $currentServiceAccounts = @($ExistingServiceAccounts)
            $currentServiceAccounts += @($currentSelections | ForEach-Object { $_.ServiceAccountUPN } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

            $selectTargetName = {
                param($environmentState)
                $shortName = Read-TextWithDefault `
                    -Prompt 'Enter a short name for this environment' `
                    -DefaultValue $environmentState.ShortName `
                    -PromptGuidanceLines @(
                        'Use a concise name such as TEST, UAT, or PROD.',
                        'This label appears in setup summaries and must be unique within the branch.'
                    ) `
                    -PromptGuidanceDocRelativePath 'docs/config/alm-config.md' `
                    -PromptGuidanceRef $ALM4DataverseRef
                if ([string]::IsNullOrWhiteSpace($shortName)) {
                    [Spectre.Console.AnsiConsole]::MarkupLine('[red]An environment short name is required.[/]')
                    Request-SetupWizardBack
                }
                if ($currentSelections | Where-Object { $_.Url -ieq $environmentState.Url }) {
                    Write-Host "An environment with Url '$($environmentState.Url)' is already selected." -ForegroundColor Red
                    Request-SetupWizardBack
                }
                if ($currentSelections | Where-Object { $_.ShortName -ieq $shortName }) {
                    Write-Host "An environment with short name '$shortName' is already selected (case-insensitive match)." -ForegroundColor Red
                    Request-SetupWizardBack
                }

                return $shortName
            }.GetNewClosure()

            return Invoke-AzDoEnvironmentConfigurationWizard `
                -Title 'Configure a deployment environment' `
                -DataverseEnvironmentPrompt 'Select a deployment environment' `
                -InitialTargetName '' `
                -TargetNameStepName 'Short name' `
                -SelectTargetNameAction $selectTargetName `
                -ExistingCredentials $currentCredentials `
                -ExistingServiceAccounts $currentServiceAccounts `
                -TenantId $TenantId `
                -ProjectName $ProjectName `
                -UseAlm4DataverseExtension $UseAlm4DataverseExtension `
                -ExcludedUrl $ExcludedUrl `
                -PromptGuidanceLines @(
                    'Select the Dataverse environment that this deployment stage should target.',
                    'The branch DEV environment cannot be selected as a deployment target.'
                ) `
                -PromptGuidanceDocRelativePath 'docs/setup/azdo-automated-setup.md' `
                -PromptGuidanceRef $ALM4DataverseRef `
                -HelpDocRelativePath 'docs/setup/azdo-automated-setup.md' `
                -HelpRef $ALM4DataverseRef
        } `
        -EditEnvironmentScriptBlock {
            param($currentSelections, $environmentToEdit, $environmentIndex)

            $otherSelections = @()
            for ($selectionIndex = 0; $selectionIndex -lt $currentSelections.Count; $selectionIndex++) {
                if ($selectionIndex -ne $environmentIndex) {
                    $otherSelections += $currentSelections[$selectionIndex]
                }
            }

            $currentCredentials = @($ExistingCredentials)
            $currentCredentials += @($otherSelections | ForEach-Object { $_.Credentials } | Where-Object { $null -ne $_ })
            $currentServiceAccounts = @($ExistingServiceAccounts)
            $currentServiceAccounts += @($otherSelections | ForEach-Object { $_.ServiceAccountUPN } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

            $selectTargetName = {
                param($environmentState)
                $shortName = Read-TextWithDefault `
                    -Prompt 'Enter a short name for this environment' `
                    -DefaultValue $environmentState.ShortName `
                    -PromptGuidanceLines @(
                        'Use a concise name such as TEST, UAT, or PROD.',
                        'This label appears in setup summaries and must be unique within the branch.'
                    ) `
                    -PromptGuidanceDocRelativePath 'docs/config/alm-config.md' `
                    -PromptGuidanceRef $ALM4DataverseRef
                if ([string]::IsNullOrWhiteSpace($shortName)) {
                    [Spectre.Console.AnsiConsole]::MarkupLine('[red]An environment short name is required.[/]')
                    Request-SetupWizardBack
                }
                if ($otherSelections | Where-Object { $_.Url -ieq $environmentState.Url }) {
                    Write-Host "An environment with Url '$($environmentState.Url)' is already selected." -ForegroundColor Red
                    Request-SetupWizardBack
                }
                if ($otherSelections | Where-Object { $_.ShortName -ieq $shortName }) {
                    Write-Host "An environment with short name '$shortName' is already selected (case-insensitive match)." -ForegroundColor Red
                    Request-SetupWizardBack
                }

                return $shortName
            }.GetNewClosure()

            return Invoke-AzDoEnvironmentConfigurationWizard `
                -Title "Configure deployment environment '$($environmentToEdit.ShortName)'" `
                -DataverseEnvironmentPrompt "Select the deployment environment for '$($environmentToEdit.ShortName)'" `
                -InitialConfiguration $environmentToEdit `
                -TargetNameStepName 'Short name' `
                -SelectTargetNameAction $selectTargetName `
                -ExistingCredentials $currentCredentials `
                -ExistingServiceAccounts $currentServiceAccounts `
                -TenantId $TenantId `
                -ProjectName $ProjectName `
                -UseAlm4DataverseExtension $UseAlm4DataverseExtension `
                -ExcludedUrl $ExcludedUrl `
                -PromptGuidanceLines @(
                    'Choose the Dataverse target for this deployment stage.',
                    'Changing the target invalidates credentials and service-account ownership selected for the previous environment.'
                ) `
                -PromptGuidanceDocRelativePath 'docs/setup/azdo-automated-setup.md' `
                -PromptGuidanceRef $ALM4DataverseRef `
                -HelpDocRelativePath 'docs/setup/azdo-automated-setup.md' `
                -HelpRef $ALM4DataverseRef
        })

    $completedEnvironments = @()
    for ($selectedEnvironmentIndex = 0; $selectedEnvironmentIndex -lt $selectedEnvironments.Count; $selectedEnvironmentIndex++) {
        $selectedEnvironment = $selectedEnvironments[$selectedEnvironmentIndex]
        if ([string]::IsNullOrWhiteSpace($selectedEnvironment.ShortName)) {
            continue
        }

        $resolvedEnvironmentUrl = ConvertTo-NormalizedEnvironmentUrl -Url $selectedEnvironment.Url
        $resolvedFriendlyName = if ([string]::IsNullOrWhiteSpace($selectedEnvironment.FriendlyName)) { $selectedEnvironment.ShortName } else { $selectedEnvironment.FriendlyName }

        $needsConfiguration = (
            ($selectedEnvironment.PSObject.Properties.Name -contains 'ConfigurationPending' -and $selectedEnvironment.ConfigurationPending) -or
            [string]::IsNullOrWhiteSpace($resolvedEnvironmentUrl) -or
            ($null -eq $selectedEnvironment.Credentials) -or
            [string]::IsNullOrWhiteSpace($selectedEnvironment.ServiceAccountUPN)
        )

        if ($needsConfiguration) {
            Write-Host "Completing configuration for existing deployment environment '$($selectedEnvironment.ShortName)'..." -ForegroundColor Yellow
            $otherSelections = @()
            for ($selectionIndex = 0; $selectionIndex -lt $selectedEnvironments.Count; $selectionIndex++) {
                if ($selectionIndex -ne $selectedEnvironmentIndex) {
                    $otherSelections += $selectedEnvironments[$selectionIndex]
                }
            }
            $selectTargetName = {
                param($environmentState)
                $shortName = Read-TextWithDefault `
                    -Prompt 'Enter a short name for this environment' `
                    -DefaultValue $environmentState.ShortName `
                    -PromptGuidanceLines @(
                        'Use a concise name such as TEST, UAT, or PROD.',
                        'This label appears in setup summaries and must be unique within the branch.'
                    ) `
                    -PromptGuidanceDocRelativePath 'docs/config/alm-config.md' `
                    -PromptGuidanceRef $ALM4DataverseRef
                if ([string]::IsNullOrWhiteSpace($shortName)) {
                    [Spectre.Console.AnsiConsole]::MarkupLine('[red]An environment short name is required.[/]')
                    Request-SetupWizardBack
                }
                if ($otherSelections | Where-Object { $_.Url -ieq $environmentState.Url }) {
                    Write-Host "An environment with Url '$($environmentState.Url)' is already selected." -ForegroundColor Red
                    Request-SetupWizardBack
                }
                if ($otherSelections | Where-Object { $_.ShortName -ieq $shortName }) {
                    Write-Host "An environment with short name '$shortName' is already selected (case-insensitive match)." -ForegroundColor Red
                    Request-SetupWizardBack
                }

                return $shortName
            }.GetNewClosure()
            $completedEnvironment = Invoke-AzDoEnvironmentConfigurationWizard `
                -Title "Configure deployment environment '$($selectedEnvironment.ShortName)'" `
                -DataverseEnvironmentPrompt "Resolve the Dataverse environment for existing deployment stage '$($selectedEnvironment.ShortName)'" `
                -InitialConfiguration $selectedEnvironment `
                -TargetNameStepName 'Short name' `
                -SelectTargetNameAction $selectTargetName `
                -ExistingCredentials $credentialsForReuse `
                -ExistingServiceAccounts $serviceAccountsForReuse `
                -TenantId $TenantId `
                -ProjectName $ProjectName `
                -UseAlm4DataverseExtension $UseAlm4DataverseExtension `
                -ExcludedUrl $ExcludedUrl `
                -PromptGuidanceLines @(
                    'Resolve the Dataverse target for this existing deployment stage.',
                    'Complete credentials and service-account ownership before continuing.'
                ) `
                -PromptGuidanceDocRelativePath 'docs/setup/azdo-automated-setup.md' `
                -PromptGuidanceRef $ALM4DataverseRef `
                -HelpDocRelativePath 'docs/setup/azdo-automated-setup.md' `
                -HelpRef $ALM4DataverseRef
            if ($null -eq $completedEnvironment) {
                throw "Configuration for deployment environment '$($selectedEnvironment.ShortName)' is incomplete."
            }
        }
        else {
            $completedEnvironment = [pscustomobject]@{
                ShortName         = $selectedEnvironment.ShortName
                FriendlyName      = $resolvedFriendlyName
                Url               = $resolvedEnvironmentUrl
                Credentials       = $selectedEnvironment.Credentials
                ServiceAccountUPN = $selectedEnvironment.ServiceAccountUPN
                IsDevelopmentEnvironment = $false
            }
        }

        $resolvedEnvironmentUrl = ConvertTo-NormalizedEnvironmentUrl -Url $completedEnvironment.Url
        if (-not [string]::IsNullOrWhiteSpace($normalizedExcludedUrl) -and $resolvedEnvironmentUrl -eq $normalizedExcludedUrl) {
            Write-Warning "Skipping deployment environment '$($completedEnvironment.ShortName)' because it points at the selected DEV environment URL."
            continue
        }
        if ([string]::IsNullOrWhiteSpace($resolvedEnvironmentUrl) -or
            $null -eq $completedEnvironment.Credentials -or
            [string]::IsNullOrWhiteSpace($completedEnvironment.ServiceAccountUPN)) {
            throw "Deployment environment '$($completedEnvironment.ShortName)' is missing a Dataverse URL, credential, or service account."
        }

        $completedEnvironments += $completedEnvironment
        if ($completedEnvironment.Credentials -and -not ($credentialsForReuse | Where-Object { $_.ApplicationId -eq $completedEnvironment.Credentials.ApplicationId -and $_.TenantId -eq $completedEnvironment.Credentials.TenantId })) {
            $credentialsForReuse += $completedEnvironment.Credentials
        }
        if (-not [string]::IsNullOrWhiteSpace($completedEnvironment.ServiceAccountUPN) -and $serviceAccountsForReuse -notcontains $completedEnvironment.ServiceAccountUPN) {
            $serviceAccountsForReuse += $completedEnvironment.ServiceAccountUPN
        }
    }

    return @($completedEnvironments)
}

function Update-DeployPipelineInWorkingTree {
    <#
    .SYNOPSIS
    Writes or updates DEPLOY-{branch}.yml with the selected environment sequence.
    .NOTES
    An empty target list removes the branch DEPLOY file. A missing file is created
    from the shared-repository scaffold first. Nonempty targets regenerate the
    deployment entries; the line scanner recognizes the exact template and six-space
    parameter layout, not arbitrary YAML. Preserves other lines and appends entries
    in promotion order. Parameters other than environmentName,
    useAlm4DataverseExtension and sharedTemplateVersion (for example secretVariables
    or timeoutInMinutes), including their nested lines, are carried over to the
    regenerated entry for the same environment name; entries for removed
    environments are dropped. The generated file starts with a notice that direct
    edits are unsupported, points at alm-config.psd1 plus setup, and passes the
    current shared template version.
    Returns whether content changed (false under WhatIf).
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][array]$Environments,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$SharedRepositoryName,
        [Parameter()][string]$SharedRepositoryRef = 'main',
        [Parameter()][bool]$UseAlm4DataverseExtension = $true
    )

    if (-not $PSCmdlet.ShouldProcess($RepoRoot, 'Update Azure DevOps DEPLOY pipeline')) { return $false }

    $deployYamlName = "DEPLOY-$Branch.yml"
    $deployYamlPath = Join-Path $RepoRoot "pipelines\$deployYamlName"

    if (-not $Environments -or $Environments.Count -eq 0) {
        if (Test-Path -LiteralPath $deployYamlPath) {
            Remove-Item -LiteralPath $deployYamlPath -Force
            Write-Host "$deployYamlName removed because branch '$Branch' has no deployment environments configured." -ForegroundColor Yellow
            return $true
        }

        Write-Host "$deployYamlName is not required because branch '$Branch' has no deployment environments configured." -ForegroundColor Yellow
        return $false
    }

    $escapedSharedRepositoryRef = ([string]$SharedRepositoryRef).Replace("'", "''")
    $templateVersion = Get-AlmSharedTemplateVersion
    if (-not (Test-Path -LiteralPath $deployYamlPath)) {
        $deployDirectory = Split-Path -Parent $deployYamlPath
        if (-not (Test-Path -LiteralPath $deployDirectory)) {
            New-Item -ItemType Directory -Path $deployDirectory -Force | Out-Null
        }

        $deployScaffold = @"
# Setup generates this file from alm-config.psd1: direct edits are not supported.
# Change alm-config.psd1, commit it, and apply it again (the APPLY-CONFIG pipeline
# or setup-azdo.ps1 -ApplyConfig) to regenerate this pipeline.

trigger: none # Triggered by build completion or manually

resources:
  pipelines:
    - pipeline: build
      source: 'BUILD'
      trigger:
        branches:
          include:
          - $Branch
  repositories:
    - repository: ALM4Dataverse
      type: git
      name: $SharedRepositoryName
      ref: 'refs/heads/$escapedSharedRepositoryRef'


name: 'Deploy `$(resources.pipeline.build.runName)'
appendCommitMessageToRunName: false

stages:
  # Deployment entries are generated by setup from alm-config.psd1.
"@
        Set-Content -LiteralPath $deployYamlPath -Value $deployScaffold -NoNewline
    }

    $originalContent = Get-Content -LiteralPath $deployYamlPath -Raw
    $contentLines = Get-Content -LiteralPath $deployYamlPath
    $cleanedContent = @()
    $preservedParameterLines = @{}
    $i = 0
    while ($i -lt $contentLines.Count) {
        $line = $contentLines[$i]
        if ($line.Trim() -eq '- template: pipelines/templates/stages/deploy-environment.yml@ALM4Dataverse') {
            $i++
            if ($i -lt $contentLines.Count -and $contentLines[$i].Trim() -eq 'parameters:') {
                $i++
                $existingEnvironmentName = $null
                $extraLines = [System.Collections.Generic.List[string]]::new()
                $inExtraParameter = $false
                # Deeper lines belong to the preceding parameter, such as list items.
                while ($i -lt $contentLines.Count -and $contentLines[$i] -match '^\s{6,}\S') {
                    $parameterLine = $contentLines[$i]
                    if ($parameterLine -match '^\s{6}environmentName:\s*(.*?)\s*$') {
                        $existingEnvironmentName = $Matches[1].Trim("'", '"')
                        $inExtraParameter = $false
                    }
                    elseif ($parameterLine -match '^\s{6}useAlm4DataverseExtension:') {
                        $inExtraParameter = $false
                    }
                    elseif ($parameterLine -match '^\s{6}sharedTemplateVersion:') {
                        $inExtraParameter = $false
                    }
                    elseif ($parameterLine -match '^\s{6}\S') {
                        $inExtraParameter = $true
                        $extraLines.Add($parameterLine)
                    }
                    elseif ($inExtraParameter) {
                        $extraLines.Add($parameterLine)
                    }
                    $i++
                }
                if (-not [string]::IsNullOrWhiteSpace($existingEnvironmentName) -and $extraLines.Count -gt 0) {
                    $preservedParameterLines[$existingEnvironmentName] = @($extraLines)
                }
            }
        }
        else {
            $cleanedContent += $line
            $i++
        }
    }

    $newStages = "`n"
    foreach ($env in $Environments) {
        $newStages += "  - template: pipelines/templates/stages/deploy-environment.yml@ALM4Dataverse`n"
        $newStages += "    parameters:`n"
        $newStages += "      environmentName: $($env.ShortName)`n"
        $newStages += "      useAlm4DataverseExtension: $($UseAlm4DataverseExtension.ToString().ToLowerInvariant())`n"
        $newStages += "      sharedTemplateVersion: '$templateVersion'`n"
        if ($preservedParameterLines.ContainsKey([string]$env.ShortName)) {
            foreach ($preservedLine in $preservedParameterLines[[string]$env.ShortName]) {
                $newStages += "$preservedLine`n"
            }
        }
    }

    $updatedContent = (($cleanedContent -join [Environment]::NewLine).TrimEnd() + $newStages).TrimEnd() + [Environment]::NewLine
    if ($updatedContent -eq $originalContent) {
        Write-Host "$deployYamlName already matches the selected deployment environments." -ForegroundColor Green
        return $false
    }

    Set-Content -LiteralPath $deployYamlPath -Value $updatedContent -NoNewline
    Write-Host "$deployYamlName updated in the working tree." -ForegroundColor Green
    return $true
}

function New-AzDoPullRequest {
    # SourceBranch/TargetBranch are short names: refs/heads/ is added to the REST payload.
    # Return the API response, or nothing if ShouldProcess declines; API failures propagate.
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$RepositoryId,
        [Parameter(Mandatory)][string]$SourceBranch,
        [Parameter(Mandatory)][string]$TargetBranch,
        [Parameter(Mandatory)][string]$Title,
        [Parameter()][string]$Description
    )

    if (-not $PSCmdlet.ShouldProcess($RepositoryId, 'Create Azure DevOps pull request')) { return }

    $body = @{
        sourceRefName = "refs/heads/$SourceBranch"
        targetRefName = "refs/heads/$TargetBranch"
        title         = $Title
        description   = $Description
    }

    return Invoke-VSTeamRequest -Method POST -Resource "git/repositories/$RepositoryId/pullrequests" -Body ($body | ConvertTo-Json -Depth 10) -ContentType 'application/json' -Version '7.1'
}

function Publish-AzDoRepoChange {
    <#
    .SYNOPSIS
    Stages all clone changes, commits/pushes the planned branch and optionally creates a pull request.
    .OUTPUTS
    System.Management.Automation.PSCustomObject. HasChanges, BranchName, TargetBranch,
    PullRequestUrl and Mode. Native Git output can also appear on the success stream.
    .NOTES
    Assumes the planned branch is already checked out. Even a clean index is pushed
    to ensure the branch exists, but no PR is created for that no-change path.
    Writes clone-local author config; location/error preference are restored on failure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][object]$PublishPlan,
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][object]$Repository
    )

    Push-Location $RepoRoot
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & git add -A
        if ($LASTEXITCODE -ne 0) {
            throw 'Git add failed.'
        }

        & git diff --cached --quiet
        $hasChanges = ($LASTEXITCODE -ne 0)
        if (-not $hasChanges) {
            Write-Host "No content changes detected, but ensuring branch '$($PublishPlan.BranchName)' exists on origin..." -ForegroundColor Yellow
            & git -c "http.extraheader=AUTHORIZATION: bearer $AccessToken" push -u origin $PublishPlan.BranchName 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw 'Git push failed.'
            }

            Write-Host 'No changes to commit; main repo already contains the required files.' -ForegroundColor Green
            return [pscustomobject]@{
                HasChanges     = $false
                BranchName     = $PublishPlan.BranchName
                TargetBranch   = $PublishPlan.TargetBranch
                PullRequestUrl = $null
                Mode           = $PublishPlan.Mode
            }
        }

        & git config user.name 'ALM4Dataverse Setup' 2>$null
        & git config user.email 'setup@alm4dataverse.local' 2>$null

        & git commit -m $PublishPlan.CommitMessage 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw 'Git commit failed.'
        }

        Write-Host "Pushing to origin/$($PublishPlan.BranchName)..." -ForegroundColor Yellow
        & git -c "http.extraheader=AUTHORIZATION: bearer $AccessToken" push -u origin $PublishPlan.BranchName 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw 'Git push failed.'
        }

        $pullRequestUrl = $null
        if ($PublishPlan.Mode -eq 'PullRequest') {
            Write-Host "Creating pull request into '$($PublishPlan.TargetBranch)'..." -ForegroundColor Yellow
            $pullRequest = New-AzDoPullRequest `
                -RepositoryId $Repository.Id `
                -SourceBranch $PublishPlan.BranchName `
                -TargetBranch $PublishPlan.TargetBranch `
                -Title $PublishPlan.PullRequestTitle `
                -Description $PublishPlan.PullRequestDescription

            if ($pullRequest -and $pullRequest._links -and $pullRequest._links.web -and $pullRequest._links.web.href) {
                $pullRequestUrl = $pullRequest._links.web.href
            }
            elseif ($pullRequest -and $pullRequest.url) {
                $pullRequestUrl = $pullRequest.url
            }
        }

        Write-Host 'Main repository updated successfully.' -ForegroundColor Green
        return [pscustomobject]@{
            HasChanges     = $true
            BranchName     = $PublishPlan.BranchName
            TargetBranch   = $PublishPlan.TargetBranch
            PullRequestUrl = $pullRequestUrl
            Mode           = $PublishPlan.Mode
        }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        Pop-Location
    }
}

function Invoke-AzDoSetupArtifactGeneration {
    <#
    .SYNOPSIS
    Generates configuration and pipeline YAML for one Azure DevOps setup publication.
    .DESCRIPTION
    Shared by publication and preview so both paths use the same generators. This
    function only writes files below RepoRoot; it does not contact Azure DevOps.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'MainRepo', Justification = 'The caller identity is part of the generation contract even though the current generators read it only through CopyRoot.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$CopyRoot,
        [Parameter(Mandatory)][object]$MainRepo,
        [Parameter(Mandatory)][string]$SharedRepositoryName,
        [Parameter(Mandatory)][string]$SharedRepositoryRef,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][bool]$UseAlm4DataverseExtension,
        [Parameter()][AllowNull()][array]$Solutions,
        [Parameter()][AllowEmptyCollection()][array]$DeploymentEnvironments = @(),
        [Parameter()][AllowEmptyCollection()][array]$DeployWorkflowBranchDefinitions = @(),
        [Parameter()][bool]$BuildValidationEnabled = $false,
        [Parameter()][AllowEmptyString()][string]$BuildValidationEnvironmentName = '',
        [Parameter()][AllowEmptyString()][string]$BuildValidationBaselineRelease = '',
        [Parameter()][System.Collections.IDictionary]$BuildValidationEnvironments = @{},
        [Parameter()][System.Collections.IDictionary]$SetupSettings
    )

    Sync-CopyToYourRepoIntoGitRepo `
        -SourceRoot $CopyRoot `
        -TargetRoot $RepoRoot `
        -SharedRepositoryName $SharedRepositoryName `
        -SharedRepositoryRef $SharedRepositoryRef | Out-Null

    Update-AlmConfigInWorkingTree `
        -Solutions $Solutions `
        -BuildValidationEnabled $BuildValidationEnabled `
        -BuildValidationBaselineRelease $BuildValidationBaselineRelease `
        -RepoRoot $RepoRoot `
        -SetupSettings $SetupSettings | Out-Null

    Update-AzDoBuildPipelineInWorkingTree `
        -RepoRoot $RepoRoot `
        -SharedRepositoryName $SharedRepositoryName `
        -SharedRepositoryRef $SharedRepositoryRef `
        -BuildEnvironmentName $(if ($BuildValidationEnabled) { $BuildValidationEnvironmentName } else { '' }) `
        -UseAlm4DataverseExtension $UseAlm4DataverseExtension `
        -BuildValidationEnvironments $BuildValidationEnvironments | Out-Null

    Update-AzDoExportPipelineInWorkingTree `
        -RepoRoot $RepoRoot `
        -SharedRepositoryName $SharedRepositoryName `
        -SharedRepositoryRef $SharedRepositoryRef `
        -UseAlm4DataverseExtension $UseAlm4DataverseExtension | Out-Null

    Update-AzDoImportPipelineInWorkingTree `
        -RepoRoot $RepoRoot `
        -SharedRepositoryName $SharedRepositoryName `
        -SharedRepositoryRef $SharedRepositoryRef `
        -UseAlm4DataverseExtension $UseAlm4DataverseExtension | Out-Null

    $deployBranchDefinitions = @($DeployWorkflowBranchDefinitions)
    if ($deployBranchDefinitions.Count -eq 0) {
        $deployBranchDefinitions = @([pscustomobject]@{
                BranchName             = $Branch
                DeploymentEnvironments = @($DeploymentEnvironments)
            })
    }
    foreach ($deployDefinition in $deployBranchDefinitions) {
        Update-DeployPipelineInWorkingTree `
            -Environments @($deployDefinition.DeploymentEnvironments) `
            -RepoRoot $RepoRoot `
            -Branch ([string]$deployDefinition.BranchName) `
            -SharedRepositoryName $SharedRepositoryName `
            -SharedRepositoryRef $SharedRepositoryRef `
            -UseAlm4DataverseExtension $UseAlm4DataverseExtension | Out-Null
    }
}

function Publish-AzDoBranchSetupChange {
    <#
    .SYNOPSIS
    Rebuilds one branch's setup files in the disposable clone and publishes its plan.
    .NOTES
    Destructively resets tracked changes and cleans untracked files before switching
    branches; RepoRoot must not be a user's working checkout. Existing target history
    wins, then default-branch history, then an orphan/available HEAD path.
    PR mode first creates a missing target branch (with an empty commit if needed)
    so Azure DevOps has a target. Null Solutions preserves that branch's list.
    Returns the publication result; failures do not roll back prior remote pushes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ConfiguredBranch,
        [Parameter(Mandatory)][object]$PublishPlan,
        [Parameter(Mandatory)][string]$DefaultBranch,
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][object]$Repository,
        [Parameter(Mandatory)][string]$CopyRoot,
        [Parameter(Mandatory)][string]$SharedRepositoryName,
        [Parameter()][string]$SharedRepositoryRef = 'main',
        [Parameter(Mandatory)][bool]$UseAlm4DataverseExtension,
        [Parameter()][AllowNull()][array]$Solutions,
        [Parameter()][array]$DeploymentEnvironments,
        [Parameter()][AllowEmptyCollection()][array]$DeployWorkflowBranchDefinitions = @(),
        [Parameter()][bool]$BuildValidationEnabled = $false,
        [Parameter()][AllowEmptyString()][string]$BuildValidationEnvironmentName = '',
        [Parameter()][AllowEmptyString()][string]$BuildValidationBaselineRelease = '',
        [Parameter()][System.Collections.IDictionary]$BuildValidationEnvironments = @{},
        [Parameter()][System.Collections.IDictionary]$SetupSettings
    )

    Push-Location $RepoRoot
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & git -c "http.extraheader=AUTHORIZATION: bearer $AccessToken" fetch origin '+refs/heads/*:refs/remotes/origin/*' --prune 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'Failed to refresh remote branches before publishing.'
        }

        & git reset --hard HEAD 2>&1 | Out-Null
        & git clean -fd 2>&1 | Out-Null

        & git -c "http.extraheader=AUTHORIZATION: bearer $AccessToken" -c credential.interactive=never ls-remote --exit-code --heads origin $ConfiguredBranch 2>&1 | Out-Null
        $targetBranchExistsOnOrigin = ($LASTEXITCODE -eq 0)

        & git -c "http.extraheader=AUTHORIZATION: bearer $AccessToken" -c credential.interactive=never ls-remote --exit-code --heads origin $DefaultBranch 2>&1 | Out-Null
        $defaultBranchExistsOnOrigin = ($LASTEXITCODE -eq 0)

        $seedRef = if ($targetBranchExistsOnOrigin) {
            "origin/$ConfiguredBranch"
        }
        elseif ($defaultBranchExistsOnOrigin) {
            "origin/$DefaultBranch"
        }
        else {
            $null
        }

        if ($PublishPlan.Mode -eq 'PullRequest' -and -not $targetBranchExistsOnOrigin) {
            Write-Host "Initializing target branch '$ConfiguredBranch' on origin before creating a pull request..." -ForegroundColor Yellow

            if ($seedRef) {
                & git checkout -B $ConfiguredBranch $seedRef 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to create local target branch '$ConfiguredBranch' from '$seedRef'."
                }
            }
            else {
                & git checkout --orphan $ConfiguredBranch 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to create orphan target branch '$ConfiguredBranch'."
                }
            }

            & git config user.name 'ALM4Dataverse Setup' 2>$null
            & git config user.email 'setup@alm4dataverse.local' 2>$null

            & git rev-parse --verify HEAD 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                & git commit --allow-empty -m "Initialize repository branch '$ConfiguredBranch' for ALM4Dataverse setup" 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to create initial commit for branch '$ConfiguredBranch'."
                }
            }

            & git -c "http.extraheader=AUTHORIZATION: bearer $AccessToken" push -u origin $ConfiguredBranch 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to push target branch '$ConfiguredBranch' to origin."
            }

            $targetBranchExistsOnOrigin = $true
            $seedRef = $ConfiguredBranch
        }

        & git rev-parse --verify HEAD 2>&1 | Out-Null
        $hasLocalHeadCommit = ($LASTEXITCODE -eq 0)

        if ($PublishPlan.Mode -eq 'PullRequest') {
            $workingBaseRef = if ($targetBranchExistsOnOrigin) { "origin/$ConfiguredBranch" } elseif ($seedRef) { $seedRef } else { 'HEAD' }
            & git checkout -B $PublishPlan.BranchName $workingBaseRef 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to create or switch to working branch '$($PublishPlan.BranchName)'."
            }
        }
        else {
            $directBaseRef = if ($targetBranchExistsOnOrigin) { "origin/$ConfiguredBranch" } elseif ($seedRef) { $seedRef } elseif ($hasLocalHeadCommit) { 'HEAD' } else { $null }
            if ($directBaseRef) {
                $checkoutOutput = @(& git checkout -B $ConfiguredBranch $directBaseRef 2>&1)
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to create or switch to target branch '$ConfiguredBranch' from '$directBaseRef': $($checkoutOutput -join ' ')"
                }
            }
            else {
                $checkoutOutput = @(& git checkout --orphan $ConfiguredBranch 2>&1)
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to create orphan target branch '$ConfiguredBranch': $($checkoutOutput -join ' ')"
                }
            }
        }

        Invoke-AzDoSetupArtifactGeneration `
            -RepoRoot $RepoRoot `
            -CopyRoot $CopyRoot `
            -MainRepo $Repository `
            -SharedRepositoryName $SharedRepositoryName `
            -SharedRepositoryRef $SharedRepositoryRef `
            -Branch $ConfiguredBranch `
            -UseAlm4DataverseExtension $UseAlm4DataverseExtension `
            -Solutions $Solutions `
            -DeploymentEnvironments $DeploymentEnvironments `
            -DeployWorkflowBranchDefinitions $DeployWorkflowBranchDefinitions `
            -BuildValidationEnabled $BuildValidationEnabled `
            -BuildValidationEnvironmentName $BuildValidationEnvironmentName `
            -BuildValidationBaselineRelease $BuildValidationBaselineRelease `
            -BuildValidationEnvironments $BuildValidationEnvironments `
            -SetupSettings $SetupSettings

        return Publish-AzDoRepoChange -RepoRoot $RepoRoot -PublishPlan $PublishPlan -AccessToken $AccessToken -Repository $Repository
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        Pop-Location
    }
}

function Get-AzDoPublishSummaryText {
    # Count content-changing results only; no-change pushes are intentionally not
    # described as updates, and PullRequest mode does not guarantee a returned PR URL.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][array]$PublishResults
    )

    $results = @($PublishResults | Where-Object { $null -ne $_ })
    if ($results.Count -eq 0) {
        return 'No repository changes were needed'
    }

    $changedResults = @($results | Where-Object { $_.HasChanges })
    if ($changedResults.Count -eq 0) {
        return 'No repository changes were needed'
    }

    $pullRequestResults = @($changedResults | Where-Object { $_.Mode -eq 'PullRequest' })
    $directResults = @($changedResults | Where-Object { $_.Mode -ne 'PullRequest' })

    $summaryParts = @()
    if ($directResults.Count -gt 0) {
        $summaryParts += "$($directResults.Count) direct branch update(s)"
    }
    if ($pullRequestResults.Count -gt 0) {
        $summaryParts += "$($pullRequestResults.Count) pull request branch update(s)"
    }

    return ($summaryParts -join ' - ')
}

function Set-AzDoEnvironmentConfiguration {
    <#
    .SYNOPSIS
    Applies selected credentials, Dataverse roles, variable-group checks and pipeline access.
    .NOTES
    DEV authorizes EXPORT; other roles use DeployPipeline (BUILD is passed there for
    validation). Existing-connection markers skip endpoint recreation and federation.
    WIF issuer/subject must come from Azure DevOps before adding the Entra credential;
    missing federation metadata warns for manual completion.
    All groups get locking; only non-DEV/non-BUILD targets request deployment approval.
    Example CR/EV variables are scaffolds, not discovered connection IDs or values.
    Honors ShouldProcess at entry; provisioning is not transactional.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][object]$EnvironmentConfiguration,
        [Parameter(Mandatory)][string]$OrganizationName,
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter()][object]$ExportPipeline,
        [Parameter()][object]$DeployPipeline
    )

    if (-not $PSCmdlet.ShouldProcess("$OrganizationName/$ProjectName", 'Configure Azure DevOps deployment environment')) { return }

    $creds = $EnvironmentConfiguration.Credentials
    $serviceAccountUPN = $EnvironmentConfiguration.ServiceAccountUPN
    $isDevelopmentEnvironment = $false
    if ($EnvironmentConfiguration.PSObject.Properties.Name -contains 'IsDevelopmentEnvironment') {
        $isDevelopmentEnvironment = [bool]$EnvironmentConfiguration.IsDevelopmentEnvironment
    }
    $isBuildValidationEnvironment = $false
    if ($EnvironmentConfiguration.PSObject.Properties.Name -contains 'IsBuildValidationEnvironment') {
        $isBuildValidationEnvironment = [bool]$EnvironmentConfiguration.IsBuildValidationEnvironment
    }

    $pipelineForPermissions = if ($isDevelopmentEnvironment) { $ExportPipeline } else { $DeployPipeline }

    $endpoint = $null
    if (-not $creds.IsExistingServiceConnection) {
        $endpointParams = @{
            ProjectName         = $ProjectName
            ServiceEndpointName = $EnvironmentConfiguration.ShortName
            EnvironmentUrl      = $EnvironmentConfiguration.Url
            ApplicationId       = $creds.ApplicationId
            TenantId            = $creds.TenantId
        }

        if ($creds.AuthType -eq 'WIF') {
            $endpointParams.AuthType = 'WIF'
        }
        else {
            $clientSecret = [string](Get-OptionalObjectPropertyValue -InputObject $creds -PropertyName 'ClientSecret')
            if (
                [string]::IsNullOrWhiteSpace($clientSecret) -and
                [bool](Get-OptionalObjectPropertyValue -InputObject $creds -PropertyName 'RotateSecret')
            ) {
                $rotationApplicationObjectId = [string](Get-OptionalObjectPropertyValue -InputObject $creds -PropertyName 'ApplicationObjectId')
                $rotationTenantId = [string](Get-OptionalObjectPropertyValue -InputObject $creds -PropertyName 'TenantId')
                if ([string]::IsNullOrWhiteSpace($rotationApplicationObjectId) -or [string]::IsNullOrWhiteSpace($rotationTenantId)) {
                    throw 'Deferred client-secret rotation requires ApplicationObjectId and TenantId.'
                }
                Write-Host 'Generating the client secret requested during setup...' -ForegroundColor Yellow
                $clientSecret = New-EntraIdApplicationSecret -ApplicationObjectId $rotationApplicationObjectId -TenantId $rotationTenantId
            }
            $endpointParams.ClientSecret = $clientSecret
            $endpointParams.AuthType = 'Secret'
        }

        $endpoint = Initialize-AzDoServiceEndpoint @endpointParams

        if ($creds.AuthType -eq 'WIF') {
            $wifIssuer = $endpoint.authorization.parameters.workloadIdentityFederationIssuer
            $wifSubject = $endpoint.authorization.parameters.workloadIdentityFederationSubject
            if ($wifIssuer -and $wifSubject) {
                $appObjectId = $creds.ApplicationObjectId
                if (-not $appObjectId) {
                    $graphToken = Get-AuthToken -ResourceUrl 'https://graph.microsoft.com' -TenantId $creds.TenantId
                    $gHeaders = @{ Authorization = "Bearer $($graphToken.AccessToken)" }
                    $gUri = "https://graph.microsoft.com/v1.0/applications?`$filter=appId eq '$($creds.ApplicationId)'&`$select=id,appId"
                    $gResult = Invoke-RestMethod -Uri $gUri -Headers $gHeaders -Method Get
                    if ($gResult.value.Count -gt 0) { $appObjectId = $gResult.value[0].id }
                }
                if ($appObjectId) {
                    $safeOrgName = ConvertTo-UrlSafeName -Name $OrganizationName
                    $safeProjectName = ConvertTo-UrlSafeName -Name $ProjectName
                    $safeSCName = ConvertTo-UrlSafeName -Name $EnvironmentConfiguration.ShortName
                    [void](Add-EntraIdFederatedCredential `
                        -ApplicationObjectId $appObjectId `
                        -TenantId $creds.TenantId `
                        -Issuer $wifIssuer `
                        -Subject $wifSubject `
                        -CredentialName "AzDO-$safeOrgName-$safeProjectName-$safeSCName")
                }
                else {
                    Write-Warning 'Could not determine Application Object ID. Federated credential not added - add it manually in Entra ID.'
                }
            }
            else {
                Write-Warning 'Service connection does not expose WIF issuer/subject properties. Federated credential not added - add it manually in Entra ID.'
            }
        }
    }
    else {
        $endpoints = @(Get-VSTeamServiceEndpoint -ProjectName $ProjectName -ErrorAction SilentlyContinue)
        $endpoint = $endpoints | Where-Object { $_.name -eq $EnvironmentConfiguration.ShortName } | Select-Object -First 1
    }

    if ($endpoint -and $endpoint.id -and $pipelineForPermissions) {
        Initialize-AzDoPipelinePermission -Organization $OrganizationName -Project $ProjectName -ResourceType 'endpoint' -ResourceId $endpoint.id -PipelineId $pipelineForPermissions.id
    }

    if (-not $isDevelopmentEnvironment) {
        $azDoEnv = Initialize-AzDoEnvironment -Organization $OrganizationName -Project $ProjectName -EnvironmentName $EnvironmentConfiguration.ShortName -Description "Deployment environment for $($EnvironmentConfiguration.ShortName)"
        if ($azDoEnv -and $DeployPipeline) {
            Initialize-AzDoPipelinePermission -Organization $OrganizationName -Project $ProjectName -ResourceType 'environment' -ResourceId $azDoEnv.id -PipelineId $DeployPipeline.id
        }
    }

    Initialize-DataverseApplicationUser -EnvironmentUrl $EnvironmentConfiguration.Url -ApplicationId $creds.ApplicationId -TenantId $creds.TenantId
    Initialize-DataverseServiceAccountUser -EnvironmentUrl $EnvironmentConfiguration.Url -ServiceAccountUPN $serviceAccountUPN -TenantId $creds.TenantId

    $groupName = "Environment-$($EnvironmentConfiguration.ShortName)"
    $variables = @{
        'DATAVERSECONNREF_example_uniquename' = 'connectionid'
        'DATAVERSEENVVAR_example_uniquename'  = 'value'
        'DataverseServiceAccountUPN' = $serviceAccountUPN
    }

    $varGroup = Initialize-AzDoVariableGroup `
        -Organization $OrganizationName `
        -Project $ProjectName `
        -GroupName $groupName `
        -Variables $variables `
        -RequireDeploymentApproval (-not $isDevelopmentEnvironment -and -not $isBuildValidationEnvironment)

    if ($varGroup -and $varGroup.id -and $pipelineForPermissions) {
        Initialize-AzDoPipelinePermission -Organization $OrganizationName -Project $ProjectName -ResourceType 'variablegroup' -ResourceId $varGroup.id -PipelineId $pipelineForPermissions.id
    }
}

function Get-AzDoSetupArtifactsPreview {
    <#
    .SYNOPSIS
    Generates Azure DevOps setup files and returns repository changes for review.
    .DESCRIPTION
    Uses the same artifact generator as publication inside an isolated temporary tree.
    The selected repository is never modified.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$CopyRoot,
        [Parameter(Mandatory)][object]$MainRepo,
        [Parameter(Mandatory)][string]$SharedRepositoryName,
        [Parameter(Mandatory)][string]$SharedRepositoryRef,
        [Parameter(Mandatory)][bool]$UseAlm4DataverseExtension,
        [Parameter(Mandatory)][array]$BranchStates,
        [Parameter()][System.Collections.IDictionary]$ProviderOptions = @{},
        [Parameter()][AllowNull()][object]$SolutionData
    )

    $settings = Get-AlmSetupConfiguration `
        -Provider azDO `
        -Repository $SharedRepositoryName `
        -Ref $SharedRepositoryRef `
        -BranchStates $BranchStates `
        -ProviderOptions $ProviderOptions
    $buildValidationEnvironments = Get-AlmSetupBuildValidationEnvironmentMap -BranchStates $BranchStates
    $solutions = if ($SolutionData) { @($SolutionData.Solutions) } else { $null }
    $previewRelativePaths = @(Get-ChildItem -LiteralPath $CopyRoot -Force -ErrorAction Stop | ForEach-Object { [string]$_.Name })
    if ('alm-config.psd1' -notin $previewRelativePaths) {
        $previewRelativePaths += 'alm-config.psd1'
    }
    $previewRoot = New-SetupPreviewRoot -BaseRoot $RepoRoot -RelativePaths $previewRelativePaths

    try {
        $deployWorkflowBranchDefinitions = @($BranchStates | ForEach-Object {
            [pscustomobject]@{
                BranchName             = [string]$_.BranchName
                DeploymentEnvironments = @($_.DeploymentEnvironments)
            }
        })
        Invoke-AzDoSetupArtifactGeneration `
            -RepoRoot $previewRoot `
            -CopyRoot $CopyRoot `
            -MainRepo $MainRepo `
            -SharedRepositoryName $SharedRepositoryName `
            -SharedRepositoryRef $SharedRepositoryRef `
            -Branch ([string](Get-OptionalObjectPropertyValue -InputObject $BranchStates[0] -PropertyName 'BranchName')) `
            -UseAlm4DataverseExtension $UseAlm4DataverseExtension `
            -Solutions $solutions `
            -DeploymentEnvironments @() `
            -DeployWorkflowBranchDefinitions $deployWorkflowBranchDefinitions `
            -BuildValidationEnabled ($buildValidationEnvironments.Count -gt 0) `
            -BuildValidationEnvironments $buildValidationEnvironments `
            -SetupSettings $settings

        $configPath = Join-Path $previewRoot 'alm-config.psd1'
        if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
            throw 'The generated alm-config.psd1 preview was not created.'
        }

        $pipelineRoot = Join-Path $previewRoot 'pipelines'
        if (-not (Test-Path -LiteralPath $pipelineRoot -PathType Container)) {
            throw 'The generated Azure DevOps pipeline preview directory was not created.'
        }

        return [pscustomobject]@{
            FileChanges = @(Get-SetupRepositoryFileChange -RepositoryRoot $RepoRoot -PreviewRoot $previewRoot -RelativePaths $previewRelativePaths)
        }
    }
    finally {
        Remove-Item -LiteralPath $previewRoot -Recurse -Force -ErrorAction Stop
    }
}

function Invoke-AzDoBranchAwareSetupApply {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'MainRepoWorkingRoot', Justification = 'Captured by the nested branch publication script block.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'MainRepo', Justification = 'Captured by the nested branch publication script block.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'DefaultBranch', Justification = 'Captured by the nested branch publication script block.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'AccessToken', Justification = 'Captured by the nested branch publication script block.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'CopyRoot', Justification = 'Captured by the nested branch publication script block.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'UseAlm4DataverseExtension', Justification = 'Captured by the nested branch publication script block.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MainRepoWorkingRoot,
        [Parameter(Mandatory)][object]$MainRepo,
        [Parameter(Mandatory)][string]$DefaultBranch,
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][string]$CopyRoot,
        [Parameter(Mandatory)][string]$SharedRepositoryName,
        [Parameter(Mandatory)][string]$SharedRepositoryRef,
        [Parameter(Mandatory)][bool]$UseAlm4DataverseExtension,
        [Parameter(Mandatory)][object]$WizardState,
        [Parameter()][System.Collections.IDictionary]$ProviderOptions = @{}
    )

    $branchStates = @($WizardState.BranchStates)
    $buildValidationEnvironments = Get-AlmSetupBuildValidationEnvironmentMap -BranchStates $branchStates
    $buildValidationEnabled = $buildValidationEnvironments.Count -gt 0
    $buildValidationEnvironmentName = if ($buildValidationEnvironments.Count -eq 1) {
        [string]@($buildValidationEnvironments.Values)[0]
    }
    else {
        ''
    }
    $setupSettings = Get-AlmSetupConfiguration `
        -Provider azDO `
        -Repository $SharedRepositoryName `
        -Ref $SharedRepositoryRef `
        -BranchStates $branchStates `
        -ProviderOptions $ProviderOptions
    $solutions = if ($WizardState.SolutionData) { @($WizardState.SolutionData.Solutions) } else { $null }
    $publishResults = @()
    $publishPlan = Get-OptionalObjectPropertyValue -InputObject $WizardState -PropertyName 'PublishPlan'
    if ($null -eq $publishPlan) {
        throw 'No repository publication plan was recorded. Revisit the publication method step before applying.'
    }

    $targetBranch = [string](Get-OptionalObjectPropertyValue -InputObject $publishPlan -PropertyName 'TargetBranch')
    if ([string]::IsNullOrWhiteSpace($targetBranch)) {
        throw 'The repository publication plan has no target branch. Revisit the publication method step before applying.'
    }

    $deployWorkflowBranchDefinitions = @($branchStates | ForEach-Object {
        [pscustomobject]@{
            BranchName             = [string]$_.BranchName
            DeploymentEnvironments = @($_.DeploymentEnvironments)
        }
    })

    $publishResult = Invoke-WithErrorHandling `
        -OperationName "Publishing repository changes for all branches on '$targetBranch'" `
        -StatusMessage "Publishing repository changes for all branches on '$targetBranch'..." `
        -CaptureOutputInPanel `
        -ScriptBlock {
            Publish-AzDoBranchSetupChange `
                -RepoRoot $MainRepoWorkingRoot `
                -ConfiguredBranch $targetBranch `
                -PublishPlan $publishPlan `
                -DefaultBranch $DefaultBranch `
                -AccessToken $AccessToken `
                -Repository $MainRepo `
                -CopyRoot $CopyRoot `
                -SharedRepositoryName $SharedRepositoryName `
                -SharedRepositoryRef $SharedRepositoryRef `
                -UseAlm4DataverseExtension $UseAlm4DataverseExtension `
                -Solutions $solutions `
                -DeploymentEnvironments @() `
                -DeployWorkflowBranchDefinitions $deployWorkflowBranchDefinitions `
                -BuildValidationEnabled $buildValidationEnabled `
                -BuildValidationEnvironmentName $buildValidationEnvironmentName `
                -BuildValidationEnvironments $buildValidationEnvironments `
                -SetupSettings $setupSettings
        }

    $publishResults += [pscustomobject]@{
        ConfiguredBranch = $targetBranch
        BranchName       = $publishResult.BranchName
        TargetBranch     = $publishResult.TargetBranch
        PullRequestUrl   = $publishResult.PullRequestUrl
        Mode             = $publishResult.Mode
        HasChanges       = $publishResult.HasChanges
    }

    $enabledBuildBranches = @($branchStates | Where-Object { $_.BuildValidationEnabled -and $_.BuildValidationEnvironmentConfiguration })
    return [pscustomobject]@{
        BranchStates                              = $branchStates
        SolutionData                              = $WizardState.SolutionData
        SolutionSourceBranch                      = $WizardState.SolutionSourceBranch
        BuildValidationEnabled                    = $buildValidationEnabled
        BuildValidationEnvironmentName            = $buildValidationEnvironmentName
        BuildValidationBaselineRelease            = $(if ($enabledBuildBranches.Count -eq 1) { [string]$enabledBuildBranches[0].BuildValidationBaselineRelease } else { '' })
        BuildValidationEnvironmentConfiguration   = $(if ($enabledBuildBranches.Count -eq 1) { $enabledBuildBranches[0].BuildValidationEnvironmentConfiguration } else { $null })
        BuildValidationEnvironmentConfigurations   = @($enabledBuildBranches | ForEach-Object { $_.BuildValidationEnvironmentConfiguration })
        PublishResults                            = @($publishResults)
    }
}

function Get-AzDoSetupResourceChange {
    <#
    .SYNOPSIS
    Describes Azure DevOps and Dataverse changes deferred until setup is applied.
    .DESCRIPTION
    The plan contains resource names and settings only; credential values are omitted.
    When SharedRepositoryState is supplied, shared-repository creation and version
    reconciliation already performed during setup are disclosed as applied.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$BranchStates,
        [Parameter(Mandatory)][object]$SelectedProject,
        [Parameter(Mandatory)][object]$MainRepo,
        [Parameter(Mandatory)][string]$SharedRepositoryName,
        [Parameter()][System.Collections.IDictionary]$SharedRepositoryState
    )

    $changes = [System.Collections.Generic.List[object]]::new()
    if ($SharedRepositoryState) {
        $sharedName = if ([string]::IsNullOrWhiteSpace([string](Get-OptionalObjectPropertyValue -InputObject $SharedRepositoryState -PropertyName 'Name'))) {
            $SharedRepositoryName
        }
        else {
            [string](Get-OptionalObjectPropertyValue -InputObject $SharedRepositoryState -PropertyName 'Name')
        }
        if ([bool](Get-OptionalObjectPropertyValue -InputObject $SharedRepositoryState -PropertyName 'CreatedDuringSetup')) {
            $changes.Add([pscustomobject]@{
                    Action   = 'Already applied'
                    Resource = 'Shared repository'
                    Target   = $sharedName
                    Details  = 'Created during setup before preview; Apply reuses it and does not create another.'
                })
        }
        if ([bool](Get-OptionalObjectPropertyValue -InputObject $SharedRepositoryState -PropertyName 'VersionUpdatedDuringSetup')) {
            $changes.Add([pscustomobject]@{
                    Action   = 'Already applied'
                    Resource = 'Shared repository history'
                    Target   = $sharedName
                    Details  = 'Checked and reconciled during setup before preview; Apply uses the updated template source.'
                })
        }
    }
    $yamlFiles = @(
        'pipelines/BUILD.yml',
        'pipelines/EXPORT.yml',
        'pipelines/IMPORT.yml'
    )
    $yamlFiles += @($BranchStates |
        Where-Object { @($_.DeploymentEnvironments).Count -gt 0 } |
        ForEach-Object { "pipelines/DEPLOY-$($_.BranchName).yml" })
    $pipelineNames = @($yamlFiles | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) } | Select-Object -Unique)

    $projectRepositoryTarget = "$($SelectedProject.Name)/$($MainRepo.Name)"
    $changes.Add([pscustomobject]@{
            Action   = 'Create or retarget'
            Resource = 'Azure DevOps YAML pipelines'
            Target   = $projectRepositoryTarget
            Details  = "Register $($pipelineNames -join ', ') from the generated YAML files."
        })
    $changes.Add([pscustomobject]@{
            Action   = 'Ensure'
            Resource = 'Azure DevOps Build Service permission'
            Target   = $projectRepositoryTarget
            Details  = "Grant the project's Build Service Contribute permission on the main repository."
        })
    $changes.Add([pscustomobject]@{
            Action   = 'Authorize'
            Resource = 'Azure DevOps pipeline repository permissions'
            Target   = "$($MainRepo.Name) and $SharedRepositoryName"
            Details  = "Allow the generated pipelines ($($pipelineNames -join ', ')) to access both repositories."
        })

    $environmentTargets = [System.Collections.Generic.List[object]]::new()
    foreach ($branchState in $BranchStates) {
        if ($branchState.DevEnvironmentConfiguration) {
            $environmentTargets.Add([pscustomobject]@{
                    Role                     = 'DEV'
                    EnvironmentConfiguration = $branchState.DevEnvironmentConfiguration
                    PipelineName             = 'EXPORT'
                    IsDevelopmentEnvironment = $true
                    IsBuildValidationEnvironment = $false
                    RequireDeploymentApproval = $false
                })
        }

        if ($branchState.BuildValidationEnabled -and $branchState.BuildValidationEnvironmentConfiguration) {
            $environmentTargets.Add([pscustomobject]@{
                    Role                     = 'BUILD validation'
                    EnvironmentConfiguration = $branchState.BuildValidationEnvironmentConfiguration
                    PipelineName             = 'BUILD'
                    IsDevelopmentEnvironment = $false
                    IsBuildValidationEnvironment = $true
                    RequireDeploymentApproval = $false
                })
        }

        foreach ($environment in @($branchState.DeploymentEnvironments)) {
            $environmentTargets.Add([pscustomobject]@{
                    Role                     = 'Deployment'
                    EnvironmentConfiguration = $environment
                    PipelineName             = "DEPLOY-$($branchState.BranchName)"
                    IsDevelopmentEnvironment = $false
                    IsBuildValidationEnvironment = $false
                    RequireDeploymentApproval = $true
                })
        }
    }

    $annotatedCredentialTargets = @{}
    foreach ($environmentTarget in $environmentTargets) {
        $environment = $environmentTarget.EnvironmentConfiguration
        $environmentName = [string]$environment.ShortName
        $credentials = Get-OptionalObjectPropertyValue -InputObject $environment -PropertyName 'Credentials'
        if (-not $credentials) {
            throw "No credentials were captured for Azure DevOps environment '$environmentName'."
        }

        $isExistingServiceConnection = [bool](Get-OptionalObjectPropertyValue -InputObject $credentials -PropertyName 'IsExistingServiceConnection')
        $authType = [string](Get-OptionalObjectPropertyValue -InputObject $credentials -PropertyName 'AuthType')
        $rotateSecret = [bool](Get-OptionalObjectPropertyValue -InputObject $credentials -PropertyName 'RotateSecret')
        $createdDuringSetup = [bool](Get-OptionalObjectPropertyValue -InputObject $credentials -PropertyName 'CreatedDuringSetup')
        if ($createdDuringSetup) {
            $credentialTarget = "$($credentials.Name) ($($credentials.ApplicationId))"
            if (-not $annotatedCredentialTargets.ContainsKey($credentialTarget)) {
                $annotatedCredentialTargets[$credentialTarget] = $true
                $changes.Add([pscustomobject]@{
                        Action   = 'Already applied'
                        Resource = 'Entra application'
                        Target   = $credentialTarget
                        Details  = 'Created during setup before preview; Apply reuses it and does not create another.'
                    })
            }
        }
        if ($isExistingServiceConnection) {
            $connectionDetails = 'Reuse the selected existing service connection; do not replace its credentials.'
            $connectionAction = 'Reuse'
        }
        else {
            $connectionDetails = "Create or reconcile the Power Platform service connection using $authType authentication."
            if ($authType -eq 'Secret') {
                if ($rotateSecret) {
                    $connectionDetails += ' Generate and store a new client secret when you apply; its value is hidden.'
                }
                else {
                    $connectionDetails += ' The client-secret value is hidden.'
                }
            }
            $connectionAction = 'Create or reconcile'
        }
        $connectionDetails += " Authorize pipeline '$($environmentTarget.PipelineName)' to use it when that pipeline exists."
        $changes.Add([pscustomobject]@{
                Action   = $connectionAction
                Resource = 'Azure DevOps service connection'
                Target   = "$($SelectedProject.Name)/$environmentName"
                Details  = $connectionDetails
            })

        if (-not $isExistingServiceConnection -and $authType -eq 'WIF') {
            $changes.Add([pscustomobject]@{
                    Action   = 'Create or update'
                    Resource = 'Entra federated identity credential'
                    Target   = "$($SelectedProject.Name)/$environmentName"
                    Details  = 'Use the issuer and subject returned by the Azure DevOps workload-identity service connection.'
                })
        }

        if (-not $environmentTarget.IsDevelopmentEnvironment) {
            $changes.Add([pscustomobject]@{
                    Action   = 'Ensure'
                    Resource = 'Azure DevOps environment'
                    Target   = "$($SelectedProject.Name)/$environmentName"
                    Details  = "Create the environment if missing and authorize pipeline '$($environmentTarget.PipelineName)' when available."
                })
        }

        $variableGroupName = "Environment-$environmentName"
        $variableGroupDetails = 'Create the variable group if missing with the scaffold connection/environment variables and service-account UPN; existing variable values are not overwritten. Ensure an exclusive lock and authorize the relevant pipeline.'
        if ($environmentTarget.RequireDeploymentApproval) {
            $variableGroupDetails += ' Ensure the deployment-approver team and approval check.'
        }
        else {
            $variableGroupDetails += ' Existing approval checks are retained; do not add a new deployment-approval check.'
        }
        $changes.Add([pscustomobject]@{
                Action   = 'Ensure'
                Resource = 'Azure DevOps variable group and checks'
                Target   = "$($SelectedProject.Name)/$variableGroupName"
                Details  = $variableGroupDetails
            })
        $changes.Add([pscustomobject]@{
                Action   = 'Ensure'
                Resource = 'Dataverse application and service-account users'
                Target   = $environmentName
                Details  = 'Ensure both configured users have the System Administrator role.'
            })
    }

    return @($changes.ToArray())
}

function Invoke-AzDoSetupPostApply {
    <#
    .SYNOPSIS
    Registers pipelines, grants resource permissions, and applies environment settings.
    .DESCRIPTION
    Runs as part of the guided Apply action so non-skipped failures return to the menu.
    Existing pipeline and environment helpers reconcile resources when Apply is retried.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'SharedRepository', Justification = 'Captured by nested pipeline-permission callbacks.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'OrganizationName', Justification = 'Captured by nested pipeline-permission and environment callbacks.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$SetupResult,
        [Parameter(Mandatory)][object]$SelectedProject,
        [Parameter(Mandatory)][object]$MainRepo,
        [Parameter(Mandatory)][object]$SharedRepository,
        [Parameter(Mandatory)][string]$OrganizationName
    )

    $branchStates = @($SetupResult.BranchStates)
    $buildValidationEnabled = @($branchStates | Where-Object { $_.BuildValidationEnabled }).Count -gt 0
    $script:yamlFiles = @(
        'pipelines/BUILD.yml',
        'pipelines/EXPORT.yml',
        'pipelines/IMPORT.yml'
    )
    $script:yamlFiles += @($branchStates | Where-Object { @($_.DeploymentEnvironments).Count -gt 0 } | ForEach-Object { "pipelines/DEPLOY-$($_.BranchName).yml" })

    Write-Section -Message 'Ensuring Build Service has Contribute on main repo'
    Invoke-WithErrorHandling `
        -OperationName 'Setting Up Build Service Permissions' `
        -StatusMessage 'Granting build service permissions for the main repository...' `
        -CaptureOutputInPanel `
        -ScriptBlock {
            Initialize-AzDoBuildServiceRepositoryPermission `
                -ProjectName $SelectedProject.Name `
                -ProjectId $SelectedProject.Id `
                -RepositoryId $MainRepo.Id
        } | Out-Null

    Invoke-WithErrorHandling `
        -OperationName 'Creating Pipeline Definitions' `
        -StatusMessage 'Creating Azure DevOps pipeline definitions...' `
        -CaptureOutputInPanel `
        -ScriptBlock {
            Initialize-AzDoMainRepositoryPipeline `
                -Project $SelectedProject.Name `
                -Repository $MainRepo `
                -YamlFiles $script:yamlFiles `
                -FolderPath "\$($MainRepo.Name)"
        } | Out-Null

    Write-Section -Message 'Authorizing pipelines for repositories'
    Invoke-WithErrorHandling `
        -OperationName 'Authorizing Pipelines for Repositories' `
        -AllowSkip `
        -StatusMessage 'Authorizing pipelines to access the required repositories...' `
        -CaptureOutputInPanel `
        -ScriptBlock {
            $pipelineNames = @($script:yamlFiles | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) } | Select-Object -Unique)
            $allPipelines = Get-VSTeamBuildDefinition -ProjectName $SelectedProject.Name
            $pipelineFolder = "\$($MainRepo.Name)"

            foreach ($name in $pipelineNames) {
                $pipeline = $allPipelines | Where-Object { $_.name -eq $name -and $_.path -eq $pipelineFolder } | Select-Object -First 1
                if ($pipeline) {
                    $mainRepoResourceId = "$($SelectedProject.Id).$($MainRepo.Id)"
                    Initialize-AzDoPipelinePermission -Organization $OrganizationName -Project $SelectedProject.Name -ResourceType 'repository' -ResourceId $mainRepoResourceId -PipelineId $pipeline.id

                    $sharedRepoResourceId = "$($SelectedProject.Id).$($SharedRepository.Id)"
                    Initialize-AzDoPipelinePermission -Organization $OrganizationName -Project $SelectedProject.Name -ResourceType 'repository' -ResourceId $sharedRepoResourceId -PipelineId $pipeline.id
                }
            }
        } | Out-Null

    $pipelineFolder = "\$($MainRepo.Name)"
    $allPipelines = Get-VSTeamBuildDefinition -ProjectName $SelectedProject.Name
    $buildPipeline = $allPipelines | Where-Object { $_.name -eq 'BUILD' -and $_.path -eq $pipelineFolder } | Select-Object -First 1
    $exportPipeline = $allPipelines | Where-Object { $_.name -eq 'EXPORT' -and $_.path -eq $pipelineFolder } | Select-Object -First 1
    $deployPipelinesByBranch = @{}
    foreach ($branchState in $branchStates) {
        $deployPipelineName = "DEPLOY-$($branchState.BranchName)"
        $deployPipeline = $allPipelines | Where-Object { $_.name -eq $deployPipelineName -and $_.path -eq $pipelineFolder } | Select-Object -First 1
        if ($deployPipeline) {
            $deployPipelinesByBranch[$branchState.BranchName] = $deployPipeline
        }
        elseif (@($branchState.DeploymentEnvironments).Count -gt 0) {
            Write-Warning "$deployPipelineName pipeline not found. Skipping some deployment authorizations for branch '$($branchState.BranchName)'."
        }
    }

    if (-not $exportPipeline) { Write-Warning 'EXPORT pipeline not found. Skipping some DEV authorizations.' }
    if ($buildValidationEnabled -and -not $buildPipeline) { Write-Warning 'BUILD pipeline not found. Skipping some BUILD validation authorizations.' }

    Write-Section -Message 'Configure DEV environments'
    $devBranchStates = @($branchStates | Where-Object { $_.DevEnvironmentConfiguration })
    if ($devBranchStates.Count -eq 0) {
        [Spectre.Console.AnsiConsole]::MarkupLine('[yellow]No DEV environment configuration was captured in the wizard, so this step will be skipped.[/]')
    }
    else {
        foreach ($branchState in $devBranchStates) {
            $deployPipeline = if ($deployPipelinesByBranch.ContainsKey($branchState.BranchName)) { $deployPipelinesByBranch[$branchState.BranchName] } else { $null }
            Invoke-WithErrorHandling `
                -OperationName "Applying DEV environment configuration for branch '$($branchState.BranchName)'" `
                -AllowSkip `
                -StatusMessage "Applying DEV environment configuration for branch '$($branchState.BranchName)'..." `
                -CaptureOutputInPanel `
                -ScriptBlock {
                    Set-AzDoEnvironmentConfiguration `
                        -EnvironmentConfiguration $branchState.DevEnvironmentConfiguration `
                        -OrganizationName $OrganizationName `
                        -ProjectName $SelectedProject.Name `
                        -ExportPipeline $exportPipeline `
                        -DeployPipeline $deployPipeline
                } | Out-Null
        }
    }

    Write-Section -Message 'Configure branch BUILD validation environments'
    $enabledBuildBranchStates = @($branchStates | Where-Object { $_.BuildValidationEnabled })
    $buildBranchesWithoutEnvironment = @($enabledBuildBranchStates | Where-Object { -not $_.BuildValidationEnvironmentConfiguration })
    if ($buildBranchesWithoutEnvironment.Count -gt 0) {
        $branchNames = @($buildBranchesWithoutEnvironment | ForEach-Object { [string]$_.BranchName }) -join ', '
        throw "BUILD validation is enabled for branch(es) '$branchNames', but no environment configuration was returned."
    }
    if ($enabledBuildBranchStates.Count -eq 0) {
        [Spectre.Console.AnsiConsole]::MarkupLine('[yellow]BUILD validation is disabled for every branch, so BUILD environment configuration will be skipped.[/]')
    }
    elseif (-not $buildPipeline) {
        [Spectre.Console.AnsiConsole]::MarkupLine('[yellow]BUILD pipeline was not found, so BUILD validation environment configuration could not be applied.[/]')
    }
    else {
        $configuredBuildEnvironmentNames = @()
        foreach ($branchState in $enabledBuildBranchStates) {
            $environmentConfiguration = $branchState.BuildValidationEnvironmentConfiguration
            $environmentName = [string]$environmentConfiguration.ShortName
            if ($configuredBuildEnvironmentNames -contains $environmentName) {
                continue
            }
            $configuredBuildEnvironmentNames += $environmentName

            Invoke-WithErrorHandling `
                -OperationName "Applying BUILD validation environment configuration for branch '$($branchState.BranchName)'" `
                -AllowSkip `
                -StatusMessage "Applying BUILD validation environment '$environmentName'..." `
                -CaptureOutputInPanel `
                -ScriptBlock {
                    Set-AzDoEnvironmentConfiguration `
                        -EnvironmentConfiguration $environmentConfiguration `
                        -OrganizationName $OrganizationName `
                        -ProjectName $SelectedProject.Name `
                        -ExportPipeline $null `
                        -DeployPipeline $buildPipeline
                } | Out-Null
        }
    }

    Write-Section -Message 'Configure deployment environments'
    $deploymentBranchStates = @($branchStates | Where-Object { @($_.DeploymentEnvironments).Count -gt 0 })
    if ($deploymentBranchStates.Count -eq 0) {
        [Spectre.Console.AnsiConsole]::MarkupLine('[yellow]No deployment environments were configured in the wizard, so this step will be skipped.[/]')
    }
    else {
        foreach ($branchState in $deploymentBranchStates) {
            $deployPipeline = if ($deployPipelinesByBranch.ContainsKey($branchState.BranchName)) { $deployPipelinesByBranch[$branchState.BranchName] } else { $null }
            foreach ($deploymentEnvironment in @($branchState.DeploymentEnvironments)) {
                Write-Section -Message "Applying environment configuration for '$($deploymentEnvironment.ShortName)' on branch '$($branchState.BranchName)'"
                Invoke-WithErrorHandling `
                    -OperationName "Applying environment configuration for '$($deploymentEnvironment.ShortName)' on branch '$($branchState.BranchName)'" `
                    -AllowSkip `
                    -StatusMessage "Applying configuration for '$($deploymentEnvironment.ShortName)' on branch '$($branchState.BranchName)'..." `
                    -CaptureOutputInPanel `
                    -ScriptBlock {
                        Set-AzDoEnvironmentConfiguration `
                            -EnvironmentConfiguration $deploymentEnvironment `
                            -OrganizationName $OrganizationName `
                            -ProjectName $SelectedProject.Name `
                            -ExportPipeline $exportPipeline `
                            -DeployPipeline $deployPipeline
                    } | Out-Null
            }
        }
    }
}

function Invoke-AzDoBranchAwareSetup {
    <#
    .SYNOPSIS
    Runs guided branch configuration with an optional preview and repository publication.
    .PARAMETER PostApplyAction
    Runs provider-specific pipeline and environment setup after repository publication.
    Failures return to the guided menu with selections retained.
    .PARAMETER PreApplyAction
    Runs after the user chooses Apply and before repository publication. Use it to
    reconcile the shared repository, which setup must not change while the preview is
    still being reviewed.
    .PARAMETER PrerequisiteSteps
    Initial guided steps displayed before branch configuration, including shared-repository
    selection and version reconciliation. Authentication and project/application-repository
    selection are completed before the menu and are not listed as rows.
    .PARAMETER SharedRepositoryState
    Mutable shared-repository name, ref, and template root used by preview and apply.
    .NOTES
    Returns BranchStates, SolutionData, SolutionSourceBranch, per-branch BUILD settings
    and publication results. Credential selection can provision Entra resources before
    preview. Requires authenticated setup context and shared UI helpers.
    Branch callbacks take allMappings then mappingToEdit positionally. Completed
    branch editing suppresses the separate DEV/deployment steps. Only DEV-configured
    branches can supply solution discovery; otherwise SolutionData stays null so
    publication preserves existing solution lists. Preview is optional, available
    after all setup steps are complete, and does not gate Apply. ApplyConfig limits
    the menu to publication planning and preview, using committed config. Publication
    is not transactional.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'allMappings', Justification = 'Required first positional argument in the nested branch-editor callback contracts.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'SelectedProject', Justification = 'Captured by the nested wizard actions.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'OrganizationName', Justification = 'Captured by the nested wizard actions.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'TenantId', Justification = 'Captured by the nested wizard actions.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MainRepoWorkingRoot,
        [Parameter(Mandatory)][object]$MainRepo,
        [Parameter(Mandatory)][object]$SelectedProject,
        [Parameter(Mandatory)][string]$OrganizationName,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$DefaultBranch,
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][string]$CopyRoot,
        [Parameter(Mandatory)][string]$SharedRepositoryName,
        [Parameter(Mandatory)][string]$SharedRepositoryRef,
        [Parameter(Mandatory)][bool]$UseAlm4DataverseExtension,
        [Parameter(Mandatory)][string]$ALM4DataverseRef,
        [Parameter()][System.Collections.IDictionary]$ProviderOptions = @{},
        [Parameter()][array]$PrerequisiteSteps = @(),
        [Parameter()][scriptblock]$PostApplyAction,
        [Parameter()][scriptblock]$PreApplyAction,
        [Parameter()][switch]$ApplyConfig,
        [Parameter()][switch]$IsNewRepository,
        [Parameter()][switch]$PreviewOnly,
        [Parameter()][switch]$Commit,
        [Parameter()][System.Collections.IDictionary]$SharedRepositoryState
    )

    if ($null -eq $SharedRepositoryState) {
        $SharedRepositoryState = [ordered]@{
            Name = $SharedRepositoryName
            Ref = $SharedRepositoryRef
            CopyRoot = $CopyRoot
        }
    }

    $credentialsCache = @()
    $serviceAccountsCache = @()

    $existingSetupState = Invoke-WithSpectreStatus -Status 'Inspecting existing Azure DevOps branch setup state...' -ScriptBlock {
        Get-AzDoRepositoryExistingSetupState `
            -RepoRoot $MainRepoWorkingRoot `
            -ProjectName $SelectedProject.Name `
            -DefaultBranch $DefaultBranch `
            -TenantId $TenantId `
            -SkipProviderState:$ApplyConfig
    }

    $initialBranchMappings = @(Get-AzDoInitialBranchMapping -ExistingSetupState $existingSetupState -DefaultBranch $DefaultBranch)
    $branchStates = @()
    foreach ($selectedBranchMapping in $initialBranchMappings) {
        $branchName = [string]$selectedBranchMapping.BranchName
        $existingBranchState = $existingSetupState.BranchStates | Where-Object { $_.BranchName -ieq $branchName } | Select-Object -First 1
        $existingDevEnvironment = Get-OptionalObjectPropertyValue -InputObject $selectedBranchMapping -PropertyName 'ExistingDevEnvironment'
        if ($null -eq $existingDevEnvironment) {
            $existingDevEnvironment = Get-OptionalObjectPropertyValue -InputObject $existingBranchState -PropertyName 'ExistingDevEnvironment'
        }
        $deploymentEnvironments = if ($existingBranchState) {
            @($existingBranchState.DeploymentEnvironments)
        }
        else {
            @($selectedBranchMapping.Environments)
        }

        $branchState = New-AzDoBranchSetupState `
            -BranchName $branchName `
            -ExistingDevEnvironment $existingDevEnvironment `
            -DeploymentEnvironments $deploymentEnvironments `
            -PublishPlan $null `
            -ExistingBuildValidationEnvironment (Get-OptionalObjectPropertyValue -InputObject $selectedBranchMapping -PropertyName 'ExistingBuildValidationEnvironment') `
            -BuildValidationEnvironmentName ([string](Get-OptionalObjectPropertyValue -InputObject $selectedBranchMapping -PropertyName 'BuildValidationEnvironmentName')) `
            -BuildValidationBaselineRelease ([string](Get-OptionalObjectPropertyValue -InputObject $selectedBranchMapping -PropertyName 'BuildValidationBaselineRelease'))
        if ($ApplyConfig) {
            $branchState.DevEnvironmentConfiguration = $existingDevEnvironment
        }
        $branchStates += $branchState
    }

    $wizardState = [pscustomobject]@{
        BranchStates         = @($branchStates)
        SolutionData         = $null
        LegacyConfigurationConversion = (Get-OptionalObjectPropertyValue -InputObject $existingSetupState -PropertyName 'LegacyConfigurationConversion')
        SolutionSourceBranch = $null
        BuildValidationEnabled = [bool](Get-OptionalObjectPropertyValue -InputObject $existingSetupState -PropertyName 'BuildValidationEnabled')
        BuildValidationBaselineRelease = ''
        BuildValidationEnvironmentConfiguration = (Get-OptionalObjectPropertyValue -InputObject $existingSetupState -PropertyName 'ExistingBuildValidationEnvironment')
        PublishPlan = $null
    }

    $ProviderOptions['azDOUseAlm4DataverseExtension'] = $UseAlm4DataverseExtension
    $branchSetupSteps = @(
        [pscustomobject]@{
            Name = 'Configure branches, dev and deployment envs'
            HelpDocRelativePath = 'docs/setup/azdo-automated-setup.md'
            SubItems = {
                Get-SetupBranchMenuItem -BranchStates @($wizardState.BranchStates)
            }
            Action = {
                param($menuTarget)
                $initialEditTarget = $menuTarget

                $existingEnvironmentConfigurations = @($existingSetupState.BranchStates | ForEach-Object { @($_.DeploymentEnvironments) } | Where-Object { $null -ne $_ })
                $currentBranchMappings = @($wizardState.BranchStates | ForEach-Object {
                    [pscustomobject]@{
                        BranchName                  = [string]$_.BranchName
                        DevEnvironmentConfiguration = $_.DevEnvironmentConfiguration
                        ExistingDevEnvironment      = $_.ExistingDevEnvironment
                        Environments                = @($_.DeploymentEnvironments)
                        BuildValidationEnabled = [bool]$_.BuildValidationEnabled
                        BuildValidationEnvironmentName = [string]$_.BuildValidationEnvironmentName
                        BuildValidationBaselineRelease = [string]$_.BuildValidationBaselineRelease
                        BuildValidationEnvironmentConfiguration = $_.BuildValidationEnvironmentConfiguration
                        ExistingBuildValidationEnvironment = $_.ExistingBuildValidationEnvironment
                        PublishPlan                 = (Get-OptionalObjectPropertyValue -InputObject $_ -PropertyName 'PublishPlan')
                    }
                })

                Write-AlmLegacyConfigurationConversionNotice -Conversion $wizardState.LegacyConfigurationConversion
                $selectedBranchMappings = @(Select-BranchEnvironmentMapping `
                    -EnvironmentConfigurations $existingEnvironmentConfigurations `
                    -InitialBranchMappings $currentBranchMappings `
                    -Title 'Manage deployment branches' `
                    -DocRelativePath 'docs/setup/azdo-automated-setup.md' `
                    -Ref $ALM4DataverseRef `
                    -InitialEditTarget $initialEditTarget `
                    -IsNewRepository:$IsNewRepository `
                    -EditDevEnvironmentScriptBlock {
                        param($allMappings, $mappingToEdit, $environmentNameToEdit)

                        Write-Section `
                            -Message "DEV environment for branch '$($mappingToEdit.BranchName)'"
                        $existingDevEnvironment = $mappingToEdit.ExistingDevEnvironment
                        $currentDevConfiguration = $mappingToEdit.DevEnvironmentConfiguration
                        $initialConfiguration = if ($currentDevConfiguration) { $currentDevConfiguration } else { $existingDevEnvironment }

                        if ($initialConfiguration) {
                            $existingDevEnvironmentUrl = [string](Get-OptionalObjectPropertyValue -InputObject $initialConfiguration -PropertyName 'Url')
                            $existingDevEnvironmentFriendlyName = [string](Get-OptionalObjectPropertyValue -InputObject $initialConfiguration -PropertyName 'FriendlyName')
                            if (-not [string]::IsNullOrWhiteSpace($existingDevEnvironmentUrl)) {
                                Write-Host "Existing DEV environment: $existingDevEnvironmentFriendlyName ($existingDevEnvironmentUrl)" -ForegroundColor DarkGray
                            }
                        }

                        if ([string]::IsNullOrWhiteSpace($environmentNameToEdit)) {
                            $configureDevEnvironment = Read-YesNo -Prompt "Configure a DEV environment for branch '$($mappingToEdit.BranchName)'?"
                            if (-not $configureDevEnvironment) {
                                return $null
                            }
                        }

                        $updatedDevConfiguration = Invoke-WithErrorHandling -OperationName "Configuring DEV environment for branch '$($mappingToEdit.BranchName)'" -ScriptBlock {
                            Invoke-AzDoEnvironmentConfigurationWizard `
                                -Title "Configure DEV environment for branch '$($mappingToEdit.BranchName)'" `
                                -DataverseEnvironmentPrompt "Select the DEV environment for branch '$($mappingToEdit.BranchName)'" `
                                -InitialConfiguration $initialConfiguration `
                                -InitialTargetName "Dev-$($mappingToEdit.BranchName)" `
                                -TargetNameStepName 'Target name' `
                                -TargetNameIsFixed `
                                -ExistingCredentials $credentialsCache `
                                -ExistingServiceAccounts $serviceAccountsCache `
                                -TenantId $TenantId `
                                -ProjectName $SelectedProject.Name `
                                -UseAlm4DataverseExtension $UseAlm4DataverseExtension `
                                -IsDevelopmentEnvironment $true `
                                -PromptGuidanceLines @(
                                    'Choose the branch-specific Dataverse environment used for development and solution discovery.',
                                    'Credentials and service-account ownership are configured in separate steps.'
                                ) `
                                -PromptGuidanceDocRelativePath 'docs/setup/azdo-automated-setup.md' `
                                -PromptGuidanceRef $ALM4DataverseRef `
                                -HelpDocRelativePath 'docs/setup/azdo-automated-setup.md' `
                                -HelpRef $ALM4DataverseRef
                        }

                        if ($null -eq $updatedDevConfiguration) {
                            return $mappingToEdit.DevEnvironmentConfiguration
                        }
                        if ($updatedDevConfiguration.Credentials -and -not ($credentialsCache | Where-Object { $_.ApplicationId -eq $updatedDevConfiguration.Credentials.ApplicationId -and $_.TenantId -eq $updatedDevConfiguration.Credentials.TenantId })) {
                            $credentialsCache += $updatedDevConfiguration.Credentials
                        }
                        if (-not [string]::IsNullOrWhiteSpace($updatedDevConfiguration.ServiceAccountUPN) -and $serviceAccountsCache -notcontains $updatedDevConfiguration.ServiceAccountUPN) {
                            $serviceAccountsCache += $updatedDevConfiguration.ServiceAccountUPN
                        }

                        return $updatedDevConfiguration
                    } `
                    -EditDeploymentEnvironmentsScriptBlock {
                        param($allMappings, $mappingToEdit, $environmentNameToEdit)
                        $initialEditEnvironmentName = $environmentNameToEdit

                        Write-Section `
                            -Message "Deployment environments for branch '$($mappingToEdit.BranchName)'"

                        $excludedUrl = $null
                        if ($mappingToEdit.DevEnvironmentConfiguration) {
                            $excludedUrl = $mappingToEdit.DevEnvironmentConfiguration.Url
                        }
                        elseif ($mappingToEdit.ExistingDevEnvironment) {
                            $excludedUrl = [string](Get-OptionalObjectPropertyValue -InputObject $mappingToEdit.ExistingDevEnvironment -PropertyName 'Url')
                        }

                        $updatedDeploymentEnvironments = @(Invoke-WithErrorHandling -OperationName "Selecting deployment environments for branch '$($mappingToEdit.BranchName)'" -ScriptBlock {
                            Get-DataverseEnvironmentsSelection `
                                -ExcludedUrl $excludedUrl `
                                -Branch $mappingToEdit.BranchName `
                                -ProjectName $SelectedProject.Name `
                                -InitialEnvironments @($mappingToEdit.Environments) `
                                -InitialEditEnvironmentName $initialEditEnvironmentName `
                                -ExistingCredentials $credentialsCache `
                                -ExistingServiceAccounts $serviceAccountsCache `
                                -TenantId $TenantId `
                                -UseAlm4DataverseExtension $UseAlm4DataverseExtension
                        })

                        foreach ($deploymentEnvironment in @($updatedDeploymentEnvironments)) {
                            if ($deploymentEnvironment.Credentials -and -not ($credentialsCache | Where-Object { $_.ApplicationId -eq $deploymentEnvironment.Credentials.ApplicationId -and $_.TenantId -eq $deploymentEnvironment.Credentials.TenantId })) {
                                $credentialsCache += $deploymentEnvironment.Credentials
                            }
                            if (-not [string]::IsNullOrWhiteSpace($deploymentEnvironment.ServiceAccountUPN) -and $serviceAccountsCache -notcontains $deploymentEnvironment.ServiceAccountUPN) {
                                $serviceAccountsCache += $deploymentEnvironment.ServiceAccountUPN
                            }
                        }

                        return @($updatedDeploymentEnvironments)
                    } `
                    -EditBuildValidationScriptBlock {
                        param($allMappings, $mappingToEdit, $environmentNameToEdit)

                        $branchName = [string]$mappingToEdit.BranchName
                        Write-Section -Message "BUILD validation for branch '$branchName'"
                        $buildValidationGuidanceLines = @(
                            'BUILD validation is configured independently for each branch.',
                            'A branch can deploy its generated artifacts to a validation environment and optionally use a separate deployment environment as its baseline source.'
                        )

                        $existingBuildValidationEnvironment = if ($mappingToEdit.BuildValidationEnvironmentConfiguration) {
                            $mappingToEdit.BuildValidationEnvironmentConfiguration
                        }
                        else {
                            $mappingToEdit.ExistingBuildValidationEnvironment
                        }
                        $existingBuildValidationEnvironmentName = [string](Get-OptionalObjectPropertyValue -InputObject $existingBuildValidationEnvironment -PropertyName 'ShortName')
                        if ([string]::IsNullOrWhiteSpace($existingBuildValidationEnvironmentName)) {
                            $existingBuildValidationEnvironmentName = [string]$mappingToEdit.BuildValidationEnvironmentName
                        }

                        if (
                            [string]::IsNullOrWhiteSpace($environmentNameToEdit) -and
                            -not [bool]$mappingToEdit.BuildValidationEnabled
                        ) {
                            # Already-enabled validation opens the detail editor directly;
                            # disabling is the branch menu's separate explicit action.
                            $enableBuildValidation = Read-YesNo `
                                -Prompt "Enable Dataverse deployment validation during BUILD for branch '$branchName'?" `
                                -PromptGuidanceLines $buildValidationGuidanceLines `
                                -PromptGuidanceDocRelativePath 'docs/usage/building-releases.md' `
                                -PromptGuidanceRef $ALM4DataverseRef `
                                -DefaultNo
                            if (-not $enableBuildValidation) {
                                return [pscustomobject]@{
                                    BuildValidationEnabled = $false
                                    BuildValidationEnvironmentName = ''
                                    BuildValidationBaselineRelease = ''
                                    BuildValidationEnvironmentConfiguration = $null
                                    ExistingBuildValidationEnvironment = $mappingToEdit.ExistingBuildValidationEnvironment
                                }
                            }
                        }

                        $selectTargetName = {
                            param($environmentState)
                            $environmentName = Read-TextWithDefault `
                                -Prompt "Enter the Azure DevOps service connection name for BUILD validation on branch '$branchName'" `
                                -DefaultValue $environmentState.ShortName `
                                -PromptGuidanceLines @(
                                    'This service connection supplies credentials for BUILD-time deployment validation.',
                                    'Use a stable name; the suggested default is branch-specific.'
                                ) `
                                -PromptGuidanceDocRelativePath 'docs/config/azdo-environment-service-connection.md' `
                                -PromptGuidanceRef $ALM4DataverseRef
                            if ([string]::IsNullOrWhiteSpace($environmentName)) {
                                [Spectre.Console.AnsiConsole]::MarkupLine('[red]A service connection name is required for BUILD validation.[/]')
                                Request-SetupWizardBack
                            }
                            return $environmentName.Trim()
                        }.GetNewClosure()
                        $selectBaseline = {
                            param($environmentState)
                            $baselineEnvironments = @($allMappings | ForEach-Object { @($_.Environments) })
                            $baselineParameters = @{
                                DeploymentEnvironments = $baselineEnvironments
                                ExcludedEnvironmentName = [string]$environmentState.ShortName
                                ExcludedEnvironmentUrl = [string]$environmentState.Url
                            }
                            if ([bool]$environmentState.BaselineConfigured) {
                                $baselineParameters['CurrentBaselineRelease'] = [string]$environmentState.BaselineRelease
                            }
                            Select-BuildValidationBaselineEnvironment @baselineParameters
                        }.GetNewClosure()
                        $buildValidationConfiguration = Invoke-WithErrorHandling -OperationName "Configuring BUILD validation for branch '$branchName'" -ScriptBlock {
                            Invoke-AzDoEnvironmentConfigurationWizard `
                                -Title "Configure BUILD validation for branch '$branchName'" `
                                -DataverseEnvironmentPrompt "Select the Dataverse environment for BUILD validation on branch '$branchName'" `
                                -InitialConfiguration $existingBuildValidationEnvironment `
                                -InitialTargetName $(if ([string]::IsNullOrWhiteSpace($existingBuildValidationEnvironmentName)) { "Build-$branchName" } else { $existingBuildValidationEnvironmentName }) `
                                -TargetNameStepName 'Service connection name' `
                                -SelectTargetNameAction $selectTargetName `
                                -SelectBaselineAction $selectBaseline `
                                -InitialBaselineRelease ([string]$mappingToEdit.BuildValidationBaselineRelease) `
                                -BaselineConfigured:([bool]$mappingToEdit.BuildValidationEnabled) `
                                -ExistingCredentials $credentialsCache `
                                -ExistingServiceAccounts $serviceAccountsCache `
                                -TenantId $TenantId `
                                -ProjectName $SelectedProject.Name `
                                -UseAlm4DataverseExtension $UseAlm4DataverseExtension `
                                -IsDevelopmentEnvironment $false `
                                -IsBuildValidationEnvironment $true `
                                -PromptGuidanceLines @(
                                    'Choose the Dataverse environment that BUILD should validate deployments against.',
                                    'A separate deployment environment can be selected as the baseline source.'
                                ) `
                                -PromptGuidanceDocRelativePath 'docs/usage/building-releases.md' `
                                -PromptGuidanceRef $ALM4DataverseRef `
                                -HelpDocRelativePath 'docs/setup/azdo-automated-setup.md' `
                                -HelpRef $ALM4DataverseRef
                        }
                        if ($null -eq $buildValidationConfiguration) {
                            if ([bool]$mappingToEdit.BuildValidationEnabled) {
                                return [pscustomobject]@{
                                    BuildValidationEnabled = $true
                                    BuildValidationEnvironmentName = [string]$mappingToEdit.BuildValidationEnvironmentName
                                    BuildValidationBaselineRelease = [string]$mappingToEdit.BuildValidationBaselineRelease
                                    BuildValidationEnvironmentConfiguration = $mappingToEdit.BuildValidationEnvironmentConfiguration
                                    ExistingBuildValidationEnvironment = $mappingToEdit.ExistingBuildValidationEnvironment
                                }
                            }
                            return [pscustomobject]@{
                                BuildValidationEnabled = $false
                                BuildValidationEnvironmentName = ''
                                BuildValidationBaselineRelease = ''
                                BuildValidationEnvironmentConfiguration = $null
                                ExistingBuildValidationEnvironment = $mappingToEdit.ExistingBuildValidationEnvironment
                            }
                        }

                        if ($buildValidationConfiguration.Credentials -and -not ($credentialsCache | Where-Object { $_.ApplicationId -eq $buildValidationConfiguration.Credentials.ApplicationId -and $_.TenantId -eq $buildValidationConfiguration.Credentials.TenantId })) {
                            $credentialsCache += $buildValidationConfiguration.Credentials
                        }
                        if (-not [string]::IsNullOrWhiteSpace($buildValidationConfiguration.ServiceAccountUPN) -and $serviceAccountsCache -notcontains $buildValidationConfiguration.ServiceAccountUPN) {
                            $serviceAccountsCache += $buildValidationConfiguration.ServiceAccountUPN
                        }

                        return [pscustomobject]@{
                            BuildValidationEnabled = $true
                            BuildValidationEnvironmentName = [string]$buildValidationConfiguration.ShortName
                            BuildValidationBaselineRelease = [string]$buildValidationConfiguration.BaselineRelease
                            BuildValidationEnvironmentConfiguration = $buildValidationConfiguration
                            ExistingBuildValidationEnvironment = $mappingToEdit.ExistingBuildValidationEnvironment
                        }
                    })

                if ($selectedBranchMappings.Count -eq 0) {
                    throw 'At least one branch must be configured for Azure DevOps setup.'
                }

                $existingStateByBranch = @{}
                foreach ($branchState in @($wizardState.BranchStates)) {
                    $existingStateByBranch[$branchState.BranchName.ToLowerInvariant()] = $branchState
                }

                $updatedBranchStates = @()
                foreach ($selectedBranchMapping in $selectedBranchMappings) {
                    $branchName = [string]$selectedBranchMapping.BranchName
                    $branchKey = $branchName.ToLowerInvariant()

                    $existingBranchState = $null
                    if ($existingStateByBranch.ContainsKey($branchKey)) {
                        $existingBranchState = $existingStateByBranch[$branchKey]
                        $existingBranchState.DevEnvironmentConfiguration = $selectedBranchMapping.DevEnvironmentConfiguration
                        $existingBranchState.DeploymentEnvironments = @($selectedBranchMapping.Environments)
                    }
                    if (-not $existingBranchState) {
                        $existingBranchState = $existingSetupState.BranchStates | Where-Object { $_.BranchName -ieq $branchName } | Select-Object -First 1
                    }

                    $updatedBranchStates += New-AzDoBranchSetupState `
                        -BranchName $branchName `
                        -ExistingDevEnvironment $(if ($existingBranchState) { $existingBranchState.ExistingDevEnvironment } else { $null }) `
                        -DeploymentEnvironments @($(if ($existingBranchState) { $existingBranchState.DeploymentEnvironments } else { @() })) `
                        -PublishPlan (Get-OptionalObjectPropertyValue -InputObject $selectedBranchMapping -PropertyName 'PublishPlan') `
                        -ExistingBuildValidationEnvironment $selectedBranchMapping.ExistingBuildValidationEnvironment `
                        -BuildValidationEnvironmentName ([string]$selectedBranchMapping.BuildValidationEnvironmentName) `
                        -BuildValidationBaselineRelease ([string]$selectedBranchMapping.BuildValidationBaselineRelease)
                    $updatedBranchStates[-1].BuildValidationEnabled = [bool]$selectedBranchMapping.BuildValidationEnabled
                    $updatedBranchStates[-1].BuildValidationEnvironmentConfiguration = $selectedBranchMapping.BuildValidationEnvironmentConfiguration
                }

                $wizardState.BranchStates = @($updatedBranchStates | Sort-Object BranchName)

                $branchMappingsForValidation = @($selectedBranchMappings | ForEach-Object {
                    [pscustomobject]@{
                        BranchName   = [string]$_.BranchName
                        Environments = @($_.Environments)
                    }
                })
                if (Test-BranchEnvironmentMappingDuplicate -BranchMappings $branchMappingsForValidation) {
                    throw 'Each deployment environment can only be assigned to one branch. Resolve duplicate environment assignments before continuing.'
                }

                $wizardState.BranchStates = @($selectedBranchMappings | ForEach-Object {
                    $mappedBranch = $_
                    $existingBranchState = $updatedBranchStates | Where-Object { $_.BranchName -ieq $mappedBranch.BranchName } | Select-Object -First 1
                    if (-not $existingBranchState) {
                        $existingBranchState = New-AzDoBranchSetupState -BranchName ([string]$mappedBranch.BranchName) -ExistingDevEnvironment $null -DeploymentEnvironments @() -PublishPlan $null
                    }

                    $existingBranchState.DevEnvironmentConfiguration = $mappedBranch.DevEnvironmentConfiguration
                    $existingBranchState.DeploymentEnvironments = @($mappedBranch.Environments)
                    $existingBranchState.ExistingBuildValidationEnvironment = $mappedBranch.ExistingBuildValidationEnvironment
                    $existingBranchState.BuildValidationEnabled = [bool]$mappedBranch.BuildValidationEnabled
                    $existingBranchState.BuildValidationEnvironmentName = [string]$mappedBranch.BuildValidationEnvironmentName
                    $existingBranchState.BuildValidationBaselineRelease = [string]$mappedBranch.BuildValidationBaselineRelease
                    $existingBranchState.BuildValidationEnvironmentConfiguration = $mappedBranch.BuildValidationEnvironmentConfiguration
                    $existingBranchState.PublishPlan = Get-OptionalObjectPropertyValue -InputObject $mappedBranch -PropertyName 'PublishPlan'
                    $existingBranchState
                })

                $enabledBuildBranches = @($wizardState.BranchStates | Where-Object { $_.BuildValidationEnabled })
                $wizardState.BuildValidationEnabled = ($enabledBuildBranches.Count -gt 0)
                $wizardState.BuildValidationEnvironmentConfiguration = if ($enabledBuildBranches.Count -eq 1) { $enabledBuildBranches[0].BuildValidationEnvironmentConfiguration } else { $null }
                $wizardState.BuildValidationBaselineRelease = if ($enabledBuildBranches.Count -eq 1) { [string]$enabledBuildBranches[0].BuildValidationBaselineRelease } else { '' }
            }
        },
        [pscustomobject]@{
            Name = 'Configure solutions'
            HelpDocRelativePath = 'docs/config/alm-config.md'
            InputSignature = {
                @($wizardState.BranchStates | ForEach-Object {
                    "$($_.BranchName)|$([string](Get-OptionalObjectPropertyValue -InputObject $_.DevEnvironmentConfiguration -PropertyName 'Url'))"
                }) -join ';'
            }
            Summary = {
                Get-SetupSolutionMenuSummary `
                    -SolutionData $wizardState.SolutionData `
                    -SourceBranch $wizardState.SolutionSourceBranch
            }
            Action = {
                Write-Section `
                    -Message 'Configure solutions'
                $solutionCandidateBranches = @($wizardState.BranchStates | Where-Object { $_.DevEnvironmentConfiguration })
                if ($solutionCandidateBranches.Count -eq 0) {
                    [Spectre.Console.AnsiConsole]::MarkupLine('[yellow]No branch has a DEV environment configured, so solution selection will be skipped for now.[/]')
                    $wizardState.SolutionData = $null
                    $wizardState.SolutionSourceBranch = $null
                    return
                }

                $solutionSourceBranchState = $solutionCandidateBranches[0]
                if ($solutionCandidateBranches.Count -gt 1) {
                    $branchMenuItems = @($solutionCandidateBranches | ForEach-Object {
                        $envLabel = if ($_.DevEnvironmentConfiguration -and -not [string]::IsNullOrWhiteSpace($_.DevEnvironmentConfiguration.FriendlyName)) { $_.DevEnvironmentConfiguration.FriendlyName } else { $_.DevEnvironmentConfiguration.ShortName }
                        "$($_.BranchName) - $envLabel"
                    })
                    $selectedBranchIndex = Select-FromMenu -Title 'Select the branch whose DEV environment should be used for solution selection' -Items $branchMenuItems -PromptGuidanceLines @(
                        'Choose which branch should provide the DEV environment for solution discovery.',
                        'Use the branch that best represents the solution baseline you want in source control.'
                    ) -PromptGuidanceDocRelativePath 'docs/config/alm-config.md' -PromptGuidanceRef $ALM4DataverseRef
                    if ($null -eq $selectedBranchIndex) {
                        throw 'No branch selected for solution selection.'
                    }

                    $solutionSourceBranchState = $solutionCandidateBranches[$selectedBranchIndex]
                }

                $existingConfigTempPath = $null
                try {
                    $existingConfigContent = Get-GitRepoFileContentFromRemoteBranch -RepoRoot $MainRepoWorkingRoot -Branch $solutionSourceBranchState.BranchName -RelativePath 'alm-config.psd1'
                    if (-not [string]::IsNullOrWhiteSpace($existingConfigContent)) {
                        $existingConfigTempPath = Join-Path ([System.IO.Path]::GetTempPath()) ("alm-config-" + [guid]::NewGuid().ToString('n') + '.psd1')
                        Set-Content -LiteralPath $existingConfigTempPath -Value $existingConfigContent -NoNewline
                    }

                    $wizardState.SolutionData = Invoke-WithErrorHandling -OperationName 'Selecting Dataverse solutions' -ScriptBlock {
                        Get-DataverseSolutionsSelection -ExistingConfigPath $existingConfigTempPath -ExistingEnvironmentUrl $solutionSourceBranchState.DevEnvironmentConfiguration.Url
                    }
                }
                finally {
                    if ($existingConfigTempPath -and (Test-Path -LiteralPath $existingConfigTempPath)) {
                        Remove-Item -LiteralPath $existingConfigTempPath -Force -ErrorAction SilentlyContinue
                    }
                }

                $wizardState.SolutionSourceBranch = $solutionSourceBranchState.BranchName
            }
        },
        [pscustomobject]@{
            Name = 'Preview changes'
            HelpDocRelativePath = 'docs/setup/azdo-automated-setup.md'
            Action = {
                $artifactPreview = Get-AzDoSetupArtifactsPreview `
                    -RepoRoot $MainRepoWorkingRoot `
                    -CopyRoot $SharedRepositoryState.CopyRoot `
                    -MainRepo $MainRepo `
                    -SharedRepositoryName $SharedRepositoryState.Name `
                    -SharedRepositoryRef $SharedRepositoryState.Ref `
                    -UseAlm4DataverseExtension $UseAlm4DataverseExtension `
                    -BranchStates @($wizardState.BranchStates) `
                    -ProviderOptions $ProviderOptions `
                    -SolutionData $wizardState.SolutionData

                $resourceChanges = @()
                $resourceChangeNote = if ($ApplyConfig) {
                    'ApplyConfig only modifies repository files; it does not provision Azure DevOps, Entra ID, or Dataverse resources.'
                }
                else {
                    $resourceChanges = @(Get-AzDoSetupResourceChange `
                            -BranchStates @($wizardState.BranchStates) `
                            -SelectedProject $SelectedProject `
                            -MainRepo $MainRepo `
                            -SharedRepositoryName $SharedRepositoryState.Name `
                            -SharedRepositoryState $SharedRepositoryState)
                    'Changes already applied during setup are marked; the remaining rows are deferred until Apply.'
                }

                $summaryAction = {
                    Write-Section -Message 'Review Dataverse environment configuration'
                    $allConfiguredEnvironments = @()
                    foreach ($branchState in @($wizardState.BranchStates)) {
                        if ($branchState.DevEnvironmentConfiguration) {
                            $allConfiguredEnvironments += $branchState.DevEnvironmentConfiguration
                        }
                        $allConfiguredEnvironments += @($branchState.DeploymentEnvironments)
                        if ($branchState.BuildValidationEnabled -and $branchState.BuildValidationEnvironmentConfiguration) {
                            $allConfiguredEnvironments += $branchState.BuildValidationEnvironmentConfiguration
                        }
                    }

                    $buildValidationSummaries = @($wizardState.BranchStates | Where-Object { $_.BuildValidationEnabled } | ForEach-Object {
                        "$($_.BranchName): $($_.BuildValidationEnvironmentName)"
                    })
                    $buildBaselineSummaries = @($wizardState.BranchStates | Where-Object { $_.BuildValidationEnabled -and -not [string]::IsNullOrWhiteSpace([string]$_.BuildValidationBaselineRelease) } | ForEach-Object {
                        "$($_.BranchName): $($_.BuildValidationBaselineRelease)"
                    })
                    $fileChanges = @($artifactPreview.FileChanges)
                    Show-KeyValueSummaryTable -Heading 'Setup summary' -Values ([ordered]@{
                        'Setup type'                = $(if ($IsNewRepository) { 'Complete setup for a new repository' } else { 'Changes to existing repository setup' })
                        'Azure DevOps project'      = $SelectedProject.Name
                        'Main repository'           = $MainRepo.Name
                        'Shared repository'         = $SharedRepositoryState.Name
                        'Configured branches'       = [string]$wizardState.BranchStates.Count
                        'BUILD validation'          = $(if ($buildValidationSummaries.Count -gt 0) { $buildValidationSummaries -join '; ' } else { 'Disabled' })
                        'BUILD validation baseline' = $(if ($buildBaselineSummaries.Count -gt 0) { $buildBaselineSummaries -join '; ' } else { '<none>' })
                        'Solution source branch'    = $(if ([string]::IsNullOrWhiteSpace($wizardState.SolutionSourceBranch)) { '<none>' } else { $wizardState.SolutionSourceBranch })
                        'Solutions selected'        = [string]$(if ($wizardState.SolutionData) { @($wizardState.SolutionData.Solutions).Count } else { 0 })
                        'Extension mode'            = $(if ($UseAlm4DataverseExtension) { 'ALM4Dataverse extension enabled' } else { 'ALM4Dataverse extension disabled' })
                        'Files to add'              = [string]@($fileChanges | Where-Object { $_.Status -eq 'Added' }).Count
                        'Files to modify'           = [string]@($fileChanges | Where-Object { $_.Status -eq 'Modified' }).Count
                        'Files to delete'           = [string]@($fileChanges | Where-Object { $_.Status -eq 'Deleted' }).Count
                        'Deferred resource changes' = [string]$resourceChanges.Count
                    })

                    Show-BranchEnvironmentMappingTable -BranchMappings @($wizardState.BranchStates | ForEach-Object {
                        [pscustomobject]@{
                            BranchName   = $_.BranchName
                            Environments = @($_.DeploymentEnvironments)
                        }
                    })
                    foreach ($branchState in @($wizardState.BranchStates)) {
                        $publishPlan = Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'PublishPlan'
                        $publishSummary = if ($publishPlan -and $publishPlan.Mode -eq 'PullRequest') {
                            "Pull request into $($publishPlan.TargetBranch) from $($publishPlan.BranchName)"
                        }
                        elseif ($publishPlan) {
                            "Direct commit to $($publishPlan.BranchName)"
                        }
                        elseif ($PreviewOnly) {
                            '<not selected in preview-only mode>'
                        }
                        else {
                            '<not configured>'
                        }
                        Show-KeyValueSummaryTable -Heading "Branch '$($branchState.BranchName)'" -Values ([ordered]@{
                            'Publish mode'             = $publishSummary
                            'DEV environment'          = $(if ($branchState.DevEnvironmentConfiguration) { $branchState.DevEnvironmentConfiguration.ShortName } else { '<none>' })
                            'BUILD validation'         = $(if ($branchState.BuildValidationEnabled) { [string]$branchState.BuildValidationEnvironmentName } else { 'Disabled' })
                            'BUILD validation baseline' = $(if ([string]::IsNullOrWhiteSpace([string]$branchState.BuildValidationBaselineRelease)) { '<none>' } else { [string]$branchState.BuildValidationBaselineRelease })
                            'Deployment environments'  = [string]@($branchState.DeploymentEnvironments).Count
                        })
                    }
                    Show-EnvironmentConfigurationTable -EnvironmentConfigurations $allConfiguredEnvironments
                }
                Show-SetupChangeReview `
                    -FileChanges @($artifactPreview.FileChanges) `
                    -ResourceChanges $resourceChanges `
                    -ResourceChangeNote $resourceChangeNote `
                    -SummaryAction $summaryAction `
                    -PreviewOnly:$PreviewOnly
            }
        }
    )
    $previewStep = $branchSetupSteps | Where-Object { $_.Name -eq 'Preview changes' } | Select-Object -First 1
    if (-not $previewStep) {
        throw 'The setup change preview action is unavailable.'
    }
    $publicationPlanStep = [pscustomobject]@{
        Name = 'Choose publication method'
        HelpDocRelativePath = 'docs/setup/azdo-automated-setup.md'
        InputSignature = {
            @($wizardState.BranchStates | ForEach-Object { [string]$_.BranchName }) -join ';'
        }
        Summary = {
            Get-SetupSinglePublishPlanSummary -PublishPlan $wizardState.PublishPlan
        }
        Action = {
            $defaultCommitMessage = if ($ApplyConfig) {
                'Apply alm-config.psd1 settings for all configured branches'
            }
            else {
                'Add ALM4Dataverse Azure DevOps pipelines for all configured branches'
            }
            $defaultPullRequestDescription = if ($ApplyConfig) {
                'This pull request regenerates the Azure DevOps pipeline files from the committed alm-config.psd1 settings for all configured branches.'
            }
            else {
                'This pull request adds or updates the ALM4Dataverse Azure DevOps pipeline YAML and repository configuration generated by setup-azdo.ps1 for all configured branches.'
            }
            $wizardState.PublishPlan = Get-SetupSingleBranchPublishPlan `
                -ProviderName 'Azure DevOps' `
                -RepositoryName $MainRepo.Name `
                -DefaultBranch $DefaultBranch `
                -BranchStates @($wizardState.BranchStates) `
                -DefaultCommitMessage $defaultCommitMessage `
                -DefaultPullRequestDescription $defaultPullRequestDescription `
                -ExistingPlan $wizardState.PublishPlan `
                -DocRelativePath 'docs/setup/azdo-automated-setup.md' `
                -Ref $ALM4DataverseRef
        }
    }
    $setupSteps = @($PrerequisiteSteps) +
        @($branchSetupSteps | Where-Object { $_.Name -ne 'Preview changes' }) +
        @($publicationPlanStep)
    if ($ApplyConfig) {
        $setupSteps = @($PrerequisiteSteps) + @($publicationPlanStep)
    }

    if ($PreviewOnly) {
        & $previewStep.Action
        Write-Host 'Preview-only complete; no changes were published.' -ForegroundColor Cyan
        return [pscustomobject]@{
            BranchStates            = @($wizardState.BranchStates)
            SolutionData            = $wizardState.SolutionData
            SolutionSourceBranch   = $wizardState.SolutionSourceBranch
            BuildValidationEnabled = [bool](@($wizardState.BranchStates | Where-Object { $_.BuildValidationEnabled }).Count -gt 0)
            PublishResults          = @()
        }
    }

    if ($Commit) {
        if (-not $ApplyConfig) {
            throw 'Commit requires ApplyConfig.'
        }

        # Unattended publication: all generated files for every configured branch
        # are committed directly to the default branch without prompts.
        $wizardState.PublishPlan = [pscustomobject]@{
            Mode                   = 'Direct'
            TargetBranch           = $DefaultBranch
            BranchName             = $DefaultBranch
            CommitMessage          = 'Apply alm-config.psd1 settings for all configured branches'
            PullRequestTitle       = ''
            PullRequestDescription = ''
        }
        $applyResult = Invoke-AzDoBranchAwareSetupApply `
            -MainRepoWorkingRoot $MainRepoWorkingRoot `
            -MainRepo $MainRepo `
            -DefaultBranch $DefaultBranch `
            -AccessToken $AccessToken `
            -CopyRoot ([string]$SharedRepositoryState.CopyRoot) `
            -SharedRepositoryName ([string]$SharedRepositoryState.Name) `
            -SharedRepositoryRef ([string]$SharedRepositoryState.Ref) `
            -UseAlm4DataverseExtension $UseAlm4DataverseExtension `
            -WizardState $wizardState `
            -ProviderOptions $ProviderOptions
        if ($PostApplyAction) {
            & $PostApplyAction $applyResult
        }
        return $applyResult
    }

    $setupResult = Invoke-SetupWizard `
        -Title 'Azure DevOps ALM4Dataverse setup' `
        -Steps $setupSteps `
        -PreviewAction $previewStep.Action `
        -PreviewActionName $previewStep.Name `
        -HelpDocRelativePath 'docs/setup/azdo-automated-setup.md' `
        -HelpRef $ALM4DataverseRef `
        -PreApplyAction $PreApplyAction `
        -ApplyAction {
        $applyResult = Invoke-AzDoBranchAwareSetupApply `
            -MainRepoWorkingRoot $MainRepoWorkingRoot `
            -MainRepo $MainRepo `
            -DefaultBranch $DefaultBranch `
            -AccessToken $AccessToken `
            -CopyRoot ([string]$SharedRepositoryState.CopyRoot) `
            -SharedRepositoryName ([string]$SharedRepositoryState.Name) `
            -SharedRepositoryRef ([string]$SharedRepositoryState.Ref) `
            -UseAlm4DataverseExtension $UseAlm4DataverseExtension `
            -WizardState $wizardState `
            -ProviderOptions $ProviderOptions
        if ($PostApplyAction) {
            & $PostApplyAction $applyResult
        }
        return $applyResult
    } -IsNewRepository:$IsNewRepository
    return $setupResult
}

}

#region Azure DevOps Setup

















#endregion

#region Dataverse Environment Selection Helper







#endregion

#region Pipeline Setup

































































# Authentication and project selection finish before the configuration menu. The main
# menu starts with shared-repository selection, followed by version reconciliation.
$startupSteps = @(
    [pscustomobject]@{
        Name = 'Authenticate with Azure DevOps'
        HelpDocRelativePath = 'docs/setup/azdo-automated-setup.md'
        LockAfterCompletion = $true
        Action = {
            $authentication = Initialize-AzDoAuthentication -TenantId $TenantId
            $script:adoAuthResult = $authentication.AuthResult
            $script:adoAccessToken = $authentication.AccessToken
            $script:secureToken = $authentication.SecureToken
        }
    }
    [pscustomobject]@{
        Name = 'Select Azure DevOps organization'
        HelpDocRelativePath = 'docs/setup/azdo-organisation-requirements.md'
        LockAfterCompletion = $true
        Action = {
            $organization = Initialize-AzDoOrganization
            if (-not $organization) {
                Request-SetupWizardBack
            }
            $script:orgName = $organization.Name
            $script:orgUri = $organization.Uri
        }
    }
    [pscustomobject]@{
        Name = 'Select project and application repository'
        HelpDocRelativePath = 'docs/setup/azdo-automated-setup.md'
        LockAfterCompletion = $true
        Action = {
            $script:initialization = Initialize-AzDoProjectAndRepository `
                -ApplyConfig:$ApplyConfig `
                -ExistingSetupMode:$existingSetupMode `
                -DeferSharedRepositorySelection:($existingSetupMode -and -not $ApplyConfig) `
                -SkipSharedRepositoryVersionUpdate
            if (-not $script:initialization) {
                Request-SetupWizardBack
            }
        }
    }
)

try {
    if ($headlessMode) {
        $authentication = Initialize-AzDoAuthentication -TenantId $TenantId -HeadlessAccessToken $AccessToken
        $script:adoAuthResult = $authentication.AuthResult
        $script:adoAccessToken = $authentication.AccessToken
        $script:secureToken = $authentication.SecureToken
        $organization = Initialize-AzDoOrganization -OrganizationName $OrganizationName
        $script:orgName = $organization.Name
        $script:orgUri = $organization.Uri
        $script:initialization = Initialize-AzDoProjectAndRepository `
            -ApplyConfig:$ApplyConfig `
            -ExistingSetupMode:$existingSetupMode `
            -SkipSharedRepositoryVersionUpdate `
            -ProjectName $ProjectName `
            -RepositoryName $RepositoryName
        if (-not $script:initialization) {
            throw 'Azure DevOps project and repository resolution failed in headless mode.'
        }
    }
    else {
        Invoke-SetupWizard `
            -Title 'Azure DevOps setup prerequisites' `
            -Steps $startupSteps `
            -HelpDocRelativePath 'docs/setup/azdo-automated-setup.md' `
            -HelpRef $ALM4DataverseRef | Out-Null
    }
}
catch {
    if ($_.Exception.Message -eq 'Setup cancelled before changes were applied.' -or (Test-IsSetupWizardBackException -Exception $_.Exception)) {
        Write-Host 'Azure DevOps setup cancelled before branch configuration.' -ForegroundColor Yellow
        return
    }
    throw
}

$initialSetupSteps = @()

# Normal setup may provision resources before branch review; ApplyConfig only reads existing resources.
$initialization = $script:initialization
if (-not $initialization) {
    return
}

$selectedProject = $initialization.SelectedProject
$mainRepo = $initialization.MainRepo
$mainRepoWorkingTree = $initialization.MainRepoWorkingTree
$mainRepoWorkingRoot = $initialization.MainRepoWorkingRoot
$azDevOpsAccessToken = $initialization.AzDevOpsAccessToken
$sharedRepoName = $initialization.SharedRepoName
$sharedRepositoryRef = $initialization.SharedRepositoryRef
$isNewRepository = [bool]$initialization.MainRepoIsNew

Write-Section `
    -Message "Ensuring main repository contains pipeline YAMLs"

$repoPublishResults = @()
$script:yamlFiles = @(
    'pipelines/BUILD.yml',
    'pipelines/EXPORT.yml',
    'pipelines/IMPORT.yml'
)

Push-Location $mainRepoWorkingRoot
try {
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'

        & git checkout $script:mainRepoBranch 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            & git checkout -b $script:mainRepoBranch 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to check out branch '$script:mainRepoBranch' in the working tree."
            }
        }

        & git -c "http.extraheader=AUTHORIZATION: bearer $azDevOpsAccessToken" fetch origin '+refs/heads/*:refs/remotes/origin/*' --prune 2>&1 | Out-Null
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}
finally {
    Pop-Location
}


$localCopyRoot = $null
if ($PSScriptRoot) {
    $candidateCopyRoot = Join-Path $PSScriptRoot 'copy-to-your-repo'
    if (Test-Path -LiteralPath $candidateCopyRoot -PathType Container) {
        $localCopyRoot = $candidateCopyRoot
    }
}

$script:sharedRepositoryState = [ordered]@{
    Repository = $null
    Name = ''
    Ref = ''
    CopyRoot = $localCopyRoot
    ClonePath = $null
    UsesLocalCopyRoot = [bool]$localCopyRoot
    ValidationError = [string](Get-OptionalObjectPropertyValue -InputObject $initialization -PropertyName 'SharedRepositorySelectionError')
    CreatedDuringSetup = $false
    VersionUpdatedDuringSetup = $false
}
[void](Set-AzDoSharedRepositoryState `
    -RepositoryState $script:sharedRepositoryState `
    -Initialization $initialization `
    -AccessToken $azDevOpsAccessToken `
    -UpstreamGitSource $upstreamRepo)
$sharedRepoName = [string]$script:sharedRepositoryState.Name
if ([string]::IsNullOrWhiteSpace($sharedRepoName)) {
    $sharedRepoName = 'ALM4Dataverse'
}
$sharedRepositoryRef = [string]$script:sharedRepositoryState.Ref
$copyRoot = [string]$script:sharedRepositoryState.CopyRoot
$sharedRepoClone = [string]$script:sharedRepositoryState.ClonePath
$initialSetupSteps += [pscustomobject]@{
    Name = 'Select shared repository'
    HelpDocRelativePath = 'docs/setup/azdo-automated-setup.md'
    Summary = {
        if ([string]::IsNullOrWhiteSpace([string]$script:sharedRepositoryState.ValidationError)) {
            "$($script:sharedRepositoryState.Name) ($($script:sharedRepositoryState.Ref))"
        }
        else {
            "Unavailable: $($script:sharedRepositoryState.ValidationError)"
        }
    }
    Action = {
        if ($ApplyConfig) {
            throw 'The shared repository cannot be changed while applying committed configuration.'
        }

        $updatedInitialization = Initialize-AzDoProjectAndRepository `
            -SharedRepositoryOnly `
            -SelectedProjectForSharedRepository $selectedProject `
            -MainRepoForSharedRepository $mainRepo `
            -MainRepoWorkingTreeForSharedRepository $mainRepoWorkingTree `
            -MainRepoWorkingRootForSharedRepository $mainRepoWorkingRoot `
            -AccessTokenForSharedRepository $azDevOpsAccessToken `
            -PreferredSharedRepositoryName ([string]$script:sharedRepositoryState.Name) `
            -PreferredSharedRepositoryRef ([string]$script:sharedRepositoryState.Ref) `
            -SkipSharedRepositoryVersionUpdate
        [void](Set-AzDoSharedRepositoryState `
            -RepositoryState $script:sharedRepositoryState `
            -Initialization $updatedInitialization `
            -AccessToken $azDevOpsAccessToken `
            -UpstreamGitSource $upstreamRepo)
        $script:sharedRepositoryState.CreatedDuringSetup = [bool](Get-OptionalObjectPropertyValue -InputObject $script:sharedRepositoryState.Repository -PropertyName 'CreatedDuringSetup')
    }
    IsComplete = [string]::IsNullOrWhiteSpace([string]$script:sharedRepositoryState.ValidationError)
    IsLocked = [bool]$ApplyConfig
}
$initialSetupSteps += [pscustomobject]@{
    Name = 'Check and update shared repository version'
    HelpDocRelativePath = 'docs/setup/azdo-automated-setup.md'
    Summary = {
        if ($ApplyConfig) {
            'Skipped by -ApplyConfig'
        }
        else {
            "Check against $ALM4DataverseRef"
        }
    }
    Action = {
        if ($ApplyConfig) {
            throw 'The shared repository version cannot be updated while applying committed configuration.'
        }

        # This step can seed or rewrite the shared repository history before the
        # preview is reviewed. Name the write explicitly so it is a deliberate choice.
        $confirmSharedRepositoryUpdate = Read-YesNo `
            -Prompt "Check and update shared repository '$($script:sharedRepositoryState.Name)' now, before preview?" `
            -PromptGuidanceLines @(
                'This step can create, seed, fast-forward, rebase, or reset the shared repository history immediately.',
                'Choose No to defer the update until you are ready; the preview lists the shared repository state as updated during setup.'
            ) `
            -PromptGuidanceDocRelativePath 'docs/setup/azdo-automated-setup.md' `
            -PromptGuidanceRef $ALM4DataverseRef
        if (-not $confirmSharedRepositoryUpdate) {
            Request-SetupWizardBack
        }

        $updatedInitialization = Initialize-AzDoProjectAndRepository `
            -SharedRepositoryOnly `
            -UsePreferredSharedRepository `
            -SelectedProjectForSharedRepository $selectedProject `
            -MainRepoForSharedRepository $mainRepo `
            -MainRepoWorkingTreeForSharedRepository $mainRepoWorkingTree `
            -MainRepoWorkingRootForSharedRepository $mainRepoWorkingRoot `
            -AccessTokenForSharedRepository $azDevOpsAccessToken `
            -PreferredSharedRepositoryName ([string]$script:sharedRepositoryState.Name) `
            -PreferredSharedRepositoryRef ([string]$script:sharedRepositoryState.Ref)
        [void](Set-AzDoSharedRepositoryState `
            -RepositoryState $script:sharedRepositoryState `
            -Initialization $updatedInitialization `
            -AccessToken $azDevOpsAccessToken `
            -UpstreamGitSource $upstreamRepo)
        $script:sharedRepositoryState.VersionUpdatedDuringSetup = $true
    }
    IsComplete = [bool]$ApplyConfig
    IsLocked = [bool]$ApplyConfig
}

try {
    Invoke-WithErrorHandling -OperationName "Preparing main repository working tree" -ScriptBlock {
        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            Sync-CopyToYourRepoIntoGitRepo `
                -SourceRoot $copyRoot `
                -TargetRoot $mainRepoWorkingRoot `
                -RepositoryName $mainRepo.Name `
                -SharedRepositoryName $sharedRepoName `
                -SharedRepositoryRef $sharedRepositoryRef `
                -Branch $script:mainRepoBranch `
                -UseAlm4DataverseExtension $script:useAlm4DataverseExtension
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
    } -StatusMessage 'Preparing the main repository working tree...' -CaptureOutputInPanel | Out-Null
}
catch {
    if ($sharedRepoClone -and (Test-Path -LiteralPath $sharedRepoClone)) {
        try { Remove-Item -LiteralPath $sharedRepoClone -Recurse -Force -ErrorAction Stop } catch { Write-Verbose 'Could not remove the shared repository clone; continuing cleanup.' }
    }
    throw
}

#endregion

#region Dev Environment and Solutions Selection







#endregion

#region Deployment Environments Selection



















































# Keep publication in the retryable Apply action so a failure returns to the wizard
# with branch choices intact. Earlier branch publications are not rolled back.
$providerOptions = [ordered]@{
    azDOUseAlm4DataverseExtension = [bool]$script:useAlm4DataverseExtension
}
try {
    $postApplyAction = $null
    if (-not $ApplyConfig) {
        $postApplyAction = {
            param($setupResult)
            Invoke-AzDoSetupPostApply `
                -SetupResult $setupResult `
                -SelectedProject $selectedProject `
                -MainRepo $mainRepo `
                -SharedRepository $script:sharedRepositoryState.Repository `
                -OrganizationName $orgName
        }
    }

    $azDoSetupResult = Invoke-AzDoBranchAwareSetup `
        -MainRepoWorkingRoot $mainRepoWorkingRoot `
        -MainRepo $mainRepo `
        -SelectedProject $selectedProject `
        -OrganizationName $orgName `
        -TenantId $adoAuthResult.TenantId `
        -DefaultBranch $script:mainRepoBranch `
        -AccessToken $azDevOpsAccessToken `
        -CopyRoot $copyRoot `
        -SharedRepositoryName $sharedRepoName `
        -SharedRepositoryRef $sharedRepositoryRef `
        -UseAlm4DataverseExtension $script:useAlm4DataverseExtension `
        -ALM4DataverseRef $ALM4DataverseRef `
        -ProviderOptions $providerOptions `
        -PrerequisiteSteps $initialSetupSteps `
        -SharedRepositoryState $script:sharedRepositoryState `
        -PostApplyAction $postApplyAction `
        -ApplyConfig:$ApplyConfig `
        -IsNewRepository:$isNewRepository `
        -PreviewOnly:$PreviewOnly `
        -Commit:$Commit
}
catch {
    if (
        $_.Exception.Message -in @('Setup cancelled before changes were applied.', 'Setup exited without applying changes.') -or
        (Test-IsSetupWizardBackException -Exception $_.Exception)
    ) {
        Write-Host 'Azure DevOps setup exited before applying changes.' -ForegroundColor Yellow
        if ($mainRepoWorkingRoot -and (Test-Path -LiteralPath $mainRepoWorkingRoot)) {
            try { Remove-Item -LiteralPath $mainRepoWorkingRoot -Recurse -Force -ErrorAction Stop } catch { Write-Verbose 'Could not remove the main repository clone; continuing cleanup.' }
        }
        return
    }
    throw
}
finally {
    if ($sharedRepoClone -and (Test-Path -LiteralPath $sharedRepoClone)) {
        try { Remove-Item -LiteralPath $sharedRepoClone -Recurse -Force -ErrorAction Stop } catch { Write-Verbose 'Could not remove the shared repository clone; continuing cleanup.' }
    }
}

$branchStates = @($azDoSetupResult.BranchStates)
$solutionSourceBranch = $azDoSetupResult.SolutionSourceBranch
$buildValidationEnabled = @($branchStates | Where-Object { $_.BuildValidationEnabled }).Count -gt 0
$enabledBuildBranchStates = @($branchStates | Where-Object { $_.BuildValidationEnabled })
$repoPublishResults = @($azDoSetupResult.PublishResults)
$allConfiguredEnvironments = @()
foreach ($branchState in @($branchStates)) {
    if ($branchState.DevEnvironmentConfiguration) {
        $allConfiguredEnvironments += $branchState.DevEnvironmentConfiguration
    }
    $allConfiguredEnvironments += @($branchState.DeploymentEnvironments)
    if ($branchState.BuildValidationEnabled -and $branchState.BuildValidationEnvironmentConfiguration) {
        $allConfiguredEnvironments += $branchState.BuildValidationEnvironmentConfiguration
    }
}

#endregion

if ($mainRepoWorkingRoot -and (Test-Path $mainRepoWorkingRoot)) {
    try { Remove-Item -LiteralPath $mainRepoWorkingRoot -Recurse -Force -ErrorAction Stop } catch { Write-Verbose 'Could not remove the main repository clone; continuing cleanup.' }
}

if ($PreviewOnly) {
    return
}

Show-SetupCompletionScreen `
    -Heading 'Azure DevOps setup completed successfully!' `
    -AccessLabel 'Open your Azure DevOps project' `
    -AccessUrl "https://dev.azure.com/$orgName/$($selectedProject.Name)/_build" `
    -SummaryValues ([ordered]@{
        'Azure DevOps project'   = $selectedProject.Name
        'Main repository'        = $mainRepo.Name
        'Shared repository'      = $sharedRepoName
        'Configured branches'    = [string]$branchStates.Count
        'Solution source branch' = $(if ([string]::IsNullOrWhiteSpace($solutionSourceBranch)) { '<none>' } else { $solutionSourceBranch })
        'Publish mode'           = (Get-AzDoPublishSummaryText -PublishResults $repoPublishResults)
        'BUILD validation'       = $(if ($buildValidationEnabled) { 'Enabled' } else { 'Disabled' })
        'BUILD validation environments' = $(if ($enabledBuildBranchStates.Count -gt 0) { @($enabledBuildBranchStates | ForEach-Object { "$($_.BranchName): $($_.BuildValidationEnvironmentName)" }) -join '; ' } else { '<none>' })
        'Configured environments' = [string]$allConfiguredEnvironments.Count
    }) `
    -NextStepLinks @(
        $(foreach ($repoPublishResult in @($repoPublishResults | Where-Object { $_.Mode -eq 'PullRequest' -and -not [string]::IsNullOrWhiteSpace($_.PullRequestUrl) })) {
            @{ Label = "Review and merge the setup pull request for branch '$($repoPublishResult.TargetBranch)'"; Url = $repoPublishResult.PullRequestUrl }
        }),
        @{ Label = 'Run EXPORT for your DEV environment'; Url = (Get-Alm4DataverseDocUrl -RelativePath 'docs/usage/exporting-changes.md' -Ref $ALM4DataverseRef) },
        @{ Label = 'Configure EV and CR values for environments'; Url = (Get-Alm4DataverseDocUrl -RelativePath 'docs/config/azdo-environment-variable-group.md' -Ref $ALM4DataverseRef) },
        @{ Label = 'Run DEPLOY to promote the build'; Url = (Get-Alm4DataverseDocUrl -RelativePath 'docs/usage/deploying.md' -Ref $ALM4DataverseRef) }
    )
