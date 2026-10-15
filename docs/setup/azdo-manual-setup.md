# Azure DevOps Manual Setup

Use this guide when you need to configure each resource yourself. The
[automated setup](azdo-automated-setup.md) creates the same core arrangement interactively.
For GitHub, use [GitHub setup](github-setup.md).

## Prerequisites

- An Azure DevOps Services organization with hosted pipeline capacity and permission to create/configure the project resources.
- Dataverse development and deployment environments, with permissions to create application users and assign security roles.
- Entra app registrations and permission to configure client secrets or federated credentials.
- An existing Dataverse user for process ownership, with appropriate licensing, roles, and connection access.
- A workstation with Git for preparing repositories; runtime scripts use PowerShell 7 on the supplied `windows-2022` agents.

See [organization requirements](azdo-organisation-requirements.md) before starting.
Use non-production environments for the initial verification.

## 1. Azure DevOps Project Setup

Create or select a long-lived project. Use a product/team name rather than a phase name.
Arrange Project Administrator permissions for setup, or ask administrators to perform
the privileged steps. Creating a new project or installing extensions may require
organization-level permissions beyond Project Administrator.

Record your application repository name, shared repository name, development branch,
deployment targets, and whether you will use WIF or client secrets.

## 2. Install Power Platform Build Tools

Install [Power Platform Build Tools](https://marketplace.visualstudio.com/items?itemName=microsoft-IsvExpTools.PowerPlatform-BuildTools).
The supplied templates also default to the
[ALM4Dataverse Azure DevOps extension](https://marketplace.visualstudio.com/items?itemName=ALM4Dataverse.alm4dataverse-azdo-extensions)
for connection-variable resolution. It is required for WIF in this integration.

> [!NOTE]
> **Advanced: using only Microsoft tooling.** If you cannot use the ALM4Dataverse extension,
> set `useAlm4DataverseExtension: false` in every caller and deployment-stage invocation,
> and use client-secret service connections. Microsoft tooling is still installed, but
> its PAC stays off PATH so the configured `pacCliVersion` is used.
> See [service connections](../config/azdo-environment-service-connection.md).

## 3. Repository Setup

### Shared Repository

Create an empty Azure Repos Git repository named `ALM4Dataverse`. Populate its `main`
branch from a tested upstream release. The following example uses the moving `stable`
tag; substitute an actual version tag if you want an explicitly pinned starting point.
Replace `YOUR_CLONE_URL` with the new repository's clone URL:

```bash
git clone YOUR_CLONE_URL
cd ALM4Dataverse
git remote add upstream https://github.com/ALM4Dataverse/ALM4Dataverse.git
git fetch upstream refs/tags/stable:refs/tags/stable
git switch -c main stable
git push origin main
```

> [!CAUTION]
> These commands are for an empty repository. For an existing shared repository, review
> and merge upstream changes instead of replacing its branch history.

Each consuming pipeline uses the repository alias `ALM4Dataverse`; preserve that alias even if its
repository resource `name` includes a project prefix.

### Application Repository

Create or clone the application repository. Copy these items from the same shared release:

| Source | Destination |
| --- | --- |
| [Configuration template](../../copy-to-your-repo/alm-config.psd1) | `alm-config.psd1` at the root |
| [Data hook examples](../../copy-to-your-repo/data) | `data/` |
| [Azure DevOps callers](../../copy-to-your-repo/pipelines) | `pipelines/` |

Do not copy the GitHub workflows unless you also intend to configure GitHub Actions.
Check each caller's shared repository resource. Add an explicit `ref` if you need to
pin the shared repository to a tag/branch instead of its default branch.

> [!IMPORTANT]
> In the DEPLOY caller, set the `build` pipeline resource's `source` to the BUILD pipeline's
> full name, including its folder. Use the displayed path separator: if the UI displays
> `YourApp\BUILD`, use that exact name. Set the branch filter, caller filename, and pipeline
> name for your deployment branch. The supplied DEPLOY stages are commented out until
> you configure targets.

The shared configuration defaults `buildVersion.default` to `1.0`; override it
or add branch-specific MAJOR.MINOR entries in `alm-config.psd1` when needed.

> [!NOTE]
> Every BUILD keeps its branch-suffixed SemVer version and source tag.

## 4. Service Principal Setup

For each target, create or select an Entra application registration. Prefer separate
identities for production and non-production. Record the application/client ID and
tenant ID; do not confuse application IDs with Entra object IDs.

For a client secret, create one under **Certificates & secrets**, store its **value**
securely, and record expiry. For WIF, create the service connection first and configure
the app's federated credential using the **issuer and subject shown by that connection**,
with audience `api://AzureADTokenExchange`. Do not guess these values from a legacy pattern.

In the Power Platform admin center, select the environment, then **Settings > Users +
permissions > Application users**. Add the app, choose its business unit, and assign
the System Administrator role used by the standard setup. A narrower custom role
requires validation against all solution, process, and hook operations you use.

> [!IMPORTANT]
> The process-owner/service-account user is separate from the application user. It must
> already exist and be able to own and activate the relevant processes and connections.

Official guidance: [register an app](https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-register-app)
and [manage application users](https://learn.microsoft.com/en-us/power-platform/admin/manage-application-users).

## 5. Service Connections

In **Project Settings > Service connections**, create a **Power Platform** connection
for each development, deployment, and optional BUILD validation environment. Use the
selected authentication type and Dataverse base URL. Complete WIF trust using the
connection's displayed issuer/subject, or supply the client secret value.

| Purpose | Connection name |
| --- | --- |
| Main development | `Dev-main` |
| Development for another branch | `Dev-<Build.SourceBranchName>` |
| Deployment target | Exactly its `environmentName`, for example `TEST-main` or `PROD` |
| BUILD validation | Exactly `buildEnvironmentName`, for example `Build` |

For `feature/customer-import`, `Build.SourceBranchName` is `customer-import`.
See [branch naming](../usage/branching-strategies.md#branch-and-environment-names).
Authorize only the pipelines that use each connection; avoid blanket access.
Full options: [service connection reference](../config/azdo-environment-service-connection.md).

## 6. Variable Groups

In **Pipelines > Library**, create `Environment-<connection-name>` for every target.
For example, `Environment-Dev-main`, `Environment-TEST-main`, and `Environment-Build`.

Add `DataverseServiceAccountUpn`, connection-reference IDs, Dataverse environment-variable
values, and any custom hook settings. The complete names and secret-mapping requirements
are in the [variable-group reference](../config/azdo-environment-variable-group.md).
Connections must exist in the target; settings do not create them or grant access.

Add an **Exclusive lock** check for shared targets. Add **Approvals** for controlled
deployment targets, with designated approvers. Normal development and disposable BUILD
validation should not use production approval requirements. If an existing group is
reused, review its checks because setup does not remove existing ones.

## 7. Environments And Approvals

In **Pipelines > Environments**, create an environment for each DEPLOY target, with
the exact `environmentName` and no resource unless you need one for other purposes.
The deployment job uses it to record history. Configure any additional approvals,
branch controls, or exclusive locks required by your policy.

> [!NOTE]
> **Advanced: layered checks.** Variable-group checks and environment checks are separate
> and can both pause a stage. Choose where approval lives to avoid accidental duplicates.
> The Dataverse environment is the external target; the Azure DevOps environment is a CI
> resource and does not provision Dataverse.

## 8. Pipeline Creation

Create a pipeline using **New pipeline > Azure Repos Git > Existing Azure Pipelines YAML**
for each caller in the application repository:

| Pipeline name | YAML path | Trigger |
| --- | --- | --- |
| BUILD | `/pipelines/BUILD.yml` | Branch pushes, or manual |
| EXPORT | `/pipelines/EXPORT.yml` | Manual, with commit message |
| IMPORT | `/pipelines/IMPORT.yml` | Manual |
| DEPLOY-main | `/pipelines/DEPLOY-main.yml` | Matching BUILD completion, or manual |

Save them in an application-specific pipeline folder if sharing a project. Ensure the
DEPLOY resource `source` matches the resulting full BUILD name. Do not run DEPLOY until
its stages are configured. A BUILD before the first EXPORT may fail because configured
solution folders do not exist yet.

## 9. Pipeline Permissions

Use the actual project-scoped Build Service identity unless your organization uses a
different job authorization scope. Resource authorization and repository Git permissions
are separate controls.

| Resource | Access to arrange |
| --- | --- |
| Shared repository | Read access and pipeline resource authorization for consumers |
| Application repository | Read; Contribute for EXPORT; Create tag for BUILD; tag creation/update permissions for DEPLOY pointers |
| Moving deployment tags | Force-update permission as narrowly scoped as your Git security model allows; do not grant source-branch rewrite access unnecessarily |
| Development service connection/group | EXPORT and IMPORT |
| BUILD validation connection/group | BUILD when enabled |
| Deployment connections/groups/environments | Relevant DEPLOY pipelines |
| BUILD artifacts | Read permission for DEPLOY and baseline-validation consumers |

Authorize service connections and variable groups through their **Pipeline permissions**,
and deployment environments through their security settings. Resolve first-run resource
authorization prompts as an administrator. Keep branch/tag policies compatible with
the intended automation without bypassing review requirements for human source changes.

## 10. Solution Configuration

In the application configuration, list solutions by unique name in dependency order:

```powershell
@{
    solutions = @(
        @{ name = 'ContosoCore' }
        @{ name = 'ContosoSales' }
    )
    assets = @('data')
    hooks = @{
        postExport = @('data/system/export.ps1')
        postDeploy = @('data/system/import.ps1')
    }
}
```

The example data scripts are initially no-ops until you customize them. Configure
[Solution Checker](../config/alm-config.md#solution-check-pac-solution-check), additional
assets/hooks, or unmanaged deployment only where needed.

In DEPLOY, add one `pipelines/templates/stages/deploy-environment.yml@ALM4Dataverse`
stage entry per target, in promotion order. Each entry supplies `environmentName`,
optionally `useAlm4DataverseExtension`, and optionally `timeoutInMinutes`. Start from the
commented example in the caller and keep valid YAML indentation.

> [!TIP]
> **Optional: deployment validation.** Set `buildEnvironmentName` in BUILD to a dedicated
> non-production connection/group name. To test an upgrade path, set
> `buildValidation.baselineRelease` to a retained BUILD ID/number or `@<deployment-environment>`.
> The baseline source is separate from the validation target. Serialize builds if branches
> share that target. See [BUILD validation](../usage/building-releases.md#build-validation).

## Verify The Installation

1. Commit the configured application files.
2. Run EXPORT on the intended development branch and inspect its commit.
3. Verify BUILD succeeds and publishes the expected packages and reports.
4. Deploy that exact build to the first non-production target and verify connection values, process activation, and app behavior.
5. Promote the same build through later stages, checking approvals and deployment history.
6. Configure the target branch's **Build validation** policy if PRs must pass BUILD before merge; setup does not create that policy automatically.

Continue with [usage and branching](../usage/branching-strategies.md),
[configuration](../config/alm-config.md), or [pipeline/template inputs](../config/pipelines.md).
