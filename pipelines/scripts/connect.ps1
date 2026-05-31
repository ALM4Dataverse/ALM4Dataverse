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

. (Join-Path $PSScriptRoot 'common.ps1')

Initialize-PacAuthentication

Write-Host "##[group] Connecting to Dataverse environment with URL: $url"
Get-DataverseConnection -setasdefault -DefaultAzureCredential -Url $url | out-null
Write-Host "Validating connection using WhoAmI..."
$whoAmI = Get-DataverseWhoAmI
Write-Host "Connected to Dataverse environment. UserId: $($whoAmI.UserId), BusinessUnitId: $($whoAmI.BusinessUnitId), OrganizationId: $($whoAmI.OrganizationId)"
Write-Host "##[endgroup]"