# Azure DevOps Automated Setup

Automated setup is the recommended route: a guided interactive script that creates or
selects the application repository, imports the shared `ALM4Dataverse` repository,
creates the caller pipelines, and configures service connections, variable groups,
environments and approvals. It does not create Dataverse environments or replace your
backup and recovery plan. Both routes generate the caller pipelines automatically from
`alm-config.psd1`; the difference is who creates everything else.

> [!TIP]
> Prefer to create each resource yourself? Use [manual setup](azdo-manual-setup.md). For
> the shortest path to a first deployment, start with the
> [Azure DevOps quickstart](../getting-started/quickstart-azdo.md).

## Before You Start

You need:

- **An Azure DevOps organization** that can run pipelines on Microsoft-hosted agents, and
  a project where you are a Project Administrator, or Project Collection Administrator
  rights so setup can create one. See
  [organization requirements](azdo-organisation-requirements.md).
- **A development Dataverse environment** with the unmanaged solutions you want to
  manage, plus at least one environment to deploy to. All must be in the same Entra ID
  tenant as your setup account and the organization.
- **The unique names of your solutions**, in dependency order.
- **An existing licensed user** in each environment to own and activate flows and other
  processes (the process owner).
- **Permission to create Entra app registrations and Dataverse application users**, or an
  administrator who can complete those steps with you.
- **Windows PowerShell 5.1 or PowerShell 7** on Windows, or PowerShell 7 on Linux with
  Git on `PATH`. Setup downloads its PowerShell modules and, on Windows, temporary Git.
  Azure Cloud Shell includes PowerShell and Git.

> [!NOTE]
> **Optional Dev Container.** The repository includes a
> [Dev Container](../../.devcontainer/devcontainer.json) with PowerShell 7, Git and
> GitHub CLI. It is not a security boundary; setup still acts with the permissions of the
> authenticated accounts. Use least-privilege identities. The container has no browser,
> so sign-in shows a device code to enter at the printed URL in a browser on your machine.

## Run Setup

Download the released script, review it, then run it:

```powershell
Invoke-WebRequest 'https://github.com/ALM4Dataverse/ALM4Dataverse/releases/latest/download/setup-azdo.ps1' -OutFile './setup-azdo.ps1'
.\setup-azdo.ps1
```

If you have already reviewed and trust the release, you can run the one-line bootstrap
instead:

```powershell
iwr https://github.com/ALM4Dataverse/ALM4Dataverse/releases/latest/download/setup-azdo.ps1 | iex
```

To select a tenant or a specific shared-code ref, see
[setup parameters](../config/pipelines.md#setup-script-parameters).

> [!NOTE]
> Released setup scripts embed their helpers. A raw script downloaded from the source
> repository is not equivalent and needs its adjacent files.

### Run in Azure Cloud Shell

Setup can run in [Azure Cloud Shell](https://shell.azure.com). Choose **PowerShell** and
run the one-line bootstrap:

```powershell
iwr https://github.com/ALM4Dataverse/ALM4Dataverse/releases/latest/download/setup-azdo.ps1 | iex
```


## Guided Setup

Setup asks a few questions, then opens a menu. New repositories unlock steps in order; an
existing repository starts from the settings in `alm-config.psd1` and lets you open any
step. After each step you return to the menu. **Preview changes** is optional, and
**Apply changes** stays unavailable until every required step is complete. Press F1 for
the current step's help page; Esc returns to the previous prompt or menu.

![Guided setup menu for a new Azure DevOps repository](./screenshots/azdo-menu-new-repository.png)

![Guided setup menu for an existing Azure DevOps repository with saved branch mappings](./screenshots/azdo-menu-existing-repository.png)

![Guided setup menu when the configured Azure DevOps shared repository is unavailable](./screenshots/azdo-menu-unavailable-shared-repository.png)

### 1. New or existing repository

Choose **Set up a new application repository** to create the repository and its first
branch, or **Configure an existing repository** to use one that already exists. The
choice appears before authentication.

![New or existing repository choice with ALM4Dataverse branding below the setup header](./screenshots/setup-mode-choice.png)

### 2. Sign in and select resources

Setup signs in to Azure DevOps and Azure, then asks for the organization, project and
application repository. You can reuse an existing Azure login. Creating a project or
repository happens immediately.

![Azure DevOps authentication choices](./screenshots/azdo-authentication.png)

![Azure DevOps project selection](./screenshots/azdo-project-selection.png)

![Azure DevOps application repository selection](./screenshots/azdo-main-repository-selection.png)

After you select the repository, setup checks for Power Platform Build Tools and asks
whether to use the ALM4Dataverse extension. Keep it enabled unless you must use Microsoft
tooling only; workload identity federation requires it. See
[service connections](../config/azdo-environment-service-connection.md).

![Azure DevOps extension confirmation with Workload Identity Federation guidance](./screenshots/azdo-extension-mode.png)

### 3. Select the shared repository

The shared `ALM4Dataverse` repository holds the templates your pipelines use. Select an
existing repository in the project or create one; creating it asks for confirmation
because the repository is created before preview.

Setup checks the selected repository automatically when it resolves an existing
repository and again after you select a different shared repository. The
**Define shared repository update strategy** step shows **No action needed** when the
repository already matches, or is ahead of, the ALM4Dataverse ref you are running. If the
check finds an empty repository, a fast-forward, or diverged history, choose the strategy
there. Setup applies the selected strategy immediately so the preview uses the updated
template source. If a check fails, the step shows the reason and lets you retry.

![Azure DevOps shared repository selection and creation confirmation](./screenshots/azdo-shared-repository-selection.png)

![Choosing a shared repository update strategy](./screenshots/azdo-shared-repository-update.png)

To get a pull request for each new upstream release afterwards, enable
[upstream release tracking](../usage/updating.md#track-upstream-releases) in the shared repository.

### 4. Configure branches and environments

**Configure branches, dev and deployment envs** defines each branch, its DEV environment,
its deployment targets and its BUILD validation. Select the row to start. When an existing
repository already has a complete saved branch and environment configuration, the step
starts marked complete and does not need to be visited. The menu lists each branch's DEV
environment, BUILD validation and deployment targets in that order.

1. **Choose a branch strategy.** For a new repository, choose `main only` or
   `main + develop`. Existing repositories start from the mappings in `alm-config.psd1`
   and skip this prompt. This creates branch mappings, not branch policies. See
   [branching strategies](../usage/branching-strategies.md).

   ![Branch strategy menu from Azure DevOps setup](./screenshots/branch-strategy.png)

2. **Add or edit branch mappings.** Choose **Add a branch mapping** or **Edit a branch
   mapping**. Branch names must be unique.

   ![Prompt for a new branch name](./screenshots/branch-name.png)

3. **Configure the DEV environment.** A branch without one shows **DEV: Not configured**.
   Select it (or **Edit DEV environment**) to open the DEV detail menu, then select **DEV
   environment** to enable it. The remaining steps stay unavailable until it is enabled;
   choose **Do not configure DEV environment** to leave it unconfigured. Enable it to
   select the Dataverse environment; setup names it `Dev-<branch>`. Only branches with a
   DEV environment can be a solution source.

   ![Azure DevOps DEV environment detail menu with the enable step](./screenshots/azdo-dev-menu.png)

   ![Azure DevOps DEV environment selection](./screenshots/azdo-dev-environment-selection.png)

4. **Choose credentials and the process owner.** The environment detail menu asks for the
   Dataverse environment, its credential and the service account. Setup can create an
   Entra app and service connection, reuse existing ones, or let you enter connection
   details. Prefer **Workload Identity Federation**; it needs no client secret. The
   service account is the licensed user that owns processes, not the application
   identity. Setup checks the format of a manually entered UPN but does not verify its
   licensing or roles. Rotating an existing client secret is deferred until you choose
   **Apply changes**. Setup first checks your Entra ID permissions; actions your
   signed-in account cannot perform, such as creating an app registration or adding a
   federated credential, are dimmed and cannot be selected. See
   [app registration permissions](../config/azdo-environment-service-connection.md#app-registration-permissions).

   When you enter an existing application ID, setup checks that it exists, has the
   Dataverse `user_impersonation` permission, has an enterprise application and has a
   usable client secret or federated credential. For WIF, it also requires the exact
   federated credential issuer and subject when the service connection is available.
   Problems are
   shown with **Continue with this application**, **Recheck application setup** and
   **Enter a different application ID** options, and the next
   authentication menu offers only the methods configured on the app. **Create a new
   application manually (with instructions)** shows the Entra portal steps, including the
   `user_impersonation` scope and manual WIF credential steps, and then validates the ID
   you enter. WIF and client secret are alternatives; WIF is recommended.
   **Search for an existing application by name** searches this tenant by display-name
   prefix when your account can list applications. Reusing an existing service connection
   does not change its Entra application.

   ![Azure DevOps credential choices](./screenshots/azdo-credentials.png)

   ![Azure DevOps manual application creation instructions](./screenshots/azdo-manual-instructions.png)

   The WIF issuer and subject must be copied exactly from the service connection that
   setup creates. Do not substitute an example or a subject from another organization,
   project or connection.

   Setup explains each validation problem and offers **Continue**, **Recheck**, or
   **Enter a different application ID**. The validation dialog is shared by both setup
   providers.

   | Validation problem | What setup reports |
   | --- | --- |
   | Application not found | ![Validation: application not found](./screenshots/validation-application-not-found.png) |
   | Dataverse user_impersonation permission missing | ![Validation: Dataverse permission missing](./screenshots/validation-missing-dataverse-permission.png) |
   | Enterprise application missing | ![Validation: enterprise application missing](./screenshots/validation-missing-enterprise-app.png) |
   | No usable client secret or federated credential | ![Validation: no usable credential](./screenshots/validation-missing-credentials.png) |
   | Client secret expired | ![Validation: expired client secret](./screenshots/validation-expired-secret.png) |
   | Federated credential uses the wrong issuer or audience | ![Validation: wrong federated credential](./screenshots/azdo-validation-wrong-federated-credential.png) |
   | Federated credential uses the wrong subject | ![Validation: wrong federated subject](./screenshots/azdo-validation-wrong-federated-subject.png) |
   | Validation could not complete | ![Validation: check failed](./screenshots/validation-check-failed.png) |

   ![Azure DevOps authentication type choices](./screenshots/azdo-authentication-type.png)

   ![Azure DevOps service-account choices](./screenshots/azdo-service-account.png)

5. **Add deployment targets.** Choose **Add an environment**, then complete the Dataverse
   environment, short name (`TEST`, `UAT`, `PROD`), credentials and service account. Add
   targets in promotion order; the list order becomes the deployment stage order. A
   branch can have no deployment targets.

   ![Per-environment detail menu with completed prerequisites and the service-account step ready to configure](./screenshots/environment-detail-menu.png)

   ![Azure DevOps deployment environment selection](./screenshots/azdo-deployment-environment-selection.png)

   ![Prompt for an Azure DevOps deployment environment short name](./screenshots/azdo-deployment-short-name.png)

   ![Azure DevOps deployment environment plan](./screenshots/azdo-deployment-environment-plan.png)

6. **Enable BUILD validation (optional).** Choose a non-production Dataverse environment
   to receive each build, then its connection, credentials, service account and optional
   baseline. Leave it off for now if you are still setting up; you can enable it later.
   See [BUILD validation](../usage/building-releases.md#build-validation).

   ![Azure DevOps BUILD validation environment selection for a branch](./screenshots/azdo-build-validation.png)

7. **Review the branch map.** Check the table, then choose **Done**. Reopen a branch to
   change its DEV environment, deployment targets or BUILD validation.

   ![Azure DevOps branch-to-environment mapping table](./screenshots/branch-mapping.png)

### 5. Configure solutions

Choose a branch with a DEV environment as the discovery source, then select and order the
solutions. The summary shows them in dependency order. See
[solutions configuration](../config/alm-config.md#solutions).

![Selecting and ordering managed solutions](./screenshots/solutions-configuration.png)

### 6. Preview and apply

**Preview changes** shows the generated files, the `alm-config.psd1` diff and the
external operations that Apply will perform: pipelines and permissions, service
connections and federated credentials, variable groups and checks, environments,
application users and process owners. It leaves the repository and the target
environments unchanged. Operations already completed during setup are marked
**Already applied**.

![Azure DevOps setup change summary and review menu](./screenshots/azdo-setup-change-review.png)

![Scrollable colored side-by-side setup diff](./screenshots/setup-change-side-by-side-diff.png)

When the menu shows **Apply changes** as ready, select it to publish the files and apply
the listed operations. You do not have to preview first.

![Guided setup menu with Apply changes ready](./screenshots/azdo-apply-changes.png)

If Apply fails, setup keeps your selections so you can correct the problem and retry.
Operations that already succeeded are not rolled back.

## Apply A Committed Config

If `alm-config.psd1` is reviewed and committed on the default branch, regenerate the
pipeline files without the settings editors:

```powershell
.\setup-azdo.ps1 -ApplyConfig
```

This mode selects existing resources and reads the shared repository, ref, provider
options and branch mappings from the committed config. It does not create repositories,
install extensions, provision Azure DevOps resources, or offer the branch, environment,
solution, BUILD validation and OIDC editors. To change those settings, edit and commit
`alm-config.psd1`, then run the command again. Add `-PreviewOnly` to inspect the diffs
without publishing:

```powershell
.\setup-azdo.ps1 -ApplyConfig -PreviewOnly
```

See
[setup metadata and branch environments](../config/alm-config.md#setup-metadata-and-branch-environments).

Applying publishes through a pull request. The pipeline pushes an `apply-config` branch and
opens a pull request into the default branch as the project's Build Service identity. Guided
setup grants that identity Contribute, Create branch and Contribute to pull requests on the
application repository. `-ApplyConfig` does not change permissions, so a project set up
before this change needs one guided setup run (`setup-azdo.ps1` without `-ApplyConfig`). If
the pull request cannot be created, the pipeline fails after pushing the branch and publishes
the generated files as the `apply-config-files` pipeline artifact.

## After Setup

1. Review the generated files, then commit them or merge the pull requests setup created.
2. Add target values that setup cannot infer: connection references, environment-variable
   values and custom secrets. See
   [variable groups](../config/azdo-environment-variable-group.md).
3. Add the right people to each `<environment> deployment approvers` team; setup creates
   the teams with only you in them.
4. Run [EXPORT](../usage/exporting-changes.md), check
   [BUILD](../usage/building-releases.md), then deploy that build to a non-production
   target.
5. Configure branch policies or PR build validation separately; setup does not create
   them.

## Re-Running Setup

Re-run setup to add environments or branches. Setup keeps some files and settings and
replaces others; see
[re-running setup](../usage/updating.md#re-run-setup-carefully).

> [!CAUTION]
> Do not run two setups against the same repository at once. If setup fails partway,
> inspect resources already created before retrying; changes are not automatically rolled
> back.

## Limitations

- The setup account, the Azure DevOps organization and all Dataverse environments must be
  in the same Entra ID tenant.
- Only the commercial `Azure Cloud` is supported; sovereign clouds are not.
- Generated pipelines use Microsoft-hosted `windows-2022` agents. Self-hosted agents
  require manual template changes.
- Entra apps created by setup are named `<project> - <environment> deployment`; you can
  rename them later.
