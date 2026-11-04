BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $e2eRoot = Join-Path $repoRoot '.github/scripts/e2e'
    Import-Module (Join-Path $e2eRoot 'E2E.psm1') -Force

    # Fail closed at external boundaries. Stubs are created from text so the
    # module resolves them globally and Pester can mock them by parameter name.
    $script:stubbedCommands = @{
        'Get-DataverseConnection' = 'param($Url, [switch]$DefaultAzureCredential)'
        'Get-DataverseRecord'     = 'param($Connection, $TableName, $FilterValues, $Columns)'
        'Set-DataverseRecord'     = 'param([Parameter(ValueFromPipeline)]$InputObject, $Connection, $TableName, $Id, [switch]$NoCreate)'
        'gh'                      = ''
        'az'                      = ''
    }
    foreach ($name in $script:stubbedCommands.Keys) {
        $body = $script:stubbedCommands[$name] + " throw 'Unexpected live $name call.'"
        Set-Item -Path "Function:global:$name" -Value ([scriptblock]::Create($body))
    }

    function Initialize-E2EFixtureRepository {
        param([string]$Version = '1.0.0.1')

        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $root 'solutions/ALM4DataverseE2E/Other') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'solutions/ALM4DataverseE2E/Other/Solution.xml') -Value "<ImportExportXml><SolutionManifest><Version>$Version</Version></SolutionManifest></ImportExportXml>"
        New-Item -ItemType Directory -Path (Join-Path $root 'stale/nested') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'stale/nested/leftover.txt') -Value 'old'
        Set-Content -LiteralPath (Join-Path $root '.github-leftover.yml') -Value 'old'
        & git -C $root init --quiet --initial-branch main
        & git -C $root add -A
        & git -C $root -c user.name=test -c user.email=test@example.invalid commit --quiet -m init
        return $root
    }

    function Get-WorkflowYaml {
        param([string]$Name)
        Get-Content -LiteralPath (Join-Path $repoRoot ".github/workflows/$Name") -Raw | ConvertFrom-Yaml
    }

    if (-not (Get-Module -Name powershell-yaml)) {
        Import-Module powershell-yaml -ErrorAction Stop
    }
}

AfterAll {
    foreach ($name in $script:stubbedCommands.Keys) {
        Remove-Item -Path "Function:global:$name" -ErrorAction SilentlyContinue
    }
    Remove-Module -Name ALM4DataverseE2ESetupGenerators, E2E -Force -ErrorAction SilentlyContinue
}

Describe 'E2E test application regeneration' {
    It 'regenerates a GitHub application from the templates with actions pinned to the commit under test' {
        $root = Initialize-E2EFixtureRepository
        Update-E2EGitHubAppRepository -RepositoryRoot $root -AlmRoot $repoRoot -SharedWorkflowRepository 'contoso/ALM4Dataverse' `
            -SharedWorkflowRef 'abc123' -SolutionName 'ALM4DataverseE2E' -Confirm:$false 6>$null

        Test-Path -LiteralPath (Join-Path $root 'stale') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $root '.github-leftover.yml') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $root 'solutions/ALM4DataverseE2E/Other/Solution.xml') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $root 'data/system/export.ps1') | Should -BeTrue

        $actionReferences = @(Get-ChildItem -LiteralPath (Join-Path $root '.github/workflows') -Filter *.yml |
            Select-String -Pattern 'uses:\s*(\S+/\.github/actions/\S+)' | ForEach-Object { $_.Matches[0].Groups[1].Value })
        $actionReferences | Should -Not -BeNullOrEmpty
        $actionReferences | Should -Not -Contain ($actionReferences | Where-Object { $_ -notlike 'contoso/ALM4Dataverse/.github/actions/*@abc123' })

        $deploy = Get-Content -LiteralPath (Join-Path $root '.github/workflows/DEPLOY-main.yml') -Raw
        $deployYaml = $deploy | ConvertFrom-Yaml
        @($deployYaml.jobs.Keys) | Should -Be @('deploy-test-main')
        $deployYaml.jobs['deploy-test-main'].environment | Should -Be 'TEST-main'
        $deployYaml.on.repository_dispatch.types | Should -Be @('alm4dataverse-build-deploy-main')
        $null = Get-Content -LiteralPath (Join-Path $root '.github/workflows/BUILD.yml') -Raw | ConvertFrom-Yaml -ErrorAction Stop

        (Import-PowerShellDataFile -LiteralPath (Join-Path $root 'alm-config.psd1')).solutions.name | Should -Be 'ALM4DataverseE2E'
    }

    It 'regenerates an Azure DevOps application with a single deployment stage' {
        $root = Initialize-E2EFixtureRepository
        Update-E2EAzDoAppRepository -RepositoryRoot $root -AlmRoot $repoRoot -RepositoryName 'alm-e2e-app' -SharedRepositoryName 'SharedAlm' `
            -SolutionName 'ALM4DataverseE2E' -UseAlm4DataverseExtension $false -Confirm:$false 6>$null

        Test-Path -LiteralPath (Join-Path $root 'stale') | Should -BeFalse
        $deployYaml = Get-Content -LiteralPath (Join-Path $root 'pipelines/DEPLOY-main.yml') -Raw | ConvertFrom-Yaml
        $deployYaml.resources.pipelines[0].source | Should -Be 'alm-e2e-app\BUILD'
        $deployYaml.resources.repositories[0].name | Should -Be 'SharedAlm'
        @($deployYaml.stages).Count | Should -Be 1
        $deployYaml.stages[0].parameters.environmentName | Should -Be 'TEST-main'
        $deployYaml.stages[0].parameters.useAlm4DataverseExtension | Should -BeFalse

        $buildYaml = Get-Content -LiteralPath (Join-Path $root 'pipelines/BUILD.yml') -Raw | ConvertFrom-Yaml
        $buildYaml.stages[0].parameters.buildEnvironmentName | Should -Be ''
        (Get-Content -LiteralPath (Join-Path $root 'pipelines/EXPORT.yml') -Raw) | Should -Match 'name: SharedAlm'
        (Import-PowerShellDataFile -LiteralPath (Join-Path $root 'alm-config.psd1')).solutions.name | Should -Be 'ALM4DataverseE2E'
    }

    It 'loads generators without the console-clearing section renderer' {
        $null = Import-SetupGeneratorFunction -AlmRoot $repoRoot -Platform GitHub
        (Get-Command Write-Section).Module.Name | Should -Be 'ALM4DataverseE2ESetupGenerators'
        { Write-Section -Message 'Plain output' 6>$null } | Should -Not -Throw
        Get-Command Copy-WorkflowTemplatesToRepo -ErrorAction Stop | Should -Not -BeNullOrEmpty
    }

    It 'rejects a provider setup script that does not parse' {
        $almRoot = Join-Path $TestDrive 'broken-alm'
        New-Item -ItemType Directory -Path $almRoot -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $almRoot 'setup-common.ps1') -Value 'function Test-Common {}'
        Set-Content -LiteralPath (Join-Path $almRoot 'setup-azdo.ps1') -Value 'function Broken {'
        { Import-SetupGeneratorFunction -AlmRoot $almRoot -Platform AzureDevOps } | Should -Throw '*Could not parse setup-azdo.ps1*'
    }

    It 'leaves files in place under WhatIf and fails when Git cannot list files' {
        $root = Initialize-E2EFixtureRepository
        Clear-E2EAppRepository -RepositoryRoot $root -WhatIf
        Test-Path -LiteralPath (Join-Path $root 'stale/nested/leftover.txt') | Should -BeTrue

        Mock git -ModuleName E2E { $global:LASTEXITCODE = 1 }
        { Clear-E2EAppRepository -RepositoryRoot $root -Confirm:$false } | Should -Throw '*Could not list tracked files*'
    }

    It 'skips regeneration under WhatIf' {
        $root = Initialize-E2EFixtureRepository
        Update-E2EGitHubAppRepository -RepositoryRoot $root -AlmRoot $repoRoot -SharedWorkflowRepository 'a/b' -SharedWorkflowRef 'c' -SolutionName 'ALM4DataverseE2E' -WhatIf
        Update-E2EAzDoAppRepository -RepositoryRoot $root -AlmRoot $repoRoot -RepositoryName 'app' -SolutionName 'ALM4DataverseE2E' -WhatIf
        Test-Path -LiteralPath (Join-Path $root 'stale/nested/leftover.txt') | Should -BeTrue
    }
}

Describe 'E2E solution source version' {
    It 'raises a lower source version to the Dev version' {
        $root = Initialize-E2EFixtureRepository -Version '1.0.0.3'
        Set-E2ESolutionSourceVersion -RepositoryRoot $root -SolutionName 'ALM4DataverseE2E' -MinimumVersion '1.2.0.7' -Confirm:$false 6>$null | Should -BeTrue
        ([xml](Get-Content -LiteralPath (Join-Path $root 'solutions/ALM4DataverseE2E/Other/Solution.xml') -Raw)).ImportExportXml.SolutionManifest.Version | Should -Be '1.2.0.7'
    }

    It 'keeps an equal or higher source version' -ForEach @(@{ Source = '1.2.0.7' }, @{ Source = '1.3.0.0' }) {
        $root = Initialize-E2EFixtureRepository -Version $Source
        Set-E2ESolutionSourceVersion -RepositoryRoot $root -SolutionName 'ALM4DataverseE2E' -MinimumVersion '1.2.0.7' | Should -BeFalse
        ([xml](Get-Content -LiteralPath (Join-Path $root 'solutions/ALM4DataverseE2E/Other/Solution.xml') -Raw)).ImportExportXml.SolutionManifest.Version | Should -Be $Source
    }

    It 'does not write under WhatIf' {
        $root = Initialize-E2EFixtureRepository -Version '1.0.0.3'
        Set-E2ESolutionSourceVersion -RepositoryRoot $root -SolutionName 'ALM4DataverseE2E' -MinimumVersion '1.2.0.7' -WhatIf | Should -BeFalse
    }

    It 'requires the solution to have been exported once' {
        { Set-E2ESolutionSourceVersion -RepositoryRoot $TestDrive -SolutionName 'Missing' -MinimumVersion '1.0' } | Should -Throw '*Export ''Missing''*'
    }
}

Describe 'E2E repository publication' {
    BeforeEach {
        $remote = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        & git init --quiet --bare --initial-branch main $remote
        $seed = Initialize-E2EFixtureRepository
        & git -C $seed push --quiet $remote HEAD:refs/heads/main
        $clone = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        & git clone --quiet $remote $clone
    }

    It 'commits and pushes changes, then reports nothing to publish' {
        Set-Content -LiteralPath (Join-Path $clone 'new.txt') -Value 'generated'
        Publish-E2EAppRepository -RepositoryRoot $clone -Message 'E2E: regenerate [skip ci]' -Confirm:$false | Should -BeTrue
        (& git -C $remote log -1 --format=%s main) | Should -Be 'E2E: regenerate [skip ci]'
        Publish-E2EAppRepository -RepositoryRoot $clone -Message 'unused' -Confirm:$false 6>$null | Should -BeFalse
    }

    It 'stops at the first failing Git command' -ForEach @(
        @{ Failing = 'add'; Message = '*git add failed*' }
        @{ Failing = 'commit'; Message = '*git commit failed*' }
        @{ Failing = 'push'; Message = '*git push to main failed*' }
    ) {
        Mock git -ModuleName E2E {
            $global:LASTEXITCODE = if ($args -contains $Failing) { 1 } elseif ($args -contains 'diff') { 1 } else { 0 }
        }
        { Publish-E2EAppRepository -RepositoryRoot $clone -Message 'm' -Confirm:$false } | Should -Throw $Message
    }

    It 'does nothing under WhatIf' {
        Publish-E2EAppRepository -RepositoryRoot $clone -Message 'm' -WhatIf | Should -BeFalse
    }
}

Describe 'E2E Dataverse helpers' {
    BeforeEach {
        $script:connection = [pscustomobject]@{ Name = 'fake' }
        Mock Get-DataverseConnection -ModuleName E2E { [pscustomobject]@{ Url = $Url; Ambient = [bool]$DefaultAzureCredential } }
        Mock Get-DataverseRecord -ModuleName E2E { [pscustomobject]@{ version = '1.2.0.3' } } -ParameterFilter { $TableName -eq 'solution' }
        Mock Get-DataverseRecord -ModuleName E2E { [pscustomobject]@{ environmentvariabledefinitionid = 'definition-id'; defaultvalue = 'previous' } } -ParameterFilter { $TableName -eq 'environmentvariabledefinition' }
        Mock Set-DataverseRecord -ModuleName E2E {}
    }

    It 'connects with the ambient Azure identity' {
        (Get-E2EDataverseConnection -Url 'https://dev.example.invalid').Ambient | Should -BeTrue
    }

    It 'reads the Dev solution version and fails when the solution is missing' {
        Get-E2ESolutionVersion -Connection $script:connection -SolutionName 'ALM4DataverseE2E' | Should -Be ([version]'1.2.0.3')
        Mock Get-DataverseRecord -ModuleName E2E {} -ParameterFilter { $TableName -eq 'solution' }
        { Get-E2ESolutionVersion -Connection $script:connection -SolutionName 'ALM4DataverseE2E' } | Should -Throw '*was not found in the Dev environment*'
    }

    It 'reads and updates the marker definition default value' {
        Get-E2EMarker -Connection $script:connection -SchemaName 'alm4dv_E2EMarker' | Should -Be 'previous'
        Set-E2EMarker -Connection $script:connection -SchemaName 'alm4dv_E2EMarker' -Value 'e2e-1' -Confirm:$false
        Should -Invoke Set-DataverseRecord -ModuleName E2E -Times 1 -Exactly -ParameterFilter {
            $TableName -eq 'environmentvariabledefinition' -and $Id -eq 'definition-id' -and $NoCreate -and $InputObject.defaultvalue -eq 'e2e-1'
        }
    }

    It 'fails when the marker definition is missing and skips writes under WhatIf' {
        Set-E2EMarker -Connection $script:connection -SchemaName 'alm4dv_E2EMarker' -Value 'e2e-1' -WhatIf
        Should -Invoke Set-DataverseRecord -ModuleName E2E -Times 0 -Exactly
        Mock Get-DataverseRecord -ModuleName E2E {} -ParameterFilter { $TableName -eq 'environmentvariabledefinition' }
        { Get-E2EMarker -Connection $script:connection -SchemaName 'alm4dv_E2EMarker' } | Should -Throw '*was not found*'
    }

    It 'runs the shared dependency installer from the application root' {
        $almRoot = Join-Path $TestDrive 'installer-alm'
        New-Item -ItemType Directory -Path (Join-Path $almRoot 'pipelines/scripts') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $almRoot 'pipelines/scripts/installdependencies.ps1') -Value 'Set-Content -LiteralPath (Join-Path (Get-Location).Path ''installed.txt'') -Value ok'
        $appRoot = Join-Path $TestDrive 'installer-app'
        New-Item -ItemType Directory -Path $appRoot -Force | Out-Null
        $before = (Get-Location).Path
        Install-E2EDependency -AlmRoot $almRoot -RepositoryRoot $appRoot
        Test-Path -LiteralPath (Join-Path $appRoot 'installed.txt') | Should -BeTrue
        (Get-Location).Path | Should -Be $before
    }
}

Describe 'E2E polling and summaries' {
    BeforeEach {
        $script:savedSummary = $env:GITHUB_STEP_SUMMARY
        $env:GITHUB_STEP_SUMMARY = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.md')
        Mock Start-Sleep -ModuleName E2E {}
    }

    AfterEach {
        $env:GITHUB_STEP_SUMMARY = $script:savedSummary
    }

    It 'polls until the script block returns a value' {
        $script:attempts = 0
        Wait-E2EResult -Description 'value' -PollSeconds 1 -ScriptBlock { $script:attempts++; if ($script:attempts -ge 3) { 'ready' } } | Should -Be 'ready'
        Should -Invoke Start-Sleep -ModuleName E2E -Times 2 -Exactly
    }

    It 'times out with the description' {
        { Wait-E2EResult -Description 'nothing' -TimeoutMinutes 0 -ScriptBlock { } } | Should -Throw '*waiting for nothing*'
    }

    It 'records successful stages and fails unsuccessful ones with their URL' {
        $state = Wait-E2EStage -Description 'BUILD' -PollSeconds 0 -GetState { [pscustomobject]@{ Completed = $true; Succeeded = $true; Result = 'success'; Url = 'https://example.invalid/1' } } 6>$null
        $state.Result | Should -Be 'success'
        Get-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Raw | Should -Match '\| BUILD \| success \| \[run\]\(https://example.invalid/1\) \|'
        { Wait-E2EStage -Description 'DEPLOY' -PollSeconds 0 -GetState { [pscustomobject]@{ Completed = $true; Succeeded = $false; Result = 'failure'; Url = 'https://example.invalid/2' } } 6>$null } |
            Should -Throw "*DEPLOY finished with result 'failure': https://example.invalid/2*"
    }

    It 'skips the summary outside GitHub Actions' {
        $env:GITHUB_STEP_SUMMARY = ''
        { Add-E2EStepSummary -Markdown 'ignored' } | Should -Not -Throw
    }
}

Describe 'E2E GitHub helpers' {
    BeforeEach {
        Mock gh -ModuleName E2E {
            $global:LASTEXITCODE = 0
            $path = [string]$args[-1]
            if ($path -like '*/workflows/BUILD.yml/runs*') {
                '{"workflow_runs":[{"id":3,"status":"completed","conclusion":"success","created_at":"2026-01-01T10:05:00Z","html_url":"u3"},{"id":2,"status":"in_progress","conclusion":null,"created_at":"2026-01-01T10:02:00Z","html_url":"u2"},{"id":1,"status":"completed","conclusion":"success","created_at":"2026-01-01T09:00:00Z","html_url":"u1"}]}'
            }
            elseif ($path -like '*/workflows/EXPORT.yml/runs*') { '{"workflow_runs":[]}' }
            elseif ($path -like '*/actions/runs/7') { '{"id":7,"status":"completed","conclusion":"cancelled","html_url":"u7"}' }
            elseif ($path -like '*/actions/runs?per_page=100') { '{"workflow_runs":[{"id":8,"status":"queued","html_url":"u8"},{"id":9,"status":"completed","html_url":"u9"}]}' }
        }
    }

    It 'finds the earliest run created after the stage started' {
        $run = Find-E2EGitHubRun -Repository 'o/r' -Workflow BUILD.yml -EventName repository_dispatch -CreatedAfter ([datetime]::Parse('2026-01-01T10:00:00Z').ToUniversalTime())
        $run.Id | Should -Be 2
        $run.Completed | Should -BeFalse
        $run.Result | Should -Be 'in_progress'
        Should -Invoke gh -ModuleName E2E -ParameterFilter { $args -contains 'repos/o/r/actions/workflows/BUILD.yml/runs?event=repository_dispatch&per_page=30' }
        Find-E2EGitHubRun -Repository 'o/r' -Workflow EXPORT.yml -EventName workflow_dispatch -CreatedAfter (Get-Date) | Should -BeNullOrEmpty
    }

    It 'reports a completed run without success as unsuccessful' {
        $state = Get-E2EGitHubRunState -Repository 'o/r' -RunId 7
        $state.Completed | Should -BeTrue
        $state.Succeeded | Should -BeFalse
        $state.Result | Should -Be 'cancelled'
    }

    It 'cancels only active runs' {
        @(Get-E2EGitHubActiveRun -Repository 'o/r').id | Should -Be @(8)
        Stop-E2EGitHubActiveRun -Repository 'o/r' -Confirm:$false 6>$null
        Should -Invoke gh -ModuleName E2E -Times 1 -Exactly -ParameterFilter { $args -contains 'POST' -and $args -contains 'repos/o/r/actions/runs/8/cancel' }
    }

    It 'throws when gh fails and returns null for an empty response' {
        Mock gh -ModuleName E2E { $global:LASTEXITCODE = 1 }
        { Invoke-E2EGitHubApi -Path 'repos/o/r' } | Should -Throw '*GET repos/o/r failed*'
        Mock gh -ModuleName E2E { $global:LASTEXITCODE = 0 }
        Invoke-E2EGitHubApi -Method POST -Path 'repos/o/r/actions/runs/1/cancel' | Should -BeNullOrEmpty
    }
}

Describe 'E2E Azure DevOps helpers' {
    BeforeEach {
        $script:context = Get-E2EAzDoContext -OrganizationUrl 'https://dev.azure.com/contoso/' -Project 'E2E Project' -AccessToken 'token'
        Mock Invoke-RestMethod -ModuleName E2E {
            $script:lastRequest = [pscustomobject]@{ Uri = $Uri; Method = $Method; Headers = $Headers; Body = $Body }
            if ($Uri -like '*build/definitions*name=EXPORT*') { [pscustomobject]@{ value = @([pscustomobject]@{ id = 12 }) } }
            elseif ($Uri -like '*build/definitions*') { [pscustomobject]@{ value = @() } }
            elseif ($Uri -like '*pipelines/12/runs*') { [pscustomobject]@{ id = 101 } }
            elseif ($Uri -like '*build/builds/101?*') { [pscustomobject]@{ id = 101; status = 'completed'; result = 'succeeded'; _links = [pscustomobject]@{ web = [pscustomobject]@{ href = 'w101' } } } }
            elseif ($Uri -like '*build/builds?definitions=*') {
                [pscustomobject]@{ value = @(
                        [pscustomobject]@{ id = 201; status = 'inProgress'; sourceVersion = 'other'; _links = [pscustomobject]@{ web = [pscustomobject]@{ href = 'w201' } } }
                        [pscustomobject]@{ id = 202; status = 'notStarted'; sourceVersion = 'abc'; _links = [pscustomobject]@{ web = [pscustomobject]@{ href = 'w202' } } }
                        [pscustomobject]@{ id = 301; status = 'completed'; result = 'failed'; sourceVersion = 'abc'; triggeredByBuild = [pscustomobject]@{ id = 202 }; _links = [pscustomobject]@{ web = [pscustomobject]@{ href = 'w301' } } }
                    ) }
            }
            elseif ($Uri -like '*build/builds?$top=100*') { [pscustomobject]@{ value = @([pscustomobject]@{ id = 5; status = 'inProgress' }, [pscustomobject]@{ id = 6; status = 'cancelling' }, [pscustomobject]@{ id = 7; status = 'completed' }) } }
            elseif ($Uri -like '*git/repositories/app/refs*') { [pscustomobject]@{ value = @([pscustomobject]@{ name = 'refs/heads/main-old'; objectId = 'wrong' }, [pscustomobject]@{ name = 'refs/heads/main'; objectId = 'abc' }) } }
            elseif ($Uri -like '*git/repositories/*') { [pscustomobject]@{ value = @() } }
        }
    }

    It 'calls project APIs with api-version 7.1 and a bearer token' {
        Get-E2EAzDoPipelineId -Context $script:context -Folder '\app' -Name EXPORT | Should -Be 12
        ([uri]$script:lastRequest.Uri).AbsoluteUri | Should -Be 'https://dev.azure.com/contoso/E2E%20Project/_apis/build/definitions?name=EXPORT&path=%5Capp&api-version=7.1'
        $script:lastRequest.Headers.Authorization | Should -Be 'Bearer token'
        { Get-E2EAzDoPipelineId -Context $script:context -Folder '\app' -Name BUILD } | Should -Throw "*'\app\BUILD' was not found*"
    }

    It 'queues a run on the branch with template parameters' {
        Start-E2EAzDoPipelineRun -Context $script:context -PipelineId 12 -TemplateParameter @{ commitMessage = 'E2E m' } -Confirm:$false | Should -Be 101
        $body = $script:lastRequest.Body | ConvertFrom-Json
        $body.resources.repositories.self.refName | Should -Be 'refs/heads/main'
        $body.templateParameters.commitMessage | Should -Be 'E2E m'
        Start-E2EAzDoPipelineRun -Context $script:context -PipelineId 12 -WhatIf | Should -BeNullOrEmpty
    }

    It 'finds builds by exact commit or by triggering build' {
        $since = (Get-Date).AddHours(-1)
        (Find-E2EAzDoBuild -Context $script:context -DefinitionId 3 -MinTime $since -SourceVersion 'abc').Id | Should -Be 202
        $deploy = Find-E2EAzDoBuild -Context $script:context -DefinitionId 4 -MinTime $since -TriggeredByBuildId 202
        $deploy.Id | Should -Be 301
        $deploy.Succeeded | Should -BeFalse
        $deploy.Result | Should -Be 'failed'
        Find-E2EAzDoBuild -Context $script:context -DefinitionId 4 -MinTime $since -SourceVersion 'missing' | Should -BeNullOrEmpty
        (Get-E2EAzDoBuildState -Context $script:context -BuildId 101).Succeeded | Should -BeTrue
    }

    It 'cancels active builds that are not already cancelling' {
        @(Get-E2EAzDoActiveBuild -Context $script:context).id | Should -Be @(5, 6)
        Stop-E2EAzDoActiveBuild -Context $script:context -Confirm:$false 6>$null
        Should -Invoke Invoke-RestMethod -ModuleName E2E -Times 1 -Exactly -ParameterFilter { $Method -eq 'PATCH' -and $Uri -like '*build/builds/5?*' -and ($Body | ConvertFrom-Json).status -eq 'cancelling' }
        Should -Invoke Invoke-RestMethod -ModuleName E2E -Times 0 -Exactly -ParameterFilter { $Method -eq 'PATCH' -and $Uri -like '*build/builds/6?*' }
    }

    It 'returns the exact branch head and fails for a missing branch' {
        Get-E2EAzDoBranchHead -Context $script:context -Repository 'app' | Should -Be 'abc'
        { Get-E2EAzDoBranchHead -Context $script:context -Repository 'other' } | Should -Throw "*Branch 'main' was not found*"
    }

    It 'gets a masked token from the Azure CLI and fails without a sign-in' {
        $savedActions = $env:GITHUB_ACTIONS
        try {
            $env:GITHUB_ACTIONS = 'true'
            Mock az -ModuleName E2E { $global:LASTEXITCODE = 0; ' secret-token ' }
            Get-E2EAzDoAccessToken 6>$null | Should -Be 'secret-token'
            Should -Invoke az -ModuleName E2E -ParameterFilter { $args -contains '499b84ac-1321-427f-aa17-267ca6975798' }
            Mock az -ModuleName E2E { $global:LASTEXITCODE = 1 }
            { Get-E2EAzDoAccessToken } | Should -Throw '*Run azure/login first*'
        }
        finally {
            $env:GITHUB_ACTIONS = $savedActions
        }
    }
}

Describe 'E2E shared environment lock' {
    BeforeEach {
        Mock Start-Sleep -ModuleName E2E {}
        $script:context = Get-E2EAzDoContext -OrganizationUrl 'https://dev.azure.com/contoso' -Project 'p' -AccessToken 't'
    }

    It 'waits until both platforms have no active runs' {
        $script:githubChecks = 0
        Mock Get-E2EGitHubActiveRun -ModuleName E2E { $script:githubChecks++; if ($script:githubChecks -eq 1) { [pscustomobject]@{ html_url = 'u1' } } }
        Mock Get-E2EAzDoActiveBuild -ModuleName E2E { }
        Wait-E2EResourceIdle -GitHubRepository 'o/r' -AzDoContext $script:context -PollSeconds 1 6>$null
        Should -Invoke Get-E2EGitHubActiveRun -ModuleName E2E -Times 2 -Exactly
        Should -Invoke Get-E2EAzDoActiveBuild -ModuleName E2E -Times 2 -Exactly
    }

    It 'times out while a platform stays busy and skips platforms that are not configured' {
        Mock Get-E2EAzDoActiveBuild -ModuleName E2E { [pscustomobject]@{ id = 9 } }
        Mock Get-E2EGitHubActiveRun -ModuleName E2E { }
        { Wait-E2EResourceIdle -AzDoContext $script:context -TimeoutMinutes 0 6>$null } | Should -Throw '*shared Dataverse environments to become idle*'
        Should -Invoke Get-E2EGitHubActiveRun -ModuleName E2E -Times 0 -Exactly
    }

    It 'serializes both E2E workflows on one non-cancelling job concurrency group' -ForEach @(
        @{ Name = 'e2e-github.yml' }
        @{ Name = 'e2e-azdo.yml' }
    ) {
        $workflow = Get-WorkflowYaml -Name $Name
        $job = $workflow.jobs.e2e
        $job.concurrency.group | Should -Be 'alm4dataverse-e2e-dataverse'
        $job.concurrency.'cancel-in-progress' | Should -BeFalse
        $job.environment | Should -Be 'e2e'
        $job.'runs-on' | Should -Be 'windows-latest'
        $job.if | Should -Match 'github.event.pull_request.head.repo.full_name == github.repository'
        $workflow.permissions.contents | Should -Be 'read'
        $workflow.permissions.'id-token' | Should -Be 'write'
        $job.steps[0].with.ref | Should -Be '${{ github.event.pull_request.head.sha || github.sha }}'
        $cleanup = $job.steps | Where-Object { $_.name -eq 'Stop test application runs' }
        $cleanup.if | Should -Be 'failure() || cancelled()'
        $cleanup.run | Should -Match '-StopActiveRuns'
    }
}

Describe 'Invoke-GitHubE2E.ps1' {
    BeforeEach {
        $script:savedSummary = $env:GITHUB_STEP_SUMMARY
        $env:GITHUB_STEP_SUMMARY = ''
        # Mocks run inside the orchestrator's script scope, so a fixed clock makes
        # the marker predictable instead of sharing state through variables.
        Mock Get-Date { [datetime]::new(2026, 1, 1, 10, 0, 0, [System.DateTimeKind]::Utc) }
        Mock gh { $global:LASTEXITCODE = 0 }
        Mock git { $global:LASTEXITCODE = 0 }
        Mock Get-E2EAzDoAccessToken { 'token' }
        Mock Wait-E2EResourceIdle {}
        Mock Update-E2EGitHubAppRepository {}
        Mock Install-E2EDependency {}
        Mock Get-E2EDataverseConnection { [pscustomobject]@{ Url = $Url } }
        Mock Get-E2ESolutionVersion { [version]'1.0.0.9' }
        Mock Set-E2ESolutionSourceVersion { $true }
        Mock Publish-E2EAppRepository { $true }
        Mock Set-E2EMarker {}
        Mock Get-E2EMarker { 'e2e-gh-1-1-20260101100000' }
        Mock Find-E2EGitHubRun { [pscustomobject]@{ Id = $Workflow } }
        Mock Get-E2EGitHubRunState { [pscustomobject]@{ Completed = $true; Succeeded = $true; Result = 'success'; Url = "u-$RunId" } }
        Mock Invoke-E2EGitHubApi { @([pscustomobject]@{ created_at = (Get-Date).ToUniversalTime() }) }
        Mock Stop-E2EGitHubActiveRun {}
        $script:parameters = @{
            AppRepository            = 'contoso/app'
            SharedWorkflowRepository = 'contoso/ALM4Dataverse'
            SharedWorkflowRef        = 'abc123'
            DevUrl                   = 'https://dev.example.invalid'
            TestUrl                  = 'https://test.example.invalid'
            AzDoOrganizationUrl      = 'https://dev.azure.com/contoso'
            AzDoProject              = 'p'
            RunLabel                 = 'gh-1-1'
            WorkRoot                 = $TestDrive
            PollSeconds              = 0
        }
    }

    AfterEach {
        $env:GITHUB_STEP_SUMMARY = $script:savedSummary
    }

    It 'regenerates, exports, builds and deploys, then verifies the Test marker' {
        & (Join-Path $e2eRoot 'Invoke-GitHubE2E.ps1') @parameters 6>$null

        Should -Invoke Wait-E2EResourceIdle -Times 1 -Exactly -ParameterFilter { $GitHubRepository -eq 'contoso/app' -and $AzDoContext.Project -eq 'p' }
        Should -Invoke Update-E2EGitHubAppRepository -Times 1 -Exactly -ParameterFilter { $SharedWorkflowRef -eq 'abc123' -and $SolutionName -eq 'ALM4DataverseE2E' }
        Should -Invoke Set-E2ESolutionSourceVersion -Times 1 -Exactly -ParameterFilter { $MinimumVersion -eq [version]'1.0.0.9' }
        Should -Invoke Publish-E2EAppRepository -Times 1 -Exactly -ParameterFilter { $Message -match '\[skip ci\]' }
        Should -Invoke Set-E2EMarker -Times 1 -Exactly -ParameterFilter { $Value -eq 'e2e-gh-1-1-20260101100000' -and $Connection.Url -eq 'https://dev.example.invalid' }
        Should -Invoke gh -Times 1 -Exactly -ParameterFilter { $args -contains 'EXPORT.yml' -and $args -contains "commit-message=E2E e2e-gh-1-1-20260101100000" }
        Should -Invoke Find-E2EGitHubRun -Times 1 -Exactly -ParameterFilter { $Workflow -eq 'BUILD.yml' -and $EventName -eq 'repository_dispatch' }
        Should -Invoke Find-E2EGitHubRun -Times 1 -Exactly -ParameterFilter { $Workflow -eq 'DEPLOY-main.yml' -and $EventName -eq 'repository_dispatch' }
        Should -Invoke Get-E2EDataverseConnection -Times 1 -Exactly -ParameterFilter { $Url -eq 'https://test.example.invalid' }
    }

    It 'fails when Test does not receive the marker' {
        Mock Get-E2EMarker { 'stale' }
        { & (Join-Path $e2eRoot 'Invoke-GitHubE2E.ps1') @parameters 6>$null } | Should -Throw "*marker is 'stale'*"
    }

    It 'fails when BUILD publishes no release' {
        Mock Invoke-E2EGitHubApi { @() }
        { & (Join-Path $e2eRoot 'Invoke-GitHubE2E.ps1') @parameters 6>$null } | Should -Throw '*did not publish a GitHub Release*'
    }

    It 'stops at a failed stage' {
        Mock Get-E2EGitHubRunState { [pscustomobject]@{ Completed = $true; Succeeded = $false; Result = 'failure'; Url = 'u-export' } }
        { & (Join-Path $e2eRoot 'Invoke-GitHubE2E.ps1') @parameters 6>$null } | Should -Throw '*EXPORT finished*u-export*'
        Should -Invoke Find-E2EGitHubRun -Times 0 -Exactly -ParameterFilter { $Workflow -eq 'BUILD.yml' }
    }

    It 'fails when the clone or dispatch fails' {
        Mock git { $global:LASTEXITCODE = 1 }
        { & (Join-Path $e2eRoot 'Invoke-GitHubE2E.ps1') @parameters 6>$null } | Should -Throw '*Could not clone contoso/app*'
        Mock git { $global:LASTEXITCODE = 0 }
        Mock gh { $global:LASTEXITCODE = if ($args -contains 'workflow') { 1 } else { 0 } }
        { & (Join-Path $e2eRoot 'Invoke-GitHubE2E.ps1') @parameters 6>$null } | Should -Throw '*Could not dispatch EXPORT*'
    }

    It 'requires cycle parameters unless stopping runs' {
        { & (Join-Path $e2eRoot 'Invoke-GitHubE2E.ps1') -AppRepository 'contoso/app' } | Should -Throw '*-SharedWorkflowRepository is required*'
    }

    It 'cancels active runs and waits for idleness in cleanup mode' {
        & (Join-Path $e2eRoot 'Invoke-GitHubE2E.ps1') -AppRepository 'contoso/app' -StopActiveRuns -PollSeconds 0
        Should -Invoke Stop-E2EGitHubActiveRun -Times 1 -Exactly -ParameterFilter { $Repository -eq 'contoso/app' }
        Should -Invoke Wait-E2EResourceIdle -Times 1 -Exactly -ParameterFilter { $GitHubRepository -eq 'contoso/app' -and -not $AzDoContext }
        Should -Invoke Update-E2EGitHubAppRepository -Times 0 -Exactly
    }
}

Describe 'Invoke-AzDoE2E.ps1' {
    BeforeEach {
        $script:savedSummary = $env:GITHUB_STEP_SUMMARY
        $env:GITHUB_STEP_SUMMARY = ''
        Mock Get-Date { [datetime]::new(2026, 1, 1, 10, 0, 0, [System.DateTimeKind]::Utc) }
        Mock git { $global:LASTEXITCODE = 0 }
        Mock Get-E2EAzDoAccessToken { 'token' }
        Mock Wait-E2EResourceIdle {}
        Mock Update-E2EAzDoAppRepository {}
        Mock Install-E2EDependency {}
        Mock Get-E2EDataverseConnection { [pscustomobject]@{ Url = $Url } }
        Mock Get-E2ESolutionVersion { [version]'1.0.0.9' }
        Mock Set-E2ESolutionSourceVersion { $false }
        Mock Publish-E2EAppRepository { $true }
        Mock Set-E2EMarker {}
        Mock Get-E2EMarker { 'e2e-azdo-1-1-20260101100000' }
        Mock Get-E2EAzDoPipelineId { @{ EXPORT = 1; BUILD = 2; 'DEPLOY-main' = 3 }[$Name] }
        Mock Start-E2EAzDoPipelineRun { 101 }
        Mock Get-E2EAzDoBranchHead { 'exported-sha' }
        Mock Find-E2EAzDoBuild { if ($SourceVersion) { [pscustomobject]@{ Id = 201 } } else { [pscustomobject]@{ Id = 301 } } }
        Mock Get-E2EAzDoBuildState { [pscustomobject]@{ Completed = $true; Succeeded = $true; Result = 'succeeded'; Url = "w$BuildId" } }
        Mock Stop-E2EAzDoActiveBuild {}
        $script:parameters = @{
            OrganizationUrl     = 'https://dev.azure.com/contoso'
            Project             = 'p'
            AppRepositoryName   = 'app'
            SharedRef           = 'abc123'
            DevUrl              = 'https://dev.example.invalid'
            TestUrl             = 'https://test.example.invalid'
            GitHubAppRepository = 'contoso/app'
            RunLabel            = 'azdo-1-1'
            WorkRoot            = $TestDrive
            PollSeconds         = 0
        }
    }

    AfterEach {
        $env:GITHUB_STEP_SUMMARY = $script:savedSummary
    }

    It 'publishes the shared commit, regenerates the application and follows the triggered pipelines' {
        & (Join-Path $e2eRoot 'Invoke-AzDoE2E.ps1') @parameters 6>$null

        Should -Invoke Wait-E2EResourceIdle -Times 1 -Exactly -ParameterFilter { $GitHubRepository -eq 'contoso/app' -and $AzDoContext.AccessToken -eq 'token' }
        Should -Invoke git -Times 1 -Exactly -ParameterFilter { $args -contains '--force' -and $args -contains 'abc123:refs/heads/main' -and $args -contains 'https://dev.azure.com/contoso/p/_git/ALM4Dataverse' }
        Should -Invoke Update-E2EAzDoAppRepository -Times 1 -Exactly -ParameterFilter { $RepositoryName -eq 'app' -and $SharedRepositoryName -eq 'ALM4Dataverse' }
        Should -Invoke Publish-E2EAppRepository -Times 1 -Exactly -ParameterFilter { $Message -match '\*\*\*NO_CI\*\*\*' -and $GitConfig[0] -eq 'http.extraheader=AUTHORIZATION: bearer token' }
        Should -Invoke Get-E2EAzDoPipelineId -Times 3 -Exactly -ParameterFilter { $Folder -eq '\app' }
        Should -Invoke Start-E2EAzDoPipelineRun -Times 1 -Exactly -ParameterFilter { $PipelineId -eq 1 -and $TemplateParameter.commitMessage -eq "E2E e2e-azdo-1-1-20260101100000" }
        Should -Invoke Set-E2EMarker -Times 1 -Exactly -ParameterFilter { $Value -eq 'e2e-azdo-1-1-20260101100000' }
        Should -Invoke Find-E2EAzDoBuild -Times 1 -Exactly -ParameterFilter { $DefinitionId -eq 2 -and $SourceVersion -eq 'exported-sha' }
        Should -Invoke Find-E2EAzDoBuild -Times 1 -Exactly -ParameterFilter { $DefinitionId -eq 3 -and $TriggeredByBuildId -eq 201 }
        Should -Invoke Get-E2EAzDoBuildState -Times 1 -Exactly -ParameterFilter { $BuildId -eq 301 }
    }

    It 'fails when Test does not receive the marker' {
        Mock Get-E2EMarker { 'stale' }
        { & (Join-Path $e2eRoot 'Invoke-AzDoE2E.ps1') @parameters 6>$null } | Should -Throw "*marker is 'stale'*"
    }

    It 'fails when the shared repository push or application clone fails' -ForEach @(
        @{ Failing = 'push'; Message = '*Could not push abc123 to ALM4Dataverse*' }
        @{ Failing = 'clone'; Message = '*Could not clone app*' }
    ) {
        Mock git { $global:LASTEXITCODE = if ($args -contains $Failing) { 1 } else { 0 } }
        { & (Join-Path $e2eRoot 'Invoke-AzDoE2E.ps1') @parameters 6>$null } | Should -Throw $Message
    }

    It 'requires cycle parameters unless stopping runs' {
        { & (Join-Path $e2eRoot 'Invoke-AzDoE2E.ps1') -OrganizationUrl 'https://dev.azure.com/contoso' -Project 'p' } | Should -Throw '*-AppRepositoryName is required*'
    }

    It 'cancels active builds and waits for idleness in cleanup mode' {
        & (Join-Path $e2eRoot 'Invoke-AzDoE2E.ps1') -OrganizationUrl 'https://dev.azure.com/contoso' -Project 'p' -StopActiveRuns -PollSeconds 0
        Should -Invoke Stop-E2EAzDoActiveBuild -Times 1 -Exactly
        Should -Invoke Wait-E2EResourceIdle -Times 1 -Exactly -ParameterFilter { -not $GitHubRepository -and $AzDoContext.Project -eq 'p' }
        Should -Invoke Update-E2EAzDoAppRepository -Times 0 -Exactly
    }
}
