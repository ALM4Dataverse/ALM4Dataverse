# Organization Settings

Configure organization-wide settings directly in `alm-config.psd1` rather than
creating a deployment hook for ordinary setting updates. The six setting maps are:

| Key | Applies |
| --- | --- |
| `organizationSettings` | Organization-table columns before deployment. |
| `postDeployOrganizationSettings` | Organization-table columns after deployment. |
| `orgDbOrgSettings` | OrgDbOrgSettings values before deployment. |
| `postDeployOrgDbOrgSettings` | OrgDbOrgSettings values after deployment. |
| `powerPlatformSettings` | Power Platform Environment Management API settings before deployment. |
| `postDeployPowerPlatformSettings` | Power Platform Environment Management API settings after deployment. |

The unprefixed maps are applied before the `preDeploy` hook and before any solution
imports. The `postDeploy` maps run after the `postDeploy` hook. Omit unused maps.
Each map is a hashtable of setting names to static PowerShell values or scriptblocks.
Scriptblocks receive `$Context` with `HookType`, `BaseDirectory`, `Config`,
`ArtifactsPath`, and `UseUnmanagedSolutions`; each must emit exactly one setting
value. They run as trusted PowerShell in the deployment process.

```powershell
organizationSettings = @{
    # Enable PCF controls in canvas apps.
    IsCustomControlsInCanvasAppsEnabled = $true
}

postDeployOrganizationSettings = @{}

orgDbOrgSettings = @{
    # Allow unmanaged changes during deployment.
    IsLockDownOfUnmanagedCustomizationEnabled = $false

    # Resolve a setting value from the target runner's environment.
    SomeDynamicSetting = {
        param($Context)
        [int]$env:MY_ORGANIZATION_SETTING
    }
}

powerPlatformSettings = @{
    # This name is the property sent by PPAC; there is no complete public catalog.
    PowerApps_AllowCodeApps = $true
}

postDeployOrgDbOrgSettings = @{
    # Block unmanaged customizations after the deployment has completed.
    IsLockDownOfUnmanagedCustomizationEnabled = $true
}
```

For organization-table names, see Microsoft's [Organization table reference](https://learn.microsoft.com/en-us/power-apps/developer/data-platform/reference/entities/organization).
Microsoft's [environment-setting guidance](https://learn.microsoft.com/en-us/power-apps/developer/data-platform/organization-table)
explains which organization columns are supported to change; writable does not
necessarily mean supported. See Microsoft's [block unmanaged customizations guidance](https://learn.microsoft.com/en-us/power-platform/alm/block-unmanaged-customizations)
for the behavior of that example.

For OrgDbOrgSettings names and types, see Microsoft's [environment database settings
guidance](https://learn.microsoft.com/en-us/power-platform/admin/environment-database-settings)
and its linked [OrgDbOrgSettings tool reference](https://support.microsoft.com/help/2691237/orgdborgsettings-tool-for-microsoft-dynamics-crm). The community-maintained
[settings XML](https://github.com/seanmcne/OrgDbOrgSettings/blob/master/mspfedyn_/OrgDbOrgSettings/Solution/WebResources/mspfedyn_/OrgDbOrgSettings/Settings.xml)
is a searchable list, but can lag newer settings; verify the setting name and type
against current feature documentation.

Power Platform API setting names don't have a complete public catalog. To discover
one, change it in PPAC and inspect the request URL and JSON payload in your browser's
developer tools Network tab. The pipeline resolves the environment ID by matching
the connected Dataverse organization against the Power Platform [environment list API](https://learn.microsoft.com/en-us/rest/api/power-platform/environmentmanagement/environments)
and patches the selected setting through the [Environment Management Settings API](https://learn.microsoft.com/en-us/rest/api/power-platform/environmentmanagement/environment-management-settings).
See the [EnvironmentManagementSetting model reference](https://learn.microsoft.com/en-us/dotnet/api/microsoft.powerplatform.management.models.environmentmanagementsetting?view=power-platform-latest)
for additional API model details.

Power Platform RBAC roles are currently available only at tenant scope; assign an
appropriate role to the identity used for the Power Platform API. When
`AZURE_CLIENT_SECRET` is configured, it is used; otherwise authentication uses the
Dataverse module's `DefaultAzureCredential` chain, including workload identity
federation, managed identity, and Azure CLI. See Microsoft's [authentication guidance](https://learn.microsoft.com/en-us/power-platform/admin/programmability-authentication-v2)
and [service-principal RBAC tutorial](https://learn.microsoft.com/en-us/power-platform/admin/programmability-tutorial-rbac-role-assignment).

Organization settings run during DEPLOY, IMPORT, and BUILD deployment validation,
so these values can also modify a shared validation environment. The deployment
is not transactional: if a later import or hook fails, earlier setting changes
remain applied. Use settings appropriate to every target and test them in a
non-production environment first.

Keep hook scripts for custom actions that can't be expressed as setting values.
Hooks reuse the pipeline's Dataverse connection; don't embed credentials or connect
to a hard-coded target. See [hook context and ordering](../alm-config.md#hooks).
