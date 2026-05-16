# Manual Setup Guide

This guide describes how to manually set up ALM4Dataverse using the Azure DevOps, Power Platform Admin Center and Entra ID user interfaces, without using the automated setup script.

> **Note:** For automated setup, use the `setup.ps1` script instead. This manual guide is for users who prefer or require manual configuration.

## Prerequisites

- Access to an Azure DevOps organization with the proper setup (see [Azure DevOps Organisation Requirements](azdo-organisation-requirements.md))
- Project Administrator or Organization Owner permissions
- Access to your Dataverse environments with System Administrator role
- Ability to create App Registrations in Entra ID (Azure Active Directory)

## Overview

The manual setup process involves:

1. [Azure DevOps Project Setup](#1-azure-devops-project-setup)
2. [Power Platform Build Tools Installation](#2-install-power-platform-build-tools)
3. [Repository Setup](#3-repository-setup)
4. [Service Principal Setup](#4-service-principal-setup)
5. [Service Connections](#5-service-connections)
6. [Variable Groups](#6-variable-groups)
7. [Environments and Approvals](#7-environments-and-approvals)
8. [Pipeline Creation](#8-pipeline-creation)
9. [Pipeline Permissions](#9-pipeline-permissions)
10. [Solution Configuration](#10-solution-configuration)

---

## 1. Azure DevOps Project Setup

### Create or Select Project

1. Navigate to your Azure DevOps organization: `https://dev.azure.com/{organization}`
2. Either:
   - **Create a new project**: Click "New Project", enter a name, select visibility (Private recommended), and choose a process template (Agile recommended)
   - **Select an existing project**: Navigate to the project where you want to set up ALM4Dataverse

📖 **Reference**: [Create a project in Azure DevOps](https://learn.microsoft.com/en-us/azure/devops/organizations/projects/create-project)

---

## 2. Repository Setup

You need two Git repositories in your project:

### 2.1 Shared Repository (ALM4Dataverse)

This repository contains the shared pipeline templates and scripts.

1. Go to **Repos** > **Files**
2. Create a new repository named `ALM4Dataverse` (initialize as empty - do not import)
3. Copy the clone URL from Azure DevOps (click "Clone" button in the top right)
4. Clone the repository and set it up with the stable release:
   ```bash
   # Clone your newly created empty repository
   # Replace YOUR_CLONE_URL with the URL you copied from Azure DevOps
   git clone YOUR_CLONE_URL
   cd ALM4Dataverse
   
   # Add the upstream repository as a remote
   git remote add upstream https://github.com/rnwood/ALM4Dataverse.git
   
   # Fetch only the stable tag from upstream (no other branches are imported)
   git fetch upstream refs/tags/stable:refs/tags/stable
   
   # Create main branch from the stable tag
   git checkout -b main stable
   
   # Push to your Azure DevOps repository
   git push origin main
   ```

> **Note**: The 'stable' tag always points to the latest stable release. You can also pin to a specific version tag (e.g., `v1.0.0`) by replacing `stable` with the version tag in the fetch and checkout commands (e.g., `git fetch upstream refs/tags/v1.0.0:refs/tags/v1.0.0` and `git checkout -b main v1.0.0`). Find available releases at https://github.com/rnwood/ALM4Dataverse/releases

📖 **Reference**: [Create a Git repo](https://learn.microsoft.com/en-us/azure/devops/repos/git/create-new-repo)

### 2.2 Main Repository (Your Application)

This is your application repository that will contain your solution source code and pipeline definitions.

1. Create a new repository (or use an existing one) for your application
2. Clone the repository locally
3. Copy all contents of the `copy-to-your-repo` folder from this project into your repository root, including:
   - `alm-config.psd1` - Configuration file for solutions
   - `data/` - Data export/import scripts
   - `pipelines/` - Pipeline YAML files

4. Update `pipelines/DEPLOY-main.yml`:
   - If your default branch is not `main`, rename the file to `DEPLOY-{branch}.yml`
   - Update the trigger branch if needed
   - Update the `source` parameter from `source: 'BUILD'` to `source: '{RepositoryName}\BUILD'`

5. Commit and push the changes

📖 **Reference**: [Clone a repository](https://learn.microsoft.com/en-us/azure/devops/repos/git/clone)

### 2.3 Grant Build Service Permissions

The Build Service needs Contribute permissions on your main repository to push changes.

1. Go to **Project Settings** > **Repositories**
2. Select your main repository
3. Go to the **Security** tab
4. Find the Build Service identity: `{ProjectName} Build Service ({OrganizationName})`
5. Set the following permissions:
   - **Contribute**: Allow
   - Ensure no Deny overrides exist

📖 **Reference**: [Set repository permissions](https://learn.microsoft.com/en-us/azure/devops/repos/git/set-git-repository-permissions)

---

## 3. Service Principal Setup

For each Dataverse environment (Dev, Test, UAT, Production, etc.), you need a Service Principal (App Registration) for authentication.

> **Authentication Methods**: You can choose between two authentication approaches:
> - **Service Principal with Client Secret (traditional)**: Simpler setup but requires managing and rotating secrets
> - **Workload Identity Federation (recommended)**: More secure, no secrets to manage, uses OpenID Connect
>
> This guide covers both methods. Choose the approach that best fits your organization's security policies.

### 3.1 Create App Registration in Entra ID

1. Navigate to the [Azure Portal](https://portal.azure.com)
2. Go to **Entra ID** (Azure Active Directory) > **App registrations**
3. Click **New registration**
4. Enter a name: `{ProjectName} - {EnvironmentName} - deployment` (e.g., "MyProject - PROD - deployment")
5. Select "Accounts in this organizational directory only"
6. Click **Register**
7. Note the **Application (client) ID** and **Directory (tenant) ID**

### 3.2 Configure Authentication

#### Option A: Client Secret (Traditional)

1. In the App Registration, go to **Certificates & secrets**
2. Click **New client secret**
3. Add a description: "ALM4Dataverse"
4. Select an expiration period (note when it expires for renewal)
5. Click **Add**
6. **Important**: Copy the secret **Value** immediately (not the Secret ID) - you cannot view it again

📖 **Reference**: [Add a client secret](https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-register-app#add-a-client-secret)

#### Option B: Workload Identity Federation (Recommended)

1. In the App Registration, go to **Certificates & secrets**
2. Go to the **Federated credentials** tab
3. Click **Add credential**
4. Select **Other issuer**
5. Fill in the details:
   - **Issuer**: Use the value shown by AzDO once you have created the SC.
   - **Subject identifier**: Use the value shown by AzDO once you have created the SC.
   - **Name**: `AzDO-{organizationName}-{projectName}-{serviceConnectionName}` (alphanumeric and hyphens only)
   - **Audience**: `api://AzureADTokenExchange`
6. Click **Add**

📖 **References**: 
- [Workload Identity Federation](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation)
- [Configure a federated identity credential](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-create-trust)

### 3.3 Create Application User in Dataverse

For each Dataverse environment, create an application user with the Service Principal:

1. Navigate to the Power Platform Admin Center: https://admin.powerplatform.microsoft.com
2. Select your environment
3. Go to **Settings** > **Users + permissions** > **Application users**
4. Click **New app user**
5. Click **Add an app**
6. Search for and select your App Registration
7. Select the **Business Unit** (typically root)
8. Add the **System Administrator** security role
9. Click **Create**

📖 **Reference**: [Create an application user](https://learn.microsoft.com/en-us/power-platform/admin/manage-application-users)

> **Security Note**: The System Administrator role provides full access. Consider using more restrictive custom security roles for production environments if appropriate.

---

## 4. Service Connections

Create a Service Connection for each Dataverse environment.

### For Each Environment (Dev-main, TEST-main, UAT-main, PROD, etc.):

#### Using Client Secret Authentication:

1. Go to **Project Settings** > **Service connections**
2. Click **New service connection**
3. Select **Power Platform**
4. Choose **Application Id and client secret** authentication
5. Fill in the details:
   - **Server URL**: Your Dataverse environment URL (e.g., `https://yourorg.crm.dynamics.com`)
   - **Tenant Id**: The Directory (tenant) ID from your App Registration
   - **Application Id**: The Application (client) ID from your App Registration
   - **Client Secret**: The client secret value you saved earlier
   - **Service connection name**: Use the pattern `{EnvironmentName}-main` (e.g., `Dev-main`, `PROD`)
6. **Do not** check "Grant access permission to all pipelines" - we'll configure specific permissions later
7. Click **Save**

#### Using Workload Identity Federation:

1. Go to **Project Settings** > **Service connections**
2. Click **New service connection**
3. Select **Power Platform**
4. Choose **Workload Identity federation (automatic)** authentication
5. Fill in the details:
   - **Server URL**: Your Dataverse environment URL (e.g., `https://yourorg.crm.dynamics.com`)
   - **Tenant Id**: The Directory (tenant) ID from your App Registration
   - **Application (client) Id**: The Application (client) ID from your App Registration
   - **Service Principal Id**: The Application (client) ID (same as above)
   - **Service connection name**: Use the pattern `{EnvironmentName}-main` (e.g., `Dev-main`, `PROD`)
     - **Important**: This must match the `{serviceConnectionName}` you used when creating the federated credential
6. **Do not** check "Grant access permission to all pipelines" - we'll configure specific permissions later
7. Click **Save**

> **Note**: When using WIF, ensure the federated credential in your App Registration matches the subject identifier pattern `sc://{organizationName}/{projectName}/{serviceConnectionName}`

📖 **References**: 
- [Power Platform service connections with client secret](https://learn.microsoft.com/en-us/power-platform/alm/devops-build-tools#configure-service-connections-using-a-service-principal)
- [Workload Identity Federation for Azure DevOps](https://learn.microsoft.com/en-us/azure/devops/pipelines/library/connect-to-azure#workload-identity-federation)

---

## 5. Variable Groups

Variable groups store environment-specific configuration values. See the [Environment Variable Group documentation](../config/environment-variable-group.md) for detailed information about what variables to configure.

### For Each Environment (Dev-main, TEST-main, UAT-main, PROD, etc.):

1. Go to **Pipelines** > **Library**
2. Click **+ Variable group**
3. Name: `Environment-{EnvironmentName}` (e.g., `Environment-Dev-main`, `Environment-PROD`)
4. Add the required variables (see [environment-variable-group.md](../config/environment-variable-group.md) for the full list)
5. Click **Save**

### Add Approval Check (for non-Dev environments):

1. In the Variable Group, click the **⋮** (more options) menu
2. Select **Approvals and checks**
3. Click **+** to add a check
4. Select **Approvals**
5. Add the approvers/approver group (create a team like "{EnvironmentName} deployment approvers" and add appropriate users)
6. Click **Create**

### Add Exclusive Lock Check (for all environments):

1. In the Variable Group, click **Approvals and checks** again
2. Click **+**
3. Select **Exclusive lock**
4. This ensures only one deployment runs at a time for this environment
5. Click **Create**

📖 **References**: 
- [Create and use variable groups](https://learn.microsoft.com/en-us/azure/devops/pipelines/library/variable-groups)
- [Approvals and checks](https://learn.microsoft.com/en-us/azure/devops/pipelines/process/approvals)

---

## 6. Environments and Approvals

For deployment environments (not Dev), create Azure DevOps environments with approval checks.

### For Each Deployment Environment (TEST-main, UAT-main, PROD, etc.):

1. Go to **Pipelines** > **Environments**
2. Click **New environment**
3. Name: `{EnvironmentName}` (e.g., `TEST-main`, `PROD`)
4. Resource: Select **None**
5. Click **Create**
6. In the environment, click the **⋮** menu > **Approvals and checks**
7. Add approval checks as needed (similar to variable groups)

📖 **Reference**: [Create and target an environment](https://learn.microsoft.com/en-us/azure/devops/pipelines/process/environments)

> **Note**: You can also create teams for approvers:
> 1. Go to **Project Settings** > **Teams**
> 2. Click **New team**
> 3. Name: `{EnvironmentName} deployment approvers`
> 4. Add team members who should approve deployments

---

## 7. Pipeline Creation

Create four pipelines for your main repository.

### 7.1 BUILD Pipeline

1. Go to **Pipelines** > **Pipelines**
2. Click **New pipeline**
3. Select **Azure Repos Git**
4. Select your main repository
5. Choose **Existing Azure Pipelines YAML file**
6. Select the branch (e.g., `main`)
7. Path: `/pipelines/BUILD.yml`
8. Click **Continue**, then **Save** (don't run yet)
9. Rename the pipeline to `BUILD`
10. Move to folder: `\{MainRepositoryName}\BUILD`

### 7.2 EXPORT Pipeline

1. Repeat the same steps as BUILD
2. Path: `/pipelines/EXPORT.yml`
3. Rename to `EXPORT`
4. Move to folder: `\{MainRepositoryName}\EXPORT`

### 7.3 IMPORT Pipeline

1. Repeat the same steps
2. Path: `/pipelines/IMPORT.yml`
3. Rename to `IMPORT`
4. Move to folder: `\{MainRepositoryName}\IMPORT`

### 7.4 DEPLOY Pipeline

1. Repeat the same steps
2. Path: `/pipelines/DEPLOY-main.yml` (or your branch name)
3. Rename to `DEPLOY-main` (or your branch name)
4. Move to folder: `\{MainRepositoryName}\DEPLOY-main`

📖 **Reference**: [Create your first pipeline](https://learn.microsoft.com/en-us/azure/devops/pipelines/create-first-pipeline)

---

## 8. Pipeline Permissions

Each pipeline needs permissions to access repositories, service connections, variable groups, and environments.

### Grant Repository Access

For each pipeline (BUILD, EXPORT, IMPORT, DEPLOY):

1. Go to **Project Settings** > **Repositories**
2. Select your **main repository**
3. Go to **Security** tab
4. Click **+** to add a user/group
5. Search for the pipeline: Search for the pipeline build service identity
6. Grant **Use** permission (if using repository resources)

Repeat for the **ALM4Dataverse** repository.

Alternatively, you can configure repository permissions in the pipeline settings:
1. Edit the pipeline
2. Click **⋮** > **Settings**
3. Under **Processing of YAML files from specific repositories**, grant access

### Grant Service Connection Access

For **EXPORT** pipeline:
1. Go to **Project Settings** > **Service connections**
2. Select the `Dev-main` service connection
3. Click **⋮** > **Security**
4. Add the EXPORT pipeline and grant access

For **DEPLOY** pipeline:
1. Repeat for each deployment environment service connection (TEST-main, UAT-main, PROD, etc.)

### Grant Variable Group Access

For **EXPORT** pipeline:
1. Go to **Pipelines** > **Library**
2. Select the `Environment-Dev-main` variable group
3. Go to **Pipeline permissions** tab
4. Click **+** and add the EXPORT pipeline

For **DEPLOY** pipeline:
1. Repeat for each deployment environment variable group

### Grant Environment Access

For **DEPLOY** pipeline:
1. Go to **Pipelines** > **Environments**
2. Select each deployment environment (TEST-main, UAT-main, PROD)
3. Click **⋮** > **Security**
4. Add the DEPLOY pipeline

📖 **Reference**: [Pipeline resources security](https://learn.microsoft.com/en-us/azure/devops/pipelines/security/resources)

---

## 9. Solution Configuration

### 9.1 Configure Solutions in alm-config.psd1

Edit the `alm-config.psd1` file in your main repository to list the solutions you want to manage:

```powershell
@{
    solutions = @(
        @{
            name = 'YourSolutionUniqueName'
            deployUnmanaged = $false
        }
        @{
            name = 'AnotherSolution'
            deployUnmanaged = $false
        }
    )
}
```

- `name`: The unique name of your Dataverse solution
- `deployUnmanaged`: Set to `$true` if you want to deploy as unmanaged (typically only for Dev), `$false` for managed

### 9.2 Configure Deployment Environments

Edit the `pipelines/DEPLOY-main.yml` (or `DEPLOY-{branch}.yml`) file to add your deployment stages:

```yaml
stages:
  - template: pipelines/templates/stages/deploy-environment.yml@ALM4Dataverse
    parameters:
      environmentName: TEST-main

  - template: pipelines/templates/stages/deploy-environment.yml@ALM4Dataverse
    parameters:
      environmentName: UAT-main

  - template: pipelines/templates/stages/deploy-environment.yml@ALM4Dataverse
    parameters:
      environmentName: PROD
```

Add or remove stages based on your environment structure. The environments will deploy in sequence (TEST first, then UAT, then PROD).

### 9.3 Commit and Push

Commit the changes to `alm-config.psd1` and `pipelines/DEPLOY-main.yml` and push to your repository.
