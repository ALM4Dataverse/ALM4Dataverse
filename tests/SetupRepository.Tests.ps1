BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repoRoot 'setup/setup-common.ps1')
    . (Join-Path $repoRoot 'tests/helpers/SetupTestHelpers.ps1')
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
        $ast = Get-SetupProviderAst -RepositoryRoot $repoRoot -EntryPoint 'setup-azdo.ps1'
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

    It 'loads the caller pipeline helper before preparing the main repository working tree' {
        $tokens = $null
        $parseErrors = $null
        $entrypointAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'setup-azdo.ps1'), [ref]$tokens, [ref]$parseErrors)
        $providerAst = Get-SetupProviderAst -RepositoryRoot $repoRoot -EntryPoint 'setup-azdo.ps1'
        $helperDefinition = $providerAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-AzDoCallerSecretVariableBlock'
        }, $true)
        $helperLoad = $entrypointAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.IfStatementAst] -and
            $node.Extent.Text.Contains('$setupAzDoSourcePath') -and
            $node.Extent.Text.Contains('__SETUP_AZDO_LIB__')
        }, $true)
        $setupStep = $entrypointAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Invoke-WithErrorHandling' -and
            $node.Extent.Text.Contains('Preparing main repository working tree')
        }, $true)

        $helperDefinition | Should -Not -BeNullOrEmpty
        $helperLoad | Should -Not -BeNullOrEmpty
        $setupStep | Should -Not -BeNullOrEmpty
        $helperLoad.Extent.StartOffset | Should -BeLessThan $setupStep.Extent.StartOffset
    }

    It 'selects the preferred shared repository while excluding the application repository' {
        $result = Select-AzDoSharedRepository -ProjectName project -PreferredRepositoryName shared -ExcludeRepositoryName main
        $result.Id | Should -Be shared-id
        Should -Invoke Add-VSTeamGitRepository -Times 0 -Exactly
        Should -Invoke Select-FromMenu -Times 1 -Exactly -ParameterFilter { @($Items).Count -eq 2 -and $Items[0] -like 'Use current*' }
    }

    It 'automatically uses an accessible preferred shared repository' {
        $result = Select-AzDoSharedRepository -ProjectName project -PreferredRepositoryName shared -ExcludeRepositoryName main -UsePreferredIfAvailable
        $result.Id | Should -Be shared-id
        Should -Invoke Select-FromMenu -Times 0 -Exactly
    }

    It 'opens the selection menu when the preferred shared repository is inaccessible' {
        Mock Get-VSTeamGitRepository {
            [pscustomobject]@{ Id = 'replacement-id'; Name = 'replacement'; remoteUrl = 'https://example.invalid/replacement' }
        }
        $script:repoMenuIndex = 0

        $result = Select-AzDoSharedRepository -ProjectName project -PreferredRepositoryName missing -UsePreferredIfAvailable

        $result.Name | Should -Be replacement
        Should -Invoke Select-FromMenu -Times 1 -Exactly
    }

    It 'does not prompt when a required preferred shared repository is inaccessible' {
        Mock Get-VSTeamGitRepository {
            [pscustomobject]@{ Id = 'main-id'; Name = 'main' }
        }

        { Select-AzDoSharedRepository -ProjectName project -PreferredRepositoryName missing -UsePreferredIfAvailable -RequirePreferred } |
            Should -Throw '*not accessible*'
        Should -Invoke Select-FromMenu -Times 0 -Exactly
    }

    It 'validates a preferred shared repository without prompting' {
        $result = Select-AzDoSharedRepository -ProjectName project -PreferredRepositoryName shared -ValidatePreferredOnly

        $result.Name | Should -Be shared
        Should -Invoke Select-FromMenu -Times 0 -Exactly
    }

    It 'returns no repository when preferred-only validation cannot find it' {
        Mock Get-VSTeamGitRepository {
            [pscustomobject]@{ Id = 'main-id'; Name = 'main' }
        }

        $result = Select-AzDoSharedRepository -ProjectName project -PreferredRepositoryName missing -ValidatePreferredOnly

        $result | Should -BeNullOrEmpty
        Should -Invoke Select-FromMenu -Times 0 -Exactly
    }

    It 'updates shared repository state from the local scaffold and removes an old clone' {
        $localCopyRoot = Join-Path $TestDrive 'local-copy-to-your-repo'
        $previousClone = Join-Path $TestDrive 'previous-shared-clone'
        New-Item -ItemType Directory -Path $localCopyRoot, $previousClone -Force | Out-Null
        $state = [ordered]@{
            Repository = $null
            Name = ''
            Ref = ''
            CopyRoot = $localCopyRoot
            ClonePath = $previousClone
            UsesLocalCopyRoot = $true
            ValidationError = 'Configured shared repository was unavailable.'
        }
        $initialization = [pscustomobject]@{
            SharedRepo = $script:workingRepository
            SharedRepoName = 'shared'
            SharedRepositoryRef = 'stable'
            SharedRepositorySelectionError = ''
        }

        $result = Set-AzDoSharedRepositoryState `
            -RepositoryState $state `
            -Initialization $initialization `
            -AccessToken fake-token `
            -UpstreamGitSource https://example.invalid/upstream

        $result.Name | Should -Be shared
        $result.Ref | Should -Be stable
        $result.CopyRoot | Should -Be $localCopyRoot
        $result.ValidationError | Should -Be ''
        (Test-Path -LiteralPath $previousClone) | Should -BeFalse
        Should -Invoke git -Times 0 -Exactly
    }

    It 'does not prepare shared repository state when WhatIf is requested' {
        $state = [ordered]@{
            Repository = $null
            Name = ''
            Ref = ''
            CopyRoot = $null
            ClonePath = $null
            UsesLocalCopyRoot = $false
        }
        $initialization = [pscustomobject]@{
            SharedRepo = $script:workingRepository
            SharedRepoName = 'shared'
            SharedRepositoryRef = 'stable'
        }

        $result = Set-AzDoSharedRepositoryState `
            -RepositoryState $state `
            -Initialization $initialization `
            -AccessToken fake-token `
            -UpstreamGitSource https://example.invalid/upstream `
            -WhatIf

        $result.Name | Should -Be ''
        $result.CopyRoot | Should -BeNullOrEmpty
        Should -Invoke git -Times 0 -Exactly
    }

    It 'clones the selected repository as the template source when no local scaffold exists' {
        Mock git {
            $global:LASTEXITCODE = 0
            if ($args -contains 'clone') {
                $destination = [string]$args[-1]
                New-Item -ItemType Directory -Path (Join-Path $destination 'copy-to-your-repo') -Force | Out-Null
            }
        }
        $state = [ordered]@{
            Repository = $null
            Name = ''
            Ref = ''
            CopyRoot = $null
            ClonePath = $null
            UsesLocalCopyRoot = $false
        }
        $initialization = [pscustomobject]@{
            SharedRepo = $script:workingRepository
            SharedRepoName = 'shared'
            SharedRepositoryRef = 'stable'
        }

        try {
            $result = Set-AzDoSharedRepositoryState `
                -RepositoryState $state `
                -Initialization $initialization `
                -AccessToken fake-token `
                -UpstreamGitSource https://example.invalid/upstream

            $result.CopyRoot | Should -Be (Join-Path $result.ClonePath 'copy-to-your-repo')
            (Test-Path -LiteralPath $result.CopyRoot -PathType Container) | Should -BeTrue
            Should -Invoke git -Times 1 -Exactly -ParameterFilter { $args -contains 'clone' }
        }
        finally {
            if ($state.ClonePath -and (Test-Path -LiteralPath $state.ClonePath)) {
                Remove-Item -LiteralPath $state.ClonePath -Recurse -Force
            }
        }
    }

    It 'uses upstream templates while a newly selected shared repository is empty' {
        $script:sharedCloneCount = 0
        Mock git {
            $global:LASTEXITCODE = 0
            if ($args -contains 'clone') {
                $script:sharedCloneCount++
                New-Item -ItemType Directory -Path $args[-1] -Force | Out-Null
                if ($script:sharedCloneCount -eq 2) {
                    New-Item -ItemType Directory -Path (Join-Path $args[-1] 'copy-to-your-repo') -Force | Out-Null
                }
            }
            elseif ($args -contains 'rev-parse') {
                $global:LASTEXITCODE = 128
            }
        }
        $state = [ordered]@{
            Repository = $null
            Name = ''
            Ref = ''
            CopyRoot = $null
            ClonePath = $null
            UsesLocalCopyRoot = $false
        }
        $initialization = [pscustomobject]@{
            SharedRepo = $script:workingRepository
            SharedRepoName = 'new-shared'
            SharedRepositoryRef = 'main'
        }

        try {
            $result = Set-AzDoSharedRepositoryState `
                -RepositoryState $state `
                -Initialization $initialization `
                -AccessToken fake-token `
                -UpstreamGitSource https://example.invalid/upstream

            $result.ClonePath | Should -Match 'ALM4Dataverse-UpstreamTemplates-'
            (Test-Path -LiteralPath $result.CopyRoot -PathType Container) | Should -BeTrue
            $script:sharedCloneCount | Should -Be 2
        }
        finally {
            if ($state.ClonePath -and (Test-Path -LiteralPath $state.ClonePath)) {
                Remove-Item -LiteralPath $state.ClonePath -Recurse -Force
            }
        }
    }

    It 'uses upstream templates while shared repository selection is deferred' -ForEach @(
        @{ SharedRepositoryName = 'missing'; SelectionError = "Configured shared repository 'missing' was not found or accessible in project 'project'." }
        @{ SharedRepositoryName = ''; SelectionError = 'No shared repository is configured in alm-config.psd1.' }
    ) {
        $previousTempDirectory = $env:TMPDIR
        $env:TMPDIR = $TestDrive
        Mock git {
            $global:LASTEXITCODE = 0
            if ($args -contains 'clone') {
                New-Item -ItemType Directory -Path (Join-Path ([string]$args[-1]) 'copy-to-your-repo') -Force | Out-Null
            }
        }
        $state = [ordered]@{
            Repository = $null
            Name = $SharedRepositoryName
            Ref = 'stable'
            CopyRoot = $null
            ClonePath = $null
            UsesLocalCopyRoot = $false
            ValidationError = $SelectionError
        }
        $initialization = [pscustomobject]@{
            SharedRepo = $null
            SharedRepoName = $SharedRepositoryName
            SharedRepositoryRef = 'stable'
            SharedRepositorySelectionError = $SelectionError
        }

        try {
            $result = Set-AzDoSharedRepositoryState `
                -RepositoryState $state `
                -Initialization $initialization `
                -AccessToken fake-token `
                -UpstreamGitSource https://example.invalid/upstream

            $result.Repository | Should -BeNullOrEmpty
            $result.Name | Should -Be $SharedRepositoryName
            $result.Ref | Should -Be stable
            $result.ValidationError | Should -Be $SelectionError
            $result.ClonePath | Should -Match 'ALM4Dataverse-UpstreamTemplates-'
            (Test-Path -LiteralPath $result.CopyRoot -PathType Container) | Should -BeTrue
            Should -Invoke git -Times 1 -Exactly -ParameterFilter { $args -contains 'clone' }
        }
        finally {
            $env:TMPDIR = $previousTempDirectory
            if ($state.ClonePath -and (Test-Path -LiteralPath $state.ClonePath)) {
                Remove-Item -LiteralPath $state.ClonePath -Recurse -Force
            }
        }
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

    It 'limits existing-repository and config application to existing application repositories' {
        $result = Select-AzDoMainRepository -ProjectName project -ExistingOnly
        $result.Id | Should -Be main-id
        Should -Invoke Select-FromMenu -Times 1 -Exactly -ParameterFilter { @($Items).Count -eq 2 -and $Items -notcontains 'Create a new repository' }
        Should -Invoke Add-VSTeamGitRepository -Times 0 -Exactly

        Mock Get-VSTeamGitRepository {}
        { Select-AzDoMainRepository -ProjectName project -ExistingOnly } |
            Should -Throw '*Existing-repository setup requires an existing application repository*'
        { Select-AzDoMainRepository -ProjectName project -ExistingOnly -ApplyConfig } |
            Should -Throw '*ApplyConfig requires an existing application repository*'
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

    It 'reads extension mode, shared repository and branch mappings only from alm-config.psd1' {
        $root = Join-Path $TestDrive 'existing'
        New-Item (Join-Path $root pipelines) -ItemType Directory -Force | Out-Null
        (Get-AzDoExtensionModeFromWorkingTree -RepoRoot $root -Branch main).IsConfigured | Should -BeFalse
        Set-Content (Join-Path $root 'pipelines/EXPORT.yml') 'useAlm4DataverseExtension: true'
        Set-Content (Join-Path $root 'pipelines/IMPORT.yml') 'useAlm4DataverseExtension: false'
        Set-Content (Join-Path $root 'pipelines/BUILD.yml') "repository: ALM4Dataverse`ntype: git`nname: shared"
        Set-Content (Join-Path $root 'pipelines/DEPLOY-main.yml') "environmentName: 'TEST'`nenvironmentName: 'TEST'`nenvironmentName: 'PROD'"
        $unconfiguredExtensionMode = Get-AzDoExtensionModeFromWorkingTree -RepoRoot $root -Branch main
        $unconfiguredExtensionMode.IsConfigured | Should -BeFalse
        $unconfiguredExtensionMode.HasConflict | Should -BeFalse
        Get-AzDoSharedRepositoryNameFromWorkingTree -RepoRoot $root -Branch main | Should -BeNullOrEmpty
        Get-AzDoDeploymentEnvironmentNamesFromWorkingTree -RepoRoot $root -Branch main | Should -BeNullOrEmpty

        $configPath = Join-Path $root 'alm-config.psd1'
        Set-Content $configPath "@{ provider = 'azDO'; repository = 'shared'; ref = 'stable'; azDOUseAlm4DataverseExtension = `$false; branches = @{} }"
        $configuredExtensionMode = Get-AzDoExtensionModeFromWorkingTree -RepoRoot $root -Branch main
        $configuredExtensionMode.IsConfigured | Should -BeTrue
        $configuredExtensionMode.HasConflict | Should -BeFalse
        $configuredExtensionMode.UseAlm4DataverseExtension | Should -BeFalse
        $configuredExtensionMode.SourceFiles | Should -Be @($configPath)
        Get-AzDoSharedRepositoryNameFromWorkingTree -RepoRoot $root -Branch main | Should -Be 'shared'
        Get-AzDoDeploymentEnvironmentNamesFromWorkingTree -RepoRoot $root -Branch main | Should -BeNullOrEmpty

        Set-Content $configPath "@{ provider = 'azDO'; repository = 'shared'; ref = 'stable'; azDOUseAlm4DataverseExtension = `$false; branches = @{ main = @{ deploymentEnvironments = @('Configured') } } }"
        Get-AzDoDeploymentEnvironmentNamesFromWorkingTree -RepoRoot $root -Branch main | Should -Be @('Configured')
    }
}

Describe 'GitHub clone base branch initialization' {
    BeforeAll {
        $ast = Get-SetupProviderAst -RepositoryRoot $repoRoot -EntryPoint 'setup-github.ps1'
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
        $ast = Get-SetupProviderAst -RepositoryRoot $repoRoot -EntryPoint $Source
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

    It 'uses the preferred GitHub repository without prompting or checking its version' -Skip:($Provider -ne 'GitHub') {
        $result = Initialize-GitHubSharedWorkflowFork `
            -UpstreamFullName upstream/shared `
            -DefaultOwner owner `
            -UpstreamGitSource $repoRoot `
            -Reference stable `
            -PreferredRepositoryFullName owner/shared `
            -SelectOnly `
            -UsePreferredRepository

        $result.nameWithOwner | Should -Be owner/shared
        Should -Invoke Get-GitHubRepo -Times 1 -Exactly
        Should -Invoke Get-GitHubAccessibleRepository -Times 0 -Exactly
        Should -Invoke Get-GitHubForkSyncState -Times 0 -Exactly
        Should -Invoke Select-FromMenu -Times 0 -Exactly
    }

    It 'reports a missing configured GitHub shared repository without prompting' -Skip:($Provider -ne 'GitHub') {
        Mock Initialize-GitHubSharedWorkflowFork { throw 'Unexpected shared repository lookup.' }

        $result = Get-GitHubSharedWorkflowRepositoryValidationState `
            -Repository '' `
            -Reference '' `
            -UpstreamFullName upstream/shared `
            -DefaultOwner owner `
            -UpstreamGitSource $repoRoot `
            -ALM4DataverseRef stable

        $result.Repository | Should -Be ''
        $result.Reference | Should -Be ''
        $result.ValidationError | Should -Be 'No shared workflow repository is configured in alm-config.psd1.'
        Should -Invoke Initialize-GitHubSharedWorkflowFork -Times 0 -Exactly
    }

    It 'keeps an inaccessible GitHub shared repository incomplete with its lookup reason' -Skip:($Provider -ne 'GitHub') {
        Mock Initialize-GitHubSharedWorkflowFork { throw 'repository not found' }

        $result = Get-GitHubSharedWorkflowRepositoryValidationState `
            -Repository owner/missing `
            -Reference stable `
            -UpstreamFullName upstream/shared `
            -DefaultOwner owner `
            -UpstreamGitSource $repoRoot `
            -ALM4DataverseRef stable

        $result.Repository | Should -Be owner/missing
        $result.Reference | Should -Be stable
        $result.ValidationError | Should -Be "Could not access configured shared workflow repository 'owner/missing': repository not found"
        Should -Invoke Initialize-GitHubSharedWorkflowFork -Times 1 -Exactly -ParameterFilter {
            $UsePreferredRepository -and $SelectOnly -and $PreferredRepositoryFullName -eq 'owner/missing'
        }
    }

    It 'uses the configured ref or accessible repository default when validating GitHub state' -ForEach @(
        @{ ConfiguredReference = 'saved'; ExpectedReference = 'saved' }
        @{ ConfiguredReference = ''; ExpectedReference = 'stable' }
    ) -Skip:($Provider -ne 'GitHub') {
        $script:validationSharedWorkflowRepo = [pscustomobject]@{
            nameWithOwner = 'owner/shared'
            defaultBranchRef = [pscustomobject]@{ name = 'stable' }
        }
        Mock Initialize-GitHubSharedWorkflowFork { $script:validationSharedWorkflowRepo }

        $result = Get-GitHubSharedWorkflowRepositoryValidationState `
            -Repository owner/shared `
            -Reference $ConfiguredReference `
            -UpstreamFullName upstream/shared `
            -DefaultOwner owner `
            -UpstreamGitSource $repoRoot `
            -ALM4DataverseRef stable

        $result.Repository | Should -Be owner/shared
        $result.Reference | Should -Be $ExpectedReference
        $result.ValidationError | Should -Be ''
        Should -Invoke Initialize-GitHubSharedWorkflowFork -Times 1 -Exactly -ParameterFilter {
            $UsePreferredRepository -and $SelectOnly -and $PreferredRepositoryFullName -eq 'owner/shared'
        }
    }

    It 'allows selecting a GitHub shared repository when none is configured' -Skip:($Provider -ne 'GitHub') {
        $script:selectedSharedWorkflowRepo = [pscustomobject]@{
            nameWithOwner = 'owner/shared'
            defaultBranchRef = [pscustomobject]@{ name = 'stable' }
        }
        $script:sharedWorkflowRepositoryStateForTest = [ordered]@{
            Repository = ''
            Reference = ''
            ValidationError = 'No shared workflow repository is configured.'
        }
        Mock Initialize-GitHubSharedWorkflowFork { $script:selectedSharedWorkflowRepo }

        $result = Select-GitHubSharedWorkflowRepositoryState `
            -RepositoryState $script:sharedWorkflowRepositoryStateForTest `
            -UpstreamFullName upstream/shared `
            -DefaultOwner owner `
            -UpstreamGitSource $repoRoot `
            -Reference stable

        $result.Repository | Should -Be owner/shared
        $result.Reference | Should -Be stable
        $result.ValidationError | Should -Be ''
        Should -Invoke Initialize-GitHubSharedWorkflowFork -Times 1 -Exactly -ParameterFilter {
            [string]::IsNullOrWhiteSpace($PreferredRepositoryFullName) -and $SelectOnly
        }
    }

    It 'selects a GitHub shared repository without checking its version and preserves or defaults its ref' -ForEach @(
        @{ SelectedRepository = 'owner/updated'; DefaultBranch = 'stable'; ExpectedReference = 'stable' }
        @{ SelectedRepository = 'owner/current'; DefaultBranch = 'new-default'; ExpectedReference = 'saved' }
    ) -Skip:($Provider -ne 'GitHub') {
        $script:selectedSharedWorkflowRepo = [pscustomobject]@{
            nameWithOwner = $SelectedRepository
            defaultBranchRef = [pscustomobject]@{ name = $DefaultBranch }
        }
        $script:sharedWorkflowRepositoryStateForTest = [ordered]@{
            Repository = 'owner/current'
            Reference = 'saved'
            ValidationError = 'Configured repository was unavailable.'
        }
        Mock Initialize-GitHubSharedWorkflowFork { $script:selectedSharedWorkflowRepo }
        Mock Initialize-GitHubSharedWorkflowAccessPolicy {}

        $result = Select-GitHubSharedWorkflowRepositoryState `
            -RepositoryState $script:sharedWorkflowRepositoryStateForTest `
            -UpstreamFullName upstream/shared `
            -DefaultOwner owner `
            -UpstreamGitSource $repoRoot `
            -Reference stable

        $result.Repository | Should -Be $SelectedRepository
        $result.Reference | Should -Be $ExpectedReference
        $result.ValidationError | Should -Be ''
        Should -Invoke Initialize-GitHubSharedWorkflowFork -Times 1 -Exactly -ParameterFilter {
            $PreferredRepositoryFullName -eq 'owner/current' -and $Reference -eq 'stable' -and $SelectOnly
        }
        Should -Invoke Initialize-GitHubSharedWorkflowAccessPolicy -Times 0 -Exactly
    }

    It 'checks and updates the selected GitHub repository without prompting again' -Skip:($Provider -ne 'GitHub') {
        $script:selectedSharedWorkflowRepo = [pscustomobject]@{
            nameWithOwner = 'owner/current'
            defaultBranchRef = [pscustomobject]@{ name = 'main' }
        }
        $script:sharedWorkflowRepositoryStateForTest = [ordered]@{
            Repository = 'owner/current'
            Reference = 'saved'
        }
        Mock Initialize-GitHubSharedWorkflowFork { $script:selectedSharedWorkflowRepo }
        Mock Initialize-GitHubSharedWorkflowAccessPolicy {}

        $result = Update-GitHubSharedWorkflowRepositoryState `
            -RepositoryState $script:sharedWorkflowRepositoryStateForTest `
            -UpstreamFullName upstream/shared `
            -DefaultOwner owner `
            -UpstreamGitSource $repoRoot `
            -Reference stable

        $result.Repository | Should -Be owner/current
        $result.Reference | Should -Be saved
        Should -Invoke Initialize-GitHubSharedWorkflowFork -Times 1 -Exactly -ParameterFilter {
            $PreferredRepositoryFullName -eq 'owner/current' -and $UsePreferredRepository -and $Reference -eq 'stable'
        }
        Should -Invoke Initialize-GitHubSharedWorkflowAccessPolicy -Times 1 -Exactly -ParameterFilter {
            $Owner -eq 'owner' -and $Repo -eq 'current'
        }
    }

    It 'does not update the selected GitHub repository when WhatIf is requested' -Skip:($Provider -ne 'GitHub') {
        $script:sharedWorkflowRepositoryStateForTest = [ordered]@{
            Repository = 'owner/current'
            Reference = 'saved'
        }
        Mock Initialize-GitHubSharedWorkflowFork {}
        Mock Initialize-GitHubSharedWorkflowAccessPolicy {}

        $result = Update-GitHubSharedWorkflowRepositoryState `
            -RepositoryState $script:sharedWorkflowRepositoryStateForTest `
            -UpstreamFullName upstream/shared `
            -DefaultOwner owner `
            -UpstreamGitSource $repoRoot `
            -Reference stable `
            -WhatIf

        $result.Repository | Should -Be 'owner/current'
        $result.Reference | Should -Be saved
        Should -Invoke Initialize-GitHubSharedWorkflowFork -Times 0 -Exactly
        Should -Invoke Initialize-GitHubSharedWorkflowAccessPolicy -Times 0 -Exactly
    }

    It 'reselects and reconciles only the shared repository when given existing Azure DevOps context' -Skip:($Provider -ne 'Azure DevOps') {
        $selectedProject = [pscustomobject]@{ Name = 'project'; Id = 'project-id' }
        $mainRepository = [pscustomobject]@{ Name = 'mainrepo'; Id = 'main-id'; IsNewRepository = $false }
        $mainRepositoryWorkingTree = [pscustomobject]@{ Path = $TestDrive; Branch = 'main' }
        Mock Select-AzDoSharedRepository {
            [pscustomobject]@{
                Name = 'replacement'
                Id = 'replacement-id'
                remoteUrl = 'https://example.invalid/replacement'
                defaultBranch = 'refs/heads/main'
            }
        }

        $result = Initialize-AzDoProjectAndRepository `
            -SharedRepositoryOnly `
            -SelectedProjectForSharedRepository $selectedProject `
            -MainRepoForSharedRepository $mainRepository `
            -MainRepoWorkingTreeForSharedRepository $mainRepositoryWorkingTree `
            -MainRepoWorkingRootForSharedRepository $TestDrive `
            -AccessTokenForSharedRepository 'fake-token' `
            -PreferredSharedRepositoryName shared `
            -PreferredSharedRepositoryRef stable

        $result.SelectedProject.Name | Should -Be project
        $result.MainRepo.Name | Should -Be mainrepo
        $result.SharedRepoName | Should -Be replacement
        $result.SharedRepositoryRef | Should -Be main
        Should -Invoke Select-AzDoSharedRepository -Times 1 -Exactly -ParameterFilter {
            $ProjectName -eq 'project' -and
            $PreferredRepositoryName -eq 'shared' -and
            $ExcludeRepositoryName -eq 'mainrepo'
        }
        Should -Invoke Get-VSTeamProject -Times 0 -Exactly
        Should -Invoke Select-AzDoMainRepository -Times 0 -Exactly
        Should -Invoke Get-AzDoSharedRepositorySyncState -Times 1 -Exactly
    }

    It 'selects the shared repository without checking its version when requested' -Skip:($Provider -ne 'Azure DevOps') {
        $selectedProject = [pscustomobject]@{ Name = 'project'; Id = 'project-id' }
        $mainRepository = [pscustomobject]@{ Name = 'mainrepo'; Id = 'main-id'; IsNewRepository = $false }
        $mainRepositoryWorkingTree = [pscustomobject]@{ Path = $TestDrive; Branch = 'main' }
        Mock Select-AzDoSharedRepository {
            [pscustomobject]@{
                Name = 'replacement'
                Id = 'replacement-id'
                remoteUrl = 'https://example.invalid/replacement'
                defaultBranch = 'refs/heads/main'
            }
        }

        $result = Initialize-AzDoProjectAndRepository `
            -SharedRepositoryOnly `
            -SkipSharedRepositoryVersionUpdate `
            -SelectedProjectForSharedRepository $selectedProject `
            -MainRepoForSharedRepository $mainRepository `
            -MainRepoWorkingTreeForSharedRepository $mainRepositoryWorkingTree `
            -MainRepoWorkingRootForSharedRepository $TestDrive `
            -AccessTokenForSharedRepository 'fake-token' `
            -PreferredSharedRepositoryName shared `
            -PreferredSharedRepositoryRef stable

        $result.SharedRepoName | Should -Be replacement
        Should -Invoke Get-AzDoSharedRepositorySyncState -Times 0 -Exactly
        Should -Invoke Select-AzDoSharedRepository -Times 1 -Exactly -ParameterFilter {
            -not $UsePreferredIfAvailable -and -not $RequirePreferred
        }
    }

    It 'checks the selected shared repository version without prompting again' -Skip:($Provider -ne 'Azure DevOps') {
        $selectedProject = [pscustomobject]@{ Name = 'project'; Id = 'project-id' }
        $mainRepository = [pscustomobject]@{ Name = 'mainrepo'; Id = 'main-id'; IsNewRepository = $false }
        $mainRepositoryWorkingTree = [pscustomobject]@{ Path = $TestDrive; Branch = 'main' }

        $result = Initialize-AzDoProjectAndRepository `
            -SharedRepositoryOnly `
            -UsePreferredSharedRepository `
            -SelectedProjectForSharedRepository $selectedProject `
            -MainRepoForSharedRepository $mainRepository `
            -MainRepoWorkingTreeForSharedRepository $mainRepositoryWorkingTree `
            -MainRepoWorkingRootForSharedRepository $TestDrive `
            -AccessTokenForSharedRepository 'fake-token' `
            -PreferredSharedRepositoryName shared `
            -PreferredSharedRepositoryRef stable

        $result.SharedRepoName | Should -Be shared
        Should -Invoke Select-AzDoSharedRepository -Times 1 -Exactly -ParameterFilter {
            $UsePreferredIfAvailable -and $RequirePreferred -and $PreferredRepositoryName -eq 'shared'
        }
        Should -Invoke Select-FromMenu -Times 0 -Exactly
        Should -Invoke Get-AzDoSharedRepositorySyncState -Times 1 -Exactly
    }

    It 'uses the configured Azure shared repository without checking its version at startup' -Skip:($Provider -ne 'Azure DevOps') {
        $result = Initialize-AzDoProjectAndRepository -SkipSharedRepositoryVersionUpdate

        $result.SharedRepoName | Should -Be shared
        Should -Invoke Select-AzDoSharedRepository -Times 1 -Exactly -ParameterFilter {
            $UsePreferredIfAvailable -and -not $RequirePreferred
        }
        Should -Invoke Get-AzDoSharedRepositorySyncState -Times 0 -Exactly
    }

    It 'defers an inaccessible Azure shared repository without prompting during existing setup' -Skip:($Provider -ne 'Azure DevOps') {
        Mock Select-AzDoSharedRepository {
            if ($ValidatePreferredOnly) {
                return $null
            }
            throw 'Unexpected shared repository prompt.'
        }

        $result = Initialize-AzDoProjectAndRepository `
            -ExistingSetupMode `
            -DeferSharedRepositorySelection `
            -SkipSharedRepositoryVersionUpdate

        $result.SharedRepo | Should -BeNullOrEmpty
        $result.SharedRepoName | Should -BeNullOrEmpty
        $result.SharedRepositorySelectionError | Should -Be "Configured shared repository 'shared' was not found or accessible in project 'project'."
        Should -Invoke Select-AzDoSharedRepository -Times 1 -Exactly -ParameterFilter {
            $ValidatePreferredOnly -and $PreferredRepositoryName -eq 'shared'
        }
        Should -Invoke Select-FromMenu -Times 1 -Exactly -ParameterFilter {
            $Title -eq 'Select the target Azure DevOps project'
        }
        Should -Invoke Get-AzDoSharedRepositorySyncState -Times 0 -Exactly
    }

    It 'reports a missing Azure shared repository configuration without prompting' -Skip:($Provider -ne 'Azure DevOps') {
        Mock Get-AzDoSharedRepositoryNameFromWorkingTree { '' }

        $result = Initialize-AzDoProjectAndRepository `
            -ExistingSetupMode `
            -DeferSharedRepositorySelection `
            -SkipSharedRepositoryVersionUpdate

        $result.SharedRepositorySelectionError | Should -Be 'No shared repository is configured in alm-config.psd1.'
        Should -Invoke Select-AzDoSharedRepository -Times 0 -Exactly
    }

    It 'shows Azure shared repository lookup failures as a selection reason' -Skip:($Provider -ne 'Azure DevOps') {
        Mock Select-AzDoSharedRepository { throw 'service unavailable' }

        $result = Initialize-AzDoProjectAndRepository `
            -ExistingSetupMode `
            -DeferSharedRepositorySelection `
            -SkipSharedRepositoryVersionUpdate

        $result.SharedRepo | Should -BeNullOrEmpty
        $result.SharedRepositorySelectionError | Should -Be "Could not verify configured shared repository 'shared' in project 'project': service unavailable"
        Should -Invoke Select-AzDoSharedRepository -Times 1 -Exactly -ParameterFilter { $ValidatePreferredOnly }
    }

    It 'uses the platform temporary directory when TEMP is unset' -Skip:($Provider -ne 'GitHub') {
        $env:TEMP = $null

        $result = Initialize-GitHubSharedWorkflowFork -UpstreamFullName upstream/shared -DefaultOwner owner -UpstreamGitSource $repoRoot -Reference stable -PreferredRepositoryFullName owner/shared

        $result.nameWithOwner | Should -Be owner/shared
    }

    It 'lists each accessible fork once in the shared workflow choices' -Skip:($Provider -ne 'GitHub') {
        Mock Get-GitHubAccessibleForksOfRepository {
            [pscustomobject]@{ full_name = 'first-org/shared' }
            [pscustomobject]@{ full_name = 'FIRST-ORG/SHARED' }
            [pscustomobject]@{ full_name = 'second-org/shared' }
        }
        Mock Get-GitHubAccessibleRepository {
            [pscustomobject]@{ full_name = 'first-org/shared' }
            [pscustomobject]@{ full_name = 'second-org/shared' }
            [pscustomobject]@{ full_name = 'third-org/other' }
        }
        $script:repositorySelection = 1

        $result = Initialize-GitHubSharedWorkflowFork -UpstreamFullName upstream/shared -DefaultOwner owner -UpstreamGitSource $repoRoot -Reference stable

        $result.nameWithOwner | Should -Be 'second-org/shared'
        Should -Invoke Select-FromMenu -Times 1 -Exactly -ParameterFilter {
            $Title -eq 'Select shared workflow repository' -and
            @($Items | Where-Object { $_ -like 'Use existing fork: *' }).Count -eq 2 -and
            @($Items) -contains 'Use existing fork: first-org/shared' -and
            @($Items) -contains 'Use existing fork: second-org/shared' -and
            @($Items) -contains 'Use existing repository: third-org/other'
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

Describe 'Repository configuration and synchronization in <Provider>' -ForEach @(
    @{ Provider = 'GitHub'; Source = 'setup-github.ps1' }
    @{ Provider = 'Azure DevOps'; Source = 'setup-azdo.ps1' }
) {
    BeforeAll {
        $ast = Get-SetupProviderAst -RepositoryRoot $repoRoot -EntryPoint $Source
        foreach ($definition in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
            Set-Item -Path "Function:$($definition.Name)" -Value $definition.Body.GetScriptBlock()
        }
    }

    BeforeEach {
        $script:discoveryExitCode = Get-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
        $global:LASTEXITCODE = 0
        $script:discoveryRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item (Join-Path $script:discoveryRoot '.github/workflows') -ItemType Directory -Force | Out-Null
        New-Item (Join-Path $script:discoveryRoot 'pipelines') -ItemType Directory -Force | Out-Null
        Set-Content (Join-Path $script:discoveryRoot '.github/workflows/BUILD.yml') 'uses: owner/shared/.github/actions/build@stable'
        Set-Content (Join-Path $script:discoveryRoot '.github/workflows/DEPLOY-release.yml') "environment-name: 'WorkflowValue'"
        Set-Content (Join-Path $script:discoveryRoot 'pipelines/BUILD.yml') "buildEnvironmentName: PipelineValue"
        Set-Content (Join-Path $script:discoveryRoot 'pipelines/DEPLOY-release.yml') "environmentName: PipelineValue"
        $script:discoveryEmpty = $false
        $script:syncFastForward = $false
        $script:syncAhead = $false
        $script:syncFailure = ''
        $script:discoveryAlmConfig = '@{ solutionCheck = @{ enabled = $true }; branches = @{} }'
        Mock git {
            $global:LASTEXITCODE = 0
            if ($script:syncFailure -and $args -contains $script:syncFailure) { $global:LASTEXITCODE = 1; 'Simulated native failure'; return }
            if ($args -contains 'for-each-ref') { if (-not $script:discoveryEmpty) { 'origin/main'; 'origin/release'; 'origin/HEAD' } }
            elseif ($args -contains 'ls-tree') {
                if ($Provider -eq 'GitHub') { '.github/workflows/BUILD.yml'; '.github/workflows/DEPLOY-main.yml'; '.github/workflows/DEPLOY-release.yml' }
                else { 'pipelines/BUILD.yml'; 'pipelines/DEPLOY-main.yml'; 'pipelines/DEPLOY-release.yml' }
            }
            elseif ($args -contains 'show') {
                if ($args[-1] -like '*alm-config.psd1') { $script:discoveryAlmConfig }
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
        Mock Get-GitRepoFileContentFromRemoteBranch {
            if ($RelativePath -ne 'alm-config.psd1') {
                throw "Setup state must not read caller file '$RelativePath'."
            }
            $script:discoveryAlmConfig
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

    It 'uses branch settings only from alm-config.psd1' {
        $providerName = if ($Provider -eq 'GitHub') { 'GitHub' } else { 'azDO' }
        $script:discoveryAlmConfig = "@{ provider = '$providerName'; repository = 'owner/shared'; ref = 'stable'; branches = @{ main = @{ developmentEnvironment = 'DEV'; deploymentEnvironments = @('Configured'); buildValidation = @{ environmentName = 'ConfiguredBuild'; baselineRelease = '1.2.3' } } } }"

        if ($Provider -eq 'GitHub') {
            $result = Get-GitHubRepositoryExistingSetupState -RepoRoot $script:discoveryRoot -RepoOwner owner -RepoName repo -DefaultBranch main -SkipProviderState
            $result.DeploymentBranchMappings.BranchName | Should -Be @('main')
            $result.DeploymentBranchMappings[0].Environments.ShortName | Should -Be 'Configured'
            $result.SharedWorkflowRepository | Should -Be 'owner/shared'
            $result.SharedWorkflowReference | Should -Be 'stable'
            $initialMapping = @(Get-GitHubInitialBranchMapping -ExistingSetupState $result -DefaultBranch main)[0]
        }
        else {
            $result = Get-AzDoRepositoryExistingSetupState -RepoRoot $script:discoveryRoot -ProjectName project -DefaultBranch main -SkipProviderState
            $result.BranchStates.BranchName | Should -Be @('main')
            $result.BranchStates[0].DeploymentEnvironments.ShortName | Should -Be 'Configured'
            $initialMapping = @(Get-AzDoInitialBranchMapping -ExistingSetupState $result -DefaultBranch main)[0]
        }

        $result.BuildValidationEnvironmentName | Should -Be 'ConfiguredBuild'
        $result.BuildValidationEnabled | Should -BeTrue
        $initialMapping.ExistingDevEnvironment.ShortName | Should -Be 'DEV'
        $initialMapping.BuildValidationBaselineRelease | Should -Be '1.2.3'
        Should -Invoke Get-GitRepoFileContentFromRemoteBranch -Times 1 -Exactly -ParameterFilter { $RelativePath -eq 'alm-config.psd1' }
    }

    It 'does not import branch settings from caller files when config is missing or empty' {
        $providerName = if ($Provider -eq 'GitHub') { 'GitHub' } else { 'azDO' }
        if ($Provider -eq 'GitHub') {
            $getSetupState = {
                Get-GitHubRepositoryExistingSetupState -RepoRoot $script:discoveryRoot -RepoOwner owner -RepoName repo -DefaultBranch main -SkipProviderState
            }
            $getInitialMapping = {
                param($state)
                @(Get-GitHubInitialBranchMapping -ExistingSetupState $state -DefaultBranch main)[0]
            }
        }
        else {
            $getSetupState = {
                Get-AzDoRepositoryExistingSetupState -RepoRoot $script:discoveryRoot -ProjectName project -DefaultBranch main -SkipProviderState
            }
            $getInitialMapping = {
                param($state)
                @(Get-AzDoInitialBranchMapping -ExistingSetupState $state -DefaultBranch main)[0]
            }
        }

        foreach ($configContent in @('', "@{ provider = '$providerName'; branches = @{} }")) {
            $script:discoveryAlmConfig = $configContent
            $result = & $getSetupState
            $result.BranchStates.Count | Should -Be 0
            $result.BuildValidationEnabled | Should -BeFalse
            $initialMapping = & $getInitialMapping $result
            $initialMapping.BranchName | Should -Be 'main'
            $initialMapping.Environments.Count | Should -Be 0
            $initialMapping.BuildValidationEnvironmentName | Should -BeNullOrEmpty
        }
        Should -Invoke Get-GitRepoFileContentFromRemoteBranch -Times 2 -Exactly -ParameterFilter { $RelativePath -eq 'alm-config.psd1' }
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
        $ast = Get-SetupProviderAst -RepositoryRoot $repoRoot -EntryPoint $Script
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