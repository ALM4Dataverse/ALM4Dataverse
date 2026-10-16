BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $script:connectionScript = Join-Path $repoRoot 'pipelines/scripts/connect.ps1'
    function Invoke-ConnectionTestPac {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        param($Verb, $Operation)
    }
    function Get-DataverseConnection {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        param([switch]$SetAsDefault, [switch]$DefaultAzureCredential, $Url)
    }
    function Get-DataverseWhoAmI {}
}

Describe 'Dataverse pipeline connection' {
    BeforeEach {
        # Authentication consumes process environment, not just parameters; use fake identities
        # and restore the caller's values even when the identity probe throws.
        $script:savedConnectionEnvironment = @{ AZURE_CLIENT_ID = $env:AZURE_CLIENT_ID; AZURE_TENANT_ID = $env:AZURE_TENANT_ID; DATAVERSE_URL = $env:DATAVERSE_URL }
        $script:savedConnectionExitCode = $global:LASTEXITCODE
        $env:AZURE_CLIENT_ID = 'test-client'
        $env:AZURE_TENANT_ID = 'test-tenant'
        $env:DATAVERSE_URL = 'https://example.crm.dynamics.com'
        Mock Get-Command { [pscustomobject]@{ Source = 'Invoke-ConnectionTestPac' } } -ParameterFilter { $Name -eq 'pac' }
        Mock Invoke-ConnectionTestPac { $global:LASTEXITCODE = 0 }
        Mock Get-DataverseConnection {}
        Mock Get-DataverseWhoAmI { @{ UserId = 'user'; BusinessUnitId = 'business'; OrganizationId = 'organization' } }
    }

    AfterEach {
        foreach ($name in $script:savedConnectionEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $script:savedConnectionEnvironment[$name])
        }
        $global:LASTEXITCODE = $script:savedConnectionExitCode
    }

    It 'authenticates PAC and verifies the default Dataverse connection' {
        & $script:connectionScript -Url 'https://example.crm.dynamics.com'
        Should -Invoke Get-DataverseConnection -Times 1 -Exactly -ParameterFilter { $SetAsDefault -and $DefaultAzureCredential -and $Url -eq 'https://example.crm.dynamics.com' }
        Should -Invoke Get-DataverseWhoAmI -Times 1 -Exactly
        Should -Invoke Invoke-ConnectionTestPac -Times 1 -Exactly -ParameterFilter { $Operation -eq 'who' }
    }

    It 'propagates inaccessible identity failures' {
        Mock Get-DataverseWhoAmI { throw 'WhoAmI denied' }
        { & $script:connectionScript -Url 'https://example.crm.dynamics.com' } | Should -Throw '*WhoAmI denied*'
    }
}