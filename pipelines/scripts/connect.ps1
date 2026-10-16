<#
.SYNOPSIS
    Connects PAC and the default Dataverse client using an existing Azure identity.
.DESCRIPTION

    This script establishes a connection to the Dataverse environment specified
    by the URL. After connecting, it validates the connection by
    calling WhoAmI to ensure the identity has access to the target environment.

.PARAMETER Url
    The URL of the Dataverse environment to connect to.
.NOTES
    Requires installed PAC and Dataverse cmdlets plus a non-interactive Azure
    sign-in context. Creates/selects the PAC profile before setting the default
    Dataverse connection; WhoAmI failures propagate rather than reporting success.
.EXAMPLE
    .\pipelines\scripts\connect.ps1 -Url https://example.crm.dynamics.com
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