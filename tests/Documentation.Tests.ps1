BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $script:documentationChecker = Join-Path $repoRoot '.github/scripts/test-documentation.ps1'
    $policy = Import-PowerShellDataFile (Join-Path $repoRoot 'scripts/powershell-validation.psd1')
    Import-Module powershell-yaml -RequiredVersion $policy.Tools['powershell-yaml']
}

Describe 'Documentation validation' {
    BeforeEach {
        $script:documentRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:documentRoot -Force | Out-Null
    }

    It 'validates repository links, examples and configuration references' {
        { & $script:documentationChecker } | Should -Not -Throw
    }

    It 'accepts local anchors, escaped paths and valid fenced examples without fetching external links' {
        $target = Join-Path $script:documentRoot 'target file.md'
        Set-Content -LiteralPath $target -Value '# Target heading'
        $path = Join-Path $script:documentRoot 'valid.md'
        Set-Content -LiteralPath $path -Value @(
            '# Fixture'
            '[Local](target%20file.md#target-heading)'
            '[Self](#fixture)'
            '[External](https://example.invalid/unavailable)'
            '```powershell'
            'Get-Item .'
            '```'
            '```yaml'
            'key: value'
            '```'
            '```json'
            '{"key": true}'
            '```'
        )
        { & $script:documentationChecker -Paths $path -SkipCoverage } | Should -Not -Throw
    }

    It 'rejects <Label>' -ForEach @(
        @{ Label = 'missing local files'; Text = '[Missing](missing.md)'; Message = '*missing link target*' }
        @{ Label = 'missing heading anchors'; Text = "# Fixture`n[Missing](#missing)"; Message = '*missing heading*' }
        @{ Label = 'malformed PowerShell'; Text = (@('```powershell', 'if (', '```') -join "`n"); Message = '*invalid powershell example*' }
        @{ Label = 'malformed YAML'; Text = (@('```yaml', 'key: [unclosed', '```') -join "`n"); Message = '*invalid yaml example*' }
        @{ Label = 'malformed JSON'; Text = (@('```json', '{invalid', '```') -join "`n"); Message = '*invalid json example*' }
    ) {
        $path = Join-Path $script:documentRoot 'invalid.md'
        Set-Content -LiteralPath $path -Value $Text
        { & $script:documentationChecker -Paths $path -SkipCoverage } | Should -Throw $Message
    }
}