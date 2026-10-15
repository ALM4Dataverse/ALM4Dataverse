BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $script:deploymentResolver = Join-Path $repoRoot '.github/actions/common/resolve-deployment.ps1'
    $policy = Import-PowerShellDataFile (Join-Path $repoRoot 'scripts/powershell-validation.psd1')
    Import-Module powershell-yaml -RequiredVersion $policy.Tools['powershell-yaml']
    $deployAction = Get-Content (Join-Path $repoRoot '.github/actions/deploy/action.yml') -Raw | ConvertFrom-Yaml
    $script:deploymentTagStep = $deployAction.runs.steps | Where-Object { $_.name -eq 'Push deployment tags' }
    function gh {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Arguments', Justification = 'Mock command signature; Pester inspects these arguments.')]
        param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    }
    function Invoke-DeploymentTagStep {
        $run = $script:deploymentTagStep.run
        foreach ($line in Get-Content $env:GITHUB_OUTPUT) {
            $name, $value = $line -split '=', 2
            $run = $run.Replace(('${{ steps.resolve.outputs.' + $name + ' }}'), $value)
        }
        & ([scriptblock]::Create($run))
    }
    function Set-DeploymentDispatchFixture {
        param([string]$Selector = 'release-1', [string]$EventName = 'workflow_dispatch')
        $payload = @{ build_run_id = ''; branch = ''; sha = ''; release_tag = '' }
        if ($EventName -eq 'repository_dispatch') {
            $payload = @{ build_run_id = '123'; branch = 'main'; sha = ('a' * 40); release_tag = 'release-1' }
        }
        $env:INPUT_GITHUB_CONTEXT_JSON = @{
            event_name = $EventName; ref_type = 'branch'; ref_name = 'main'
            event = @{ client_payload = $payload }
        } | ConvertTo-Json -Depth 10
        $env:INPUT_CALLER_INPUTS_JSON = @{ 'build-run-name' = $Selector; 'build-run-id' = ''; 'target-environment' = 'TEST' } | ConvertTo-Json
    }
}

Describe 'GitHub deployment selection and gates' {
    BeforeEach {
        $script:savedDeploymentEnvironment = @{}
        foreach ($name in @('INPUT_ENVIRONMENT_NAME', 'INPUT_PREVIOUS_ENVIRONMENT_NAME', 'INPUT_PROMOTION_MODE', 'INPUT_GITHUB_CONTEXT_JSON', 'INPUT_CALLER_INPUTS_JSON', 'INPUT_TRIGGER_BRANCH', 'GITHUB_OUTPUT', 'GITHUB_TOKEN', 'GITHUB_REPOSITORY')) {
            $script:savedDeploymentEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        $env:INPUT_ENVIRONMENT_NAME = 'TEST'
        $env:INPUT_PREVIOUS_ENVIRONMENT_NAME = 'DEV'
        $env:INPUT_PROMOTION_MODE = 'manual-gate-tag'
        $env:INPUT_TRIGGER_BRANCH = 'main'
        $env:GITHUB_OUTPUT = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.outputs')
        $env:GITHUB_TOKEN = 'fake-test-token'
        $env:GITHUB_REPOSITORY = 'example/repository'
        Set-DeploymentDispatchFixture
        Mock Invoke-RestMethod {
            $run = [pscustomobject]@{ id = 123; path = '.github/workflows/BUILD.yml'; name = 'BUILD'; display_title = 'release-1'; run_name = 'release-1'; head_sha = ('a' * 40); head_branch = 'main'; conclusion = 'success' }
            $release = [pscustomobject]@{ tag_name = 'release-1'; prerelease = $true; body = "<!-- alm4dataverse-build-branch:main -->`nBuild: release-1`nSource commit: $('a' * 40)`nBUILD run: [123](https://example/run/123)"; assets = @([pscustomobject]@{ name = 'artifacts.zip' }) }
            if ($Uri -match '/releases/tags/') { return $release }
            if ($Uri -match '/releases\?' -and $Uri -match 'page=1$') { return @($release) }
            if ($Uri -match '/actions/runs/') { return $run }
            if ($Uri -match '/actions/workflows/' -and $Uri -notmatch 'page=2$') { return @{ workflow_runs = @($run) } }
            if ($Uri -match '/actions/workflows/') { return @{ workflow_runs = @() } }
            if ($Uri -match '/git/ref/tags/') { return @{ object = @{ type = 'tag'; sha = 'tag-sha' } } }
            if ($Uri -match '/git/tags/') { return @{ message = "Build: release-1`nBranch: main`nSource commit: $('a' * 40)`nBUILD run: 123"; object = @{ type = 'commit'; sha = ('a' * 40) } } }
            @()
        }
    }

    AfterEach {
        foreach ($name in $script:savedDeploymentEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $script:savedDeploymentEnvironment[$name])
        }
    }

    It 'resolves fixed release tags and emits promotion gates and artifact source' {
        & $script:deploymentResolver
        $output = Get-Content $env:GITHUB_OUTPUT -Raw
        $output | Should -Match 'build_run_id=123'
        $output | Should -Match 'artifact_source=release'
        $output | Should -Match 'required_gate_tag=deployed/release-1/DEV'
        $output | Should -Match 'success_gate_tag=deployed/release-1/TEST'
        $output | Should -Match 'environment_pointer_tag=deployed/TEST'
    }

    It 'emits gates only for manual promotion while preserving pointers: <Mode>, predecessor <Previous>' -ForEach @(
        @{ Mode = 'manual-gate-tag'; Previous = ''; Required = ''; Success = 'deployed/release-1/TEST' }
        @{ Mode = 'manual-gate-tag'; Previous = 'DEV'; Required = 'deployed/release-1/DEV'; Success = 'deployed/release-1/TEST' }
        @{ Mode = 'environment-approval'; Previous = ''; Required = ''; Success = '' }
        @{ Mode = 'environment-approval'; Previous = 'DEV'; Required = ''; Success = '' }
    ) {
        $env:INPUT_PROMOTION_MODE = $Mode
        $env:INPUT_PREVIOUS_ENVIRONMENT_NAME = $Previous
        & $script:deploymentResolver
        $output = Get-Content $env:GITHUB_OUTPUT
        $output | Should -Contain "required_gate_tag=$Required"
        $output | Should -Contain "success_gate_tag=$Success"
        $output | Should -Contain 'environment_pointer_tag=deployed/TEST'
    }

    It 'allows the source build tag, success gate, and environment pointer to coexist in Git' {
        & $script:deploymentResolver
        $output = Get-Content $env:GITHUB_OUTPUT
        $gateTag = ($output | Where-Object { $_ -like 'success_gate_tag=*' }) -replace '^success_gate_tag=', ''
        $pointerTag = ($output | Where-Object { $_ -like 'environment_pointer_tag=*' }) -replace '^environment_pointer_tag=', ''
        $gitDirectory = Join-Path $TestDrive 'tag-namespace'
        git init --quiet $gitDirectory
        $LASTEXITCODE | Should -Be 0
        git -C $gitDirectory -c user.name=Test -c user.email=test@example.com -c commit.gpgsign=false commit --quiet --allow-empty -m fixture
        $LASTEXITCODE | Should -Be 0
        foreach ($tag in @('release-1', $gateTag, $pointerTag)) {
            git -C $gitDirectory -c tag.gpgsign=false tag $tag
            $LASTEXITCODE | Should -Be 0
        }
        @(git -C $gitDirectory tag --list) | Should -Be @('deployed/TEST', 'deployed/release-1/TEST', 'release-1')
    }

    Context 'Publishing deployment tags' {
        BeforeEach {
            $script:savedTagExitCode = $global:LASTEXITCODE
            Mock gh {
                $global:LASTEXITCODE = 0
                if ($Arguments -contains '/repos/example/repository/git/tags') {
                    return (@{ sha = ('b' * 40) } | ConvertTo-Json)
                }
                '{}'
            }
        }

        AfterEach {
            $global:LASTEXITCODE = $script:savedTagExitCode
        }

        It 'runs publishing when either a gate or environment pointer is requested' {
            $script:deploymentTagStep.if | Should -Be "steps.resolve.outputs.success_gate_tag != '' || steps.resolve.outputs.environment_pointer_tag != ''"
        }

        It 'publishes the annotated pointer and only the requested gate: <Mode>, <EventName>' -ForEach @(
            @{ Mode = 'manual-gate-tag'; EventName = 'workflow_dispatch'; GateCalls = 1; TotalCalls = 4 }
            @{ Mode = 'environment-approval'; EventName = 'workflow_dispatch'; GateCalls = 0; TotalCalls = 3 }
            @{ Mode = 'environment-approval'; EventName = 'repository_dispatch'; GateCalls = 0; TotalCalls = 3 }
        ) {
            $env:INPUT_PROMOTION_MODE = $Mode
            Set-DeploymentDispatchFixture -EventName $EventName
            & $script:deploymentResolver
            Invoke-DeploymentTagStep
            Should -Invoke gh -Times $TotalCalls -Exactly
            Should -Invoke gh -Times $GateCalls -Exactly -ParameterFilter {
                $Arguments -contains 'ref=refs/tags/deployed/release-1/TEST' -and
                $Arguments -contains "sha=$('a' * 40)"
            }
            Should -Invoke gh -Times 1 -Exactly -ParameterFilter {
                $Arguments -contains 'POST' -and $Arguments -contains '/repos/example/repository/git/tags' -and
                $Arguments -contains 'tag=deployed/TEST' -and $Arguments -contains "object=$('a' * 40)" -and
                $Arguments -contains 'type=commit' -and
                ($Arguments -like 'message=*') -match 'BUILD run: 123\nRelease tag: release-1'
            }
            Should -Invoke gh -Times 1 -Exactly -ParameterFilter {
                $Arguments -contains 'DELETE' -and $Arguments -contains '/repos/example/repository/git/refs/tags/deployed/TEST'
            }
            Should -Invoke gh -Times 1 -Exactly -ParameterFilter {
                $Arguments -contains 'POST' -and $Arguments -contains 'ref=refs/tags/deployed/TEST' -and
                $Arguments -contains "sha=$('b' * 40)"
            }
        }

        It 'continues updating the pointer when the success gate already exists' {
            Mock gh { $global:LASTEXITCODE = 1; '{"message":"Reference already exists"}' } -ParameterFilter {
                $Arguments -contains 'ref=refs/tags/deployed/release-1/TEST'
            }
            & $script:deploymentResolver
            Invoke-DeploymentTagStep
            Should -Invoke gh -Times 1 -Exactly -ParameterFilter { $Arguments -contains 'ref=refs/tags/deployed/TEST' }
        }

        It 'surfaces gate creation failures without moving the pointer' {
            Mock gh { $global:LASTEXITCODE = 1; '{"message":"Reference update failed"}' } -ParameterFilter {
                $Arguments -contains 'ref=refs/tags/deployed/release-1/TEST'
            }
            & $script:deploymentResolver
            { Invoke-DeploymentTagStep } | Should -Throw '*Failed to push gate tag*Reference update failed*'
            Should -Invoke gh -Times 1 -Exactly
        }

        It 'surfaces pointer creation failures in approval mode' {
            $env:INPUT_PROMOTION_MODE = 'environment-approval'
            Mock gh { $global:LASTEXITCODE = 1; '{"message":"Reference update failed"}' } -ParameterFilter {
                $Arguments -contains 'ref=refs/tags/deployed/TEST'
            }
            & $script:deploymentResolver
            { Invoke-DeploymentTagStep } | Should -Throw '*Failed to create environment pointer tag*Reference update failed*'
        }
    }

    It 'resolves numeric selectors, latest managed releases, and repository dispatches' -ForEach @(
        @{ Selector = '123'; EventName = 'workflow_dispatch' }
        @{ Selector = ''; EventName = 'workflow_dispatch' }
        @{ Selector = ''; EventName = 'repository_dispatch' }
    ) {
        Set-DeploymentDispatchFixture -Selector $Selector -EventName $EventName
        & $script:deploymentResolver
        Get-Content $env:GITHUB_OUTPUT -Raw | Should -Match 'build_run_name=release-1'
        Get-Content $env:GITHUB_OUTPUT -Raw | Should -Match 'release_tag=release-1'
    }

    It 'selects the branch-suffixed BUILD Release for a numeric BUILD selector' {
        $metadataBody = "<!-- alm4dataverse-build-branch:main -->`nBuild: example-main-1`nBranch: main`nSource commit: $('a' * 40)`nBUILD run: [123](https://example/run/123)"
        $buildRelease = [pscustomobject]@{
            tag_name = 'v1.2.123-main'
            prerelease = $true
            body = "Version: 1.2.123-main`n$metadataBody"
            assets = @([pscustomobject]@{ name = 'artifacts.zip' })
        }
        $nonPrereleaseRelease = [pscustomobject]@{
            tag_name = 'v1.2.123'
            prerelease = $false
            body = "Version: 1.2.123`n$metadataBody"
            assets = @([pscustomobject]@{ name = 'artifacts.zip' })
        }
        $run = [pscustomobject]@{
            id = 123; path = '.github/workflows/BUILD.yml'; name = 'BUILD'
            display_title = 'example-main-1'; run_name = 'example-main-1'
            head_sha = ('a' * 40); head_branch = 'main'; conclusion = 'success'
        }
        Mock Invoke-RestMethod {
            if ($Uri -match '/releases\?' -and $Uri -match 'page=1$') { return @($buildRelease, $nonPrereleaseRelease) }
            if ($Uri -match '/releases\?' -and $Uri -match 'page=2$') { return @() }
            if ($Uri -match '/actions/runs/') { return $run }
            if ($Uri -match '/git/ref/tags/') { return @{ object = @{ type = 'tag'; sha = 'tag-sha' } } }
            if ($Uri -match '/git/tags/') { return @{ message = 'stable tag'; object = @{ type = 'commit'; sha = ('a' * 40) } } }
            @()
        }
        Set-DeploymentDispatchFixture -Selector '123'

        & $script:deploymentResolver
        Get-Content $env:GITHUB_OUTPUT -Raw | Should -Match 'release_tag=v1\.2\.123-main'
        Get-Content $env:GITHUB_OUTPUT -Raw | Should -Match 'artifact_source=release'
    }

    It 'selects a branch-suffixed BUILD Release by exact BUILD name' {
        $sourceSha = 'a' * 40
        $selectedRelease = [pscustomobject]@{
            tag_name = 'v1.0.43-main'
            prerelease = $true
            body = "<!-- alm4dataverse-build-branch:main -->`nBuild: example-main-43`nSource commit: $sourceSha`nBUILD run: [123](https://example/run/123)"
            assets = @([pscustomobject]@{ name = 'artifacts.zip' })
        }
        $selectedBuildRun = [pscustomobject]@{
            id = 123; path = '.github/workflows/BUILD.yml'; name = 'BUILD'
            display_title = 'example-main-43'; run_name = 'example-main-43'
            head_sha = $sourceSha; head_branch = 'main'; conclusion = 'success'
        }
        Mock Invoke-RestMethod {
            if ($Uri -match '/releases/tags/') { return $null }
            if ($Uri -match '/releases\?' -and $Uri -match 'page=1$') { return @($selectedRelease) }
            if ($Uri -match '/releases\?' -and $Uri -match 'page=2$') { return @() }
            if ($Uri -match '/actions/workflows/') { return @{ workflow_runs = @($selectedBuildRun) } }
            if ($Uri -match '/actions/runs/') { return $selectedBuildRun }
            if ($Uri -match '/git/ref/tags/') { return @{ object = @{ type = 'tag'; sha = 'tag-sha' } } }
            if ($Uri -match '/git/tags/') { return @{ message = ''; object = @{ type = 'commit'; sha = $sourceSha } } }
            @()
        }
        Set-DeploymentDispatchFixture -Selector 'example-main-43'

        & $script:deploymentResolver
        Get-Content $env:GITHUB_OUTPUT -Raw | Should -Match 'build_run_name=example-main-43'
        Get-Content $env:GITHUB_OUTPUT -Raw | Should -Match 'release_tag=v1\.0\.43-main'
        Get-Content $env:GITHUB_OUTPUT -Raw | Should -Match 'artifact_source=release'
    }

    It 'uses the latest managed Release object and its actual branch-suffixed tag' {
        $sourceSha = 'a' * 40
        $latestRelease = [pscustomobject]@{
            tag_name = 'v1.0.43-main'
            prerelease = $true
            body = "<!-- alm4dataverse-build-branch:main -->`nBuild: example-main-43`nSource commit: $sourceSha`nBUILD run: [123](https://example/run/123)"
            assets = @([pscustomobject]@{ name = 'artifacts.zip' })
        }
        $latestBuildRun = [pscustomobject]@{
            id = 123; path = '.github/workflows/BUILD.yml'; name = 'BUILD'
            display_title = 'example-main-43'; run_name = 'example-main-43'
            head_sha = $sourceSha; head_branch = 'main'; conclusion = 'success'
        }
        Mock Invoke-RestMethod {
            if ($Uri -match '/releases\?' -and $Uri -match 'page=1$') { return @($latestRelease) }
            if ($Uri -match '/releases\?' -and $Uri -match 'page=2$') { return @() }
            if ($Uri -match '/actions/runs/') { return $latestBuildRun }
            if ($Uri -match '/git/ref/tags/') { return @{ object = @{ type = 'tag'; sha = 'tag-sha' } } }
            if ($Uri -match '/git/tags/') { return @{ message = ''; object = @{ type = 'commit'; sha = $sourceSha } } }
            @()
        }
        Set-DeploymentDispatchFixture -Selector ''

        & $script:deploymentResolver
        Get-Content $env:GITHUB_OUTPUT -Raw | Should -Match 'build_run_name=example-main-43'
        Get-Content $env:GITHUB_OUTPUT -Raw | Should -Match 'release_tag=v1\.0\.43-main'
        Get-Content $env:GITHUB_OUTPUT -Raw | Should -Match 'artifact_source=release'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Uri -match '/releases/tags/' }
    }

    It 'uses the latest successful branch build when no managed releases exist' {
        Set-DeploymentDispatchFixture -Selector ''
        $env:INPUT_PROMOTION_MODE = 'environment-approval'
        Mock Invoke-RestMethod { @() } -ParameterFilter { $Uri -match '/releases\?' }
        & $script:deploymentResolver
        Get-Content $env:GITHUB_OUTPUT -Raw | Should -Match 'artifact_source=build'
        Get-Content $env:GITHUB_OUTPUT -Raw | Should -Match 'required_gate_tag=\r?\n'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -match 'branch=main&status=success' }
    }

    It 'retains release metadata when the historical workflow run has expired' {
        Mock Invoke-RestMethod { $null } -ParameterFilter { $Uri -match '/actions/runs/' }
        & $script:deploymentResolver
        Get-Content $env:GITHUB_OUTPUT -Raw | Should -Match 'build_run_id=\r?\n'
        Get-Content $env:GITHUB_OUTPUT -Raw | Should -Match 'artifact_source=release'
    }

    It 'uses annotated build metadata when a legacy release tag has no GitHub Release' {
        Mock Invoke-RestMethod { $null } -ParameterFilter { $Uri -match '/releases/tags/' }
        & $script:deploymentResolver
        Get-Content $env:GITHUB_OUTPUT -Raw | Should -Match 'artifact_source=build'
        Get-Content $env:GITHUB_OUTPUT -Raw | Should -Match 'release_tag=release-1'
    }

    It 'rejects incorrect trigger branches and unsupported promotion modes' -ForEach @(
        @{ Trigger = 'other'; Mode = 'manual-gate-tag'; Message = '*does not match trigger-branch*' }
        @{ Trigger = 'main'; Mode = 'unsupported'; Message = '*Unsupported promotion-mode*' }
    ) {
        $env:INPUT_TRIGGER_BRANCH = $Trigger
        $env:INPUT_PROMOTION_MODE = $Mode
        { & $script:deploymentResolver } | Should -Throw $Message
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'rejects unsuccessful and non-BUILD runs' -ForEach @(
        @{ Path = '.github/workflows/BUILD.yml'; Name = 'BUILD'; Conclusion = 'failure'; Message = '*is not successful*' }
        @{ Path = '.github/workflows/EXPORT.yml'; Name = 'EXPORT'; Conclusion = 'success'; Message = '*is not a BUILD run*' }
    ) {
        Mock Invoke-RestMethod { [pscustomobject]@{ id = 123; path = $Path; name = $Name; conclusion = $Conclusion } } -ParameterFilter { $Uri -match '/actions/runs/' }
        { & $script:deploymentResolver } | Should -Throw $Message
    }

    It 'rejects tags whose commit does not match release metadata' {
        Mock Invoke-RestMethod { @{ message = ''; object = @{ type = 'commit'; sha = ('b' * 40) } } } -ParameterFilter { $Uri -match '/git/tags/' }
        { & $script:deploymentResolver } | Should -Throw '*does not match source commit*'
    }

    It 'normalizes gate tags and validates manual branch contexts' {
        . $script:deploymentResolver
        ConvertTo-BuildReleaseTag ' /release..name//branch.lock ' | Should -Be 'release-name/branch-lock'
        ConvertTo-GateTagSegment ' /release--name..//branch.lock ' | Should -Be 'release-name./branch-lock'
        { ConvertTo-BuildReleaseTag '///' } | Should -Throw '*cannot be converted*'
        { ConvertTo-GateTagSegment '...' } | Should -Throw '*cannot be converted*'
        Resolve-WorkflowDispatchBranch -GitHubContext ([pscustomobject]@{ ref = 'refs/heads/topic' }) | Should -Be topic
        { Resolve-WorkflowDispatchBranch -GitHubContext ([pscustomobject]@{ ref = 'refs/tags/v1' }) } | Should -Throw '*branch-based workflow_dispatch*'
        Resolve-WorkflowDispatchBranch -GitHubContext ([pscustomobject]@{}) | Should -Be ''
    }

    It 'resolves run display names and workflow identity from supported properties' {
        . $script:deploymentResolver
        Resolve-BuildRunDisplayName -Run ([pscustomobject]@{ id = 1; run_name = ' Run Name ' }) | Should -Be 'Run Name'
        Resolve-BuildRunDisplayName -Run ([pscustomobject]@{ id = 1; head_branch = 'main'; run_number = 7 }) | Should -Be 'main-7'
        Resolve-BuildRunDisplayName -Run ([pscustomobject]@{ id = 1 }) | Should -Be '1'
        Test-IsBuildWorkflowRun -Run ([pscustomobject]@{ name = ' build ' }) | Should -BeTrue
        Test-IsBuildWorkflowRun -Run ([pscustomobject]@{ path = '.github/workflows/BUILD.yaml@main' }) | Should -BeTrue
        Test-IsBuildWorkflowRun -Run ([pscustomobject]@{ name = 'EXPORT' }) | Should -BeFalse
    }

    It 'finds named runs and rejects missing names or empty successful branch histories' {
        . $script:deploymentResolver
        (Find-BuildRunByName -RunName release-1).id | Should -Be 123
        { Find-BuildRunByName -RunName missing } | Should -Throw '*No BUILD workflow run named*'
        Mock Invoke-GitHubApi { @{ workflow_runs = @() } }
        { Find-LatestSuccessfulBuildRunForBranch -BranchName main } | Should -Throw '*No successful BUILD workflow runs*'
    }

    It 'rejects incomplete metadata and ambiguous releases and ignores unrelated branches' {
        . $script:deploymentResolver
        { Get-ReleaseInformation -Release @{ body = ''; tag_name = 'invalid' } } | Should -Throw '*complete ALM build metadata*'
        Mock Invoke-GitHubApi {
            if ($RelativePath -match 'page=1$') {
                $release = [pscustomobject]@{ tag_name = 'release-1'; prerelease = $true; body = "<!-- alm4dataverse-build-branch:main -->`nBuild: release-1`nSource commit: $('a' * 40)`nBUILD run: [123](https://example/run/123)" }
                @($release, $release, @{ tag_name = 'invalid'; body = '' })
            }
        }
        { Find-ReleaseForBuildRun -RunId 123 } | Should -Throw '*Multiple GitHub Releases*'
        Find-LatestManagedReleaseForBranch -BranchName other | Should -BeNullOrEmpty
        Find-ReleaseForBuildRun -RunId 999 | Should -BeNullOrEmpty
    }
}