# Automated Setup

> If you are unable to use the automated setup process, you can follow the instructions in the [manual setup guide](azdo-manual-setup.md).

## Limitations

- The account you use for setup must be in the same Entra ID tenant as:

    - the Dataverse environments for development and deployment
    - the Azure DevOps organisation.

- The process works for the standard `Azure Cloud` (`Commercial`) cloud and not `GCC` etc.

- The process works with Microsoft hosted Pipelines agents only currently and not self-hosted.

- Entra ID Applications:
    - if created automatically, will have name in format '<project name> - <env name> deployment' (but you can safely rename them if you wish after creation).
    - you will be prompted to choose between two authentication types:
      - **Service Principal with Secret (traditional)**: Uses a client secret that expires and needs periodic renewal
      - **Workload Identity Federation (recommended)**: Uses OpenID Connect federation with no secrets to manage

## Pre-requisites

Before you start, you need:

### 1) An Azure DevOps organisation.

You will need an Azure DevOps organisation with pipeline capabilities enabled. See [Azure DevOps Organisation Requirements](azdo-organisation-requirements.md) for details on:
- Creating a new organisation if you don't have one
- Configuring pipeline capabilities (free or paid options)
  
### 2) An Azure DevOps project or permissions to create one.
   
You will need to be 'Project Collection Administrator' if you want the automated process to create a new project for you. Otherwise, you will need a project with 'Project Administrator' role assigned to you.
  
[How to create a new project](https://learn.microsoft.com/en-us/azure/devops/organizations/projects/create-project?view=azure-devops&tabs=browser#create-a-project)

> **Project naming best practice** - 
> Don't include your phase name like "CRM System *Phase 1*" as AzDO projects should live long-term.

[How to assign the project administrator role for an existing project](https://learn.microsoft.com/en-us/azure/devops/user-guide/project-admin-tutorial?toc=%2Fazure%2Fdevops%2Forganizations%2Ftoc.json&view=azure-devops#add-members-to-the-project-administrators-group)

### 3) Entra ID Applications for each environment

> ** Application best practice**
> Use a separate application for each environment (or at least NONPROD and PROD) to keep proper separation between environments.
> Since there's no cost to these applications, there isn't a big overhead of doing this.

## Running Setup

The easiest way to run setup is:

1) Open "Windows PowerShell" from the start menu (every Windows computer has this installed)

2) Paste this in and hit enter.

   ```powershell
   iwr https://github.com/ALM4Dataverse/ALM4Dataverse/releases/latest/download/setup.ps1 | iex
   ```

   > If you would like to review the script first (good practice) you can download the script and save it from https://github.com/ALM4Dataverse/ALM4Dataverse/releases/latest/download/setup.ps1

3) Follow the instructions.

## What Setup Does

1) Prompts you to authenticate. The account you select will be used when connecting to AzDO and Dataverse environments during setup. 
2) Ensures the required Power Platform AzDO Extension is installed in the target AzDO.
   If you have the required level of access it will be enabled automatically.
3) Prompts you to select an existing AzDO project, or create a new one.
   If you select the option to create a new one, you will be prompted for the name and process template.
4) Imports or updates the shared `ALM4Dataverse` repo.
5) Prompts you to select the Git repo in the AzDO project or create a new one and creates the required pipelines files and registrations.
6) Prompts you to select a Dataverse environment to be used as the main development environment and creates the required variable groups and service connections.
7) Prompts you to select the solutions to be managed in dependency order and edits the `alm-config.psd1` file
8) Prompts you to select Dataverse environments to be used as the deployment targets (your test and prod environment) and creates the required variable groups and service connections.
9) For both the dev environment and all deployment environments prompts you to select the Entra ID application (service principal) you want to use, with an option to create automatically.
10) For each selected service principal, prompts you to choose the authentication type:
    - **Service Principal with Secret**: Traditional approach using client secrets
    - **Workload Identity Federation**: Modern approach using federated credentials (no secrets required)
11) For both the dev environment and all deployment environments prompts you to select the Service Account (user account) you want to use. This must be pre-existing as no option to create it is given.
