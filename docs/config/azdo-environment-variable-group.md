# Azure DevOps Environment Variable Groups

Use variable groups for target-specific settings, and [service connections](azdo-environment-service-connection.md) for authentication. Do not put target credentials or secret values into the application's configuration or build artifacts.

## Overview

Each environment (Dev-main, TEST-main, UAT-main, PROD, etc.) requires a variable group named `Environment-{EnvironmentName}` containing environment-specific configuration values.

These variable groups are used by the pipelines to:

- Configure connection references to use environment-specific connections
- Set environment variable values that differ between environments
- Select the user who owns and activates workflows and flows
- Provide settings for custom hooks

> [!NOTE]
> **Advanced: custom callers.** EXPORT and IMPORT callers attach the development group,
> DEPLOY uses each target group, and optional BUILD validation uses its own group.
> Preserve those declarations when customizing callers; the shared export/import
> templates do not attach the group themselves.

## Variable Group Naming Convention

Variable groups must follow this naming pattern:

`Environment-<environment name>`

For example:

- `Environment-Dev-main`
- `Environment-PROD`

The default development name uses `Dev-<Build.SourceBranchName>`. Azure DevOps uses the final branch path component: `feature/customer-import` becomes `Dev-customer-import`. See [branching strategies](../usage/branching-strategies.md) before introducing branches with slashes.

## Required Variables

| Variable | Required for | Value |
| --- | --- | --- |
| `DataverseServiceAccountUpn` | Process activation during IMPORT, DEPLOY, and BUILD deployment validation | UPN of an existing enabled user in the target Dataverse environment. |
| Custom key named by `solutions[].serviceAccountUpnConfigKey` | A solution that overrides its process owner | UPN of that solution's owner. The runner reads the uppercased key. |
| `DataverseConnRef_<schema-name>` | Each connection reference needing a target connection | Existing connection ID in the target environment. |
| `DataverseEnvVar_<schema-name>` | Each environment variable needing a target value | String value, with sensitive values marked secret. |

> [!IMPORTANT]
> The service account is **not** the service principal/application user used for
> authentication. It needs appropriate licenses, roles, and connection access for the
> processes it owns. Connections must already exist; supplying an ID does not create
> one or grant access to it.

### Connection Reference Variables

Connection references in Dataverse solutions must be configured to point to the correct connection in each environment.

**Naming Pattern**: `DataverseConnRef_{connectionreference_uniquename}`

For each connection reference in your solution:

- **Variable name**: `DataverseConnRef_` followed by the connection reference unique name (schema name)
- **Variable value**: The connection ID from the target environment

**Example**:

```text
Variable Name: DataverseConnRef_contoso_sharedsharepointonline_12abc
Variable Value: 00000000-0000-0000-0000-000000000000
```

#### How to Find Connection Reference Unique Names

- Open your solution in the maker portal.
- Go to **Connection References**.
- Note the **Name** column, which contains the unique/schema name.

#### How to Find Connection IDs

1. Navigate to the target environment in the [Power Platform maker portal](https://make.powerapps.com).
2. Select the correct environment from the environment picker
3. Go to **Data** > **Connections**
4. Find the connection you want to use
5. Click on the connection to open its details
6. The Connection ID is in the URL: `https://make.powerapps.com/environments/{envid}/connections/{connectiontype}/{connectionid}`
7. Copy the `{connectionid}` exactly; use the connection identifier, not the Dataverse connection-reference record ID.

### Environment Variable Values

Environment variables in Dataverse can have different values in each environment.

**Naming Pattern**: `DataverseEnvVar_{environmentvariable_schemaname}`

For each environment variable in your solution:

- **Variable name**: `DataverseEnvVar_` followed by the environment variable schema name
- **Variable value**: The value for this environment

**Example**:

```text
Variable Name: DataverseEnvVar_contoso_APIEndpoint
Variable Value: https://api.production.contoso.com
```

#### How to Find Environment Variable Schema Names

- Open your solution in the maker portal.
- Go to **Environment variables**.
- Note the **Name** column, which contains the schema name.

### Secret Values

Mark sensitive variables as secret using the lock control in the variable group.

> [!IMPORTANT]
> Azure DevOps does not automatically expose secret variables to scripts. Add an explicit
> mapping to the `env` block of the relevant PowerShell build/import/deploy step, alongside
> its existing authentication mappings.

Example mapping:

```yaml
env: { DataverseEnvVar_contoso_APIKey: '$(DataverseEnvVar_contoso_APIKey)' }
```

This is a customization to the shared template or a caller-owned equivalent step; declaring a secret only in the group is insufficient. Do not echo secrets or include them in a command line. Variable-group approvals protect access to the group; they are not a replacement for restricting who can edit the pipeline and its hooks.

## Example Variable Groups

### Environment-Dev-main

| Variable Name | Value | Notes |
| --- | --- | --- |
| `DataverseServiceAccountUpn` | `svc-dataverse-dev@contoso.com` | Process owner in Dev |
| `DataverseConnRef_contoso_sharedsharepointonline_12abc` | `12345678-1234-1234-1234-123456789abc` | SharePoint connection for dev site |
| `DataverseConnRef_contoso_sharedcommondataserviceforapps_98xyz` | `98765432-9876-9876-9876-987654321abc` | Dataverse connection |
| `DataverseEnvVar_contoso_APIEndpoint` | `https://api.dev.contoso.com` | Dev API endpoint |
| `DataverseEnvVar_contoso_BatchSize` | `10` | Smaller batch size for dev |
| `DataverseEnvVar_contoso_FeatureXEnabled` | `true` | Feature flag |

### Environment-TEST-main

| Variable Name | Value | Notes |
| --- | --- | --- |
| `DataverseServiceAccountUpn` | `svc-dataverse-test@contoso.com` | Process owner in Test |
| `DataverseConnRef_contoso_sharedsharepointonline_12abc` | `23456789-2345-2345-2345-23456789abcd` | SharePoint connection for test site |
| `DataverseConnRef_contoso_sharedcommondataserviceforapps_98xyz` | `87654321-8765-8765-8765-876543219abc` | Dataverse connection |
| `DataverseEnvVar_contoso_APIEndpoint` | `https://api.test.contoso.com` | Test API endpoint |
| `DataverseEnvVar_contoso_BatchSize` | `50` | Medium batch size for test |
| `DataverseEnvVar_contoso_FeatureXEnabled` | `true` | Feature flag |

### Environment-PROD

| Variable Name | Value | Notes |
| --- | --- | --- |
| `DataverseServiceAccountUpn` | `svc-dataverse-prod@contoso.com` | Process owner in Production |
| `DataverseConnRef_contoso_sharedsharepointonline_12abc` | `34567890-3456-3456-3456-34567890abce` | SharePoint connection for prod site |
| `DataverseConnRef_contoso_sharedcommondataserviceforapps_98xyz` | `76543210-7654-7654-7654-765432108abc` | Dataverse connection |
| `DataverseEnvVar_contoso_APIEndpoint` | `https://api.contoso.com` | Production API endpoint |
| `DataverseEnvVar_contoso_BatchSize` | `100` | Larger batch size for production |
| `DataverseEnvVar_contoso_FeatureXEnabled` | `false` | Feature disabled in prod initially |

## Permissions And Checks

Authorize each consuming pipeline under the group's **Pipeline permissions**. Add an **Exclusive lock** for operations sharing a target. Add **Approvals** for controlled deployment targets; BUILD's disposable validation environment normally should not require deployment approval. Review existing checks when reusing a group because setup leaves them in place.

## Reference

- [Use Azure DevOps variable groups](https://learn.microsoft.com/en-us/azure/devops/pipelines/library/variable-groups)
- [Connection references overview](https://learn.microsoft.com/en-us/power-apps/maker/data-platform/create-connection-reference)
- [Environment variables overview](https://learn.microsoft.com/en-us/power-apps/maker/data-platform/environmentvariables)
