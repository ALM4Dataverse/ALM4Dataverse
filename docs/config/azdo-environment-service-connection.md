# Service Connection Configuration

This document describes service connection options for Azure DevOps environments used by ALM4Dataverse pipelines.

## Overview

When `useAlm4DataverseExtension: true`, pipelines use Power Platform service connections and the ALM4Dataverse extension **Set Connection Variables** task.

When `useAlm4DataverseExtension: false`, pipelines still use Power Platform service connections, but use Power Platform Build Tools **Set Connection Variables** task (`PowerPlatformSetConnectionVariables@2`). In this mode, only service-principal-with-secret authentication is available.

For detailed steps on creating service principals and service connections, see the [Manual Setup Guide](../setup/azdo-manual-setup.md#4-service-principal-setup).

## Service Connection Type

### Power Platform Service Connection

ALM4Dataverse uses Power Platform service connections to authenticate to Dataverse environments.

**Type**: Power Platform (with Application Id and client secret)

**Configuration**:
- **Authentication Type**: Application Id and client secret
- **Server URL**: Your Dataverse environment URL (e.g., `https://yourorg.crm.dynamics.com`)
- **Tenant ID**: The Directory (tenant) ID from your App Registration in Entra ID
- **Application ID**: The Application (client) ID from your App Registration
- **Client Secret**: The client secret value from your App Registration

## Service Connection Naming Convention

Service connections follow the naming pattern used in the pipelines:

`{EnvironmentName}`

**Examples**:
- `DEV-main` - for the Dev environment on main branch
- `PROD` - for the PROD environment

## Setting Up Service Connections

See [Service Principal Setup](../setup/azdo-manual-setup.md#4-service-principal-setup) in the Manual Setup Guide for detailed instructions on:

1. Creating an App Registration in Entra ID
2. Creating a client secret
3. Creating an application user in each Dataverse environment
4. Creating the service connection in Azure DevOps

## Example Service Connection Configuration

### Development Environment (Dev-main)

| Connection Name | Environment URL | Authentication |
|---|---|---|
| `Dev-main` | `https://yourorg-dev.crm.dynamics.com` | Service Principal: `YourProject - Dev - deployment` |

### Test Environment (TEST-main)

| Connection Name | Environment URL | Authentication |
|---|---|---|
| `TEST-main` | `https://yourorg-test.crm.dynamics.com` | Service Principal: `YourProject - TEST - deployment` |

### Production Environment (PROD)

| Connection Name | Environment URL | Authentication |
|---|---|---|
| `PROD` | `https://yourorg.crm.dynamics.com` | Service Principal: `YourProject - PROD - deployment` |

## Best Practices

### Security

- **System Administrator Role**: Assign the System Administrator security role to the application user in each Dataverse environment to allow solution import and export.
- **Dedicated Service Principals**: Create separate service principals for each environment (e.g. separate app registrations for Dev, TEST, UAT, and PROD).
- **Client Secret Rotation**: Rotate client secrets periodically and track expiration dates to prevent authentication failures.

## Optional: Azure Key Vault secret mapping for DEPLOY

The `deploy-environment.yml` stage template can optionally fetch extra secrets from Azure Key Vault and map them to runtime environment variables **before** ALM4Dataverse deploy scripts run.

```yaml
- template: pipelines/templates/stages/deploy-environment.yml@ALM4Dataverse
  parameters:
    environmentName: PROD
    keyVaultName: contoso-kv-prod
    keyVaultServiceConnection: Contoso-Shared-Azure
    keyVaultSecrets:
      DATAVERSESERVICEACCOUNTUPN: dataverse-service-upn
      CustomApiKey: contoso-api-key
```

In this example:
- `keyVaultSecrets` maps `{ targetEnvVarName: keyVaultSecretName }`
- `dataverse-service-upn` is fetched from Key Vault and exposed to scripts as `DATAVERSESERVICEACCOUNTUPN`
- `contoso-api-key` is exposed as `CustomApiKey`

### Key Vault permissions for the deployment identity

Grant the identity used by `keyVaultServiceConnection` permission to read secrets from the target Key Vault:

- **RBAC model (recommended)**: assign **Key Vault Secrets User** on the vault scope
- **Access policy model**: grant **Get** and **List** secret permissions

Use least privilege and scope access to only the vault required by that deployment stage.

## Reference

- [Manual Setup Guide - Service Principal Setup](../setup/azdo-manual-setup.md#4-service-principal-setup)
- [Manual Setup Guide - Service Connections](../setup/azdo-manual-setup.md#5-service-connections)
- [Environment Variable Group Configuration](azdo-environment-variable-group.md)
- [Create and use a service connection](https://learn.microsoft.com/en-us/azure/devops/pipelines/library/service-endpoints)
- [Power Platform service connections](https://learn.microsoft.com/en-us/power-platform/alm/devops-build-tools#configure-service-connections-using-a-service-principal)
- [Create an application user in Dataverse](https://learn.microsoft.com/en-us/power-platform/admin/manage-application-users)
- [Register an application with Entra ID](https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-register-app)
