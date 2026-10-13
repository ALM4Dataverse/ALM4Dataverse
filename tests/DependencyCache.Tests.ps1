BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $script:cacheScript = Join-Path $repoRoot 'pipelines/scripts/resolvedependencycache.ps1'
}

Describe 'Dependency cache resolution' {
    BeforeEach {
        $script:savedCacheEnvironment = @{ GITHUB_OUTPUT = $env:GITHUB_OUTPUT; RUNNER_OS = $env:RUNNER_OS }
        $script:cacheDirectory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:cacheDirectory | Out-Null
        $env:GITHUB_OUTPUT = Join-Path $script:cacheDirectory 'output.txt'
        $env:RUNNER_OS = 'Windows'
        Set-Content (Join-Path $script:cacheDirectory 'alm-config.psd1') -Value "@{ scriptDependencies = @{ TestModule = ' PRERELEASE ' }; pacCliVersion = ' 2.7.4 ' }"
    }

    AfterEach {
        foreach ($name in $script:savedCacheEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $script:savedCacheEnvironment[$name])
        }
    }

    It 'produces stable cache keys from normalized version selectors' {
        & $script:cacheScript -BaseDirectory $script:cacheDirectory
        $firstOutput = Get-Content $env:GITHUB_OUTPUT -Raw
        $firstOutput | Should -Match 'module_cache_enabled=true'
        $firstOutput | Should -Match 'pac_cache_key=alm4dataverse-Windows-paccli-[a-f0-9]{64}'
        Remove-Item $env:GITHUB_OUTPUT
        Set-Content (Join-Path $script:cacheDirectory 'alm-config.psd1') -Value "@{ scriptDependencies = @{ TestModule = 'prerelease' }; pacCliVersion = '2.7.4' }"
        & $script:cacheScript -BaseDirectory $script:cacheDirectory
        Get-Content $env:GITHUB_OUTPUT -Raw | Should -Be $firstOutput
    }

    It 'uses locked versions and partitions keys by runner OS' {
        Set-Content (Join-Path $script:cacheDirectory 'scriptDependencies.lock.json') -Value '{"scriptDependencies":{"LockedModule":"1.2.3"},"pacCliVersion":"2.7.4-preview.1"}'
        $env:RUNNER_OS = ''
        . $script:cacheScript -BaseDirectory $script:cacheDirectory
        $output = Get-Content $env:GITHUB_OUTPUT -Raw
        $expectedModuleHash = Get-HashHex -Value 'LockedModule=1.2.3'
        $output | Should -Match "module_cache_key=alm4dataverse-unknown-psmodules-$expectedModuleHash"
        ConvertTo-VersionSpecifier -Value '' | Should -Be latest
        ConvertTo-VersionSpecifier -Value '   ' | Should -Be latest
        ConvertTo-VersionSpecifier -Value ' PRERELEASE ' | Should -Be prerelease
    }

    It 'prints outputs when not running in GitHub Actions' {
        $env:GITHUB_OUTPUT = ''
        Mock Write-Host {}
        & $script:cacheScript -BaseDirectory $script:cacheDirectory
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -eq 'module_cache_enabled=true' }
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -eq 'pac_cache_enabled=true' }
    }

    It 'rejects missing configuration directories and script roots' {
        { & $script:cacheScript -BaseDirectory (Join-Path $TestDrive 'missing') } | Should -Throw '*Base directory*does not exist*'
        { & $script:cacheScript -BaseDirectory $script:cacheDirectory -AlmScriptsRoot $TestDrive } | Should -Throw '*common.ps1 not found*'
    }
}