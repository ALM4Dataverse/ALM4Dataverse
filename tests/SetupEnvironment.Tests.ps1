BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repoRoot 'setup-common.ps1')
    function Get-VSTeamServiceEndpoint {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ProjectName', Justification = 'Mock command signature; Pester inspects this argument.')]
        [CmdletBinding()]
        param($ProjectName)
    }
    # These fallback implementations fail closed if a case misses a mock; the write stub
    # still honors ShouldProcess so a declined mutation cannot be mistaken for a live write.
    function Get-DataverseConnection {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Url', Justification = 'Pester mock command parameter.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'AccessToken', Justification = 'Pester mock command parameter.')]
        [CmdletBinding()]
        param($Url, $AccessToken)
        throw 'Unexpected live connection.'
    }
    function Get-DataverseEnvironment {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'AccessToken', Justification = 'Mock command signature; Pester invokes the token callback.')]
        [CmdletBinding()]
        param($AccessToken)
        throw 'Unexpected live environment discovery.'
    }
    function Get-DataverseRecord {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Connection', Justification = 'Pester mock command parameter.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'TableName', Justification = 'Pester mock command parameter.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'FilterValues', Justification = 'Pester mock command parameter.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Columns', Justification = 'Pester mock command parameter.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Top', Justification = 'Pester mock command parameter.')]
        [CmdletBinding()]
        param($Connection, $TableName, $FilterValues, $Columns, $Top)
        throw 'Unexpected live read.'
    }
    function Set-DataverseRecord {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Connection', Justification = 'Pester mock command parameter.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'CreateOnly', Justification = 'Pester mock command parameter.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'PassThru', Justification = 'Pester mock command parameter.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'InputObject', Justification = 'Pester mock command parameter.')]
        [CmdletBinding(SupportsShouldProcess = $true)]
        param($Connection, $TableName, [switch]$CreateOnly, [switch]$PassThru, [Parameter(ValueFromPipeline)]$InputObject)
        process {
            if ($PSCmdlet.ShouldProcess($TableName, 'Write Dataverse record')) { throw 'Unexpected live write.' }
        }
    }
}

Describe '<Provider> credential and environment configuration' -ForEach @(
    @{ Provider = 'GitHub'; Source = 'setup-github.ps1'; CredentialHelper = 'Get-GitHubCredentialsForEnvironment'; ApplyHelper = 'Set-GitHubEnvironmentConfiguration' }
    @{ Provider = 'Azure DevOps'; Source = 'setup-azdo.ps1'; CredentialHelper = 'Get-PowerPlatformSCCredential'; ApplyHelper = 'Set-AzDoEnvironmentConfiguration' }
) {
    BeforeAll {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $Source), [ref]$tokens, [ref]$parseErrors)
        # Load provider function bodies without executing installer bootstrap/authentication.
        foreach ($definition in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
            Set-Item -Path "Function:$($definition.Name)" -Value $definition.Body.GetScriptBlock()
        }
    }

    BeforeEach {
        $script:ALM4DataverseRef = 'stable'
        $script:credentialAnswers = [System.Collections.Generic.Queue[int]]::new()
        $script:environmentCredential = [pscustomobject]@{ Name = 'App'; ApplicationId = '00000000-0000-0000-0000-000000000001'; ApplicationObjectId = $null; TenantId = 'example.com'; ClientSecret = $null; HasExistingSecret = $true; AuthType = 'WIF'; IsExistingServiceConnection = $false }
        Mock Write-SetupGuidance {}
        Mock Select-FromMenu {
            if ($script:credentialAnswers.Count -eq 0) { throw "Unexpected credential menu: $Title" }
            $script:credentialAnswers.Dequeue()
        }
        Mock Get-AuthToken { [pscustomobject]@{ AccessToken = 'fake-token' } }
        Mock Invoke-RestMethod { [pscustomobject]@{ value = @() } }
        Mock Get-VSTeamServiceEndpoint { @() }
        Mock Resolve-EntraIdApplicationByAppId { [pscustomobject]@{ id = 'object-id'; displayName = 'App' } }
        Mock New-EntraIdApplicationSecret { 'fake-rotated-secret' }
        Mock New-EntraIdApplication { [pscustomobject]@{ ApplicationId = 'new-app'; AuthType = $AuthType } }
        Mock Initialize-EntraIdServicePrincipal { [pscustomobject]@{ id = 'service-principal-id' } }
        Mock Read-TextWithDefault { if ($Prompt -like '*ID*') { '00000000-0000-0000-0000-000000000001' } else { 'Manual' } }
        Mock Read-SecretText { 'fake-client-secret-value' }
        Mock Read-YesNo { $true }
        $script:credentialParameters = @{ TenantId = 'example.com'; EnvironmentName = 'TEST' }
        if ($Provider -eq 'GitHub') { $script:credentialParameters.RepoName = 'repo' }
        else { $script:credentialParameters.ProjectName = 'project' }
    }

    It 'reuses WIF credentials without creating an application or secret' {
        $script:credentialAnswers.Enqueue(0)
        $script:credentialParameters.ExistingCredential = $script:environmentCredential
        $result = & $CredentialHelper @script:credentialParameters
        $result.ApplicationId | Should -Be $script:environmentCredential.ApplicationId
        $result.AuthType | Should -Be WIF
        Should -Invoke New-EntraIdApplication -Times 0 -Exactly
        Should -Invoke New-EntraIdApplicationSecret -Times 0 -Exactly
    }

    It 'keeps or explicitly rotates an existing secret without changing the original fixture' -ForEach @(
        @{ Rotate = 0 }
        @{ Rotate = 1 }
    ) {
        $script:credentialAnswers.Enqueue(0)
        $script:credentialAnswers.Enqueue($Rotate)
        $script:environmentCredential.AuthType = 'Secret'
        $script:credentialParameters.ExistingCredential = $script:environmentCredential
        $result = & $CredentialHelper @script:credentialParameters
        $script:environmentCredential.ClientSecret | Should -BeNullOrEmpty
        if ($Rotate) {
            $result.ClientSecret | Should -Be 'fake-rotated-secret'
            Should -Invoke New-EntraIdApplicationSecret -Times 1 -Exactly -ParameterFilter { $ApplicationObjectId -eq 'object-id' }
        }
        else {
            $result.ClientSecret | Should -BeNullOrEmpty
            Should -Invoke New-EntraIdApplicationSecret -Times 0 -Exactly
        }
    }

    It 'creates the explicitly selected new application authentication mode' -ForEach @(
        @{ AuthIndex = 0; ExpectedAuth = 'WIF' }
        @{ AuthIndex = 1; ExpectedAuth = 'Secret' }
    ) {
        $script:credentialAnswers.Enqueue(0)
        $script:credentialAnswers.Enqueue($AuthIndex)
        $result = & $CredentialHelper @script:credentialParameters
        $result.AuthType | Should -Be $ExpectedAuth
        Should -Invoke New-EntraIdApplication -Times 1 -Exactly -ParameterFilter { $AuthType -eq $ExpectedAuth }
    }

    It 'reuses cached credentials by identity' {
        $script:credentialAnswers.Enqueue(2)
        $script:credentialParameters.ExistingCredentials = @($script:environmentCredential)
        & $CredentialHelper @script:credentialParameters | Should -Be $script:environmentCredential
    }

    It 'accepts manual application details for both supported authentication modes' -ForEach @(
        @{ AuthType = 'WIF' }
        @{ AuthType = 'Secret' }
    ) {
        $script:credentialAnswers.Enqueue(1)
        $index = if ($Provider -eq 'GitHub') { $(if ($AuthType -eq 'WIF') { 0 } else { 1 }) } else { $(if ($AuthType -eq 'WIF') { 1 } else { 0 }) }
        $script:credentialAnswers.Enqueue($index)
        $result = & $CredentialHelper @script:credentialParameters
        $result.AuthType | Should -Be $AuthType
        $result.Name | Should -Be Manual
        $result.ApplicationId | Should -Be '00000000-0000-0000-0000-000000000001'
        if ($AuthType -eq 'Secret') { $result.ClientSecret | Should -Be 'fake-client-secret-value' }
        else { $result.ClientSecret | Should -BeNullOrEmpty }
        Should -Invoke Initialize-EntraIdServicePrincipal -Times 1 -Exactly
    }

    It 'does not choose credentials after a cancelled selection' {
        Mock Select-FromMenu { $null }
        { & $CredentialHelper @script:credentialParameters } | Should -Throw '*No credential selected*'
        Should -Invoke New-EntraIdApplication -Times 0 -Exactly
    }

    It 'configures service identity and permissions for <AuthType> credentials' -ForEach @(
        @{ AuthType = 'WIF' }
        @{ AuthType = 'Secret' }
    ) {
        $script:environmentCredential.AuthType = $AuthType
        $script:environmentCredential.ApplicationObjectId = 'object-id'
        $script:environmentCredential.ClientSecret = 'fake-client-secret-value'
        $environment = [pscustomobject]@{ ShortName = 'TEST'; Url = 'https://test.example.com'; Credentials = $script:environmentCredential; ServiceAccountUPN = 'service@example.com'; IsDevelopmentEnvironment = $false; IsBuildValidationEnvironment = $false }
        Mock Add-EntraIdFederatedCredential {}
        Mock Initialize-DataverseApplicationUser {}
        Mock Initialize-DataverseServiceAccountUser {}
        if ($Provider -eq 'GitHub') {
            Mock Initialize-GitHubEnvironment {}
            Mock Set-GitHubEnvironmentVariable {}
            Mock Set-GitHubEnvironmentSecret {}
            Mock Set-GitHubPrefixedEnvironmentCredential {}
            Set-GitHubEnvironmentConfiguration -EnvironmentConfiguration $environment -TenantId example.com -RepoOwner owner -RepoName repo -RepoFullName owner/repo -RepoOwnerId 1 -RepoId 2 -UseImmutableWifSubject $true
            Should -Invoke Set-GitHubEnvironmentVariable -Times 4 -Exactly
            Set-GitHubEnvironmentConfiguration -EnvironmentConfiguration $environment -TenantId example.com -RepoOwner owner -RepoName repo -RepoFullName owner/repo -RepoOwnerId 1 -RepoId 2 -UseImmutableWifSubject $false -UseGitHubEnvironments $false -UseRepositoryVariablePrefix $false
            Should -Invoke Set-GitHubPrefixedEnvironmentCredential -Times 1 -Exactly -ParameterFilter { -not $UseEnvironmentPrefix }
        }
        else {
            Mock Initialize-AzDoServiceEndpoint { [pscustomobject]@{ id = 3; authorization = [pscustomobject]@{ parameters = [pscustomobject]@{ workloadIdentityFederationIssuer = 'issuer'; workloadIdentityFederationSubject = 'subject' } } } }
            Mock Initialize-AzDoEnvironment { [pscustomobject]@{ id = 4 } }
            Mock Initialize-AzDoPipelinePermission {}
            Mock Initialize-AzDoVariableGroup { [pscustomobject]@{ id = 5 } }
            Set-AzDoEnvironmentConfiguration -EnvironmentConfiguration $environment -OrganizationName org -ProjectName project -ExportPipeline ([pscustomobject]@{ id = 1 }) -DeployPipeline ([pscustomobject]@{ id = 2 })
            Should -Invoke Initialize-AzDoPipelinePermission -Times 3 -Exactly -ParameterFilter { $PipelineId -eq 2 }
            Should -Invoke Initialize-AzDoVariableGroup -Times 1 -Exactly -ParameterFilter { $RequireDeploymentApproval }
            $environment.IsDevelopmentEnvironment = $true
            Set-AzDoEnvironmentConfiguration -EnvironmentConfiguration $environment -OrganizationName org -ProjectName project -ExportPipeline ([pscustomobject]@{ id = 1 }) -DeployPipeline ([pscustomobject]@{ id = 2 })
            Should -Invoke Initialize-AzDoEnvironment -Times 1 -Exactly
            Should -Invoke Initialize-AzDoVariableGroup -Times 1 -Exactly -ParameterFilter { -not $RequireDeploymentApproval }
        }
        Should -Invoke Initialize-DataverseApplicationUser -Times 2 -Exactly
        Should -Invoke Initialize-DataverseServiceAccountUser -Times 2 -Exactly
        if ($AuthType -eq 'WIF') { Should -Invoke Add-EntraIdFederatedCredential -Times 2 -Exactly }
        else { Should -Invoke Add-EntraIdFederatedCredential -Times 0 -Exactly }
    }

    Context 'Dataverse users and role assignments' {
        BeforeEach {
            $script:missingTable = ''
            $script:existingUser = $false
            $script:existingRole = $false
            Mock Get-DataverseConnection {
                # Invoke the callback as the module would; returning a connection alone would
                # miss regressions in deferred authentication and resource normalization.
                & $AccessToken 'https://test.example.com/api/data/v9.2' | Should -Be 'fake-token'
                [pscustomobject]@{ ConnectedOrgFriendlyName = 'Test' }
            }
            Mock Get-DataverseRecord {
                if ($TableName -eq $script:missingTable) { return $null }
                switch ($TableName) {
                    businessunit { [pscustomobject]@{ businessunitid = 'business-unit' } }
                    role { [pscustomobject]@{ roleid = 'admin-role' } }
                    systemuser { if ($script:existingUser) { [pscustomobject]@{ systemuserid = 'user-id'; fullname = 'Service Account' } } }
                    systemuserroles { if ($script:existingRole) { [pscustomobject]@{ systemuserroleid = 'association-id' } } }
                }
            }
            Mock Set-DataverseRecord { [pscustomobject]@{ Id = 'user-id' } }
        }

        It 'creates or reuses <Kind> users and their administrator association' -ForEach @(
            @{ Kind = 'application'; Exists = $false }
            @{ Kind = 'application'; Exists = $true }
            @{ Kind = 'service account'; Exists = $false }
            @{ Kind = 'service account'; Exists = $true }
        ) {
            $script:existingUser = $Exists
            $script:existingRole = $Exists
            if ($Kind -eq 'application') {
                Initialize-DataverseApplicationUser -EnvironmentUrl https://test.example.com -ApplicationId app-id -TenantId example.com
            }
            else {
                Initialize-DataverseServiceAccountUser -EnvironmentUrl https://test.example.com -ServiceAccountUPN service@example.com -TenantId example.com
            }
            $writes = if ($Exists) { 0 } else { 1 }
            Should -Invoke Set-DataverseRecord -Times $writes -Exactly -ParameterFilter { $TableName -eq 'systemuser' -and $CreateOnly -and $PassThru }
            Should -Invoke Set-DataverseRecord -Times $writes -Exactly -ParameterFilter { $TableName -eq 'systemuserroles' -and $CreateOnly }
            Should -Invoke Get-DataverseRecord -Times 1 -Exactly -ParameterFilter { $TableName -eq 'systemuserroles' -and $FilterValues.systemuserid -eq 'user-id' -and $FilterValues.roleid -eq 'admin-role' }
            Should -Invoke Get-AuthToken -Times 1 -Exactly -ParameterFilter { $ResourceUrl -eq 'https://test.example.com' -and $TenantId -eq 'example.com' }
        }

        It 'rejects missing <Missing> before writing users or associations' -ForEach @(
            @{ Missing = 'connection'; Message = '*Failed to connect*' }
            @{ Missing = 'businessunit'; Message = '*root business unit*' }
            @{ Missing = 'role'; Message = '*System Administrator*' }
        ) {
            if ($Missing -eq 'connection') { Mock Get-DataverseConnection { $null } }
            else { $script:missingTable = $Missing }
            { Initialize-DataverseApplicationUser -EnvironmentUrl https://test.example.com -ApplicationId app-id -TenantId example.com } | Should -Throw $Message
            { Initialize-DataverseServiceAccountUser -EnvironmentUrl https://test.example.com -ServiceAccountUPN service@example.com -TenantId example.com } | Should -Throw $Message
            Should -Invoke Set-DataverseRecord -Times 0 -Exactly
        }
    }

    Context 'Dataverse solution discovery' {
        BeforeEach {
            $script:TenantId = 'example.com'
            $script:selectedCatalogEnvironment = [pscustomobject]@{ FriendlyName = 'Development'; UniqueName = 'dev'; Endpoints = @{ WebApplication = 'https://DEV.example.com/' } }
            $script:catalogSolutions = @(
                [pscustomobject]@{ uniquename = 'Zebra'; friendlyname = 'Zebra' }
                [pscustomobject]@{ uniquename = 'Example'; friendlyname = 'Example' }
                [pscustomobject]@{ uniquename = 'Default'; friendlyname = 'Default' }
                [pscustomobject]@{ uniquename = 'System'; friendlyname = 'System' }
            )
            Mock Select-DataverseEnvironment { $script:selectedCatalogEnvironment }
            Mock Invoke-WithSpectreStatus { & $ScriptBlock }
            Mock Get-DataverseConnection {
                & $AccessToken $null | Should -Be 'fake-token'
                [pscustomobject]@{ ConnectedOrgFriendlyName = 'Development' }
            }
            Mock Get-DataverseRecord { $script:catalogSolutions }
            Mock Select-OrderedSolution { $AvailableSolutions }
            Mock Start-Sleep {}
        }

        It 'filters system solutions and writes normalized unmanaged configuration in selected order' {
            $result = Get-DataverseSolutionsSelection -ExistingEnvironmentUrl https://dev.example.com
            $result.EnvironmentUrl | Should -Be 'https://dev.example.com'
            $result.Solutions.name | Should -Be @('Example', 'Zebra')
            $result.Solutions.deployUnmanaged | Should -Be @($false, $false)
            if ($Provider -eq 'GitHub') { $result.ReuseExistingConfiguration | Should -BeTrue }
            Should -Invoke Get-DataverseRecord -Times 1 -Exactly -ParameterFilter { $TableName -eq 'solution' -and -not $FilterValues.ismanaged -and $FilterValues.isvisible }
        }

        It 'preselects configured solutions that still exist and honors edited selection order' {
            $configPath = Join-Path $TestDrive 'solutions.psd1'
            Set-Content $configPath "@{ solutions = @(@{ name = 'Zebra' }, @{ name = 'Missing' }) }"
            Mock Select-OrderedSolution {
                $InitiallySelectedSolutions.uniquename | Should -Be Zebra
                @($AvailableSolutions | Sort-Object friendlyname -Descending)
            }
            $result = Get-DataverseSolutionsSelection -ExistingConfigPath $configPath
            $result.Solutions.name | Should -Be @('Zebra', 'Example')
        }

        It 'returns no configuration for <Case> rather than selecting a system solution' -ForEach @(
            @{ Case = 'empty catalog' }
            @{ Case = 'system solutions only' }
            @{ Case = 'empty user selection' }
        ) {
            if ($Case -eq 'empty catalog') { $script:catalogSolutions = @() }
            elseif ($Case -eq 'system solutions only') { $script:catalogSolutions = @($script:catalogSolutions | Where-Object uniquename -In Default,System) }
            else { Mock Select-OrderedSolution { @() } }
            $result = Get-DataverseSolutionsSelection
            $result.Solutions.Count | Should -Be 0
            $result.EnvironmentUrl | Should -Be 'https://dev.example.com'
        }

        It 'propagates cancellation and connection failure without reading records' {
            Mock Select-DataverseEnvironment { $null }
            { Get-DataverseSolutionsSelection } | Should -Throw '*No environment selected*'
            Mock Select-DataverseEnvironment { $script:selectedCatalogEnvironment }
            Mock Get-DataverseConnection { $null }
            { Get-DataverseSolutionsSelection } | Should -Throw '*Failed to connect*'
            Should -Invoke Get-DataverseRecord -Times 0 -Exactly
        }
    }

    Context 'Deployment environment editor callbacks' {
        BeforeEach {
            $script:targetConfiguration = [pscustomobject]@{ ShortName = 'TEST'; FriendlyName = 'Test'; Url = 'https://test.example.com'; Credentials = $script:environmentCredential; ServiceAccountUPN = 'service@example.com' }
            Mock Select-DataverseEnvironment { [pscustomobject]@{ FriendlyName = 'Test'; Endpoints = @{ WebApplication = 'https://test.example.com/' } } }
            Mock Get-DataverseServiceAccountUPN { 'service@example.com' }
            Mock Invoke-WithSpectreStatus { & $ScriptBlock }
            Mock Start-Sleep {}
            Mock Read-TextWithDefault { 'TEST' }
            if ($Provider -eq 'Azure DevOps') {
                Mock Get-AzDoEnvironmentConfiguration { $script:targetConfiguration }
                Mock Get-ExistingEnvironmentsFromWorkingTree { @('TEST', 'PROD') }
                Mock Get-AzDoExistingEnvironmentState { $script:targetConfiguration }
            }
        }

        It 'returns normalized environment configuration with reused credentials and ownership' {
            if ($Provider -eq 'GitHub') {
                Mock Get-GitHubCredentialsForEnvironment { $script:environmentCredential }
                $result = Get-GitHubEnvironmentConfiguration -EnvironmentName TEST -EnvironmentUrl https://TEST.example.com/ -TenantId example.com -RepoName repo
                $result.ShortName | Should -Be TEST
                $result.FriendlyName | Should -Be TEST
                $result.Url | Should -Be 'https://test.example.com'
                $result.Credentials | Should -Be $script:environmentCredential
                $result.ServiceAccountUPN | Should -Be 'service@example.com'
            }
            else {
                Mock Select-ConfiguredDeploymentEnvironment {
                    $added = & $AddEnvironmentScriptBlock @()
                    & $EditEnvironmentScriptBlock @($added) $added 0
                }
                $result = @(Get-DataverseEnvironmentsSelection -ProjectName project -TenantId example.com)
                $result.Count | Should -Be 1
                $result[0].ShortName | Should -Be TEST
                Should -Invoke Get-AzDoEnvironmentConfiguration -Times 2 -Exactly
            }
        }

        It 'rejects duplicate target URLs or short names in add and edit callbacks' -Skip:($Provider -eq 'GitHub') {
            Mock Select-ConfiguredDeploymentEnvironment {
                & $AddEnvironmentScriptBlock @($script:targetConfiguration) | Should -BeNullOrEmpty
                & $EditEnvironmentScriptBlock @($script:targetConfiguration, $script:targetConfiguration) $script:targetConfiguration 1 | Should -BeNullOrEmpty
                Mock Select-DataverseEnvironment { [pscustomobject]@{ FriendlyName = 'Other'; Endpoints = @{ WebApplication = 'https://other.example.com' } } }
                & $AddEnvironmentScriptBlock @($script:targetConfiguration) | Should -BeNullOrEmpty
                & $EditEnvironmentScriptBlock @($script:targetConfiguration, $script:targetConfiguration) $script:targetConfiguration 1 | Should -BeNullOrEmpty
                @()
            }
            @(Get-DataverseEnvironmentsSelection -ProjectName project).Count | Should -Be 0
            Should -Invoke Get-AzDoEnvironmentConfiguration -Times 0 -Exactly
        }

        It 'prepopulates existing stages and completes missing configuration' -Skip:($Provider -eq 'GitHub') {
            Mock Get-AzDoExistingEnvironmentState { [pscustomobject]@{ ShortName = $EnvironmentName; FriendlyName = ''; Url = ''; Credentials = $null; ServiceAccountUPN = '' } }
            Mock Select-ConfiguredDeploymentEnvironment { $InitialEnvironments }
            $result = @(Get-DataverseEnvironmentsSelection -RepoRoot $TestDrive -Branch main -ProjectName project -TenantId example.com)
            $result.Count | Should -Be 2
            $result[0].Credentials | Should -Be $script:environmentCredential
            $result[0].Url | Should -Be 'https://test.example.com'
            Should -Invoke Get-AzDoEnvironmentConfiguration -Times 2 -Exactly
            Should -Invoke Select-DataverseEnvironment -Times 2 -Exactly
        }
    }
}

Describe 'Identity and environment discovery in <Provider>' -ForEach @(
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
        $script:ALM4DataverseRef = 'stable'
        $script:TenantId = 'example.com'
        $script:identityExisting = $false
        $script:identityApp = [pscustomobject]@{ id = 'object-id'; appId = 'app-id'; displayName = 'App' }
        $script:federatedCredentials = @()
        $script:identityIssuer = if ($Provider -eq 'GitHub') { 'https://token.actions.githubusercontent.com' } else { 'https://issuer.example.com' }
        $script:identitySecret = $false
        # Catalog caching is script-scoped; reset it so provider cases cannot share discovery.
        $script:dataverseEnvironmentCatalog = $null
        $script:discoveryCatalog = @(
            [pscustomobject]@{ FriendlyName = 'Development'; UniqueName = 'dev'; Endpoints = @{ WebApplication = 'https://dev.example.com/' } }
            [pscustomobject]@{ FriendlyName = 'Test'; UniqueName = 'test'; Endpoints = @{ WebApplication = 'https://test.example.com/' } }
        )
        Mock Get-AuthToken { [pscustomobject]@{ AccessToken = 'fake-token' } }
        Mock Start-Sleep {}
        Mock Write-SetupGuidance {}
        Mock Invoke-WithSpectreStatus { & $ScriptBlock }
        Mock Read-TextWithDefault { 'service@example.com' }
        Mock Select-FromMenu { 0 }
        Mock Get-DataverseEnvironment {
            & $AccessToken 'https://globaldisco.crm.dynamics.com/api/discovery' | Should -Be 'fake-token'
            $script:discoveryCatalog
        }
        Mock Invoke-RestMethod {
            if ($Method -eq 'Get') {
                if ($Uri -like '*federatedIdentityCredentials*') { [pscustomobject]@{ value = @($script:federatedCredentials) } }
                else { [pscustomobject]@{ value = @($script:identityApp | Where-Object { $script:identityExisting }) } }
            }
            else { $script:identityApp }
        }
    }

    It 'creates or reuses application and service-principal identities using <AuthType>' -ForEach @(
        @{ AuthType = 'WIF'; Existing = $false }
        @{ AuthType = 'WIF'; Existing = $true }
        @{ AuthType = 'Secret'; Existing = $false }
        @{ AuthType = 'Secret'; Existing = $true }
    ) {
        $script:identityExisting = $Existing
        Mock New-EntraIdApplicationSecret { 'fake-secret' }
        $result = New-EntraIdApplication -DisplayName App -TenantId example.com -AuthType $AuthType
        $result.ApplicationId | Should -Be app-id
        $result.ApplicationObjectId | Should -Be object-id
        $result.AuthType | Should -Be $AuthType
        $creates = if ($Existing) { 0 } else { 1 }
        Should -Invoke Invoke-RestMethod -Times $creates -Exactly -ParameterFilter { $Method -eq 'Post' -and $Uri -like '*/applications' }
        Should -Invoke Invoke-RestMethod -Times $creates -Exactly -ParameterFilter { $Method -eq 'Post' -and $Uri -like '*/servicePrincipals' }
        if ($AuthType -eq 'Secret') { $result.ClientSecret | Should -Be fake-secret }
        else { $result.ClientSecret | Should -BeNullOrEmpty }
    }

    It 'creates or reuses a federated credential for the exact issuer and subject' -ForEach @(
        @{ Existing = $false }
        @{ Existing = $true }
    ) {
        if ($Existing) { $script:federatedCredentials = @([pscustomobject]@{ id = 'credential-id'; name = 'TEST'; issuer = $script:identityIssuer; subject = 'subject'; audiences = @('api://AzureADTokenExchange') }) }
        $parameters = @{ ApplicationObjectId = 'object-id'; TenantId = 'example.com'; Subject = 'subject'; CredentialName = 'TEST' }
        if ($Provider -eq 'Azure DevOps') { $parameters.Issuer = $script:identityIssuer }
        Add-EntraIdFederatedCredential @parameters | Should -Not -BeNullOrEmpty
        $creates = if ($Existing) { 0 } else { 1 }
        Should -Invoke Invoke-RestMethod -Times $creates -Exactly -ParameterFilter {
            if ($Method -ne 'Post') { return $false }
            $payload = $Body | ConvertFrom-Json
            $payload.subject -eq 'subject' -and $payload.issuer -eq $script:identityIssuer -and $payload.audiences[0] -eq 'api://AzureADTokenExchange'
        }
    }

    It 'refreshes outdated GitHub federated settings rather than adding another credential' -Skip:($Provider -ne 'GitHub') {
        $script:federatedCredentials = @([pscustomobject]@{ id = 'credential-id'; name = 'TEST'; issuer = 'old'; subject = 'old'; audiences = @('old') })
        Add-EntraIdFederatedCredential -ApplicationObjectId object-id -TenantId example.com -Subject subject -CredentialName TEST | Should -Be $script:identityApp
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'Patch' -and $Uri -like '*/credential-id' }
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'Post' }
    }

    It 'caches catalog discovery and explicitly refreshes it' {
        @(Get-DataverseEnvironmentCatalog -ShowStatus).Count | Should -Be 2
        @(Get-DataverseEnvironmentCatalog).Count | Should -Be 2
        Should -Invoke Get-DataverseEnvironment -Times 1 -Exactly
        @(Get-DataverseEnvironmentCatalog -ForceRefresh).Count | Should -Be 2
        Should -Invoke Get-DataverseEnvironment -Times 2 -Exactly
    }

    It 'normalizes preferred and excluded environment URLs before selection' {
        $result = Select-DataverseEnvironment -Prompt Select -PreferredUrl https://DEV.example.com -ExcludeUrl https://test.example.com
        $result.UniqueName | Should -Be dev
        Should -Invoke Select-FromMenu -Times 1 -Exactly -ParameterFilter { @($Items).Count -eq 1 -and $Items[0] -like 'Use existing*' }
        Mock Select-FromMenu { $null }
        Select-DataverseEnvironment -Prompt Select | Should -BeNullOrEmpty
    }

    It 'rejects empty catalog results and fully excluded environments' {
        $script:discoveryCatalog = @()
        { Get-DataverseEnvironmentCatalog -ForceRefresh } | Should -Throw '*No Dataverse environments*'
        $script:discoveryCatalog = @([pscustomobject]@{ FriendlyName = 'Development'; UniqueName = 'dev'; Endpoints = @{ WebApplication = 'https://dev.example.com/' } })
        Get-DataverseEnvironmentCatalog -ForceRefresh | Out-Null
        { Select-DataverseEnvironment -Prompt Select -ExcludeUrl https://dev.example.com } | Should -Throw
    }

    It 'reuses existing or cached service-account ownership and validates manual input' {
        Get-DataverseServiceAccountUPN -EnvironmentName TEST -ExistingValue existing@example.com | Should -Be existing@example.com
        Mock Select-FromMenu { 1 }
        Get-DataverseServiceAccountUPN -EnvironmentName TEST -ExistingServiceAccounts @('cached@example.com') | Should -Be cached@example.com
        Mock Select-FromMenu { 0 }
        $script:serviceInputs = [System.Collections.Generic.Queue[string]]::new()
        @('', 'invalid', 'manual@example.com') | ForEach-Object { $script:serviceInputs.Enqueue($_) }
        Mock Read-TextWithDefault { $script:serviceInputs.Dequeue() }
        Get-DataverseServiceAccountUPN -EnvironmentName TEST | Should -Be manual@example.com
        Mock Select-FromMenu { $null }
        { Get-DataverseServiceAccountUPN -EnvironmentName TEST } | Should -Throw '*No service account selected*'
    }

    It 'recognizes unprefixed repository variables and prefers active-environment values' -Skip:($Provider -ne 'GitHub') {
        Mock Resolve-EntraIdApplicationByAppId { $script:identityApp }
        Mock Resolve-DataverseEnvironmentFriendlyName { 'Test' }
        $script:repositoryVariables = @{
            AZURE_CLIENT_ID = 'unprefixed-app'
            AZURE_TENANT_ID = 'example.com'
            DATAVERSE_URL = 'https://unprefixed.example.com'
            DATAVERSE_SERVICE_ACCOUNT_UPN = 'unprefixed@example.com'
            TEST_MAIN_AZURE_CLIENT_ID = 'prefixed-app'
            TEST_MAIN_DATAVERSE_URL = 'https://prefixed.example.com'
            TEST_MAIN_DATAVERSE_SERVICE_ACCOUNT_UPN = 'prefixed@example.com'
        }
        Mock Get-GitHubActionsVariableValue {
            if ([string]::IsNullOrWhiteSpace($EnvironmentName) -and $script:repositoryVariables.ContainsKey($VariableName)) {
                return $script:repositoryVariables[$VariableName]
            }
            return $null
        }
        Mock Test-GitHubActionSecretExistence { $false }

        $result = Get-GitHubExistingEnvironmentState -Owner owner -Repo repo -EnvironmentName 'TEST-main' -TenantId example.com
        $result.StorageScope | Should -Be RepositoryPrefix
        $result.Credentials.ApplicationId | Should -Be prefixed-app
        $result.Url | Should -Be 'https://prefixed.example.com'
        $result.ServiceAccountUPN | Should -Be 'prefixed@example.com'

        $script:repositoryVariables.Remove('TEST_MAIN_AZURE_CLIENT_ID')
        $script:repositoryVariables.Remove('TEST_MAIN_DATAVERSE_URL')
        $script:repositoryVariables.Remove('TEST_MAIN_DATAVERSE_SERVICE_ACCOUNT_UPN')
        $result = Get-GitHubExistingEnvironmentState -Owner owner -Repo repo -EnvironmentName 'TEST-main' -TenantId example.com
        $result.StorageScope | Should -Be RepositoryUnprefixed
        $result.Credentials.ApplicationId | Should -Be unprefixed-app
        $result.Url | Should -Be 'https://unprefixed.example.com'
        $result.ServiceAccountUPN | Should -Be 'unprefixed@example.com'
    }

    It 'writes bare repository variable names when preserving unprefixed storage' -Skip:($Provider -ne 'GitHub') {
        $script:writtenGitHubVariableNames = @()
        Mock Set-GitHubRepoVariable { $script:writtenGitHubVariableNames += $VariableName }
        $credentials = [pscustomobject]@{ ApplicationId = 'app-id'; TenantId = 'example.com'; AuthType = 'WIF'; ClientSecret = $null }

        Set-GitHubPrefixedEnvironmentCredential -Owner owner -Repo repo -EnvironmentName 'TEST-main' -Credentials $credentials -DataverseUrl 'https://test.example.com' -ServiceAccountUPN 'service@example.com' -UseEnvironmentPrefix $false

        $script:writtenGitHubVariableNames | Should -Contain AZURE_CLIENT_ID
        $script:writtenGitHubVariableNames | Should -Contain AZURE_TENANT_ID
        $script:writtenGitHubVariableNames | Should -Contain DATAVERSE_URL
        $script:writtenGitHubVariableNames | Should -Contain DATAVERSE_SERVICE_ACCOUNT_UPN
        $script:writtenGitHubVariableNames | Should -Not -Contain TEST_MAIN_AZURE_CLIENT_ID
    }

    It 'discovers existing environment identity and authentication mode' -ForEach @(
        @{ AuthType = 'WIF' }
        @{ AuthType = 'Secret' }
    ) {
        Mock Resolve-EntraIdApplicationByAppId { $script:identityApp }
        Mock Resolve-DataverseEnvironmentFriendlyName { 'Test' }
        if ($Provider -eq 'GitHub') {
            $script:identitySecret = $AuthType -eq 'Secret'
            Mock Invoke-GhApi {
                if ($Endpoint -like '*secrets/*') { if ($script:identitySecret) { [pscustomobject]@{ name = 'AZURE_CLIENT_SECRET' } } }
                else {
                    $value = switch -Wildcard ($Endpoint) {
                        '*AZURE_CLIENT_ID' { 'app-id' }
                        '*AZURE_TENANT_ID' { 'example.com' }
                        '*DATAVERSE_URL' { 'https://TEST.example.com/' }
                        default { 'service@example.com' }
                    }
                    [pscustomobject]@{ value = $value }
                }
            }
            $result = Get-GitHubExistingEnvironmentState -Owner owner -Repo repo -EnvironmentName TEST -TenantId example.com
            $result.StorageScope | Should -Be Environment
        }
        else {
            Mock Get-AzDoExistingEnvironmentServiceAccountUPN { 'service@example.com' }
            Mock Get-VSTeamServiceEndpoint {
                [pscustomobject]@{ name = 'TEST'; id = 'endpoint-id'; url = 'https://TEST.example.com/'; authorization = [pscustomobject]@{ scheme = $(if ($AuthType -eq 'WIF') { 'WorkloadIdentityFederation' } else { 'None' }); parameters = [pscustomobject]@{ applicationId = 'app-id'; tenantId = 'example.com' } } }
            }
            $result = Get-AzDoExistingEnvironmentState -ProjectName project -EnvironmentName TEST -TenantId example.com
        }
        $result.Url | Should -Be 'https://test.example.com'
        $result.Credentials.ApplicationId | Should -Be app-id
        $result.Credentials.AuthType | Should -Be $AuthType
        $result.ServiceAccountUPN | Should -Be service@example.com
    }
}