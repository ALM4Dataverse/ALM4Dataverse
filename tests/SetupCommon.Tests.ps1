BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repoRoot 'pipelines/scripts/common.ps1')
    . (Join-Path $repoRoot 'setup-common.ps1')
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
    public class SelectionPrompt<T> {
        public string MoreChoicesText, SearchPlaceholderText;
        public bool WrapAround, SearchEnabled;
        public int PageSize;
        public System.Collections.Generic.List<T> Choices = new System.Collections.Generic.List<T>();
        public void AddChoice(T value) { Choices.Add(value); }
        public System.Threading.Tasks.Task<T> ShowAsync(object console, System.Threading.CancellationToken token) {
            token.ThrowIfCancellationRequested();
            return System.Threading.Tasks.Task.FromResult((T)AnsiConsole.Answers.Dequeue());
        }
    }
    public class TextPrompt<T> {
        public bool IsSecret, AllowEmpty;
        public TextPrompt(string text) {}
        public T Show(object console) { return (T)AnsiConsole.Answers.Dequeue(); }
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
        public static object Console = new object();
        public static System.Collections.Generic.Queue<object> Answers = new System.Collections.Generic.Queue<object>();
        public static System.Collections.Generic.List<object> Output = new System.Collections.Generic.List<object>();
        public static StatusDisplay Status() { return new StatusDisplay(); }
        public static void MarkupLine(string value) { Output.Add(value); }
        public static void WriteLine() {}
        public static void Write(object value) { Output.Add(value); }
        public static void Markup(string value) { Output.Add(value); }
        public static void Clear() { Output.Clear(); }
        public static bool Confirm(string value, bool defaultValue) { return Answers.Count == 0 ? defaultValue : (bool)Answers.Dequeue(); }
        public static T Ask<T>(string value, T defaultValue) { return Answers.Count == 0 ? defaultValue : (T)Answers.Dequeue(); }
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
        $result = @(Select-BranchEnvironmentMapping -InitialBranchMappings @($initial) -BranchOnly -EditDevEnvironmentScriptBlock {
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
}

Describe 'Shared setup prompt and rendering contracts' {
    BeforeEach {
        Mock Initialize-SpectreConsole {}
        Mock Write-SetupConsoleBar { $false }
        # Both the wrappers and fake console hold process/session state between prompt calls.
        Clear-SetupWizardContext
        Clear-SetupPromptDocContext
        [Spectre.Console.AnsiConsole]::Answers.Clear()
        [Spectre.Console.AnsiConsole]::Output.Clear()
    }

    AfterEach {
        Clear-SetupWizardContext
        Clear-SetupPromptDocContext
        [Spectre.Console.AnsiConsole]::Answers.Clear()
        [Spectre.Console.AnsiConsole]::Output.Clear()
    }

    It 'delegates bottom-row lookup and falls back when the console bar is unavailable' {
        Show-SetupStatusBarAtBottom -PromptKind Menu -SearchEnabled
        Clear-SetupStatusBarAtBottom
        Should -Invoke Write-SetupConsoleBar -Times 2 -Exactly -ParameterFilter {
            $AtBottom -and $RestoreCursorPosition
        }
        ([Spectre.Console.AnsiConsole]::Output -join "`n") | Should -Match 'Type=filter'
    }

    It 'maps markup-safe menu values and supports single-choice cancellation' {
        [Spectre.Console.AnsiConsole]::Answers.Enqueue('[[One]]')
        Select-FromMenu -Title Test -Items @('[One]', 'Two') | Should -Be 0
        [Spectre.Console.AnsiConsole]::Answers.Enqueue('< Cancel setup')
        Select-FromMenu -Title Test -Items @('One') | Should -BeNullOrEmpty
        Select-FromMenu -Title Test -Items @() | Should -BeNullOrEmpty
    }

    It 'supports searchable menus and requests back navigation from later wizard steps' {
        $items = @(1..10 | ForEach-Object { "Item $_" })
        [Spectre.Console.AnsiConsole]::Answers.Enqueue('Item 10')
        Select-FromMenu -Title Test -Items $items | Should -Be 9
        Set-SetupWizardContext -Title Test -StepNames @('First', 'Second') -CurrentStepIndex 1
        [Spectre.Console.AnsiConsole]::Answers.Enqueue('< Back to previous step')
        { Select-FromMenu -Title Test -Items @('One', 'Two') } | Should -Throw '*__ALM4DATAVERSE_WIZARD_BACK__*'
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

Describe 'Setup configuration and validation helpers' {
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
