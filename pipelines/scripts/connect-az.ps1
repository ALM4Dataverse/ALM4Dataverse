<#
.SYNOPSIS
    Establishes Azure CLI and Az PowerShell contexts from the Azure DevOps service connection.
.DESCRIPTION
    Uses the client-secret credentials or federated token file supplied by the
    ALM4Dataverse Set Connection Variables task. Fails if neither auth type is
    fully configured or either login fails. Does not read credentials from
    configuration files. Az PowerShell skips subscription-context population;
    hooks that need a subscription must select one explicitly. Azure CLI uses its
    own allow-no-subscriptions option. An unresolved Azure DevOps client-secret
    macro is treated as absent so downstream authentication can use the
    federated token file.
#>

$ErrorActionPreference = 'Stop'

$clientId = $env:AZURE_CLIENT_ID
$tenantId = $env:AZURE_TENANT_ID
if ([string]::IsNullOrWhiteSpace($clientId) -or [string]::IsNullOrWhiteSpace($tenantId)) {
    throw 'AZURE_CLIENT_ID and AZURE_TENANT_ID are required to sign in to Azure.'
}

$azLoginArguments = @(
    'login'
    '--service-principal'
    '--username'
    $clientId
    '--tenant'
    $tenantId
    '--allow-no-subscriptions'
    '--output'
    'none'
)

$clientSecret = $env:AZURE_CLIENT_SECRET
if ($clientSecret -match '^\$\(.+\)$') {
    $clientSecret = $null
    $env:AZURE_CLIENT_SECRET = $null
}

if (-not [string]::IsNullOrWhiteSpace($clientSecret) -and $clientSecret -notmatch '^\$\(.+\)$') {
    $secureClientSecret = ConvertTo-SecureString -String $clientSecret -AsPlainText -Force
    $servicePrincipalCredential = [System.Management.Automation.PSCredential]::new($clientId, $secureClientSecret)
    Connect-AzAccount `
        -ServicePrincipal `
        -Tenant $tenantId `
        -Credential $servicePrincipalCredential `
        -SkipContextPopulation `
        -ErrorAction Stop | Out-Null
    $azLoginArguments += "--password=$($env:AZURE_CLIENT_SECRET)"
}
else {
    $federatedTokenFile = $env:AZURE_FEDERATED_TOKEN_FILE
    if ([string]::IsNullOrWhiteSpace($federatedTokenFile)) {
        throw 'Set Connection Variables did not provide AZURE_CLIENT_SECRET or AZURE_FEDERATED_TOKEN_FILE for Azure sign-in.'
    }
    if (-not (Test-Path -LiteralPath $federatedTokenFile -PathType Leaf)) {
        throw "Azure federated token file '$federatedTokenFile' was not found."
    }

    $federatedToken = (Get-Content -LiteralPath $federatedTokenFile -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($federatedToken)) {
        throw "Azure federated token file '$federatedTokenFile' is empty."
    }

    Connect-AzAccount `
        -ServicePrincipal `
        -Tenant $tenantId `
        -ApplicationId $clientId `
        -FederatedToken $federatedToken `
        -SkipContextPopulation `
        -ErrorAction Stop | Out-Null
    $azLoginArguments += @('--federated-token', $federatedToken)
}

$azCommand = Get-Command -Name 'az' -ErrorAction Stop
& $azCommand @azLoginArguments
if ($LASTEXITCODE -ne 0) {
    throw "Azure CLI login failed with exit code $LASTEXITCODE."
}
