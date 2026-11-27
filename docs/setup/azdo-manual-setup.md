# Azure DevOps Manual Setup

Use this guide to create the Azure DevOps resources yourself. The
[automated setup](azdo-automated-setup.md) performs the same steps interactively. Both
routes generate the caller pipelines automatically from `alm-config.psd1` at the end;
this guide covers the resource creation only. For GitHub, use
[GitHub automated setup](github-setup.md).

## Before You Start

- An Azure DevOps Services organization with hosted pipeline capacity and permission to
  create and configure the project resources. See
  [organization requirements](azdo-organisation-requirements.md).
- Development and deployment Dataverse environments, with permission to create
  application users and assign security roles.
- Entra app registrations and permission to configure client secrets or federated
  credentials.
- An existing licensed Dataverse user for process ownership, with the roles and
  connection access the processes need.
- Git on a workstation for preparing repositories. The supplied pipelines run PowerShell
  7 on `windows-2022` agents.

Use non-production environments for the initial verification.

## 1. Azure DevOps Project Setup

Create or select a long-lived project. Use a product or team name rather than a phase
name. Arrange Project Administrator permissions for setup, or ask administrators to
perform the privileged steps. Creating a project or installing extensions can require
organization-level permissions beyond Project Administrator.

Record the application repository name, shared repository name, development branch,
deployment targets, and whether you will use workload identity federation or client
secrets.

## 2. Install Extensions

Install [Power Platform Build Tools](https://marketplace.visualstudio.com/items?itemName=microsoft-IsvExpTools.PowerPlatform-BuildTools)
and the [ALM4Dataverse Azure DevOps extension](https://marketplace.visualstudio.com/items?itemName=ALM4Dataverse.alm4dataverse-azdo-extensions).
The ALM4Dataverse extension is required for workload identity federation. See
[organization requirements](azdo-organisation-requirements.md) for installation steps and
the Microsoft-tooling-only fallback.

## 3. Repository Setup

### Shared Repository

Create an empty Azure Repos Git repository named `ALM4Dataverse` and populate its `main`
branch from a tested release. Replace `YOUR_CLONE_URL` with the new repository's clone
URL:

```bash
git clone YOUR_CLONE_URL
cd ALM4Dataverse
git remote add upstream https://github.com/ALM4Dataverse/ALM4Dataverse.git
git fetch upstream refs/tags/stable:refs/tags/stable
git switch -c main stable
git push origin main
```

Keep the pipeline repository alias `ALM4Dataverse` even when the resource name includes a
project prefix. For an existing shared repository, merge upstream changes instead of
replacing its branch history;
[upstream release tracking](../usage/updating.md#track-upstream-releases) can open those
pull requests for you.

### Application Repository

Create or clone the application repository and copy these items from the same shared
release:

| Source | Destination |
| --- | --- |
| [Configuration template](../../copy-to-your-repo/alm-config.psd1) | `alm-config.psd1` at the root |
| [AI-agent context](../../copy-to-your-repo/AGENTS.md) | `AGENTS.md` at the root |
| [Data hook examples](../../copy-to-your-repo/data) | `data/` |

The caller pipelines are generated from `alm-config.psd1`, not copied or edited by hand:
applying the configuration writes `pipelines/BUILD.yml`, `pipelines/EXPORT.yml`,
`pipelines/IMPORT.yml` and `pipelines/DEPLOY-<branch>.yml` (the static
`APPLY-CONFIG.yml` caller is the only pipeline copied from the shared scaffold). Set the setup metadata in
`alm-config.psd1` — `provider = 'azDO'`, the shared repository name in `repository`, its
branch in `ref`, and the application branches with their environments under `branches` —
commit it, then create the APPLY-CONFIG pipeline described in
[pipeline creation](#8-pipeline-creation) and run it to generate and publish the caller
files; set the pipeline's **preview** parameter to see the generated file diffs in the
run output without committing them. Alternatively, run `setup-azdo.ps1 -ApplyConfig`
from the application repository root on a workstation; add `-PreviewOnly` to review the
generated file diffs without publishing. See
[setup metadata and branch environments](../config/alm-config.md#setup-metadata-and-branch-environments)
and [setup script parameters](../config/pipelines.md#setup-script-parameters).

Do not copy the GitHub workflows unless you also configure GitHub Actions. Keep
`AGENTS.md` and ask an AI agent to read it before changing components or configuration.
See [application repository layout](../concepts/application-repository.md).

## 4. Service Principal Setup

For each target, create or select an Entra app registration. Prefer separate identities
for production and non-production. Record the application/client ID and tenant ID, not
the Entra object ID. Under **API permissions**, add **Dynamics CRM** > **Delegated
permissions** > `user_impersonation` and grant admin consent. The Dataverse application
user grants access to the environment; the `user_impersonation` permission is the scope
the deployment identity requests. Guided setup validates the app registration, its
Dataverse permission, enterprise application and configured client secret or federated
credential when you enter an existing application ID.

Choose one authentication method; workload identity federation is recommended because it
avoids client secrets:

- **Client secret:** create one under **Certificates & secrets**, store its value
  securely, and record the expiry.
- **Workload identity federation:** create the service connection first, then add a
  federated credential using the issuer and subject shown by that connection, with
  audience `api://AzureADTokenExchange`. Do not guess these values from a legacy pattern.

In the Power Platform admin center, select the environment, then **Settings > Users +
permissions > Application users**. Add the app, choose its business unit, and assign the
System Administrator role used by the standard setup. A narrower custom role requires
validation against every solution, process and hook operation you use.

The process-owner user is separate from the application user. It must already exist, be
enabled, and be able to own and activate the relevant processes and connections.

See [service connections](../config/azdo-environment-service-connection.md) for the full
connection reference.

## 5. Service Connections

In **Project Settings > Service connections**, create a **Power Platform** connection for
each development, deployment and optional BUILD validation environment. Use the selected
authentication type and Dataverse base URL.

| Purpose | Connection name |
| --- | --- |
| Main development | `Dev-main` |
| Development for another branch | `Dev-<Build.SourceBranchName>` |
| Deployment target | Exactly its `environmentName`, for example `TEST-main` or `PROD` |
| BUILD validation | Exactly `buildEnvironmentName`, for example `Build` |

For `feature/customer-import`, `Build.SourceBranchName` is `customer-import`. See
[branch and environment names](../usage/branching-strategies.md#branch-and-environment-names).
Authorize only the pipelines that use each connection. Full options:
[service connection reference](../config/azdo-environment-service-connection.md).

## 6. Variable Groups

In **Pipelines > Library**, create `Environment-<connection-name>` for every target, for
example `Environment-Dev-main`, `Environment-TEST-main` and `Environment-Build`.

Add `DataverseServiceAccountUpn`, connection-reference IDs, Dataverse environment-variable
values, and any custom hook settings. The complete names and secret-mapping requirements
are in the [variable-group reference](../config/azdo-environment-variable-group.md).
Connections must already exist in the target; settings do not create them or grant
access.

Add an **Exclusive lock** check for shared targets. Add **Approvals** for controlled
deployment targets, with designated approvers. Normal development and disposable BUILD
validation should not use production approval requirements. Review existing checks when
reusing a group because setup does not remove them.

## 7. Environments And Approvals

In **Pipelines > Environments**, create an environment for each DEPLOY target with the
exact `environmentName` and no resource unless you need one for another purpose. The
deployment job uses it to record history. Configure any additional approvals, branch
controls or exclusive locks required by your policy.

> [!NOTE]
> Variable-group checks and environment checks are separate and can both pause a stage.
> Choose where approval lives to avoid accidental duplicates. The Dataverse environment is
> the external target; the Azure DevOps environment is a CI resource.

## 8. Pipeline Creation

Create a pipeline using **New pipeline > Azure Repos Git > Existing Azure Pipelines YAML**
for each caller in the application repository:

| Pipeline name | YAML path | Trigger |
| --- | --- | --- |
| APPLY-CONFIG | `/pipelines/APPLY-CONFIG.yml` | Manual |
| `<repository>-BUILD` | `/pipelines/BUILD.yml` | Branch pushes, or manual |
| `<repository>-EXPORT` | `/pipelines/EXPORT.yml` | Manual, with commit message |
| `<repository>-IMPORT` | `/pipelines/IMPORT.yml` | Manual |
| `<repository>-DEPLOY-main` | `/pipelines/DEPLOY-main.yml` | Matching BUILD completion, or manual |

`<repository>` is the application repository name.

Create the APPLY-CONFIG pipeline first, authorize the shared repository resource at its
first run, and run it: it applies the committed `alm-config.psd1` and commits the
generated caller files to the default branch. After that, create the BUILD, EXPORT,
IMPORT and DEPLOY pipelines from the generated files.

Create one DEPLOY pipeline per configured deployment branch. Qualify every pipeline name
with the application repository name, as shown, because pipeline completion triggers
resolve the BUILD resource by name. Two application repositories in one project with
pipelines both named `BUILD` make the DEPLOY resource reference ambiguous and deployment
triggers stop firing. Do not run DEPLOY until its branch has deployment
environments configured. A BUILD before the first EXPORT may fail because the configured
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
authorization prompts as an administrator. Keep branch and tag policies compatible with
the intended automation without bypassing review requirements for human source changes.

## 10. Solution Configuration

List solutions by unique name in dependency order in `alm-config.psd1`:

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

Configure [Solution Checker](../config/alm-config.md#solution-check-pac-solution-check),
additional assets or hooks, and unmanaged deployment only where needed.

Branch environments drive the generated pipelines. Configure the `branches` map so each
branch selects its development environment, ordered deployment environments, and
optional BUILD validation:

```powershell
@{
    provider = 'azDO'
    repository = 'ALM4Dataverse'
    ref = 'main'
    branches = @{
        main = @{
            developmentEnvironment = 'Dev-main'
            deploymentEnvironments = @('TEST-main', 'PROD')
            buildValidation = @{
                environmentName = 'Build-main'
                baselineRelease = ''
            }
        }
    }
}
```

Setup writes `DEPLOY-<branch>.yml` with one deployment stage per entry in
`deploymentEnvironments`. Leave `buildValidation.environmentName` empty to pack only.
Use the exact names configured in [service connections](#5-service-connections) and
[variable groups](#6-variable-groups). To test an upgrade path, set
`branches.<branch>.buildValidation.baselineRelease` to a retained BUILD ID/number or
`@<deployment-environment>`; the baseline source is separate from the validation
target. See [BUILD validation](../usage/building-releases.md#build-validation).

After changing and committing `alm-config.psd1`, run `setup-azdo.ps1 -ApplyConfig` again
to regenerate the caller files; they are never edited by hand. See
[setup metadata and branch environments](../config/alm-config.md#setup-metadata-and-branch-environments)
and the [template reference](../config/pipelines.md#azure-devops-templates).

## Verify The Installation

1. Commit the configured application files.
2. Run EXPORT on the intended development branch and inspect its commit.
3. Verify BUILD succeeds and publishes the expected packages and reports.
4. Deploy that exact build to the first non-production target and verify connection
   values, process activation and application behavior.
5. Promote the same build through later stages, checking approvals and deployment history.
6. Configure the target branch's **Build validation** policy if pull requests must pass
   BUILD before merge; setup does not create that policy.

Continue with [usage and branching](../usage/branching-strategies.md),
[configuration](../config/alm-config.md), or
[pipeline and template inputs](../config/pipelines.md).
