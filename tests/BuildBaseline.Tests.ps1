BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $script:baselineScript = Join-Path $repoRoot 'pipelines/scripts/resolvebuildvalidationbaseline.ps1'
    function git {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        param($Verb, $First, $Second, $Third, [Alias('t')][switch]$TagType, [Alias('p')][switch]$PrintContents)
    }
    # Keep selector cases on the same config/ADO identity so only resolution policy varies.
    function Invoke-BaselineFixture {
        param([string]$Selector)
        $configPath = Join-Path $TestDrive 'alm-config.psd1'
        Set-Content -LiteralPath $configPath -Value "@{ buildValidation = @{ baselineRelease = '$Selector' } }"
        & $script:baselineScript -ConfigPath $configPath -SourceDirectory $TestDrive `
            -CollectionUri 'https://dev.azure.com/example' -Project 'Test Project' -DefinitionId 7 -AccessToken test-token
    }
}

Describe 'Azure DevOps BUILD baseline selection' {
    BeforeEach {
        # Native-command mocks set process-wide exit state just as git would; restore it per case.
        $script:savedExitCode = $global:LASTEXITCODE
        Mock git {
            $global:LASTEXITCODE = 0
            switch ($Verb) {
                'ls-remote' { 'pointer exists' }
                'cat-file' { if ($TagType) { 'tag' } else { 'BUILD run: 123' } }
                'rev-list' { 'a' * 40 }
            }
        }
        Mock Invoke-RestMethod {
            $build = [pscustomobject]@{ id = 123; definition = @{ id = 7 }; status = 'completed'; result = 'succeeded'; buildNumber = 'release-1' }
            [pscustomobject]@{ id = $build.id; definition = $build.definition; status = $build.status; result = $build.result; value = @($build) }
        }
        Mock Invoke-WebRequest {
            $build = @{ id = 123; definition = @{ id = 7 }; status = 'completed'; result = 'succeeded'; sourceVersion = ('a' * 40) }
            @{ StatusCode = 200; Content = (@{ value = @($build) } | ConvertTo-Json -Depth 5); Headers = @{} }
        }
    }

    AfterEach {
        $global:LASTEXITCODE = $script:savedExitCode
    }

    It 'skips baseline deployment when no selector is configured' {
        Invoke-BaselineFixture -Selector ''
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        Should -Invoke git -Times 0 -Exactly
    }

    It 'validates a fixed BUILD run ID' {
        Invoke-BaselineFixture -Selector 123
        Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter { $Uri -match '/builds/123\?api-version=7.1' }
    }

    It 'resolves an exact successful BUILD name' {
        Invoke-BaselineFixture -Selector release-1
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -match 'buildNumber=release-1' }
    }

    It 'rejects missing or ambiguous BUILD names' -ForEach @(
        @{ Matches = @(); Message = '*No successful BUILD run*' }
        @{ Matches = @(@{ id = 1; definition = @{ id = 7 }; status = 'completed'; result = 'succeeded'; buildNumber = 'release-1' }, @{ id = 2; definition = @{ id = 7 }; status = 'completed'; result = 'succeeded'; buildNumber = 'release-1' }); Message = '*More than one successful BUILD run*' }
    ) {
        Mock Invoke-RestMethod { @{ value = $Matches } }
        { Invoke-BaselineFixture -Selector release-1 } | Should -Throw $Message
    }

    It 'rejects BUILD runs from another definition' {
        Mock Invoke-RestMethod { @{ id = 123; definition = @{ id = 8 }; status = 'completed'; result = 'succeeded' } }
        { Invoke-BaselineFixture -Selector 123 } | Should -Throw '*belongs to pipeline definition*'
    }

    It 'rejects unsuccessful BUILD runs' {
        Mock Invoke-RestMethod { @{ id = 123; definition = @{ id = 7 }; status = 'completed'; result = 'failed' } }
        { Invoke-BaselineFixture -Selector 123 } | Should -Throw '*not a successfully completed BUILD run*'
    }

    It 'resolves annotated deployment pointers by BUILD run metadata' {
        Invoke-BaselineFixture -Selector '@TEST'
        Should -Invoke git -Times 1 -Exactly -ParameterFilter { $Verb -eq 'fetch' }
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'uses candidate-only validation when no deployment pointer exists' {
        Mock git { $global:LASTEXITCODE = 2 } -ParameterFilter { $Verb -eq 'ls-remote' }
        Invoke-BaselineFixture -Selector '@TEST'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        $global:LASTEXITCODE | Should -Be 0
    }

    It 'resolves legacy pointers by source commit and pagination' {
        Mock git { $global:LASTEXITCODE = 0; 'commit' } -ParameterFilter { $Verb -eq 'cat-file' }
        Mock Invoke-WebRequest {
            if ($Uri -match 'continuationToken=next') {
                return @{ StatusCode = 200; Content = '{"value":[]}'; Headers = @{} }
            }
            $build = @{ id = 123; definition = @{ id = 7 }; status = 'completed'; result = 'succeeded'; sourceVersion = ('a' * 40) }
            @{ StatusCode = 200; Content = (@{ value = @($build) } | ConvertTo-Json -Depth 5); Headers = @{ 'x-ms-continuationtoken' = 'next' } }
        }
        Invoke-BaselineFixture -Selector '@TEST'
        Should -Invoke Invoke-WebRequest -Times 2 -Exactly
    }

    It 'propagates legacy pointer API failures' {
        Mock git { $global:LASTEXITCODE = 0; 'commit' } -ParameterFilter { $Verb -eq 'cat-file' }
        Mock Invoke-WebRequest { @{ StatusCode = 403; Content = 'Forbidden'; Headers = @{} } }
        { Invoke-BaselineFixture -Selector '@TEST' } | Should -Throw '*HTTP 403*'
    }

    It 'rejects traversal in environment selectors' {
        { Invoke-BaselineFixture -Selector '@../PROD' } | Should -Throw '*Unsupported BUILD validation baseline*'
        Should -Invoke git -Times 0 -Exactly
    }

    It 'fails rather than ignoring pointer fetch failures' {
        Mock git { $global:LASTEXITCODE = 1 } -ParameterFilter { $Verb -eq 'fetch' }
        { Invoke-BaselineFixture -Selector '@TEST' } | Should -Throw '*Could not fetch deployment pointer*'
    }
}