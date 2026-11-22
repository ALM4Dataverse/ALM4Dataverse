BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repoRoot 'setup/setup-common.ps1')
    . (Join-Path $repoRoot 'setup/azdo/repository-setup-state.ps1')

    function Get-DataverseConnection {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Url', Justification = 'Mock command signature; Pester inspects these arguments.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'AccessToken', Justification = 'Mock command signature; Pester inspects these arguments.')]
        param($Url, [scriptblock]$AccessToken)
    }

    function Get-DataverseRecord {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Connection', Justification = 'Mock command signature; Pester inspects these arguments.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'TableName', Justification = 'Mock command signature; Pester inspects these arguments.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'FilterValues', Justification = 'Mock command signature; Pester inspects these arguments.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Columns', Justification = 'Mock command signature; Pester inspects these arguments.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Top', Justification = 'Mock command signature; Pester inspects these arguments.')]
        param($Connection, $TableName, $FilterValues, $Columns, $Top)
    }

    function Set-DataverseRecord {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Connection', Justification = 'Mock command signature; Pester inspects these arguments.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'TableName', Justification = 'Mock command signature; Pester inspects these arguments.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'CreateOnly', Justification = 'Mock command signature; Pester inspects these arguments.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'PassThru', Justification = 'Mock command signature; Pester inspects these arguments.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'InputObject', Justification = 'Mock command signature; Pester inspects these arguments.')]
        [CmdletBinding(SupportsShouldProcess = $true)]
        param(
            $Connection,
            $TableName,
            [switch]$CreateOnly,
            [switch]$PassThru,
            [Parameter(ValueFromPipeline)]$InputObject
        )
        process {}
    }
}

Describe 'Azure DevOps Dataverse application user roles' {
    BeforeEach {
        Mock Get-SetupAccessTokenCallback { { 'fake-token' } }
        Mock Get-DataverseConnection { [pscustomobject]@{ ConnectedOrgFriendlyName = 'Test' } }
        Mock Get-DataverseRecord {
            switch ($TableName) {
                businessunit { [pscustomobject]@{ businessunitid = 'business-unit' } }
                role {
                    $roleId = if ($FilterValues.name -eq 'System Customizer') { 'customizer-role' } else { 'admin-role' }
                    [pscustomobject]@{ roleid = $roleId }
                }
                systemuser { $null }
                systemuserroles { $null }
            }
        }
        Mock Set-DataverseRecord { [pscustomobject]@{ Id = 'user-id' } }
    }

    It 'assigns both required roles to the created application user' {
        Initialize-DataverseApplicationUser -EnvironmentUrl 'https://test.example.com' -ApplicationId 'app-id' -TenantId 'example.com'

        Should -Invoke Get-DataverseRecord -Times 1 -Exactly -ParameterFilter {
            $TableName -eq 'role' -and $FilterValues.name -eq 'System Administrator'
        }
        Should -Invoke Get-DataverseRecord -Times 1 -Exactly -ParameterFilter {
            $TableName -eq 'role' -and $FilterValues.name -eq 'System Customizer'
        }
        Should -Invoke Set-DataverseRecord -Times 1 -Exactly -ParameterFilter {
            $TableName -eq 'systemuser' -and $CreateOnly -and $PassThru
        }
        Should -Invoke Set-DataverseRecord -Times 2 -Exactly -ParameterFilter {
            $TableName -eq 'systemuserroles' -and $CreateOnly
        }
    }
}
