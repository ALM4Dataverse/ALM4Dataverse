# Service Connection Configuration

This document describes service connection options for Azure DevOps environments used by ALM4Dataverse pipelines.

## Overview

When `useAlm4DataverseExtension: true`, pipelines use Power Platform service connections and the ALM4Dataverse extension **Set Connection Variables** task.

When `useAlm4DataverseExtension: false`, pipelines still use Power Platform service connections, but use Power Platform Build Tools **Set Connection Variables** task (`PowerPlatformSetConnectionVariables@2`). In this mode, only service-principal-with-secret authentication is available.

For detailed steps on creating service principals and service connections, see the [Manual Setup Guide](../setup/manual-setup.md#4-service-principal-setup).

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

See [Service Principal Setup](../setup/manual-setup.md#4-service-principal-setup) in the Manual Setup Guide for detailed instructions on:

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

- **System Administrator Role**: Assign the System Administrator security role to the application user in each Dataverse environment to allow solution import and export
- **Dedicated Service Principals**: Create separate service principals for each environment (e.g., separate app registrations for Dev, TEST, UAT, and PROD)
- **Client Secret Rotation**: Rotate client secrets periodically and track expiration dates to prevent authentication failures
### Organization

## Reference

- [Manual Setup Guide - Service Principal Setup](../setup/manual-setup.md#4-service-principal-setup)
- [Manual Setup Guide - Service Connections](../setup/manual-setup.md#5-service-connections)
- [Environment Variable Group Configuration](environment-variable-group.md)
- [Create and use a service connection](https://learn.microsoft.com/en-us/azure/devops/pipelines/library/service-endpoints)
- [Power Platform service connections](https://learn.microsoft.com/en-us/power-platform/alm/devops-build-tools#configure-service-connections-using-a-service-principal)
- [Create an application user in Dataverse](https://learn.microsoft.com/en-us/power-platform/admin/manage-application-users)
- [Register an application with Entra ID](https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-register-app)
