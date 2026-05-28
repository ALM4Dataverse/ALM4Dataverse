# Environment Variable Group Configuration

This document describes the variables that should be configured in each environment's variable group in Azure DevOps.

## Overview

Each environment (Dev-main, TEST-main, UAT-main, PROD, etc.) requires a variable group named `Environment-{EnvironmentName}` containing environment-specific configuration values.

These variable groups are used by the pipelines to:
- Configure connection references to use environment-specific connections
- Set environment variable values that differ between environments
- Provide other environment-specific settings

## Variable Group Naming Convention

Variable groups must follow this naming pattern:

`Environment-<environment name>`

For example:
- `Environment-DEV-main`
- `Environment-PROD`

> Note: the DEV environment name is always suffixed with the branch name, which is `main` by default.

## Required Variables

### Connection Reference Variables

Connection references in Dataverse solutions must be configured to point to the correct connection in each environment.

**Naming Pattern**: `DataverseConnRef_{connectionreference_uniquename}`

For each connection reference in your solution:
- **Variable name**: `DataverseConnRef_` followed by the connection reference unique name (schema name)
- **Variable value**: The connection ID from the target environment

**Example**:
```
Variable Name: DataverseConnRef_contoso_sharedsharepointonline_12abc
Variable Value: 00000000-0000-0000-0000-000000000000
```

#### How to Find Connection Reference Unique Names

 - Open your solution in the maker portal
 - Go to **Connection References**
 - Note the **Name** column - this is the unique name (schema name)

#### How to Find Connection IDs

1. Navigate to the target environment in the Power Platform maker portal: https://make.powerapps.com
2. Select the correct environment from the environment picker
3. Go to **Data** > **Connections**
4. Find the connection you want to use
5. Click on the connection to open its details
6. The Connection ID is in the URL: `https://make.powerapps.com/environments/{envid}/connections/{connectiontype}/{connectionid}`
7. Copy the `{connectionid}` GUID

### Environment Variable Values

Environment variables in Dataverse can have different values in each environment.

**Naming Pattern**: `DataverseEnvVar_{environmentvariable_schemaname}`

For each environment variable in your solution:
- **Variable name**: `DataverseEnvVar_` followed by the environment variable schema name
- **Variable value**: The value for this environment

**Example**:
```
Variable Name: DataverseEnvVar_contoso_APIEndpoint
Variable Value: https://api.production.contoso.com
```

#### How to Find Environment Variable Schema Names

 - Open your solution in the maker portal
 - Go to **Environment variables**
 - Note the **Name** column - this is the schema name

## Example Variable Groups

### Environment-Dev-main

| Variable Name | Value | Notes |
|--------------|-------|-------|
| `DataverseConnRef_contoso_sharedsharepointonline_12abc` | `12345678-1234-1234-1234-123456789abc` | SharePoint connection for dev site |
| `DataverseConnRef_contoso_sharedcommondataserviceforapps_98xyz` | `98765432-9876-9876-9876-987654321xyz` | Dataverse connection |
| `DataverseEnvVar_contoso_APIEndpoint` | `https://api.dev.contoso.com` | Dev API endpoint |
| `DataverseEnvVar_contoso_BatchSize` | `10` | Smaller batch size for dev |
| `DataverseEnvVar_contoso_FeatureXEnabled` | `true` | Feature flag |

### Environment-TEST-main

| Variable Name | Value | Notes |
|--------------|-------|-------|
| `DataverseConnRef_contoso_sharedsharepointonline_12abc` | `23456789-2345-2345-2345-23456789abcd` | SharePoint connection for test site |
| `DataverseConnRef_contoso_sharedcommondataserviceforapps_98xyz` | `87654321-8765-8765-8765-876543219xyz` | Dataverse connection |
| `DataverseEnvVar_contoso_APIEndpoint` | `https://api.test.contoso.com` | Test API endpoint |
| `DataverseEnvVar_contoso_BatchSize` | `50` | Medium batch size for test |
| `DataverseEnvVar_contoso_FeatureXEnabled` | `true` | Feature flag |

### Environment-PROD

| Variable Name | Value | Notes |
|--------------|-------|-------|
| `DataverseConnRef_contoso_sharedsharepointonline_12abc` | `34567890-3456-3456-3456-34567890abce` | SharePoint connection for prod site |
| `DataverseConnRef_contoso_sharedcommondataserviceforapps_98xyz` | `76543210-7654-7654-7654-765432108xyz` | Dataverse connection |
| `DataverseEnvVar_contoso_APIEndpoint` | `https://api.contoso.com` | Production API endpoint |
| `DataverseEnvVar_contoso_BatchSize` | `100` | Larger batch size for production |
| `DataverseEnvVar_contoso_FeatureXEnabled` | `false` | Feature disabled in prod initially |


## Reference

- [Use Azure DevOps variable groups](https://learn.microsoft.com/en-us/azure/devops/pipelines/library/variable-groups)
- [Connection references overview](https://learn.microsoft.com/en-us/power-apps/maker/data-platform/create-connection-reference)
- [Environment variables overview](https://learn.microsoft.com/en-us/power-apps/maker/data-platform/environmentvariables)
