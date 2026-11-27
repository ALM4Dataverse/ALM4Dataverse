# Azure DevOps Service Connections

This document describes service connection options for Azure DevOps environments used by ALM4Dataverse pipelines.

## Overview

When `useAlm4DataverseExtension: true`, pipelines use Power Platform service connections and the ALM4Dataverse extension **Set Connection Variables** task.

When `useAlm4DataverseExtension: false`, pipelines still use Power Platform service connections, but use Power Platform Build Tools **Set Connection Variables** task (`PowerPlatformSetConnectionVariables@2`). In this mode, only service-principal-with-secret authentication is available.

| Connection-variable task | Client secret | Workload identity federation (WIF) |
| --- | --- | --- |
| ALM4Dataverse extension (`useAlm4DataverseExtension: true`, the default) | Supported | Supported |
| Microsoft Power Platform Build Tools (`useAlm4DataverseExtension: false`) | Supported | Not supported by this integration |

WIF is preferred when available because it avoids a long-lived client secret. Both methods require an Entra app registration and a Dataverse application user with permission to perform the solution operations. The separate service-account UPN used for process ownership belongs in the [variable group](azdo-environment-variable-group.md).

For DEPLOY with the ALM4Dataverse extension, the Set Connection Variables task
provides the client-secret or WIF token-file values. The deployment template uses
those values to log in to both Azure CLI and Az PowerShell before running the
deployment script and its `postDeploy` hook. The client-secret and WIF login
methods use their corresponding service-connection credentials. Az PowerShell
skips automatic subscription-context population; hooks that need subscription-
scoped cmdlets must select a subscription explicitly. The CLI login uses
`--allow-no-subscriptions`, so an Azure subscription is not required for login.
`useAlm4DataverseExtension: false` supports client-secret connections only and
uses the Build Tools task's secret output for both Azure logins.
DEPLOY checks that the selected build artifact contains the login helper; if it
does not, the error instructs you to rebuild the artifact with the updated shared ref.

For detailed steps on creating service principals and service connections, see the [Manual Setup Guide](../setup/azdo-manual-setup.md#4-service-principal-setup).

## Service Connection Type

### Power Platform Service Connection

ALM4Dataverse uses Power Platform service connections to authenticate to Dataverse environments.

**Type**: Power Platform, using either application ID/client secret or workload identity federation.

**Common configuration:**

- **Server URL**: Your Dataverse environment URL (e.g., `https://yourorg.crm.dynamics.com`)
- **Tenant ID**: The Directory (tenant) ID from your App Registration in Entra ID
- **Application ID**: The Application (client) ID from your App Registration

> [!IMPORTANT]
> For client-secret authentication, supply the secret **value**, not its ID, and track
> expiry. For WIF, use the connection's displayed issuer and subject with audience
> `api://AzureADTokenExchange`; do not guess an issuer or assume a legacy `sc://...` subject.
> Client/application IDs and Entra object IDs are different values. Follow the form's labels.

## Service Connection Naming Convention

Service connections follow the naming pattern used in the pipelines:

`{EnvironmentName}`

**Examples**:

- `Dev-main` - for the development environment on the `main` branch
- `PROD` - for the PROD environment

`EXPORT` and `IMPORT` use `Dev-<Build.SourceBranchName>`. Optional BUILD deployment validation uses `buildEnvironmentName`; DEPLOY uses `environmentName`. These identify connections, not Dataverse display names. See [template parameters](pipelines.md#azure-devops-templates).

## Setting Up Service Connections

See [Service Principal Setup](../setup/azdo-manual-setup.md#4-service-principal-setup) in the Manual Setup Guide for detailed instructions on:

1. Creating an App Registration in Entra ID
2. Configuring a client secret or federated credential
3. Creating an application user in each Dataverse environment
4. Creating the service connection in Azure DevOps

### App registration permissions

Setup checks the signed-in account's Entra ID directory roles, app-registration
ownership and the tenant's **Users can register applications** setting before it
offers app-registration changes. Actions the account cannot perform are dimmed and
cannot be selected:

- **Create new App Registration (Entra ID)** needs permission to create an app
  registration and its enterprise application. The Application Administrator,
  Cloud Application Administrator, Global Administrator and Application Developer
  roles grant it; otherwise the tenant must allow users to register applications.
- **Generate a new client secret when changes are applied** adds a password
  credential, and choosing **Workload Identity Federation** for an existing app
  registration adds a federated identity credential. Both need ownership of the app
  registration or an application-administration role.
- **Reuse** of a WIF credential for another environment adds a federated identity
  credential with that service connection's subject, so it needs the same access.
- Reusing an existing service connection does not change the Entra application and
  remains available.

When Microsoft Graph cannot answer, setup leaves the action available rather than
block a permitted account after a transient read failure; the later write still
requires Graph authorization and can fail. Custom directory roles are not inspected,
and an application owner can still be denied by the client application's granted
Graph scopes.

### Existing application validation

When you select **Enter existing Service Principal details** or a search result, setup
reads the App Registration and checks:

- The client ID exists in the tenant.
- An enterprise application (service principal) exists.
- The app registration requests the Dataverse `user_impersonation` delegated
  permission (**API permissions** > **Dynamics CRM** > **Delegated permissions** >
  `user_impersonation`). An Entra administrator must grant admin consent.
- A non-expired client secret exists, a federated identity credential with audience
  `api://AzureADTokenExchange`, the exact required issuer and the exact required subject
  exists, or both. The issuer and subject are checked when setup knows them: the GitHub
  repository and environment values, or the Azure DevOps service connection values.

The Dataverse application user grants access to the environment; the
`user_impersonation` permission is the scope the deployment identity requests.

Problems are shown before the authentication step with **Continue with this
application**, **Recheck application setup**, and **Enter a different application ID**.
Continuing records the explicit choice but does not change the app. The authentication
menu offers only the configured methods; if neither method is usable, both remain
available after the warning. When extension mode is disabled, WIF is never offered.
Setup never displays or retrieves an existing secret value, so client secret
authentication still asks for the value.

**Create a new application manually (with instructions)** displays the Entra portal
steps and then validates the application ID you enter. **Search for an existing
application by name** lists applications whose display name starts with the text you
enter; it is dimmed when the account cannot list applications. Reusing an existing
service connection does not validate or change its Entra application.

## Example Service Connection Configuration

### Development Environment (Dev-main)

| Connection Name | Environment URL | Authentication |
| --- | --- | --- |
| `Dev-main` | `https://yourorg-dev.crm.dynamics.com` | Service Principal: `YourProject - Dev - deployment` |

### Test Environment (TEST-main)

| Connection Name | Environment URL | Authentication |
| --- | --- | --- |
| `TEST-main` | `https://yourorg-test.crm.dynamics.com` | Service Principal: `YourProject - TEST - deployment` |

### Production Environment (PROD)

| Connection Name | Environment URL | Authentication |
| --- | --- | --- |
| `PROD` | `https://yourorg.crm.dynamics.com` | Service Principal: `YourProject - PROD - deployment` |

## Best Practices

### Security

- **System Administrator Role**: Assign the System Administrator security role to the application user in each Dataverse environment to allow solution import and export.
- **Dedicated Service Principals**: Create separate service principals for each environment (e.g. separate app registrations for Dev, TEST, UAT, and PROD).
- **Client Secret Rotation**: Rotate client secrets periodically and track expiration dates to prevent authentication failures.

### Pipeline Access

Authorize only the pipelines that use the connection: EXPORT and IMPORT for development,
BUILD when validation is enabled, and the relevant DEPLOY pipelines for target environments.

> [!NOTE]
> Repository, variable-group, service-connection, and deployment-environment permissions
> are separate. A successful interactive setup sign-in does not prove the pipeline's
> application identity has access.

## Reference

- [Manual Setup Guide - Service Principal Setup](../setup/azdo-manual-setup.md#4-service-principal-setup)
- [Manual Setup Guide - Service Connections](../setup/azdo-manual-setup.md#5-service-connections)
- [Environment Variable Group Configuration](azdo-environment-variable-group.md)
- [Create and use a service connection](https://learn.microsoft.com/en-us/azure/devops/pipelines/library/service-endpoints)
- [Power Platform service connections](https://learn.microsoft.com/en-us/power-platform/alm/devops-build-tools#configure-service-connections-using-a-service-principal)
- [Create an application user in Dataverse](https://learn.microsoft.com/en-us/power-platform/admin/manage-application-users)
- [Register an application with Entra ID](https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-register-app)
