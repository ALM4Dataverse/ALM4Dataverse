# Azure DevOps Automated Setup

> [!TIP]
> Need to configure resources individually? Follow the [manual setup guide](azdo-manual-setup.md).

Setup provisions ALM resources interactively: repositories, caller pipelines, service
connections, variable groups, and target configuration. It does not create your Dataverse
environments or replace a backup/recovery plan. Run it with a setup identity authorized
to make these changes; pipeline execution later uses the configured application identities.

## Limitations

- The account you use for setup must be in the same Entra ID tenant as:

  - the Dataverse environments for development and deployment
  - the Azure DevOps organisation.

- The process works for the standard `Azure Cloud` (`Commercial`) cloud and not `GCC` etc.

- Generated pipelines use Microsoft-hosted `windows-2022` agents. Self-hosted pools require manual template customization and validation; they are not a setup-script option.

- Entra ID Applications:
  - if created automatically, will have name in format `<project name> - <env name> deployment` (but you can safely rename them if you wish after creation).
  - you will be prompted to choose between two authentication types:
    - **Service Principal with Secret (traditional)**: Uses a client secret that expires and needs periodic renewal
    - **Workload Identity Federation (recommended)**: Uses OpenID Connect federation with no secrets to manage

## Pre-requisites

Before you start, you need:

- Windows PowerShell 5.1 or PowerShell 7 on Windows, plus network access to the required Microsoft services, GitHub, and package feeds.
- Existing Dataverse environments, the solutions to manage, and suitable process-owner user accounts.
- Permission to create/configure Entra apps, Dataverse application users, and the relevant Azure DevOps resources, or administrators available to complete those steps.

Setup downloads a temporary portable Git and its required PowerShell modules. Keep
interactive authentication in the console/browser; do not put passwords or tokens into
source files or command history.

### 1) An Azure DevOps organisation

You will need an Azure DevOps organisation with pipeline capabilities enabled. See [Azure DevOps Organisation Requirements](azdo-organisation-requirements.md) for details on:

- Creating a new organisation if you don't have one
- Configuring pipeline capabilities (free or paid options)
  
### 2) An Azure DevOps project or permissions to create one

You will need to be 'Project Collection Administrator' if you want the automated process to create a new project for you. Otherwise, you will need a project with 'Project Administrator' role assigned to you.
  
[How to create a new project](https://learn.microsoft.com/en-us/azure/devops/organizations/projects/create-project?view=azure-devops&tabs=browser#create-a-project)

> [!TIP]
> Choose a long-lived project name. Avoid phase names such as "CRM System Phase 1".

[How to assign the project administrator role for an existing project](https://learn.microsoft.com/en-us/azure/devops/user-guide/project-admin-tutorial?toc=%2Fazure%2Fdevops%2Forganizations%2Ftoc.json&view=azure-devops#add-members-to-the-project-administrators-group)

### 3) Entra ID Applications for each environment

> [!TIP]
> Use a separate application for each environment (or at least one for non-production and one for production) to keep proper separation between environments.
> There is no cost to these applications, so there is no significant overhead in doing this.

## Running Setup

Download and review the released script before executing it:

```powershell
Invoke-WebRequest 'https://github.com/ALM4Dataverse/ALM4Dataverse/releases/latest/download/setup-azdo.ps1' -OutFile './setup-azdo.ps1'
```

After review, run `.\setup-azdo.ps1`. To select a tenant, device authentication, or shared
code ref, use the [setup parameters](../config/pipelines.md#setup-script-parameters).

> [!NOTE]
> **Advanced: running source scripts.** Released setup scripts embed their helpers and
> pinned dependencies. A single raw script downloaded from the source repository is not
> equivalent; it needs the adjacent shared files.

The one-line bootstrap is also available after you have reviewed and trust the release:

1) Open "Windows PowerShell" from the start menu (every Windows computer has this installed)

2) Paste this in and press Enter.

   ```powershell
   iwr https://github.com/ALM4Dataverse/ALM4Dataverse/releases/latest/download/setup-azdo.ps1 | iex
   ```

   Use the download-and-review approach above before trusting this bootstrap.

3) Follow the on-screen instructions.

## What Setup Does

1) Prompts you to authenticate. The account you select will be used when connecting to AzDO and Dataverse environments during setup.
2) Ensures the required Power Platform AzDO Extension is installed in the target AzDO organisation.
   If you have the required level of access, it will be enabled automatically.
   Pipeline execution still uses the pinned `pacCliVersion` installed by `installdependencies.ps1` (the templates keep PPBT `AddToolsToPath` disabled).
3) Prompts you whether to use the ALM4Dataverse extension task for connection-variable resolution.
   - If enabled, setup can use either client secret or workload identity federation authentication.
   - If disabled, setup configures pipelines to use the Power Platform Build Tools **Set Connection Variables** task with service-principal secret auth.
4) Prompts you to select an existing AzDO project, or create a new one.
   If you select the option to create a new one, you will be prompted for the name and process template.
5) Imports or updates the shared `ALM4Dataverse` repo.
6) Prompts you to select the Git repo in the AzDO project or create a new one and creates the required pipelines files and registrations.
7) Prompts you to select a Dataverse environment to be used as the main development environment and creates the required variable groups and service connections.
8) Prompts you to select the solutions to be managed in dependency order and edits the `alm-config.psd1` file
9) Prompts you to select Dataverse environments to be used as the deployment targets (your test and production environments) and creates the required variable groups and service connections.
10) For both the dev environment and all deployment environments, prompts you to select the Entra ID application (service principal) you want to use, with an option to create one automatically.
11) For each selected service principal, prompts you to choose the authentication type:
     - **Service Principal with Secret**: Traditional approach using client secrets
     - **Workload Identity Federation**: Modern approach using federated credentials (no secrets required)
     - When ALM4Dataverse extension mode is disabled, only **Service Principal with Secret** is available.
12) For both the dev environment and all deployment environments, prompts you to select the Service Account (user account) you want to use. This must be pre-existing as no option to create one is provided.
13) Offers shared BUILD validation, configures its URL/authentication/service account, and lets you choose a separate deployment environment as the baseline source or choose no baseline.

> [!NOTE]
> **Advanced: BUILD validation.** Generated pipelines deploy an available baseline first,
> then the candidate, and run configured PAC Solution Checker rules. If the baseline source
> has no successful deployment pointer yet, BUILD warns and validates only the candidate.
> A successful DEPLOY creates the pointer for subsequent builds.
>
> Setup creates no deployment approvers team or approval check for the BUILD variable group.
> Deployment target groups retain their approval checks, and existing checks are left unchanged.
> All branches share the validation target, so choose a non-production environment that is
> safe to update repeatedly. See [Building Releases](../usage/building-releases.md).

## After Setup

1. Review generated caller files, solution order, environment URLs, authentication type, and the selected shared-code ref.
2. Complete target settings that automation cannot infer: connection IDs, Dataverse values, custom secrets, and hook configuration. See [variable groups](../config/azdo-environment-variable-group.md).
3. Check pipeline resource permissions, approver membership, and locks. Confirm the process-owner UPN identifies the intended enabled Dataverse user.
4. Run [EXPORT](../usage/exporting-changes.md) to establish solution source, then verify [BUILD](../usage/building-releases.md).
5. Deploy that exact build to a non-production target and test the application before promoting it further.
6. Configure branch/PR build policies separately if required; setup does not enforce your review process.

## Reconfigure An Existing Installation

Re-run setup to select existing resources and review its proposed updates.

> [!CAUTION]
> Preserve and review custom callers/templates, hooks, secret mappings, and approval checks.
> Do not run two setups concurrently against the same repository. If setup fails partway,
> inspect resources already created before retrying; changes are not automatically rolled back.

Keep shared repository updates and application caller changes consistent. An older
release artifact retains its packaged deployment scripts even after shared code is
updated. See [pipeline parameters](../config/pipelines.md) for manual customization.
