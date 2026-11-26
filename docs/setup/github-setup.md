# GitHub Automated Setup

Automated setup is the recommended GitHub Actions route (PREVIEW): one guided script that
creates or selects the application repository, configures GitHub environments, variables,
secrets and OIDC settings, and generates the caller workflows from `alm-config.psd1`. It
does not create Dataverse environments. Both routes generate the caller workflows
automatically from `alm-config.psd1`; the difference is who creates everything else.

For Azure DevOps, use the [Azure DevOps automated setup guide](azdo-automated-setup.md).
To create the GitHub and Dataverse resources yourself, use
[manual setup](github-manual-setup.md). For the shortest path to a first deployment, start
with the [GitHub quickstart](../getting-started/quickstart-github.md).

## Before You Start

- **A GitHub repository** with Actions enabled and permission to configure its workflows,
  variables, secrets and environments. Use a public repository, or a private one on a plan
  with environments; see
  [plan limitations](github-manual-setup.md#github-licence-limitations).
- **Development and deployment Dataverse environments**, with permission to create and
  manage application users.
- **An Entra app registration for each target**, or permission to create one and configure
  its authentication.
- **An existing licensed user** in each environment to own and activate flows and other
  processes.
- **For automated setup:** Windows PowerShell 5.1 or PowerShell 7 on Windows, Git, and
  network access to GitHub and the required Microsoft services. Setup downloads a
  temporary GitHub CLI when `gh` is missing.

> [!NOTE]
> **Optional Dev Container.** The repository includes a
> [Dev Container](../../.devcontainer/devcontainer.json) with PowerShell 7, Git and
> GitHub CLI. It is not a security boundary; setup still acts with the permissions of the
> authenticated accounts. Use least-privilege identities. The container has no browser,
> so sign-in shows a device code to enter at the printed URL in a browser on your machine.

> [!CAUTION]
> Use separate application identities for production and non-production. The application
> user authenticates automation; the service-account user owns and activates processes.
> They are not interchangeable. The standard setup assigns the application user the
> Dataverse System Administrator role. Treat workflow and hook changes as privileged code
> changes.

## Automated Setup

Download the released script, review it, then run it:

```powershell
Invoke-WebRequest 'https://github.com/ALM4Dataverse/ALM4Dataverse/releases/latest/download/setup-github.ps1' -OutFile './setup-github.ps1'
.\setup-github.ps1
```

If you have already reviewed and trust the release, you can run the one-line bootstrap
instead:

```powershell
iwr https://github.com/ALM4Dataverse/ALM4Dataverse/releases/latest/download/setup-github.ps1 | iex
```

To select a tenant or a specific shared-code ref, see
[setup parameters](../config/pipelines.md#setup-script-parameters).

> [!NOTE]
> Released setup scripts embed their helpers. A raw script downloaded from the source
> repository is not equivalent and needs its adjacent files.

### Guided Setup

Setup asks a few questions, then opens a menu. New repositories unlock steps in order; an
existing repository starts from the settings in `alm-config.psd1` and lets you open any
step. After each step you return to the menu. **Preview changes** is optional, and
**Apply changes** stays unavailable until every required step is complete.

![Guided setup menu for a new GitHub repository](./screenshots/github-menu-new-repository.png)

![Guided setup menu for an existing GitHub repository with saved branch mappings](./screenshots/github-menu-existing-repository.png)

![Guided setup menu when the configured shared workflow repository is inaccessible](./screenshots/github-menu-unavailable-shared-repository.png)

#### 1. New or existing repository

Choose **Set up a new application repository** to create the repository and its first
branch, or **Configure an existing repository** to use one that already exists. An
existing repository can be empty; setup creates its initial branch and commit when it
publishes files. The choice appears before authentication.

![New or existing repository choice with ALM4Dataverse branding below the setup header](./screenshots/setup-mode-choice.png)

#### 2. Sign in and select the application repository

Setup signs in to GitHub and Azure, then asks for the application repository. Existing
repository choices include repositories you own, repositories in your organizations, and
repositories shared with you as a collaborator.

![GitHub authentication choices](./screenshots/github-authentication.png)

![Selecting the GitHub application repository](./screenshots/github-application-repository.png)

#### 3. Select the shared workflow repository

The shared workflow repository contains the composite actions and reusable workflows.
Select an existing fork or private repository, or create one; creating it asks for
confirmation because it is created before preview. When creating, setup asks for the owner
and defaults to the owner of the application repository.

Setup checks the selected repository automatically when it resolves an existing
repository and again after you select a different shared repository. The
**Define shared repository update strategy** step shows **No action needed** when the
repository already matches, or is ahead of, the ALM4Dataverse ref you are running. If the
check finds a fast-forward, an alignment, or diverged history, choose the strategy there;
setup records it and performs the update only when you choose **Apply changes**. Apply
uses the selected strategy without prompting again. If a check fails, the step shows the
reason and lets you retry.

![Selecting or creating the shared workflow repository](./screenshots/github-shared-workflow-repository.png)

![Choosing a shared workflow repository update strategy](./screenshots/github-shared-repository-update.png)

#### 4. Configure branches and environments

**Configure branches, dev and deployment envs** defines each branch, its DEV environment,
its deployment targets and its BUILD validation. Select the row to start. When an existing
repository already has a complete saved branch and environment configuration, the step
starts marked complete and does not need to be visited. The menu lists each branch's DEV
environment, BUILD validation and deployment targets in that order.

1. **Choose a branch strategy.** For a new repository, choose `main only` or
   `main + develop`. Existing repositories start from the mappings in `alm-config.psd1`
   and skip this prompt. This creates branch mappings, not branch protection. See
   [branching strategies](../usage/branching-strategies.md).

   ![Branch strategy menu from GitHub setup](./screenshots/branch-strategy.png)

2. **Add or edit branch mappings.** Choose **Add a branch mapping** or **Edit a branch
   mapping**. Branch names must be unique.

   ![Prompt for a new branch name](./screenshots/branch-name.png)

3. **Configure the DEV environment.** A branch without one shows **DEV: Not configured**.
   Select it (or **Edit DEV environment**) to open the DEV detail menu, then select **DEV
   environment** to enable it. The remaining steps stay unavailable until it is enabled;
   choose **Do not configure DEV environment** to leave it unconfigured. Enable it to
   select the Dataverse environment; setup names it `Dev-<branch>`. Only branches with a
   DEV environment can be a solution source.

   ![GitHub DEV environment detail menu with the enable step](./screenshots/github-dev-menu.png)

   ![GitHub DEV environment selection](./screenshots/github-dev-environment-selection.png)

4. **Choose credentials and the process owner.** The environment detail menu asks for the
   Dataverse environment, its credential and the service account. Setup can create an App
   Registration, reuse an existing one, or let you enter existing details. A new
   registration asks whether to use workload identity federation or a client secret. If
   you choose a client secret, store it as a GitHub secret; never put it in
   `alm-config.psd1` or source control. Rotating an existing secret is deferred until you
   choose **Apply changes**.

   ![GitHub credential choices](./screenshots/github-credentials.png)

   ![GitHub authentication type choices](./screenshots/github-authentication-type.png)

   ![GitHub service-account choices](./screenshots/github-service-account.png)

   The service account is the licensed user that owns processes, not the application
   identity. Setup checks the format of a manually entered UPN but does not verify its
   licensing or roles.

5. **Add deployment targets.** Choose **Add an environment**, then complete the Dataverse
   environment, short name (`TEST`, `UAT`, `PROD`), credentials and service account. Add
   targets in promotion order; the list order becomes the deployment stage order. A
   branch can have no deployment targets.

   ![Per-environment detail menu with completed prerequisites and the service-account step ready to configure](./screenshots/environment-detail-menu.png)

   ![GitHub deployment environment selection](./screenshots/github-deployment-environment-selection.png)

   ![Prompt for a deployment environment short name](./screenshots/deployment-short-name.png)

   ![GitHub deployment environment plan](./screenshots/deployment-environment-plan.png)

6. **Enable BUILD validation (optional).** Choose a non-production Dataverse environment
   to receive each build, then its GitHub environment name, credentials, service account
   and optional baseline. Leave it off for now if you are still setting up; you can enable
   it later. See
   [BUILD validation](github-manual-setup.md#build-validation-and-pull-requests).

   ![GitHub BUILD validation environment selection for a branch](./screenshots/github-build-validation.png)

7. **Review the branch map.** Check the table, then choose **Done**. Reopen a branch to
   change its DEV environment, deployment targets or BUILD validation.

   ![GitHub branch-to-environment mapping table](./screenshots/branch-mapping.png)

#### 5. Configure solutions

Choose a branch with a DEV environment as the discovery source, then select and order the
solutions. The summary shows them in dependency order. See
[solutions configuration](../config/alm-config.md#solutions).

![Selecting and ordering managed solutions](./screenshots/solutions-configuration.png)

#### 6. Configure GitHub OIDC identity

When a selected credential uses workload identity federation and immutable subjects are
not already enabled, setup asks whether to enable them for the repository. The setting is
changed during Apply. Review other applications that trust the repository before changing
this repository-wide setting.

![GitHub OIDC immutable-subject confirmation](./screenshots/github-oidc-identity.png)

#### 7. Preview and apply

**Preview changes** shows the generated files, the `alm-config.psd1` diff and the external
operations that Apply will perform: repository OIDC settings, environment variables,
secrets and approvals, federated credentials, application users and process owners. It
leaves the repository and the target environments unchanged. Operations already completed
during setup are marked **Already applied**.

![GitHub setup change summary and review menu](./screenshots/github-setup-change-review.png)

![Scrollable colored side-by-side setup diff](./screenshots/setup-change-side-by-side-diff.png)

When the menu shows **Apply changes** as ready, select it to publish the files and apply
the listed settings. You do not have to preview first. If Apply fails, setup keeps your
selections so you can correct the problem and retry. Operations that already succeeded are
not rolled back.

![Guided setup menu with Apply changes ready](./screenshots/github-apply-changes.png)

### Apply A Committed Config

If `alm-config.psd1` is reviewed and committed on the default branch, regenerate the
workflows without the settings editors:

```powershell
.\setup-github.ps1 -ApplyConfig
```

This mode selects an existing repository and reads the provider, repository, ref, provider
options and branch mappings from the committed config. It does not create repositories,
configure GitHub environments, secrets, OIDC subjects or approvals, or offer the branch,
environment, solution, BUILD validation and OIDC editors. To change those settings, edit
and commit `alm-config.psd1`, then run the command again. Add `-PreviewOnly` to inspect the
diffs without publishing:

```powershell
.\setup-github.ps1 -ApplyConfig -PreviewOnly
```

See
[setup metadata and branch environments](../config/alm-config.md#setup-metadata-and-branch-environments).

> [!IMPORTANT]
> GitHub does not let the built-in Actions token create or update files under
> `.github/workflows/`. The APPLY-CONFIG **workflow** therefore opens a pull request that
> puts the regenerated workflow files in `replace-github-workflows/`. Merge it, replace
> `.github/workflows` with that folder, and commit; BUILD fails until you do. Guided setup
> enables **Allow GitHub Actions to create and approve pull requests** so the workflow can
> open the pull request. Preview runs never change anything. Running `-ApplyConfig -Commit`
> on a workstation uses your own sign-in and opens a pull request the same way. See
> [apply configuration](../config/github-secrets.md#apply-configuration).

## Manual Setup

To create the repository settings, environments and credentials yourself, use
[manual setup](github-manual-setup.md).

## After Setup

1. Review the generated files, then commit them or merge the pull requests setup created.
2. Run EXPORT from the intended development branch with a meaningful commit message.
3. Review the exported `solutions/<unique-name>` files and any data changes.
4. Check the resulting BUILD and its Release. A build before the first export may fail
   because solution source is not present yet.
5. Deploy that exact build to the first non-production target and verify process activation
   and application behavior.
6. Promote the same build through the remaining configured targets.

Continue with [exporting](../usage/exporting-changes.md),
[building](../usage/building-releases.md), [deploying](../usage/deploying.md), or
[importing](../usage/importing-changes.md).

## Re-Running Setup

Re-running setup can update generated files. Existing `secrets-json` mappings, `AGENTS.md`
and files under `data/` are preserved. Review the resulting diff; other workflow
customizations can be overwritten. See
[re-running setup](../usage/updating.md#re-run-setup-carefully). GitHub cannot reveal
existing secret values, so map relocated secrets explicitly.
