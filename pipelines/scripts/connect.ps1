<#
.SYNOPSIS
    Connects to a Dataverse environment using the provided connection string.
.DESCRIPTION

    This script establishes a connection to the Dataverse environment specified 
    by the URL. After connecting, it validates the connection by
    calling WhoAmI to ensure the identity has access to the target environment.

.PARAMETER Url
    The URL of the Dataverse environment to connect to.
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$url
)

Write-Host "##[group] Connecting to Dataverse environment with URL: $url"
Get-DataverseConnection -setasdefault -DefaultAzureCredential -Url $url | out-null
Write-Host "Validating connection using WhoAmI..."
$whoAmI = Get-DataverseWhoAmI
Write-Host "Connected to Dataverse environment. UserId: $($whoAmI.UserId), BusinessUnitId: $($whoAmI.BusinessUnitId), OrganizationId: $($whoAmI.OrganizationId)"
Write-Host "##[endgroup]"

Write-Host "##[group] Signing in to Azure CLI"
if ($env:AZURE_CLIENT_ID -and $env:AZURE_TENANT_ID) {
    Write-Host "Signing in to Azure CLI..."
    if ($env:AZURE_FEDERATED_TOKEN_FILE) {
        az login --service-principal -u $env:AZURE_CLIENT_ID --federated-token (Get-Content $env:AZURE_FEDERATED_TOKEN_FILE -Raw) --tenant $env:AZURE_TENANT_ID --output none
    } else {
        az login --service-principal -u $env:AZURE_CLIENT_ID -p $env:AZURE_CLIENT_SECRET --tenant $env:AZURE_TENANT_ID --output none
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI sign-in failed"
    }
    Write-Host "Azure CLI sign-in successful."
} else {
    Write-Host "##[debug]Azure CLI sign-in skipped (AZURE_CLIENT_ID or AZURE_TENANT_ID not set)."
}
Write-Host "##[endgroup]"