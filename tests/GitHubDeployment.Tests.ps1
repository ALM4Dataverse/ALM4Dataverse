BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $script:deploymentResolver = Join-Path $repoRoot '.github/actions/common/resolve-deployment.ps1'
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
            $release = [pscustomobject]@{ tag_name = 'release-1'; body = "<!-- alm4dataverse-build-branch:main -->`nBuild: release-1`nSource commit: $('a' * 40)`nBUILD run: [123](https://example/run/123)"; assets = @([pscustomobject]@{ name = 'artifacts.zip' }) }
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
        $output | Should -Match 'required_gate_tag=release-1/deployed/DEV'
        $output | Should -Match 'environment_pointer_tag=deployed/TEST'
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
        { Get-ReleaseMetadata -Release @{ body = ''; tag_name = 'invalid' } } | Should -Throw '*complete ALM build metadata*'
        Mock Invoke-GitHubApi {
            if ($RelativePath -match 'page=1$') {
                $release = [pscustomobject]@{ tag_name = 'release-1'; body = "<!-- alm4dataverse-build-branch:main -->`nBuild: release-1`nSource commit: $('a' * 40)`nBUILD run: [123](https://example/run/123)" }
                @($release, $release, @{ tag_name = 'invalid'; body = '' })
            }
        }
        { Find-ReleaseForBuildRun -RunId 123 } | Should -Throw '*Multiple GitHub Releases*'
        Find-LatestManagedReleaseForBranch -BranchName other | Should -BeNullOrEmpty
        Find-ReleaseForBuildRun -RunId 999 | Should -BeNullOrEmpty
    }
}