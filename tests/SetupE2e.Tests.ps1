class SetupE2eFakeTerminal {
    [string[]]$Screen = @()
    [bool]$IsRunning = $true
    [System.Collections.Generic.List[string]]$Sent = [System.Collections.Generic.List[string]]::new()

    [bool]SendText([string]$text) {
        $this.Sent.Add($text)
        if ($text.Contains([string][char]3)) {
            $this.IsRunning = $false
        }
        return $true
    }

    [string[]]ReadScreenText() {
        return $this.Screen
    }

    [void]Dispose() {
        $this.IsRunning = $false
    }
}

class SetupE2eFakeWindow {
    [bool]$Closed = $false

    [void]Close() {
        $this.Closed = $true
    }
}

BeforeAll {
    $repositoryRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repositoryRoot 'tools/SetupE2e/Invoke-SetupE2e.ps1')

    function Initialize-SetupE2eTestSession {
        param(
            [Parameter()][string[]]$Screen = @('prompt >'),
            [Parameter()][string]$RunDirectory = (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))),
            [Parameter()][int]$PollMilliseconds = 5
        )

        [System.IO.Directory]::CreateDirectory((Join-Path $RunDirectory 'screens')) | Out-Null
        [System.IO.Directory]::CreateDirectory((Join-Path $RunDirectory 'images')) | Out-Null
        $recorder = Initialize-SetupE2eRecorder -RunDirectory $RunDirectory -Columns 80 -Rows 24 -Title 'test'
        $terminal = [SetupE2eFakeTerminal]::new()
        $terminal.Screen = $Screen
        $window = [SetupE2eFakeWindow]::new()

        return [pscustomobject]@{
            Terminal               = $terminal
            Window                 = $window
            Recorder               = $recorder
            CaptureImages          = $false
            ScreenPollMilliseconds = $PollMilliseconds
            RunDirectory           = $RunDirectory
            ReadScreen             = { $terminal.Screen }.GetNewClosure()
        }
    }
}

Describe 'Setup E2E configuration' {
    It 'resolves an explicit configuration path and rejects a missing one' {
        $path = Join-Path $TestDrive 'config.psd1'
        Set-Content -LiteralPath $path -Value '@{ azdo = @{}; github = @{}; dataverse = @{}; serviceAccount = "a@example.invalid"; solutionName = "S" }'

        (Get-SetupE2eConfigPath -Path $path) | Should -Be (Resolve-Path -LiteralPath $path).Path
        { Get-SetupE2eConfigPath -Path (Join-Path $TestDrive 'missing.psd1') } | Should -Throw
    }

    It 'falls back to the reserved example configuration when no local file exists' {
        $examplePath = Join-Path $repositoryRoot 'tools/SetupE2e/config.example.psd1'
        $script:SetupE2eScriptRoot = Join-Path $TestDrive 'isolated-tools'
        New-Item -ItemType Directory -Path $script:SetupE2eScriptRoot -Force | Out-Null

        (Get-SetupE2eConfigPath) | Should -Be (Join-Path $script:SetupE2eScriptRoot 'config.example.psd1')
        (Get-SetupE2eConfigPath -Path $examplePath) | Should -Be (Resolve-Path -LiteralPath $examplePath).Path
        $script:SetupE2eScriptRoot = Join-Path $repositoryRoot 'tools/SetupE2e'
    }

    It 'flattens sections into variables and validates required keys' {
        $path = Join-Path $TestDrive 'valid.psd1'
        Set-Content -LiteralPath $path -Value @'
@{
    azdo = @{ organization = 'example-organization'; project = 'Example project' }
    github = @{ owner = 'example-owner' }
    dataverse = @{ dev = @{ name = 'dev'; url = 'https://dev.example.invalid' } }
    serviceAccount = 'automation@example.invalid'
    solutionName = 'ExampleSolution'
}
'@
        $config = Import-SetupE2eConfig -Path $path

        $config.Variables['azdo.organization'] | Should -Be 'example-organization'
        $config.Variables['dataverse.dev.url'] | Should -Be 'https://dev.example.invalid'
        $config.Variables['serviceAccount'] | Should -Be 'automation@example.invalid'

        $invalidPath = Join-Path $TestDrive 'invalid.psd1'
        Set-Content -LiteralPath $invalidPath -Value '@{ azdo = @{}; github = @{}; dataverse = @{}; serviceAccount = "a"; }'
        { Import-SetupE2eConfig -Path $invalidPath } | Should -Throw '*missing ''solutionName''*'

        $sectionPath = Join-Path $TestDrive 'section.psd1'
        Set-Content -LiteralPath $sectionPath -Value '@{ azdo = "text"; github = @{}; dataverse = @{}; serviceAccount = "a"; solutionName = "S" }'
        { Import-SetupE2eConfig -Path $sectionPath } | Should -Throw '*must be a hashtable*'
    }

    It 'expands known placeholders and rejects unknown ones' {
        $variables = [ordered]@{ 'azdo.project' = 'Example project' }
        Expand-SetupE2ePlaceholder -Text 'Use {{ azdo.project }} now' -Variables $variables |
            Should -Be 'Use Example project now'
        { Expand-SetupE2ePlaceholder -Text 'Use {{ missing }}' -Variables $variables } |
            Should -Throw '*not defined*'
    }
}

Describe 'Setup E2E input conversion' {
    It 'keeps special keys atomic and expands readable tokens' {
        $enter = ConvertTo-SetupE2eInputText -Keys 'main{ENTER}'
        $enter | Should -Be "main`r"

        $arrows = ConvertTo-SetupE2eInputText -Keys '{DOWN}{UP}{TAB}{ESC}'
        $arrows | Should -Be "$([char]27)[B$([char]27)[A`t$([char]27)"

        (ConvertTo-SetupE2eInputText -Keys 'a{{b}}c') | Should -Be 'a{b}c'
    }

    It 'rejects malformed and unknown tokens' {
        { ConvertTo-SetupE2eInputText -Keys '{NOPE}' } | Should -Throw '*Unknown key token*'
        { ConvertTo-SetupE2eInputText -Keys 'abc{DOWN' } | Should -Throw '*Unterminated*'
    }

    It 'describes control input and passes printable text through' {
        Get-SetupE2eReadableInput -InputText "`r" | Should -Be '{ENTER}'
        Get-SetupE2eReadableInput -InputText "$([char]27)[B" | Should -Be '{DOWN}'
        Get-SetupE2eReadableInput -InputText 'text' | Should -Be 'text'
        Get-SetupE2eReadableInput -InputText ([string][char]1) | Should -Be '<U+0001>'
    }
}

Describe 'Setup E2E scenarios' {
    BeforeAll {
        $scenarioPath = Join-Path $TestDrive 'scenarios.psd1'
        Set-Content -LiteralPath $scenarioPath -Value @'
@{
    'sample' = @{
        Provider = 'azdo'
        Description = 'Sample scenario'
        SetupArguments = @('-ApplyConfig')
        Steps = @(
            @{ Action = 'Wait'; Text = 'Ready' }
            @{ Action = 'Type'; Text = 'value' }
            @{ Action = 'Keys'; Keys = '{ENTER}' }
            @{ Action = 'Capture'; Label = 'ready' }
            @{ Action = 'Assert'; Text = 'Done' }
            @{ Action = 'Sleep'; Milliseconds = 1 }
            @{ Action = 'Note'; Text = 'finished' }
        )
    }
    'broken' = @{ Steps = @(@{ Action = 'Explode' }) }
    'empty' = @{ Steps = @(@{ Action = 'Wait' }) }
    'nosteps' = @{ Provider = 'azdo' }
}
'@
    }

    It 'resolves a scenario case-insensitively with its metadata' {
        $set = Get-SetupE2eScenarioSet -Path $scenarioPath
        $scenario = Resolve-SetupE2eScenario -Name 'SAMPLE' -ScenarioSet $set

        $scenario.Name | Should -Be 'sample'
        $scenario.Provider | Should -Be 'azdo'
        $scenario.Description | Should -Be 'Sample scenario'
        $scenario.SetupArguments | Should -Be @('-ApplyConfig')
        $scenario.Steps.Count | Should -Be 7
    }

    It 'rejects unknown scenarios and invalid steps before starting a terminal' {
        $set = Get-SetupE2eScenarioSet -Path $scenarioPath
        { Resolve-SetupE2eScenario -Name 'missing' -ScenarioSet $set } | Should -Throw '*Unknown setup E2E scenario*'
        { Resolve-SetupE2eScenario -Name 'broken' -ScenarioSet $set } | Should -Throw '*unsupported action*'
        { Resolve-SetupE2eScenario -Name 'empty' -ScenarioSet $set } | Should -Throw '*Wait requires Text*'
        { Resolve-SetupE2eScenario -Name 'nosteps' -ScenarioSet $set } | Should -Throw '*does not define Steps*'
    }

    It 'lists committed scenarios with descriptions' {
        $committed = Get-SetupE2eScenarioSet
        $committed.Contains('azdo-smoke') | Should -BeTrue
    }
}

Describe 'Setup E2E recording' {
    It 'creates the run layout and sanitizes the label' {
        $runDirectory = Initialize-SetupE2eRunDirectory -Root $TestDrive -Label 'azdo new/repo'

        (Split-Path -Leaf $runDirectory) | Should -Match '^\d{8}-\d{6}-azdo-new-repo$'
        Test-Path -LiteralPath (Join-Path $runDirectory 'screens') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $runDirectory 'images') | Should -BeTrue
    }

    It 'writes a cast header, deduplicates screens and closes with a transcript' {
        $runDirectory = Initialize-SetupE2eRunDirectory -Root $TestDrive -Label 'recorder'
        $recorder = Initialize-SetupE2eRecorder -RunDirectory $runDirectory -Columns 100 -Rows 30 -Title 'Test run'

        (Add-SetupE2eRecorderScreen -Recorder $recorder -Lines @('line one', 'line two')) | Should -BeTrue
        (Add-SetupE2eRecorderScreen -Recorder $recorder -Lines @('line one', 'line two')) | Should -BeFalse
        (Add-SetupE2eRecorderScreen -Recorder $recorder -Lines @('line one changed')) | Should -BeTrue
        Add-SetupE2eRecorderEvent -Recorder $recorder -Kind 'input' -Text '{ENTER}'
        Add-SetupE2eRecorderEvent -Recorder $recorder -Kind 'note' -Text 'Checking output'
        Complete-SetupE2eRecorder -Recorder $recorder -Outcome 'Succeeded' -ExitCode 0

        $castLines = @(Get-Content -LiteralPath (Join-Path $runDirectory 'session.cast'))
        $header = $castLines[0] | ConvertFrom-Json
        $header.version | Should -Be 2
        $header.width | Should -Be 100
        $header.height | Should -Be 30
        $header.title | Should -Be 'Test run'
        $castLines.Count | Should -BeGreaterThan 2
        $castLines[1] | Should -Match '^\[[0-9.]+,"o",'
        @($castLines | Where-Object { $_ -match '"i"' }).Count | Should -Be 1

        $events = @(Get-Content -LiteralPath (Join-Path $runDirectory 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
        @($events | Where-Object kind -eq 'input').text | Should -Be '{ENTER}'
        ($events | Where-Object kind -eq 'end').text | Should -Be 'Succeeded'

        $transcript = Get-Content -LiteralPath (Join-Path $runDirectory 'transcript.md') -Raw
        $transcript | Should -Match 'Setup E2E session'
        $transcript | Should -Match 'Checking output'
        $transcript | Should -Match 'Outcome: Succeeded'
        (Get-Content -LiteralPath (Join-Path $runDirectory 'latest.txt')) | Should -Be @('line one changed')
    }

    It 'rewrites only changed lines and clears removed lines' {
        $full = ConvertTo-SetupE2eAnsiFrame -Lines @('a', 'b')
        $full.StartsWith("$([char]27)[2J$([char]27)[H") | Should -BeTrue

        $diff = ConvertTo-SetupE2eAnsiFrame -Lines @('a', 'changed') -PreviousLines @('a', 'b')
        $diff | Should -Not -Match "1;1H"
        $diff | Should -Match "2;1Hchanged"

        $shorter = ConvertTo-SetupE2eAnsiFrame -Lines @('a') -PreviousLines @('a', 'b')
        $shorter | Should -Match "2;1H$([char]27)\[K"
    }

    It 'writes the interactive state atomically' {
        $session = Initialize-SetupE2eTestSession
        Write-SetupE2eState -Session $session -Status 'ready' -ProcessedSequence 3 -Detail 'waiting'

        $state = Get-Content -LiteralPath (Join-Path $session.RunDirectory 'state.json') -Raw | ConvertFrom-Json
        $state.status | Should -Be 'ready'
        $state.processedSequence | Should -Be 3
        $state.detail | Should -Be 'waiting'
        (Test-Path -LiteralPath (Join-Path $session.RunDirectory 'state.json.tmp')) | Should -BeFalse
        $null = Complete-SetupE2eSession -Session $session -ExitTimeoutSeconds 1
    }
}

Describe 'Setup E2E engine' {
    It 'waits for text, sends typed characters and captures a snapshot' {
        $session = Initialize-SetupE2eTestSession -Screen @('Enter a name >')
        try {
            $steps = @(
                @{ Action = 'Wait'; Text = 'Enter a name' }
                @{ Action = 'Note'; Text = 'typing' }
                @{ Action = 'Type'; Text = 'abc'; TypingDelayMilliseconds = 0 }
                @{ Action = 'Keys'; Keys = '{ENTER}' }
                @{ Action = 'Capture'; Label = 'after-input' }
            )
            Invoke-SetupE2eSequence -Session $session -Steps $steps

            @($session.Terminal.Sent) | Should -Be @('a', 'b', 'c', "`r")
            $snapshot = Get-ChildItem -LiteralPath (Join-Path $session.RunDirectory 'screens') -Filter '*.txt'
            $snapshot.Name | Should -Match '^001-after-input\.txt$'
        }
        finally {
            $null = Complete-SetupE2eSession -Session $session -ExitTimeoutSeconds 1
        }
    }

    It 'expands configuration placeholders in typed text' {
        $session = Initialize-SetupE2eTestSession
        try {
            Invoke-SetupE2eSequence -Session $session -Steps @(
                @{ Action = 'Type'; Text = '{{ value }}'; TypingDelayMilliseconds = 0 }
            ) -Variables ([ordered]@{ value = 'shown' })

            @($session.Terminal.Sent) | Should -Be @('s', 'h', 'o', 'w', 'n')
        }
        finally {
            $null = Complete-SetupE2eSession -Session $session -ExitTimeoutSeconds 1
        }
    }

    It 'reports the visible screen when an assertion times out' {
        $session = Initialize-SetupE2eTestSession -Screen @('Unexpected screen')
        try {
            {
                Invoke-SetupE2eSequence -Session $session -Steps @(
                    @{ Action = 'Assert'; Text = 'Expected prompt'; TimeoutSeconds = 1 }
                )
            } | Should -Throw '*Expected prompt*Unexpected screen*'
        }
        finally {
            $null = Complete-SetupE2eSession -Session $session -ExitTimeoutSeconds 1
        }
    }

    It 'moves the menu highlight to the requested item and activates it' {
        $session = Initialize-SetupE2eTestSession
        $terminal = $session.Terminal
        $session.ReadScreen = {
            if ($terminal.Sent.Count -eq 0) {
                @('  ALM4Dataverse', '> example-org', '  Other')
            }
            else {
                @('  ALM4Dataverse', '  example-org', '> Other')
            }
        }.GetNewClosure()
        try {
            Invoke-SetupE2eSequence -Session $session -Steps @(
                @{ Action = 'Select'; Text = 'Other' }
            )

            @($session.Terminal.Sent) | Should -Be @("$([char]27)[B", "`r")
        }
        finally {
            $null = Complete-SetupE2eSession -Session $session -ExitTimeoutSeconds 1
        }
    }

    It 'filters a searchable menu before activating the requested item' {
        $session = Initialize-SetupE2eTestSession
        $terminal = $session.Terminal
        $session.ReadScreen = {
            if ($terminal.Sent.Count -eq 0) {
                @('Start typing to filter options', '  ALM4Dataverse', '> First', '  Second')
            }
            else {
                @('Start typing to filter options', '  ALM4Dataverse', '> Second')
            }
        }.GetNewClosure()
        try {
            Invoke-SetupE2eSequence -Session $session -Steps @(
                @{ Action = 'Select'; Text = 'Second' }
            )

            @($session.Terminal.Sent) | Should -Be @('S', 'e', 'c', 'o', 'n', 'd', "`r")
        }
        finally {
            $null = Complete-SetupE2eSession -Session $session -ExitTimeoutSeconds 1
        }
    }

    It 'waits for an unrelated prompt to close before navigating a menu' {
        $session = Initialize-SetupE2eTestSession
        $script:menuReads = 0
        $session.ReadScreen = {
            $script:menuReads++
            if ($script:menuReads -lt 4) { @('Service Account UPN >') } else { @('> Service account') }
        }.GetNewClosure()
        try {
            [void](Select-SetupE2eMenuItem -Session $session -Text 'Service account' -SettleMilliseconds 5 -TimeoutSeconds 3)

            @($session.Terminal.Sent)[0] | Should -Be "`r"
        }
        finally {
            $null = Complete-SetupE2eSession -Session $session -ExitTimeoutSeconds 1
        }
    }

    It 'fails a selection when the requested item never becomes highlighted' {
        $session = Initialize-SetupE2eTestSession -Screen @('> ALM4Dataverse', '  example-org')
        try {
            {
                Select-SetupE2eMenuItem -Session $session -Text 'Missing' -MaxSteps 2 -SettleMilliseconds 0 -TimeoutSeconds 1
            } | Should -Throw '*Missing*did not appear*'
        }
        finally {
            $null = Complete-SetupE2eSession -Session $session -ExitTimeoutSeconds 1
        }
    }

    It 'answers an optional prompt only when it is visible' {
        $session = Initialize-SetupE2eTestSession -Screen @('> Continue')
        try {
            Invoke-SetupE2eSequence -Session $session -Steps @(
                @{ Action = 'AnswerIfPresent'; Text = 'Enable optional setting'; Type = 'y'; TimeoutSeconds = 1 }
            )
            @($session.Terminal.Sent).Count | Should -Be 0

            $session.ReadScreen = { @('Enable optional setting? [y/n] (n):') }
            Invoke-SetupE2eSequence -Session $session -Steps @(
                @{ Action = 'AnswerIfPresent'; Text = 'Enable optional setting'; Type = 'y'; TimeoutSeconds = 1 }
            )
            @($session.Terminal.Sent) | Should -Be @('y', "`r")
        }
        finally {
            $null = Complete-SetupE2eSession -Session $session -ExitTimeoutSeconds 1
        }
    }

    It 'stops waiting when the process exits' {
        $session = Initialize-SetupE2eTestSession -Screen @('bye')
        $session.Terminal.IsRunning = $false
        try {
            $lines = Wait-SetupE2eScreenText -Session $session -UntilExit -TimeoutSeconds 1
            ($lines -join [Environment]::NewLine) | Should -Match 'bye'
        }
        finally {
            $null = Complete-SetupE2eSession -Session $session -ExitTimeoutSeconds 1
        }
    }
}

Describe 'Setup E2E HTML viewer' {
    It 'builds a self-contained replay with deduplicated frames and grouped typing' {
        $runDirectory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
        @(
            '{"elapsed":0.5,"kind":"screen","text":"first screen"}'
            '{"elapsed":0.6,"kind":"screen","text":"first screen"}'
            '{"elapsed":1.0,"kind":"input","text":"a"}'
            '{"elapsed":1.1,"kind":"input","text":"b"}'
            '{"elapsed":1.2,"kind":"input","text":"{ENTER}"}'
            '{"elapsed":2.0,"kind":"screen","text":"second <screen>"}'
        ) | Set-Content -LiteralPath (Join-Path $runDirectory 'events.jsonl')

        $path = Write-SetupE2eHtmlViewer -RunDirectory $runDirectory

        $path | Should -Be (Join-Path $runDirectory 'viewer.html')
        $html = Get-Content -LiteralPath $path -Raw
        $html | Should -Match 'first screen'
        $html | Should -Match 'second <screen>'
        $html | Should -Match 'ab'
        $html | Should -Not -Match 'first screen</'
    }

    It 'rejects a run without captured frames' {
        $runDirectory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $runDirectory 'events.jsonl') -Value '{"elapsed":1,"kind":"input","text":"x"}'

        { Write-SetupE2eHtmlViewer -RunDirectory $runDirectory } | Should -Throw '*no screen frames*'
    }
}

Describe 'Setup E2E launcher and completion' {
    It 'writes a launcher that quotes the setup path and arguments' {
        $runDirectory = Initialize-SetupE2eRunDirectory -Root $TestDrive -Label 'launcher'
        $setupPath = Join-Path $TestDrive "setup o'brien.ps1"
        $launcherPath = Write-SetupE2eLauncher `
            -RunDirectory $runDirectory `
            -SetupScriptPath $setupPath `
            -WorkingDirectory $TestDrive `
            -SetupArguments @('-ApplyConfig', 'value with space')

        $content = Get-Content -LiteralPath $launcherPath -Raw
        $content | Should -Match "setup o''brien\.ps1"
        $content | Should -Match "'-ApplyConfig', 'value with space'"
        $content | Should -Match 'SETUP-E2E-EXIT:'
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($launcherPath, [ref]$null, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
    }

    It 'reads the reported exit code and records the outcome' {
        $session = Initialize-SetupE2eTestSession -Screen @('SETUP-E2E-EXIT:0')
        $session.Terminal.IsRunning = $false

        $exitCode = Complete-SetupE2eSession -Session $session -ExitTimeoutSeconds 1

        $exitCode | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $session.RunDirectory 'transcript.md') -Raw) | Should -Match 'Outcome: Succeeded'
    }

    It 'reports a failed exit code and an unreported exit' {
        $failedSession = Initialize-SetupE2eTestSession -Screen @('SETUP-E2E-EXIT:2')
        $failedSession.Terminal.IsRunning = $false
        (Complete-SetupE2eSession -Session $failedSession -ExitTimeoutSeconds 1) | Should -Be 2
        (Get-Content -LiteralPath (Join-Path $failedSession.RunDirectory 'transcript.md') -Raw) | Should -Match 'Failed with exit code 2'

        $unknownSession = Initialize-SetupE2eTestSession -Screen @('no marker')
        $unknownSession.Terminal.IsRunning = $false
        (Complete-SetupE2eSession -Session $unknownSession -ExitTimeoutSeconds 1) | Should -BeNullOrEmpty
        (Get-Content -LiteralPath (Join-Path $unknownSession.RunDirectory 'transcript.md') -Raw) | Should -Match 'Exit code not reported'
    }
}

Describe 'Setup E2E interactive control' {
    It 'executes appended commands once and records state' {
        $session = Initialize-SetupE2eTestSession -Screen @('prompt >')
        $controlPath = Join-Path $session.RunDirectory 'control.jsonl'
        @(
            '{"action":"note","text":"starting"}'
            '{"action":"type","text":"ok","typingDelayMilliseconds":0}'
            '{"action":"capture","label":"typed"}'
            '{"action":"stop"}'
        ) | Set-Content -LiteralPath $controlPath

        try {
            $exitCode = Invoke-SetupE2eInteractiveSession -Session $session -MaxMinutes 1
            $exitCode | Should -BeNullOrEmpty
            @($session.Terminal.Sent) | Select-Object -First 2 | Should -Be @('o', 'k')
            @(Get-ChildItem -LiteralPath (Join-Path $session.RunDirectory 'screens') -Filter '*.txt').Count | Should -Be 1

            $events = @(Get-Content -LiteralPath (Join-Path $session.RunDirectory 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
            @($events | Where-Object { $_.kind -eq 'note' }).text | Should -Contain 'starting'

            $offset = 0
            $first = Read-SetupE2eControlCommand -RunDirectory $session.RunDirectory -Offset ([ref]$offset)
            $first.Commands.Count | Should -Be 4
            $second = Read-SetupE2eControlCommand -RunDirectory $session.RunDirectory -Offset ([ref]$offset)
            $second.Commands.Count | Should -Be 0

            Add-Content -LiteralPath $controlPath -Value '{"action":"note","text":"later"}'
            $third = Read-SetupE2eControlCommand -RunDirectory $session.RunDirectory -Offset ([ref]$offset)
            $third.Commands.Count | Should -Be 1
            $third.Commands[0].text | Should -Be 'later'
        }
        finally {
            if ($session.Terminal.IsRunning) {
                $null = Complete-SetupE2eSession -Session $session -ExitTimeoutSeconds 1 -Terminate
            }
        }
    }

    It 'selects a highlighted menu item from a control command' {
        $session = Initialize-SetupE2eTestSession -Screen @('  ALM4Dataverse', '> example-org')
        $controlPath = Join-Path $session.RunDirectory 'control.jsonl'
        @(
            '{"action":"select","text":"example-org"}'
            '{"action":"stop"}'
        ) | Set-Content -LiteralPath $controlPath

        try {
            $null = Invoke-SetupE2eInteractiveSession -Session $session -MaxMinutes 1
            @($session.Terminal.Sent)[0] | Should -Be "`r"
        }
        finally {
            if ($session.Terminal.IsRunning) {
                $null = Complete-SetupE2eSession -Session $session -ExitTimeoutSeconds 1 -Terminate
            }
        }
    }

    It 'rejects malformed control lines and unsupported actions' {
        $session = Initialize-SetupE2eTestSession
        try {
            $offset = 0
            Set-Content -LiteralPath (Join-Path $session.RunDirectory 'control.jsonl') -Value '{"action":"unknown"}'
            $read = Read-SetupE2eControlCommand -RunDirectory $session.RunDirectory -Offset ([ref]$offset)
            $read.Commands.Count | Should -Be 1

            Set-Content -LiteralPath (Join-Path $session.RunDirectory 'control.jsonl') -Value 'not json'
            $offset = 0
            { Read-SetupE2eControlCommand -RunDirectory $session.RunDirectory -Offset ([ref]$offset) } |
                Should -Throw '*Invalid interactive command*'
        }
        finally {
            $null = Complete-SetupE2eSession -Session $session -ExitTimeoutSeconds 1 -Terminate
        }
    }

    It 'passes the live process environment to the terminal' {
        $environment = Get-SetupE2eTerminalEnvironment
        $environment['TERM'] | Should -Be 'xterm-256color'
        # Windows exposes the process path as 'Path', not 'PATH'.
        @($environment.Keys | Where-Object { $_ -ieq 'PATH' }).Count | Should -Be 1
    }
}
