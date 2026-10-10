param(
    [switch]$RequireServiceAccount
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($env:AZURE_CLIENT_ID)) {
    throw 'AZURE_CLIENT_ID is required. Set a GitHub environment variable or provide a prefixed repository secret/variable.'
}

if ([string]::IsNullOrWhiteSpace($env:AZURE_TENANT_ID)) {
    throw 'AZURE_TENANT_ID is required. Set a GitHub environment variable or provide a prefixed repository secret/variable.'
}

$tenant = $env:AZURE_TENANT_ID.Trim()
$isGuid = $tenant -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
$isDns = $tenant -match '^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}$'
if (-not ($isGuid -or $isDns)) {
    throw "AZURE_TENANT_ID value '$tenant' is invalid. Use a tenant GUID or tenant domain."
}

if ([string]::IsNullOrWhiteSpace($env:DATAVERSE_URL)) {
    throw 'DATAVERSE_URL is required. Set a GitHub environment variable or provide a prefixed repository variable.'
}

if ($RequireServiceAccount -and [string]::IsNullOrWhiteSpace($env:DATAVERSESERVICEACCOUNTUPN)) {
    throw 'DATAVERSESERVICEACCOUNTUPN is required. Set a GitHub environment variable or provide a prefixed repository secret/variable.'
}