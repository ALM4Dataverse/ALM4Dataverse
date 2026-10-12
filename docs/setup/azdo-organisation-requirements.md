# Azure DevOps Organisation Requirements

Before setting up ALM4Dataverse, your Azure DevOps organisation needs to be properly configured.

The supplied setup targets **Azure DevOps Services**, commercial Azure, and
Microsoft-hosted Windows agents. Azure DevOps Server, sovereign-cloud authentication,
and custom/self-hosted pools require separate validation and are not automatically
configured by these guides.

## Creating an Azure DevOps Organisation

If you don't have an existing Azure DevOps organisation, follow [the instructions provided by Microsoft](https://learn.microsoft.com/en-us/azure/devops/organizations/accounts/create-organization?view=azure-devops#create-an-organization-1) to create one.

> [!TIP]
> Name the organization after your company or division, not a specific project or phase.

## Pipeline Capabilities

Your organisation will need to be configured with pipeline capabilities. You have two options:

### Option A: Free Limited Pipelines Usage

If you qualify, you can use the free tier with limited pipeline parallel jobs.

[Follow the instructions provided by Microsoft to request free limited pipeline usage](https://learn.microsoft.com/en-us/azure/devops/pipelines/get-started/what-is-azure-pipelines?view=azure-devops#azure-pipelines-pricing)

### Option B: Paid Parallel Jobs

Alternatively, purchase Microsoft-hosted parallel-job capacity for longer jobs and no
monthly hosted-minute cap on that purchased capacity. This does not mean unlimited
concurrency or unlimited job duration.

[See the Microsoft documentation for information on configuring parallel jobs](https://learn.microsoft.com/en-us/azure/devops/pipelines/licensing/concurrent-jobs?view=azure-devops&tabs=ms-hosted)

> [!IMPORTANT]
> Free private hosted jobs are limited to 60 minutes; paid hosted jobs can run up to
> 360 minutes. ALM4Dataverse requests 360 minutes but cannot raise your capacity limit.
> Check current grants and limits rather than assuming a public project receives a
> particular entitlement. Microsoft maintains the [hosted-agent limits](https://learn.microsoft.com/en-us/azure/devops/pipelines/agents/hosted#capabilities-and-limitations).

Ensure hosted agents can reach Dataverse and the required package feeds. Private network
endpoints or restrictive IP rules may need a different runner/network arrangement.

## Permissions

Arrange permission to create repositories, pipelines, variable groups, environments,
and service connections. Installing extensions can require organization-level access.
Entra app and Dataverse application-user permissions are separate from Azure DevOps
permissions. After setup, authorize the runtime Build Service only for the resources
each pipeline needs; see [pipeline permissions](azdo-manual-setup.md#9-pipeline-permissions).

## Extensions

### Power Platform Build Tools

The Power Platform Build Tools extension is required for the pipelines to work.

> [!NOTE]
> **Advanced: PAC version selection.** ALM4Dataverse installs PAC through its dependency
> installer and pins the version using `pacCliVersion` from the application/shared defaults.
> The templates set `PowerPlatformToolInstaller@2` to `AddToolsToPath: false` so the
> Microsoft tool installer does not override that pinned version.

1. Navigate to the Azure DevOps Marketplace: [Power Platform Build Tools](https://marketplace.visualstudio.com/items?itemName=microsoft-IsvExpTools.PowerPlatform-BuildTools)
2. Click "Get it free"
3. Select your Azure DevOps organization
4. Click "Install"

📖 **Reference**: [Install extensions](https://learn.microsoft.com/en-us/azure/devops/marketplace/install-extension)

## ALM4Dataverse AzDO Extensions

The ALM4Dataverse AzDO Extensions extension is optional.

- **Required** when using Workload Identity Federation (WIF)
- **Required** when `useAlm4DataverseExtension: true`
- **Optional** when `useAlm4DataverseExtension: false` (pipelines use PPBT Set Connection Variables with service-principal secret auth)

1. Navigate to the Azure DevOps Marketplace: [ALM4Dataverse Azure DevOps Extensions](https://marketplace.visualstudio.com/items?itemName=ALM4Dataverse.alm4dataverse-azdo-extensions)
2. Click "Get it free"
3. Select your Azure DevOps organization
4. Click "Install"

📖 **Reference**: [Install extensions](https://learn.microsoft.com/en-us/azure/devops/marketplace/install-extension)
