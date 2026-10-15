BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repoRoot 'setup-common.ps1')
    function Get-DataverseEnvironment {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'AccessToken', Justification = 'Mock command signature; Pester inspects these arguments.')]
        param($AccessToken)
    }
    function Get-VSTeamServiceEndpoint {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ProjectName', Justification = 'Mock command signature; Pester inspects these arguments.')]
        [CmdletBinding()]
        param($ProjectName)
    }
    function Get-VSTeamVariableGroup {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        [CmdletBinding()]
        param($ProjectName, $Name)
    }
    function Add-VSTeamVariableGroup {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        param($ProjectName, $Name, $Type, $Variables, $Description)
    }
    function Initialize-AzDoVariableGroupExclusiveLock {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        param($Organization, $Project, $VariableGroupId, $VariableGroupName)
    }
    function Get-VSTeamBuildDefinition {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        [CmdletBinding()]
        param($ProjectName, $Id)
    }
    function Invoke-VSTeamRequest {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Method', Justification = 'Pester mock command parameter.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Resource', Justification = 'Pester mock command parameter.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Body', Justification = 'Pester mock command parameter.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ContentType', Justification = 'Pester mock command parameter.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Version', Justification = 'Pester mock command parameter.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Area', Justification = 'Pester mock command parameter.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ProjectName', Justification = 'Pester mock command parameter.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Id', Justification = 'Pester mock command parameter.')]
        [CmdletBinding()]
        param($Method, $Resource, $Body, $ContentType, $Version, $Area, $ProjectName, $Id)
        throw 'Unexpected live provider request.'
    }
    function Add-VSTeamServiceEndpoint {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ProjectName', Justification = 'Pester mock command parameter.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'EndpointName', Justification = 'Pester mock command parameter.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'EndpointType', Justification = 'Pester mock command parameter.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Object', Justification = 'Pester mock command parameter.')]
        [CmdletBinding()]
        param($ProjectName, $EndpointName, $EndpointType, $Object)
        throw 'Unexpected live endpoint creation.'
    }
    function Remove-VSTeamServiceEndpoint {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ProjectName', Justification = 'Pester mock command parameter.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Force', Justification = 'Pester mock command parameter.')]
        [CmdletBinding(SupportsShouldProcess = $true)]
        param($ProjectName, $Id, [switch]$Force)
        if ($PSCmdlet.ShouldProcess($Id, 'Remove service endpoint')) { throw 'Unexpected live endpoint deletion.' }
    }
}

Describe 'Dataverse setup authentication callbacks in <ScriptName>' -ForEach @(
    @{ ScriptName = 'setup-azdo.ps1' }
    @{ ScriptName = 'setup-github.ps1' }
) {
    BeforeEach {
        $script:savedProviderTenant = Get-Variable -Name TenantId -Scope Global -ErrorAction SilentlyContinue
        Set-Variable -Name TenantId -Scope Global -Value 'example.com'
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $ScriptName), [ref]$tokens, [ref]$parseErrors)
        $definition = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-DataverseEnvironmentCatalog'
        }, $false)
        Set-Item -Path Function:Get-DataverseEnvironmentCatalog -Value $definition.Body.GetScriptBlock()
        Mock Get-Variable { $null } -ParameterFilter { $Name -eq 'dataverseEnvironmentCatalog' -and $Scope -eq 'Script' }
        Mock Get-AuthToken { [pscustomobject]@{ AccessToken = 'fake-token' } }
        Mock Get-DataverseEnvironment {
            & $AccessToken 'relative/fake-secret' | Out-Null
            [pscustomobject]@{ FriendlyName = 'Test Environment' }
        }
    }

    AfterEach {
        if ($null -ne $script:savedProviderTenant) {
            Set-Variable -Name TenantId -Scope Global -Value $script:savedProviderTenant.Value
        }
        else {
            Remove-Variable -Name TenantId -Scope Global -ErrorAction SilentlyContinue
        }
    }

    It 'retains the supplied resource after normalization failure and emits no sensitive diagnostics' {
        $parameters = @{ ForceRefresh = $true; Verbose = $true }
        if ((Get-Command Get-DataverseEnvironmentCatalog).Parameters.ContainsKey('TenantId')) { $parameters.TenantId = 'example.com' }
        $output = @(Get-DataverseEnvironmentCatalog @parameters 4>&1)
        $messages = @($output | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] })
        $messages.Message | Should -Contain 'Could not normalize the authentication resource; using the supplied value.'
        ($messages | Out-String) | Should -Not -Match 'fake-secret|fake-token'
        Should -Invoke Get-AuthToken -Times 1 -Exactly -ParameterFilter { $ResourceUrl -eq 'relative/fake-secret' }
    }

    It 'normalizes valid resources to their authority' {
        Mock Get-DataverseEnvironment {
            & $AccessToken 'https://resource.example.com/path/?query=1' | Out-Null
            [pscustomobject]@{ FriendlyName = 'Test Environment' }
        }
        $parameters = @{ ForceRefresh = $true }
        if ((Get-Command Get-DataverseEnvironmentCatalog).Parameters.ContainsKey('TenantId')) { $parameters.TenantId = 'example.com' }
        Get-DataverseEnvironmentCatalog @parameters | Out-Null
        Should -Invoke Get-AuthToken -Times 1 -Exactly -ParameterFilter { $ResourceUrl -eq 'https://resource.example.com' }
    }

    It 'propagates authentication failure instead of returning a successful environment list' {
        Mock Get-AuthToken { throw 'Authentication denied' }
        $parameters = @{ ForceRefresh = $true }
        if ((Get-Command Get-DataverseEnvironmentCatalog).Parameters.ContainsKey('TenantId')) { $parameters.TenantId = 'example.com' }
        { Get-DataverseEnvironmentCatalog @parameters } | Should -Throw '*Authentication denied*'
    }
}

Describe 'Azure DevOps lookup failure handling' {
    BeforeAll {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'setup-azdo.ps1'), [ref]$tokens, [ref]$parseErrors)
        foreach ($name in @('Get-PowerPlatformSCCredential', 'Initialize-AzDoVariableGroup')) {
            $definition = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $false)
            Set-Item -Path "Function:$name" -Value $definition.Body.GetScriptBlock()
        }
    }

    BeforeEach {
        Mock Get-VSTeamServiceEndpoint { throw 'Service connection lookup denied' }
        Mock Get-VSTeamVariableGroup { throw 'Variable group lookup denied' }
        Mock Add-VSTeamVariableGroup { [pscustomobject]@{ id = 7 } }
        Mock Initialize-AzDoVariableGroupExclusiveLock {}
        Mock Select-FromMenu { throw 'Unexpected interactive selection' }
    }

    It 'does not start credential provisioning after a failed service connection lookup' {
        { Get-PowerPlatformSCCredential -ProjectName project -EnvironmentName TEST } | Should -Throw '*Service connection lookup denied*'
        Should -Invoke Select-FromMenu -Times 0 -Exactly
    }

    It 'does not create a variable group after an unclassified lookup failure' {
        { Initialize-AzDoVariableGroup -Organization org -Project project  -GroupName Environment-TEST -Variables @{} -RequireDeploymentApproval $false } | Should -Throw '*Variable group lookup denied*'
        Should -Invoke Add-VSTeamVariableGroup -Times 0 -Exactly
    }

    It 'does not treat HTTP permission failure as a missing variable group' {
        Mock Get-VSTeamVariableGroup {
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Permission denied', [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Forbidden))
        }
        { Initialize-AzDoVariableGroup -Organization org -Project project  -GroupName Environment-TEST -Variables @{} -RequireDeploymentApproval $false } | Should -Throw '*Permission denied*'
        Should -Invoke Add-VSTeamVariableGroup -Times 0 -Exactly
    }

    It 'creates a variable group only after a confirmed missing resource' {
        Mock Get-VSTeamVariableGroup {
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Not found', [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::NotFound))
        }
        $result = Initialize-AzDoVariableGroup -Organization org -Project project  -GroupName Environment-TEST -Variables @{} -RequireDeploymentApproval $false
        $result.id | Should -Be 7
        Should -Invoke Add-VSTeamVariableGroup -Times 1 -Exactly
    }
}

Describe 'Provider mutation guards in <ScriptName>: <Helper>' -ForEach @(
    @{ ScriptName = 'setup-azdo.ps1'; Helper = 'New-AzDoProject' }
    @{ ScriptName = 'setup-azdo.ps1'; Helper = 'Start-AzDoGitRepositoryImport' }
    @{ ScriptName = 'setup-azdo.ps1'; Helper = 'New-AzDoRepoWorkingTree' }
    @{ ScriptName = 'setup-azdo.ps1'; Helper = 'Set-AzDoAccessControlEntry' }
    @{ ScriptName = 'setup-azdo.ps1'; Helper = 'New-EntraIdApplication' }
    @{ ScriptName = 'setup-azdo.ps1'; Helper = 'Update-AzDoVariableGroup' }
    @{ ScriptName = 'setup-azdo.ps1'; Helper = 'Update-AlmConfigInWorkingTree' }
    @{ ScriptName = 'setup-azdo.ps1'; Helper = 'Update-AzDoBuildPipelineInWorkingTree' }
    @{ ScriptName = 'setup-azdo.ps1'; Helper = 'Update-DeployPipelineInWorkingTree' }
    @{ ScriptName = 'setup-azdo.ps1'; Helper = 'New-AzDoPullRequest' }
    @{ ScriptName = 'setup-azdo.ps1'; Helper = 'Set-AzDoEnvironmentConfiguration' }
    @{ ScriptName = 'setup-github.ps1'; Helper = 'Set-GitHubEnvironmentSecret' }
    @{ ScriptName = 'setup-github.ps1'; Helper = 'Set-GitHubEnvironmentVariable' }
    @{ ScriptName = 'setup-github.ps1'; Helper = 'Set-GitHubRepoSecret' }
    @{ ScriptName = 'setup-github.ps1'; Helper = 'Set-GitHubRepoVariable' }
    @{ ScriptName = 'setup-github.ps1'; Helper = 'Set-GitHubPrefixedEnvironmentCredential' }
    @{ ScriptName = 'setup-github.ps1'; Helper = 'Set-GitHubRepositoryImmutableSubject' }
    @{ ScriptName = 'setup-github.ps1'; Helper = 'New-GitHubRepositoryInteractive' }
    @{ ScriptName = 'setup-github.ps1'; Helper = 'New-EntraIdApplication' }
    @{ ScriptName = 'setup-github.ps1'; Helper = 'Update-AlmConfigInRepoClone' }
    @{ ScriptName = 'setup-github.ps1'; Helper = 'Update-BuildWorkflowInRepoClone' }
    @{ ScriptName = 'setup-github.ps1'; Helper = 'Update-DeployWorkflowInRepoClone' }
    @{ ScriptName = 'setup-github.ps1'; Helper = 'Set-GitHubEnvironmentConfiguration' }
) {
    BeforeAll {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $ScriptName), [ref]$tokens, [ref]$parseErrors)
        $definition = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Helper
        }, $false)
        Set-Item -Path "Function:$Helper" -Value $definition.Body.GetScriptBlock()
        function gh { throw 'Unexpected GitHub CLI call' }
        function git { throw 'Unexpected Git call' }
    }

    It 'returns before prompts, authentication, service calls or file changes under WhatIf' {
        Mock Get-AuthToken { throw 'Unexpected authentication' }
        Mock Invoke-RestMethod { throw 'Unexpected REST call' }
        Mock Invoke-WebRequest { throw 'Unexpected web request' }
        Mock Select-FromMenu { throw 'Unexpected selection' }
        Mock Read-TextWithDefault { throw 'Unexpected input' }
        Mock Write-Section { throw 'Unexpected wizard section' }
        Mock Set-Content { throw 'Unexpected file write' }
        Mock New-Item { throw 'Unexpected filesystem creation' }
        Mock Remove-Item { throw 'Unexpected filesystem removal' }
        Mock gh { throw 'Unexpected GitHub CLI call' }
        Mock git { throw 'Unexpected Git call' }
        $parameters = @{}
        foreach ($parameter in (Get-Command $Helper).Parameters.Values) {
            if (@($parameter.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }).Count -eq 0) { continue }
            $parameters[$parameter.Name] = switch ($parameter.ParameterType.FullName) {
                'System.Boolean' { $true }
                'System.Int64' { 1L }
                'System.Int32' { 1 }
                'System.Guid' { [guid]::Empty }
                'System.Collections.Hashtable' { @{ example = 'value' } }
                'System.Array' { ,@([pscustomobject]@{ Name = 'TEST' }) }
                'System.Object' { [pscustomobject]@{ Name = 'example'; remoteUrl = 'https://example.invalid/repository'; use_default = $true } }
                default {
                    if ($parameter.Name -in @('SecretValue','VariableValue','AccessToken','Token')) { 'fake-sensitive-value' }
                    else { 'example' }
                }
            }
        }
        & $Helper @parameters -WhatIf | Out-Null
        foreach ($command in @('Get-AuthToken','Invoke-RestMethod','Invoke-WebRequest','Select-FromMenu','Read-TextWithDefault','Write-Section','Set-Content','New-Item','Remove-Item','gh','git')) {
            Should -Invoke $command -Times 0 -Exactly
        }
    }
}

Describe 'GitHub credential writes: <Helper>' -ForEach @(
    @{ Helper = 'Set-GitHubEnvironmentSecret'; Settings = @{ Owner = 'owner'; Repo = 'repo'; EnvironmentName = 'TEST'; SecretName = 'CLIENT_SECRET'; SecretValue = "fake-secret`r`n" }; ExpectedValue = 'fake-secret' }
    @{ Helper = 'Set-GitHubRepoSecret'; Settings = @{ Owner = 'owner'; Repo = 'repo'; SecretName = 'CLIENT_SECRET'; SecretValue = "fake-secret`n" }; ExpectedValue = 'fake-secret' }
    @{ Helper = 'Set-GitHubEnvironmentVariable'; Settings = @{ Owner = 'owner'; Repo = 'repo'; EnvironmentName = 'TEST'; VariableName = 'URL'; VariableValue = 'https://example.invalid/' }; ExpectedValue = 'https://example.invalid/' }
    @{ Helper = 'Set-GitHubRepoVariable'; Settings = @{ Owner = 'owner'; Repo = 'repo'; VariableName = 'URL'; VariableValue = 'https://example.invalid/' }; ExpectedValue = 'https://example.invalid/' }
) {
    BeforeAll {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'setup-github.ps1'), [ref]$tokens, [ref]$parseErrors)
        $definition = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Helper
        }, $false)
        Set-Item -Path "Function:$Helper" -Value $definition.Body.GetScriptBlock()
        function gh { throw 'Unmocked GitHub CLI call' }
    }

    BeforeEach {
        $script:savedCredentialExitCode = $global:LASTEXITCODE
        Mock gh {
            $script:credentialArguments = @($args)
            $global:LASTEXITCODE = 0
        }
    }

    AfterEach {
        $global:LASTEXITCODE = $script:savedCredentialExitCode
    }

    It 'runs the approved mutation once with the expected repository and normalized value' {
        & $Helper @Settings -Confirm:$false
        Should -Invoke gh -Times 1 -Exactly
        $script:credentialArguments | Should -Contain 'owner/repo'
        $script:credentialArguments | Should -Contain $ExpectedValue
        $script:credentialArguments | Should -Contain '--body'
        if ($Settings.ContainsKey('EnvironmentName')) { $script:credentialArguments | Should -Contain 'TEST' }
    }

    It 'propagates native failure and restores the error preference' {
        Mock gh { $global:LASTEXITCODE = 1; 'CLI denied' }
        $previousPreference = $ErrorActionPreference
        { & $Helper @Settings -Confirm:$false } | Should -Throw '*CLI denied*'
        $ErrorActionPreference | Should -Be $previousPreference
        Should -Invoke gh -Times 1 -Exactly
    }
}

Describe 'GitHub repository owner filtering' {
    BeforeAll {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'setup-github.ps1'), [ref]$tokens, [ref]$parseErrors)
        foreach ($name in @('Get-GitHubOwnedReposForOwner', 'Get-GitHubForksOfRepositoryForOwner')) {
            $definition = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $false)
            Set-Item -Path "Function:$name" -Value $definition.Body.GetScriptBlock()
        }
        function Invoke-GhApi {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
            param($Endpoint, [switch]$AllowNotFound)
        }
    }

    BeforeEach {
        Mock Invoke-GhApi {
            @(
                [pscustomobject]@{ full_name = 'OWNER/shared'; fork = $true; parent = [pscustomobject]@{ full_name = 'upstream/shared' } }
                [pscustomobject]@{ full_name = 'other/shared'; fork = $true; parent = [pscustomobject]@{ full_name = 'upstream/shared' } }
                [pscustomobject]@{ full_name = 'owner/unrelated'; fork = $true; parent = [pscustomobject]@{ full_name = 'other/upstream' } }
            )
        }
    }

    It 'returns only repositories owned by the requested account, ignoring case' {
        @(Get-GitHubOwnedReposForOwner -Owner owner).full_name | Should -Be @('OWNER/shared', 'owner/unrelated')
    }

    It 'returns only matching upstream forks owned by the requested account' {
        @(Get-GitHubForksOfRepositoryForOwner -Owner owner -UpstreamFullName upstream/shared).full_name | Should -Be @('OWNER/shared')
    }

    It 'returns no repository for an unmatched owner' {
        @(Get-GitHubOwnedReposForOwner -Owner missing).Count | Should -Be 0
        @(Get-GitHubForksOfRepositoryForOwner -Owner missing -UpstreamFullName upstream/shared).Count | Should -Be 0
    }
}

Describe 'Provider cleanup failure handling' {
    BeforeAll {
        foreach ($provider in @(
            @{ Path = 'setup-azdo.ps1'; Name = 'New-AzDoRepoWorkingTree' }
            @{ Path = 'setup-github.ps1'; Name = 'Get-GitHubEnvironmentCapability' }
        )) {
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $provider.Path), [ref]$tokens, [ref]$parseErrors)
            $definition = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $provider.Name
            }, $false)
            Set-Item -Path "Function:$($provider.Name)" -Value $definition.Body.GetScriptBlock()
        }
        function git { throw 'Unmocked Git call' }
        function Invoke-GhApi {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
            param($Endpoint, $Method, $Body, [switch]$AllowNotFound)
        }
    }

    BeforeEach {
        $script:savedCleanupExitCode = $global:LASTEXITCODE
        $script:savedCleanupTemp = $env:TEMP
        $env:TEMP = $TestDrive
    }

    AfterEach {
        $global:LASTEXITCODE = $script:savedCleanupExitCode
        $env:TEMP = $script:savedCleanupTemp
    }

    It 'preserves the original clone failure when temporary-folder cleanup also fails' {
        Mock git { $global:LASTEXITCODE = 1; 'Original clone failure' }
        Mock Remove-Item { throw 'fake-cleanup-secret' }
        Mock Test-Path { $false }
        $previousPreference = $ErrorActionPreference
        { New-AzDoRepoWorkingTree -TargetRepo ([pscustomobject]@{ Name = 'repo'; remoteUrl = 'https://example.invalid/repo' }) -AccessToken fake-token -Confirm:$false } |
            Should -Throw '*Original clone failure*'
        $ErrorActionPreference | Should -Be $previousPreference
        Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter { $ErrorAction -eq 'Stop' }
    }

    It 'preserves successful capability results and emits a nonsensitive cleanup diagnostic' {
        Mock Invoke-GhApi {} -ParameterFilter { $Method -eq 'PUT' }
        Mock Invoke-GhApi { throw 'fake-cleanup-secret' } -ParameterFilter { $Method -eq 'DELETE' }
        $output = @(Get-GitHubEnvironmentCapability -Owner owner -Repo repo -ApprovalReviewerId 7 -Verbose 4>&1)
        $result = $output | Where-Object { $_ -isnot [System.Management.Automation.VerboseRecord] }
        $result.EnvironmentsAvailable | Should -BeTrue
        $result.ApprovalsAvailable | Should -BeTrue
        $messages = @($output | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] })
        $messages.Message | Should -Contain 'Could not remove the temporary environment probe; continuing cleanup.'
        ($messages | Out-String) | Should -Not -Match 'fake-cleanup-secret'
        Should -Invoke Invoke-GhApi -Times 1 -Exactly -ParameterFilter { $Method -eq 'DELETE' -and $AllowNotFound }
    }

    It 'reports an unavailable probe and still attempts cleanup' {
        Mock Invoke-GhApi { throw 'Environments unavailable' } -ParameterFilter { $Method -eq 'PUT' }
        Mock Invoke-GhApi {} -ParameterFilter { $Method -eq 'DELETE' }
        $result = Get-GitHubEnvironmentCapability -Owner owner -Repo repo
        $result.EnvironmentsAvailable | Should -BeFalse
        $result.Message | Should -Match 'Environments unavailable'
        Should -Invoke Invoke-GhApi -Times 1 -Exactly -ParameterFilter { $Method -eq 'DELETE' }
    }
}

Describe 'HTTP missing-resource classification' {
    It 'recognizes only HTTP 404, including wrapped exceptions' -ForEach @(
        @{ Status = 404; Expected = $true; Wrapped = $false }
        @{ Status = 404; Expected = $true; Wrapped = $true }
        @{ Status = 403; Expected = $false; Wrapped = $false }
        @{ Status = 500; Expected = $false; Wrapped = $true }
    ) {
        $exception = [Microsoft.PowerShell.Commands.HttpResponseException]::new('Failure', [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]$Status))
        if ($Wrapped) { $exception = [System.Exception]::new('Wrapped failure', $exception) }
        $record = [System.Management.Automation.ErrorRecord]::new($exception, 'Probe', [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
        Test-SetupResourceNotFound -ErrorRecord $record | Should -Be $Expected
    }

    It 'does not infer absence from exception text' {
        $record = [System.Management.Automation.ErrorRecord]::new([System.Exception]::new('Resource not found or request failed'), 'Probe', [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
        Test-SetupResourceNotFound -ErrorRecord $record | Should -BeFalse
    }
}

Describe 'Generated GitHub workflow files' {
    BeforeAll {
        $policy = Import-PowerShellDataFile (Join-Path $repoRoot 'scripts/powershell-validation.psd1')
        Import-Module powershell-yaml -RequiredVersion $policy.Tools['powershell-yaml']
        $actionlintCommand = Get-Command actionlint -ErrorAction SilentlyContinue
        $script:actionlintPath = if ($null -ne $actionlintCommand) { $actionlintCommand.Source } else { $null }
        if ($env:ACTIONLINT_REQUIRED -eq 'true' -and -not $script:actionlintPath) {
            throw 'ACTIONLINT_REQUIRED is true, but actionlint was not found on PATH.'
        }
        function Assert-GeneratedWorkflowActionlint {
            param([Parameter(Mandatory)][string]$Content)
            if (-not $script:actionlintPath) { return }
            $output = @($Content | & $script:actionlintPath - 2>&1)
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) {
                throw "actionlint rejected a generated workflow: $($output -join [Environment]::NewLine)"
            }
        }
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'setup-github.ps1'), [ref]$tokens, [ref]$parseErrors)
        foreach ($name in @('Update-BuildWorkflowInRepoClone', 'Update-DeployWorkflowInRepoClone', 'Get-SecretJsonInputBlock', 'Merge-SecretJsonInput')) {
            $definition = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $false)
            Set-Item -Path "Function:$name" -Value $definition.Body.GetScriptBlock()
        }
    }

    BeforeEach {
        $workingRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $workingRoot | Out-Null
    }

    It 'generates build validation inputs and safely quotes the environment' -ForEach @(
        @{ Enabled = $true }
        @{ Enabled = $false }
    ) {
        Update-BuildWorkflowInRepoClone -RepoRoot $workingRoot -SharedWorkflowRepository owner/shared -SharedWorkflowReference stable -BuildEnvironmentName "Build's" -BuildValidationEnabled $Enabled
        $content = Get-Content (Join-Path $workingRoot '.github/workflows/BUILD.yml') -Raw
        $null = ConvertFrom-Yaml -Yaml $content -ErrorAction Stop
        Assert-GeneratedWorkflowActionlint -Content $content
        $content | Should -Match 'uses: owner/shared/.github/actions/build@stable'
        $content | Should -Match 'alm4dataverse-export-build'
        if ($Enabled) {
            $content | Should -Match "name: 'Build''s'"
            $content | Should -Match 'AZURE_CLIENT_SECRET'
        }
        else {
            $content | Should -Match "environment-name: ''"
            $content | Should -Not -Match 'AZURE_CLIENT_SECRET'
        }
        Update-BuildWorkflowInRepoClone -RepoRoot $workingRoot -SharedWorkflowRepository owner/shared -SharedWorkflowReference stable -BuildEnvironmentName "Build's" -BuildValidationEnabled $Enabled
        Get-Content (Join-Path $workingRoot '.github/workflows/BUILD.yml') -Raw | Should -Be $content
    }

    It 'chains deployment stages with stable unique job IDs in <Mode> mode' -ForEach @(
        @{ Mode = 'manual-gate-tag' }
        @{ Mode = 'environment-approval' }
    ) {
        $environments = @('QA', 'qa!', '!!!', "Prod's") | ForEach-Object { [pscustomobject]@{ ShortName = $_ } }
        Update-DeployWorkflowInRepoClone -RepoRoot $workingRoot -Branch main -DeploymentEnvironments @($environments) -SharedWorkflowRepository owner/shared -SharedWorkflowRef stable -PromotionMode $Mode
        $content = Get-Content (Join-Path $workingRoot '.github/workflows/DEPLOY-main.yml') -Raw
        $null = ConvertFrom-Yaml -Yaml $content -ErrorAction Stop
        Assert-GeneratedWorkflowActionlint -Content $content
        $content | Should -Match 'deploy-qa:'
        $content | Should -Match 'deploy-qa-2:'
        $content | Should -Match 'deploy-stage-3:'
        $content | Should -Match 'needs: deploy-qa-2'
        $content | Should -Match "environment: 'Prod''s'"
        $content | Should -Match "previous-environment-name: 'QA'"
        if ($Mode -eq 'environment-approval') {
            $content | Should -Match 'alm4dataverse-build-deploy-main'
            $content | Should -Match "needs\['deploy-qa'\].result == 'success'"
        }
        else {
            $content | Should -Not -Match 'repository_dispatch:'
            $content | Should -Match 'type: choice'
        }
        Update-DeployWorkflowInRepoClone -RepoRoot $workingRoot -Branch main -DeploymentEnvironments @() -SharedWorkflowRepository owner/shared -SharedWorkflowRef stable
        Test-Path (Join-Path $workingRoot '.github/workflows/DEPLOY-main.yml') | Should -BeFalse
        Update-DeployWorkflowInRepoClone -RepoRoot $workingRoot -Branch main -DeploymentEnvironments @() -SharedWorkflowRepository owner/shared -SharedWorkflowRef stable
        Test-Path (Join-Path $workingRoot '.github/workflows/DEPLOY-main.yml') | Should -BeFalse
    }

    It 'preserves status-aware predecessor guards in <Mode> mode' -ForEach @(
        @{ Mode = 'manual-gate-tag' }
        @{ Mode = 'environment-approval' }
    ) {
        $environments = @([pscustomobject]@{ ShortName = 'TEST-main' }, [pscustomobject]@{ ShortName = 'PROD' })
        Update-DeployWorkflowInRepoClone -RepoRoot $workingRoot -Branch main -DeploymentEnvironments $environments -SharedWorkflowRepository owner/shared -SharedWorkflowRef stable -PromotionMode $Mode
        $content = Get-Content (Join-Path $workingRoot '.github/workflows/DEPLOY-main.yml') -Raw
        Assert-GeneratedWorkflowActionlint -Content $content
        $workflow = ConvertFrom-Yaml -Yaml $content -ErrorAction Stop
        $condition = [string]$workflow.jobs['deploy-prod']['if']
        $condition | Should -Match '!cancelled\(\)'
        $workflow.jobs['deploy-prod'].needs | Should -Be 'deploy-test-main'
        if ($Mode -eq 'environment-approval') {
            $condition | Should -Match "needs\['deploy-test-main'\].result == 'success'"
        }
    }

    It 'preserves manual and automatic stage guards in the copied deployment workflow' {
        $workflow = Get-Content (Join-Path $repoRoot 'copy-to-your-repo/.github/workflows/DEPLOY-main.yml') -Raw | ConvertFrom-Yaml
        $condition = [string]$workflow.jobs['deploy-prod']['if']
        $condition | Should -Match '!cancelled\(\)'
        $condition | Should -Match "needs\['deploy-test'\].result == 'success'"
    }

    It 'keeps secret-input merges byte-stable for <Label> generated newlines' -ForEach @(
        @{ Label = 'LF'; Newline = "`n" }
        @{ Label = 'CRLF'; Newline = "`r`n" }
        @{ Label = 'mixed'; Newline = "`n" }
    ) {
        $lines = @('jobs:', '  build:', '    with:', '      environment-name: DEV', '      secrets-json: >-', '        {"VALUE": "${{ secrets.VALUE }}"}')
        $generated = $lines -join $Newline
        if ($Label -eq 'mixed') { $generated = $generated.Replace('    with:' + "`n", '    with:' + "`r`n") }
        $first = Merge-SecretJsonInput -ExistingContent '' -GeneratedContent $generated
        $second = Merge-SecretJsonInput -ExistingContent $first -GeneratedContent $generated
        $second | Should -BeExactly $first
        $first | Should -BeExactly ($lines -join [Environment]::NewLine)
    }
}

Describe 'Generated Azure DevOps pipeline files' {
    BeforeAll {
        $script:azurePipelineSchemaPath = $env:AZURE_PIPELINES_SCHEMA
        $script:azurePipelineLanguageServicePath = $env:AZURE_PIPELINES_LANGUAGE_SERVICE
        $nodeCommand = Get-Command node -ErrorAction SilentlyContinue
        $script:nodePath = if ($null -ne $nodeCommand) { $nodeCommand.Source } else { $null }
        $script:azurePipelineValidatorPath = Join-Path $repoRoot 'scripts/validate-azure-pipelines.js'
        if ($env:AZURE_PIPELINES_SCHEMA_REQUIRED -eq 'true' -and
            (-not $script:azurePipelineSchemaPath -or
                -not (Test-Path -LiteralPath $script:azurePipelineSchemaPath) -or
                -not $script:azurePipelineLanguageServicePath -or
                -not $script:nodePath)) {
            throw 'Azure Pipelines schema validation is required, but the schema, language service, or Node.js was not found.'
        }
        function Assert-GeneratedAzurePipelineSchema {
            param([Parameter(Mandatory)][string]$Path)
            if (-not $script:azurePipelineSchemaPath) { return }
            $output = @(
                & $script:nodePath $script:azurePipelineValidatorPath `
                    --schema $script:azurePipelineSchemaPath $Path 2>&1
            )
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) {
                throw "Microsoft's Azure Pipelines language service rejected '$Path': $($output -join [Environment]::NewLine)"
            }
        }
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'setup-azdo.ps1'), [ref]$tokens, [ref]$parseErrors)
        foreach ($name in @('Update-AzDoBuildPipelineInWorkingTree', 'Update-DeployPipelineInWorkingTree')) {
            $definition = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $false)
            Set-Item -Path "Function:$name" -Value $definition.Body.GetScriptBlock()
        }
    }

    BeforeEach {
        $workingRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $workingRoot 'pipelines') -Force | Out-Null
        Copy-Item (Join-Path $repoRoot 'copy-to-your-repo/pipelines/*.yml') (Join-Path $workingRoot 'pipelines')
    }

    It 'writes build settings and replaces deployment stages for extension=<Enabled>' -ForEach @(
        @{ Enabled = $true }
        @{ Enabled = $false }
    ) {
        Update-AzDoBuildPipelineInWorkingTree -RepoRoot $workingRoot -SharedRepositoryName shared -BuildEnvironmentName "Build's" -UseAlm4DataverseExtension $Enabled
        $content = Get-Content (Join-Path $workingRoot 'pipelines/BUILD.yml') -Raw
        $null = ConvertFrom-Yaml -Yaml $content -ErrorAction Stop
        Assert-GeneratedAzurePipelineSchema -Path (Join-Path $workingRoot 'pipelines/BUILD.yml')
        $content | Should -Match "buildEnvironmentName: 'Build''s'"
        $content | Should -Match ('useAlm4DataverseExtension: ' + $Enabled.ToString().ToLowerInvariant())
        $environments = @([pscustomobject]@{ ShortName = 'QA' }, [pscustomobject]@{ ShortName = 'PROD' })
        Update-DeployPipelineInWorkingTree -RepoRoot $workingRoot -Branch main -Environments $environments -UseAlm4DataverseExtension $Enabled | Should -BeTrue
        $deployContent = Get-Content (Join-Path $workingRoot 'pipelines/DEPLOY-main.yml') -Raw
        $null = ConvertFrom-Yaml -Yaml $deployContent -ErrorAction Stop
        Assert-GeneratedAzurePipelineSchema -Path (Join-Path $workingRoot 'pipelines/DEPLOY-main.yml')
        $deployContent | Should -Match 'environmentName: QA'
        $deployContent | Should -Match 'environmentName: PROD'
        @([regex]::Matches($deployContent, '(?m)^\s+environmentName:')).Count | Should -Be 2
        Update-DeployPipelineInWorkingTree -RepoRoot $workingRoot -Branch main -Environments $environments -UseAlm4DataverseExtension $Enabled | Should -BeFalse
    }

    It 'rejects syntactically valid pipeline YAML that violates the Microsoft schema' {
        if (-not $script:azurePipelineSchemaPath) {
            Set-ItResult -Skipped -Because 'The Azure Pipelines schema validator is installed in CI.'
            return
        }

        $invalidPath = Join-Path $TestDrive 'invalid-pipeline.yml'
        Set-Content -LiteralPath $invalidPath -Value 'stages: not-a-list'
        $null = & $script:nodePath $script:azurePipelineValidatorPath `
            --schema $script:azurePipelineSchemaPath $invalidPath 2>&1
        $LASTEXITCODE | Should -Not -Be 0
    }

    It 'fails rather than silently fabricating missing templates' {
        { Update-AzDoBuildPipelineInWorkingTree -RepoRoot $TestDrive -SharedRepositoryName shared -BuildEnvironmentName '' -UseAlm4DataverseExtension $true } | Should -Throw '*Build pipeline file not found*'
        { Update-DeployPipelineInWorkingTree -RepoRoot $workingRoot -Branch absent -Environments @([pscustomobject]@{ ShortName = 'QA' }) } | Should -Throw '*not found*'
    }
}

Describe 'Azure DevOps pipeline and endpoint reconciliation' {
    BeforeAll {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'setup-azdo.ps1'), [ref]$tokens, [ref]$parseErrors)
        foreach ($definition in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
            Set-Item -Path "Function:$($definition.Name)" -Value $definition.Body.GetScriptBlock()
        }
    }

    BeforeEach {
        $script:adoAccessToken = [pscustomobject]@{ Token = 'fake-token' }
        $script:apiExists = $false
        $script:pipelineDefinition = [pscustomobject]@{ id = 7; name = 'BUILD'; path = '\'; repository = [pscustomobject]@{ id = 'repo-id'; name = 'repo'; defaultBranch = 'refs/heads/main' }; process = [pscustomobject]@{ type = 2; yamlFilename = 'pipelines/BUILD.yml' } }
        $script:apiEndpoint = $null
        Mock Write-Section {}
        Mock Start-Sleep {}
        Mock Get-VSTeamBuildDefinition { if ($script:apiExists) { $script:pipelineDefinition } }
        Mock Invoke-VSTeamRequest { [pscustomobject]@{ id = 7 } }
        Mock Get-VSTeamServiceEndpoint { if ($script:apiEndpoint) { $script:apiEndpoint } }
        Mock Remove-VSTeamServiceEndpoint { $script:apiEndpoint = $null }
        Mock Add-VSTeamServiceEndpoint {
            $script:apiEndpoint = [pscustomobject]@{ id = 8; name = $EndpointName; url = $Object.url; authorization = [pscustomobject]@{ scheme = $Object.authorization.scheme; parameters = [pscustomobject]$Object.authorization.parameters } }
            $script:apiEndpoint
        }
        Mock Invoke-RestMethod {
            if ($Method -eq 'Get') {
                [pscustomobject]@{ value = @([pscustomobject]@{ name = 'TEST'; id = 8 } | Where-Object { $script:apiExists }); pipelines = @([pscustomobject]@{ id = 7; authorized = $true } | Where-Object { $script:apiExists }) }
            }
            else { [pscustomobject]@{ id = 8 } }
        }
    }

    It 'creates or preserves a current YAML pipeline' -ForEach @(
        @{ Exists = $false }
        @{ Exists = $true }
    ) {
        $script:apiExists = $Exists
        Initialize-AzDoYamlPipelineDefinition -Project project -Repository ([pscustomobject]@{ Id = 'repo-id'; Name = 'repo' }) -DefinitionName BUILD -YamlPath /pipelines/BUILD.yml -DefinitionBranch refs/heads/main -QueueId 1
        $writes = if ($Exists) { 0 } else { 1 }
        Should -Invoke Invoke-VSTeamRequest -Times $writes -Exactly -ParameterFilter {
            $payload = $Body | ConvertFrom-Json
            $Method -eq 'POST' -and $payload.process.type -eq 2 -and $payload.process.yamlFilename -eq 'pipelines/BUILD.yml' -and $payload.repository.defaultBranch -eq 'refs/heads/main'
        }
    }

    It 'updates a pipeline when the YAML path or branch has changed' {
        $script:apiExists = $true
        Initialize-AzDoYamlPipelineDefinition -Project project -Repository ([pscustomobject]@{ Id = 'repo-id'; Name = 'repo' }) -DefinitionName BUILD -YamlPath pipelines/BUILD-new.yml -DefinitionBranch release -QueueId 1
        Should -Invoke Invoke-VSTeamRequest -Times 1 -Exactly -ParameterFilter {
            $payload = $Body | ConvertFrom-Json
            $Method -eq 'PUT' -and $Resource -eq 'build/definitions/7' -and $payload.process.yamlFilename -eq 'pipelines/BUILD-new.yml' -and $payload.repository.defaultBranch -eq 'refs/heads/release'
        }
    }

    It 'creates, reuses or refreshes an endpoint using <AuthType>' -ForEach @(
        @{ AuthType = 'WIF'; Existing = $false; Drift = $false }
        @{ AuthType = 'WIF'; Existing = $true; Drift = $false }
        @{ AuthType = 'WIF'; Existing = $true; Drift = $true }
        @{ AuthType = 'Secret'; Existing = $false; Drift = $false }
        @{ AuthType = 'Secret'; Existing = $true; Drift = $true }
    ) {
        if ($Existing) { $script:apiEndpoint = [pscustomobject]@{ id = 8; name = 'TEST'; url = 'https://test.example.com'; authorization = [pscustomobject]@{ scheme = 'WorkloadIdentityFederation'; parameters = [pscustomobject]@{ serviceprincipalid = $(if ($Drift) { 'old-app' } else { 'app-id' }); tenantid = 'example.com' } } } }
        $parameters = @{ ProjectName = 'project'; ServiceEndpointName = 'TEST'; EnvironmentUrl = 'https://test.example.com'; ApplicationId = 'app-id'; TenantId = 'example.com'; AuthType = $AuthType }
        if ($AuthType -eq 'Secret') { $parameters.ClientSecret = 'fake-secret' }
        $result = Initialize-AzDoServiceEndpoint @parameters
        $result.id | Should -Be 8
        $writes = if ($Existing -and -not $Drift) { 0 } else { 1 }
        Should -Invoke Add-VSTeamServiceEndpoint -Times $writes -Exactly -ParameterFilter { $EndpointType -eq 'powerplatform-spn' -and $Object.url -eq 'https://test.example.com' }
        $deletes = if ($Existing -and $Drift) { 1 } else { 0 }
        Should -Invoke Remove-VSTeamServiceEndpoint -Times $deletes -Exactly -ParameterFilter { $Id -eq 8 -and $Force }
        if ($AuthType -eq 'Secret') { $result.authorization.parameters.clientSecret | Should -Be fake-secret }
        else { $result.authorization.scheme | Should -Be WorkloadIdentityFederation }
    }

    It 'rejects secret authentication without a secret before creating an endpoint' {
        { Initialize-AzDoServiceEndpoint -ProjectName project -ServiceEndpointName TEST -EnvironmentUrl https://test.example.com -ApplicationId app-id -TenantId example.com -AuthType Secret } | Should -Throw '*ClientSecret is required*'
        Should -Invoke Add-VSTeamServiceEndpoint -Times 0 -Exactly
    }

    It 'creates or reuses deployment environments and grants only missing pipeline permissions' -ForEach @(
        @{ Exists = $false }
        @{ Exists = $true }
    ) {
        $script:apiExists = $Exists
        $result = Initialize-AzDoEnvironment -Organization org -Project project -EnvironmentName TEST -Description Deployment
        $result.id | Should -Be 8
        Initialize-AzDoPipelinePermission -Organization org -Project project -ResourceType endpoint -ResourceId 8 -PipelineId 7
        $writes = if ($Exists) { 0 } else { 1 }
        Should -Invoke Invoke-RestMethod -Times $writes -Exactly -ParameterFilter { $Method -eq 'Post' }
        Should -Invoke Invoke-RestMethod -Times $writes -Exactly -ParameterFilter { $Method -eq 'Patch' -and ($Body | ConvertFrom-Json).pipelines[0].authorized }
    }

    It 'assigns DEPLOY definitions to their configured branch rather than the repository default' {
        Mock Get-AzDoDefaultAgentQueueId { 1 }
        Mock Initialize-AzDoYamlPipelineDefinition {}
        Initialize-AzDoMainRepositoryPipeline -Project project -Repository ([pscustomobject]@{ Id = 'repo-id'; Name = 'repo'; defaultBranch = 'refs/heads/main' }) -YamlFiles @('pipelines/BUILD.yml', 'pipelines/DEPLOY-release.yml')
        Should -Invoke Initialize-AzDoYamlPipelineDefinition -Times 1 -Exactly -ParameterFilter { $DefinitionName -eq 'BUILD' -and $DefinitionBranch -eq 'main' }
        Should -Invoke Initialize-AzDoYamlPipelineDefinition -Times 1 -Exactly -ParameterFilter { $DefinitionName -eq 'DEPLOY-release' -and $DefinitionBranch -eq 'release' }
    }
}