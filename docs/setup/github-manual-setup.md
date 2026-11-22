# GitHub Actions Manual Setup

Use this guide to create the GitHub and Dataverse resources yourself. The
[automated setup](github-setup.md) performs the same steps interactively. Both routes
generate the caller workflows automatically from `alm-config.psd1` at the end; this guide
covers the resource creation only. For Azure DevOps, use
[Azure DevOps manual setup](azdo-manual-setup.md).

## Before You Start

- A GitHub repository with Actions enabled and permission to configure its workflows,
  variables, secrets and environments. Use a public repository, or a private one on a plan
  with environments; see [plan limitations](#github-licence-limitations).
- Development and deployment Dataverse environments, with permission to create and manage
  application users.
- An Entra app registration for each target, or permission to create one.
- An existing licensed user in each environment to own and activate flows and other
  processes.
- The application files from a consistent ALM4Dataverse release. See
  [copy the application files](#2-copy-the-application-files).

> [!CAUTION]
> Use separate application identities for production and non-production. The application
> user authenticates automation; the service-account user owns and activates processes.
> They are not interchangeable. Treat workflow and hook changes as privileged code
> changes.

## 1. Prepare Application Identities

For each target, register an app in Entra ID and record its application/client ID and
tenant ID. In the Power Platform admin center, select the Dataverse environment, add an
**Application user** for that app, and assign the required role.

Choose authentication:

- **WIF/OIDC:** add a federated credential with issuer
  `https://token.actions.githubusercontent.com`, audience `api://AzureADTokenExchange`,
  and the exact job subject. No client secret is needed.
- **Client secret:** create a secret and store its value in GitHub Secrets, not source
  control. Track its expiry and rotation process.

The [credential reference](../config/github-secrets.md#entra-id-federated-credential-setup)
shows both legacy and immutable subject formats. For environment-based jobs, create a
credential for each relevant GitHub environment, including BUILD validation when enabled.

> [!NOTE]
> **Advanced: immutable OIDC subjects.** Setup can offer to enable these on existing
> repositories. Review other applications trusting the old subjects before changing this
> repository-wide setting.

Official guidance: [app registrations](https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-register-app),
[Dataverse application users](https://learn.microsoft.com/en-us/power-platform/admin/manage-application-users),
and [GitHub OIDC with Azure](https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-azure).

## 2. Copy The Application Files

Copy these items from a consistent ALM4Dataverse release into your application repository:

| Source | Destination |
| --- | --- |
| [alm-config.psd1](../../copy-to-your-repo/alm-config.psd1) | Repository root |
| [AI-agent context](../../copy-to-your-repo/AGENTS.md) | `AGENTS.md` at the repository root |
| [data](../../copy-to-your-repo/data) | `data/` |

The caller workflows are generated from `alm-config.psd1`, not copied or edited by hand:
applying the configuration writes BUILD, EXPORT, IMPORT and DEPLOY-<branch> into
`.github/workflows/` (CLEANUP-RELEASES and the static APPLY-CONFIG caller are the only
workflows copied from the shared scaffold). Set the setup metadata in `alm-config.psd1` —
`provider = 'GitHub'`, the shared repository name in `repository`, its ref in `ref`, the
application branches with their environments under `branches`, and the GitHub options
such as `GitHubDeploymentPromotionMode` — commit it, and then apply the configuration:

1. Open the repository's **Actions** tab and run the **APPLY-CONFIG** workflow
   (`workflow_dispatch`). It runs the shared setup source at the ref this workflow
   references, regenerates every caller workflow for every configured branch, and opens a
   pull request into the default branch with the changes. Enable the **preview** input to
   see the generated file diffs in the run output without opening a pull request. GitHub
   blocks the built-in Actions token from changing workflow files, so the pull request puts
   them in `replace-github-workflows/`. Merge it, then replace `.github/workflows` with that
   folder and commit; BUILD fails until you do. This is how manual setup generates the
   caller workflows.
   Before the first run, enable **Allow GitHub Actions to create and approve pull requests**
   under **Settings > Actions > General > Workflow permissions**. Guided setup does this for
   you, but manual setup does not.
   See [apply configuration](../config/github-secrets.md#apply-configuration).
2. Alternatively, run `setup-github.ps1 -ApplyConfig` from the application repository
   root on a workstation. Add `-PreviewOnly` to review the generated file diffs without
   publishing.

See
[setup metadata and branch environments](../config/alm-config.md#setup-metadata-and-branch-environments)
and [setup script parameters](../config/pipelines.md#setup-script-parameters).

Do not copy the Azure DevOps `pipelines` callers unless you also configure that platform.
Keep `AGENTS.md` and ask an AI agent to read it before changing Dataverse components or
ALM configuration. See [application repository layout](../concepts/application-repository.md).

Configure `solutions` using unique names in dependency order, then customize optional
assets, hooks, checker rules and validation in the
[ALM configuration](../config/alm-config.md). Do not add plaintext secrets to that file.

## 3. Configure Credentials

Follow the [environment checklist](github-variables.md) for `Dev-main`, your deployment
targets, and optional BUILD validation environment. The generated workflow's
`environment` selects GitHub environment settings; `environment-name` tells the action
which configuration prefix to resolve. Keep the names in `alm-config.psd1` consistent with
the checklist names.

Pass `${{ toJSON(vars) }}` as `vars-json`. Explicitly select each secret in `secrets-json`,
using `toJSON(secrets.NAME)` to escape its value. For prefixed repository secrets, map the
stored prefixed name to the runtime unprefixed name in each stage. Do not duplicate a
setting in multiple forms and rely on ambiguous precedence.

The complete settings are maintained in one
[credential reference](../config/github-secrets.md):

| Requirement | Reference |
| --- | --- |
| Environment values with WIF | [WIF settings and subjects](../config/github-secrets.md#approach-1-workload-identity-federation-oidc) |
| Environment values with a client secret | [Client-secret settings](../config/github-secrets.md#approach-2-github-environments-with-client-secret) |
| Repository values | [Repository variables and secrets](../config/github-secrets.md#approach-3-repository-variables-and-secrets) |
| Connection references and Dataverse variables | [Per-solution settings](../config/github-secrets.md#per-solution-connection-references) |
| Custom secrets and process-owner keys | [Explicit mapping](../config/github-secrets.md#per-solution-environment-variable-values) |

## Deployment Configuration

Setup generates DEPLOY-<branch> with one job per entry in the branch's
`deploymentEnvironments`, in promotion order. Select the promotion strategy with
`GitHubDeploymentPromotionMode` in `alm-config.psd1` before applying: `'environment-approval'`
or `'manual-gate-tag'`. See the [deploy action reference](../config/pipelines.md#deploy).

### Environment Approval Mode

Set `GitHubDeploymentPromotionMode = 'environment-approval'`. A successful BUILD sends
`alm4dataverse-build-deploy-<branch-token>` through `repository_dispatch`; the first stage
starts, and later stages follow successful predecessors.

> [!IMPORTANT]
> Configure required reviewers on each GitHub environment where your plan supports them.
> Without protection rules, `environment-approval` can deploy through every stage
> automatically.

For a manual run, leave `target-environment` empty to start at the first stage, or set it
to a named stage. The `build-run-name` selector can be an exact Release tag, BUILD name, or
numeric BUILD run ID; blank means the latest successful BUILD from the selected branch. For
promotion, use an explicit identity so a newer build is not selected by accident.

### Manual Gate-Tag Promotion

`manual-gate-tag` is the alternative when required reviewers are unavailable, such as
private Pro/Team repositories. It does not make private GitHub Free repositories work: the
supplied jobs still need GitHub environments, which private Free repositories lack. See
[plan limitations](#github-licence-limitations).

Set `GitHubDeploymentPromotionMode = 'manual-gate-tag'` and re-run setup. The generated
workflow keeps `target-environment` as a required choice containing your target names and
gives each job a manual selection condition, such as:

```yaml
if: ${{ !cancelled() && github.event_name == 'workflow_dispatch' && inputs.target-environment == 'PROD' }}
```

Run DEPLOY manually for the first target, inspect the result, then run it again for the
next target with the same build identity. Later stages require a success tag for that
build in the previous environment. These tags enforce recorded order, not a separate
person's approval. Anyone able to modify trusted workflows, credentials or gate tags can
affect that control, so secure those permissions.

### Branches And Additional Stages

For another deployment branch, add an entry to the `branches` map in `alm-config.psd1` with
its own `developmentEnvironment` and `deploymentEnvironments`, then re-run setup. Add a UAT
stage by adding `UAT` to the branch's `deploymentEnvironments` in promotion order; the
generated jobs chain and update predecessors automatically. Test automatic and targeted
manual runs. The dispatch token is the lowercase branch name with non-alphanumeric runs
replaced by `-`, trimmed at the ends: `feature/customer-import` becomes
`feature-customer-import`. Avoid normalized-name collisions. The
[action reference](../config/pipelines.md#deploy) defines all supported inputs.

> [!NOTE]
> Repository-dispatch workflows must exist on the default branch. They use the payload to
> select the source branch and build, but the workflow's GitHub ref still comes from the
> default branch. Account for that in environment deployment-branch policies. See
> [branching strategies](../usage/branching-strategies.md).

## BUILD Validation And Pull Requests

Setup writes BUILD validation settings under `branches.<branch>.buildValidation`.
Configure an environment name and, optionally, `baselineRelease` for each branch that
should run validation. The selected environment needs its URL, credentials,
process-owner UPN, connections and Dataverse values. New branches can leave BUILD
validation disabled.

> [!CAUTION]
> Use a dedicated non-production Dataverse environment for BUILD validation. It is updated
> in place, not reset. Branches may use separate environments or deliberately share one;
> serialize builds that could update the same environment.

Optionally set each branch's `buildValidation.baselineRelease` to a retained build or
`@<deployment-environment>`. That source environment is separate from the validation
target. The legacy top-level `buildValidation.baselineRelease` is only a fallback for older
configurations; see
[setup metadata and branch environments](../config/alm-config.md#setup-metadata-and-branch-environments).

Enable Solution Checker separately if required. It checks package quality, not end-user
behavior. The generated BUILD workflow runs on branch pushes, manual dispatch and export
dispatch, not `pull_request`. Configure required status checks in repository policies; add
PR-merge or merge-queue validation separately when required. Do not expose privileged
credentials to untrusted PR code. See
[building releases](../usage/building-releases.md).

## Permissions And Timeouts

Keep the caller's explicit job-level permissions, described in the
[permissions reference](../config/pipelines.md#caller-settings-and-permissions), and
verify that organization and repository policy permit them. EXPORT pushes source changes;
BUILD publishes tags and Releases; DEPLOY writes success and pointer tags; cleanup deletes
managed Releases. Branch and tag rules must permit these intended operations.

Caller jobs run on `ubuntu-latest` and request `timeout-minutes: 360` at job level. Do not
pass a timeout as a composite-action input. DEPLOY's example concurrency groups use
`cancel-in-progress: true`; EXPORT and IMPORT use a shared development-environment group
with cancellation disabled. Review the consequences of cancellation for server-side
imports. See [timeouts](../config/alm-config.md#import-timeout).

> [!NOTE]
> EXPORT normally uses `GITHUB_TOKEN` to dispatch BUILD. Its default mapping also accepts
> an optional `WORKFLOW_DISPATCH_TOKEN` or legacy `GH_WORKFLOW_TOKEN` secret when policy
> requires one. Dataverse credentials do not grant GitHub repository access.

## GitHub Licence Limitations

| Capability | Public repositories on Free/Pro/Team | Private Free | Private Pro/Team |
| --- | --- | --- | --- |
| GitHub Actions | Available, subject to policy/limits | Available, subject to limits | Available, subject to limits |
| Environments and environment secrets/variables | Available | Not available | Available |
| Required reviewers and wait timers | Available | Not available | Not available |
| Environment deployment branch/tag restrictions | Available | Not available | Available |

For private-repository required reviewers, check the applicable GitHub Enterprise
offering. These are platform capabilities, not features ALM4Dataverse can enable on an
unsupported plan. Prefixed repository credentials and manual gate tags are not equivalent
to protected environment secrets and independent approval.

Consult [environment availability](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments),
[protection rules](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments),
and [current Actions limits](https://docs.github.com/en/actions/reference/limits).
The supplied Linux jobs should not be budgeted using Windows-runner multipliers.

## Verify The Installation

1. Commit the configured application files.
2. Run EXPORT from the intended development branch and inspect its commit.
3. Verify BUILD succeeds and publishes the expected Release.
4. Deploy that exact build to the first non-production target and verify process
   activation and application behavior.
5. Promote the same build through later targets, checking approvals and deployment
   history.

Continue with [exporting](../usage/exporting-changes.md),
[building](../usage/building-releases.md), [deploying](../usage/deploying.md), or
[importing](../usage/importing-changes.md).
