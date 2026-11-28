BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repoRoot 'setup/setup-common.ps1')
    if (-not ('Alm4DataverseSetupWebTestActions' -as [type])) {
        Add-Type -TypeDefinition @'
using System.Collections.Generic;

public static class Alm4DataverseSetupWebTestActions
{
    public static readonly Queue<object> Queue = new Queue<object>();
}
'@
    }
    $script:webHost = Initialize-SetupWebHost -Provider 'GitHub' -ProductVersion '1.2.3-test' -Title 'Test setup' -NoBrowser
    $script:baseUrl = "http://127.0.0.1:$($script:webHost.Port)"
}

AfterAll {
    Close-SetupWebHost
}

Describe 'Embedded browser setup assets' {
    It 'serves complete HTML, CSS and JavaScript assets' {
        $html = Get-SetupWebUiAsset -Name 'index.html'
        $css = Get-SetupWebUiAsset -Name 'app.css'
        $js = Get-SetupWebUiAsset -Name 'app.js'

        $html | Should -Match 'logo\.png'
        $html | Should -Match 'app\.css'
        $html | Should -Match 'app\.js'
        $html | Should -Match 'id="stage"'
        $html | Should -Match 'repository-chip'
        $html | Should -Match 'footer-status'
        $html | Should -Match 'busy-indicator'
        $html | Should -Match 'busy-spinner'
        $html | Should -Not -Match 'Everything runs locally'
        $css | Should -Match '\.step-card'
        $css | Should -Match '\.step-card-main'
        $css | Should -Match '\.step-subitems'
        $css | Should -Match '\.subitem-tree'
        $css | Should -Match '\.busy-indicator'
        $css | Should -Match '\.busy-spinner-arc'
        $css | Should -Match '\.working-card'
        $css | Should -Match 'data-theme="dark"'
        $html | Should -Match 'theme-toggle'
        $js | Should -Match 'api/state'
        $js | Should -Match 'wizard'
        $js | Should -Match 'choice-filter'
        $js | Should -Match 'showBusy'
        $js | Should -Match 'buildSubItemTree'
        $js | Should -Match 'renderSubItemTree'
        $js | Should -Match 'interactiveVersion'
        $js | Should -Match 'asArray'
        $css | Should -Match 'search-field'
        $css.Length | Should -BeGreaterThan 10000
        $js.Length | Should -BeGreaterThan 10000
    }

    It 'keeps the embedded logo identical to logo.png' {
        $expected = [System.IO.File]::ReadAllBytes((Join-Path $repoRoot 'logo.png'))
        $actual = Get-SetupWebLogo
        $actual | Should -BeOfType [byte]
        $actual.Length | Should -Be $expected.Length
        [System.Linq.Enumerable]::SequenceEqual([byte[]]$actual, [byte[]]$expected) | Should -BeTrue
    }
}

Describe 'Loopback setup web server' {
    It 'compiles the server type once' {
        (Get-SetupWebServerType).FullName | Should -Be 'ALM4Dataverse.SetupWebHost'
        (Get-SetupWebServerType) | Should -Be (Get-SetupWebServerType)
    }

    It 'serves the application shell, logo and API state' {
        $page = Invoke-WebRequest -Uri "$script:baseUrl/" -UseBasicParsing
        $page.StatusCode | Should -Be 200
        $page.Content | Should -Match 'ALM4Dataverse'

        $logo = Invoke-WebRequest -Uri "$script:baseUrl/logo.png" -UseBasicParsing
        $logo.StatusCode | Should -Be 200
        $logo.RawContentLength | Should -BeGreaterThan 1000

        $state = Invoke-WebRequest -Uri "$script:baseUrl/api/state?token=$($script:webHost.Token)" -UseBasicParsing | ConvertFrom-Json
        $state.state.app | Should -Be 'GitHub'
        $state.state.version | Should -Be '1.2.3-test'
        $state.deviceCode | Should -Be ''
    }

    It 'rejects API requests without the action token' {
        { Invoke-WebRequest -Uri "$script:baseUrl/api/state?token=wrong" -UseBasicParsing } | Should -Throw '*403*'
        { Invoke-WebRequest -Uri "$script:baseUrl/api/heartbeat?token=wrong" -UseBasicParsing } | Should -Throw '*403*'
        { Invoke-WebRequest -Uri "$script:baseUrl/api/action?token=wrong" -Method Post -Body '{}' -UseBasicParsing } | Should -Throw '*403*'
    }

    It 'accepts one action and exposes device code text separately from state' {
        $payload = '{"action":"choose","value":2}'
        $response = Invoke-WebRequest -Uri "$script:baseUrl/api/action?token=$($script:webHost.Token)" -Method Post -ContentType 'application/json' -Body $payload -UseBasicParsing
        $response.StatusCode | Should -Be 200
        $script:webHost.Server.WaitForAction(2000) | Should -Be $payload

        $script:webHost.Server.PublishDeviceCode("Sign in with code ABC-123`nhttps://example.com/device")
        $state = Invoke-WebRequest -Uri "$script:baseUrl/api/state?token=$($script:webHost.Token)" -UseBasicParsing | ConvertFrom-Json
        $state.deviceCode | Should -Match 'ABC-123'
        $script:webHost.Server.ClearDeviceCode()
        $state = Invoke-WebRequest -Uri "$script:baseUrl/api/state?token=$($script:webHost.Token)" -UseBasicParsing | ConvertFrom-Json
        $state.deviceCode | Should -Be ''
    }

    It 'returns not found for unknown assets and method errors for wrong verbs' {
        { Invoke-WebRequest -Uri "$script:baseUrl/missing.txt" -UseBasicParsing } | Should -Throw '*404*'
        { Invoke-WebRequest -Uri "$script:baseUrl/api/state?token=$($script:webHost.Token)" -Method Post -Body '{}' -UseBasicParsing } | Should -Throw '*405*'
    }

    It 'stops cleanly and wakes a waiting action reader' {
        $serverType = Get-SetupWebServerType
        $server = [System.Activator]::CreateInstance($serverType)
        $server.SetToken('token')
        $server.Start(0)
        $server.Port | Should -BeGreaterThan 0
        $server.Stop()
        $server.WaitForAction(100) | Should -BeNullOrEmpty
        $server.Dispose()
    }

    It 'launches the browser only when the platform launcher succeeds' {
        $originalOS = $env:OS
        try {
            $env:OS = 'Windows_NT'
            Mock Start-Process { }
            Open-SetupWebBrowser -Url 'https://example.com' | Should -BeTrue

            Mock Start-Process { throw [System.InvalidOperationException]::new('no launcher') }
            Open-SetupWebBrowser -Url 'https://example.com' | Should -BeFalse
        }
        finally {
            $env:OS = $originalOS
        }
    }
}

Describe 'Browser state and prompt model' {
    BeforeEach {
        [Alm4DataverseSetupWebTestActions]::Queue.Clear()
        Mock Read-SetupWebAction {
            if ([Alm4DataverseSetupWebTestActions]::Queue.Count -gt 0) { return [Alm4DataverseSetupWebTestActions]::Queue.Dequeue() }
            throw [System.OperationCanceledException]::new('No queued test action.')
        }
        $script:SetupWebPendingGuidance = $null
        $script:SetupWebPendingBlocks = @()
    }

    It 'publishes activity with tones and caps the drawer' {
        $before = $script:webHost.Server.GetStateVersion()
        Add-SetupWebActivity -Text 'info line' -Tone 'info'
        Add-SetupWebActivity -Text 'warning line' -Tone 'warn'
        Add-SetupWebActivity -Text '' -Tone 'info'
        $payload = Get-SetupWebStatePayload
        @($payload.activity | Where-Object { $_.text -eq 'warning line' }).Count | Should -BeGreaterThan 0
        $script:webHost.Server.GetStateVersion() | Should -BeGreaterThan $before

        for ($index = 0; $index -lt 420; $index++) {
            Add-SetupWebActivity -Text "line $index" -Tone 'muted'
        }
        $payload = Get-SetupWebStatePayload
        @($payload.activity).Count | Should -Be 400
        $payload.activity[-1].text | Should -Be 'line 419'
    }

    It 'updates identity, busy state and explicit prompt blocks' {
        Publish-SetupWebIdentity -ProductVersion '9.9.9' -Reference 'feature/test'
        Publish-SetupWebRepository -Name 'contoso/app-platform' -Url 'https://example.com/contoso/app-platform'
        $payload = Get-SetupWebStatePayload
        $payload.version | Should -Be '9.9.9'
        $payload.ref | Should -Be 'feature/test'
        $payload.repository | Should -Be 'contoso/app-platform'
        $payload.repositoryUrl | Should -Be 'https://example.com/contoso/app-platform'

        $script:SetupWebPendingBlocks = @([ordered]@{ type = 'keyvalue'; heading = 'Queued'; values = @() })
        $prompt = Get-SetupWebPromptBase -Kind 'notice' -Title 'Queued blocks'
        $prompt.blocks.Count | Should -Be 1
        $prompt.eyebrow | Should -Not -BeNullOrEmpty
        @(Get-SetupWebContentQueue).Count | Should -Be 0

        $explicit = Get-SetupWebPromptBase -Kind 'notice' -Title 'Explicit' -Blocks @([ordered]@{ type = 'file'; path = 'x' })
        $explicit.blocks[0].path | Should -Be 'x'

        $beforeInteractive = (Get-SetupWebStatePayload).interactiveVersion
        $promptId = Publish-SetupWebPrompt -Prompt $prompt
        $payload = Get-SetupWebStatePayload
        $payload.prompt.id | Should -Be $promptId
        $payload.interactiveVersion | Should -BeGreaterThan $beforeInteractive
        Publish-SetupWebBusy -Message 'Working'
        $payload = Get-SetupWebStatePayload
        $payload.prompt | Should -BeNullOrEmpty
        $payload.busy | Should -Be 'Working'
    }

    It 'publishes device instructions beside the prompt state' {
        $prompt = Get-SetupWebPromptBase -Kind 'notice' -Title 'Device'
        $promptId = Publish-SetupWebPrompt -Prompt $prompt
        try {
            Publish-SetupWebDeviceCode -Message 'one-time code ABCD-1234'
            $state = Invoke-RestMethod -Uri "$script:baseUrl/api/state?token=$($script:webHost.Token)"
            $state.deviceCode | Should -Be 'one-time code ABCD-1234'
            $state.state.prompt.id | Should -Be $promptId
        }
        finally {
            Publish-SetupWebDeviceCode -Message ''
            Publish-SetupWebBusy -Message 'test cleanup'
        }

        $state = Invoke-RestMethod -Uri "$script:baseUrl/api/state?token=$($script:webHost.Token)"
        $state.deviceCode | Should -BeNullOrEmpty
    }

    It 'converts escaped Spectre markup to plain text' {
        ConvertFrom-SetupWebMarkup -Text '[[literal]] [red]error[/] [bold]bold[/]' | Should -Be '[literal] error bold'
        ConvertFrom-SetupWebMarkup -Text '' | Should -Be ''
    }

    It 'adds content blocks to capture instead of pending state' {
        $capture = [System.Collections.Generic.List[object]]::new()
        $script:SetupWebCaptureBlocks = $capture
        try {
            Add-SetupWebContentBlock -Block ([ordered]@{ type = 'file'; path = 'captured' })
            $capture.Count | Should -Be 1
            @(Get-SetupWebContentQueue).Count | Should -Be 0
        }
        finally {
            $script:SetupWebCaptureBlocks = $null
        }

        Add-SetupWebContentBlock -Block ([ordered]@{ type = 'file'; path = 'pending' })
        @(Get-SetupWebContentQueue)[0].path | Should -Be 'pending'
    }
}

Describe 'Browser prompt readers' {
    BeforeEach {
        [Alm4DataverseSetupWebTestActions]::Queue.Clear()
        Mock Read-SetupWebAction {
            if ([Alm4DataverseSetupWebTestActions]::Queue.Count -gt 0) { return [Alm4DataverseSetupWebTestActions]::Queue.Dequeue() }
            throw [System.OperationCanceledException]::new('No queued test action.')
        }
        $script:publishedPrompts = [System.Collections.Generic.List[object]]::new()
        Mock Publish-SetupWebPrompt {
            $script:publishedPrompts.Add($Prompt)
            return [string]$Prompt['id']
        }
        $script:SetupWebPendingGuidance = $null
        $script:SetupWebPendingBlocks = @()
        Clear-SetupWizardContext
        Clear-SetupPromptDocContext
        Remove-Variable -Name 'SetupCurrentSectionMessage' -Scope Script -ErrorAction SilentlyContinue
        $script:SetupGuidancePanelVisible = $false
    }

    AfterEach {
        Clear-SetupWizardContext
        Clear-SetupPromptDocContext
        Remove-Variable -Name 'SetupCurrentSectionMessage' -Scope Script -ErrorAction SilentlyContinue
    }

    It 'returns null for an empty menu' {
        Read-SetupWebMenu -Title 'Empty' -Items @() | Should -BeNullOrEmpty
        $script:publishedPrompts.Count | Should -Be 0
    }

    It 'returns the selected menu index and records the choice' {
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'choose'; value = 1 })
        Read-SetupWebMenu -Title 'Choose' -Items @('One', 'Two', 'Three') -PromptGuidanceLines @('Pick one.') | Should -Be 1
        $script:publishedPrompts[0].kind | Should -Be 'menu'
        $script:publishedPrompts[0].items.Count | Should -Be 3
        $script:publishedPrompts[0].guidance | Should -Contain 'Pick one.'
    }

    It 'styles action and dim items without changing their indexes' {
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'choose'; value = 1 })
        $result = Read-SetupWebMenu `
            -Title 'Styled' `
            -Items @('Setup one', 'Action', 'Dimmed one') `
            -ActionItems @('Action') `
            -ActionSectionFirst `
            -DimItems @('Dimmed one') `
            -ActionSectionTitle 'Actions' `
            -ItemStyles @{ 'Setup one' = 'bold white' }
        $result | Should -Be 1
        $prompt = $script:publishedPrompts[0]
        $prompt.actionFirst | Should -BeTrue
        $prompt.actionSectionTitle | Should -Be 'Actions'
        @($prompt.items | Where-Object { $_.label -eq 'Action' })[0].action | Should -BeTrue
        @($prompt.items | Where-Object { $_.label -eq 'Dimmed one' })[0].dimmed | Should -BeTrue
    }

    It 'returns null for an invalid menu choice' {
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'choose'; value = 99 })
        Read-SetupWebMenu -Title 'Choose' -Items @('One', 'Two') | Should -BeNullOrEmpty
    }

    It 'treats a Back menu item as wizard navigation' {
        Set-SetupWizardContext -Title 'Wizard' -StepNames @('Step') -CurrentStepIndex 0
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'choose'; value = 0 })
        { Read-SetupWebMenu -Title 'Choose' -Items @('Back', 'Other') } | Should -Throw '*__ALM4DATAVERSE_WIZARD_BACK__*'
    }

    It 'renders a single-item menu as a normal choice' {
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'choose'; value = 0 })

        Read-SetupWebMenu -Title 'Continue?' -Items @('Continue') | Should -Be 0

        $script:publishedPrompts[0].kind | Should -Be 'menu'
        @($script:publishedPrompts[0].items).Count | Should -Be 1
        $script:publishedPrompts[0].items[0].label | Should -Be 'Continue'
    }

    It 'handles Back and Cancel actions on a menu' {
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'back' })
        { Read-SetupWebMenu -Title 'Root' -Items @('One', 'Two') } | Should -Throw '*cancelled*'

        Set-SetupWizardContext -Title 'Wizard' -StepNames @('Step') -CurrentStepIndex 0
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'back' })
        { Read-SetupWebMenu -Title 'Step prompt' -Items @('One', 'Two') } | Should -Throw '*__ALM4DATAVERSE_WIZARD_BACK__*'

        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'cancel' })
        { Read-SetupWebYesNo -Prompt 'Cancel?' } | Should -Throw '*cancelled*'
    }

    It 'ignores an unknown menu action and accepts the next one' {
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'unexpected' })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'choose'; value = 0 })
        Read-SetupWebMenu -Title 'Choose' -Items @('One', 'Two') | Should -Be 0
    }

    It 'reads yes and no answers with the configured default' {
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'yes' })
        Read-SetupWebYesNo -Prompt 'Confirm?' | Should -BeTrue
        $script:publishedPrompts[0].defaultYes | Should -BeTrue

        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'no' })
        Read-SetupWebYesNo -Prompt 'Confirm?' -DefaultNo | Should -BeFalse
        $script:publishedPrompts[1].defaultYes | Should -BeFalse
    }

    It 'accepts a default, trims typed text and allows an empty value' {
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'submit'; value = '' })
        Read-SetupWebTextWithDefault -Prompt 'Name' -DefaultValue 'default-name' | Should -Be 'default-name'

        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'submit'; value = '  typed  ' })
        Read-SetupWebTextWithDefault -Prompt 'Name' | Should -Be 'typed'

        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'submit'; value = '   ' })
        Read-SetupWebTextWithDefault -Prompt 'Name' -AllowEmpty | Should -Be ''

        $script:publishedPrompts[2].allowEmpty | Should -BeTrue
    }

    It 'republishes text input with a validation error before accepting a value' {
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'submit'; value = '' })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'submit'; value = 'valid' })
        Read-SetupWebTextWithDefault -Prompt 'Required' | Should -Be 'valid'
        $script:publishedPrompts.Count | Should -Be 2
        $script:publishedPrompts[1].error | Should -Match 'required'
    }

    It 'keeps secret whitespace and never publishes the entered value' {
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'submit'; value = ' secret value ' })
        Read-SetupWebSecretText -Prompt 'Client secret' | Should -Be ' secret value '
        $script:publishedPrompts[0].kind | Should -Be 'secret'
        $script:publishedPrompts[0].Contains('secret value') | Should -BeFalse

        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'submit'; value = '' })
        Read-SetupWebSecretText -Prompt 'Client secret' -AllowEmpty | Should -Be ''

        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'submit'; value = '' })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'submit'; value = 'value' })
        Read-SetupWebSecretText -Prompt 'Client secret' | Should -Be 'value'
        $script:publishedPrompts[3].error | Should -Match 'required'
    }

    It 'discards actions addressed to a different prompt' {
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ id = 'stale'; action = 'choose'; value = 1 })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ id = 'active'; action = 'choose'; value = 0 })
        $action = Read-SetupWebPromptAction -PromptId 'active'
        $action.id | Should -Be 'active'
        $action.value | Should -Be 0
    }

    It 'waits for an acknowledgement' {
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'continue' })
        Wait-SetupWebAcknowledgement -Message 'Review complete' -ContinueLabel 'Next'
        $script:publishedPrompts[0].kind | Should -Be 'notice'
        $script:publishedPrompts[0].continueLabel | Should -Be 'Next'
    }

    It 'stores section guidance and help metadata without drawing console output' {
        Write-SetupWebSection -Message 'Configure solutions' -GuidanceLines @('Pick solutions.') -GuidanceDocRelativePath 'docs/config/alm-config.md'
        (Get-SetupWebStatePayload).section | Should -Be 'Configure solutions'
        $guidance = Get-SetupWebPendingGuidance
        $guidance.Lines | Should -Contain 'Pick solutions.'
        $guidance.HelpUrl | Should -Match 'docs/config/alm-config.md'

        Show-SetupWebPromptGuidance -PromptText 'Prompt help' -GuidanceLines @('Prompt-specific help.') -DocRelativePath 'docs/config/alm-config.md'
        (Get-SetupWebPendingGuidance).Lines | Should -Contain 'Prompt-specific help.'
    }

    It 'escapes and logs captured operation output' {
        Show-SetupWebActivityOutputPanel -Heading 'Output' -Lines @()
        Show-SetupWebActivityOutputPanel -Heading 'Output' -Lines @('[red]first[/]', '[grey]second[/]', '[green]third[/]') -MaxLines 2
        Show-SetupWebActivityOutputPanel -Heading 'Output' -Lines @('[red]first[/]') -MaxLines 5
        $payload = Get-SetupWebStatePayload
        @($payload.activity | Where-Object { $_.text -match 'second' }).Count | Should -BeGreaterThan 0
        @($payload.activity | Where-Object { $_.text -match 'omitted' }).Count | Should -BeGreaterThan 0
    }
}

Describe 'Browser setup wizard' {
    BeforeEach {
        [Alm4DataverseSetupWebTestActions]::Queue.Clear()
        Mock Read-SetupWebAction {
            if ([Alm4DataverseSetupWebTestActions]::Queue.Count -gt 0) { return [Alm4DataverseSetupWebTestActions]::Queue.Dequeue() }
            throw [System.OperationCanceledException]::new('No queued test action.')
        }
        Clear-SetupWizardContext
        $script:SetupWebWizardNotice = $null
        $script:firstStepRuns = 0
        $script:secondStepRuns = 0
        $script:previewRuns = 0
        $script:applyRuns = 0
        $script:preApplyRuns = 0
        $script:entryTarget = $null
    }

    AfterEach {
        Clear-SetupWizardContext
    }

    It 'rejects preview or return-to-caller without an apply action' {
        { Invoke-SetupWebWizard -Title 'Bad' -Steps @([pscustomobject]@{ Name = 'Only'; Action = {} }) -PreviewAction {} } |
            Should -Throw '*PreviewAction requires ApplyAction*'
        { Invoke-SetupWebWizard -Title 'Bad' -Steps @([pscustomobject]@{ Name = 'Only'; Action = {} }) -ReturnToCaller } |
            Should -Throw '*ReturnToCaller requires ApplyAction*'
    }

    It 'completes a multi-step board and returns the apply result' {
        $steps = @(
            [pscustomobject]@{
                Name = 'First'
                Summary = { if ($script:firstStepRuns -gt 0) { 'First configured' } else { 'Not configured' } }
                Action = { $script:firstStepRuns++ }
            }
            [pscustomobject]@{
                Name = 'Second'
                Summary = { if ($script:secondStepRuns -gt 0) { 'Second configured' } else { 'Not configured' } }
                Action = { $script:secondStepRuns++ }
            }
        )
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'selectStep'; index = 0 })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'selectStep'; index = 1 })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'apply' })

        $result = Invoke-SetupWebWizard -Title 'Board' -Steps $steps -ApplyActionName 'Apply changes' -ApplyAction {
            $script:applyRuns++
            'applied-result'
        }
        $result | Should -Be 'applied-result'
        $script:firstStepRuns | Should -Be 1
        $script:secondStepRuns | Should -Be 1
        $script:applyRuns | Should -Be 1
        (Get-SetupWebStatePayload).wizard | Should -BeNullOrEmpty
    }

    It 'explains blocked, locked and not-ready actions before completing' {
        $steps = @(
            [pscustomobject]@{ Name = 'Locked'; IsLocked = $true; Action = { throw 'locked step must not run' } }
            [pscustomobject]@{ Name = 'Second'; Action = { $script:secondStepRuns++ } }
            [pscustomobject]@{ Name = 'Third'; Action = { $script:firstStepRuns++ } }
        )
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'selectStep'; index = 0 })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'selectStep'; index = 1 })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'apply' })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'selectStep'; index = 2 })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'apply' })

        $result = Invoke-SetupWebWizard -Title 'Sequential' -Steps $steps -RequireSequentialSteps -ApplyAction { 'done' }
        $result | Should -Be 'done'
        $script:secondStepRuns | Should -Be 1
        $script:firstStepRuns | Should -Be 1
    }

    It 'prevents repeating a step locked after completion' {
        $steps = @(
            [pscustomobject]@{
                Name = 'One-time'
                IsComplete = $true
                LockAfterCompletion = $true
                Action = { throw 'locked step must not run' }
            }
            [pscustomobject]@{ Name = 'Second'; Action = { $script:secondStepRuns++ } }
        )
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'selectStep'; index = 0 })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'selectStep'; index = 1 })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'apply' })
        Invoke-SetupWebWizard -Title 'Locked' -Steps $steps -ApplyAction { 'ok' } | Should -Be 'ok'
        $script:secondStepRuns | Should -Be 1
    }

    It 'runs preview before apply only when every step is complete' {
        $steps = @(
            [pscustomobject]@{ Name = 'First'; IsComplete = $true; Action = { } }
        )
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'preview' })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'apply' })
        Invoke-SetupWebWizard `
            -Title 'Preview' `
            -Steps $steps `
            -PreviewAction { $script:previewRuns++ } `
            -PreviewActionName 'Preview changes' `
            -ApplyAction { 'applied' } | Should -Be 'applied'
        $script:previewRuns | Should -Be 1
    }

    It 'reports preview and apply attempts before steps are complete' {
        $steps = @([pscustomobject]@{ Name = 'First'; Action = { $script:firstStepRuns++ } })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'preview' })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'apply' })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'selectStep'; index = 0 })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'apply' })
        Invoke-SetupWebWizard `
            -Title 'Not ready' `
            -Steps $steps `
            -PreviewAction { $script:previewRuns++ } `
            -PreviewActionName 'Preview changes' `
            -ApplyAction { 'applied' } | Should -Be 'applied'
        $script:previewRuns | Should -Be 0
        $script:firstStepRuns | Should -Be 1
    }

    It 'shows a step failure on the board and keeps the step incomplete' {
        $script:branchStepAttempts = 0
        $steps = @(
            [pscustomobject]@{
                Name = 'Branches'
                Action = {
                    $script:branchStepAttempts++
                    if ($script:branchStepAttempts -eq 1) {
                        throw 'Each configured branch must have at least one mapped environment.'
                    }

                    $state = Get-SetupWebStatePayload
                    $script:stepFailureNotice = $state.wizard.notice
                    $script:stepFailureTone = $state.wizard.noticeTone
                    $script:stepFailureStatus = $state.wizard.steps[0].statusLabel
                }
            }
        )
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'selectStep'; index = 0 })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'selectStep'; index = 0 })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'apply' })

        Invoke-SetupWebWizard -Title 'Step errors' -Steps $steps -ApplyAction { 'applied' } | Should -Be 'applied'

        $script:branchStepAttempts | Should -Be 2
        $script:stepFailureNotice | Should -Match 'Error in Branches'
        $script:stepFailureNotice | Should -Match 'Each configured branch'
        $script:stepFailureTone | Should -Be 'error'
        $script:stepFailureStatus | Should -Be 'Next'
    }

    It 'recovers from an apply failure and keeps the board available' {
        $steps = @([pscustomobject]@{ Name = 'First'; IsComplete = $true; Action = { } })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'apply' })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'apply' })
        $result = Invoke-SetupWebWizard -Title 'Retry apply' -Steps $steps -ApplyAction {
            $script:applyRuns++
            if ($script:applyRuns -eq 1) { throw 'transient apply failure' }
            'recovered'
        }
        $result | Should -Be 'recovered'
        $script:applyRuns | Should -Be 2
    }

    It 'recovers from a pre-apply failure' {
        $steps = @([pscustomobject]@{ Name = 'First'; IsComplete = $true; Action = { } })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'apply' })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'apply' })
        $result = Invoke-SetupWebWizard -Title 'Pre-apply' -Steps $steps -PreApplyAction {
            $script:preApplyRuns++
            if ($script:preApplyRuns -eq 1) { throw 'pre-apply failure' }
        } -ApplyAction { 'applied' }
        $result | Should -Be 'applied'
        $script:preApplyRuns | Should -Be 2
    }

    It 'confirms exit without applying and supports declining it' {
        $steps = @([pscustomobject]@{ Name = 'First'; IsComplete = $true; Action = { } })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'exit' })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'no' })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'apply' })
        Invoke-SetupWebWizard -Title 'Exit declined' -Steps $steps -ApplyAction { 'applied' } | Should -Be 'applied'

        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'exit' })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'yes' })
        { Invoke-SetupWebWizard -Title 'Exit accepted' -Steps $steps -ApplyAction { 'applied' } } |
            Should -Throw '*Setup exited without applying changes*'
    }

    It 'returns to the board when exit confirmation is backed out' {
        $steps = @([pscustomobject]@{ Name = 'First'; IsComplete = $true; Action = { } })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'exit' })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'back' })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'apply' })
        Invoke-SetupWebWizard -Title 'Back from exit' -Steps $steps -ApplyAction { 'applied' } | Should -Be 'applied'
    }

    It 'supports cancel action, nested cancel and top-level cancel semantics' {
        $steps = @([pscustomobject]@{ Name = 'First'; IsComplete = $true; Action = { } })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'cancelAction' })
        Invoke-SetupWebWizard -Title 'Nested' -Steps $steps -ApplyAction { 'unused' } -CancelActionName 'Do not configure' | Should -BeNullOrEmpty

        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'cancel' })
        Invoke-SetupWebWizard -Title 'Nested back' -Steps $steps -ApplyAction { 'unused' } -ReturnToCaller | Should -BeNullOrEmpty

        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'cancel' })
        { Invoke-SetupWebWizard -Title 'Top-level cancel' -Steps $steps -ApplyAction { 'unused' } } |
            Should -Throw '*Setup cancelled before changes were applied*'
    }

    It 'opens a sub-item target and handles an unavailable entry' {
        $steps = @(
            [pscustomobject]@{
                Name = 'Branches'
                SubItems = {
                    [pscustomobject]@{ Label = 'main / DEV'; Depth = 1; Target = 'main-target' }
                }
                Action = { param($target) $script:entryTarget = $target }
            }
        )
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'selectEntry'; index = 0; entryId = '0:0' })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'selectEntry'; index = 0; entryId = '0:9' })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'apply' })
        Invoke-SetupWebWizard -Title 'Entries' -Steps $steps -ApplyAction { 'applied' } | Should -Be 'applied'
        $script:entryTarget | Should -Be 'main-target'
    }

    It 'invalidates later steps when their input signature changes' {
        $script:signatureValue = 'one'
        $steps = @(
            [pscustomobject]@{ Name = 'First'; Action = { $script:signatureValue = 'two' } }
            [pscustomobject]@{
                Name = 'Second'
                InputSignature = { $script:signatureValue }
                Action = { $script:secondStepRuns++ }
            }
        )
        # Start with both steps complete and a stale signature on the second step.
        $steps[0] | Add-Member -NotePropertyName IsComplete -NotePropertyValue $true
        $steps[1] | Add-Member -NotePropertyName IsComplete -NotePropertyValue $true
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'selectStep'; index = 0 })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'selectStep'; index = 1 })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'apply' })
        Invoke-SetupWebWizard -Title 'Signatures' -Steps $steps -ApplyAction { 'applied' } | Should -Be 'applied'
        $script:secondStepRuns | Should -BeGreaterThan 0
    }

    It 'handles an unrecognized action and an invalid step index with a notice' {
        $steps = @([pscustomobject]@{ Name = 'First'; Action = { $script:firstStepRuns++ } })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'choose'; value = 0 })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'selectStep'; index = 99 })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'selectStep'; index = 0 })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'wizard'; operation = 'apply' })
        Invoke-SetupWebWizard -Title 'Notices' -Steps $steps -ApplyAction { 'applied' } | Should -Be 'applied'
        $script:firstStepRuns | Should -Be 1
    }

    It 'executes the linear wizard and returns to the previous step on back' {
        $script:linearAttempts = 0
        $script:linearOrder = @()
        $steps = @(
            [pscustomobject]@{
                Name = 'First'
                Action = {
                    $script:linearAttempts++
                    $script:linearOrder += 'first'
                    if ($script:linearAttempts -eq 2) { Request-SetupWizardBack }
                }
            }
            [pscustomobject]@{
                Name = 'Second'
                Action = { $script:linearOrder += 'second' }
            }
        )
        Invoke-SetupWebWizard -Title 'Linear' -Steps $steps | Out-Null
        $script:linearOrder | Should -Be @('first', 'second')
    }

    It 'cancels a back navigation from the first linear step' {
        $steps = @(
            [pscustomobject]@{ Name = 'First'; Action = { Request-SetupWizardBack } }
        )
        { Invoke-SetupWebWizard -Title 'Linear cancel' -Steps $steps } | Should -Throw '*cancelled*'
    }

    It 'builds a wizard view with progress, statuses and summaries' {
        $steps = @(
            [pscustomobject]@{ Name = 'Complete'; Summary = 'Configured'; Action = {} }
            [pscustomobject]@{ Name = 'Active'; Action = {} }
            [pscustomobject]@{ Name = 'Locked'; IsLocked = $true; Action = {} }
            [pscustomobject]@{ Name = 'Blocked'; Action = {} }
        )
        $view = Get-SetupWebWizardView `
            -Title 'View' `
            -Steps $steps `
            -CompletedSteps ([bool[]]@($true, $false, $true, $false)) `
            -LockedSteps ([bool[]]@($false, $false, $true, $false)) `
            -FurthestStepIndex 1 `
            -CurrentStepIndex 1 `
            -RequireSequentialSteps $true `
            -AllStepsCompleted $false `
            -Actions @() `
            -Notice 'Pay attention'
        $view.progress.completed | Should -Be 2
        $view.progress.total | Should -Be 4
        $view.steps[0].statusLabel | Should -Be 'Complete'
        $view.steps[1].statusLabel | Should -Be 'Next'
        $view.steps[2].statusLabel | Should -Be 'Locked'
        $view.steps[3].statusLabel | Should -Be 'Earlier steps first'
        $view.notice | Should -Be 'Pay attention'
    }

    It 'keeps sub-item depth for grouped browser rendering' {
        $steps = @(
            [pscustomobject]@{
                Name = 'Branches'
                SubItems = {
                    [pscustomobject]@{ Label = 'main'; Depth = 1; Target = 'branch' }
                    [pscustomobject]@{ Label = 'DEV: Dev-Main'; Depth = 2; Target = 'dev' }
                }
                Action = {}
            }
        )
        $view = Get-SetupWebWizardView `
            -Title 'Grouped' `
            -Steps $steps `
            -CompletedSteps ([bool[]]@($false)) `
            -LockedSteps ([bool[]]@($false)) `
            -FurthestStepIndex 0 `
            -CurrentStepIndex 0 `
            -RequireSequentialSteps $false `
            -AllStepsCompleted $false
        $view.steps[0].subItems[0].depth | Should -Be 1
        $view.steps[0].subItems[1].depth | Should -Be 2
        $view.steps[0].subItems[1].label | Should -Be 'DEV: Dev-Main'
    }

    It 'rejects invalid sub-item declarations' {
        $invalidSteps = @([pscustomobject]@{ Name = 'Bad'; SubItems = { $null }; Action = {} })
        { Get-SetupWebWizardView -Title 'Bad' -Steps $invalidSteps -CompletedSteps ([bool[]]@($false)) -LockedSteps ([bool[]]@($false)) -FurthestStepIndex 0 -CurrentStepIndex 0 -RequireSequentialSteps $false -AllStepsCompleted $false } |
            Should -Throw '*null SubItems entry*'

        $missingProperties = @([pscustomobject]@{ Name = 'Bad'; SubItems = { [pscustomobject]@{ Label = 'missing' } }; Action = {} })
        { Get-SetupWebWizardView -Title 'Bad' -Steps $missingProperties -CompletedSteps ([bool[]]@($false)) -LockedSteps ([bool[]]@($false)) -FurthestStepIndex 0 -CurrentStepIndex 0 -RequireSequentialSteps $false -AllStepsCompleted $false } |
            Should -Throw '*must have Label, Depth, and Target*'

        $invalidDepth = @([pscustomobject]@{ Name = 'Bad'; SubItems = { [pscustomobject]@{ Label = 'nested'; Depth = 0; Target = 'target' } }; Action = {} })
        { Get-SetupWebWizardView -Title 'Bad' -Steps $invalidDepth -CompletedSteps ([bool[]]@($false)) -LockedSteps ([bool[]]@($false)) -FurthestStepIndex 0 -CurrentStepIndex 0 -RequireSequentialSteps $false -AllStepsCompleted $false } |
            Should -Throw '*invalid SubItems entry*'
    }

    It 'records apply failure details for the board notice' {
        $errorRecord = [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new('apply exploded'),
            'ApplyError',
            [System.Management.Automation.ErrorCategory]::OperationStopped,
            $null
        )
        Write-SetupWebWizardApplyFailure -OperationName 'Apply changes' -ErrorRecord $errorRecord
        (Get-Variable -Name 'SetupWebWizardNotice' -Scope Script -ValueOnly) | Should -Match 'apply exploded'
        @((Get-SetupWebStatePayload).activity | Where-Object { $_.text -match 'Apply failed' }).Count | Should -BeGreaterThan 0
    }
}

Describe 'Browser change review and display helpers' {
    BeforeEach {
        [Alm4DataverseSetupWebTestActions]::Queue.Clear()
        Mock Read-SetupWebAction {
            if ([Alm4DataverseSetupWebTestActions]::Queue.Count -gt 0) { return [Alm4DataverseSetupWebTestActions]::Queue.Dequeue() }
            throw [System.OperationCanceledException]::new('No queued test action.')
        }
        $script:publishedPrompts = [System.Collections.Generic.List[object]]::new()
        Mock Publish-SetupWebPrompt {
            $script:publishedPrompts.Add($Prompt)
            return [string]$Prompt['id']
        }
        $script:SetupWebPendingBlocks = @()
        $script:SetupWebPendingGuidance = $null
        $script:SetupWebCaptureBlocks = $null
    }

    It 'captures repository files, resources, tables and metrics' {
        Show-SetupWebFileChangeSummary -FileChanges @(
            [pscustomobject]@{ Path = 'b.yml'; Status = 'Added' }
            [pscustomobject]@{ Path = 'a.yml'; Status = 'Modified' }
        )
        Show-SetupWebResourceChangeSummary -ResourceChanges @(
            [pscustomobject]@{ Action = 'Create'; Resource = 'Pipeline'; Target = 'app-BUILD'; Details = 'Deferred' }
        ) -Note 'Note text'
        Show-SetupWebKeyValueSummaryTable -Heading 'Summary' -Values ([ordered]@{ Repository = 'app' })
        $metricCards = @(
            @{ Label = 'Selected'; Value = '2'; Detail = 'Chosen' }
            [pscustomobject]@{ Label = 'Pending'; Value = '1'; Detail = 'Remaining' }
        )
        Show-SetupWebMetricCard -Cards $metricCards
        Show-SetupWebFilePreview -Path 'alm-config.psd1' -Content "line one`r`nline two`r`n"

        $blocks = @(Get-SetupWebContentQueue)
        $blocks.Count | Should -Be 5
        $blocks[0].files[0].path | Should -Be 'a.yml'
        $blocks[1].items[0].resource | Should -Be 'Pipeline'
        $blocks[2].values[0].label | Should -Be 'Repository'
        $blocks[3].cards.Count | Should -Be 2
        $blocks[4].content | Should -Be "line one`r`nline two"
    }

    It 'rejects incomplete resource descriptions and accepts empty lists' {
        { Show-SetupWebResourceChangeSummary -ResourceChanges @([pscustomobject]@{ Action = 'Create'; Resource = 'Pipeline' }) } |
            Should -Throw "*missing required 'Target'*"
        Show-SetupWebFileChangeSummary -FileChanges @()
        Show-SetupWebResourceChangeSummary -ResourceChanges @()
        $blocks = @(Get-SetupWebContentQueue)
        $blocks[0].files.Count | Should -Be 0
        $blocks[1].items.Count | Should -Be 0
    }

    It 'projects branch and environment tables without secrets' {
        Show-SetupWebBranchEnvironmentMappingTable -BranchMappings @()
        $mapping = [pscustomobject]@{
            BranchName = 'main'
            DevEnvironmentConfiguration = [pscustomobject]@{ ShortName = 'DEV' }
            Environments = @([pscustomobject]@{ ShortName = 'TEST' }, [pscustomobject]@{ FriendlyName = 'Production' })
            BuildValidationEnabled = $true
            BuildValidationEnvironmentName = 'BUILD'
            BuildValidationBaselineRelease = 'v1.0.0'
        }
        Show-SetupWebBranchEnvironmentMappingTable -BranchMappings @($mapping)
        Show-SetupWebEnvironmentConfigurationTable -EnvironmentConfigurations @()
        Show-SetupWebEnvironmentConfigurationTable -EnvironmentConfigurations @(
            [pscustomobject]@{
                ShortName = 'DEV'
                FriendlyName = 'Development'
                Url = 'https://dev.example.com'
                Credentials = [pscustomobject]@{ AuthType = 'WIF'; Name = 'app' }
                ServiceAccountUPN = 'service@example.com'
            }
        )
        $blocks = @(Get-SetupWebContentQueue)
        $blocks.Count | Should -Be 4
        $blocks[1].rows[0][2] | Should -Be 'TEST, Production'
        $blocks[1].rows[0][3] | Should -Match 'v1.0.0'
        $blocks[3].rows[0][0] | Should -Be 'DEV'
    }

    It 'renders a changed and an unchanged file diff' {
        $change = [pscustomobject]@{ Path = 'a.txt'; Status = 'Modified'; BeforeContent = "one`ntwo"; AfterContent = "one`nthree" }
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'diff'; operation = 'close' })
        Show-SetupWebSideBySideDiff -FileChanges @($change)
        $script:publishedPrompts[0].kind | Should -Be 'diff'
        $script:publishedPrompts[0].rows.Count | Should -BeGreaterThan 0

        $unchanged = [pscustomobject]@{ Path = 'b.txt'; Status = 'Modified'; BeforeContent = 'same'; AfterContent = 'same' }
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'back' })
        Show-SetupWebSideBySideDiff -FileChanges @($unchanged)
        $script:publishedPrompts[1].rows[0].type | Should -Be 'Notice'

        Show-SetupWebSideBySideDiff -FileChanges @()
        { Show-SetupWebSideBySideDiff -FileChanges @($change, $change) } | Should -Throw '*one file at a time*'
    }

    It 'reviews files interactively, opens a diff and returns' {
        $change = [pscustomobject]@{ Path = 'a.txt'; Status = 'Modified'; BeforeContent = 'before'; AfterContent = 'after' }
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'review'; operation = 'openFile'; index = 0 })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'diff'; operation = 'close' })
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'review'; operation = 'done' })
        Show-SetupWebChangeReview -FileChanges @($change) -SummaryAction {
            Show-SetupWebKeyValueSummaryTable -Heading 'Setup summary' -Values @{ Repository = 'app' }
        }
        $script:publishedPrompts[0].kind | Should -Be 'review'
        $script:publishedPrompts[0].title | Should -Be 'Review setup changes'
        $script:publishedPrompts[0].files[0].path | Should -Be 'a.txt'
    }

    It 'labels preview mode and skips an interactive surface when requested' {
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'review'; operation = 'done' })
        Show-SetupWebChangeReview -FileChanges @([pscustomobject]@{ Path = 'a.txt'; Status = 'Added'; BeforeContent = $null; AfterContent = 'x' }) -PreviewOnly -SummaryAction { }
        $script:publishedPrompts[0].title | Should -Be 'Preview setup changes'
        $script:publishedPrompts[0].doneLabel | Should -Be 'Done previewing'

        $publishedCount = $script:publishedPrompts.Count
        Show-SetupWebChangeReview -FileChanges @() -SkipReview -SummaryAction { }
        $script:publishedPrompts.Count | Should -Be $publishedCount
    }

    It 'publishes completion details, next-step forms and a stop screen' {
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'complete'; operation = 'ack' })
        Show-SetupWebCompletionScreen `
            -Heading 'Completed' `
            -AccessLabel 'Open project' `
            -AccessUrl 'https://example.com/project' `
            -SummaryValues ([ordered]@{ Repository = 'app'; Branches = '2' }) `
            -NextStepLinks @(
                'https://example.com/plain',
                @{ Url = 'https://example.com/label'; Label = 'Labeled' },
                @{ Url = 'https://example.com/description'; Description = 'Described' },
                @{ Url = 'https://example.com/text'; Text = 'Textual' },
                @{ Label = 'Missing URL' }
            )
        $prompt = (Get-SetupWebStatePayload).prompt
        $prompt.kind | Should -Be 'complete'
        $prompt.summary.Count | Should -Be 2
        $prompt.nextSteps.Count | Should -Be 4
        $prompt.nextSteps[0].label | Should -Be 'https://example.com/plain'
        $prompt.nextSteps[1].label | Should -Be 'Labeled'
        $prompt.nextSteps[2].label | Should -Be 'Described'
        $prompt.nextSteps[3].label | Should -Be 'Textual'
        (Get-SetupWebStatePayload).finished | Should -BeTrue

        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'stopped'; operation = 'ack' })
        Show-SetupWebStopScreen -Title 'Stopped' -Message 'Nothing applied.'
        (Get-SetupWebStatePayload).prompt.kind | Should -Be 'stopped'
    }

    It 'tolerates a missing completion acknowledgement' {
        Mock Read-SetupWebAction { throw [System.OperationCanceledException]::new('window closed') }
        Show-SetupWebCompletionScreen -Heading 'Done' -AccessLabel 'Open' -AccessUrl 'https://example.com'
        (Get-SetupWebStatePayload).prompt.kind | Should -Be 'complete'
    }

    It 'keeps status-bar, dashboard and guidance compatibility helpers quiet' {
        Show-SetupWebStatusBar -PromptKind 'Menu' -SearchEnabled -StatusDetail 'rows 1-2'
        Clear-SetupWebStatusBar
        Write-SetupWebDashboard -Message 'Dashboard heading' -IncludeTrailingSpacer -ShowProductBrand
        (Get-SetupWebStatePayload).section | Should -Be 'Dashboard heading'
        Show-SetupWebPromptGuidance -PromptText 'No guidance' -GuidanceLines @() | Should -BeNullOrEmpty
        { Write-SetupWebGuidance -Header 'Header' -Lines @('line') -SkipContextUpdate } | Should -Not -Throw
        { Write-SetupWebGuidance -Header '   ' -Lines @('line') -SkipContextUpdate } | Should -Throw '*non-empty header*'
    }

    It 'mirrors console output into activity and forwards it to the host' {
        Write-SetupWebHost -Object 'plain message'
        Write-SetupWebHost -Object @('first', 'second') -Separator ':' -ForegroundColor Yellow -NoNewline
        Write-SetupWebHost -Object 'error message' -ForegroundColor Red -BackgroundColor Black
        $activity = @((Get-SetupWebStatePayload).activity)
        @($activity | Where-Object { $_.text -eq 'first:second' })[0].tone | Should -Be 'warn'
        @($activity | Where-Object { $_.text -eq 'error message' })[0].tone | Should -Be 'error'
    }
}

Describe 'Browser status and error handling' {
    BeforeEach {
        [Alm4DataverseSetupWebTestActions]::Queue.Clear()
        Mock Read-SetupWebAction {
            if ([Alm4DataverseSetupWebTestActions]::Queue.Count -gt 0) { return [Alm4DataverseSetupWebTestActions]::Queue.Dequeue() }
            throw [System.OperationCanceledException]::new('No queued test action.')
        }
        $script:publishedPrompts = [System.Collections.Generic.List[object]]::new()
        Mock Publish-SetupWebPrompt {
            $script:publishedPrompts.Add($Prompt)
            return [string]$Prompt['id']
        }
        Clear-SetupWizardContext
        Remove-Variable -Name 'headlessMode' -Scope Script -ErrorAction SilentlyContinue
    }

    AfterEach {
        Clear-SetupWizardContext
        Remove-Variable -Name 'headlessMode' -Scope Script -ErrorAction SilentlyContinue
    }

    It 'runs status callbacks with and without captured output' {
        Invoke-SetupWebStatus -Status 'Simple' -ScriptBlock { 42 } | Should -Be 42
        $captured = Invoke-SetupWebStatus -Status 'Captured' -CaptureOutputInPanel -ScriptBlock {
            Write-Host 'host output'
            Write-Warning 'warning output'
            Write-Verbose 'verbose output'
            Write-Debug 'debug output'
            Write-Output 'string output'
            [pscustomobject]@{ Result = 'ok' }
        }
        $captured.Result | Should -Be 'ok'
        $activity = @((Get-SetupWebStatePayload).activity)
        @($activity | Where-Object { $_.text -eq 'warning output' }).Count | Should -BeGreaterThan 0
        @($activity | Where-Object { $_.text -eq 'host output' }).Count | Should -BeGreaterThan 0

        { Invoke-SetupWebStatus -Status 'Failure' -CaptureOutputInPanel -ScriptBlock { throw 'captured failure' } } |
            Should -Throw '*captured failure*'
    }

    It 'falls back to direct execution without a host and keeps back navigation' {
        $savedHost = Get-SetupWebHost
        try {
            $script:SetupWebHost = $null
            Invoke-SetupWebStatus -Status 'No host' -ScriptBlock { 'direct' } | Should -Be 'direct'
        }
        finally {
            $script:SetupWebHost = $savedHost
        }

        Set-SetupWizardContext -Title 'Wizard' -StepNames @('Step') -CurrentStepIndex 0
        { Invoke-SetupWebStatus -Status 'Back' -ScriptBlock { Request-SetupWizardBack } } |
            Should -Throw '*__ALM4DATAVERSE_WIZARD_BACK__*'
    }

    It 'publishes an unhandled entrypoint failure to the stop screen' {
        Mock Get-SetupWebHost { [pscustomobject]@{} }
        Mock Add-SetupWebActivity {}
        Mock Show-SetupWebStopScreen {}
        $errorRecord = [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new('branch validation exploded'),
            'BranchValidation',
            [System.Management.Automation.ErrorCategory]::InvalidData,
            $null
        )

        Show-SetupWebFailure -Title 'Setup failed' -ErrorRecord $errorRecord

        Should -Invoke Add-SetupWebActivity -Times 1 -Exactly -ParameterFilter {
            $Text -match 'branch validation exploded' -and $Tone -eq 'error'
        }
        Should -Invoke Show-SetupWebStopScreen -Times 1 -Exactly -ParameterFilter {
            $Title -eq 'Setup failed' -and $Message -match 'branch validation exploded'
        }
    }

    It 'offers retry, skip and abort after an error' {
        $script:attempts = 0
        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'error'; value = 'retry' })
        $result = Invoke-SetupWebErrorHandling -OperationName 'Retry operation' -AllowSkip -ScriptBlock {
            $script:attempts++
            if ($script:attempts -eq 1) { throw 'first failure' }
            'recovered'
        }
        $result | Should -Be 'recovered'
        $script:publishedPrompts[0].kind | Should -Be 'error'
        $script:publishedPrompts[0].options.Count | Should -Be 3

        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'error'; value = 'skip' })
        Invoke-SetupWebErrorHandling -OperationName 'Skip operation' -AllowSkip -ScriptBlock { throw 'skip failure' } |
            Should -BeNullOrEmpty

        [Alm4DataverseSetupWebTestActions]::Queue.Enqueue([pscustomobject]@{ action = 'error'; value = 'abort' })
        { Invoke-SetupWebErrorHandling -OperationName 'Abort operation' -ScriptBlock { throw 'abort failure' } } |
            Should -Throw '*Setup aborted by user after error*'
    }

    It 'propagates back and interrupt exceptions without a retry card' {
        Set-SetupWizardContext -Title 'Wizard' -StepNames @('Step') -CurrentStepIndex 0
        { Invoke-SetupWebErrorHandling -OperationName 'Back operation' -ScriptBlock { Request-SetupWizardBack } } |
            Should -Throw '*__ALM4DATAVERSE_WIZARD_BACK__*'

        $script:publishedBefore = $script:publishedPrompts.Count
        { Invoke-SetupWebErrorHandling -OperationName 'Cancel operation' -ScriptBlock { throw [System.OperationCanceledException]::new('user cancelled') } } |
            Should -Throw '*user cancelled*'
        $script:publishedPrompts.Count | Should -Be $script:publishedBefore
    }

    It 'rethrows unattended headless failures without drawing a prompt' {
        $script:headlessMode = $true
        { Invoke-SetupWebErrorHandling -OperationName 'Headless operation' -ScriptBlock { throw 'headless failure' } } |
            Should -Throw '*headless failure*'
        $script:publishedPrompts.Count | Should -Be 0
    }

    It 'runs a status message through the capture path' {
        Invoke-SetupWebErrorHandling -OperationName 'Status operation' -StatusMessage 'Working' -CaptureOutputInPanel -ScriptBlock {
            Write-Host 'status output'
            'status result'
        } | Should -BeNullOrEmpty
        @((Get-SetupWebStatePayload).activity | Where-Object { $_.text -eq 'status result' }).Count | Should -BeGreaterThan 0
    }
}
