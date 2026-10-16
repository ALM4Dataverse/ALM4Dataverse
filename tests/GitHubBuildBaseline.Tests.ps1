BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $script:githubBaselineScript = Join-Path $repoRoot '.github/actions/common/deploy-build-validation.ps1'
    function gh {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Arguments', Justification = 'Mock command signature; Pester inspects these arguments.')]
        param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    }
}

Describe 'GitHub baseline package selection and deployment order' {
    BeforeEach {
        $script:savedBaselineEnvironment = @{ RUNNER_TEMP = $env:RUNNER_TEMP; GITHUB_TOKEN = $env:GITHUB_TOKEN; GITHUB_REPOSITORY = $env:GITHUB_REPOSITORY; GH_TOKEN = $env:GH_TOKEN }
        $script:savedBaselineExitCode = $global:LASTEXITCODE
        $env:RUNNER_TEMP = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $env:GITHUB_TOKEN = 'fake-test-token'
        $env:GITHUB_REPOSITORY = 'example/repository'
        $script:candidatePath = Join-Path $env:RUNNER_TEMP 'candidate'
        $baselineSource = Join-Path $env:RUNNER_TEMP 'baseline-source'
        # Both packages expose a recording-only deploy entry point, so archive extraction and
        # invocation order are exercised without importing solutions into a live environment.
        foreach ($packagePath in @($script:candidatePath, $baselineSource)) {
            $deployPath = Join-Path $packagePath 'alm/pipelines/scripts/deploy.ps1'
            New-Item -ItemType Directory -Path (Split-Path $deployPath -Parent) -Force | Out-Null
            Set-Content -LiteralPath $deployPath -Value @'
param([string]$ArtifactsPath)
Add-Content -LiteralPath (Join-Path $env:RUNNER_TEMP 'deploy-order.log') -Value $ArtifactsPath
'@
        }
        Set-Content (Join-Path $script:candidatePath 'alm-config.psd1') -Value "@{ buildValidation = @{ baselineRelease = 'release-1' } }"
        Compress-Archive -Path (Join-Path $baselineSource '*') -DestinationPath (Join-Path $env:RUNNER_TEMP 'baseline.zip')
        Mock Invoke-RestMethod {
            $release = [pscustomobject]@{
                tag_name = 'release-1'
                prerelease = $true
                body = "<!-- alm4dataverse-build-branch:main -->`nBuild: release-1`nSource commit: $('a' * 40)`nBUILD run: [123](https://example/run/123)"
                assets = @([pscustomobject]@{ name = 'artifacts.zip' })
            }
            if ($Uri -match '/releases/tags/') { return $release }
            if ($Uri -match '/releases\?' -and $Uri -match 'page=1$') { return @($release) }
            if ($Uri -match '/git/ref/tags/') { return @{ object = @{ type = 'tag'; sha = 'tag-sha' } } }
            if ($Uri -match '/git/tags/') { return @{ message = "BUILD run: 123`nRelease tag: release-1"; object = @{ type = 'commit'; sha = ('a' * 40) } } }
            @()
        }
        Mock gh {
            $global:LASTEXITCODE = 0
            $directoryIndex = [Array]::IndexOf($Arguments, '--dir')
            Copy-Item -LiteralPath (Join-Path $env:RUNNER_TEMP 'baseline.zip') -Destination (Join-Path $Arguments[$directoryIndex + 1] 'artifacts.zip')
        }
    }

    AfterEach {
        foreach ($name in $script:savedBaselineEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $script:savedBaselineEnvironment[$name])
        }
        $global:LASTEXITCODE = $script:savedBaselineExitCode
    }

    It 'deploys a downloaded baseline before the candidate and removes temporary packages' {
        & $script:githubBaselineScript -ArtifactsPath $script:candidatePath -EnvironmentName TEST
        $order = @(Get-Content (Join-Path $env:RUNNER_TEMP 'deploy-order.log'))
        $order.Count | Should -Be 2
        $order[0] | Should -Match 'alm4dataverse-baseline-'
        $order[1] | Should -Be $script:candidatePath
        @(Get-ChildItem $env:RUNNER_TEMP -Directory -Filter 'alm4dataverse-*').Count | Should -Be 0
        Should -Invoke gh -Times 1 -Exactly
    }

    It 'supports numeric, annotated pointer, and legacy pointer selectors' -ForEach @(
        @{ Selector = '123'; Legacy = $false }
        @{ Selector = '@TEST'; Legacy = $false }
        @{ Selector = '@TEST'; Legacy = $true }
    ) {
        Set-Content (Join-Path $script:candidatePath 'alm-config.psd1') -Value "@{ buildValidation = @{ baselineRelease = '$Selector' } }"
        if ($Legacy) {
            Mock Invoke-RestMethod { @{ object = @{ type = 'commit'; sha = ('a' * 40) } } } -ParameterFilter { $Uri -match '/git/ref/tags/' }
        }
        & $script:githubBaselineScript -ArtifactsPath $script:candidatePath -EnvironmentName TEST
        @(Get-Content (Join-Path $env:RUNNER_TEMP 'deploy-order.log')).Count | Should -Be 2
    }

    It 'deploys only the candidate when baseline configuration or a pointer is missing' -ForEach @(
        @{ Configuration = '@{}'; MissingPointer = $false }
        @{ Configuration = "@{ buildValidation = @{ baselineRelease = '@TEST' } }"; MissingPointer = $true }
    ) {
        Set-Content (Join-Path $script:candidatePath 'alm-config.psd1') -Value $Configuration
        if ($MissingPointer) {
            Mock Invoke-RestMethod { $null } -ParameterFilter { $Uri -match '/git/ref/tags/' }
        }
        & $script:githubBaselineScript -ArtifactsPath $script:candidatePath -EnvironmentName TEST
        @(Get-Content (Join-Path $env:RUNNER_TEMP 'deploy-order.log')) | Should -Be @($script:candidatePath)
        Should -Invoke gh -Times 0 -Exactly
    }

    It 'requires credentials before baseline resolution' {
        $env:GITHUB_TOKEN = ''
        { & $script:githubBaselineScript -ArtifactsPath $script:candidatePath -EnvironmentName TEST } | Should -Throw '*GITHUB_TOKEN and GITHUB_REPOSITORY are required*'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'propagates failed or missing downloads without deploying the candidate' -ForEach @(
        @{ ExitCode = 1; Message = '*Could not download*' }
        @{ ExitCode = 0; Message = '*did not download the expected*' }
    ) {
        Mock gh { $global:LASTEXITCODE = $ExitCode }
        { & $script:githubBaselineScript -ArtifactsPath $script:candidatePath -EnvironmentName TEST } | Should -Throw $Message
        Test-Path (Join-Path $env:RUNNER_TEMP 'deploy-order.log') | Should -BeFalse
        @(Get-ChildItem $env:RUNNER_TEMP -Directory -Filter 'alm4dataverse-*').Count | Should -Be 0
    }

    It 'validates metadata, pointer commits, and traversal selectors' {
        . $script:githubBaselineScript -ArtifactsPath $script:candidatePath -EnvironmentName TEST
        { Get-ReleaseInformation -Release @{ tag_name = 'bad'; body = 'incomplete' } } | Should -Throw '*complete ALM4Dataverse build metadata*'
        { Resolve-Baseline -Selector '@../PROD' } | Should -Throw '*Invalid BUILD validation baseline*'
        { Resolve-CommitFromTagReference -Reference @{ object = @{ type = 'blob'; sha = 'invalid' } } } | Should -Throw '*does not resolve to a source commit*'
        Resolve-CommitFromTagReference -Reference @{ object = @{ type = 'tag'; sha = 'tag-sha' } } | Should -Be ('a' * 40)
    }

    It 'prefers the branch-suffixed BUILD Release when multiple releases share an identity' {
        . $script:githubBaselineScript -ArtifactsPath $script:candidatePath -EnvironmentName TEST
        $metadataBody = "<!-- alm4dataverse-build-branch:main -->`nBuild: example-main-1`nBranch: main`nSource commit: $('a' * 40)`nBUILD run: [123](https://example/run/123)"
        $buildRelease = @{
            tag_name = 'v1.2.123-main'
            prerelease = $true
            body = "Version: 1.2.123-main`n$metadataBody"
        }
        $nonPrereleaseRelease = @{
            tag_name = 'v1.2.123'
            prerelease = $false
            body = "Version: 1.2.123`n$metadataBody"
        }
        Mock Invoke-GitHubApi {
            if ($RelativePath -match '^releases\?.*page=1$') { return @($buildRelease, $nonPrereleaseRelease) }
            return @()
        }

        (Find-ReleaseForRunId -RunId 123).TagName | Should -Be $buildRelease.tag_name
        (Find-UniqueReleaseForCommit -CommitSha ('a' * 40)).TagName | Should -Be $buildRelease.tag_name
    }

    It 'rejects missing and ambiguous release matches rather than choosing one' {
        . $script:githubBaselineScript -ArtifactsPath $script:candidatePath -EnvironmentName TEST
        Mock Invoke-GitHubApi { @() }
        { Find-ReleaseForRunId -RunId 999 } | Should -Throw '*No GitHub Release was found*'
        Find-UniqueReleaseForCommit -CommitSha ('b' * 40) | Should -BeNullOrEmpty
        Mock Invoke-GitHubApi {
            if ($RelativePath -match 'page=1$') {
                $release = @{ tag_name = 'release-1'; prerelease = $true; body = "<!-- alm4dataverse-build-branch:main -->`nBuild: release-1`nSource commit: $('a' * 40)`nBUILD run: [123](https://example/run/123)" }
                @($release, $release, @{ tag_name = 'invalid'; body = '' })
            }
        }
        { Find-ReleaseForRunId -RunId 123 } | Should -Throw '*Multiple GitHub Releases*'
        { Find-UniqueReleaseForCommit -CommitSha ('a' * 40) } | Should -Throw '*Multiple successful BUILD releases*'
    }

    It 'resolves one valid release tag from noisy baseline output and rejects ambiguous tags' {
        . $script:githubBaselineScript -ArtifactsPath $script:candidatePath -EnvironmentName TEST
        Mock Get-ReleaseByTag {
            if ($TagName -eq 'release-1') {
                @{ tag_name = 'release-1'; body = "<!-- alm4dataverse-build-branch:main -->`nBuild: release-1`nSource commit: $('a' * 40)`nBUILD run: [123](https://example/run/123)" }
            }
        }
        Resolve-BaselineReleaseTag -Baseline @{ RunId = '123'; TagName = "noise`nrelease-1" } | Should -Be release-1
        { Resolve-BaselineReleaseTag -Baseline @{ RunId = '123'; TagName = '' } } | Should -Throw '*has no Release tag*'
        { Resolve-BaselineReleaseTag -Baseline @{ RunId = 'invalid'; TagName = 'first second' } } | Should -Throw '*without a valid BUILD run ID*'
        { Resolve-BaselineReleaseTag -Baseline @{ RunId = '123'; TagName = 'first second' } } | Should -Throw '*Could not uniquely resolve*'
    }

    It 'rejects baseline archives that do not contain a deploy entry point' {
        . $script:githubBaselineScript -ArtifactsPath $script:candidatePath -EnvironmentName TEST
        $invalidFile = Join-Path $env:RUNNER_TEMP 'payload.txt'
        $invalidArchive = Join-Path $env:RUNNER_TEMP 'invalid.zip'
        Set-Content $invalidFile -Value 'not a package'
        Compress-Archive -LiteralPath $invalidFile -DestinationPath $invalidArchive
        { Expand-BaselineArchive -ArchivePath $invalidArchive -DestinationPath (Join-Path $env:RUNNER_TEMP 'extracted') } | Should -Throw '*does not contain*deploy.ps1*'
        { Save-BaselineReleaseAsset -ReleaseTag 'first second' -DestinationPath $TestDrive } | Should -Throw '*single non-empty line*'
    }
}