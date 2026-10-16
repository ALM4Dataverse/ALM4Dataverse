BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $script:environmentResolver = Join-Path $repoRoot '.github/actions/common/resolve-prefixed-env.ps1'
    $script:authenticationValidator = Join-Path $repoRoot '.github/actions/common/validate-auth.ps1'
}

Describe 'GitHub environment mapping and authentication validation' {
    BeforeEach {
        # Resolver writes survive script scope; remove inherited inputs and restore every tracked
        # mapping afterward so developer credentials or earlier cases cannot satisfy a missing field.
        $script:savedActionEnvironment = @{}
        foreach ($name in @('GITHUB_ENV', 'VARS_JSON', 'SELECTED_SECRETS_JSON', 'RESOLVED_ENVIRONMENT_NAME', 'AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'AZURE_CLIENT_SECRET', 'DATAVERSE_URL', 'DATAVERSESERVICEACCOUNTUPN', 'DATAVERSE_SERVICE_ACCOUNT_UPN', 'DATAVERSE_CONNECTION_REFS', 'DATAVERSE_CONN_REFS', 'ALM_TEST_BOOLEAN', 'ALM_TEST_NUMBER', 'ALM_TEST_ARRAY', 'DATAVERSECONNREF_ALM_MAPPING_TEST', 'DATAVERSEENVVAR_ALM_MAPPING_TEST', 'CONFIG_ALM_MAPPING_TEST')) {
            $script:savedActionEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $null)
        }
        $env:GITHUB_ENV = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.env')
        $env:RESOLVED_ENVIRONMENT_NAME = 'Unit Test'
    }

    AfterEach {
        foreach ($name in $script:savedActionEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $script:savedActionEnvironment[$name])
        }
    }

    It 'maps direct values and aliases while preserving existing environment values' {
        $env:AZURE_CLIENT_ID = 'existing-client'
        $env:VARS_JSON = '{"AZURE_CLIENT_ID":"ignored-client","AZURE_TENANT_ID":"tenant.example.com","DATAVERSE_URL":"https://example.crm.dynamics.com","DATAVERSE_CONN_REFS":{"reference":"value"},"DATAVERSESERVICEACCOUNTUPN":"service@example.com"}'
        & $script:environmentResolver
        $env:AZURE_CLIENT_ID | Should -Be existing-client
        $env:AZURE_TENANT_ID | Should -Be tenant.example.com
        $env:DATAVERSE_CONNECTION_REFS | Should -Be '{"reference":"value"}'
        $env:DATAVERSESERVICEACCOUNTUPN | Should -Be service@example.com
        & $script:authenticationValidator -RequireServiceAccount
    }

    It 'maps normalized environment prefixes, aliases, and explicit false or zero values' {
        $env:VARS_JSON = '{"UNIT_TEST_AZURE_CLIENT_ID":"client","UNIT_TEST_DATAVERSE_SERVICE_ACCOUNT_UPN":"service@example.com","UNIT_TEST_DATAVERSE_CONN_REFS":"refs","ALM_TEST_BOOLEAN":false,"ALM_TEST_NUMBER":0,"ALM_TEST_ARRAY":[1,2],"UNIT_TEST_":"ignored","UNIT_TEST_DATAVERSE_URL":null}'
        & $script:environmentResolver
        $env:AZURE_CLIENT_ID | Should -Be client
        $env:DATAVERSESERVICEACCOUNTUPN | Should -Be service@example.com
        $env:DATAVERSE_CONNECTION_REFS | Should -Be refs
        $env:ALM_TEST_BOOLEAN | Should -Be false
        $env:ALM_TEST_NUMBER | Should -Be '0'
        $env:ALM_TEST_ARRAY | Should -Be '[1,2]'
        $env:DATAVERSE_URL | Should -BeNullOrEmpty
    }

    It 'masks explicitly supplied secrets and writes Azure credentials without exposing them in host messages' {
        $env:VARS_JSON = '{"AZURE_CLIENT_ID":"client","AZURE_TENANT_ID":"example.com"}'
        $env:SELECTED_SECRETS_JSON = '{"AZURE_CLIENT_SECRET":"fake-test-secret","ALM_TEST_NUMBER":0,"DATAVERSE_URL":null,"DATAVERSESERVICEACCOUNTUPN":""}'
        $output = @(& $script:environmentResolver)
        $output | Should -Contain '::add-mask::fake-test-secret'
        $env:AZURE_CLIENT_SECRET | Should -Be fake-test-secret
        $env:ALM_TEST_NUMBER | Should -Be '0'
        Get-Content $env:GITHUB_ENV -Raw | Should -Match 'ALM_AZURE_CREDENTIALS<<EOF_'
    }

    It 'handles missing, null, and malformed variable context safely' {
        $env:VARS_JSON = '['
        . $script:environmentResolver
        ConvertTo-HashtableSafe '' | Should -BeOfType hashtable
        ConvertTo-HashtableSafe 'null' | Should -BeOfType hashtable
        Get-PrefixFromEnvironment '' | Should -Be ''
        Get-PrefixFromEnvironment '!!!' | Should -Be ''
        Get-PrefixFromEnvironment '  test-prod ' | Should -Be 'TEST_PROD_'
    }

    It 'rejects malformed and non-object explicit secrets' -ForEach @(
        @{ Json = '[' }
        @{ Json = '[1,2]' }
        @{ Json = 'null' }
    ) {
        $env:SELECTED_SECRETS_JSON = $Json
        { & $script:environmentResolver } | Should -Throw '*must contain a JSON object*'
    }

    It 'rejects each missing authentication field and invalid tenants' -ForEach @(
        @{ Missing = 'AZURE_CLIENT_ID'; Tenant = 'example.com'; Message = '*AZURE_CLIENT_ID is required*' }
        @{ Missing = 'AZURE_TENANT_ID'; Tenant = 'example.com'; Message = '*AZURE_TENANT_ID is required*' }
        @{ Missing = 'DATAVERSE_URL'; Tenant = 'example.com'; Message = '*DATAVERSE_URL is required*' }
        @{ Missing = 'DATAVERSESERVICEACCOUNTUPN'; Tenant = 'example.com'; Message = '*DATAVERSESERVICEACCOUNTUPN is required*' }
        @{ Missing = ''; Tenant = 'not a tenant'; Message = '*is invalid*' }
    ) {
        $env:AZURE_CLIENT_ID = 'client'
        $env:AZURE_TENANT_ID = $Tenant
        $env:DATAVERSE_URL = 'https://example.crm.dynamics.com'
        $env:DATAVERSESERVICEACCOUNTUPN = 'service@example.com'
        if ($Missing) { [Environment]::SetEnvironmentVariable($Missing, $null) }
        { & $script:authenticationValidator -RequireServiceAccount } | Should -Throw $Message
    }

    It 'accepts GUID tenants without requiring a service account by default' {
        $env:AZURE_CLIENT_ID = 'client'
        $env:AZURE_TENANT_ID = '00000000-0000-0000-0000-000000000001'
        $env:DATAVERSE_URL = 'https://example.crm.dynamics.com'
        & $script:authenticationValidator
    }

    It 'honors Dataverse mapping precedence for <Label>' -ForEach @(
        @{ Label = 'environment-specific over unprefixed values'; Variables = '{"DATAVERSECONNREF_ALM_MAPPING_TEST":"connection-test","DATAVERSEENVVAR_ALM_MAPPING_TEST":"direct-test","TEST_MAIN_DATAVERSEENVVAR_ALM_MAPPING_TEST":"prefixed-test"}'; Selected = '{}'; Existing = ''; Expected = 'prefixed-test'; Connection = 'connection-test' }
        @{ Label = 'selected values over runtime and variables'; Variables = '{"DATAVERSEENVVAR_ALM_MAPPING_TEST":"direct-test"}'; Selected = '{"DATAVERSEENVVAR_ALM_MAPPING_TEST":"selected-test"}'; Existing = 'existing-test'; Expected = 'selected-test'; Connection = '' }
        @{ Label = 'existing runtime values'; Variables = '{"DATAVERSEENVVAR_ALM_MAPPING_TEST":"direct-test"}'; Selected = '{}'; Existing = 'existing-test'; Expected = 'existing-test'; Connection = '' }
        @{ Label = 'environment-specific fallback'; Variables = '{"TEST_MAIN_DATAVERSEENVVAR_ALM_MAPPING_TEST":"prefixed-test"}'; Selected = '{}'; Existing = ''; Expected = 'prefixed-test'; Connection = '' }
    ) {
        Set-StrictMode -Version Latest
        $env:RESOLVED_ENVIRONMENT_NAME = 'TEST-main'
        $env:VARS_JSON = $Variables
        $env:SELECTED_SECRETS_JSON = $Selected
        $env:DATAVERSEENVVAR_ALM_MAPPING_TEST = $Existing
        & $script:environmentResolver
        $env:DATAVERSEENVVAR_ALM_MAPPING_TEST | Should -Be $Expected
        $env:DATAVERSECONNREF_ALM_MAPPING_TEST | Should -Be $Connection
    }

    It 'maps unprefixed values and prefers environment-specific values' {
        $env:RESOLVED_ENVIRONMENT_NAME = 'TEST-main'
        $env:VARS_JSON = '{"CONFIG_ALM_MAPPING_TEST":"unprefixed","TEST_MAIN_CONFIG_ALM_MAPPING_TEST":"environment-specific"}'
        & $script:environmentResolver
        $env:CONFIG_ALM_MAPPING_TEST | Should -Be 'environment-specific'

        [Environment]::SetEnvironmentVariable('CONFIG_ALM_MAPPING_TEST', $null)
        $env:VARS_JSON = '{"CONFIG_ALM_MAPPING_TEST":"unprefixed"}'
        & $script:environmentResolver
        $env:CONFIG_ALM_MAPPING_TEST | Should -Be 'unprefixed'
    }

    It 'maps service-account aliases and prefers the environment-specific alias' {
        $env:RESOLVED_ENVIRONMENT_NAME = 'TEST-main'
        $env:VARS_JSON = '{"DATAVERSE_SERVICE_ACCOUNT_UPN":"unprefixed-alias"}'
        & $script:environmentResolver
        $env:DATAVERSESERVICEACCOUNTUPN | Should -Be 'unprefixed-alias'

        [Environment]::SetEnvironmentVariable('DATAVERSESERVICEACCOUNTUPN', $null)
        $env:VARS_JSON = '{"DATAVERSESERVICEACCOUNTUPN":"unprefixed-compact","TEST_MAIN_DATAVERSE_SERVICE_ACCOUNT_UPN":"prefixed-alias"}'
        & $script:environmentResolver
        $env:DATAVERSESERVICEACCOUNTUPN | Should -Be 'prefixed-alias'
    }
}