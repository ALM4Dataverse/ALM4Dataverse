BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repoRoot 'setup-common.ps1')
    # Fail closed at external boundaries: later mocks simulate provider/native behavior while
    # generated configuration and workflow files are still written to real fixture directories.
    function git { throw 'Unexpected live Git command' }
    function gh { throw 'Unexpected live GitHub command' }
    function Get-VSTeamProject {}
    function Get-VSTeamExtension {}
    function Add-VSTeamExtension {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$PublisherId,
            [Parameter(Mandatory)][string]$ExtensionId
        )
    }
    function Set-VSTeamDefaultProject {
        [CmdletBinding(SupportsShouldProcess = $true)]
        param($Project)
        if ($PSCmdlet.ShouldProcess($Project, 'Set default project')) { throw 'Unexpected live project configuration.' }
    }
    function Get-VSTeamBuildDefinition {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        [CmdletBinding()]
        param($ProjectName, $Id)
    }
    function Get-VSTeamGitRepository {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ProjectName', Justification = 'Mock command signature; Pester inspects this argument.')]
        [CmdletBinding()]
        param($ProjectName)
    }
    function Add-VSTeamGitRepository {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ProjectName', Justification = 'Pester mock command parameter.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Name', Justification = 'Pester mock command parameter.')]
        [CmdletBinding()]
        param($ProjectName, $Name)
        throw 'Unexpected live repository creation.'
    }
}

Describe 'Azure DevOps repository selection and working trees' {
    BeforeAll {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'setup-azdo.ps1'), [ref]$tokens, [ref]$parseErrors)
        foreach ($definition in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
            Set-Item -Path "Function:$($definition.Name)" -Value $definition.Body.GetScriptBlock()
        }
    }

    BeforeEach {
        $script:workingTemp = $env:TEMP
        $script:workingExitCode = Get-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
        # Production working-tree helpers allocate under TEMP; redirect even failed clones
        # into this case's disposable tree and preserve whether LASTEXITCODE existed at all.
        $env:TEMP = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item $env:TEMP -ItemType Directory | Out-Null
        $global:LASTEXITCODE = 0
        $script:ALM4DataverseRef = 'stable'
        $script:workingHasCommits = $true
        $script:workingCheckoutFallback = $false
        $script:workingFailure = ''
        $script:repoMenuIndex = 0
        $script:workingRepository = [pscustomobject]@{ Id = 'shared-id'; Name = 'shared'; remoteUrl = 'https://example.invalid/shared'; defaultBranch = 'refs/heads/main' }
        Mock Write-Section {}
        Mock Invoke-WithSpectreStatus { & $ScriptBlock }
        Mock Select-FromMenu { $script:repoMenuIndex }
        Mock Read-TextWithDefault { 'newrepo' }
        Mock Get-VSTeamGitRepository { $script:workingRepository; [pscustomobject]@{ Id = 'main-id'; Name = 'main'; remoteUrl = 'https://example.invalid/main'; defaultBranch = 'refs/heads/main' } }
        Mock Add-VSTeamGitRepository { [pscustomobject]@{ Id = 'new-id'; Name = $Name } }
        Mock git {
            $global:LASTEXITCODE = 0
            if ($args -contains 'clone') { New-Item $args[-1] -ItemType Directory -Force | Out-Null }
            if ($args -contains 'rev-parse' -and -not $script:workingHasCommits) { $global:LASTEXITCODE = 1 }
            if ($args -contains 'checkout' -and $script:workingCheckoutFallback -and $args -notcontains '-b' -and $args -notcontains '-B') { $global:LASTEXITCODE = 1 }
            if ($script:workingFailure -and $args -contains $script:workingFailure) { $global:LASTEXITCODE = 1; 'Simulated working tree failure' }
        }
    }

    AfterEach {
        $env:TEMP = $script:workingTemp
        if ($script:workingExitCode) { $global:LASTEXITCODE = $script:workingExitCode.Value }
        else { Remove-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue }
    }

    It 'declares the caller pipeline helper before preparing the main repository working tree' {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'setup-azdo.ps1'), [ref]$tokens, [ref]$parseErrors)
        $helperDefinition = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-AzDoCallerSecretVariableBlock'
        }, $true)
        $setupStep = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Invoke-WithErrorHandling' -and
            $node.Extent.Text.Contains('Preparing main repository working tree')
        }, $true)

        $helperDefinition | Should -Not -BeNullOrEmpty
        $setupStep | Should -Not -BeNullOrEmpty
        $helperDefinition.Extent.StartOffset | Should -BeLessThan $setupStep.Extent.StartOffset
    }

    It 'selects the preferred shared repository while excluding the application repository' {
        $result = Select-AzDoSharedRepository -ProjectName project -PreferredRepositoryName shared -ExcludeRepositoryName main
        $result.Id | Should -Be shared-id
        Should -Invoke Add-VSTeamGitRepository -Times 0 -Exactly
        Should -Invoke Select-FromMenu -Times 1 -Exactly -ParameterFilter { @($Items).Count -eq 2 -and $Items[0] -like 'Use current*' }
    }

    It 'creates a shared repository after rejecting an empty name' {
        $script:repoMenuIndex = 1
        $script:repositoryNames = [System.Collections.Generic.Queue[string]]::new()
        @(' ', 'newrepo') | ForEach-Object { $script:repositoryNames.Enqueue($_) }
        Mock Read-TextWithDefault { $script:repositoryNames.Dequeue() }
        $result = Select-AzDoSharedRepository -ProjectName project -PreferredRepositoryName shared -ExcludeRepositoryName main
        $result.Name | Should -Be newrepo
        Should -Invoke Add-VSTeamGitRepository -Times 1 -Exactly -ParameterFilter { $ProjectName -eq 'project' -and $Name -eq 'newrepo' }
    }

    It 'creates and selects the main repository or respects a cancelled choice' {
        $result = Select-AzDoMainRepository -ProjectName project -SharedRepositoryName shared
        $result.Id | Should -Be new-id
        $script:repoMenuIndex = 1
        $result = Select-AzDoMainRepository -ProjectName project -SharedRepositoryName shared
        $result.Id | Should -Be main-id
        Mock Select-FromMenu { $null }
        { Select-AzDoMainRepository -ProjectName project } | Should -Throw '*No main repository selected*'
        { Select-AzDoSharedRepository -ProjectName project } | Should -Throw '*No shared repository selected*'
    }

    It 'prepares existing, fallback and empty working branches' -ForEach @(
        @{ HasCommits = $true; Fallback = $false }
        @{ HasCommits = $true; Fallback = $true }
        @{ HasCommits = $false; Fallback = $false }
    ) {
        $script:workingHasCommits = $HasCommits
        $script:workingCheckoutFallback = $Fallback
        $originalLocation = (Get-Location).Path
        $result = New-AzDoRepoWorkingTree -TargetRepo $script:workingRepository -AccessToken fake-token -WorkBranch setup/main
        $result.BaseBranch | Should -Be main
        Test-Path $result.Path | Should -BeTrue
        (Get-Location).Path | Should -Be $originalLocation
        Should -Invoke git -Times 1 -Exactly -ParameterFilter { $args -contains '-B' -and $args -contains 'setup/main' }
    }

    It 'removes failed working trees and restores location and preference' -ForEach @(
        @{ Command = 'clone' }
        @{ Command = 'checkout' }
    ) {
        $script:workingFailure = $Command
        $originalLocation = (Get-Location).Path
        $originalPreference = $ErrorActionPreference
        { New-AzDoRepoWorkingTree -TargetRepo $script:workingRepository -AccessToken fake-token } | Should -Throw
        (Get-Location).Path | Should -Be $originalLocation
        $ErrorActionPreference | Should -Be $originalPreference
        @(Get-ChildItem $env:TEMP -Directory -Filter 'ALM4Dataverse-MainRepo-*').Count | Should -Be 0
    }

    It 'discovers extension conflicts and shared repository references from existing files' {
        $root = Join-Path $TestDrive 'existing'
        New-Item (Join-Path $root pipelines) -ItemType Directory -Force | Out-Null
        (Get-AzDoExtensionModeFromWorkingTree -RepoRoot $root -Branch main).IsConfigured | Should -BeFalse
        Set-Content (Join-Path $root 'pipelines/EXPORT.yml') 'useAlm4DataverseExtension: true'
        Set-Content (Join-Path $root 'pipelines/IMPORT.yml') 'useAlm4DataverseExtension: false'
        Set-Content (Join-Path $root 'pipelines/BUILD.yml') "repository: ALM4Dataverse`ntype: git`nname: shared"
        Set-Content (Join-Path $root 'pipelines/DEPLOY-main.yml') "environmentName: 'TEST'`nenvironmentName: 'TEST'`nenvironmentName: 'PROD'"
        (Get-AzDoExtensionModeFromWorkingTree -RepoRoot $root -Branch main).HasConflict | Should -BeTrue
        Get-AzDoSharedRepositoryNameFromWorkingTree -RepoRoot $root -Branch main | Should -Be shared
        Get-AzDoDeploymentEnvironmentNamesFromWorkingTree -RepoRoot $root -Branch main | Should -Be @('TEST', 'PROD')
        Set-Content (Join-Path $root 'pipelines/IMPORT.yml') 'useAlm4DataverseExtension: true'
        (Get-AzDoExtensionModeFromWorkingTree -RepoRoot $root -Branch main).UseAlm4DataverseExtension | Should -BeTrue
    }
}

Describe 'GitHub clone base branch initialization' {
    BeforeAll {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'setup-github.ps1'), [ref]$tokens, [ref]$parseErrors)
        $definition = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-GitHubCloneBaseBranchCheckout'
        }, $false)
        Set-Item -Path 'Function:Invoke-GitHubCloneBaseBranchCheckout' -Value $definition.Body.GetScriptBlock()
    }

    BeforeEach {
        $script:cloneHasCommit = $false
        Mock git {
            $global:LASTEXITCODE = 0
            if ($args -contains 'checkout') {
                $global:LASTEXITCODE = 1
                'The requested branch does not exist.'
            }
            elseif ($args -contains 'rev-parse' -and -not $script:cloneHasCommit) {
                $global:LASTEXITCODE = 128
                'fatal: Needed a single revision'
            }
        }
    }

    It 'points an empty clone at an unborn default branch' {
        $originalPreference = $ErrorActionPreference

        Invoke-GitHubCloneBaseBranchCheckout -RepoRoot $TestDrive -DefaultBranch main

        $ErrorActionPreference | Should -Be $originalPreference
        Should -Invoke git -Times 1 -Exactly -ParameterFilter {
            $args -contains 'symbolic-ref' -and $args -contains 'HEAD' -and $args -contains 'refs/heads/main'
        }
    }

    It 'still fails when an initialized clone is missing its base branch' {
        $script:cloneHasCommit = $true

        { Invoke-GitHubCloneBaseBranchCheckout -RepoRoot $TestDrive -DefaultBranch main } | Should -Throw "*Failed to check out repository base branch 'main'*"
        Should -Invoke git -Times 0 -Exactly -ParameterFilter { $args -contains 'symbolic-ref' }
    }
}

Describe 'Shared repository lifecycle in <Provider>' -ForEach @(
    @{ Provider = 'GitHub'; Source = 'setup-github.ps1' }
    @{ Provider = 'Azure DevOps'; Source = 'setup-azdo.ps1' }
) {
    BeforeAll {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $Source), [ref]$tokens, [ref]$parseErrors)
        foreach ($definition in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
            Set-Item -Path "Function:$($definition.Name)" -Value $definition.Body.GetScriptBlock()
        }
    }

    BeforeEach {
        $script:savedRepositoryTemp = $env:TEMP
        $script:savedRepositoryExitCode = Get-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
        $global:LASTEXITCODE = 0
        $env:TEMP = $TestDrive
        $script:ALM4DataverseRef = 'stable'
        $script:upstreamRepo = $repoRoot
        $script:orgName = 'org'
        $script:adoAccessToken = [pscustomobject]@{ Token = 'fake-token' }
        $script:sync = [pscustomobject]@{ LocalHash = 'one'; UpstreamHash = 'one'; UpstreamRef = 'upstream/main'; CanFastForward = $false; IsAhead = $false; MatchesCanonicalUpstreamDefault = $false }
        $script:repositorySelection = 0
        $script:ghUser = 'owner'
        $script:divergenceSelection = 2
        Mock Write-Section {}
        Mock Write-SetupGuidance {}
        Mock Read-YesNo { $true }
        Mock Read-TextWithDefault { if ($Prompt -like '*owner*') { $DefaultValue } else { 'shared' } }
        Mock Invoke-WithSpectreStatus { & $ScriptBlock }
        Mock Invoke-WithErrorHandling { & $ScriptBlock }
        Mock Select-FromMenu {
            if ($Title -like '*diverged*') { $script:divergenceSelection }
            else { $script:repositorySelection }
        }
        Mock git { $global:LASTEXITCODE = 0; if ($args -contains 'ls-remote') { 'abcdef refs/heads/stable' } }
        Mock gh { $global:LASTEXITCODE = 0 }
        if ($Provider -eq 'GitHub') {
            Mock Get-GitHubAccessibleForksOfRepository { [pscustomobject]@{ full_name = 'owner/shared' } }
            Mock Get-GitHubAccessibleRepository { [pscustomobject]@{ full_name = 'owner/shared' }; [pscustomobject]@{ full_name = 'owner/other' } }
            Mock Get-GitHubRepo { [pscustomobject]@{ name = $Repo; nameWithOwner = "$Owner/$Repo"; defaultBranchRef = [pscustomobject]@{ name = 'main' } } }
            Mock Get-GitHubForkSyncState { $script:sync }
        }
        else {
            Mock Get-VSTeamProject { [pscustomobject]@{ Name = 'project'; Id = 'project-id' } }
            Mock Set-VSTeamDefaultProject {}
            Mock Select-AzDoMainRepository { [pscustomobject]@{ Name = 'mainrepo'; Id = 'main-id'; defaultBranch = 'refs/heads/main' } }
            Mock New-AzDoRepoWorkingTree { [pscustomobject]@{ Path = $TestDrive; Branch = 'main' } }
            Mock Get-AzDoExtensionModeFromWorkingTree { [pscustomobject]@{ IsConfigured = $true; HasConflict = $false; UseAlm4DataverseExtension = $true; SourceFiles = @('BUILD.yml') } }
            Mock Get-VSTeamExtension { [pscustomobject]@{ publisherId = 'microsoft-IsvExpTools'; extensionId = 'PowerPlatform-BuildTools'; version = '1' }; [pscustomobject]@{ publisherId = 'ALM4Dataverse'; extensionId = 'alm4dataverse-azdo-extensions'; version = '1' } }
            Mock Get-AzDoSharedRepositoryNameFromWorkingTree { 'shared' }
            Mock Select-AzDoSharedRepository { [pscustomobject]@{ Name = 'shared'; Id = 'shared-id'; remoteUrl = 'https://example.invalid/shared' } }
            Mock Test-AzDoGitRepositoryCommit { $true }
            Mock Get-AzDoSharedRepositorySyncState { $script:sync }
        }
    }

    AfterEach {
        $env:TEMP = $script:savedRepositoryTemp
        if ($script:savedRepositoryExitCode) { $global:LASTEXITCODE = $script:savedRepositoryExitCode.Value }
        else { Remove-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue }
    }

    It 'reuses a repository that already matches upstream' {
        if ($Provider -eq 'GitHub') {
            $result = Initialize-GitHubSharedWorkflowFork -UpstreamFullName upstream/shared -DefaultOwner owner -UpstreamGitSource $repoRoot -Reference stable -PreferredRepositoryFullName owner/shared
            $result.nameWithOwner | Should -Be owner/shared
        }
        else {
            $result = Initialize-AzDoProjectAndRepository
            $result.SelectedProject.Name | Should -Be project
            $result.SharedRepoName | Should -Be shared
        }
        Should -Invoke git -Times 0 -Exactly
        Should -Invoke gh -Times 0 -Exactly
        @(Get-ChildItem $TestDrive -Directory -Filter 'ALM4Dataverse-*').Count | Should -Be 0
    }

    It 'uses the platform temporary directory when TEMP is unset' -Skip:($Provider -ne 'GitHub') {
        $env:TEMP = $null

        $result = Initialize-GitHubSharedWorkflowFork -UpstreamFullName upstream/shared -DefaultOwner owner -UpstreamGitSource $repoRoot -Reference stable -PreferredRepositoryFullName owner/shared

        $result.nameWithOwner | Should -Be owner/shared
    }

    It 'lists accessible organization repositories in the shared workflow choices' -Skip:($Provider -ne 'GitHub') {
        Mock Get-GitHubAccessibleForksOfRepository { [pscustomobject]@{ full_name = 'first-org/shared' } }
        Mock Get-GitHubAccessibleRepository {
            [pscustomobject]@{ full_name = 'first-org/shared' }
            [pscustomobject]@{ full_name = 'second-org/other' }
        }
        $script:repositorySelection = 0

        $result = Initialize-GitHubSharedWorkflowFork -UpstreamFullName upstream/shared -DefaultOwner owner -UpstreamGitSource $repoRoot -Reference stable

        $result.nameWithOwner | Should -Be 'first-org/shared'
        Should -Invoke Select-FromMenu -Times 1 -Exactly -ParameterFilter {
            $Title -eq 'Select shared workflow repository' -and
            @($Items) -contains 'Use existing fork: first-org/shared' -and
            @($Items) -contains 'Use existing repository: second-org/other'
        }
    }

    It 'prompts for a shared repository owner defaulting to the main repository owner for <CreationMode> creation' -ForEach @(
        @{ CreationMode = 'Public'; CreationSelection = 0 }
        @{ CreationMode = 'Private'; CreationSelection = 1 }
    ) -Skip:($Provider -ne 'GitHub') {
        Mock Get-GitHubAccessibleForksOfRepository { @() }
        Mock Get-GitHubAccessibleRepository { @() }
        $script:repositorySelection = 0
        $script:ownerPromptDefault = $null
        $script:sharedRepoCreateArgs = @()
        Mock Read-TextWithDefault {
            if ($Prompt -eq 'Shared workflow repository owner (user or organization)') {
                $script:ownerPromptDefault = $DefaultValue
                return $DefaultValue
            }
            return 'shared'
        }
        Mock Select-FromMenu {
            if ($Title -like 'How should*') { $CreationSelection }
            else { 0 }
        }
        Mock gh {
            $script:sharedRepoCreateArgs = @($args)
            $global:LASTEXITCODE = 0
        }

        $result = Initialize-GitHubSharedWorkflowFork -UpstreamFullName upstream/shared -DefaultOwner main-org -UpstreamGitSource $repoRoot -Reference stable

        $script:ownerPromptDefault | Should -Be 'main-org'
        $result.nameWithOwner | Should -Be 'main-org/shared'
        Should -Invoke Read-TextWithDefault -Times 1 -Exactly -ParameterFilter {
            $Prompt -eq 'Shared workflow repository owner (user or organization)' -and $DefaultValue -eq 'main-org'
        }
        if ($CreationMode -eq 'Public') {
            $script:sharedRepoCreateArgs | Should -Contain '--org'
            $script:sharedRepoCreateArgs | Should -Contain 'main-org'
            $script:sharedRepoCreateArgs | Should -Contain 'fork'
        }
        else {
            $script:sharedRepoCreateArgs | Should -Contain 'create'
            $script:sharedRepoCreateArgs | Should -Contain 'main-org/shared'
            $script:sharedRepoCreateArgs | Should -Contain '--private'
        }
    }

    It 'fast-forwards only after approval and restores command state' {
        $script:sync.UpstreamHash = 'two'
        $script:sync.CanFastForward = $true
        if ($Provider -eq 'GitHub') { Initialize-GitHubSharedWorkflowFork -UpstreamFullName upstream/shared -DefaultOwner owner -UpstreamGitSource $repoRoot -Reference stable | Out-Null }
        else { Initialize-AzDoProjectAndRepository | Out-Null }
        Should -Invoke git -Times 1 -Exactly -ParameterFilter { $args -contains '--ff-only' }
        Should -Invoke git -Times 1 -Exactly -ParameterFilter { $args -contains 'push' }
    }

    It 'honors each explicit divergence action' -ForEach @(
        @{ Selection = 0; ExpectedCommand = 'rebase' }
        @{ Selection = 1; ExpectedCommand = 'reset' }
        @{ Selection = 2; ExpectedCommand = '' }
    ) {
        $script:sync.UpstreamHash = 'two'
        $script:divergenceSelection = $Selection
        if ($Provider -eq 'GitHub') { Initialize-GitHubSharedWorkflowFork -UpstreamFullName upstream/shared -DefaultOwner owner -UpstreamGitSource $repoRoot -Reference stable | Out-Null }
        else { Initialize-AzDoProjectAndRepository | Out-Null }
        if ($ExpectedCommand) {
            Should -Invoke git -Times 1 -Exactly -ParameterFilter { $args -contains $ExpectedCommand }
            Should -Invoke git -Times 1 -Exactly -ParameterFilter { $args -contains '--force-with-lease' }
        }
        else { Should -Invoke git -Times 0 -Exactly }
    }

    It 'propagates native sync failure and cleans the temporary repository' {
        $script:sync.UpstreamHash = 'two'
        $script:sync.CanFastForward = $true
        Mock git { $global:LASTEXITCODE = 1 }
        if ($Provider -eq 'GitHub') { { Initialize-GitHubSharedWorkflowFork -UpstreamFullName upstream/shared -DefaultOwner owner -UpstreamGitSource $repoRoot -Reference stable } | Should -Throw '*merge failed*' }
        else { { Initialize-AzDoProjectAndRepository } | Should -Throw '*merge failed*' }
        @(Get-ChildItem $TestDrive -Directory -Filter 'ALM4Dataverse-*').Count | Should -Be 0
    }

    It 'initializes an empty shared repository from the requested upstream ref' {
        $script:sync.UpstreamHash = 'two'
        if ($Provider -eq 'GitHub') {
            $script:repositorySelection = 1
            Initialize-GitHubSharedWorkflowFork -UpstreamFullName upstream/shared -DefaultOwner owner -UpstreamGitSource $repoRoot -Reference stable | Out-Null
            Should -Invoke gh -Times 1 -Exactly -ParameterFilter { $args -contains 'create' }
            Should -Invoke git -Times 1 -Exactly -ParameterFilter { $args -contains 'reset' }
        }
        else {
            Mock Test-AzDoGitRepositoryCommit { $false }
            Initialize-AzDoProjectAndRepository | Out-Null
            Should -Invoke git -Times 1 -Exactly -ParameterFilter { $args -contains 'init' }
            Should -Invoke git -Times 1 -Exactly -ParameterFilter { $args -contains 'push' }
        }
    }

    It 'creates a project and resolves conflicting extension mode before installing dependencies' -Skip:($Provider -ne 'Azure DevOps') {
        Mock Select-FromMenu { if ($Title -like '*project*') { 1 } else { 0 } }
        Mock New-AzDoProject { [pscustomobject]@{ name = 'shared'; id = 'new-project-id' } }
        Mock Get-AzDoExtensionModeFromWorkingTree { [pscustomobject]@{ IsConfigured = $false; HasConflict = $true; UseAlm4DataverseExtension = $null; SourceFiles = @('EXPORT.yml', 'IMPORT.yml') } }
        Mock Read-YesNo { $Prompt -notlike 'Use ALM4Dataverse*' }
        $script:extensionsInstalled = $false
        Mock Get-VSTeamExtension { if ($script:extensionsInstalled) { [pscustomobject]@{ publisherId = 'microsoft-IsvExpTools'; extensionId = 'PowerPlatform-BuildTools'; version = '1' } } }
        Mock Add-VSTeamExtension { $script:extensionsInstalled = $true }
        $result = Initialize-AzDoProjectAndRepository
        $result.SelectedProject.Name | Should -Be shared
        Should -Invoke New-AzDoProject -Times 1 -Exactly -ParameterFilter { $ProjectName -eq 'shared' -and $Visibility -eq 'private' }
        Should -Invoke Add-VSTeamExtension -Times 1 -Exactly -ParameterFilter {
            $PublisherId -eq 'microsoft-IsvExpTools' -and $ExtensionId -eq 'PowerPlatform-BuildTools'
        }
    }

    Context 'Branch publication with generated files' {
        BeforeEach {
            $script:publishRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item $script:publishRoot -ItemType Directory | Out-Null
            $script:publishHasChanges = $true
            $script:publishTargetExists = $true
            $script:publishDefaultExists = $true
            $script:publishHeadExists = $true
            $script:publishFailureCommand = ''
            $script:publishExistingPr = $false
            $script:publishPlan = [pscustomobject]@{ Mode = 'Direct'; BranchName = 'release'; TargetBranch = 'release'; CommitMessage = 'Setup'; PullRequestTitle = 'Setup'; PullRequestDescription = 'Configure automation' }
            Mock git {
                $global:LASTEXITCODE = 0
                # Git diff uses 1 for changes, unlike the failure codes simulated below.
                if ($args -contains 'diff' -and $script:publishHasChanges) { $global:LASTEXITCODE = 1 }
                if ($args -contains 'ls-remote') {
                    $exists = if ($args[-1] -eq 'release') { $script:publishTargetExists } else { $script:publishDefaultExists }
                    if (-not $exists) { $global:LASTEXITCODE = 2 }
                }
                if ($args -contains 'rev-parse' -and -not $script:publishHeadExists) { $global:LASTEXITCODE = 1 }
                if ($script:publishFailureCommand -and $args -contains $script:publishFailureCommand) { $global:LASTEXITCODE = 1 }
            }
            Mock gh {
                $global:LASTEXITCODE = 0
                if ($args -contains 'list') {
                    if ($script:publishExistingPr) { '[{"number":7,"url":"https://example.invalid/pr/7"}]' }
                    else { '[]' }
                }
                elseif ($args -contains 'create') { 'https://example.invalid/pr/7' }
            }
            $script:publicationParameters = @{
                RepoRoot = $script:publishRoot; ConfiguredBranch = 'release'; DefaultBranch = 'main'
                PublishPlan = $script:publishPlan; CopyRoot = (Join-Path $repoRoot 'copy-to-your-repo')
                Solutions = @(@{ name = 'Example'; deployUnmanaged = $false })
                DeploymentEnvironments = @([pscustomobject]@{ ShortName = 'TEST' })
                BuildValidationEnabled = $true; BuildValidationEnvironmentName = 'Build'; BuildValidationBaselineRelease = '@TEST'
            }
            if ($Provider -eq 'GitHub') {
                $script:publicationHelper = 'Publish-GitHubBranchSetupChange'
                $script:publicationParameters.SharedWorkflowRepository = 'owner/shared'
                $script:publicationParameters.SharedWorkflowReference = 'stable'
                $script:publicationParameters.PromotionMode = 'environment-approval'
            }
            else {
                $script:publicationHelper = 'Publish-AzDoBranchSetupChange'
                $script:publicationParameters.AccessToken = 'fake-token'
                $script:publicationParameters.Repository = [pscustomobject]@{ Id = 'repo-id'; Name = 'repo' }
                $script:publicationParameters.SharedRepositoryName = 'shared'
                $script:publicationParameters.UseAlm4DataverseExtension = $false
                Mock New-AzDoPullRequest { [pscustomobject]@{ _links = [pscustomobject]@{ web = [pscustomobject]@{ href = 'https://example.invalid/pr/7' } }; url = 'https://example.invalid/pr/7' } }
            }
        }

        It 'publishes <Mode> changes from an existing or seeded branch' -ForEach @(
            @{ Mode = 'Direct'; TargetExists = $true; DefaultExists = $true }
            @{ Mode = 'Direct'; TargetExists = $false; DefaultExists = $false }
            @{ Mode = 'PullRequest'; TargetExists = $true; DefaultExists = $true }
            @{ Mode = 'PullRequest'; TargetExists = $false; DefaultExists = $true }
            @{ Mode = 'PullRequest'; TargetExists = $false; DefaultExists = $false }
        ) {
            $script:publishPlan.Mode = $Mode
            $script:publishTargetExists = $TargetExists
            $script:publishDefaultExists = $DefaultExists
            $script:publishHeadExists = $TargetExists
            if ($Mode -eq 'PullRequest') { $script:publishPlan.BranchName = 'setup/release' }
            $originalLocation = (Get-Location).Path
            $originalPreference = $ErrorActionPreference
            $result = & $script:publicationHelper @script:publicationParameters
            $result.HasChanges | Should -BeTrue
            $result.TargetBranch | Should -Be release
            $result.Mode | Should -Be $Mode
            if ($Mode -eq 'PullRequest') { $result.PullRequestUrl | Should -Be 'https://example.invalid/pr/7' }
            if ($Provider -eq 'GitHub' -and $Mode -eq 'Direct' -and -not $TargetExists -and -not $DefaultExists) {
                Should -Invoke git -Times 1 -Exactly -ParameterFilter { $args -contains '--orphan' -and $args -contains 'release' }
            }
            (Get-Location).Path | Should -Be $originalLocation
            $ErrorActionPreference | Should -Be $originalPreference
            (Import-PowerShellDataFile (Join-Path $script:publishRoot 'alm-config.psd1')).solutions[0].name | Should -Be Example
            Should -Invoke git -Times 1 -Exactly -ParameterFilter { $args -contains 'commit' -and $args -contains '-m' -and $args -contains 'Setup' }
        }

        It 'ensures an unchanged branch exists without committing or opening a PR' {
            $script:publishHasChanges = $false
            $result = & $script:publicationHelper @script:publicationParameters
            $result.HasChanges | Should -BeFalse
            $result.PullRequestUrl | Should -BeNullOrEmpty
            Should -Invoke git -Times 0 -Exactly -ParameterFilter { $args -contains 'commit' }
            Should -Invoke git -Times 1 -Exactly -ParameterFilter { $args -contains 'push' }
            if ($Provider -eq 'GitHub') { Should -Invoke gh -Times 0 -Exactly }
            else { Should -Invoke New-AzDoPullRequest -Times 0 -Exactly }
        }

        It 'restores location and preference after a failed <Command>' -ForEach @(
            @{ Command = 'fetch' }
            @{ Command = 'checkout' }
            @{ Command = 'add' }
            @{ Command = 'commit' }
            @{ Command = 'push' }
        ) {
            $script:publishFailureCommand = $Command
            $originalLocation = (Get-Location).Path
            $originalPreference = $ErrorActionPreference
            { & $script:publicationHelper @script:publicationParameters } | Should -Throw
            (Get-Location).Path | Should -Be $originalLocation
            $ErrorActionPreference | Should -Be $originalPreference
        }

        It 'updates an existing GitHub pull request rather than creating another' -Skip:($Provider -ne 'GitHub') {
            $script:publishPlan.Mode = 'PullRequest'
            $script:publishExistingPr = $true
            $result = & $script:publicationHelper @script:publicationParameters
            $result.PullRequestUrl | Should -Be 'https://example.invalid/pr/7'
            Should -Invoke gh -Times 1 -Exactly -ParameterFilter { $args -contains 'edit' }
            Should -Invoke gh -Times 0 -Exactly -ParameterFilter { $args -contains 'create' }
        }
    }
}

Describe 'Repository discovery and synchronization in <Provider>' -ForEach @(
    @{ Provider = 'GitHub'; Source = 'setup-github.ps1' }
    @{ Provider = 'Azure DevOps'; Source = 'setup-azdo.ps1' }
) {
    BeforeAll {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $Source), [ref]$tokens, [ref]$parseErrors)
        foreach ($definition in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
            Set-Item -Path "Function:$($definition.Name)" -Value $definition.Body.GetScriptBlock()
        }
    }

    BeforeEach {
        $script:discoveryExitCode = Get-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
        $global:LASTEXITCODE = 0
        $script:discoveryRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item (Join-Path $script:discoveryRoot '.github/workflows') -ItemType Directory -Force | Out-Null
        Set-Content (Join-Path $script:discoveryRoot '.github/workflows/BUILD.yml') 'uses: owner/shared/.github/actions/build@stable'
        $script:discoveryEmpty = $false
        $script:syncFastForward = $false
        $script:syncAhead = $false
        $script:syncFailure = ''
        Mock git {
            $global:LASTEXITCODE = 0
            if ($script:syncFailure -and $args -contains $script:syncFailure) { $global:LASTEXITCODE = 1; 'Simulated native failure'; return }
            if ($args -contains 'for-each-ref') { if (-not $script:discoveryEmpty) { 'origin/main'; 'origin/release'; 'origin/HEAD' } }
            elseif ($args -contains 'ls-tree') {
                if ($Provider -eq 'GitHub') { '.github/workflows/BUILD.yml'; '.github/workflows/DEPLOY-main.yml'; '.github/workflows/DEPLOY-release.yml' }
                else { 'pipelines/BUILD.yml'; 'pipelines/DEPLOY-main.yml'; 'pipelines/DEPLOY-release.yml' }
            }
            elseif ($args -contains 'show') {
                if ($args[-1] -like '*alm-config.psd1') { '@{ solutionCheck = @{ enabled = $true } }' }
                elseif ($Provider -eq 'GitHub') { "environment-name: 'TEST'`nenvironment-name: 'Missing'" }
                else { "environmentName: 'TEST'`nenvironmentName: 'Missing'`nbuildEnvironmentName: 'Build'" }
            }
            elseif ($args -contains 'ls-remote') { 'bbbb refs/heads/stable' }
            elseif ($args -contains 'rev-parse') { if ($args[-1] -eq 'HEAD') { 'aaaa' } else { 'bbbb' } }
            elseif ($args -contains 'merge-base') {
                $ancestor = if ($args[-2] -eq 'HEAD') { $script:syncFastForward } else { $script:syncAhead }
                if (-not $ancestor) { $global:LASTEXITCODE = 1 }
            }
            elseif ($args[-1] -eq 'remote') { 'upstream-github' }
        }
        Mock gh {
            $global:LASTEXITCODE = 0
            if ($script:syncFailure -eq 'clone') { $global:LASTEXITCODE = 1; 'Simulated clone failure' }
        }
        if ($Provider -eq 'GitHub') {
            Mock Resolve-GitTargetRefFromRemote { 'upstream/stable' }
            Mock Get-GitHubExistingEnvironmentState {
                if ($EnvironmentName -eq 'Missing') { return $null }
                [pscustomobject]@{ ShortName = $EnvironmentName; FriendlyName = $EnvironmentName; Url = 'https://test.example.com'; Credentials = $null; ServiceAccountUPN = 'service@example.com'; StorageScope = 'Environment' }
            }
        }
        else {
            Mock Get-VSTeamBuildDefinition { if (-not $script:discoveryEmpty) { [pscustomobject]@{ name = 'DEPLOY-release'; process = $null } } }
            Mock Get-AzDoExistingEnvironmentState {
                if ($EnvironmentName -eq 'Missing') { return $null }
                [pscustomobject]@{ ShortName = $EnvironmentName; FriendlyName = $EnvironmentName; Url = 'https://test.example.com'; Credentials = $null; ServiceAccountUPN = 'service@example.com' }
            }
        }
    }

    AfterEach {
        if ($script:discoveryExitCode) { $global:LASTEXITCODE = $script:discoveryExitCode.Value }
        else { Remove-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue }
    }

    It 'discovers mapped branches and validation state from repository content' {
        if ($Provider -eq 'GitHub') {
            $result = Get-GitHubRepositoryExistingSetupState -RepoRoot $script:discoveryRoot -RepoOwner owner -RepoName repo -DefaultBranch main -TenantId example.com
            $result.DeploymentBranchMappings.BranchName | Should -Be @('main', 'release')
            $result.DeploymentEnvironments.ShortName | Should -Be @('TEST', 'Missing')
            $result.DeploymentEnvironments[1].Credentials | Should -BeNullOrEmpty
            $result.SharedWorkflowRepository | Should -Be 'owner/shared'
            $result.SharedWorkflowReference | Should -Be stable
            $result.CredentialStorageScope | Should -Be Environment
        }
        else {
            $result = Get-AzDoRepositoryExistingSetupState -RepoRoot $script:discoveryRoot -ProjectName project -DefaultBranch main -TenantId example.com
            $result.BranchStates.BranchName | Should -Be @('main', 'release')
            $result.BranchStates[0].DeploymentEnvironments.ShortName | Should -Be TEST
            $result.BuildValidationEnvironmentName | Should -Be Build
        }
        $result.BuildValidationEnabled | Should -BeTrue
    }

    It 'retains the default branch when no deployment mapping exists' {
        $script:discoveryEmpty = $true
        if ($Provider -eq 'GitHub') {
            $result = Get-GitHubRepositoryExistingSetupState -RepoRoot $script:discoveryRoot -RepoOwner owner -RepoName repo -DefaultBranch main
            $result.DeploymentBranchMappings[0].BranchName | Should -Be main
            $result.DeploymentBranchMappings[0].Environments.Count | Should -Be 0
        }
        else {
            $result = Get-AzDoRepositoryExistingSetupState -RepoRoot $script:discoveryRoot -ProjectName project -DefaultBranch main
            $result.BranchStates[0].BranchName | Should -Be main
            $result.BranchStates[0].DeploymentEnvironments.Count | Should -Be 0
        }
    }

    It 'classifies divergent, fast-forward and ahead repository histories' -ForEach @(
        @{ FastForward = $false; Ahead = $false }
        @{ FastForward = $true; Ahead = $false }
        @{ FastForward = $false; Ahead = $true }
    ) {
        $script:syncFastForward = $FastForward
        $script:syncAhead = $Ahead
        if ($Provider -eq 'GitHub') {
            $result = Get-GitHubForkSyncState -ForkFullName owner/shared -WorkRoot $script:discoveryRoot -UpstreamGitSource https://example.invalid/shared -UpstreamFullName upstream/shared -Reference stable -DefaultBranch main
        }
        else {
            $result = Get-AzDoSharedRepositorySyncState -RepositoryRemoteUrl https://example.invalid/shared -WorkRoot $script:discoveryRoot -UpstreamGitSource https://example.invalid/upstream -Reference stable -AccessToken fake-token
        }
        $result.LocalHash | Should -Be aaaa
        $result.UpstreamHash | Should -Be bbbb
        $result.CanFastForward | Should -Be $FastForward
        $result.IsAhead | Should -Be $Ahead
    }

    It 'reports clone failure and restores error preference' {
        $script:syncFailure = 'clone'
        $originalPreference = $ErrorActionPreference
        if ($Provider -eq 'GitHub') {
            { Get-GitHubForkSyncState -ForkFullName owner/shared -WorkRoot $script:discoveryRoot -UpstreamGitSource https://example.invalid/shared -UpstreamFullName upstream/shared -Reference stable -DefaultBranch main } | Should -Throw '*clone*'
        }
        else {
            { Get-AzDoSharedRepositorySyncState -RepositoryRemoteUrl https://example.invalid/shared -WorkRoot $script:discoveryRoot -UpstreamGitSource https://example.invalid/upstream -Reference stable -AccessToken fake-token } | Should -Throw '*clone*'
        }
        $ErrorActionPreference | Should -Be $originalPreference
    }
}

Describe '<Provider> scaffold re-sync' -ForEach @(
    @{ Provider = 'GitHub'; Script = 'setup-github.ps1' }
    @{ Provider = 'AzDo'; Script = 'setup-azdo.ps1' }
) {
    BeforeAll {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $Script), [ref]$tokens, [ref]$parseErrors)
        foreach ($definition in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
            Set-Item -Path "Function:$($definition.Name)" -Value $definition.Body.GetScriptBlock()
        }
    }

    BeforeEach {
        Mock Write-Section {}
        $script:scaffoldSource = Join-Path $TestDrive "source-$([guid]::NewGuid().ToString('N'))"
        $script:scaffoldTarget = Join-Path $TestDrive "target-$([guid]::NewGuid().ToString('N'))"
        foreach ($relativePath in @('AGENTS.md', 'data/system/import.ps1', 'pipelines/BUILD.yml', 'pipelines/DEPLOY-main.yml', 'README-scaffold.md')) {
            $path = Join-Path $script:scaffoldSource $relativePath
            New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
            Set-Content -LiteralPath $path -Value "scaffold $relativePath" -NoNewline
        }
        New-Item -ItemType Directory -Path $script:scaffoldTarget | Out-Null

        $script:invokeScaffoldSync = {
            if ($Provider -eq 'GitHub') {
                Copy-WorkflowTemplatesToRepo -SourceRoot $script:scaffoldSource -TargetRoot $script:scaffoldTarget -Branch main -SharedWorkflowRepository owner/shared -SharedWorkflowRef stable
            }
            else {
                Sync-CopyToYourRepoIntoGitRepo -SourceRoot $script:scaffoldSource -TargetRoot $script:scaffoldTarget -RepositoryName app -SharedRepositoryName shared -Branch main
            }
        }
    }

    It 'creates application-owned files when missing' {
        & $script:invokeScaffoldSync

        Get-Content -LiteralPath (Join-Path $script:scaffoldTarget 'AGENTS.md') -Raw | Should -Be 'scaffold AGENTS.md'
        Get-Content -LiteralPath (Join-Path $script:scaffoldTarget 'data/system/import.ps1') -Raw | Should -Be 'scaffold data/system/import.ps1'
    }

    It 'keeps customized application-owned files and still refreshes other scaffold files' {
        foreach ($relativePath in @('AGENTS.md', 'data/system/import.ps1', 'README-scaffold.md')) {
            $path = Join-Path $script:scaffoldTarget $relativePath
            New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
            Set-Content -LiteralPath $path -Value 'customized' -NoNewline
        }

        & $script:invokeScaffoldSync

        Get-Content -LiteralPath (Join-Path $script:scaffoldTarget 'AGENTS.md') -Raw | Should -Be 'customized'
        Get-Content -LiteralPath (Join-Path $script:scaffoldTarget 'data/system/import.ps1') -Raw | Should -Be 'customized'
        Get-Content -LiteralPath (Join-Path $script:scaffoldTarget 'README-scaffold.md') -Raw | Should -Be 'scaffold README-scaffold.md'
    }

    It 'leaves existing Azure DevOps BUILD and DEPLOY callers for the pipeline updaters' {
        if ($Provider -ne 'AzDo') { Set-ItResult -Skipped -Because 'GitHub callers live under .github/workflows and are covered by workflow generation tests'; return }
        New-Item -ItemType Directory -Path (Join-Path $script:scaffoldTarget 'pipelines') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:scaffoldTarget 'pipelines/BUILD.yml') -Value 'customized build' -NoNewline
        Set-Content -LiteralPath (Join-Path $script:scaffoldTarget 'pipelines/DEPLOY-main.yml') -Value 'customized deploy' -NoNewline

        & $script:invokeScaffoldSync

        Get-Content -LiteralPath (Join-Path $script:scaffoldTarget 'pipelines/BUILD.yml') -Raw | Should -Be 'customized build'
        Get-Content -LiteralPath (Join-Path $script:scaffoldTarget 'pipelines/DEPLOY-main.yml') -Raw | Should -Be 'customized deploy'
    }

    It 'refreshes the Azure DevOps EXPORT caller but keeps its secretVariables block' {
        if ($Provider -ne 'AzDo') { Set-ItResult -Skipped -Because 'GitHub secret mappings are covered by secrets-json merge tests'; return }
        Set-Content -LiteralPath (Join-Path $script:scaffoldSource 'pipelines/EXPORT.yml') -Value @"
resources:
  repositories:
    - repository: ALM4Dataverse
      name: ALM4Dataverse
stages:
- template: pipelines/templates/export.yml@ALM4Dataverse
  parameters:
    useAlm4DataverseExtension: true
    # secretVariables:
"@
        New-Item -ItemType Directory -Path (Join-Path $script:scaffoldTarget 'pipelines') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:scaffoldTarget 'pipelines/EXPORT.yml') -Value @"
stages:
- template: pipelines/templates/export.yml@ALM4Dataverse
  parameters:
    useAlm4DataverseExtension: true
    secretVariables:
    - DataverseEnvVar_contoso_APIKey
      # nested comment
    - DataverseEnvVar_contoso_Other
"@

        & $script:invokeScaffoldSync

        $content = Get-Content -LiteralPath (Join-Path $script:scaffoldTarget 'pipelines/EXPORT.yml') -Raw
        $content | Should -Match '(?m)^\s+name: shared\s*$'
        $content | Should -Match '(?m)^    secretVariables:\r?\n    - DataverseEnvVar_contoso_APIKey\r?\n      # nested comment\r?\n    - DataverseEnvVar_contoso_Other\s*$'
    }

    It 'returns an empty secretVariables block for a missing caller or a caller without one' {
        if ($Provider -ne 'AzDo') { Set-ItResult -Skipped -Because 'Azure DevOps helper only'; return }
        Get-AzDoCallerSecretVariableBlock -Path (Join-Path $script:scaffoldTarget 'missing.yml') | Should -BeExactly ''
        Get-AzDoCallerSecretVariableBlock -Path (Join-Path $script:scaffoldSource 'pipelines/BUILD.yml') | Should -BeExactly ''
    }
}