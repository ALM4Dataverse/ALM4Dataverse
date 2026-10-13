BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repoRoot 'setup-common.ps1')
    function Get-DataverseEnvironment { param($AccessToken) }
    function Get-VSTeamServiceEndpoint {
        [CmdletBinding()]
        param($ProjectName)
    }
    function Get-VSTeamVariableGroup {
        [CmdletBinding()]
        param($ProjectName, $Name)
    }
    function Add-VSTeamVariableGroup { param($ProjectName, $Name, $Type, $Variables, $Description) }
    function Ensure-AzDoVariableGroupExclusiveLock { param($Organization, $Project, $VariableGroupId, $VariableGroupName) }
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
        foreach ($name in @('Get-PowerPlatformSCCredentials', 'Ensure-AzDoVariableGroupExists')) {
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
        Mock Ensure-AzDoVariableGroupExclusiveLock {}
        Mock Select-FromMenu { throw 'Unexpected interactive selection' }
    }

    It 'does not start credential provisioning after a failed service connection lookup' {
        { Get-PowerPlatformSCCredentials -ProjectName project -EnvironmentName TEST } | Should -Throw '*Service connection lookup denied*'
        Should -Invoke Select-FromMenu -Times 0 -Exactly
    }

    It 'does not create a variable group after an unclassified lookup failure' {
        { Ensure-AzDoVariableGroupExists -Organization org -Project project -ProjectId project-id -GroupName Environment-TEST -Variables @{} -RequireDeploymentApproval $false } | Should -Throw '*Variable group lookup denied*'
        Should -Invoke Add-VSTeamVariableGroup -Times 0 -Exactly
    }

    It 'does not treat HTTP permission failure as a missing variable group' {
        Mock Get-VSTeamVariableGroup {
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Permission denied', [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Forbidden))
        }
        { Ensure-AzDoVariableGroupExists -Organization org -Project project -ProjectId project-id -GroupName Environment-TEST -Variables @{} -RequireDeploymentApproval $false } | Should -Throw '*Permission denied*'
        Should -Invoke Add-VSTeamVariableGroup -Times 0 -Exactly
    }

    It 'creates a variable group only after a confirmed missing resource' {
        Mock Get-VSTeamVariableGroup {
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Not found', [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::NotFound))
        }
        $result = Ensure-AzDoVariableGroupExists -Organization org -Project project -ProjectId project-id -GroupName Environment-TEST -Variables @{} -RequireDeploymentApproval $false
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
    @{ ScriptName = 'setup-github.ps1'; Helper = 'Set-GitHubEnvironmentSecret' }
    @{ ScriptName = 'setup-github.ps1'; Helper = 'Set-GitHubEnvironmentVariable' }
    @{ ScriptName = 'setup-github.ps1'; Helper = 'Set-GitHubRepoSecret' }
    @{ ScriptName = 'setup-github.ps1'; Helper = 'Set-GitHubRepoVariable' }
    @{ ScriptName = 'setup-github.ps1'; Helper = 'Set-GitHubPrefixedEnvironmentCredentials' }
    @{ ScriptName = 'setup-github.ps1'; Helper = 'Set-GitHubRepositoryImmutableSubject' }
    @{ ScriptName = 'setup-github.ps1'; Helper = 'New-GitHubRepositoryInteractive' }
    @{ ScriptName = 'setup-github.ps1'; Helper = 'New-EntraIdApplication' }
    @{ ScriptName = 'setup-github.ps1'; Helper = 'Update-AlmConfigInRepoClone' }
    @{ ScriptName = 'setup-github.ps1'; Helper = 'Update-BuildWorkflowInRepoClone' }
    @{ ScriptName = 'setup-github.ps1'; Helper = 'Update-DeployWorkflowInRepoClone' }
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

Describe 'Provider cleanup failure handling' {
    BeforeAll {
        foreach ($provider in @(
            @{ Path = 'setup-azdo.ps1'; Name = 'New-AzDoRepoWorkingTree' }
            @{ Path = 'setup-github.ps1'; Name = 'Get-GitHubEnvironmentCapabilities' }
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
        function Invoke-GhApi { param($Endpoint, $Method, $Body, [switch]$AllowNotFound) }
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
        $output = @(Get-GitHubEnvironmentCapabilities -Owner owner -Repo repo -ApprovalReviewerId 7 -Verbose 4>&1)
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
        $result = Get-GitHubEnvironmentCapabilities -Owner owner -Repo repo
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