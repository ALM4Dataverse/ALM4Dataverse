# Troubleshooting

Start with the **first failing step**, not only the final job result. Record the operation,
platform, branch/SHA, build identity, target environment, and relevant error text. Do not
post access tokens, client secrets, connection strings, or exported personal data in an issue.

## Setup Or Resource Authorization

| Symptom | Check |
| --- | --- |
| Setup fails after creating some resources | Inspect what already exists before rerunning. Setup is interactive, not an all-or-nothing transaction. Preserve custom caller files and existing checks. |
| Azure DevOps resource not found/authorized | Check the shared repository alias/name, service connection, `Environment-<name>` group, deployment environment, and their pipeline permissions. |
| Azure DevOps DEPLOY cannot resolve BUILD | Set the `build` resource `source` to the full BUILD pipeline name including its folder. Confirm branch filters and artifact read access. |
| A hosted job will not start or expires early | Check purchased/granted runner capacity and the platform's job limit. An import timeout cannot extend the hosted job limit. |
| GitHub environment unavailable or approval absent | Check repository visibility and plan support. Manual promotion does not remove the supplied jobs' dependence on GitHub environments. |

References: [Azure DevOps permissions](../setup/azdo-manual-setup.md#9-pipeline-permissions),
[GitHub prerequisites](../setup/github-setup.md), and [timeouts](../config/alm-config.md).

## Authentication And Target Settings

1. Confirm the Dataverse URL and tenant/client IDs refer to the intended environment and app.
2. Confirm the app has an enabled Dataverse application user with the required security roles.
3. For a secret, verify expiry and that the **secret value**, not its identifier, is configured.
4. For WIF/OIDC, compare the actual issuer, audience, and subject with the Entra credential. Environment names, casing, escaping, and branch/ref context matter.
5. Check value delivery separately from value storage: a configured secret is not automatically exposed to a script.

> [!NOTE]
> **Advanced: value delivery.** On GitHub, align the job's `environment` with the action's
> `environment-name` and select secrets in `secrets-json`. Nonempty selected secrets
> override existing runtime values; supported direct variables precede prefixed fallbacks.
> Do not print entire variable/secret JSON documents for diagnosis.
>
> On Azure DevOps, secrets require explicit `env:` mapping into the relevant PowerShell
> step. The runner normalizes nonsecret names; deployment resolves its supported settings
> case-insensitively through uppercase names.

References: [GitHub mapping and OIDC](../config/github-secrets.md),
[Azure DevOps authentication](../config/azdo-environment-service-connection.md), and
[target variables](../config/azdo-environment-variable-group.md).

## EXPORT Or IMPORT Uses The Wrong Development Target

GitHub's default is `Dev-<full-branch-name>`; Azure DevOps uses
`Dev-<Build.SourceBranchName>`, the last path component. For `feature/customer-import`,
these are `Dev-feature/customer-import` and `Dev-customer-import` respectively. Check
all matching credentials/groups and avoid Azure DevOps branches with duplicate leaf names.

EXPORT writes directly to the selected branch. A protected branch or concurrent push
can reject its commit after the Dataverse solution version has already changed. Inspect
both source and environment state; do not force-push over someone else's changes.

IMPORT uses source from the selected branch; it does not retrieve a numbered release or
merge unsaved maker work. See [branching](branching-strategies.md), [EXPORT](exporting-changes.md),
and [IMPORT](importing-changes.md).

## GitHub BUILD Or DEPLOY Did Not Trigger

- A push using `GITHUB_TOKEN` does not normally trigger another push workflow. EXPORT sends a repository-dispatch event explicitly after it pushes changes.
- Dispatch-driven workflows must be present on the default branch. Check the dispatch event token, payload branch/SHA, branch conditions, and action `trigger-branch` together.
- In manual gate-tag mode, start each deployment stage manually with the **same exact build** and a named target. This is not an automatic chain.
- A later manually selected job must use a status-aware condition such as the supplied `!cancelled()` guard; otherwise skipped dependencies can suppress it.
- A missing predecessor gate means that build has not completed the required prior target. Do not create a tag to bypass that check.

Check job permissions against the [action contracts](../config/pipelines.md) and compare
custom callers with the supplied [deployment caller](../../copy-to-your-repo/.github/workflows/DEPLOY-main.yml).

## Packaging, Hooks, Or Checker Failure

| Symptom | Check |
| --- | --- |
| Solution source folder is missing | Run EXPORT first and match `solutions[].name` to the Dataverse unique name, not the display name. |
| Asset or deployment hook is missing | Include it in `assets`; a hook path alone does not copy it into the build. Use `$PSScriptRoot` or `Context.BaseDirectory` deliberately. |
| Module/PAC installation fails | Check access to package feeds, requested versions, runner compatibility, and the artifact's dependency lock. A cache is an optimization, not an offline guarantee. |
| Checker fails | Read `solution-check-report`, `summary.md`, per-solution logs, and the aggregate JSON. Check authentication, rule/region settings, exclusions, and `failThreshold`. |
| A hook behaves differently in BUILD validation or IMPORT | Both run deployment hooks. Check `Context.HookType`, supplied operation context, target identity, and idempotence. |

> [!IMPORTANT]
> Fix source/configuration and build a new package. Do not silently alter an already
> promoted Release asset or treat a failed build's diagnostic artifact as a valid release.

## Solution Import, Upgrade, Or Process Activation

| Symptom | Check before retrying |
| --- | --- |
| Same-version import skipped | Compare source/package and installed versions. A redeploy still runs surrounding hooks; it does not force the package to import again. |
| Missing solution dependency | Order configured solutions with dependencies first and provision required external/first-party dependencies. |
| Pending/holding solution or conflicting import | Check Dataverse solution history and active operations. Determine whether staging or upgrade completed before taking recovery action. |
| Timeout or cancellation | The server-side import may still be running. Raising a timeout does not make concurrent retries safe. |
| Process owner not found or activation fails | Verify `DataverseServiceAccountUpn` or the solution's custom owner key, enabled user, roles/licenses, and access to target connections. |
| Connection reference or environment value is wrong | Check logical/schema names, actual target connection IDs, secret delivery, and whether import was skipped. Configuration does not create connections. |
| Migration cannot find an old component | Single-solution `Auto` import can upgrade before `dataMigrations`. Plan a separate migration release when both old and new schema are needed. |

> [!WARNING]
> Retry only after the previous Dataverse operation has finished and the target state
> is understood. Inspect hook side effects as well as solution history. An older package
> is not a guaranteed reversal of upgrades or data changes;
> see [recovery](deploying.md#retry-redeploy-and-recovery).

## Missing Build Or Baseline

Use the exact successful BUILD identity and correct branch. GitHub DEPLOY prefers
Release assets and can fall back to a retained Actions artifact. Azure DevOps uses the
selected pipeline artifact. An identity tag alone is not a downloadable package.

> [!NOTE]
> **Advanced: baseline pointers.** For `buildValidation.baselineRelease = '@PROD'`, inspect
> the annotated `deployed/PROD` pointer. No pointer means candidate-only validation with
> a warning. A pointer to an unavailable/invalid build is a different failure: restore
> the required artifact/Release or intentionally update the baseline configuration.

GitHub cleanup protects active annotated deployment Release pointers, but fixed old
baselines can age out. GitHub baseline validation needs the Release asset, not just its
metadata tag. Azure DevOps retention is separate. Review [retention](building-releases.md#github-release-cleanup)
before changing or deleting deployment pointers.

## Reporting A Reproducible Problem

Include the ALM4Dataverse ref, runner OS/PowerShell version, operation, exact error,
sanitized configuration, and whether the same source/build worked previously. Describe
target state without sharing secrets or sensitive data. Distinguish an offline syntax
check from a real hosted pipeline or Dataverse reproduction.
