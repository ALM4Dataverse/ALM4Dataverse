Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$names = @(
    'GITHUB_ENV', 'VARS_JSON', 'SELECTED_SECRETS_JSON', 'RESOLVED_ENVIRONMENT_NAME',
    'AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'AZURE_CLIENT_SECRET',
    'DATAVERSECONNREF_ALM_MAPPING_TEST', 'DATAVERSEENVVAR_ALM_MAPPING_TEST'
)
$saved = @{}
foreach ($name in $names) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name)
}
$outputPath = [IO.Path]::GetTempFileName()

try {
    foreach ($name in $names) {
        [Environment]::SetEnvironmentVariable($name, $null)
    }
    $env:GITHUB_ENV = $outputPath
    $env:RESOLVED_ENVIRONMENT_NAME = 'TEST-main'
    $env:SELECTED_SECRETS_JSON = '{}'
    $env:VARS_JSON = @{
        DATAVERSECONNREF_ALM_MAPPING_TEST = 'connection-test'
        DATAVERSEENVVAR_ALM_MAPPING_TEST = 'direct-test'
        TEST_MAIN_DATAVERSEENVVAR_ALM_MAPPING_TEST = 'prefixed-test'
    } | ConvertTo-Json -Compress

    & "$repoRoot/.github/actions/common/resolve-prefixed-env.ps1"
    if ($env:DATAVERSECONNREF_ALM_MAPPING_TEST -ne 'connection-test' -or
        $env:DATAVERSEENVVAR_ALM_MAPPING_TEST -ne 'direct-test') {
        throw 'Direct Dataverse mapping must take precedence over prefixed variables.'
    }
    Write-Host 'PASS: Direct Dataverse settings and precedence'

    $env:SELECTED_SECRETS_JSON = '{"DATAVERSEENVVAR_ALM_MAPPING_TEST":"selected-test"}'
    & "$repoRoot/.github/actions/common/resolve-prefixed-env.ps1"
    if ($env:DATAVERSEENVVAR_ALM_MAPPING_TEST -ne 'selected-test') {
        throw 'Explicit selected values must override runtime and variable values.'
    }
    Write-Host 'PASS: Selected values take precedence'

    $env:SELECTED_SECRETS_JSON = '{}'
    $env:DATAVERSEENVVAR_ALM_MAPPING_TEST = 'existing-test'
    & "$repoRoot/.github/actions/common/resolve-prefixed-env.ps1"
    if ($env:DATAVERSEENVVAR_ALM_MAPPING_TEST -ne 'existing-test') {
        throw 'Variables must not overwrite an existing runtime value.'
    }
    Write-Host 'PASS: Existing runtime values are preserved'

    [Environment]::SetEnvironmentVariable('DATAVERSEENVVAR_ALM_MAPPING_TEST', $null)
    $env:VARS_JSON = '{"TEST_MAIN_DATAVERSEENVVAR_ALM_MAPPING_TEST":"prefixed-test"}'
    & "$repoRoot/.github/actions/common/resolve-prefixed-env.ps1"
    if ($env:DATAVERSEENVVAR_ALM_MAPPING_TEST -ne 'prefixed-test') {
        throw 'Environment-specific prefixed fallback failed.'
    }
    Write-Host 'PASS: Environment-specific prefixed fallback'

    [Environment]::SetEnvironmentVariable('DATAVERSEENVVAR_ALM_MAPPING_TEST', $null)
    $env:VARS_JSON = '{"PREFIX_DATAVERSEENVVAR_ALM_MAPPING_TEST":"fallback-test"}'
    & "$repoRoot/.github/actions/common/resolve-prefixed-env.ps1"
    if ($env:DATAVERSEENVVAR_ALM_MAPPING_TEST -ne 'fallback-test') {
        throw 'Literal PREFIX_ fallback failed.'
    }
    Write-Host 'PASS: Literal prefix fallback'
    Write-Host 'All environment mapping checks passed under StrictMode Latest.'
}
finally {
    foreach ($name in $names) {
        [Environment]::SetEnvironmentVariable($name, $saved[$name])
    }
    Remove-Item -LiteralPath $outputPath -Force
}