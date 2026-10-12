# GitHub Actions Setup Guide

GitHub Actions support is **PREVIEW**. This guide covers automated and manual setup.
For Azure DevOps, use the [Azure DevOps setup guide](azdo-automated-setup.md).

The application repository contains unpacked solutions, its ALM configuration, data/hooks,
and small caller workflows. Shared composite actions run the build/export/import/deploy
steps; a separate reusable workflow handles Release cleanup. You do not need a second
GitHub repository unless you want to maintain a fork of the shared implementation.

## Prerequisites

- A GitHub repository with Actions enabled and permission to configure its workflows, variables, secrets, and environments.
- Access to development and deployment Dataverse environments and permission to create/manage application users.
- An Entra app registration for each target, or permission to create one and configure its authentication.
- An existing user account for process ownership, with the necessary licensing, roles, and connection access.
- A GitHub plan supporting the environment features you intend to use; see [licence limitations](#github-licence-limitations).
- For automated setup: Windows PowerShell 5.1 or PowerShell 7 on Windows, Git, and network access to GitHub and the required Microsoft/package services. Setup downloads a temporary GitHub CLI when `gh` is missing.

> [!CAUTION]
> Use separate application identities for production and non-production. The application
> user authenticates automation; the service-account user owns and activates processes.
> They are not interchangeable. The standard setup assigns the application user the
> Dataverse System Administrator role. Restrict access to CI credentials and treat
> workflow and hook changes as privileged code changes.

## Automated Setup

Download the released script, review it, then run it from PowerShell:

```powershell
Invoke-WebRequest 'https://github.com/ALM4Dataverse/ALM4Dataverse/releases/latest/download/setup-github.ps1' -OutFile './setup-github.ps1'
```

After reviewing the downloaded file:

```powershell
.\setup-github.ps1
```

The existing one-line bootstrap remains available for users who have already reviewed
and trust the release:

```powershell
iwr https://github.com/ALM4Dataverse/ALM4Dataverse/releases/latest/download/setup-github.ps1 | iex
```

Setup signs in, selects or creates the application repository, selects solutions in
dependency order, and configures development and deployment environments. It prompts
for application identities/authentication and process-owner accounts, generates caller
workflows, and offers shared BUILD deployment validation with an optional baseline source.

> [!IMPORTANT]
> Verify plan compatibility and the generated protection rules. Setup selects
> `environment-approval` when it detects support, or prefixed repository variables plus
> `manual-gate-tag` otherwise. The fallback still stores client secrets in the matching
> GitHub environment; it does not make private GitHub Free repositories a fully supported
> out-of-the-box configuration.

Re-running setup can update generated files. Existing `secrets-json` mappings, including
separate deployment-stage mappings, are preserved by the updater. Review the resulting
diff and stored settings; do not assume every local workflow customization is preserved.
GitHub cannot reveal existing secret values for automatic relocation.

For `TenantId`, `UseDeviceAuthentication`, and `ALM4DataverseRef`, see
[setup parameters](../config/pipelines.md#setup-script-parameters). Released scripts
embed their helpers; raw repository scripts need the adjacent files in this repository.

## Manual Setup

### 1. Prepare Application Identities

For each target, register an app in Entra ID and record its application/client ID and
tenant ID. In the Power Platform admin center, select the Dataverse environment, add
an **Application user** for that app, and assign the required role.

Choose authentication:

- **WIF/OIDC:** add a federated credential with issuer `https://token.actions.githubusercontent.com`, audience `api://AzureADTokenExchange`, and the exact job subject. No client secret is needed.
- **Client secret:** create a secret and retain its value in GitHub Secrets, not source control. Track its expiry and rotation process.

The [credential reference](../config/github-secrets.md#entra-id-federated-credential-setup)
shows both legacy and immutable subject formats. For environment-based jobs, create a
credential for each relevant GitHub environment, including BUILD validation when enabled.

> [!NOTE]
> **Advanced: immutable OIDC subjects.** Setup can offer to enable these on existing
> repositories. Review other applications trusting the old subjects before changing
> this repository-wide setting.

Official guidance: [app registrations](https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-register-app),
[Dataverse application users](https://learn.microsoft.com/en-us/power-platform/admin/manage-application-users),
and [GitHub OIDC with Azure](https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-azure).

### 2. Copy The Application Files

Copy the following from a consistent ALM4Dataverse release into your application repository:

| Source | Destination |
| --- | --- |
| [alm-config.psd1](../../copy-to-your-repo/alm-config.psd1) | Repository root |
| [data](../../copy-to-your-repo/data) | `data/` |
| [GitHub workflows](../../copy-to-your-repo/.github/workflows) | `.github/workflows/` |

Include the hidden `.github` directory. Do not copy the Azure DevOps `pipelines` callers
unless you also intend to configure that platform. Select a tested action/workflow ref
instead of unintentionally following the template's `@main` references.

The caller workflows are BUILD, EXPORT, IMPORT, DEPLOY-main, and CLEANUP-RELEASES.
Configure `solutions` using unique names in dependency order, then customize optional
assets, hooks, checker rules, and validation in the [ALM configuration](../config/alm-config.md).
Do not add plaintext secrets to that file.

### 3. Configure Credentials

Follow the [environment checklist](github-variables.md) for `Dev-main`, your deployment
targets, and optional BUILD validation environment. The job's `environment` selects
GitHub environment settings; `environment-name` tells the action which configuration
prefix to resolve. Keep them consistent.

Pass `${{ toJSON(vars) }}` as `vars-json`. Explicitly select each secret in `secrets-json`,
using `toJSON(secrets.NAME)` to escape its value. For prefixed repository secrets, map the
stored prefixed name to the runtime unprefixed name in each stage. Do not duplicate a
setting in multiple forms and rely on ambiguous precedence.

## Credential Configuration

The complete settings are maintained in one [credential reference](../config/github-secrets.md):

| Requirement | Reference |
| --- | --- |
| Environment values with WIF | [WIF settings and subjects](../config/github-secrets.md#approach-1-workload-identity-federation-oidc) |
| Environment values with a client secret | [Client-secret settings](../config/github-secrets.md#approach-2-github-environments-with-client-secret) |
| Prefixed repository values | [Prefixes, aliases, and secrets](../config/github-secrets.md#approach-3-prefixed-repository-variables-and-secrets) |
| Connection references and Dataverse variables | [Per-solution settings](../config/github-secrets.md#per-solution-connection-references) |
| Custom secrets and process-owner keys | [Explicit mapping](../config/github-secrets.md#per-solution-environment-variable-values) |

## Deployment Configuration

Edit DEPLOY-main to contain one job per target environment. Configure the job environment,
action `environment-name`, `previous-environment-name`, `promotion-mode`, and
`trigger-branch`. Keep `github-context-json: ${{ toJSON(github) }}` and
`caller-inputs-json: ${{ toJSON(inputs) }}` unchanged.

### Environment Approval Mode

The copied caller explicitly uses `environment-approval`. A successful BUILD sends
`alm4dataverse-build-deploy-<branch-token>` through `repository_dispatch`; the first
stage starts, and later stages follow successful predecessors.

> [!IMPORTANT]
> Configure actual GitHub environment required reviewers where supported. Without
> protection rules, `environment-approval` can deploy through every stage automatically.

For a manual run, leave `target-environment` empty to start at the first stage, or set
it to a named stage. The `build-run-name` selector can be an exact Release tag, BUILD
name, or numeric BUILD run ID; blank means the latest successful BUILD from the selected
branch. For promotion, use an explicit identity so a newer build is not selected by accident.

### Deployment Gates For GitHub Free

`manual-gate-tag` is the alternative when required reviewers are unavailable, including
private Pro/Team repositories. The name of this section is retained for existing links;
the [private-Free environment restriction](#github-licence-limitations) still applies.

To adapt the supplied caller:

1. Set every stage's `promotion-mode` to `manual-gate-tag`.
2. Remove the `repository_dispatch` trigger.
3. Make `target-environment` a required choice containing your target names.
4. Give each job a manual selection condition. Jobs with `needs` must use a status-aware condition, such as `!cancelled()`, so a skipped earlier job does not suppress the selected stage.
5. Set each later stage's `previous-environment-name` to its predecessor.

For example, the selection condition on a manual PROD job can be:

```yaml
if: ${{ !cancelled() && github.event_name == 'workflow_dispatch' && inputs.target-environment == 'PROD' }}
```

Run DEPLOY manually for the first target, inspect the result, then run it again for the
next target with the **same build identity**. Later stages require a success tag for
that build in the previous environment. These tags enforce recorded order, not a separate
person's approval. Anyone able to modify trusted workflows, credentials, or gate tags
can affect that control, so secure those permissions.

### Branches And Additional Stages

For another deployment branch, create a matching DEPLOY caller and update its name,
branch filters, dispatch event, `trigger-branch`, and target settings consistently.
The dispatch token is the lowercase branch name with non-alphanumeric runs replaced
by `-`, trimmed at the ends: `feature/customer-import` becomes `feature-customer-import`.
Avoid normalized-name collisions.

> [!NOTE]
> **Advanced: dispatch branch context.** Repository-dispatch workflows must exist on the
> repository's **default branch**. They use the payload to select the source branch/build,
> but the workflow's GitHub ref still comes from the default branch. Account for that in
> environment deployment-branch policies. See [branching strategies](../usage/branching-strategies.md).

To add UAT, add a job, target choice if applicable, credentials, and concurrency group;
chain it with `needs` and update PROD's predecessor. Test automatic and targeted manual
runs. The [action reference](../config/pipelines.md#deploy) defines all supported inputs.

## BUILD Validation And Pull Requests

For deployment validation, uncomment the BUILD job's environment block, set its name,
and set the action's `environment-name` to that same value. Provide the target's URL,
credentials, process-owner UPN, connections, and Dataverse values.

> [!CAUTION]
> Use a dedicated non-production Dataverse environment for BUILD validation. It is
> updated in place, not reset, and builds from multiple branches can share it.
> Configure appropriate serialization to prevent conflicting deployments.

Optionally set `buildValidation.baselineRelease` to a retained build or `@<deployment-environment>`.
That source environment is separate from the validation target.

Enable Solution Checker separately if required. It checks package quality, not end-user
behavior. The copied BUILD workflow runs on branch pushes, manual dispatch, and export
dispatch, not `pull_request`. Configure required status checks in repository policies;
add PR-merge/merge-queue validation separately when required. Do not expose privileged
credentials to untrusted PR code. See [building releases](../usage/building-releases.md).

## Workflow Job Timeouts

Caller jobs run on `ubuntu-latest` and request `timeout-minutes: 360` at job level.
Do not pass a timeout as a composite-action input. DEPLOY's example concurrency groups
use `cancel-in-progress: true`; EXPORT/IMPORT use a shared development-environment group
with cancellation disabled. Review the consequences of cancellation for server-side imports.
See [timeouts](../config/alm-config.md#import-timeout).

## GitHub Licence Limitations

| Capability | Public repositories on Free/Pro/Team | Private Free | Private Pro/Team |
| --- | --- | --- | --- |
| GitHub Actions | Available, subject to policy/limits | Available, subject to limits | Available, subject to limits |
| Environments and environment secrets/variables | Available | Not available | Available |
| Required reviewers and wait timers | Available | Not available | Not available |
| Environment deployment branch/tag restrictions | Available | Not available | Available |

For private-repository required reviewers, check the applicable GitHub Enterprise offering.
These are platform capabilities, not features ALM4Dataverse can enable on an unsupported
plan. Prefixed repository credentials and manual gate tags are not equivalent to protected
environment secrets and independent approval.

Consult [environment availability](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments),
[protection rules](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments),
and [current Actions limits](https://docs.github.com/en/actions/reference/limits).
The supplied Linux jobs should not be budgeted using Windows-runner multipliers.

## Grant Permissions For Workflow Operations

Keep the caller's explicit job-level permissions, described in the
[permissions reference](../config/pipelines.md#caller-settings-and-permissions), and
verify organization/repository policy permits them. EXPORT needs to push source changes;
BUILD publishes tags and Releases; DEPLOY writes success/pointer tags; cleanup deletes
managed Releases. Branch and tag rules must permit these intended operations.

> [!NOTE]
> **Advanced: custom dispatch tokens.** EXPORT normally uses `GITHUB_TOKEN` to dispatch
> BUILD after committing. Its default mapping also accepts an optional
> `WORKFLOW_DISPATCH_TOKEN` or legacy `GH_WORKFLOW_TOKEN` secret when policy requires one.
> Dataverse credentials do not grant GitHub repository access. Do not grant broad default
> token access when explicit job permissions suffice.

## First Run

1. Commit the configured callers and configuration to the default branch.
2. Run EXPORT from the intended development branch with a meaningful commit message.
3. Review the exported `solutions/<unique-name>` files and any data changes.
4. Check the resulting BUILD and its Release. A build before the first export may fail because solution source is not present yet.
5. Deploy that exact build to the first non-production target and verify process activation and application behavior.
6. Promote the same build through the remaining configured targets.

Use IMPORT to seed or synchronize a development environment from source, not to promote
a release. Keep CLEANUP-RELEASES on the default branch and review its retention policy.
Continue with [exporting](../usage/exporting-changes.md), [building](../usage/building-releases.md),
[deploying](../usage/deploying.md), or [importing](../usage/importing-changes.md).
