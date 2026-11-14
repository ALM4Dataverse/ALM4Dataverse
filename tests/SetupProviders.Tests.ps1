BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repoRoot 'setup/setup-common.ps1')
    . (Join-Path $repoRoot 'tests/helpers/SetupTestHelpers.ps1')
    function Get-DataverseEnvironment {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'AccessToken', Justification = 'Mock command signature; Pester inspects these arguments.')]
        param($AccessToken)
    }
    function Get-VSTeamServiceEndpoint {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ProjectName', Justification = 'Mock command signature; Pester inspects these arguments.')]
        [CmdletBinding()]
        param($ProjectName)
    }
    function Add-VSTeamVariableGroup {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        param($ProjectName, $Name, $Type, $Variables, $Description)
    }
    function Update-VSTeamVariableGroup {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test fallback always throws and cannot mutate provider state.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        [CmdletBinding()]
        param($ProjectName, $Id, $Name, $Type, $Variables, $Description)
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
    # Nonempty fallbacks make an unmocked provider mutation fail rather than call an installed
    # module; removal retains its ShouldProcess boundary for mutation-guard cases.
    function Invoke-VSTeamRequest {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Method', Justification = 'Pester mock command parameter.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Resource', Justification = 'Pester mock command parameter.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Body', Justification = 'Pester mock command parameter.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ContentType', Justification = 'Pester mock command parameter.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Version', Justification = 'Pester mock command parameter.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Area', Justification = 'Pester mock command parameter.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ProjectName', Justification = 'Pester mock command parameter.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Id', Justification = 'Pester mock command parameter.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'QueryString', Justification = 'Pester mock command parameter.')]
        [CmdletBinding()]
        param($Method, $Resource, $Body, $ContentType, $Version, $Area, $ProjectName, $Id, $QueryString)
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

Describe 'Setup provider source aggregators' {
    It 'loads the Azure DevOps helper modules into the caller scope' {
        $loaded = & {
            . (Join-Path $repoRoot 'setup/setup-azdo.ps1')
            [bool](Get-Command -Name Get-AzDoCallerSecretVariableBlock -ErrorAction SilentlyContinue)
        }

        $loaded | Should -BeTrue
    }

    It 'loads the GitHub helper modules into the caller scope' {
        $loaded = & {
            . (Join-Path $repoRoot 'setup/setup-github.ps1')
            [bool](Get-Command -Name Get-GitHubAccessibleRepository -ErrorAction SilentlyContinue)
        }

        $loaded | Should -BeTrue
    }
}

Describe 'Setup bootstrap source aggregators' {
    It 'loads Azure DevOps bootstrap helpers into the caller scope' {
        $loaded = & {
            . (Join-Path $repoRoot 'setup/setup-azdo-bootstrap.ps1')
            [bool](Get-Command -Name Install-PortableGit -ErrorAction SilentlyContinue)
        }

        $loaded | Should -BeTrue
    }

    It 'loads GitHub bootstrap helpers into the caller scope' {
        $loaded = & {
            . (Join-Path $repoRoot 'setup/setup-github-bootstrap.ps1')
            [bool](Get-Command -Name Install-PortableGitHubCli -ErrorAction SilentlyContinue)
        }

        $loaded | Should -BeTrue
    }
}

Describe 'Azure DevOps Git bootstrap' {
    BeforeAll {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'setup/azdo/bootstrap.ps1'), [ref]$tokens, [ref]$parseErrors)
        $definition = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Install-PortableGit'
        }, $false)
        Set-Item -Path 'Function:Install-PortableGit' -Value $definition.Body.GetScriptBlock()

        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'setup/github/bootstrap.ps1'), [ref]$tokens, [ref]$parseErrors)
        $definition = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Install-PortableGitHubCli'
        }, $false)
        Set-Item -Path 'Function:Install-PortableGitHubCli' -Value $definition.Body.GetScriptBlock()
    }

    It 'uses system Git without downloading a Windows executable on non-Windows systems' -Skip:([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        $script:systemGitCommand = [pscustomobject]@{ Source = Join-Path $TestDrive 'usr/bin/git' }
        Mock Get-Command { $script:systemGitCommand }
        Mock Invoke-WebRequest { throw 'Unexpected Windows Git download.' }
        Mock Start-Process { throw 'Unexpected Windows Git extraction.' }

        $gitBinDirectory = Install-PortableGit -Destination $TestDrive

        $gitBinDirectory | Should -Be (Split-Path -Parent $script:systemGitCommand.Source)
        Should -Invoke Get-Command -Times 1 -Exactly
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        Should -Invoke Start-Process -Times 0 -Exactly
    }

    It 'reuses an existing portable Windows Git installation' {
        $destination = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $destination | Out-Null
        $expectedGitBinDirectory = Join-Path (Join-Path $destination 'Git') 'bin'
        New-Item -ItemType Directory -Path $expectedGitBinDirectory -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $expectedGitBinDirectory 'git.exe') -Force | Out-Null
        Mock Invoke-WebRequest { throw 'Unexpected Windows Git download.' }

        $gitBinDirectory = Install-PortableGit -Destination $destination -Platform ([System.PlatformID]::Win32NT)

        $gitBinDirectory | Should -Be $expectedGitBinDirectory
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'downloads and extracts Windows Git when it is not cached' {
        $destination = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $destination | Out-Null
        $expectedGitBinDirectory = Join-Path (Join-Path $destination 'Git') 'bin'
        Mock Invoke-WebRequest {
            Set-Content -LiteralPath $OutFile -Value 'installer'
        }
        Mock Start-Process {
            $gitBinDirectory = Join-Path (Join-Path (Split-Path -Parent $FilePath) 'Git') 'bin'
            New-Item -ItemType Directory -Path $gitBinDirectory -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $gitBinDirectory 'git.exe') -Force | Out-Null
            [pscustomobject]@{ ExitCode = 0 }
        }

        $gitBinDirectory = Install-PortableGit -Destination $destination -Platform ([System.PlatformID]::Win32NT)

        $gitBinDirectory | Should -Be $expectedGitBinDirectory
        Test-Path (Join-Path $destination 'PortableGit.exe') | Should -BeFalse
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        Should -Invoke Start-Process -Times 1 -Exactly
    }

    It 'reports a missing Windows Git installer after download' {
        $destination = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $destination | Out-Null
        Mock Invoke-WebRequest {}
        Mock Start-Process { throw 'Unexpected Windows Git extraction.' }

        { Install-PortableGit -Destination $destination -Platform ([System.PlatformID]::Win32NT) } |
            Should -Throw '*Failed to download Git installer*'
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        Should -Invoke Start-Process -Times 0 -Exactly
    }

    It 'fails with an install instruction when system Git is unavailable on non-Windows systems' -Skip:([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        Mock Get-Command { $null }
        Mock Invoke-WebRequest { throw 'Unexpected Windows Git download.' }

        { Install-PortableGit -Destination $TestDrive } |
            Should -Throw '*Git must be installed and available on PATH*'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }
}

Describe 'GitHub CLI bootstrap' {
    BeforeAll {
        $repoRoot = Split-Path $PSScriptRoot -Parent
        . (Join-Path $repoRoot 'setup/setup-common.ps1')
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'setup/github/bootstrap.ps1'), [ref]$tokens, [ref]$parseErrors)
        $definition = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Install-PortableGitHubCli'
        }, $false)
        Set-Item -Path 'Function:Install-PortableGitHubCli' -Value $definition.Body.GetScriptBlock()
    }

    BeforeEach {
        $script:savedProcessorArchitecture = $env:PROCESSOR_ARCHITECTURE
        $env:PROCESSOR_ARCHITECTURE = 'AMD64'
    }

    AfterEach {
        $env:PROCESSOR_ARCHITECTURE = $script:savedProcessorArchitecture
    }

    It 'reuses an existing GitHub CLI executable' {
        $destination = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $destination | Out-Null
        $installDirectory = Join-Path $destination 'GitHubCLI'
        $expectedBinDirectory = Join-Path $installDirectory 'bin'
        New-Item -ItemType Directory -Path $expectedBinDirectory -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $expectedBinDirectory 'gh.exe') -Force | Out-Null
        Mock Invoke-RestMethod { throw 'Unexpected GitHub CLI release request.' }

        Install-PortableGitHubCli -Destination $destination | Should -Be $expectedBinDirectory
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'downloads the matching GitHub CLI archive and removes it after extraction' {
        $destination = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $destination | Out-Null
        $installDirectory = Join-Path $destination 'GitHubCLI'
        $expectedBinDirectory = Join-Path $installDirectory 'bin'
        New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null
        Mock Invoke-RestMethod {
            [pscustomobject]@{
                assets = @(
                    [pscustomobject]@{
                        name = 'gh_2.55.0_windows_amd64.zip'
                        browser_download_url = 'https://example.invalid/gh.zip'
                    }
                )
            }
        }
        Mock Invoke-WebRequest {
            Set-Content -LiteralPath $OutFile -Value 'archive'
        }
        Mock Expand-SetupConsoleArchive {
            $binDirectory = Join-Path $DestinationPath 'bin'
            New-Item -ItemType Directory -Path $binDirectory -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $binDirectory 'gh.exe') -Force | Out-Null
        }

        $binDirectory = Install-PortableGitHubCli -Destination $destination

        $binDirectory | Should -Be $expectedBinDirectory
        Test-Path (Join-Path $destination 'GitHubCLI.zip') | Should -BeFalse
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        Should -Invoke Expand-SetupConsoleArchive -Times 1 -Exactly
    }

    It 'fails when no release asset matches the architecture' {
        $destination = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $destination | Out-Null
        Mock Invoke-RestMethod {
            [pscustomobject]@{
                assets = @([pscustomobject]@{ name = 'gh_2.55.0_windows_arm64.zip'; browser_download_url = 'https://example.invalid/gh.zip' })
            }
        }
        Mock Invoke-WebRequest { throw 'Unexpected GitHub CLI archive download.' }

        { Install-PortableGitHubCli -Destination $destination } |
            Should -Throw '*Could not find a GitHub CLI release archive*'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'rejects unsupported processor architectures' {
        $env:PROCESSOR_ARCHITECTURE = 'UNSUPPORTED'
        Mock Invoke-RestMethod { throw 'Unexpected GitHub CLI release request.' }

        { Install-PortableGitHubCli -Destination $TestDrive } |
            Should -Throw '*Unsupported processor architecture*'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }
}

Describe 'Dataverse setup authentication callbacks in <ScriptName>' -ForEach @(
    @{ ScriptName = 'setup-azdo.ps1' }
    @{ ScriptName = 'setup-github.ps1' }
) {
    BeforeEach {
        $script:savedProviderTenant = Get-Variable -Name TenantId -Scope Global -ErrorAction SilentlyContinue
        Set-Variable -Name TenantId -Scope Global -Value 'example.com'
        $script:providerTrace = [System.Collections.Generic.List[string]]::new()
        $script:providerCallbackToken = $null
        $ast = Get-SetupProviderAst -RepositoryRoot $repoRoot -EntryPoint $ScriptName
        # Import only the function under test, not the installer's interactive entry point.
        $definition = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-DataverseEnvironmentCatalog'
        }, $false)
        Set-Item -Path Function:Get-DataverseEnvironmentCatalog -Value $definition.Body.GetScriptBlock()
        Mock Get-Variable { $null } -ParameterFilter { $Name -eq 'dataverseEnvironmentCatalog' -and $Scope -eq 'Script' }
        Mock Get-AuthToken {
            $script:providerTrace.Add('authentication') | Out-Null
            [pscustomobject]@{ AccessToken = 'fake-token' }
        }
        Mock Get-DataverseEnvironment {
            $script:providerTrace.Add('discovery') | Out-Null
            $script:providerCallbackToken = & $AccessToken 'https://globaldisco.crm.dynamics.com/'
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

    It 'acquires the discovery token before invoking the provider callback' {
        $parameters = @{ ForceRefresh = $true }
        if ((Get-Command Get-DataverseEnvironmentCatalog).Parameters.ContainsKey('TenantId')) { $parameters.TenantId = 'example.com' }
        Get-DataverseEnvironmentCatalog @parameters | Out-Null
        $script:providerTrace.ToArray() | Should -Be @('authentication', 'discovery')
        $script:providerCallbackToken | Should -Be 'fake-token'
        Should -Invoke Get-AuthToken -Times 1 -Exactly -ParameterFilter { $ResourceUrl -eq 'https://globaldisco.crm.dynamics.com' }
    }

    It 'rejects a callback resource that does not match the pre-acquired discovery token' {
        Mock Get-DataverseEnvironment {
            & $AccessToken 'https://resource.example.com' | Out-Null
            [pscustomobject]@{ FriendlyName = 'Test Environment' }
        }
        $parameters = @{ ForceRefresh = $true }
        if ((Get-Command Get-DataverseEnvironmentCatalog).Parameters.ContainsKey('TenantId')) { $parameters.TenantId = 'example.com' }
        { Get-DataverseEnvironmentCatalog @parameters } | Should -Throw '*unexpected resource*'
    }

    It 'propagates authentication failure instead of returning a successful environment list' {
        Mock Get-AuthToken { throw 'Authentication denied' }
        $parameters = @{ ForceRefresh = $true }
        if ((Get-Command Get-DataverseEnvironmentCatalog).Parameters.ContainsKey('TenantId')) { $parameters.TenantId = 'example.com' }
        { Get-DataverseEnvironmentCatalog @parameters } | Should -Throw '*Authentication denied*'
        Should -Invoke Get-DataverseEnvironment -Times 0 -Exactly
    }
}

Describe 'Azure DevOps lookup failure handling' {
    BeforeAll {
        $ast = Get-SetupProviderAst -RepositoryRoot $repoRoot -EntryPoint 'setup-azdo.ps1'
        foreach ($name in @('Get-PowerPlatformSCCredential', 'Get-AzDoVariableGroupByName', 'Initialize-AzDoVariableGroup', 'Update-AzDoVariableGroup')) {
            $definition = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $false)
            Set-Item -Path "Function:$name" -Value $definition.Body.GetScriptBlock()
        }
    }

    BeforeEach {
        Mock Get-VSTeamServiceEndpoint { throw 'Service connection lookup denied' }
        Mock Add-VSTeamVariableGroup { [pscustomobject]@{ id = 7 } }
        Mock Update-VSTeamVariableGroup { throw 'Unexpected VSTeam typed variable group update.' }
        Mock Initialize-AzDoVariableGroupExclusiveLock {}
        Mock Select-FromMenu { throw 'Unexpected interactive selection' }
    }

    It 'does not start credential provisioning after a failed service connection lookup' {
        { Get-PowerPlatformSCCredential -ProjectName project -EnvironmentName TEST } | Should -Throw '*Service connection lookup denied*'
        Should -Invoke Select-FromMenu -Times 0 -Exactly
    }

    It 'does not create a variable group after an unclassified lookup failure' {
        Mock Invoke-VSTeamRequest { throw 'Variable group lookup denied' } -ParameterFilter {
            $Area -eq 'distributedtask' -and $Resource -eq 'variablegroups'
        }
        { Initialize-AzDoVariableGroup -Organization org -Project project  -GroupName Environment-TEST -Variables @{} -RequireDeploymentApproval $false } | Should -Throw '*Variable group lookup denied*'
        Should -Invoke Add-VSTeamVariableGroup -Times 0 -Exactly
        Should -Invoke Invoke-VSTeamRequest -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'does not treat HTTP permission failure as a missing variable group' {
        Mock Invoke-VSTeamRequest {
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Permission denied', [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Forbidden))
        } -ParameterFilter {
            $Area -eq 'distributedtask' -and $Resource -eq 'variablegroups'
        }
        { Initialize-AzDoVariableGroup -Organization org -Project project  -GroupName Environment-TEST -Variables @{} -RequireDeploymentApproval $false } | Should -Throw '*Permission denied*'
        Should -Invoke Add-VSTeamVariableGroup -Times 0 -Exactly
        Should -Invoke Invoke-VSTeamRequest -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'creates a variable group only after a confirmed missing resource' {
        $script:variableGroupGetCount = 0
        $script:variableGroupCreateBody = $null
        Mock Invoke-VSTeamRequest {
            if ($Method -eq 'GET') {
                $script:variableGroupGetCount++
                if ($script:variableGroupGetCount -eq 1) {
                    throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Not found', [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::NotFound))
                }

                return [pscustomobject]@{
                    value = @([pscustomobject]@{
                        id = 7
                        variables = [pscustomobject]@{}
                    })
                }
            }

            if ($Method -eq 'POST') {
                $script:variableGroupCreateBody = $Body
                return [pscustomobject]@{ id = 7 }
            }
        } -ParameterFilter {
            $Area -eq 'distributedtask' -and $Resource -eq 'variablegroups'
        }
        $result = Initialize-AzDoVariableGroup -Organization org -Project project  -GroupName Environment-TEST -Variables @{} -RequireDeploymentApproval $false
        $result.id | Should -Be 7
        $createPayload = $script:variableGroupCreateBody | ConvertFrom-Json -AsHashtable
        $createPayload.name | Should -Be Environment-TEST
        $createPayload.type | Should -Be Vsts
        Should -Invoke Invoke-VSTeamRequest -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'POST' -and
            $Area -eq 'distributedtask' -and
            $Resource -eq 'variablegroups' -and
            $Version -eq '5.1-preview.1' -and
            $ContentType -eq 'application/json'
        }
        Should -Invoke Add-VSTeamVariableGroup -Times 0 -Exactly
    }

    It 'updates variable groups through raw REST without VSTeam user decoration' {
        $script:variableGroupUpdateBody = $null
        Mock Invoke-VSTeamRequest {
            if ($Method -eq 'GET') {
                return [pscustomobject]@{
                    value = @([pscustomobject]@{
                        id = 7
                        description = 'existing group'
                        createdBy = $null
                        modifiedBy = $null
                        variables = [pscustomobject]@{
                            Keep = [pscustomobject]@{ value = 'keep'; isSecret = $true }
                            Replace = [pscustomobject]@{ value = 'old' }
                        }
                    })
                }
            }

            if ($Method -eq 'PUT') {
                $script:variableGroupUpdateBody = $Body
                return [pscustomobject]@{}
            }
        } -ParameterFilter {
            $Area -eq 'distributedtask' -and $Resource -eq 'variablegroups'
        }

        $result = Update-AzDoVariableGroup -ProjectName project -GroupName Environment-TEST -Variables @{
            Replace = 'new'
            Added = 'value'
        } -Confirm:$false

        $result.id | Should -Be 7
        $updatePayload = $script:variableGroupUpdateBody | ConvertFrom-Json -AsHashtable
        $updatePayload.name | Should -Be Environment-TEST
        $updatePayload.type | Should -Be Vsts
        $updatePayload.variables.Keep.value | Should -Be keep
        $updatePayload.variables.Keep.ContainsKey('isSecret') | Should -BeFalse
        $updatePayload.variables.Replace.value | Should -Be new
        $updatePayload.variables.Added.value | Should -Be value
        Should -Invoke Invoke-VSTeamRequest -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'PUT' -and
            $Area -eq 'distributedtask' -and
            $Resource -eq 'variablegroups' -and
            $Id -eq '7' -and
            $Version -eq '5.1-preview.1' -and
            $ContentType -eq 'application/json'
        }
        Should -Invoke Update-VSTeamVariableGroup -Times 0 -Exactly
    }

    It 'retrieves variable groups without requiring non-null user metadata' {
        Mock Invoke-VSTeamRequest {
            [pscustomobject]@{
                value = @([pscustomobject]@{
                    id = 7
                    createdBy = $null
                    modifiedBy = $null
                    variables = [pscustomobject]@{}
                })
            }
        } -ParameterFilter {
            $Area -eq 'distributedtask' -and $Resource -eq 'variablegroups'
        }

        $group = Get-AzDoVariableGroupByName -ProjectName project -GroupName Environment-TEST

        $group.id | Should -Be 7
        $group.createdBy | Should -BeNullOrEmpty
        Should -Invoke Invoke-VSTeamRequest -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'GET' -and
            $Area -eq 'distributedtask' -and
            $Resource -eq 'variablegroups' -and
            $ProjectName -eq 'project' -and
            $Version -eq '5.1-preview.1' -and
            $QueryString.groupName -eq 'Environment-TEST'
        }
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
        $ast = Get-SetupProviderAst -RepositoryRoot $repoRoot -EntryPoint $ScriptName
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
        # Populate mandatory bindings only to reach the early ShouldProcess guard. The fake
        # values are not a valid provisioning request and must never reach any mocked boundary.
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
        $ast = Get-SetupProviderAst -RepositoryRoot $repoRoot -EntryPoint 'setup-github.ps1'
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

Describe 'GitHub repository access listing' {
    BeforeAll {
        $ast = Get-SetupProviderAst -RepositoryRoot $repoRoot -EntryPoint 'setup-github.ps1'
        foreach ($name in @('Get-GitHubAccessibleRepository', 'Get-GitHubAccessibleForksOfRepository')) {
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
                [pscustomobject]@{ full_name = 'OWNER/shared'; fork = $true; parent = [pscustomobject]@{ full_name = 'upstream/shared' } }
                [pscustomobject]@{ full_name = 'other/shared'; fork = $true; parent = [pscustomobject]@{ full_name = 'upstream/shared' } }
                [pscustomobject]@{ full_name = 'org/shared'; fork = $false }
                [pscustomobject]@{ full_name = 'owner/unrelated'; fork = $true; parent = [pscustomobject]@{ full_name = 'other/upstream' } }
            )
        }
    }

    It 'returns repositories owned by, shared with, or available through organizations for the account' {
        $repoNames = @(Get-GitHubAccessibleRepository).full_name

        $repoNames | Should -Contain 'OWNER/shared'
        $repoNames | Should -Contain 'org/shared'
        $repoNames | Should -Contain 'other/shared'
        $repoNames | Should -Contain 'owner/unrelated'
        Should -Invoke Invoke-GhApi -Times 1 -Exactly -ParameterFilter {
            $Endpoint -eq 'user/repos?affiliation=owner,collaborator,organization_member&sort=updated&per_page=100'
        }
    }

    It 'returns each matching upstream fork once regardless of owner' {
        @(Get-GitHubAccessibleForksOfRepository -UpstreamFullName upstream/shared).full_name | Should -Be @('OWNER/shared', 'other/shared')
        Should -Invoke Invoke-GhApi -Times 1 -Exactly -ParameterFilter {
            $Endpoint -eq 'user/repos?affiliation=owner,collaborator,organization_member&sort=updated&per_page=100'
        }
    }

    It 'returns no repositories when the authenticated endpoint is empty' {
        Mock Invoke-GhApi { @() }

        @(Get-GitHubAccessibleRepository).Count | Should -Be 0
        @(Get-GitHubAccessibleForksOfRepository -UpstreamFullName upstream/shared).Count | Should -Be 0
    }
}

Describe 'GitHub repository listing' {
    BeforeAll {
        $ast = Get-SetupProviderAst -RepositoryRoot $repoRoot -EntryPoint 'setup-github.ps1'
        $definition = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-GitHubRepoList'
        }, $false)
        Set-Item -Path 'Function:Get-GitHubRepoList' -Value $definition.Body.GetScriptBlock()
        function Invoke-GhApi {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
            param($Endpoint)
        }
    }

    BeforeEach {
        Mock Invoke-GhApi {
            @(
                [pscustomobject]@{
                    full_name     = 'user/personal'
                    name          = 'personal'
                    owner         = [pscustomobject]@{ login = 'user' }
                    default_branch = 'main'
                }
                [pscustomobject]@{
                    full_name     = 'org/shared'
                    name          = 'shared'
                    owner         = [pscustomobject]@{ login = 'org' }
                    default_branch = 'develop'
                }
                [pscustomobject]@{
                    full_name     = 'other/collaborated'
                    name          = 'collaborated'
                    owner         = [pscustomobject]@{ login = 'other' }
                    default_branch = 'main'
                }
            )
        }
    }

    It 'includes personal, organization and collaborator repositories in the existing selection shape' {
        $repos = @(Get-GitHubRepoList)

        $repos.nameWithOwner | Should -Be @('user/personal', 'org/shared', 'other/collaborated')
        $repos[1].owner.login | Should -Be 'org'
        $repos[1].defaultBranchRef.name | Should -Be 'develop'
        Should -Invoke Invoke-GhApi -Times 1 -Exactly -ParameterFilter {
            $Endpoint -eq 'user/repos?affiliation=owner,collaborator,organization_member&sort=updated&per_page=100'
        }
    }
}

Describe 'GitHub API response handling' {
    BeforeAll {
        $ast = Get-SetupProviderAst -RepositoryRoot $repoRoot -EntryPoint 'setup-github.ps1'
        $definition = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-GhApi'
        }, $false)
        Set-Item -Path 'Function:Invoke-GhApi' -Value $definition.Body.GetScriptBlock()
        function gh { throw 'Unmocked GitHub CLI call' }
    }

    BeforeEach {
        $script:savedApiExitCode = $global:LASTEXITCODE
    }

    AfterEach {
        $global:LASTEXITCODE = $script:savedApiExitCode
    }

    It 'parses successful JSON responses and restores the caller error preference' {
        Mock gh { $global:LASTEXITCODE = 0; '{"login":"example-user"}' }
        $previousPreference = $ErrorActionPreference

        $response = Invoke-GhApi -Endpoint 'user'

        $response.login | Should -Be 'example-user'
        $ErrorActionPreference | Should -Be $previousPreference
        Should -Invoke gh -Times 1 -Exactly
    }

    It 'sends request bodies and returns null for an allowed not-found response' {
        Mock gh { $global:LASTEXITCODE = 0; '{"accepted":true}' }
        (Invoke-GhApi -Endpoint 'repos/example/repository/hooks' -Method POST -Body @{ accepted = $true }).accepted |
            Should -BeTrue

        Mock gh { $global:LASTEXITCODE = 1; 'HTTP 404: Not Found' }
        Invoke-GhApi -Endpoint 'repos/example/repository/missing' -AllowNotFound |
            Should -BeNullOrEmpty
    }

    It 'throws for other CLI failures after restoring the caller error preference' {
        Mock gh { $global:LASTEXITCODE = 3; 'Request denied' }
        $previousPreference = $ErrorActionPreference

        { Invoke-GhApi -Endpoint 'user' } | Should -Throw '*exit code 3*Request denied*'

        $ErrorActionPreference | Should -Be $previousPreference
    }
}

Describe 'GitHub setup authentication and application repository context' {
    BeforeAll {
        $ast = Get-SetupProviderAst -RepositoryRoot $repoRoot -EntryPoint 'setup-github.ps1'
        foreach ($name in @('Initialize-GitHubSetupAuthentication', 'Initialize-GitHubApplicationRepositoryContext')) {
            $definition = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $false)
            Set-Item -Path "Function:$name" -Value $definition.Body.GetScriptBlock()
        }

        function gh { throw 'Unmocked GitHub CLI call' }
        function git { throw 'Unmocked Git call' }
        function Get-GitHubRepoList {}
        function Get-GitHubRepositoryIdentity {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
            param($Owner, $Repo)
        }
        function Get-GitHubRepositoryExistingSetupState {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
            param($RepoRoot, $RepoOwner, $RepoName, $DefaultBranch, $TenantId, [switch]$SkipProviderState)
        }
        function Invoke-GitHubCloneBaseBranchCheckout {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
            param($RepoRoot, $DefaultBranch)
        }
    }

    BeforeEach {
        $script:ALM4DataverseRef = 'stable'
        $script:savedSetupGitHubExitCode = $global:LASTEXITCODE
        Mock Invoke-WithSpectreStatus { & $ScriptBlock }
        Mock Invoke-WithErrorHandling { & $ScriptBlock }
    }

    AfterEach {
        $global:LASTEXITCODE = $script:savedSetupGitHubExitCode
    }

    It 'uses the existing GitHub login in apply-config mode without Azure authentication' {
        $script:authenticationGhCalls = @()
        Mock gh {
            $script:authenticationGhCalls += ,@($args)
            if ($args[0] -eq 'auth' -and $args[1] -eq 'status') {
                $global:LASTEXITCODE = 0
                return
            }
            if ($args[0] -eq 'api' -and $args[-1] -eq '.login') {
                $global:LASTEXITCODE = 0
                return 'example-user'
            }
            if ($args[0] -eq 'api' -and $args[-1] -eq '.id') {
                $global:LASTEXITCODE = 0
                return '42'
            }

            throw 'Unexpected GitHub CLI command.'
        }
        Mock Select-FromMenu { 0 }

        $result = Initialize-GitHubSetupAuthentication -ApplyConfig

        $result.TenantId | Should -BeNullOrEmpty
        $result.GitHubUser | Should -Be 'example-user'
        $result.GitHubUserId | Should -Be 42
        $script:authenticationGhCalls.Count | Should -Be 4
        Should -Invoke Select-FromMenu -Times 1 -Exactly
    }

    It 'opens browser authentication when the GitHub CLI has no existing login' {
        $script:authenticationGhCalls = @()
        Mock gh {
            $script:authenticationGhCalls += ,@($args)
            if ($args[0] -eq 'auth' -and $args[1] -eq 'status') {
                $global:LASTEXITCODE = 1
                return 'Not logged in.'
            }
            if ($args[0] -eq 'auth' -and $args[1] -eq 'login') {
                $global:LASTEXITCODE = 0
                return
            }
            if ($args[0] -eq 'api' -and $args[-1] -eq '.login') {
                $global:LASTEXITCODE = 0
                return 'example-user'
            }
            if ($args[0] -eq 'api' -and $args[-1] -eq '.id') {
                $global:LASTEXITCODE = 0
                return '42'
            }

            throw 'Unexpected GitHub CLI command.'
        }
        Mock Select-FromMenu { 0 }

        $result = Initialize-GitHubSetupAuthentication -ApplyConfig

        $result.GitHubUser | Should -Be 'example-user'
        $result.GitHubUserId | Should -Be 42
        $script:authenticationGhCalls.Count | Should -Be 4
        Should -Invoke Select-FromMenu -Times 0 -Exactly
    }

    It 'clones and inspects the selected existing repository in setup mode' {
        $script:selectedRepository = [pscustomobject]@{
            name             = 'application'
            nameWithOwner    = 'example-owner/application'
            owner            = [pscustomobject]@{ login = 'example-owner' }
            defaultBranchRef = [pscustomobject]@{ name = 'release' }
        }
        $script:existingRepositoryState = [pscustomobject]@{ IsConfigured = $true }

        Mock Get-GitHubRepoList { @($script:selectedRepository) }
        Mock Select-FromMenu { 0 }
        Mock Get-GitHubRepositoryIdentity {
            [pscustomobject]@{ OwnerId = 11; RepositoryId = 22; UseImmutableSubject = $true }
        }
        Mock Get-GitHubRepositoryExistingSetupState { $script:existingRepositoryState }
        Mock Invoke-GitHubCloneBaseBranchCheckout {}
        Mock gh { $global:LASTEXITCODE = 0 }
        Mock git { $global:LASTEXITCODE = 0 }

        $result = Initialize-GitHubApplicationRepositoryContext -ExistingSetupMode

        $result.RepoFullName | Should -Be 'example-owner/application'
        $result.RepoOwnerId | Should -Be 11
        $result.RepoId | Should -Be 22
        $result.DefaultBranch | Should -Be 'release'
        $result.CloneRoot | Should -Not -BeNullOrEmpty
        $result.ExistingSetupState.IsConfigured | Should -BeTrue
        $result.IsNewRepository | Should -BeFalse
        Should -Invoke Invoke-GitHubCloneBaseBranchCheckout -Times 1 -Exactly
        Should -Invoke Get-GitHubRepositoryExistingSetupState -Times 1 -Exactly -ParameterFilter {
            $RepoRoot -eq $result.CloneRoot -and $RepoOwner -eq 'example-owner' -and $RepoName -eq 'application' -and
            $DefaultBranch -eq 'release' -and -not $SkipProviderState
        }
    }
}

Describe 'Azure DevOps organization selection' {
    BeforeAll {
        $ast = Get-SetupProviderAst -RepositoryRoot $repoRoot -EntryPoint 'setup-azdo.ps1'
        $definition = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Initialize-AzDoOrganization'
        }, $false)
        Set-Item -Path 'Function:Initialize-AzDoOrganization' -Value $definition.Body.GetScriptBlock()
        function Set-VSTeamAccount {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Empty test command stub; it performs no account or service mutation.')]
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
            param($Account, $SecurePersonalAccessToken, [switch]$UseBearerToken, [switch]$Force)
        }
    }

    BeforeEach {
        $script:secureToken = [System.Security.SecureString]::new()
        $script:previousAdoAccessToken = Get-Variable -Name adoAccessToken -Scope Global -ErrorAction SilentlyContinue
        Set-Variable -Name adoAccessToken -Value ([pscustomobject]@{ Token = '' }) -Scope Global
        Mock Invoke-WithErrorHandling { & $ScriptBlock }
        Mock Test-SetupDebugEnabled { $true }
        Mock Write-SetupDebug {}
    }

    AfterEach {
        if ($script:previousAdoAccessToken) {
            Set-Variable -Name adoAccessToken -Value $script:previousAdoAccessToken.Value -Scope Global
        }
        else {
            Remove-Variable -Name adoAccessToken -Scope Global -ErrorAction SilentlyContinue
        }
    }

    It 'deduplicates organizations and disambiguates duplicate names in the selection menu' {
        $script:organizationMenuItems = @()
        Mock Invoke-RestMethod {
            if ($Uri -like '*profiles/me*') {
                return [pscustomobject]@{ publicAlias = 'member-alias' }
            }

            [pscustomobject]@{
                value = @(
                    [pscustomobject]@{ accountId = 'organization-id'; accountName = 'Example'; accountUri = 'https://dev.azure.com/example' }
                    [pscustomobject]@{ accountId = 'organization-id'; accountName = 'Example'; accountUri = 'https://dev.azure.com/duplicate' }
                    [pscustomobject]@{ accountId = $null; accountUri = 'https://dev.azure.com/example-alt'; accountName = 'Example' }
                    [pscustomobject]@{ accountId = $null; accountUri = $null; accountName = 'Solo' }
                )
            }
        }
        Mock Select-FromMenu {
            $script:organizationMenuItems = @($Items)
            0
        }
        Mock Set-VSTeamAccount {}

        $organization = Initialize-AzDoOrganization

        $organization.Name | Should -Be 'Example'
        $organization.Uri | Should -Be 'https://dev.azure.com/example'
        $script:organizationMenuItems | Should -Contain 'Example (https://dev.azure.com/example)'
        $script:organizationMenuItems | Should -Contain 'Example (https://dev.azure.com/example-alt)'
        $script:organizationMenuItems | Should -Contain 'Solo'
        Should -Invoke Set-VSTeamAccount -Times 1 -Exactly -ParameterFilter {
            $Account -eq 'Example' -and $UseBearerToken -and $Force
        }
    }

    It 'returns without configuring VSTeam when the organization menu is cancelled' {
        Mock Invoke-RestMethod {
            if ($Uri -like '*profiles/me*') {
                return [pscustomobject]@{ publicAlias = $null; id = 'member-id' }
            }

            [pscustomobject]@{
                value = @(
                    [pscustomobject]@{ accountId = 'organization-id'; accountName = 'Example'; accountUri = 'https://dev.azure.com/example' }
                )
            }
        }
        Mock Select-FromMenu { $null }
        Mock Set-VSTeamAccount {}

        Initialize-AzDoOrganization | Should -BeNullOrEmpty

        Should -Invoke Set-VSTeamAccount -Times 0 -Exactly
    }
}

Describe 'Provider cleanup failure handling' {
    BeforeAll {
        foreach ($provider in @(
            @{ Path = 'setup-azdo.ps1'; Name = 'New-AzDoRepoWorkingTree' }
            @{ Path = 'setup-github.ps1'; Name = 'Get-GitHubEnvironmentCapability' }
        )) {
            $ast = Get-SetupProviderAst -RepositoryRoot $repoRoot -EntryPoint $provider.Path
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
        # Clone/probe cleanup is production behavior; any created folders must belong to Pester.
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
        # Optional locally, mandatory when ACTIONLINT_REQUIRED is set above; validate via stdin
        # so linting sees the generated text without depending on the test process's location.
        function Assert-GeneratedWorkflowActionlint {
            param([Parameter(Mandatory)][string]$Content)
            if (-not $script:actionlintPath) { return }
            $output = @($Content | & $script:actionlintPath - 2>&1)
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) {
                throw "actionlint rejected a generated workflow: $($output -join [Environment]::NewLine)"
            }
        }
        $ast = Get-SetupProviderAst -RepositoryRoot $repoRoot -EntryPoint 'setup-github.ps1'
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
        # No schema means a local opt-out; required CI prerequisites are checked above.
        # This validates pipeline semantics in addition to ConvertFrom-Yaml syntax checks.
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
        $ast = Get-SetupProviderAst -RepositoryRoot $repoRoot -EntryPoint 'setup-azdo.ps1'
        foreach ($name in @('Get-AzDoCallerSecretVariableBlock', 'Update-AzDoBuildPipelineInWorkingTree', 'Update-DeployPipelineInWorkingTree')) {
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

    It 'preserves per-environment extra deployment parameters when regenerating stages' {
        $deployPath = Join-Path $workingRoot 'pipelines/DEPLOY-main.yml'
        $environments = @([pscustomobject]@{ ShortName = 'QA' }, [pscustomobject]@{ ShortName = 'PROD' })
        Update-DeployPipelineInWorkingTree -RepoRoot $workingRoot -Branch main -Environments $environments | Should -BeTrue
        $original = (Get-Content -LiteralPath $deployPath -Raw).Replace("`r`n", "`n")
        $prodEntry = "      environmentName: PROD`n      useAlm4DataverseExtension: true`n"
        $original | Should -Match ([regex]::Escape($prodEntry))
        $customized = $original.Replace($prodEntry, $prodEntry + "      timeoutInMinutes: 120`n      secretVariables:`n        - DataverseEnvVar_contoso_APIKey`n")
        Set-Content -LiteralPath $deployPath -Value $customized -NoNewline

        $reordered = @([pscustomobject]@{ ShortName = 'UAT' }, [pscustomobject]@{ ShortName = 'PROD' })
        Update-DeployPipelineInWorkingTree -RepoRoot $workingRoot -Branch main -Environments $reordered | Should -BeTrue
        $content = Get-Content -LiteralPath $deployPath -Raw
        $parsed = ConvertFrom-Yaml -Yaml $content -ErrorAction Stop
        Assert-GeneratedAzurePipelineSchema -Path $deployPath

        $stages = @($parsed.stages)
        $stages.Count | Should -Be 2
        $stages[0].parameters.environmentName | Should -Be 'UAT'
        $stages[0].parameters.ContainsKey('secretVariables') | Should -BeFalse
        $stages[1].parameters.environmentName | Should -Be 'PROD'
        $stages[1].parameters.timeoutInMinutes | Should -Be 120
        @($stages[1].parameters.secretVariables) | Should -Be @('DataverseEnvVar_contoso_APIKey')
        $content | Should -Not -Match 'environmentName: QA'

        Update-DeployPipelineInWorkingTree -RepoRoot $workingRoot -Branch main -Environments $reordered | Should -BeFalse
    }

    It 'preserves an existing BUILD secretVariables block when rewriting the caller' {
        $buildPath = Join-Path $workingRoot 'pipelines/BUILD.yml'
        Update-AzDoBuildPipelineInWorkingTree -RepoRoot $workingRoot -SharedRepositoryName shared -BuildEnvironmentName 'Build' -UseAlm4DataverseExtension $true
        Add-Content -LiteralPath $buildPath -Value "`n    secretVariables:`n      - DataverseEnvVar_contoso_APIKey"

        Update-AzDoBuildPipelineInWorkingTree -RepoRoot $workingRoot -SharedRepositoryName shared -BuildEnvironmentName 'Validation' -UseAlm4DataverseExtension $true
        $parsed = Get-Content -LiteralPath $buildPath -Raw | ConvertFrom-Yaml -ErrorAction Stop
        Assert-GeneratedAzurePipelineSchema -Path $buildPath
        $parameters = @($parsed.stages)[0].parameters
        $parameters.buildEnvironmentName | Should -Be 'Validation'
        @($parameters.secretVariables) | Should -Be @('DataverseEnvVar_contoso_APIKey')
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
        $ast = Get-SetupProviderAst -RepositoryRoot $repoRoot -EntryPoint 'setup-azdo.ps1'
        foreach ($definition in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
            Set-Item -Path "Function:$($definition.Name)" -Value $definition.Body.GetScriptBlock()
        }
    }

    Describe 'Azure DevOps provisioning primitives' {
        BeforeAll {
            $ast = Get-SetupProviderAst -RepositoryRoot $repoRoot -EntryPoint 'setup-azdo.ps1'
            foreach ($definition in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
                Set-Item -Path "Function:$($definition.Name)" -Value $definition.Body.GetScriptBlock()
            }

            function Get-VSTeamQueue {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ProjectName', Justification = 'Mock command signature; Pester inspects these arguments.')]
                param($ProjectName)
            }
            function Get-VSTeamUser {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'SubjectTypes', Justification = 'Mock command signature; Pester inspects these arguments.')]
                [CmdletBinding()]
                param($SubjectTypes)
            }
            function Get-VSTeamSecurityNamespace {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Id', Justification = 'Mock command signature; Pester inspects these arguments.')]
                [CmdletBinding()]
                param($Id)
            }
            function Get-VSTeamAccessControlList {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
                [CmdletBinding()]
                param($SecurityNamespaceId, $Token, $Descriptors)
            }
            function Get-VSTeamGroup {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ProjectName', Justification = 'Mock command signature; Pester inspects these arguments.')]
                [CmdletBinding()]
                param($ProjectName)
            }
        }

        BeforeEach {
            $script:previousGlobalAdoAccessToken = Get-Variable -Name adoAccessToken -Scope Global -ErrorAction SilentlyContinue
            Set-Variable -Name adoAccessToken -Value ([pscustomobject]@{ Token = '' }) -Scope Global
            $script:adoAccessToken = Get-Variable -Name adoAccessToken -Scope Global -ValueOnly
            $script:agentQueues = @()
            Mock Get-VSTeamQueue { $script:agentQueues }
            Mock Get-VSTeamUser { @() }
            Mock Get-VSTeamSecurityNamespace { @() }
            Mock Get-VSTeamAccessControlList { @() }
            Mock Get-VSTeamGroup { @() }
            Mock Invoke-VSTeamRequest { }
            Mock Invoke-RestMethod { [pscustomobject]@{ count = 0; value = @() } }
        }

        AfterEach {
            if ($script:previousGlobalAdoAccessToken) {
                Set-Variable -Name adoAccessToken -Value $script:previousGlobalAdoAccessToken.Value -Scope Global
            }
            else {
                Remove-Variable -Name adoAccessToken -Scope Global -ErrorAction SilentlyContinue
            }
        }

        It 'prefers Azure Pipelines then Default and falls back to the first queue' -ForEach @(
            @{
                Queues = @(
                    [pscustomobject]@{ name = 'Default'; id = 1 }
                    [pscustomobject]@{ name = 'Azure Pipelines'; id = 2 }
                )
                Expected = 2
            }
            @{
                Queues = @(
                    [pscustomobject]@{ name = 'First'; id = 3 }
                    [pscustomobject]@{ name = 'Default'; id = 4 }
                )
                Expected = 4
            }
            @{
                Queues = @(
                    [pscustomobject]@{ name = 'First'; id = 5 }
                    [pscustomobject]@{ name = 'Second'; id = 6 }
                )
                Expected = 5
            }
        ) {
            $script:agentQueues = @($Queues)
            Get-AzDoDefaultAgentQueueId -Project 'example-project' | Should -Be $Expected
        }

        It 'rejects an empty queue list and queues without a usable id' {
            { Get-AzDoDefaultAgentQueueId -Project 'example-project' } | Should -Throw '*No agent queues found*'
            $script:agentQueues = @([pscustomobject]@{ name = 'Unusable'; id = 0 })
            { Get-AzDoDefaultAgentQueueId -Project 'example-project' } | Should -Throw '*Unable to resolve an agent queue id*'
        }

        It 'decodes service descriptors and skips malformed identities' {
            $decodedIdentity = 'org\project\Build:project-id'
            $encodedIdentity = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($decodedIdentity)).TrimEnd('=')
            $script:serviceIdentities = @(
                [pscustomobject]@{ descriptor = 'svc.%%%'; displayName = 'Malformed service identity' }
                [pscustomobject]@{ descriptor = "svc.$encodedIdentity"; displayName = 'Example Build Service' }
            )
            Mock Get-VSTeamUser { $script:serviceIdentities }

            Get-AzDoBuildServiceIdentity -ProjectId 'project-id' -ProjectName 'example-project' |
                Should -Be "Microsoft.TeamFoundation.ServiceIdentity;$decodedIdentity"
        }

        It 'throws when no decodable Build Service identity matches the project' {
            Mock Get-VSTeamUser { @([pscustomobject]@{ descriptor = 'svc.%%%'; displayName = 'Malformed service identity' }) }

            { Get-AzDoBuildServiceIdentity -ProjectId 'project-id' -ProjectName 'example-project' } |
                Should -Throw "*Unable to find Build Service identity with descriptor ending 'Build:project-id'*"
        }

        It 'resolves a security action bit by its display name and rejects missing metadata' {
            $namespace = [pscustomobject]@{
                name = 'Git Repositories'
                actions = @([pscustomobject]@{ name = 'Contribute'; displayName = 'Contribute access'; bit = 8 })
            }
            Get-AzDoSecurityNamespaceActionBit -Namespace $namespace -ActionName 'Contribute access' | Should -Be 8

            $missingBitNamespace = [pscustomobject]@{
                name = 'Git Repositories'
                actions = @([pscustomobject]@{ name = 'Contribute' })
            }
            { Get-AzDoSecurityNamespaceActionBit -Namespace $missingBitNamespace -ActionName 'Contribute' } |
                Should -Throw "*Unable to resolve action 'Contribute'*"
        }

        It 'returns the matching access-control entry and treats unreadable ACL data as absent' {
            $script:expectedAce = [pscustomobject]@{ allow = 4; deny = 1 }
            $aceDictionary = @{ 'example-descriptor' = $script:expectedAce }
            Mock Get-VSTeamAccessControlList { [pscustomobject]@{ acesDictionary = $aceDictionary } }

            $ace = Get-AzDoAccessControlEntry -NamespaceId 'namespace-id' -Token 'repoV2/project-id/repository-id' -Descriptor 'example-descriptor'
            $ace.allow | Should -Be 4
            $ace.deny | Should -Be 1

            Mock Get-VSTeamAccessControlList { throw 'ACL lookup failed' }
            Get-AzDoAccessControlEntry -NamespaceId 'namespace-id' -Token 'repoV2/project-id/repository-id' -Descriptor 'example-descriptor' |
                Should -BeNullOrEmpty
        }

        It 'preserves existing repository permission masks and clears only a Contribute deny' {
            Mock Get-AzDoBuildServiceIdentity { ' service-descriptor ' }
            Mock Get-AzDoSecurityNamespaceByName { [pscustomobject]@{ Id = 'namespace-id' } }
            Mock Get-AzDoSecurityNamespaceActionBit { 8 }
            Mock Get-AzDoAccessControlEntry { [pscustomobject]@{ allow = 2; deny = 8 } }
            Mock Set-AzDoAccessControlEntry { }

            Initialize-AzDoBuildServiceRepositoryPermission -ProjectName 'example-project' -ProjectId 'project-id' -RepositoryId 'repository-id'

            Should -Invoke Set-AzDoAccessControlEntry -Times 1 -Exactly -ParameterFilter {
                $NamespaceId -eq 'namespace-id' -and
                $Token -eq 'repoV2/project-id/repository-id' -and
                $Descriptor -eq 'service-descriptor' -and
                $Allow -eq 10 -and
                $Deny -eq 0
            }

            Mock Get-AzDoAccessControlEntry { [pscustomobject]@{ allow = 8; deny = 0 } }
            Initialize-AzDoBuildServiceRepositoryPermission -ProjectName 'example-project' -ProjectId 'project-id' -RepositoryId 'repository-id'
            Should -Invoke Set-AzDoAccessControlEntry -Times 1 -Exactly
        }

        It 'leaves existing variable-group Approval and ExclusiveLock checks untouched' {
            $script:existingChecks = [pscustomobject]@{
                count = 2
                value = @(
                    [pscustomobject]@{
                        resource = [pscustomobject]@{ type = 'variablegroup'; id = '12' }
                        type = [pscustomobject]@{ name = 'Approval' }
                    }
                    [pscustomobject]@{
                        resource = [pscustomobject]@{ type = 'variablegroup'; id = '12' }
                        type = [pscustomobject]@{ name = 'ExclusiveLock' }
                    }
                )
            }
            Mock Invoke-RestMethod { $script:existingChecks }

            Initialize-AzDoVariableGroupApproval -Organization 'example-org' -Project 'example-project' -VariableGroupId '12' -VariableGroupName 'TEST' -ApproverTeam ([pscustomobject]@{ name = 'TEST deployment approvers' })
            Initialize-AzDoVariableGroupExclusiveLock -Organization 'example-org' -Project 'example-project' -VariableGroupId '12' -VariableGroupName 'TEST'

            Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter { $Method -eq 'Get' }
            Should -Invoke Invoke-VSTeamRequest -Times 0 -Exactly
            Should -Invoke Get-VSTeamGroup -Times 0 -Exactly
        }

        It 'creates missing variable-group Approval and ExclusiveLock checks' {
            $script:createdCheckTypes = @()
            Mock Get-VSTeamGroup {
                [pscustomobject]@{
                    principalName = 'TEST deployment approvers'
                    displayName = 'TEST deployment approvers'
                    originId = 'group-id'
                    descriptor = 'group-descriptor'
                }
            }
            Mock Invoke-VSTeamRequest {
                $check = $Body | ConvertFrom-Json
                $script:createdCheckTypes += $check.type.name
            }

            Initialize-AzDoVariableGroupApproval -Organization 'example-org' -Project 'example-project' -VariableGroupId '12' -VariableGroupName 'TEST' -ApproverTeam ([pscustomobject]@{ name = 'TEST deployment approvers' })
            Initialize-AzDoVariableGroupExclusiveLock -Organization 'example-org' -Project 'example-project' -VariableGroupId '12' -VariableGroupName 'TEST'

            $script:createdCheckTypes | Should -HaveCount 2
            $script:createdCheckTypes[0] | Should -Be 'Approval'
            $script:createdCheckTypes[1] | Should -Be 'ExclusiveLock'
            Should -Invoke Get-VSTeamGroup -Times 1 -Exactly
            Should -Invoke Invoke-VSTeamRequest -Times 2 -Exactly -ParameterFilter {
                $Method -eq 'POST' -and $Resource -eq 'pipelines/checks/configurations'
            }
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