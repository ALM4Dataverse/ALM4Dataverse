BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repoRoot 'pipelines/scripts/common.ps1')
    . (Join-Path $repoRoot 'setup/setup-common.ps1')
    if (-not ('Alm4DataverseSetupAccessTokenTestRunner' -as [type])) {
        Add-Type -TypeDefinition @'
using System.Collections.ObjectModel;
using System.Management.Automation;
using System.Threading.Tasks;

public static class Alm4DataverseSetupAccessTokenTestRunner
{
    public static Task<Collection<PSObject>> Invoke(ScriptBlock callback, string resource)
    {
        return Task.Run(() => callback.Invoke(resource));
    }
}
'@
    }
}

Describe 'Setup MSAL assembly initialization' {
    It 'prefers runtime-matched Core and Broker assets and loads them as a pair' {
        $moduleBase = Join-Path $TestDrive 'runtime-matched-dataverse-module'
        if ($PSVersionTable.PSEdition -eq 'Core') {
            $runtimeMajor = [System.Environment]::Version.Major
            $targetFramework = if ($runtimeMajor -ge 10) {
                "net$runtimeMajor.0"
            }
            elseif ($runtimeMajor -eq 9) {
                'net9.0'
            }
            else {
                'net8.0'
            }
        }
        else {
            $targetFramework = 'net462'
        }

        $targetDirectory = Join-Path (Join-Path $moduleBase 'cmdlets') $targetFramework
        New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
        $corePath = Join-Path $targetDirectory 'Microsoft.Identity.Client.dll'
        $brokerPath = Join-Path $targetDirectory 'Microsoft.Identity.Client.Broker.dll'
        Set-Content -LiteralPath $corePath -Value ''
        Set-Content -LiteralPath $brokerPath -Value ''

        if ($PSVersionTable.PSEdition -eq 'Core' -and $targetFramework -ne 'net8.0') {
            $fallbackDirectory = Join-Path (Join-Path $moduleBase 'cmdlets') 'net8.0'
            New-Item -ItemType Directory -Path $fallbackDirectory -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $fallbackDirectory 'Microsoft.Identity.Client.dll') -Value ''
            Set-Content -LiteralPath (Join-Path $fallbackDirectory 'Microsoft.Identity.Client.Broker.dll') -Value ''
        }

        $paths = Get-SetupMsalAssemblyPath -ModuleBase $moduleBase
        $paths.CorePath | Should -Be $corePath
        $paths.BrokerPath | Should -Be $brokerPath

        $script:setupMsalAssemblyLoadPaths = @()
        Mock Get-SetupAssemblyVersion { [version]'4.84.1.0' }
        Mock Get-SetupDefaultContextAssembly { $null }
        Mock Add-Type { $script:setupMsalAssemblyLoadPaths += $Path }

        Initialize-SetupMsalAssembly -ModuleBase $moduleBase

        $script:setupMsalAssemblyLoadPaths | Should -Be @($corePath, $brokerPath)
    }

    It 'supports older module assets without a Broker assembly' {
        $moduleBase = Join-Path $TestDrive 'core-only-dataverse-module'
        $targetFramework = if ($PSVersionTable.PSEdition -eq 'Core') { 'net8.0' } else { 'net462' }
        $targetDirectory = Join-Path (Join-Path $moduleBase 'cmdlets') $targetFramework
        New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
        $corePath = Join-Path $targetDirectory 'Microsoft.Identity.Client.dll'
        Set-Content -LiteralPath $corePath -Value ''

        $script:setupMsalAssemblyLoadPaths = @()
        Mock Get-SetupAssemblyVersion { [version]'4.84.1.0' }
        Mock Get-SetupDefaultContextAssembly { $null }
        Mock Add-Type { $script:setupMsalAssemblyLoadPaths += $Path }

        Initialize-SetupMsalAssembly -ModuleBase $moduleBase

        $script:setupMsalAssemblyLoadPaths | Should -Be @($corePath)
    }

    It 'rejects an incompatible MSAL assembly already loaded in the default context' {
        $moduleBase = Join-Path $TestDrive 'incompatible-dataverse-module'
        $targetFramework = if ($PSVersionTable.PSEdition -eq 'Core') { 'net8.0' } else { 'net462' }
        $targetDirectory = Join-Path (Join-Path $moduleBase 'cmdlets') $targetFramework
        New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $targetDirectory 'Microsoft.Identity.Client.dll') -Value ''
        Set-Content -LiteralPath (Join-Path $targetDirectory 'Microsoft.Identity.Client.Broker.dll') -Value ''

        $script:setupMismatchedMsalAssembly = [pscustomobject]@{}
        $script:setupMismatchedMsalAssembly | Add-Member -MemberType ScriptMethod -Name GetName -Value {
            [pscustomobject]@{ Version = [version]'4.83.0.0' }
        }
        Mock Get-SetupAssemblyVersion { [version]'4.84.1.0' }
        Mock Get-SetupDefaultContextAssembly {
            if ($Name -eq 'Microsoft.Identity.Client') {
                return $script:setupMismatchedMsalAssembly
            }

            return $null
        }

        { Initialize-SetupMsalAssembly -ModuleBase $moduleBase } |
            Should -Throw '*incompatible Microsoft.Identity.Client version*'
    }

    It 'finds compatible MSAL assets in a nested packaged framework directory' {
        $moduleBase = Join-Path $TestDrive 'nested-dataverse-module'
        $targetFramework = if ($PSVersionTable.PSEdition -eq 'Core') { 'netstandard2.0' } else { 'net472' }
        $targetDirectory = Join-Path (Join-Path $moduleBase 'nested') $targetFramework
        New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
        $corePath = Join-Path $targetDirectory 'Microsoft.Identity.Client.dll'
        $brokerPath = Join-Path $targetDirectory 'Microsoft.Identity.Client.Broker.dll'
        Set-Content -LiteralPath $corePath -Value ''
        Set-Content -LiteralPath $brokerPath -Value ''

        $paths = Get-SetupMsalAssemblyPath -ModuleBase $moduleBase

        $paths.CorePath | Should -Be $corePath
        $paths.BrokerPath | Should -Be $brokerPath
    }
}

Describe 'Common module version management' {
    It 'selects only the requested version from available modules' {
        Mock Get-Module {
            @(
                [pscustomobject]@{ Version = [version]'1.0.0' }
                [pscustomobject]@{ Version = [version]'2.0.0' }
            )
        }

        (Get-ModuleAvailableExact -Name 'SetupTestModule' -RequiredVersion '2.0.0').Version |
            Should -Be ([version]'2.0.0')
    }

    It 'downloads and verifies an exact version when it is not initially discoverable' {
        $script:moduleAvailabilityCalls = 0
        Mock Get-Module {
            $script:moduleAvailabilityCalls++
            if ($script:moduleAvailabilityCalls -eq 1) {
                return
            }

            [pscustomobject]@{ Version = [version]'1.2.3' }
        }
        Mock Get-PackageProvider { [pscustomobject]@{ Name = 'NuGet' } }
        Mock Save-Module {}
        Mock Import-Module {}

        Import-RequiredModuleVersion -Name 'SetupTestModule' -RequiredVersion '1.2.3' -Destination $TestDrive

        Should -Invoke Save-Module -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'SetupTestModule' -and $RequiredVersion -eq '1.2.3' -and $Path -eq $TestDrive
        }
        Should -Invoke Import-Module -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'SetupTestModule' -and $RequiredVersion -eq '1.2.3' -and $Force
        }
    }

    It 'installs NuGet for the current user before saving when the provider is missing' {
        Mock Get-PackageProvider { $null }
        Mock Install-PackageProvider {}
        Mock Save-Module {}

        Save-ModuleExact -Name 'SetupTestModule' -RequiredVersion '1.2.3' -Destination $TestDrive

        Should -Invoke Install-PackageProvider -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'NuGet' -and $Scope -eq 'CurrentUser'
        }
        Should -Invoke Save-Module -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'SetupTestModule' -and $RequiredVersion -eq '1.2.3'
        }
    }
}

Describe 'Setup authentication helpers' {
    BeforeAll {
        if (-not ('Microsoft.Identity.Client.PublicClientApplicationBuilder' -as [type])) {
            Add-Type -TypeDefinition 'namespace Microsoft.Identity.Client { public class PublicClientApplicationBuilder {} }'
        }

        function New-SetupTestMsalApplication {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory MSAL test double and does not change external state.')]
            param(
                [Parameter(Mandatory)][object[]]$Accounts,
                [Parameter()][object]$AuthenticationResult
            )

            $cache = [pscustomobject]@{}
            $cache | Add-Member -MemberType ScriptMethod -Name SerializeMsalV3 -Value { return [byte[]]@() }

            $accountTask = [pscustomobject]@{ Result = $Accounts }
            $accountTask | Add-Member -MemberType ScriptMethod -Name GetAwaiter -Value { return $this }
            $accountTask | Add-Member -MemberType ScriptMethod -Name GetResult -Value { return $this.Result }
            $accountTaskAccessor = { return $accountTask }.GetNewClosure()

            $application = [pscustomobject]@{
                UserTokenCache = $cache
                LastScopes     = @()
                LastAccount    = $null
            }
            $application | Add-Member -MemberType ScriptMethod -Name GetAccountsAsync -Value $accountTaskAccessor

            if ($null -ne $AuthenticationResult) {
                $authenticationTask = [pscustomobject]@{ Result = $AuthenticationResult }
                $authenticationTask | Add-Member -MemberType ScriptMethod -Name GetAwaiter -Value { return $this }
                $authenticationTask | Add-Member -MemberType ScriptMethod -Name GetResult -Value { return $this.Result }

                $silentBuilder = [pscustomobject]@{}
                $silentBuilder | Add-Member -MemberType ScriptMethod -Name ExecuteAsync -Value {
                    return $authenticationTask
                }.GetNewClosure()
                $acquireTokenSilent = {
                    param($Scopes, $Account)
                    $this.LastScopes = @($Scopes)
                    $this.LastAccount = $Account
                    return $silentBuilder
                }.GetNewClosure()
                $application | Add-Member -MemberType ScriptMethod -Name AcquireTokenSilent -Value $acquireTokenSilent
            }

            return $application
        }
    }

    BeforeEach {
        Mock Get-Module { $null }
        Mock Initialize-SetupMsalAssembly {}
        Mock New-DirectoryIfMissing {}
        Mock Test-Path { $false }
        $script:entraApplicationCache = @{}
        Remove-Variable -Name MsalApp -Scope Script -ErrorAction SilentlyContinue
    }

    It 'lists distinct nonblank cached usernames without acquiring a token' {
        $accounts = @(
            [pscustomobject]@{ Username = 'first@example.invalid' }
            [pscustomobject]@{ Username = 'first@example.invalid' }
            [pscustomobject]@{ Username = '' }
            [pscustomobject]@{ Username = 'second@example.invalid' }
        )
        $script:MsalApp = New-SetupTestMsalApplication -Accounts $accounts

        @(Get-AuthToken -ResourceUrl 'https://api.example.invalid/' -ListAccountsOnly) |
            Should -Be @('first@example.invalid', 'second@example.invalid')
        Should -Invoke Initialize-SetupMsalAssembly -Times 1 -Exactly
    }

    It 'acquires a silent token with the normalized scope and preferred cached account' {
        $accounts = @(
            [pscustomobject]@{ Username = 'first@example.invalid' }
            [pscustomobject]@{ Username = 'second@example.invalid' }
        )
        $authenticationResult = [pscustomobject]@{ ResultName = 'silent-result' }
        $script:MsalApp = New-SetupTestMsalApplication -Accounts $accounts -AuthenticationResult $authenticationResult

        $result = Get-AuthToken -ResourceUrl 'https://api.example.invalid/' -PreferredUsername 'SECOND@example.invalid'

        $result.ResultName | Should -Be 'silent-result'
        $script:MsalApp.LastScopes | Should -Be @('https://api.example.invalid/.default')
        $script:MsalApp.LastAccount.Username | Should -Be 'second@example.invalid'
    }
}

Describe 'Setup authentication reference resolution' {
    BeforeAll {
        function Get-DataverseEnvironmentCatalog {}
    }

    BeforeEach {
        $script:entraApplicationCache = @{}
    }

    It 'returns the configured fallback for blank or unresolved environment URLs' {
        Resolve-DataverseEnvironmentFriendlyName -EnvironmentUrl '' -FallbackName 'Configured name' |
            Should -Be 'Configured name'

        Mock Get-DataverseEnvironmentCatalog { throw 'Catalog unavailable' }
        Resolve-DataverseEnvironmentFriendlyName -EnvironmentUrl 'https://org.example.invalid' -FallbackName 'Configured name' |
            Should -Be 'Configured name'
    }

    It 'resolves an environment friendly name by normalized endpoint URL' {
        Mock Get-DataverseEnvironmentCatalog {
            @(
                [pscustomobject]@{
                    Endpoints    = @{ WebApplication = 'https://org.example.invalid/' }
                    FriendlyName = 'Development'
                }
            )
        }

        Resolve-DataverseEnvironmentFriendlyName -EnvironmentUrl 'https://org.example.invalid' -FallbackName 'Configured name' |
            Should -Be 'Development'
    }

    It 'returns and caches matching Graph application metadata' {
        Mock Get-AuthToken { [pscustomobject]@{ AccessToken = '' } }
        Mock Invoke-RestMethod {
            [pscustomobject]@{
                value = @(
                    [pscustomobject]@{
                        id          = 'application-object'
                        appId       = 'application-client'
                        displayName = 'Setup application'
                    }
                )
            }
        }

        $application = Resolve-EntraIdApplicationByAppId -ApplicationId 'application-client' -TenantId 'tenant.example.invalid'
        $cachedApplication = Resolve-EntraIdApplicationByAppId -ApplicationId 'application-client' -TenantId 'tenant.example.invalid'

        $application.displayName | Should -Be 'Setup application'
        $cachedApplication.id | Should -Be 'application-object'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
    }

    It 'caches Graph misses and rejects blank identifiers before authenticating' {
        Mock Get-AuthToken { [pscustomobject]@{ AccessToken = '' } }
        Mock Invoke-RestMethod { [pscustomobject]@{ value = @() } }

        Resolve-EntraIdApplicationByAppId -ApplicationId '' -TenantId 'tenant.example.invalid' |
            Should -BeNullOrEmpty
        Resolve-EntraIdApplicationByAppId -ApplicationId 'application-client' -TenantId 'tenant.example.invalid' |
            Should -BeNullOrEmpty
        Resolve-EntraIdApplicationByAppId -ApplicationId 'application-client' -TenantId 'tenant.example.invalid' |
            Should -BeNullOrEmpty

        Should -Invoke Get-AuthToken -Times 1 -Exactly
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
    }
}

Describe 'Setup access token preauthentication' {
    It 'normalizes the resource and returns a token acquired with the requested tenant' {
        Mock Get-AuthToken { [pscustomobject]@{ AccessToken = 'fake-token' } }

        Get-SetupAccessToken -ResourceUrl 'https://test.example.com/api/data/v9.2' -TenantId 'example.com' |
            Should -Be 'fake-token'

        Should -Invoke Get-AuthToken -Times 1 -Exactly -ParameterFilter {
            $ResourceUrl -eq 'https://test.example.com' -and $TenantId -eq 'example.com'
        }
    }

    It 'rejects invalid resources and missing access tokens' {
        Mock Get-AuthToken { throw 'Unexpected authentication' }
        { Get-SetupAccessToken -ResourceUrl 'relative/resource' } |
            Should -Throw '*valid HTTP(S) resource URL*'
        Should -Invoke Get-AuthToken -Times 0 -Exactly

        Mock Get-AuthToken { [pscustomobject]@{ AccessToken = '' } }
        { Get-SetupAccessToken -ResourceUrl 'https://test.example.com' } |
            Should -Throw '*did not return an access token*'
    }
}

Describe 'Setup access token callbacks' {
    It 'returns the captured token from a worker task without reacquiring it' {
        Mock Get-AuthToken { [pscustomobject]@{ AccessToken = 'fake-token' } }
        $callback = Get-SetupAccessTokenCallback -ResourceUrl 'https://test.example.com/api/data/v9.2' -TenantId 'example.com'
        $task = [Alm4DataverseSetupAccessTokenTestRunner]::Invoke($callback, 'https://test.example.com/api/data/v9.2')

        if (-not $task.Wait([TimeSpan]::FromSeconds(5))) {
            throw 'The worker callback did not complete.'
        }

        $task.Result.Count | Should -Be 1
        $task.Result[0] | Should -Be 'fake-token'
        Should -Invoke Get-AuthToken -Times 1 -Exactly -ParameterFilter {
            $ResourceUrl -eq 'https://test.example.com' -and $TenantId -eq 'example.com'
        }
    }

    It 'rejects a callback request for a different resource' {
        Mock Get-AuthToken { [pscustomobject]@{ AccessToken = 'fake-token' } }
        $callback = Get-SetupAccessTokenCallback -ResourceUrl 'https://test.example.com' -TenantId 'example.com'

        { & $callback 'https://other.example.com/api/data/v9.2' } |
            Should -Throw '*unexpected resource*'
    }
}

Describe 'Setup status callback state' {
    BeforeAll {
        # The embedded Spectre substitute captures renderables and dequeues prompt answers;
        # it tests wrapper contracts, not terminal rendering. CLR types persist for this process.
        if (-not ('Spectre.Console.AnsiConsole' -as [type])) {
            Add-Type -TypeDefinition @'
namespace Spectre.Console {
    public class Markup : Rendering.IRenderable {
        public string Text;
        public Markup(string text) { Text = text; }
        public override string ToString() { return Text; }
    }
    public class Padding { public Padding(int left, int top, int right, int bottom) {} }
    public class BoxBorder { public static object Rounded = new object(); }
    public class PanelHeader { public string Text; public PanelHeader(string text) { Text = text; } }
    public class Panel : Rendering.IRenderable {
        public object Content, Border, BorderStyle, Padding;
        public PanelHeader Header;
        public bool Expand;
        public Panel(object content) { Content = content; }
        public override string ToString() { return (Header == null ? "" : Header.Text) + " " + Content; }
    }
    public class TableColumn { public string Text; public TableColumn(string text) { Text = text; } }
    public class Table : Rendering.IRenderable {
        public System.Collections.Generic.List<Rendering.IRenderable[]> Rows = new System.Collections.Generic.List<Rendering.IRenderable[]>();
        public System.Collections.Generic.List<TableColumn> Columns = new System.Collections.Generic.List<TableColumn>();
        public void AddColumn(TableColumn column) { Columns.Add(column); }
    }
    public class GridColumn { public bool NoWrap; public int Width; public Padding Padding; }
    public class Grid : Rendering.IRenderable {
        public bool Expand;
        public System.Collections.Generic.List<Rendering.IRenderable[]> Rows = new System.Collections.Generic.List<Rendering.IRenderable[]>();
        public void AddColumn() {}
        public void AddColumn(GridColumn column) {}
        public void AddRow(Rendering.IRenderable[] row) { Rows.Add(row); }
    }
    public class Columns : Rendering.IRenderable {
        public bool Expand;
        public Padding Padding;
        public Rendering.IRenderable[] Items;
        public Columns(Rendering.IRenderable[] items) { Items = items; }
    }
    public interface IAnsiConsoleInput {
        bool IsKeyAvailable();
        System.ConsoleKeyInfo? ReadKey(bool intercept);
        System.Threading.Tasks.Task<System.ConsoleKeyInfo?> ReadKeyAsync(bool intercept, System.Threading.CancellationToken token);
    }
    public interface IAnsiConsole {
        IAnsiConsoleInput Input { get; }
    }
    public class TestAnsiConsoleInput : IAnsiConsoleInput {
        public bool IsKeyAvailable() { return AnsiConsole.Keys.Count > 0; }
        public System.ConsoleKeyInfo? ReadKey(bool intercept) {
            if (AnsiConsole.Keys.Count == 0) {
                return new System.ConsoleKeyInfo('\r', System.ConsoleKey.Enter, false, false, false);
            }
            return AnsiConsole.Keys.Dequeue();
        }
        public System.Threading.Tasks.Task<System.ConsoleKeyInfo?> ReadKeyAsync(bool intercept, System.Threading.CancellationToken token) {
            token.ThrowIfCancellationRequested();
            return System.Threading.Tasks.Task.FromResult(ReadKey(intercept));
        }
    }
    public class TestAnsiConsole : IAnsiConsole {
        private readonly IAnsiConsoleInput _input = new TestAnsiConsoleInput();
        public IAnsiConsoleInput Input { get { return _input; } }
    }
    public class SelectionPromptItem<T> {
        private readonly System.Collections.Generic.List<T> _choices;
        public SelectionPromptItem(System.Collections.Generic.List<T> choices) { _choices = choices; }
        public SelectionPromptItem<T> AddChild(T value) {
            _choices.Add(value);
            return this;
        }
    }
    public class SelectionPrompt<T> {
        public string MoreChoicesText, SearchPlaceholderText;
        public bool WrapAround, SearchEnabled;
        public int PageSize;
        public System.Collections.Generic.List<T> Choices = new System.Collections.Generic.List<T>();
        public SelectionPromptItem<T> AddChoice(T value) {
            Choices.Add(value);
            return new SelectionPromptItem<T>(Choices);
        }
        public System.Threading.Tasks.Task<T> ShowAsync(object console, System.Threading.CancellationToken token) {
            token.ThrowIfCancellationRequested();
            ((IAnsiConsole)console).Input.ReadKeyAsync(true, token).GetAwaiter().GetResult();
            return System.Threading.Tasks.Task.FromResult((T)AnsiConsole.Answers.Dequeue());
        }
    }
    public class TextPrompt<T> {
        public bool IsSecret, AllowEmpty;
        public TextPrompt(string text) {}
        public T Show(object console) {
            ((IAnsiConsole)console).Input.ReadKey(true);
            return (T)AnsiConsole.Answers.Dequeue();
        }
    }
    public class StatusContext {}
    public class Style {
        public static object Parse(string value) { return null; }
    }
    public class StatusDisplay {
        public bool AutoRefresh { get; set; }
        public object SpinnerStyle { get; set; }
        public object Start(string status, System.Func<StatusContext, object> callback) {
            return callback(new StatusContext());
        }
    }
    public static class AnsiConsole {
        private static IAnsiConsole _console = new TestAnsiConsole();
        public static IAnsiConsole Console { get { return _console; } set { _console = value; } }
        public static System.Collections.Generic.Queue<object> Answers = new System.Collections.Generic.Queue<object>();
        public static System.Collections.Generic.Queue<System.ConsoleKeyInfo?> Keys = new System.Collections.Generic.Queue<System.ConsoleKeyInfo?>();
        public static System.Collections.Generic.List<object> Output = new System.Collections.Generic.List<object>();
        public static StatusDisplay Status() { return new StatusDisplay(); }
        public static void MarkupLine(string value) { Output.Add(value); }
        public static void WriteLine() {}
        public static void Write(object value) { Output.Add(value); }
        public static void Markup(string value) { Output.Add(value); }
        public static void Clear() { Output.Clear(); }
        public static bool Confirm(string value, bool defaultValue) {
            Console.Input.ReadKey(true);
            return Answers.Count == 0 ? defaultValue : (bool)Answers.Dequeue();
        }
        public static T Ask<T>(string value, T defaultValue) {
            Console.Input.ReadKey(true);
            return Answers.Count == 0 ? defaultValue : (T)Answers.Dequeue();
        }
    }
}
namespace Spectre.Console.Rendering { public interface IRenderable {} }
'@
        }
    }

    It 'does not repeat a completed operation when the output panel fails' {
        Mock Initialize-SpectreConsole {}
        Mock Show-SetupActivityOutputPanel { throw 'Display failed' }
        # Shared mutable state crosses the status delegate boundary and reveals an accidental
        # retry of a completed side effect when only rendering the result failed.
        $executionState = @{ Count = 0 }
        $result = Invoke-WithSpectreStatus -Status 'Test operation' -CaptureOutputInPanel -ScriptBlock {
            $executionState.Count++
            [pscustomobject]@{ Value = 42 }
        }
        $executionState.Count | Should -Be 1
        $result.Value | Should -Be 42
    }

    It 'shows the inner PowerShell error location for a wrapped status callback failure' {
        Mock Initialize-SpectreConsole {}
        Mock Select-FromMenu { 1 }
        [Spectre.Console.AnsiConsole]::Clear()

        $innerException = $null
        try {
            $null.ToString()
        }
        catch {
            $innerException = $_.Exception
        }
        $script:statusCallbackException = [System.Reflection.TargetInvocationException]::new('Status callback failed', $innerException)

        {
            Invoke-WithErrorHandling -OperationName 'Test callback' -StatusMessage 'Running test callback' -CaptureOutputInPanel -ScriptBlock {
                throw $script:statusCallbackException
            }
        } | Should -Throw '*Setup aborted by user after error in Test callback*'

        $output = [Spectre.Console.AnsiConsole]::Output -join [Environment]::NewLine
        $output | Should -Match 'Inner Error Type'
        $output | Should -Match 'You cannot call a method on a null-valued expression'
        $output | Should -Match 'Inner Location'
        $output | Should -Match 'SetupCommon.Tests.ps1'
        $output | Should -Match 'Inner Stack Trace'
    }
}

Describe 'Setup selector state transitions' {
    BeforeEach {
        Mock Initialize-SpectreConsole {}
        Mock Write-SetupConsoleBar { $false }
        # Resolve answers against the current menu instead of hard-coded indexes; unexpected
        # extra prompts fail immediately rather than silently navigating a different branch.
        $script:menuAnswers = [System.Collections.Generic.Queue[string]]::new()
        $script:textAnswers = [System.Collections.Generic.Queue[string]]::new()
        Mock Select-FromMenu {
            if ($script:menuAnswers.Count -eq 0) { throw "Unexpected menu: $Title" }
            $answer = $script:menuAnswers.Dequeue()
            $index = [array]::IndexOf($Items, $answer)
            if ($index -lt 0) { throw "Unavailable answer '$answer' in '$Title': $($Items -join ', ')" }
            $index
        }
        Mock Read-TextWithDefault {
            if ($script:textAnswers.Count -eq 0) { throw "Unexpected text prompt: $Prompt" }
            $script:textAnswers.Dequeue()
        }
    }

    It 'adds, reorders and removes solutions without changing their identity' {
        foreach ($answer in @('Add a solution', 'One (one)', 'Add a solution', 'Two (two)', 'Move a solution earlier', 'Two (two)', 'Move a solution later', 'Two (two)', 'Remove a solution', 'Two (two)', 'Done')) { $script:menuAnswers.Enqueue($answer) }
        $solutions = @([pscustomobject]@{ friendlyname = 'One'; uniquename = 'one' }, [pscustomobject]@{ friendlyname = 'Two'; uniquename = 'two' })
        $selected = @(Select-OrderedSolution -AvailableSolutions $solutions)
        $selected.Count | Should -Be 1
        $selected[0] | Should -Be $solutions[0]
        $script:menuAnswers.Count | Should -Be 0
    }

    It 'clears an existing solution selection' {
        foreach ($answer in @('Clear list', 'Done')) { $script:menuAnswers.Enqueue($answer) }
        $solution = [pscustomobject]@{ friendlyname = 'One'; uniquename = 'one' }
        @(Select-OrderedSolution -AvailableSolutions @($solution) -InitiallySelectedSolutions @($solution)).Count | Should -Be 0
    }

    It 'initializes both supported bootstrap branch strategies and calls environment editors' -ForEach @(
        @{ Strategy = 'main only (recommended simple option)'; ExpectedBranches = @('main') }
        @{ Strategy = 'main + develop (required for environments that enforce PRs)'; ExpectedBranches = @('main', 'develop') }
    ) {
        $script:menuAnswers.Enqueue($Strategy)
        $script:menuAnswers.Enqueue('Done')
        $initial = [pscustomobject]@{ BranchName = 'main'; Environments = @() }
        $result = @(Select-BranchEnvironmentMapping -InitialBranchMappings @($initial) -BranchOnly -IsNewRepository -EditDevEnvironmentScriptBlock {
            param($allMappings, $mapping)
            $allMappings.Count | Should -Be $ExpectedBranches.Count
            [pscustomobject]@{ ShortName = "Dev-$($mapping.BranchName)" }
        } -EditDeploymentEnvironmentsScriptBlock {
            param($allMappings, $mapping)
            $allMappings.Count | Should -Be $ExpectedBranches.Count
            [pscustomobject]@{ ShortName = "Target-$($mapping.BranchName)"; Url = "https://$($mapping.BranchName).example.com" }
        })
        @($result.BranchName) | Should -Be $ExpectedBranches
        foreach ($mapping in $result) {
            $mapping.DevEnvironmentConfiguration.ShortName | Should -Be "Dev-$($mapping.BranchName)"
            $mapping.Environments[0].ShortName | Should -Be "Target-$($mapping.BranchName)"
        }
    }

    It 'skips branch-strategy selection for an existing repository' {
        $script:menuAnswers.Enqueue('Done')
        $initial = [pscustomobject]@{ BranchName = 'main'; Environments = @() }

        $result = @(Select-BranchEnvironmentMapping -InitialBranchMappings @($initial) -BranchOnly)

        @($result.BranchName) | Should -Be @('main')
        $script:menuAnswers.Count | Should -Be 0
    }

    It 'shows the selected branch setup before opening its edit menu' {
        $script:menuAnswers.Enqueue('Done')
        $initial = @(
            [pscustomobject]@{ BranchName = 'main'; Environments = @() }
            [pscustomobject]@{
                BranchName = 'develop'
                DevEnvironmentConfiguration = [pscustomobject]@{ ShortName = 'Dev-develop' }
                Environments = @([pscustomobject]@{ ShortName = 'PROD' })
                BuildValidationEnabled = $true
                BuildValidationEnvironmentName = 'Build-develop'
                BuildValidationBaselineRelease = 'stable'
            }
        )
        Mock Show-BranchEnvironmentMappingTable {
            $script:branchSummaryMappings = @($BranchMappings)
        }

        $result = @(Select-BranchEnvironmentMapping `
            -InitialBranchMappings $initial `
            -BranchOnly `
            -InitialEditTarget ([pscustomobject]@{ Kind = 'Branch'; BranchName = 'develop' }))

        @($result.BranchName) | Should -Be @('main', 'develop')
        Should -Invoke Select-FromMenu -Times 1 -Exactly -ParameterFilter {
            $Title -eq "Edit branch 'develop'"
        }
        Should -Invoke Show-BranchEnvironmentMappingTable -Times 1 -Exactly -ParameterFilter {
            $BranchMappings.Count -eq 1 -and $BranchMappings[0].BranchName -eq 'develop'
        }
        $script:branchSummaryMappings[0].DevEnvironmentConfiguration.ShortName | Should -Be 'Dev-develop'
        $script:branchSummaryMappings[0].Environments[0].ShortName | Should -Be 'PROD'
        $script:branchSummaryMappings[0].BuildValidationEnvironmentName | Should -Be 'Build-develop'
        $script:branchSummaryMappings[0].BuildValidationBaselineRelease | Should -Be 'stable'
        $script:menuAnswers.Count | Should -Be 0
    }

    It 'opens the selected DEV environment editor directly from the setup menu' {
        $initial = [pscustomobject]@{
            BranchName = 'main'
            DevEnvironmentConfiguration = [pscustomobject]@{ ShortName = 'Dev-main' }
            Environments = @()
            BuildValidationEnabled = $false
        }
        $target = [pscustomobject]@{
            Kind = 'DevEnvironment'
            BranchName = 'main'
            EnvironmentName = 'Dev-main'
        }

        $result = @(Select-BranchEnvironmentMapping `
            -InitialBranchMappings @($initial) `
            -BranchOnly `
            -InitialEditTarget $target `
            -EditDevEnvironmentScriptBlock {
                param($allMappings, $mappingToEdit, $environmentNameToEdit)
                @($allMappings).Count | Should -Be 1
                $mappingToEdit.BranchName | Should -Be main
                $environmentNameToEdit | Should -Be 'Dev-main'
                [pscustomobject]@{ ShortName = 'Dev-updated' }
            })

        $result[0].DevEnvironmentConfiguration.ShortName | Should -Be 'Dev-updated'
        $script:menuAnswers.Count | Should -Be 0
    }

    It 'opens the selected deployment environment editor for that branch and environment' {
        $initial = [pscustomobject]@{
            BranchName = 'main'
            Environments = @([pscustomobject]@{ ShortName = 'PROD' }, [pscustomobject]@{ ShortName = 'TEST' })
            BuildValidationEnabled = $false
        }
        $target = [pscustomobject]@{
            Kind = 'DeploymentEnvironment'
            BranchName = 'main'
            EnvironmentName = 'TEST'
        }

        $result = @(Select-BranchEnvironmentMapping `
            -InitialBranchMappings @($initial) `
            -BranchOnly `
            -InitialEditTarget $target `
            -EditDeploymentEnvironmentsScriptBlock {
                param($allMappings, $mappingToEdit, $environmentNameToEdit)
                @($allMappings).Count | Should -Be 1
                $mappingToEdit.BranchName | Should -Be main
                $environmentNameToEdit | Should -Be TEST
                @([pscustomobject]@{ ShortName = 'PROD' }, [pscustomobject]@{ ShortName = 'UAT' })
            })

        $result[0].Environments.ShortName | Should -Be @('PROD', 'UAT')
        $script:menuAnswers.Count | Should -Be 0
    }

    It 'opens the selected BUILD-validation editor directly from the setup menu' {
        $initial = [pscustomobject]@{
            BranchName = 'main'
            Environments = @()
            BuildValidationEnabled = $true
            BuildValidationEnvironmentName = 'Build-main'
        }
        $target = [pscustomobject]@{
            Kind = 'BuildValidation'
            BranchName = 'main'
            EnvironmentName = 'Build-main'
        }

        $result = @(Select-BranchEnvironmentMapping `
            -InitialBranchMappings @($initial) `
            -BranchOnly `
            -InitialEditTarget $target `
            -EditBuildValidationScriptBlock {
                param($allMappings, $mappingToEdit, $environmentNameToEdit)
                @($allMappings).Count | Should -Be 1
                $mappingToEdit.BranchName | Should -Be main
                $environmentNameToEdit | Should -Be 'Build-main'
                [pscustomobject]@{
                    BuildValidationEnabled = $true
                    BuildValidationEnvironmentName = 'Build-updated'
                    BuildValidationBaselineRelease = ''
                    BuildValidationEnvironmentConfiguration = $null
                    ExistingBuildValidationEnvironment = $null
                }
            })

        $result[0].BuildValidationEnabled | Should -BeTrue
        $result[0].BuildValidationEnvironmentName | Should -Be 'Build-updated'
        $script:menuAnswers.Count | Should -Be 0
    }

    It 'renames a branch, assigns a target exclusively, then removes another branch' {
        foreach ($answer in @('Edit a branch mapping', 'main', 'Rename branch', 'Assign environments', 'QA - QA [not selected]', 'Done', 'Done', 'Remove a branch mapping', 'develop', 'Done')) { $script:menuAnswers.Enqueue($answer) }
        $script:textAnswers.Enqueue('release')
        $qa = [pscustomobject]@{ ShortName = 'QA'; FriendlyName = 'QA'; Url = 'https://qa.example.com' }
        $prod = [pscustomobject]@{ ShortName = 'PROD'; FriendlyName = 'Production'; Url = 'https://prod.example.com' }
        $initial = @([pscustomobject]@{ BranchName = 'main'; Environments = @() }, [pscustomobject]@{ BranchName = 'develop'; Environments = @($prod) })
        $result = @(Select-BranchEnvironmentMapping -EnvironmentConfigurations @($qa, $prod) -InitialBranchMappings $initial)
        $result.Count | Should -Be 1
        $result[0].BranchName | Should -Be release
        $result[0].Environments[0].ShortName | Should -Be QA
        $script:menuAnswers.Count | Should -Be 0
    }

    It 'adds and edits a deployment target and invokes both callback contracts' {
        foreach ($answer in @('Add an environment', 'Edit an environment', 'TEST - Test (https://test.example.com)', 'Done')) { $script:menuAnswers.Enqueue($answer) }
        $result = @(Select-ConfiguredDeploymentEnvironment -AddEnvironmentScriptBlock {
            param($currentSelections)
            @($currentSelections).Count | Should -Be 0
            [pscustomobject]@{ ShortName = 'TEST'; FriendlyName = 'Test'; Url = 'https://test.example.com'; Credentials = $null; ServiceAccountUPN = '' }
        } -EditEnvironmentScriptBlock {
            param($currentSelections, $environment, $index)
            @($currentSelections).Count | Should -Be 1
            $index | Should -Be 0
            $environment.FriendlyName = 'Edited'
            $environment
        })
        $result.Count | Should -Be 1
        $result[0].FriendlyName | Should -Be Edited
    }

    It 'jumps directly to editing a selected deployment environment' {
        Mock Show-EnvironmentConfigurationTable {}
        $initialEnvironment = [pscustomobject]@{
            ShortName = 'TEST'
            FriendlyName = 'Test'
            Url = 'https://test.example.com'
        }

        $result = @(Select-ConfiguredDeploymentEnvironment `
            -InitialEnvironments @($initialEnvironment) `
            -InitialEditEnvironmentName 'TEST' `
            -AddEnvironmentScriptBlock { throw 'The focused editor must not add an environment.' } `
            -EditEnvironmentScriptBlock {
                param($currentSelections, $environment, $index)
                @($currentSelections).Count | Should -Be 1
                $index | Should -Be 0
                $environment.ShortName | Should -Be TEST
                [pscustomobject]@{
                    ShortName = 'UAT'
                    FriendlyName = 'Updated'
                    Url = 'https://uat.example.com'
                }
            })

        $result.Count | Should -Be 1
        $result[0].ShortName | Should -Be UAT
        $script:menuAnswers.Count | Should -Be 0
    }
}

Describe 'Setup wizard navigation menu' {
    BeforeEach {
        Mock Initialize-SpectreConsole {}
        $script:wizardSelections = [System.Collections.Generic.Queue[int]]::new()
        $script:wizardMenuItems = @()
        $script:wizardActionMenuItems = @()
        $script:wizardActionSectionsFirst = @()
        [Spectre.Console.AnsiConsole]::Keys.Clear()
        Mock Select-FromMenu {
            $script:wizardMenuItems += ,@($Items)
            $script:wizardActionMenuItems += ,@($ActionItems)
            $script:wizardActionSectionsFirst += [bool]$ActionSectionFirst
            if ($script:wizardSelections.Count -eq 0) {
                throw "Unexpected setup menu: $Title"
            }
            $script:wizardSelections.Dequeue()
        }
        [Spectre.Console.AnsiConsole]::Clear()
    }

    It 'allows existing repositories to jump between steps and invalidates later completion' {
        foreach ($selection in @(1, 0, 1, 0)) {
            $script:wizardSelections.Enqueue($selection)
        }
        $script:stepCalls = @{ First = 0; Second = 0; Apply = 0 }
        $steps = @(
            [pscustomobject]@{ Name = 'First'; Action = { $script:stepCalls.First++ } }
            [pscustomobject]@{ Name = 'Second'; Action = { $script:stepCalls.Second++ } }
        )

        $result = Invoke-SetupWizard -Title 'Setup' -Steps $steps -ApplyAction {
            $script:stepCalls.Apply++
            'applied'
        }

        $result | Should -Be applied
        $script:stepCalls.First | Should -Be 1
        $script:stepCalls.Second | Should -Be 2
        $script:stepCalls.Apply | Should -Be 1
        $script:wizardMenuItems.Count | Should -Be 4
        $script:wizardSelections.Count | Should -Be 0
    }

    It 'limits new repositories to the furthest step reached' {
        foreach ($selection in @(0, 1, 0)) {
            $script:wizardSelections.Enqueue($selection)
        }
        $script:stepCalls = @{ First = 0; Second = 0; Apply = 0 }
        $steps = @(
            [pscustomobject]@{ Name = 'First'; Action = { $script:stepCalls.First++ } }
            [pscustomobject]@{ Name = 'Second'; Action = { $script:stepCalls.Second++ } }
        )

        Invoke-SetupWizard -Title 'Setup' -Steps $steps -IsNewRepository -ApplyAction {
            $script:stepCalls.Apply++
        }

        $script:stepCalls.First | Should -Be 1
        $script:stepCalls.Second | Should -Be 1
        $script:stepCalls.Apply | Should -Be 1
        $script:wizardMenuItems.Count | Should -Be 3
        $script:wizardSelections.Count | Should -Be 0
    }

    It 'returns to a nested editor caller without showing the whole-setup exit action' {
        Mock Select-FromMenu {
            $script:wizardMenuItems += ,@($Items)
            $script:wizardActionMenuItems += ,@($ActionItems)
            return $null
        }
        $steps = @([pscustomobject]@{ Name = 'Configure'; Action = {} })

        $result = Invoke-SetupWizard `
            -Title 'Environment details' `
            -Steps $steps `
            -ApplyAction { 'done' } `
            -ApplyActionName 'Done' `
            -ReturnToCaller

        $result | Should -BeNullOrEmpty
        $script:wizardMenuItems.Count | Should -Be 1
        $script:wizardMenuItems[0] | Should -Not -Contain 'Exit without applying changes'
        $script:wizardActionMenuItems[0] | Should -Not -Contain 'Exit without applying changes'
    }

    It 'shows configured summaries and reevaluates dynamic summaries after a step runs' {
        $script:wizardSummaryState = @{ Branches = 'Not configured' }
        $script:wizardSelections.Enqueue(0)
        $script:wizardSelections.Enqueue(0)
        $steps = @(
            [pscustomobject]@{
                Name = 'Configure repository settings'
                Summary = { $script:wizardSummaryState.Branches }
                Action = { $script:wizardSummaryState.Branches = 'main (PROD)' }
            }
        )

        Invoke-SetupWizard -Title 'Setup' -Steps $steps -ApplyAction {}

        $script:wizardMenuItems.Count | Should -Be 2
        $script:wizardMenuItems[0][0] | Should -Be '[ ] Configure repository settings - Not configured'
        $script:wizardMenuItems[1][0] | Should -Be 'Apply changes - Ready'
        $script:wizardMenuItems[1][1] | Should -Be 'Exit without applying changes'
        $script:wizardMenuItems[1][2] | Should -Be '[✓] Configure repository settings - main (PROD)'
    }

    It 'guides a new environment through sequential detail steps and keeps secrets out of summaries' {
        foreach ($selection in @(0, 1, 2, 3, 4, 0)) {
            $script:wizardSelections.Enqueue($selection)
        }
        $credential = [pscustomobject]@{
            Name = 'Example deployment app'
            ApplicationId = 'example-app-id'
            AuthType = 'WIF'
            ClientSecret = 'must-not-be-displayed'
        }
        $script:environmentTestCredential = $credential

        $result = Invoke-SetupEnvironmentConfigurationWizard `
            -Title 'Configure deployment environment' `
            -SelectDataverseEnvironmentAction {
                [pscustomobject]@{ FriendlyName = 'Test'; Url = 'https://test.example.com/' }
            } `
            -SelectTargetNameAction { 'TEST' } `
            -SelectCredentialsAction { $script:environmentTestCredential } `
            -SelectServiceAccountAction { 'service@example.com' } `
            -SelectBaselineAction { '@PROD' }

        $result.ShortName | Should -Be 'TEST'
        $result.FriendlyName | Should -Be 'Test'
        $result.Url | Should -Be 'https://test.example.com'
        $result.Credentials | Should -Be $credential
        $result.ServiceAccountUPN | Should -Be 'service@example.com'
        $result.BaselineRelease | Should -Be '@PROD'
        $script:wizardMenuItems[0] | Should -Contain '[ ] Target name - Not configured (locked; complete earlier steps first)'
        $script:wizardMenuItems[1] | Should -Contain '[✓] Dataverse environment - Test (https://test.example.com)'
        $script:wizardMenuItems[1] | Should -Contain '[ ] Credentials - Not configured (locked; complete earlier steps first)'
        (($script:wizardMenuItems | ForEach-Object { $_ -join ' ' }) -join "`n") |
            Should -Not -Match 'must-not-be-displayed'
        $script:wizardSelections.Count | Should -Be 0
    }

    It 'shows branch-generated DEV target names as complete and locked' {
        Mock Select-FromMenu {
            $script:wizardMenuItems += ,@($Items)
            $script:wizardActionMenuItems += ,@($ActionItems)
            return $null
        }
        $configuration = [pscustomobject]@{
            ShortName = 'Dev-main'
            FriendlyName = 'Example Development'
            Url = 'https://development.example.invalid'
            Credentials = [pscustomobject]@{ Name = 'Example DEV app'; ApplicationId = 'example-dev'; AuthType = 'WIF' }
            ServiceAccountUPN = 'automation@example.invalid'
        }

        $result = Invoke-SetupEnvironmentConfigurationWizard `
            -Title "Configure DEV environment for branch 'main'" `
            -InitialConfiguration $configuration `
            -TargetNameIsFixed `
            -SelectDataverseEnvironmentAction { throw 'No edit action should run.' } `
            -SelectCredentialsAction { $configuration.Credentials } `
            -SelectServiceAccountAction { $configuration.ServiceAccountUPN }

        $result | Should -BeNullOrEmpty
        $script:wizardMenuItems[0] | Should -Contain '[✓] Target name - Dev-main (generated from branch) (locked)'
    }

    It 'clears credentials and service-account ownership when the Dataverse environment changes' {
        foreach ($selection in @(1, 1, 2, 0)) {
            $script:wizardSelections.Enqueue($selection)
        }
        $oldCredential = [pscustomobject]@{ Name = 'Old app'; ApplicationId = 'old-app'; AuthType = 'WIF' }
        $newCredential = [pscustomobject]@{ Name = 'New app'; ApplicationId = 'new-app'; AuthType = 'WIF' }
        $script:environmentTestCredential = $newCredential
        $initialConfiguration = [pscustomobject]@{
            ShortName = 'TEST'
            FriendlyName = 'Old'
            Url = 'https://old.example.com'
            Credentials = $oldCredential
            ServiceAccountUPN = 'old-service@example.com'
        }

        $result = Invoke-SetupEnvironmentConfigurationWizard `
            -Title 'Configure deployment environment' `
            -InitialConfiguration $initialConfiguration `
            -SelectDataverseEnvironmentAction {
                [pscustomobject]@{ FriendlyName = 'New'; Url = 'https://new.example.com' }
            } `
            -SelectCredentialsAction {
                param($environmentState)
                $environmentState.Credentials | Should -BeNullOrEmpty
                $script:environmentTestCredential
            } `
            -SelectServiceAccountAction {
                param($environmentState)
                $environmentState.ServiceAccountUPN | Should -BeNullOrEmpty
                'new-service@example.com'
            }

        $result.Url | Should -Be 'https://new.example.com'
        $result.Credentials | Should -Be $newCredential
        $result.ServiceAccountUPN | Should -Be 'new-service@example.com'
        $script:wizardSelections.Count | Should -Be 0
    }

    It 'shows nested step rows and passes the selected subitem target to its action' {
        $script:wizardSelections.Enqueue(2)
        $script:wizardSelections.Enqueue(0)
        $script:selectedMenuTargets = @()
        $steps = @(
            [pscustomobject]@{
                Name = 'Configure branches, dev and deployment envs'
                Summary = { throw 'Subitem rows replace the compact summary.' }
                SubItems = {
                    @(
                        [pscustomobject]@{
                            Label = 'main'
                            Depth = 1
                            Target = [pscustomobject]@{ Kind = 'Branch'; BranchName = 'main' }
                        }
                        [pscustomobject]@{
                            Label = 'DEV: Dev-main (main)'
                            Depth = 2
                            Target = [pscustomobject]@{ Kind = 'DevEnvironment'; BranchName = 'main'; EnvironmentName = 'Dev-main' }
                        }
                    )
                }
                Action = {
                    param($selectedTarget)
                    $script:selectedMenuTargets += $selectedTarget
                }
            }
        )

        $result = Invoke-SetupWizard -Title 'Setup' -Steps $steps -ApplyAction { 'applied' }

        $result | Should -Be applied
        $script:wizardMenuItems[0] | Should -Be @(
            '[ ] Configure branches, dev and deployment envs'
            '  main'
            '    DEV: Dev-main (main)'
            'Apply changes (finish all setup steps first) - Not ready'
            'Exit without applying changes'
        )
        $script:wizardMenuItems[1][2] | Should -Be '[✓] Configure branches, dev and deployment envs'
        $script:selectedMenuTargets.Count | Should -Be 1
        $script:selectedMenuTargets[0].Kind | Should -Be DevEnvironment
        $script:selectedMenuTargets[0].BranchName | Should -Be main
    }

    It 'shows an unavailable shared repository as incomplete with its reason until selected' {
        $script:wizardSharedRepositoryState = @{
            ValidationError = "Configured repository 'old-templates' was not found."
        }
        $script:wizardSelections.Enqueue(0)
        $script:wizardSelections.Enqueue(0)
        $steps = @(
            [pscustomobject]@{
                Name = 'Select shared repository'
                Summary = {
                    if ($script:wizardSharedRepositoryState.ValidationError) {
                        "Unavailable: $($script:wizardSharedRepositoryState.ValidationError)"
                    }
                    else {
                        'shared-templates (main)'
                    }
                }
                Action = { $script:wizardSharedRepositoryState.ValidationError = '' }
                IsComplete = $false
            }
        )

        Invoke-SetupWizard -Title 'Setup' -Steps $steps -ApplyAction {}

        $script:wizardMenuItems.Count | Should -Be 2
        $script:wizardMenuItems[0][0] | Should -Be '[ ] Select shared repository - Unavailable: Configured repository ''old-templates'' was not found.'
        $script:wizardMenuItems[1][1] | Should -Be 'Exit without applying changes'
        $script:wizardMenuItems[1][2] | Should -Be '[✓] Select shared repository - shared-templates (main)'
    }

    It 'keeps incomplete steps in supplied order and puts Apply first only when ready' {
        foreach ($selection in @(0, 1, 0)) {
            $script:wizardSelections.Enqueue($selection)
        }
        $script:stepCalls = @{ First = 0; Second = 0; Apply = 0 }
        $steps = @(
            [pscustomobject]@{ Name = 'First'; Action = { $script:stepCalls.First++ } }
            [pscustomobject]@{ Name = 'Second'; Action = { $script:stepCalls.Second++ } }
        )

        $result = Invoke-SetupWizard -Title 'Setup' -Steps $steps -ApplyAction {
            $script:stepCalls.Apply++
            'applied'
        }

        $result | Should -Be applied
        $script:wizardMenuItems.Count | Should -Be 3
        $script:wizardMenuItems[0][0] | Should -Be '[ ] First - Not configured'
        $script:wizardMenuItems[0][1] | Should -Be '[ ] Second - Not configured'
        $script:wizardMenuItems[0][2] | Should -Be 'Apply changes (finish all setup steps first) - Not ready'
        $script:wizardMenuItems[0][3] | Should -Be 'Exit without applying changes'
        $script:wizardMenuItems[1][0] | Should -Be '[✓] First - Complete'
        $script:wizardMenuItems[1][1] | Should -Be '[ ] Second - Not configured'
        $script:wizardMenuItems[1][2] | Should -Be 'Apply changes (finish all setup steps first) - Not ready'
        $script:wizardMenuItems[1][3] | Should -Be 'Exit without applying changes'
        $script:wizardMenuItems[2][0] | Should -Be 'Apply changes - Ready'
        $script:wizardMenuItems[2][1] | Should -Be 'Exit without applying changes'
        $script:stepCalls.First | Should -Be 1
        $script:stepCalls.Second | Should -Be 1
        $script:stepCalls.Apply | Should -Be 1
    }

    It 'keeps Preview optional and unavailable until required setup steps are complete' {
        foreach ($selection in @(1, 0, 1, 0)) {
            $script:wizardSelections.Enqueue($selection)
        }
        $script:previewCalls = 0
        $script:stepCalls = @{ Configure = 0; Apply = 0 }
        $steps = @(
            [pscustomobject]@{ Name = 'Configure'; Action = { $script:stepCalls.Configure++ } }
        )

        Invoke-SetupWizard -Title 'Setup' -Steps $steps -PreviewAction {
            $script:previewCalls++
        } -ApplyAction {
            $script:stepCalls.Apply++
        }

        $script:previewCalls | Should -Be 1
        $script:stepCalls.Configure | Should -Be 1
        $script:stepCalls.Apply | Should -Be 1
        $script:wizardMenuItems.Count | Should -Be 4
        $script:wizardMenuItems[0] | Should -Be $script:wizardMenuItems[1]
        $script:wizardMenuItems[0][1] | Should -Be 'Preview changes (finish all setup steps first) - Not ready'
        $script:wizardMenuItems[0][2] | Should -Be 'Apply changes (finish all setup steps first) - Not ready'
        $script:wizardMenuItems[0][3] | Should -Be 'Exit without applying changes'
        $script:wizardMenuItems[2][0] | Should -Be 'Apply changes - Ready'
        $script:wizardMenuItems[2][1] | Should -Be 'Preview changes'
        $script:wizardMenuItems[2][2] | Should -Be 'Exit without applying changes'
        $script:wizardMenuItems[2] | Should -Be $script:wizardMenuItems[3]
        $script:wizardActionMenuItems[0] | Should -Contain 'Preview changes (finish all setup steps first) - Not ready'
        $script:wizardActionMenuItems[0] | Should -Contain 'Apply changes (finish all setup steps first) - Not ready'
        $script:wizardActionMenuItems[0] | Should -Contain 'Exit without applying changes'
        $script:wizardActionMenuItems[2] | Should -Contain 'Preview changes'
        $script:wizardActionMenuItems[2] | Should -Contain 'Apply changes - Ready'
        $script:wizardActionMenuItems[2] | Should -Contain 'Exit without applying changes'
        $script:wizardActionSectionsFirst[0] | Should -BeFalse
        $script:wizardActionSectionsFirst[1] | Should -BeFalse
        $script:wizardActionSectionsFirst[2] | Should -BeTrue
        $script:wizardActionSectionsFirst[3] | Should -BeTrue
    }

    It 'allows Apply after required steps without selecting Preview' {
        foreach ($selection in @(0, 0)) {
            $script:wizardSelections.Enqueue($selection)
        }
        $script:previewCalls = 0
        $script:applyCalls = 0
        $steps = @(
            [pscustomobject]@{ Name = 'Configure'; Action = {} }
        )

        Invoke-SetupWizard -Title 'Setup' -Steps $steps -PreviewAction {
            $script:previewCalls++
        } -ApplyAction {
            $script:applyCalls++
        }

        $script:previewCalls | Should -Be 0
        $script:applyCalls | Should -Be 1
        $script:wizardMenuItems[1][0] | Should -Be 'Apply changes - Ready'
    }

    It 'requires confirmation before exiting without applying changes' {
        $script:wizardSelections.Enqueue(1)
        $script:applyCalls = 0
        $steps = @(
            [pscustomobject]@{ Name = 'Complete'; Action = {}; IsComplete = $true }
        )
        Mock Read-YesNo { $true }

        {
            Invoke-SetupWizard -Title 'Setup' -Steps $steps -ApplyAction {
                $script:applyCalls++
            }
        } | Should -Throw '*Setup exited without applying changes.*'

        $script:applyCalls | Should -Be 0
        $script:wizardActionMenuItems[0] | Should -Contain 'Exit without applying changes'
        Should -Invoke Read-YesNo -Times 1 -Exactly -ParameterFilter {
            $Prompt -eq 'Exit setup without applying changes?' -and $DefaultNo
        }
    }

    It 'returns to the menu when exit confirmation is declined' {
        foreach ($selection in @(1, 0)) {
            $script:wizardSelections.Enqueue($selection)
        }
        $script:applyCalls = 0
        $steps = @(
            [pscustomobject]@{ Name = 'Complete'; Action = {}; IsComplete = $true }
        )
        Mock Read-YesNo { $false }

        $result = Invoke-SetupWizard -Title 'Setup' -Steps $steps -ApplyAction {
            $script:applyCalls++
            'applied'
        }

        $result | Should -Be applied
        $script:applyCalls | Should -Be 1
        $script:wizardMenuItems.Count | Should -Be 2
        Should -Invoke Read-YesNo -Times 1 -Exactly -ParameterFilter { $DefaultNo }
    }

    It 'returns to the menu when exit confirmation is escaped' {
        foreach ($selection in @(1, 0)) {
            $script:wizardSelections.Enqueue($selection)
        }
        $script:applyCalls = 0
        $steps = @(
            [pscustomobject]@{ Name = 'Complete'; Action = {}; IsComplete = $true }
        )
        Mock Read-YesNo {
            throw [System.InvalidOperationException]::new('__ALM4DATAVERSE_WIZARD_BACK__')
        }

        $result = Invoke-SetupWizard -Title 'Setup' -Steps $steps -ApplyAction {
            $script:applyCalls++
            'applied'
        }

        $result | Should -Be applied
        $script:applyCalls | Should -Be 1
        $script:wizardMenuItems.Count | Should -Be 2
        Should -Invoke Read-YesNo -Times 1 -Exactly
    }

    It 'returns to the menu after apply fails and preserves selections for retry' {
        foreach ($selection in @(0, 0, 0)) {
            $script:wizardSelections.Enqueue($selection)
        }
        $script:stepCalls = @{ Configure = 0; Apply = 0 }
        $steps = @(
            [pscustomobject]@{ Name = 'Configure'; Action = { $script:stepCalls.Configure++ } }
        )

        $result = Invoke-SetupWizard -Title 'Setup' -Steps $steps -ApplyAction {
            $script:stepCalls.Apply++
            if ($script:stepCalls.Apply -eq 1) {
                throw 'Temporary publish failure'
            }
            'applied'
        }

        $result | Should -Be applied
        $script:stepCalls.Configure | Should -Be 1
        $script:stepCalls.Apply | Should -Be 2
        ([Spectre.Console.AnsiConsole]::Output -join "`n") | Should -Match 'Temporary publish failure'
        $script:wizardSelections.Count | Should -Be 0
    }
}

Describe 'Setup menu branch items' {
    It 'summarizes each selectable environment without exposing credential secrets' {
        $branchStates = @(
            [pscustomobject]@{
                BranchName = 'main'
                DevEnvironmentConfiguration = $null
                DeploymentEnvironments = @([pscustomobject]@{
                    ShortName = 'PROD'
                    FriendlyName = 'Production'
                    Url = 'https://prod.example.com'
                    Credentials = [pscustomobject]@{ Name = 'Prod deployment'; ApplicationId = 'prod-app'; AuthType = 'WIF'; ClientSecret = 'must-not-be-displayed' }
                    ServiceAccountUPN = 'deploy@example.com'
                })
                BuildValidationEnabled = $false
            },
            [pscustomobject]@{
                BranchName = 'develop'
                DevEnvironmentConfiguration = [pscustomobject]@{
                    ShortName = 'Dev-develop'
                    FriendlyName = 'Development'
                    Url = 'https://dev.example.com'
                    Credentials = [pscustomobject]@{ Name = 'Dev app'; ApplicationId = 'dev-app'; AuthType = 'WIF'; ClientSecret = 'must-not-be-displayed' }
                    ServiceAccountUPN = 'dev@example.com'
                }
                DeploymentEnvironments = @([pscustomobject]@{
                    ShortName = 'TEST'
                    FriendlyName = 'Testing'
                    Url = 'https://test.example.com'
                    Credentials = [pscustomobject]@{ Name = 'Test app'; ApplicationId = 'test-app'; AuthType = 'Secret'; ClientSecret = 'must-not-be-displayed' }
                    ServiceAccountUPN = 'test@example.com'
                })
                BuildValidationEnabled = $true
                BuildValidationEnvironmentName = 'Build-develop'
                BuildValidationEnvironmentConfiguration = [pscustomobject]@{
                    ShortName = 'Build-develop'
                    FriendlyName = 'Validation'
                    Url = 'https://build.example.com'
                    Credentials = [pscustomobject]@{ Name = 'Build app'; ApplicationId = 'build-app'; AuthType = 'WIF'; ClientSecret = 'must-not-be-displayed' }
                    ServiceAccountUPN = 'build@example.com'
                }
                BuildValidationBaselineRelease = '@PROD'
            }
        )

        $items = @(Get-SetupBranchMenuItem -BranchStates $branchStates)
        $items.Label | Should -Be @(
            'main'
            'Deployment: PROD (main) - Dataverse: Production (https://prod.example.com); Credentials: WIF - Prod deployment; Service account: deploy@example.com'
            'develop'
            'DEV: Dev-develop (develop) - Dataverse: Development (https://dev.example.com); Credentials: WIF - Dev app; Service account: dev@example.com'
            'Deployment: TEST (develop) - Dataverse: Testing (https://test.example.com); Credentials: Secret - Test app; Service account: test@example.com'
            'BUILD validation: Build-develop (develop) - Dataverse: Validation (https://build.example.com); Credentials: WIF - Build app; Service account: build@example.com; Baseline: @PROD'
        )
        ($items.Label -join "`n") | Should -Not -Match 'must-not-be-displayed'
        $items.Depth | Should -Be @(1, 2, 1, 2, 2, 2)
        $items.Target.Kind | Should -Be @('Branch', 'DeploymentEnvironment', 'Branch', 'DevEnvironment', 'DeploymentEnvironment', 'BuildValidation')
        $items[1].Target.EnvironmentName | Should -Be PROD
        $items[4].Target.EnvironmentName | Should -Be TEST
        $items[5].Target.EnvironmentName | Should -Be 'Build-develop'
        @(Get-SetupBranchMenuItem -BranchStates @()).Count | Should -Be 0
        $emptyBranchItems = @(Get-SetupBranchMenuItem -BranchStates @(
            [pscustomobject]@{
                BranchName = 'main'
                Environments = @()
                BuildValidationEnabled = $false
            }
        ))
        $emptyBranchItems.Count | Should -Be 1
        $emptyBranchItems[0].Label | Should -Be main
        $emptyBranchItems[0].Depth | Should -Be 1
    }

    It 'lists selected direct and pull-request publication plans' {
        $branchStates = @(
            [pscustomobject]@{
                BranchName = 'main'
                PublishPlan = [pscustomobject]@{
                    Mode = 'Direct'
                    TargetBranch = 'main'
                }
            },
            [pscustomobject]@{
                BranchName = 'develop'
                PublishPlan = [pscustomobject]@{
                    Mode = 'PullRequest'
                    BranchName = 'setup/develop'
                    TargetBranch = 'develop'
                }
            }
        )

        Get-SetupPublishPlanMenuSummary -BranchStates $branchStates |
            Should -Be 'main: direct, develop: PR from setup/develop'
        Get-SetupPublishPlanMenuSummary -BranchStates @() | Should -Be 'Not configured'
    }

    It 'lists selected solutions and distinguishes empty from unconfigured selections' {
        $solutionData = [pscustomobject]@{
            Solutions = @(
                @{ name = 'Core' }
                @{ name = 'Sales' }
            )
        }

        Get-SetupSolutionMenuSummary -SolutionData $solutionData -SourceBranch develop |
            Should -Be 'develop: Core, Sales'
        Get-SetupSolutionMenuSummary -SolutionData ([pscustomobject]@{ Solutions = @() }) |
            Should -Be 'No solutions selected'
        Get-SetupSolutionMenuSummary -SolutionData $null | Should -Be 'Not configured'
    }
}

Describe 'Shared setup prompt and rendering contracts' {
    BeforeEach {
        Mock Initialize-SpectreConsole {}
        Mock Write-SetupConsoleBar { $false }
        # Both the wrappers and fake console hold process/session state between prompt calls.
        Clear-SetupWizardContext
        Clear-SetupPromptDocContext
        Remove-Variable -Name 'SetupHelpLauncher' -Scope Script -ErrorAction SilentlyContinue
        $script:SetupGuidancePanelVisible = $false
        Remove-Variable -Name 'SetupCurrentSectionMessage' -Scope Script -ErrorAction SilentlyContinue
        [Spectre.Console.AnsiConsole]::Answers.Clear()
        [Spectre.Console.AnsiConsole]::Keys.Clear()
        [Spectre.Console.AnsiConsole]::Output.Clear()
    }

    AfterEach {
        Clear-SetupWizardContext
        Clear-SetupPromptDocContext
        Remove-Variable -Name 'SetupHelpLauncher' -Scope Script -ErrorAction SilentlyContinue
        $script:SetupGuidancePanelVisible = $false
        Remove-Variable -Name 'SetupCurrentSectionMessage' -Scope Script -ErrorAction SilentlyContinue
        [Spectre.Console.AnsiConsole]::Answers.Clear()
        [Spectre.Console.AnsiConsole]::Keys.Clear()
        [Spectre.Console.AnsiConsole]::Output.Clear()
    }

    It 'shows one useful default guidance panel for every prompt type' {
        $script:guidancePanelCalls = @()
        Mock Write-SetupGuidance {
            $script:guidancePanelCalls += [pscustomobject]@{
                Header = $Header
                Lines = @($Lines)
            }
            $script:SetupGuidancePanelVisible = $true
        }

        [Spectre.Console.AnsiConsole]::Answers.Enqueue('One')
        Select-FromMenu -Title Choose -Items @('One', 'Two') | Should -Be 0
        [Spectre.Console.AnsiConsole]::Answers.Enqueue('typed value')
        Read-TextWithDefault -Prompt Value | Should -Be 'typed value'
        [Spectre.Console.AnsiConsole]::Answers.Enqueue('secret value')
        Read-SecretText -Prompt Secret | Should -Be 'secret value'
        Read-YesNo -Prompt Confirm | Should -BeTrue

        $script:guidancePanelCalls.Count | Should -Be 4
        $script:guidancePanelCalls[0].Lines -join ' ' | Should -Match 'arrow keys'
        $script:guidancePanelCalls[1].Lines -join ' ' | Should -Match 'requested value'
        $script:guidancePanelCalls[2].Lines -join ' ' | Should -Match 'masked while typing'
        $script:guidancePanelCalls[3].Lines -join ' ' | Should -Match 'Yes or No'
    }

    It 'shows the prompt title in the setup header when no section is active' {
        $script:setupDashboardMessages = @()
        Mock Write-SetupDashboard {
            $script:setupDashboardMessages += $Message
        }
        Mock Write-SetupGuidance {
            $script:SetupGuidancePanelVisible = $true
        }

        Write-SetupPromptFrame `
            -PromptText 'Select a deployment environment' `
            -PromptKind Menu `
            -PromptGuidanceLines @('Choose the environment to configure.')

        $script:setupDashboardMessages | Should -Be @('Select a deployment environment')
    }

    It 'shows the product mark, name and version when branding is requested' {
        $previousVersion = Get-Variable -Name 'ALM4DataverseVersion' -Scope Script -ErrorAction SilentlyContinue
        Mock Write-SetupConsoleBar { $false }
        try {
            $script:ALM4DataverseVersion = 'v1.2.3'
            Write-SetupDashboard -Message 'Choose setup type' -ShowProductBrand

            $renderedDashboard = [Spectre.Console.AnsiConsole]::Output -join "`n"
            $renderedDashboard | Should -Match '⢀⣠⣤⣶'
            $renderedDashboard | Should -Not -Match '∞'
            $renderedDashboard | Should -Not -Match '█'
            $renderedDashboard | Should -Match 'ALM4Dataverse'
            $renderedDashboard | Should -Match 'v1\.2\.3'
            $renderedDashboardLines = @($renderedDashboard -split "`n")
            $brandNameRows = @($renderedDashboardLines | Where-Object { $_ -match '\[bold\]ALM4Dataverse\[/\]' })
            $brandVersionRows = @($renderedDashboardLines | Where-Object { $_ -match '\[grey\]v1\.2\.3\[/\]' })
            $brandNameRows.Count | Should -Be 1
            $brandVersionRows.Count | Should -Be 1
            $brandNameRows[0] | Should -Match '\[bold green\].*⡜.*\[/\]    \[bold\]ALM4Dataverse\[/\]'
            $brandVersionRows[0] | Should -Match '\[bold green\].*⠐⣝.*\[/\]    \[grey\]v1\.2\.3\[/\]'
            $headerIndex = $renderedDashboard.IndexOf('ALM4Dataverse Setup - Choose setup type')
            $brandIconIndex = $renderedDashboard.IndexOf('⢀⣠⣤⣶')
            $brandNameRowIndex = [Array]::IndexOf($renderedDashboardLines, $brandNameRows[0])
            $brandVersionRowIndex = [Array]::IndexOf($renderedDashboardLines, $brandVersionRows[0])
            $brandNameIndex = $renderedDashboard.IndexOf('[bold]ALM4Dataverse[/]')
            $brandVersionIndex = $renderedDashboard.IndexOf('[grey]v1.2.3[/]')
            (
                $headerIndex -ge 0 -and
                $headerIndex -lt $brandIconIndex -and
                $brandIconIndex -lt $brandNameIndex -and
                $brandNameIndex -lt $brandVersionIndex -and
                ($brandVersionRowIndex - $brandNameRowIndex) -eq 2
            ) |
                Should -BeTrue
        }
        finally {
            if ($null -eq $previousVersion) {
                Remove-Variable -Name 'ALM4DataverseVersion' -Scope Script -ErrorAction SilentlyContinue
            }
            else {
                $script:ALM4DataverseVersion = $previousVersion.Value
            }
        }
    }

    It 'leaves a blank line below the product mark before prompt content' {
        Mock Show-SetupPromptGuidance {
            [Spectre.Console.AnsiConsole]::MarkupLine('PROMPT CONTENT')
        }

        Write-SetupPromptFrame `
            -PromptText 'Choose setup type' `
            -PromptKind Menu `
            -ShowProductBrand

        $renderedLines = @(([Spectre.Console.AnsiConsole]::Output -join "`n") -split "`n")
        $logoLineIndex = -1
        for ($lineIndex = 0; $lineIndex -lt $renderedLines.Count; $lineIndex++) {
            if ($renderedLines[$lineIndex] -match '⠉⠙⠛') {
                $logoLineIndex = $lineIndex
            }
        }
        $contentLineIndex = [Array]::IndexOf($renderedLines, 'PROMPT CONTENT')

        ($logoLineIndex -ge 0) | Should -BeTrue
        $renderedLines[$logoLineIndex + 1] | Should -Be ''
        ($contentLineIndex - $logoLineIndex) | Should -Be 2
    }

    It 'keeps the active section in the setup header when rendering a prompt' {
        $script:SetupCurrentSectionMessage = "BUILD validation for branch 'main'"
        $script:setupDashboardMessages = @()
        Mock Write-SetupDashboard {
            $script:setupDashboardMessages += $Message
        }
        Mock Write-SetupGuidance {
            $script:SetupGuidancePanelVisible = $true
        }

        Write-SetupPromptFrame -PromptText 'Enable BUILD validation?' -PromptKind YesNo

        $script:setupDashboardMessages | Should -Be @("BUILD validation for branch 'main'")
    }

    It 'keeps one existing guidance panel when a nested menu preserves content' {
        $script:guidancePanelCalls = @()
        Mock Write-SetupGuidance {
            $script:guidancePanelCalls += [pscustomobject]@{
                Header = $Header
                Lines = @($Lines)
            }
            $script:SetupGuidancePanelVisible = $true
        }

        Write-SetupPromptFrame -PromptText Parent -PromptKind Menu -PromptGuidanceLines @('Parent guidance')
        Write-SetupPromptFrame `
            -PromptText Nested `
            -PromptKind Menu `
            -PromptGuidanceLines @('Nested guidance') `
            -PreserveExistingContent

        $script:guidancePanelCalls.Count | Should -Be 1
        $script:guidancePanelCalls[0].Lines | Should -Contain 'Parent guidance'
        $script:guidancePanelCalls[0].Lines | Should -Not -Contain 'Nested guidance'
    }

    It 'delegates bottom-row lookup and falls back when the console bar is unavailable' {
        Show-SetupStatusBarAtBottom -PromptKind Menu -SearchEnabled
        Clear-SetupStatusBarAtBottom
        Should -Invoke Write-SetupConsoleBar -Times 2 -Exactly -ParameterFilter {
            $AtBottom -and $RestoreCursorPosition
        }
        ([Spectre.Console.AnsiConsole]::Output -join "`n") | Should -Match 'Type=filter'
        ([Spectre.Console.AnsiConsole]::Output -join "`n") | Should -Match 'Esc=cancel'

        Set-SetupWizardContext -Title Test -StepNames @('Step') -CurrentStepIndex 0
        Show-SetupStatusBarAtBottom -PromptKind Text
        ([Spectre.Console.AnsiConsole]::Output -join "`n") | Should -Match 'Esc=back'
    }

    It 'shows F1 help in prompt guidance and the status bar using the selected documentation ref' {
        Set-SetupWizardContext `
            -Title Setup `
            -StepNames @('Step') `
            -CurrentStepIndex 0 `
            -HelpDocRelativePath 'docs/setup/github-setup.md' `
            -HelpRef 'selected-ref'
        $script:capturedHelpOverlay = $null
        Mock Write-SetupPanelBottomBorderOverlay {
            $script:capturedHelpOverlay = $MarkupText
        }

        Write-SetupGuidance -Header Help -Lines @('Use F1 to open the setup guide.')
        Write-SetupPromptFrame -PromptText Help -PromptKind Text
        Show-SetupStatusBarAtBottom -PromptKind Text

        $expectedHelpUrl = 'https://github.com/ALM4Dataverse/ALM4Dataverse/tree/selected-ref/docs/setup/github-setup.md'
        Get-SetupActivePromptHelpUrl | Should -Be $expectedHelpUrl
        $script:capturedHelpOverlay | Should -Match 'F1 for help'
        $script:capturedHelpOverlay | Should -Not -Match '\[link='
        ([Spectre.Console.AnsiConsole]::Output -join "`n") | Should -Match 'F1=help'
    }

    It 'keeps section-level documentation available to prompts that preserve the guidance panel' {
        Write-Section `
            -Message 'Configure deployment environments' `
            -GuidanceLines @('Choose the deployment targets for this branch.') `
            -GuidanceDocRelativePath 'docs/setup/github-setup.md' `
            -GuidanceRef 'selected-ref'
        $expectedHelpUrl = 'https://github.com/ALM4Dataverse/ALM4Dataverse/tree/selected-ref/docs/setup/github-setup.md'

        Get-SetupActivePromptHelpUrl | Should -Be $expectedHelpUrl
        Write-SetupPromptFrame `
            -PromptText 'Target deployment environments' `
            -PromptKind Menu `
            -PreserveExistingContent
        Show-SetupStatusBarAtBottom -PromptKind Menu

        ([Spectre.Console.AnsiConsole]::Output -join "`n") | Should -Match 'F1=help'
    }

    It 'resumes synchronous and asynchronous prompts after F1 opens the active help URL' {
        Set-SetupWizardContext `
            -Title Setup `
            -StepNames @('Step') `
            -CurrentStepIndex 0 `
            -HelpDocRelativePath 'docs/config/alm-config.md' `
            -HelpRef 'selected-ref'
        Write-SetupPromptFrame -PromptText Help -PromptKind Text
        $expectedHelpUrl = 'https://github.com/ALM4Dataverse/ALM4Dataverse/tree/selected-ref/docs/config/alm-config.md'
        $script:openedHelpUrls = [System.Collections.Generic.List[string]]::new()
        $script:SetupHelpLauncher = [System.Action[string]]{
            param([string]$url)
            [void]$script:openedHelpUrls.Add($url)
        }
        $helpKey = [System.ConsoleKeyInfo]::new([char]0, [System.ConsoleKey]::F1, $false, $false, $false)
        $enterKey = [System.ConsoleKeyInfo]::new([char]13, [System.ConsoleKey]::Enter, $false, $false, $false)

        [Spectre.Console.AnsiConsole]::Keys.Enqueue($helpKey)
        [Spectre.Console.AnsiConsole]::Keys.Enqueue($enterKey)
        $syncKey = Invoke-SetupPromptWithEscapeNavigation -ScriptBlock {
            [Spectre.Console.AnsiConsole]::Console.Input.ReadKey($true)
        }
        $syncKey.Key | Should -Be ([System.ConsoleKey]::Enter)

        [Spectre.Console.AnsiConsole]::Keys.Enqueue($helpKey)
        [Spectre.Console.AnsiConsole]::Keys.Enqueue($enterKey)
        $asyncKey = Invoke-SetupPromptWithEscapeNavigation -ScriptBlock {
            [Spectre.Console.AnsiConsole]::Console.Input.ReadKeyAsync(
                $true,
                [System.Threading.CancellationToken]::None
            ).GetAwaiter().GetResult()
        }
        $asyncKey.Key | Should -Be ([System.ConsoleKey]::Enter)
        @($script:openedHelpUrls) | Should -Be @($expectedHelpUrl, $expectedHelpUrl)
        [Spectre.Console.AnsiConsole]::Keys.Count | Should -Be 0
    }

    It 'opens F1 help while a menu is visible and resumes selection' {
        $script:openedHelpUrls = [System.Collections.Generic.List[string]]::new()
        $script:SetupHelpLauncher = [System.Action[string]]{
            param([string]$url)
            [void]$script:openedHelpUrls.Add($url)
        }
        $helpKey = [System.ConsoleKeyInfo]::new([char]0, [System.ConsoleKey]::F1, $false, $false, $false)
        $enterKey = [System.ConsoleKeyInfo]::new([char]13, [System.ConsoleKey]::Enter, $false, $false, $false)
        [Spectre.Console.AnsiConsole]::Keys.Enqueue($helpKey)
        [Spectre.Console.AnsiConsole]::Keys.Enqueue($enterKey)
        [Spectre.Console.AnsiConsole]::Answers.Enqueue('One')

        Select-FromMenu `
            -Title Choose `
            -Items @('One', 'Two') `
            -PromptGuidanceLines @('Choose an option.') `
            -PromptGuidanceDocRelativePath 'docs/setup/github-setup.md' `
            -PromptGuidanceRef 'selected-ref' | Should -Be 0

        $script:openedHelpUrls | Should -HaveCount 1
        $script:openedHelpUrls[0] |
            Should -Be 'https://github.com/ALM4Dataverse/ALM4Dataverse/tree/selected-ref/docs/setup/github-setup.md'
        [Spectre.Console.AnsiConsole]::Keys.Count | Should -Be 0
    }

    It 'uses step-specific help pages and the wizard-selected ref' {
        $script:stepHelpContext = $null
        $script:helpWizardMenuCalls = 0
        Mock Select-FromMenu {
            $script:helpWizardMenuCalls++
            if ($script:helpWizardMenuCalls -eq 1) {
                return 0
            }
            return $null
        }
        $steps = @(
            [pscustomobject]@{
                Name = 'Edit configuration'
                HelpDocRelativePath = 'docs/config/alm-config.md'
                Action = {
                    $script:stepHelpContext = Get-SetupPromptHelpContext
                }
            }
        )

        {
            Invoke-SetupWizard `
                -Title Setup `
                -Steps $steps `
                -ApplyAction {} `
                -HelpDocRelativePath 'docs/setup/github-setup.md' `
                -HelpRef 'selected-ref'
        } | Should -Throw '*Setup cancelled before changes were applied.*'

        $script:stepHelpContext.DocRelativePath | Should -Be 'docs/config/alm-config.md'
        $script:stepHelpContext.Ref | Should -Be 'selected-ref'
    }

    It 'maps markup-safe menu values and supports single-choice cancellation' {
        [Spectre.Console.AnsiConsole]::Answers.Enqueue('[[One]]')
        Select-FromMenu -Title Test -Items @('[One]', 'Two') | Should -Be 0
        [Spectre.Console.AnsiConsole]::Answers.Enqueue('< Cancel setup')
        Select-FromMenu -Title Test -Items @('One') | Should -BeNullOrEmpty
        Select-FromMenu -Title Test -Items @() | Should -BeNullOrEmpty
    }

    It 'groups action choices separately, styles them, and preserves their item indexes' {
        $script:actionPromptChoices = @()
        Mock Show-SelectionPromptWithInterruptHandling {
            $script:actionPromptChoices = @($Prompt.Choices)
            $script:actionPromptChoices | Where-Object { $_ -like '*Preview changes*' } | Select-Object -First 1
        }

        Select-FromMenu `
            -Title Test `
            -Items @('Configure branches, dev and deployment envs', 'Preview changes', 'Apply changes - Not ready', 'Exit without applying changes') `
            -ActionItems @('Preview changes', 'Apply changes - Not ready', 'Exit without applying changes') `
            -ActionSectionTitle '---' |
            Should -Be 1

        $script:actionPromptChoices[0] | Should -Be '[bold]Setup steps[/]'
        $script:actionPromptChoices[1] | Should -Be 'Configure branches, dev and deployment envs'
        $script:actionPromptChoices[2] | Should -Be '[bold deepskyblue1]---[/]'
        $script:actionPromptChoices[3] | Should -Be '[bold deepskyblue1]Preview changes[/]'
        $script:actionPromptChoices[4] | Should -Be '[bold deepskyblue1]Apply changes - Not ready[/]'
        $script:actionPromptChoices[5] | Should -Be '[bold deepskyblue1]Exit without applying changes[/]'
    }

    It 'supports searchable menus and requests back navigation from later wizard steps' {
        $items = @(1..10 | ForEach-Object { "Item $_" })
        [Spectre.Console.AnsiConsole]::Answers.Enqueue('Item 10')
        Select-FromMenu -Title Test -Items $items | Should -Be 9
        Set-SetupWizardContext -Title Test -StepNames @('First', 'Second') -CurrentStepIndex 1
        [Spectre.Console.AnsiConsole]::Answers.Enqueue('< Back to previous step')
        { Select-FromMenu -Title Test -Items @('One', 'Two') } | Should -Throw '*__ALM4DATAVERSE_WIZARD_BACK__*'
    }

    It 'routes Escape from menus and every prompt type to the setup menu' {
        $originalConsole = [Spectre.Console.AnsiConsole]::Console
        Set-SetupWizardContext -Title Test -StepNames @('First') -CurrentStepIndex 0
        $escapeKey = [System.ConsoleKeyInfo]::new([char]0, [System.ConsoleKey]::Escape, $false, $false, $false)

        [Spectre.Console.AnsiConsole]::Keys.Enqueue($escapeKey)
        { Select-FromMenu -Title Test -Items @('One', 'Two') } | Should -Throw '*__ALM4DATAVERSE_WIZARD_BACK__*'

        [Spectre.Console.AnsiConsole]::Keys.Enqueue($escapeKey)
        { Read-TextWithDefault -Prompt Text } | Should -Throw '*__ALM4DATAVERSE_WIZARD_BACK__*'

        [Spectre.Console.AnsiConsole]::Keys.Enqueue($escapeKey)
        { Read-TextWithDefault -Prompt Text -DefaultValue Default } | Should -Throw '*__ALM4DATAVERSE_WIZARD_BACK__*'

        [Spectre.Console.AnsiConsole]::Keys.Enqueue($escapeKey)
        { Read-SecretText -Prompt Secret } | Should -Throw '*__ALM4DATAVERSE_WIZARD_BACK__*'

        [Spectre.Console.AnsiConsole]::Keys.Enqueue($escapeKey)
        { Read-YesNo -Prompt Confirm } | Should -Throw '*__ALM4DATAVERSE_WIZARD_BACK__*'

        [object]::ReferenceEquals([Spectre.Console.AnsiConsole]::Console, $originalConsole) | Should -BeTrue
        [Spectre.Console.AnsiConsole]::Keys.Count | Should -Be 0
    }

    It 'cancels a prompt when Escape is pressed before the navigation menu exists' {
        $escapeKey = [System.ConsoleKeyInfo]::new([char]0, [System.ConsoleKey]::Escape, $false, $false, $false)
        [Spectre.Console.AnsiConsole]::Keys.Enqueue($escapeKey)

        { Read-TextWithDefault -Prompt Text } | Should -Throw '*Setup cancelled by user.*'
    }

    It 'returns to the wizard menu when Escape is pressed inside a step prompt' {
        $script:escapeWizardSelectionCalls = 0
        $script:escapeKey = [System.ConsoleKeyInfo]::new([char]0, [System.ConsoleKey]::Escape, $false, $false, $false)
        Mock Select-FromMenu {
            $script:escapeWizardSelectionCalls++
            if ($script:escapeWizardSelectionCalls -eq 1) {
                return 0
            }
            return $null
        }
        $steps = @(
            [pscustomobject]@{
                Name = 'First'
                Action = {
                    [Spectre.Console.AnsiConsole]::Keys.Enqueue($script:escapeKey)
                    Read-TextWithDefault -Prompt Value | Out-Null
                }
            }
        )

        { Invoke-SetupWizard -Title Setup -Steps $steps -ApplyAction {} } |
            Should -Throw '*Setup cancelled before changes were applied.*'

        $script:escapeWizardSelectionCalls | Should -Be 2
        [Spectre.Console.AnsiConsole]::Keys.Count | Should -Be 0
    }

    It 'cancels setup when Escape has no parent menu' {
        $escapeKey = [System.ConsoleKeyInfo]::new([char]0, [System.ConsoleKey]::Escape, $false, $false, $false)
        [Spectre.Console.AnsiConsole]::Keys.Enqueue($escapeKey)
        $steps = @(
            [pscustomobject]@{ Name = 'First'; Action = {} }
        )

        { Invoke-SetupWizard -Title Setup -Steps $steps -ApplyAction {} } |
            Should -Throw '*Setup cancelled before changes were applied.*'
    }

    It 'cancels a linear wizard at its first step when there is no previous menu' {
        $escapeKey = [System.ConsoleKeyInfo]::new([char]0, [System.ConsoleKey]::Escape, $false, $false, $false)
        $steps = @(
            [pscustomobject]@{
                Name = 'First'
                Action = {
                    [Spectre.Console.AnsiConsole]::Keys.Enqueue($escapeKey)
                    Read-TextWithDefault -Prompt Value | Out-Null
                }
            }
        )

        { Invoke-SetupWizard -Title Setup -Steps $steps } |
            Should -Throw '*Setup cancelled by user.*'
    }

    It 'preserves secret whitespace, trims text, honors defaults and allows explicitly empty input' {
        [Spectre.Console.AnsiConsole]::Answers.Enqueue(' fake-secret ')
        Read-SecretText -Prompt Secret | Should -Be ' fake-secret '
        [Spectre.Console.AnsiConsole]::Answers.Enqueue('  text  ')
        Read-TextWithDefault -Prompt Text | Should -Be text
        Read-TextWithDefault -Prompt Text -DefaultValue Default | Should -Be Default
        [Spectre.Console.AnsiConsole]::Answers.Enqueue('')
        Read-SecretText -Prompt Secret -AllowEmpty | Should -Be ''
        [Spectre.Console.AnsiConsole]::Answers.Enqueue('')
        Read-TextWithDefault -Prompt Text -AllowEmpty | Should -Be ''
        Read-YesNo -Prompt Confirm | Should -BeTrue
        Read-YesNo -Prompt Confirm -DefaultNo | Should -BeFalse
    }

    It 'renders escaped metrics, documentation links and completion summary values' {
        $columns = New-SpectreMetricColumn -Cards @(@{ Label = '[Count]'; Value = '3'; Detail = 'detail'; AccentColor = 'green' }, [pscustomobject]@{ Label = 'Other'; Value = '4'; Detail = ''; AccentColor = 'yellow' })
        $columns.Items.Count | Should -Be 2
        $columns.Items[0].Content.ToString() | Should -Match '\[\[Count\]\]'
        Write-SetupGuidance -Header Guidance -Lines @('Read [this]', '') -DocRelativePath docs/config/alm-config.md -Ref main
        (Get-SetupPromptDocContext).Ref | Should -Be main
        Show-SetupCompletionScreen -Heading Done -AccessLabel Repository -AccessUrl https://example.com -SummaryValues @{ Repository = 'repo' } -NextStepLinks @('https://one.example.com', @{ Url = 'https://two.example.com'; Description = 'Two' }, [pscustomobject]@{ Url = 'https://three.example.com'; Text = 'Three' })
        ([Spectre.Console.AnsiConsole]::Output | Out-String) | Should -Match 'https://three.example.com'
    }

    It 'retries a failed operation once and preserves its successful result' {
        Mock Select-FromMenu { 0 }
        $state = @{ Attempts = 0 }
        $result = Invoke-WithErrorHandling -OperationName Test -ScriptBlock {
            $state.Attempts++
            if ($state.Attempts -eq 1) { throw 'Temporary failure' }
            42
        }
        $result | Should -Be 42
        $state.Attempts | Should -Be 2
    }

    It 'summarizes pending configuration, authentication mix and distinct service accounts' -ForEach @(
        @{ AuthTypes = @('WIF', 'Secret'); ExpectedMix = 'Mixed' }
        @{ AuthTypes = @('WIF'); ExpectedMix = 'WIF' }
        @{ AuthTypes = @('Secret'); ExpectedMix = 'Secret' }
        @{ AuthTypes = @(); ExpectedMix = 'Unassigned' }
    ) {
        $environments = @($AuthTypes | ForEach-Object {
            [pscustomobject]@{ Credentials = [pscustomobject]@{ AuthType = $_ }; ServiceAccountUPN = 'service@example.com'; ConfigurationPending = $false }
        })
        $environments += [pscustomobject]@{ Credentials = $null; ServiceAccountUPN = ''; ConfigurationPending = $true }
        Mock Show-SpectreMetricCard {}
        Show-EnvironmentConfigurationOverview -EnvironmentConfigurations $environments
        Should -Invoke Show-SpectreMetricCard -Times 1 -Exactly -ParameterFilter {
            ($Cards | Where-Object Label -eq 'Auth mode').Value -eq $ExpectedMix -and
            ($Cards | Where-Object Label -eq 'Pending setup').Value -eq '1'
        }
    }

    It 'selects only a distinct deployment environment as BUILD baseline' {
        $build = [pscustomobject]@{ ShortName = 'Build'; FriendlyName = 'Validation'; Url = 'https://build.example.com' }
        $target = [pscustomobject]@{ ShortName = 'TEST'; FriendlyName = 'Test'; Url = 'https://test.example.com' }
        Mock Select-FromMenu { 1 }
        Select-BuildValidationBaselineEnvironment -DeploymentEnvironments @($build, $target, $target) -ExcludedEnvironmentName Build -ExcludedEnvironmentUrl $build.Url | Should -Be '@TEST'
        Select-BuildValidationBaselineEnvironment -DeploymentEnvironments @() | Should -Be ''
        Should -Invoke Select-FromMenu -Times 1 -Exactly -ParameterFilter { $Items.Count -eq 2 }
    }
}

Describe 'Setup repository change review' {
    BeforeEach {
        Mock Initialize-SpectreConsole {}
        Mock Write-SetupConsoleBar { $false }
        Mock Show-SetupFileChangeSummary {}
        [Spectre.Console.AnsiConsole]::Output.Clear()
    }

    AfterEach {
        [Spectre.Console.AnsiConsole]::Output.Clear()
    }

    It 'classifies added, modified, and deleted files across the requested roots' {
        $repositoryRoot = Join-Path $TestDrive 'repository'
        $previewRoot = Join-Path $TestDrive 'preview'
        foreach ($root in @($repositoryRoot, $previewRoot)) {
            New-Item -ItemType Directory -Path (Join-Path $root '.github/workflows') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $root 'pipelines') -Force | Out-Null
        }

        [System.IO.File]::WriteAllText((Join-Path $repositoryRoot '.github/workflows/BUILD.yml'), "old build`n")
        [System.IO.File]::WriteAllText((Join-Path $previewRoot '.github/workflows/BUILD.yml'), "new build`n")
        [System.IO.File]::WriteAllText((Join-Path $repositoryRoot '.github/workflows/unchanged.yml'), "same`n")
        [System.IO.File]::WriteAllText((Join-Path $previewRoot '.github/workflows/unchanged.yml'), "same`n")
        [System.IO.File]::WriteAllText((Join-Path $repositoryRoot 'pipelines/DEPLOY-main.yml'), "removed`n")
        [System.IO.File]::WriteAllText((Join-Path $previewRoot 'pipelines/EXPORT.yml'), "added`n")
        [System.IO.File]::WriteAllText((Join-Path $repositoryRoot 'alm-config.psd1'), "old config`n")
        [System.IO.File]::WriteAllText((Join-Path $previewRoot 'alm-config.psd1'), "new config`n")
        [System.IO.File]::WriteAllText((Join-Path $repositoryRoot 'outside-scope.txt'), "original`n")
        [System.IO.File]::WriteAllText((Join-Path $previewRoot 'outside-scope.txt'), "ignored`n")

        $changes = @(Get-SetupRepositoryFileChange `
                -RepositoryRoot $repositoryRoot `
                -PreviewRoot $previewRoot `
                -RelativePaths @('.github', 'pipelines', 'alm-config.psd1'))

        $changes.Count | Should -Be 4
        ($changes | Where-Object Path -eq '.github/workflows/BUILD.yml').Status | Should -Be Modified
        ($changes | Where-Object Path -eq 'alm-config.psd1').Status | Should -Be Modified
        ($changes | Where-Object Path -eq 'pipelines/DEPLOY-main.yml').Status | Should -Be Deleted
        ($changes | Where-Object Path -eq 'pipelines/EXPORT.yml').Status | Should -Be Added
        $changes.Path | Should -Not -Contain 'outside-scope.txt'
        $changes.Path | Should -Not -Contain '.github/workflows/unchanged.yml'
    }

    It 'aligns shared context and pairs changed lines for a side-by-side diff' {
        $rows = @(Get-SetupSideBySideDiffRow `
                -BeforeContent "first`nold line`nlast" `
                -AfterContent "first`nnew line`nextra line`nlast")

        $rows.Count | Should -Be 4
        $rows[0].Type | Should -Be Context
        $rows[0].LeftText | Should -Be first
        $rows[1].Type | Should -Be Modified
        $rows[1].LeftText | Should -Be 'old line'
        $rows[1].RightText | Should -Be 'new line'
        $rows[2].Type | Should -Be Added
        $rows[2].RightText | Should -Be 'extra line'
        $rows[3].Type | Should -Be Context
        $rows[3].LeftText | Should -Be last
    }

    It 'wraps text to the requested column width and clamps viewer scrolling' {
        Get-SetupDiffTextSegment -Text 'abcdefghij' -Width 4 | Should -Be @('abcd', 'efgh', 'ij')
        Get-SetupDiffNextStartIndex -CurrentStartIndex 8 -PageSize 5 -RowCount 20 -Key PageDown | Should -Be 13
        Get-SetupDiffNextStartIndex -CurrentStartIndex 8 -PageSize 5 -RowCount 20 -Key PageUp | Should -Be 3
        Get-SetupDiffNextStartIndex -CurrentStartIndex 8 -PageSize 5 -RowCount 20 -Key End | Should -Be 15
        Get-SetupDiffNextStartIndex -CurrentStartIndex 8 -PageSize 5 -RowCount 20 -Key DownArrow | Should -Be 9
        Get-SetupDiffNextStartIndex -CurrentStartIndex 0 -PageSize 5 -RowCount 20 -Key UpArrow | Should -Be 0
    }

    It 'renders deleted and added lines with distinct colors' {
        Show-SetupSideBySideDiff -Title 'Modified: pipelines/BUILD.yml' -FileChanges @([pscustomobject]@{
                Path          = 'pipelines/BUILD.yml'
                Status        = 'Modified'
                BeforeContent = "old line`n"
                AfterContent  = "new line`n"
            }) -NoPaging

        $renderedOutput = [Spectre.Console.AnsiConsole]::Output -join "`n"
        $renderedOutput | Should -Match '\[red3_1\]'
        $renderedOutput | Should -Match '\[green3_1\]'
        $renderedOutput | Should -Match 'BEFORE'
        $renderedOutput | Should -Match 'AFTER'
        $renderedOutput | Should -Match 'ALM4Dataverse Setup - Modified: pipelines/BUILD.yml'
    }

    It 'rejects attempts to render multiple files in a single diff view' {
        $changes = @(
            [pscustomobject]@{ Path = 'one.txt'; Status = 'Modified'; BeforeContent = 'old'; AfterContent = 'new' }
            [pscustomobject]@{ Path = 'two.txt'; Status = 'Added'; BeforeContent = $null; AfterContent = 'new' }
        )

        { Show-SetupSideBySideDiff -FileChanges $changes } | Should -Throw '*one file at a time*'
    }

    It 'offers a separate config diff and selects one status-labeled file at a time' {
        Mock Show-SetupSideBySideDiff {}
        Mock Show-SetupResourceChangeSummary {
            $script:reviewedResourceChanges = @($ResourceChanges)
            $script:reviewedResourceChangeNote = $Note
        }
        $changes = @(
            [pscustomobject]@{ Path = 'alm-config.psd1'; Status = 'Modified'; BeforeContent = 'old'; AfterContent = 'new' }
            [pscustomobject]@{ Path = 'pipelines/BUILD.yml'; Status = 'Added'; BeforeContent = $null; AfterContent = 'pipeline' }
        )
        $resourceChanges = @([pscustomobject]@{
                Action = 'Ensure'
                Resource = 'GitHub environment'
                Target = 'owner/repo/PROD'
                Details = 'Set variables and approvals; secret values are hidden.'
            })
        $script:reviewSelections = [System.Collections.Generic.Queue[int]]::new()
        $script:reviewSelections.Enqueue(0)
        $script:reviewSelections.Enqueue(2)
        Mock Select-FromMenu {
            $script:lastReviewMenuItems = @($Items)
            $script:reviewSelections.Dequeue()
        }

        Show-SetupChangeReview `
            -FileChanges $changes `
            -ResourceChanges $resourceChanges `
            -ResourceChangeNote 'Prerequisite resources are excluded.' `
            -SummaryAction {}

        $script:lastReviewMenuItems | Should -Contain 'Added: pipelines/BUILD.yml'
        $script:reviewedResourceChanges[0].Resource | Should -Be 'GitHub environment'
        $script:reviewedResourceChangeNote | Should -Be 'Prerequisite resources are excluded.'
        Should -Invoke Show-SetupSideBySideDiff -Times 1 -Exactly -ParameterFilter {
            $Title -eq 'alm-config.psd1 diff' -and
            $FileChanges.Count -eq 1 -and
            $FileChanges[0].Path -eq 'alm-config.psd1'
        }

        $script:previewSummaryCalls = 0
        $script:reviewSelections.Enqueue(1)
        $script:reviewSelections.Enqueue(2)
        Show-SetupChangeReview -FileChanges $changes -SummaryAction { $script:previewSummaryCalls++ } -PreviewOnly
        $script:previewSummaryCalls | Should -Be 2
        Should -Invoke Show-SetupSideBySideDiff -Times 1 -Exactly -ParameterFilter {
            $Title -eq 'Added: pipelines/BUILD.yml' -and
            $FileChanges.Count -eq 1 -and
            $FileChanges[0].Path -eq 'pipelines/BUILD.yml' -and
            $NoPaging
        }
    }

    It 'runs the summary action in caller scope so setup helpers remain available' {
        Mock Write-Section {
            $script:summaryReviewHeading = $Message
        }
        Mock Show-SetupResourceChangeSummary {}
        Mock Show-SetupFileChangeSummary {}
        Mock Select-FromMenu { 1 }

        & {
            $reviewHeading = 'Review setup changes'
            $summaryAction = {
                Write-Section -Message $reviewHeading
            }
            Show-SetupChangeReview -SummaryAction $summaryAction
        }

        $script:summaryReviewHeading | Should -Be 'Review setup changes'
        Should -Invoke Write-Section -Times 1 -Exactly
    }
}

Describe 'Setup configuration and validation helpers' {
    It 'imports committed config text and resolves branch settings case-insensitively' {
        $configContent = "@{ branches = @{ main = @{ developmentEnvironment = 'Dev-main' } } }"
        $config = ConvertFrom-AlmConfigContentForSetup -ConfigContent $configContent
        $branch = Get-AlmSetupBranchConfiguration -Config $config -BranchName 'MAIN'

        $branch.developmentEnvironment | Should -Be 'Dev-main'
        (Get-AlmSetupBranchConfiguration -Config $config -BranchName 'feature').Count | Should -Be 0
        { ConvertFrom-AlmConfigContentForSetup -ConfigContent '@{ branches = ' } |
            Should -Throw '*Could not import committed alm-config.psd1 content*'
        { Get-AlmSetupBranchConfiguration -Config @{ branches = @('main') } -BranchName main } |
            Should -Throw '*branches setting in alm-config.psd1 must be a hashtable*'
    }

    It 'requires committed provider, source, and branch metadata before applying config' {
        $config = @{
            provider = 'GitHub'
            repository = 'owner/shared'
            ref = 'stable'
            branches = @{ main = @{} }
        }
        $validated = Assert-AlmSetupConfigurationForApply -Configuration $config -Provider GitHub
        $validated.provider | Should -Be GitHub

        { Assert-AlmSetupConfigurationForApply -Configuration $config -Provider azDO } |
            Should -Throw "*provider = 'azDO'*"
        { Assert-AlmSetupConfigurationForApply -Configuration @{ provider = 'GitHub'; ref = 'stable'; branches = @{ main = @{} } } -Provider GitHub } |
            Should -Throw "*non-empty 'repository' string*"
        { Assert-AlmSetupConfigurationForApply -Configuration @{ provider = 'GitHub'; repository = 'owner/shared'; branches = @{ main = @{} } } -Provider GitHub } |
            Should -Throw "*non-empty 'ref' string*"
        { Assert-AlmSetupConfigurationForApply -Configuration @{ provider = 'GitHub'; repository = 'owner/shared'; ref = 'stable'; branches = @{} } -Provider GitHub } |
            Should -Throw '*non-empty branches map*'
        { Assert-AlmSetupConfigurationForApply -Configuration @{ provider = 'GitHub'; repository = 'owner/shared'; ref = 'stable'; branches = @{ main = 'not-a-hashtable' } } -Provider GitHub } |
            Should -Throw "*Configuration for branch 'main'*"
    }

    It 'builds provider-neutral setup settings with explicit per-branch validation state' {
        $branchStates = @(
            [pscustomobject]@{
                BranchName = 'main'
                DevEnvironmentConfiguration = [pscustomobject]@{ ShortName = 'Dev-main' }
                DeploymentEnvironments = @([pscustomobject]@{ ShortName = 'TEST' })
                BuildValidationEnabled = $true
                BuildValidationEnvironmentConfiguration = [pscustomobject]@{ ShortName = 'Build-main' }
                BuildValidationBaselineRelease = '@TEST'
            }
            [pscustomobject]@{
                BranchName = 'feature'
                DevEnvironmentConfiguration = $null
                DeploymentEnvironments = @()
                BuildValidationEnabled = $false
                BuildValidationEnvironmentConfiguration = $null
                BuildValidationBaselineRelease = ''
            }
        )

        $settings = Get-AlmSetupConfiguration -Provider GitHub -Repository owner/shared -Ref stable `
            -BranchStates $branchStates -ProviderOptions @{ GitHubUseEnvironments = $true }

        $settings.provider | Should -Be GitHub
        $settings.repository | Should -Be owner/shared
        $settings.ref | Should -Be stable
        $settings.GitHubUseEnvironments | Should -BeTrue
        $settings.branches.main.developmentEnvironment | Should -Be Dev-main
        $settings.branches.main.deploymentEnvironments | Should -Be @('TEST')
        $settings.branches.main.buildValidation.environmentName | Should -Be Build-main
        $settings.branches.main.buildValidation.baselineRelease | Should -Be '@TEST'
        $settings.branches.feature.buildValidation.environmentName | Should -Be ''
        $settings.branches.feature.buildValidation.baselineRelease | Should -Be ''
    }

    It 'updates provider and branch setup settings while preserving unrelated configuration' {
        $configPath = Join-Path $TestDrive 'setup-settings.psd1'
        Set-Content -LiteralPath $configPath -Value @'
@{
    # Keep this comment and the application-specific entries.
    provider = 'GitHub'
    repository = 'old/repository'
    customSetting = 'keep'
    branches = @{
        main = @{
            deploymentEnvironments = @('OLD')
        }
    }
}
'@
        $settings = [ordered]@{
            provider = 'azDO'
            repository = 'shared'
            ref = 'stable'
            azDOUseAlm4DataverseExtension = $true
            branches = [ordered]@{
                main = [ordered]@{
                    developmentEnvironment = 'Dev-main'
                    deploymentEnvironments = @('TEST', 'PROD')
                    buildValidation = [ordered]@{
                        environmentName = 'Build-main'
                        baselineRelease = '@TEST'
                    }
                }
            }
        }

        Set-AlmConfigSetupSettingsInFile -ConfigPath $configPath -Settings $settings | Should -BeTrue

        $config = Get-AlmConfigForSetup -ConfigPath $configPath
        $config.provider | Should -Be azDO
        $config.repository | Should -Be shared
        $config.ref | Should -Be stable
        $config.azDOUseAlm4DataverseExtension | Should -BeTrue
        $config.branches.main.developmentEnvironment | Should -Be Dev-main
        $config.branches.main.deploymentEnvironments | Should -Be @('TEST', 'PROD')
        $config.branches.main.buildValidation.environmentName | Should -Be Build-main
        $config.branches.main.buildValidation.baselineRelease | Should -Be '@TEST'
        $config.customSetting | Should -Be keep
        (Get-Content -LiteralPath $configPath -Raw) | Should -Match 'Keep this comment'
        Set-AlmConfigSetupSettingsInFile -ConfigPath $configPath -Settings $settings | Should -BeFalse
    }

    It 'rejects unsupported setup setting values and returns empty state for a missing config' {
        $missingConfigPath = Join-Path $TestDrive 'missing-setup-config.psd1'
        (Get-AlmConfigForSetup -ConfigPath $missingConfigPath).Count | Should -Be 0
        $configPath = Join-Path $TestDrive 'unsupported-setup-value.psd1'
        Set-Content -LiteralPath $configPath -Value "@{ provider = 'GitHub' }"
        { Set-AlmConfigSetupSettingsInFile -ConfigPath $configPath -Settings @{ provider = { 'GitHub' } } } |
            Should -Throw '*Unsupported ALM configuration data value type*'
    }

    It 'declares the emitted branch-mapping element type for both strategies' -ForEach @(
        @{ Strategy = 'Simple'; ExpectedCount = 1 }
        @{ Strategy = 'GitflowLike'; ExpectedCount = 3 }
    ) {
        $environment = [pscustomobject]@{ ShortName = 'prod'; FriendlyName = 'Production' }
        $mappings = @(Get-DefaultBranchEnvironmentMappingsFromStrategy -Strategy $Strategy -EnvironmentConfigurations @($environment))
        $mappings.Count | Should -Be $ExpectedCount
        $declaredTypes = @((Get-Command Get-DefaultBranchEnvironmentMappingsFromStrategy).OutputType.Type)
        $declaredTypes | Should -Contain ([object[]])
        foreach ($mapping in $mappings) {
            $mapping | Should -BeOfType ([pscustomobject])
            @($declaredTypes | Where-Object { $_.IsInstanceOfType($mapping) }).Count | Should -BeGreaterThan 0
        }
    }

    It 'reads optional hashtable and object values under strict mode without losing false or zero' {
        Set-StrictMode -Version Latest
        Get-OptionalObjectPropertyValue -InputObject $null -PropertyName key | Should -BeNullOrEmpty
        Get-OptionalObjectPropertyValue -InputObject @{} -PropertyName key | Should -BeNullOrEmpty
        Get-OptionalObjectPropertyValue -InputObject ([pscustomobject]@{ other = 1 }) -PropertyName key | Should -BeNullOrEmpty
        Get-OptionalObjectPropertyValue -InputObject @{ key = $false } -PropertyName key | Should -BeFalse
        Get-OptionalObjectPropertyValue -InputObject ([pscustomobject]@{ key = 0 }) -PropertyName key | Should -Be 0
        ConvertTo-SpectreMarkupLiteral '[value]' | Should -Be '[[value]]'
        ConvertTo-SpectreMarkupLiteral $null | Should -Be ''
    }

    It 'normalizes branch names, URLs, credential names, tenant identifiers, and docs links' {
        ConvertFrom-GitRefToBranchName 'refs/heads/topic' | Should -Be topic
        ConvertFrom-GitRefToBranchName main | Should -Be main
        ConvertTo-UrlSafeName ' /test feature// ' | Should -Be test-feature
        ConvertTo-NormalizedEnvironmentUrl ' https://example.com/path/?query=1 ' | Should -Be 'https://example.com'
        ConvertTo-NormalizedEnvironmentUrl 'invalid/' | Should -Be invalid
        ConvertTo-NormalizedEnvironmentUrl 'ftp://example.com/' | Should -Be 'ftp://example.com'
        ConvertTo-NormalizedEnvironmentUrl '' | Should -BeNullOrEmpty
        Test-IsValidTenantIdentifier 'example.onmicrosoft.com' | Should -BeTrue
        Test-IsValidTenantIdentifier '00000000-0000-0000-0000-000000000001' | Should -BeTrue
        Test-IsValidTenantIdentifier ' ' | Should -BeFalse
        { Assert-ValidTenantIdentifier -TenantIdentifier invalid -Source TestTenant } | Should -Throw '*TestTenant*is invalid*'
        Assert-ValidTenantIdentifier -TenantIdentifier example.com
        Get-Alm4DataverseDocUrl -RelativePath '/docs\config' -Ref main | Should -Be 'https://github.com/ALM4Dataverse/ALM4Dataverse/tree/main/docs/config'
        Get-Alm4DataverseDocumentationRef | Should -Be stable
        Get-DefaultSetupBranchName -BaseBranch '///' -Context '///' | Should -Match '^alm4dataverse/setup-main-\d{14}$'
    }

    It 'summarizes credentials without exposing any secret fields' {
        Get-CredentialSummaryText $null | Should -Be ''
        Get-CredentialSummaryText ([pscustomobject]@{ Name = 'Connection'; IsExistingServiceConnection = $true; Secret = 'fake-secret' }) | Should -Be 'Existing service connection - Connection'
        Get-CredentialSummaryText ([pscustomobject]@{ IsExistingServiceConnection = $true }) | Should -Be 'Existing service connection'
        Get-CredentialSummaryText ([pscustomobject]@{ ApplicationId = 'app-id'; AuthType = 'Federated'; Secret = 'fake-secret' }) | Should -Be 'Federated - app-id'
        Get-CredentialSummaryText ([pscustomobject]@{}) | Should -Be Credential
    }

    It 'creates or replaces solution selections while preserving unrelated configuration' -ForEach @(
        @{ Initial = '@{ assets = @("data") }' }
        @{ Initial = '@{ assets = @("data"); solutions = @(@{ name = "Old" }) }' }
    ) {
        Set-StrictMode -Version Latest
        $configPath = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.psd1')
        Set-Content $configPath -Value $Initial
        $solutions = @(@{ name = "O'Brien"; deployUnmanaged = $true }, @{ name = 'Managed' })
        Set-AlmConfigSolutionsInFile -ConfigPath $configPath -Solutions $solutions | Should -BeTrue
        $config = Import-PowerShellDataFile $configPath
        $config.assets | Should -Be @('data')
        $config.solutions[0].name | Should -Be "O'Brien"
        $config.solutions[0].deployUnmanaged | Should -BeTrue
        $config.solutions[1].ContainsKey('deployUnmanaged') | Should -BeFalse
        Set-AlmConfigSolutionsInFile -ConfigPath $configPath -Solutions $solutions | Should -BeFalse
    }

    It 'preserves existing per-solution mappings and custom properties when replacing selections' {
        $configPath = Join-Path $TestDrive 'mapped-solutions.psd1'
        # Deliberately mix retired solution-level keys with supported inline entries:
        # refreshing selection must drop the former without discarding mapping metadata.
        Set-Content -LiteralPath $configPath -Value @'
@{
    solutions = @(
        @{
            name = 'PluginSolution'
            mappingFile = 'legacy-mapping.xml'
            buildCommands = @(@{ executable = 'dotnet'; arguments = @('build') })
            mappings = @(
                @{
                    type = 'FileToFile'
                    source = 'plugins/Example.dll'
                    destination = 'PluginAssemblies/Example.dll'
                    buildCommand = @{
                        executable = 'dotnet'
                        arguments = @('build', 'plugins/Example.csproj')
                    }
                }
            )
            customSetting = @{ keep = $true }
        }
        @{ name = 'UnselectedSolution'; mappings = @() }
    )
}
'@

        Set-AlmConfigSolutionsInFile -ConfigPath $configPath -Solutions @(
            @{ name = 'PluginSolution'; deployUnmanaged = $true }
        ) | Should -BeTrue

        $solution = (Import-PowerShellDataFile -LiteralPath $configPath).solutions[0]
        $solution.mappings[0].type | Should -Be 'FileToFile'
        $solution.mappings[0].source | Should -Be 'plugins/Example.dll'
        $solution.mappings[0].destination | Should -Be 'PluginAssemblies/Example.dll'
        $solution.mappings[0].buildCommand.arguments | Should -Be @('build', 'plugins/Example.csproj')
        $solution.customSetting.keep | Should -BeTrue
        $solution.deployUnmanaged | Should -BeTrue
        $solution.ContainsKey('mappingFile') | Should -BeFalse
        $solution.ContainsKey('buildCommands') | Should -BeFalse
        (Import-PowerShellDataFile -LiteralPath $configPath).solutions.Count | Should -Be 1
    }

    It 'creates configuration from a template and toggles checker configuration idempotently' {
        $configPath = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.psd1')
        $templatePath = Join-Path $TestDrive 'template.psd1'
        Set-Content $templatePath -Value '@{ assets = @("data") }'
        Set-AlmConfigSolutionCheckEnabledInFile -ConfigPath $configPath -Enabled $true -CreateIfMissing -TemplatePath $templatePath | Should -BeTrue
        (Import-PowerShellDataFile $configPath).solutionCheck.enabled | Should -BeTrue
        Set-AlmConfigSolutionCheckEnabledInFile -ConfigPath $configPath -Enabled $false | Should -BeTrue
        (Import-PowerShellDataFile $configPath).solutionCheck.enabled | Should -BeFalse
        Set-AlmConfigSolutionCheckEnabledInFile -ConfigPath $configPath -Enabled $false | Should -BeFalse
        (Import-PowerShellDataFile $configPath).assets | Should -Be @('data')
    }

    It 'detects active solution-check settings but ignores commented examples' {
        $commentedConfig = @'
@{
    # solutionCheck = @{
    #     enabled = $true
    # }
    solutions = @(
        @{
            name = 'Example'
            # solutionCheck = @{
            #     enabled = $true
            # }
        }
    )
}
'@
        Get-SolutionCheckEnabledFromConfigContent -ConfigContent $commentedConfig | Should -BeFalse
        Get-SolutionCheckEnabledFromConfigContent -ConfigContent '@{ solutionCheck = @{ enabled = $true } }' | Should -BeTrue
        Get-SolutionCheckEnabledFromConfigContent -ConfigContent '@{ solutions = @(@{ name = "Example"; solutionCheck = @{ enabled = $true } }) }' | Should -BeTrue
        Get-SolutionCheckEnabledFromConfigContent -ConfigContent '@{ solutionCheck = @{ enabled = $false } }' | Should -BeFalse
        { Get-SolutionCheckEnabledFromConfigContent -ConfigContent '@{ solutionCheck = ' } |
            Should -Throw '*Unable to inspect alm-config.psd1*'
    }

    It 'adds and updates baseline selectors without replacing other validation settings' -ForEach @(
        @{ Initial = '@{}'; HasPreserved = $false }
        @{ Initial = '@{ buildValidation = @{ other = 42 } }'; HasPreserved = $true }
        @{ Initial = '@{ buildValidation = @{ baselineRelease = "old"; other = 42 } }'; HasPreserved = $true }
    ) {
        $configPath = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.psd1')
        Set-Content $configPath -Value $Initial
        Set-AlmConfigBuildValidationBaselineReleaseInFile -ConfigPath $configPath -BaselineRelease "release's name" | Should -BeTrue
        $config = Import-PowerShellDataFile $configPath
        $config.buildValidation.baselineRelease | Should -Be "release's name"
        if ($HasPreserved) { $config.buildValidation.other | Should -Be 42 }
        Set-AlmConfigBuildValidationBaselineReleaseInFile -ConfigPath $configPath -BaselineRelease "release's name" | Should -BeFalse
        Set-AlmConfigBuildValidationBaselineReleaseInFile -ConfigPath $configPath -BaselineRelease '' | Should -BeTrue
    }

    It 'rejects missing, malformed, or non-hashtable configuration before editing' {
        $configPath = Join-Path $TestDrive 'invalid.psd1'
        { Set-AlmConfigBuildValidationBaselineReleaseInFile -ConfigPath $configPath -BaselineRelease '' } | Should -Throw '*not found*'
        Set-Content $configPath -Value '@{'
        { Set-AlmConfigBuildValidationBaselineReleaseInFile -ConfigPath $configPath -BaselineRelease '' } | Should -Throw '*Could not parse*'
        Set-Content $configPath -Value '42'
        { Set-AlmConfigSolutionCheckEnabledInFile -ConfigPath $configPath -Enabled $true } | Should -Throw '*root hashtable*'
        Set-Content $configPath -Value '@{ buildValidation = "not a hashtable" }'
        { Set-AlmConfigBuildValidationBaselineReleaseInFile -ConfigPath $configPath -BaselineRelease '' } | Should -Throw '*must be a hashtable*'
    }

    It 'maps simple and Gitflow strategies and detects the same environment on multiple branches' {
        $dev = [pscustomobject]@{ ShortName = 'DEV'; FriendlyName = 'Development'; Url = 'https://dev.example.com/path' }
        $prod = [pscustomobject]@{ ShortName = 'PROD'; FriendlyName = 'Production'; Url = 'https://prod.example.com/' }
        $simple = @(Get-DefaultBranchEnvironmentMappingsFromStrategy -Strategy Simple -EnvironmentConfigurations @($dev, $prod))
        $simple[0].Environments.Count | Should -Be 2
        $gitflow = @(Get-DefaultBranchEnvironmentMappingsFromStrategy -Strategy GitflowLike -EnvironmentConfigurations @($dev, $prod))
        $gitflow[0].Environments | Should -Be @($dev)
        $gitflow[2].Environments | Should -Be @($prod)
        Test-BranchEnvironmentMappingDuplicate -BranchMappings $gitflow | Should -BeFalse
        Test-BranchEnvironmentMappingDuplicate -BranchMappings @(@{ BranchName = 'main'; Environments = @($dev) }, @{ BranchName = 'develop'; Environments = @($dev) }) | Should -BeTrue
        $noProduction = @(Get-DefaultBranchEnvironmentMappingsFromStrategy -Strategy GitflowLike -EnvironmentConfigurations @($dev))
        $noProduction[2].Environments.Count | Should -Be 0
    }
}

Describe 'Setup shared mutation guards' {
    It 'does not create directories under WhatIf but preserves normal creation' {
        $directory = Join-Path $TestDrive 'guarded-directory'
        New-DirectoryIfMissing -Path $directory -WhatIf
        Test-Path $directory | Should -BeFalse
        New-DirectoryIfMissing -Path $directory -Confirm:$false
        Test-Path $directory -PathType Container | Should -BeTrue
    }

    It 'does not create or modify configuration under WhatIf' -ForEach @(
        @{ Setter = 'Set-AlmConfigSolutionsInFile'; Settings = @{ Solutions = @(@{ name = 'Example' }) } }
        @{ Setter = 'Set-AlmConfigSolutionCheckEnabledInFile'; Settings = @{ Enabled = $true } }
        @{ Setter = 'Set-AlmConfigBuildValidationBaselineReleaseInFile'; Settings = @{ BaselineRelease = '@TEST' } }
    ) {
        $configPath = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.psd1')
        & $Setter -ConfigPath $configPath -CreateIfMissing @Settings -WhatIf | Should -BeFalse
        Test-Path $configPath | Should -BeFalse
        Set-Content $configPath -Value '@{ preserved = 42 }'
        $before = [System.IO.File]::ReadAllBytes($configPath)
        & $Setter -ConfigPath $configPath @Settings -WhatIf | Should -BeFalse
        [System.IO.File]::ReadAllBytes($configPath) | Should -Be $before
    }

    It 'does not authenticate or create application secrets under WhatIf' {
        Mock Get-AuthToken { throw 'Unexpected authentication' }
        Mock Invoke-RestMethod { throw 'Unexpected Graph request' }
        New-EntraIdApplicationSecret -ApplicationObjectId application-id -TenantId example.com -WhatIf
        Should -Invoke Get-AuthToken -Times 0 -Exactly
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'returns the generated secret after an approved Graph request' {
        Mock Get-AuthToken { [pscustomobject]@{ AccessToken = 'fake-token' } }
        Mock Invoke-RestMethod { [pscustomobject]@{ secretText = 'fake-generated-secret' } }
        New-EntraIdApplicationSecret -ApplicationObjectId application-id -TenantId example.com -Confirm:$false | Should -Be 'fake-generated-secret'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://graph.microsoft.com/v1.0/applications/application-id/addPassword' -and $Method -eq 'Post' -and
                $Headers.Authorization -eq 'Bearer fake-token' -and ($Body | ConvertFrom-Json).passwordCredential.displayName -eq 'ALM4Dataverse Setup'
        }
    }

    It 'propagates authentication failures before issuing a secret creation request' {
        Mock Get-AuthToken { throw 'Authentication denied' }
        Mock Invoke-RestMethod { throw 'Unexpected Graph request' }
        { New-EntraIdApplicationSecret -ApplicationObjectId application-id -TenantId example.com -Confirm:$false } | Should -Throw '*Authentication denied*'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }
}

Describe 'Setup publication decisions' {
    BeforeEach {
        Mock Write-SetupGuidance {}
        Mock Read-TextWithDefault { $DefaultValue }
    }

    It 'supports direct, alternate-branch, and PR publication without contacting a provider' -ForEach @(
        @{ Selection = 0; Mode = 'Direct'; ExpectedBranch = 'main' }
        @{ Selection = 1; Mode = 'Direct'; ExpectedBranch = 'main' }
        @{ Selection = 2; Mode = 'PullRequest'; ExpectedBranch = '' }
    ) {
        Mock Select-FromMenu { $Selection }
        $plan = Get-RepoChangePublishPlan -ProviderName GitHub -RepositoryName Repo -BaseBranch main -DefaultCommitMessage 'Commit' -DefaultPullRequestTitle 'PR'
        $plan.Mode | Should -Be $Mode
        $plan.TargetBranch | Should -Be main
        if ($ExpectedBranch) { $plan.BranchName | Should -Be $ExpectedBranch }
        else { $plan.BranchName | Should -Match '^alm4dataverse/Repo-main-\d{14}$'; $plan.PullRequestTitle | Should -Be PR }
    }

    It 'supports branch-targeted publication choices' -ForEach @(
        @{ Selection = 0; Mode = 'Direct' }
        @{ Selection = 1; Mode = 'PullRequest' }
    ) {
        Mock Select-FromMenu { $Selection }
        $plan = Get-BranchTargetedRepoChangePublishPlan -ProviderName GitHub -RepositoryName Repo -TargetBranch develop -DefaultCommitMessage 'Commit' -DefaultPullRequestTitle 'PR'
        $plan.Mode | Should -Be $Mode
        $plan.TargetBranch | Should -Be develop
    }

    It 'rejects cancelled publication choices' {
        Mock Select-FromMenu { $null }
        { Get-RepoChangePublishPlan -ProviderName GitHub -RepositoryName Repo -BaseBranch main -DefaultCommitMessage 'Commit' -DefaultPullRequestTitle 'PR' } | Should -Throw '*No repository publish option selected*'
        { Get-BranchTargetedRepoChangePublishPlan -ProviderName GitHub -RepositoryName Repo -TargetBranch main -DefaultCommitMessage 'Commit' -DefaultPullRequestTitle 'PR' } | Should -Throw '*No repository publish option selected*'
    }
}

Describe 'Development ALM4Dataverse reference resolution' {
    It 'uses the commit for a detached linked worktree' {
        $repositoryPath = Join-Path $TestDrive 'development-reference-repository'
        $worktreePath = Join-Path $TestDrive 'development-reference-worktree'
        New-Item -ItemType Directory -Path $repositoryPath -Force | Out-Null

        & git -C $repositoryPath init --quiet
        if ($LASTEXITCODE -ne 0) { throw 'Failed to initialize the resolver test repository.' }
        Set-Content -LiteralPath (Join-Path $repositoryPath 'test.txt') -Value 'test'
        & git -C $repositoryPath add test.txt
        if ($LASTEXITCODE -ne 0) { throw 'Failed to stage the resolver test file.' }
        & git -C $repositoryPath -c user.name=SetupTest -c user.email=setup-test@example.invalid commit --quiet -m 'Test resolver'
        if ($LASTEXITCODE -ne 0) { throw 'Failed to create the resolver test commit.' }
        $expectedCommit = (& git -C $repositoryPath rev-parse HEAD).Trim()
        & git -C $repositoryPath worktree add --quiet --detach $worktreePath HEAD
        if ($LASTEXITCODE -ne 0) { throw 'Failed to create the detached resolver test worktree.' }

        Resolve-DevelopmentDefaultAlm4DataverseRef -PrimaryRepositoryPath $worktreePath -FallbackRef stable |
            Should -Be $expectedCommit
    }
}
