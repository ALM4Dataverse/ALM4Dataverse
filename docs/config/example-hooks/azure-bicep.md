# Azure Resource Deployment with Bicep

This example shows how to deploy Azure resources using Bicep as part of the build and deploy pipelines.

The `postBuild` hook validates the Bicep file so that syntax errors are caught early. The `preDeploy` hook then deploys the Azure resources to the target environment before the Dataverse solutions are imported.

The following configuration is required to ensure the example scripts below are executed and that the `azure` folder (containing the Bicep files) is copied to the build artifacts so it is available at deploy time.

*alm-config.psd1 (partial content)*

```powershell
hooks = @{
    postBuild = @('azure/validate-bicep.ps1')
    preDeploy = @('azure/deploy-bicep.ps1')
}

assets = @(
    'azure'
)
```

## Bicep Template

Place your Bicep template in the `azure` folder of your repository. The example below deploys an Azure Storage Account.

*azure/main.bicep*

```bicep
param location string
param storageAccountName string

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
}
```

## Validating (Build)

The `postBuild` hook validates the Bicep file by compiling it to ARM JSON. This catches syntax and type errors early, before the artifacts are used in a deployment.

The hook runs after all solutions are packed and assets are copied, so `$Context.ArtifactStagingDirectory` points to the output folder. The Bicep source file is in `$Context.SourceDirectory`.

`az bicep build` compiles the Bicep file locally using the Bicep CLI embedded in `az`. It requires no Azure authentication. The Bicep CLI must be available on the build agent — run `az bicep install` as part of your agent setup if it is not already present.

*azure/validate-bicep.ps1*

```powershell
param($Context)

Write-Host "Validating Bicep template..."

az bicep build --file (Join-Path $Context.SourceDirectory 'azure/main.bicep')

if ($LASTEXITCODE -ne 0) {
    throw "Bicep validation failed"
}

Write-Host "Bicep validation passed."
```

## Deploying

The `preDeploy` hook deploys the Azure resources. It reads parameters from environment variables prefixed with `AzureBicep_` so that each environment's variable group can supply the correct values.

*azure/deploy-bicep.ps1*

```powershell
param($Context)

$resourceGroup = $env:AzureBicep_ResourceGroup
if ([string]::IsNullOrEmpty($resourceGroup)) {
    throw "AzureBicep_ResourceGroup environment variable is not set."
}

# Collect all AzureBicep_ prefixed variables as Bicep parameters
$params = @()
Get-ChildItem Env: | Where-Object { $_.Name -like 'AzureBicep_*' } | ForEach-Object {
    $paramName = $_.Name.Substring(11)  # Remove 'AzureBicep_' prefix
    $params += "$paramName=$($_.Value)"
}

Write-Host "Deploying Bicep template to resource group: $resourceGroup"

az deployment group create `
    --resource-group $resourceGroup `
    --template-file (Join-Path $Context.ArtifactsPath 'azure/main.bicep') `
    --parameters $params

if ($LASTEXITCODE -ne 0) {
    throw "Bicep deployment failed"
}

Write-Host "Bicep deployment completed successfully."
```

## Variable Group Configuration

Add the following variables to each environment's variable group (`Environment-{EnvironmentName}`). Each variable with the `AzureBicep_` prefix maps directly to a Bicep parameter of the same name (with the prefix removed).

| Variable Name | Example Value | Description |
|---|---|---|
| `AzureBicep_ResourceGroup` | `myapp-dev-rg` | Resource group to deploy into |
| `AzureBicep_location` | `eastus` | Azure region for new resources |
| `AzureBicep_storageAccountName` | `myappdevstorage` | Storage account name |

> Note: `AzureBicep_ResourceGroup` is special — it identifies **which** resource group to target and is always required. All other `AzureBicep_` variables are passed as Bicep parameters.
