# Organization Settings

Use a deployment hook for environment-wide settings that are not solution components.

> [!CAUTION]
> The hook runs during DEPLOY, IMPORT, and BUILD deployment validation. Choose settings
> appropriate to every target using this configuration and review their environment-wide
> impact before enabling them.

Add the script to both the hook list and the assets list in your existing configuration:

```powershell
hooks = @{
    preDeploy     = @('deploy-orgsettings.ps1')
}

assets = @('deploy-orgsettings.ps1')
```

> [!IMPORTANT]
> Merge these fragments into existing `hooks` and `assets` entries without removing other
> hooks or data assets. The script must be in both lists. Use `preDeploy` for prerequisites
> needed before solution import, or `postDeploy` for settings that must be applied afterward.

Add your settings to the relevant blocks below.

You can find column names [in the documentation for the organization table](https://learn.microsoft.com/en-us/power-apps/developer/data-platform/reference/entities/organization).

You can find many "OrgDbOrgSettings" [in the settings for the OrgDbOrgSettings OSS tool](https://github.com/seanmcne/OrgDbOrgSettings/blob/master/mspfedyn_/OrgDbOrgSettings/Solution/WebResources/mspfedyn_/OrgDbOrgSettings/Settings.xml).

Check the type in the above sources carefully, as many are not as you would expect:

- Boolean values are `$true` and `$false`.
- String values are `"example"`.
- Numeric values are `1234.56`

> [!TIP]
> If you're not sure which settings are used or the values you need, use your browser F12 Network tools to see the request the standard PPAC/other settings UI sends.

Create `deploy-orgsettings.ps1` in your application repository:

```powershell
param([hashtable]$Context)

$ErrorActionPreference = 'Stop'

Set-DataverseOrganizationSettings -Verbose -Confirm:$false -InputObject ([PSCustomObject]@{
  advancedfilteringenabled=$true
  multicolumnsortenabled=1
})

Set-DataverseOrganizationSettings -OrgDbOrgSettings -Verbose -Confirm:$false -InputObject ([PSCustomObject]@{
  SkipSuffixOnKBArticles=$true
  SendEmailSynchronously=$false
})
```

When this executes, it will log out settings that were or were not changed:

```text
VERBOSE: Column 'advancedfilteringenabled': No change (value is 'True')
VERBOSE: Column 'multicolumnsortenabled': Changing from '0' to '1'
VERBOSE: Performing the operation "Update organization settings" on target "Organization record 9bf94c2a-1ee5-ee11-9048-0022481a23a4".
VERBOSE: Updated 1 attribute(s) in organization record 9bf94c2a-1ee5-ee11-9048-0022481a23a4
```

The hook reuses the connection established by the pipeline. Do not embed credentials or connect to a hard-coded target inside the script. For target-specific choices, read explicitly configured runner environment variables. See [hook context and ordering](../alm-config.md#hooks).
