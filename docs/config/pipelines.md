# Pipeline, Action, And Script Reference

Use this reference when customizing the supplied callers. For ordinary operation, follow the [usage guides](../../README.md#documentation). Solution and hook settings are in the [ALM configuration reference](alm-config.md).

## GitHub Composite Actions

The [caller workflows](../../copy-to-your-repo/.github/workflows) own triggers, jobs, runners, permissions, environment selection, timeouts, concurrency, and secret selection. The shared actions own the steps inside each job. These are composite actions invoked from `steps`, not reusable workflows invoked directly from `jobs`.

The templates reference `ALM4Dataverse/ALM4Dataverse/.github/actions/<action>@main`.
Automated setup substitutes its selected ALM4Dataverse ref.

> [!TIP]
> Pin a tested release tag or commit for controlled upgrades. Update all four action
> references and the cleanup workflow consistently. A private fork must also allow
> consuming repositories to use its actions.

### Common Inputs

| Input | Required | Default | Meaning |
| --- | --- | --- | --- |
| `vars-json` | No | `{}` | Pass `${{ toJSON(vars) }}` to supply repository and selected environment variables. |
| `secrets-json` | No | `{}` | JSON object of explicitly selected secrets mapped to runtime variable names. Use `toJSON(secrets.NAME)` for each value. |

> [!IMPORTANT]
> Action inputs do not select a GitHub job environment. For environment-scoped values,
> set `jobs.<id>.environment` as well as the action's `environment-name`, using identical
> names. See [credentials and value precedence](github-secrets.md).

### Build

Source: [build action](../../.github/actions/build/action.yml).

| Input | Required | Default | Meaning |
| --- | --- | --- | --- |
| `build-name` | Yes | None | Repository-prefixed display name retained for run selection; SemVer tags are resolved separately from `alm-config.psd1`. |
| `source-ref` | No | `''` | Checkout ref or commit; empty uses `github.sha`. Dispatch callers pass the exported commit SHA. |
| `source-branch` | No | `''` | Source branch recorded for Release metadata and deployment dispatch. Custom callers should supply it explicitly. |
| `environment-name` | No | `''` | Nonempty enables authentication and baseline/candidate deployment validation. |

Outputs: `run-id` (numeric Actions run ID), `run-name` (the supplied display name), `build-version` (branch-suffixed SemVer), `release-tag` (the same suffixed version as a source tag), and `release-url`.

Build artifacts are uploaded as `artifacts` and, when present, `solution-check-report`, with a requested 90-day retention. Upload steps run even after failure to aid diagnosis; partial artifacts from a failed run are not a deployable release. Successful builds publish `artifacts.zip` and optionally `solution-check-report.zip` as prerelease assets, then send a branch-scoped deployment dispatch. See [building releases](../usage/building-releases.md).

### Export

Source: [export action](../../.github/actions/export/action.yml).

| Input | Required | Default | Meaning |
| --- | --- | --- | --- |
| `commit-message` | Yes | None | Message for the commit containing exported changes. |
| `environment-name` | No | `''` | Credential/value environment; empty resolves to `Dev-<github.ref_name>`. |
| `dev-environment-label` | No | `''` | Label passed to the script and export hook context; empty resolves to `Dev-<github.ref_name>`. Does not select a Dataverse URL. |

Outputs: `pushed` (`true` or `false`) and `pushed-sha` (the new commit SHA, empty when nothing was committed).

The action commits all working-tree changes, pushes to the selected branch, and sends `alm4dataverse-export-build` through `repository_dispatch` only when it created a commit.

> [!NOTE]
> **Advanced: solution version reservations.** Changed solutions reserve their
> versions with non-force-pushed tags under `alm4dv/solution-version/`. The
> GitHub token therefore needs `contents: write`. The target BUILD workflow
> must be present on the repository's default branch. Configure an optional
> `WORKFLOW_DISPATCH_TOKEN` through `secrets-json` only when repository policy
> requires a separate token.

### Import

Source: [import action](../../.github/actions/import/action.yml).

| Input | Required | Default | Meaning |
| --- | --- | --- | --- |
| `environment-name` | No | `''` | Credential/value environment; empty resolves to `Dev-<github.ref_name>`. |

No action outputs. Imports a fresh build of the selected source as unmanaged solutions. Build hooks, enabled checker rules, and deployment hooks run. It does not publish a BUILD Release or advance a deployment pointer.

### Deploy

Source: [deploy action](../../.github/actions/deploy/action.yml).

| Input | Required | Default | Meaning |
| --- | --- | --- | --- |
| `environment-name` | Yes | None | Target credential/value environment and deployment identity. |
| `previous-environment-name` | No | `''` | Predecessor environment for manual promotion's same-build gate. Empty means first stage. |
| `promotion-mode` | No | `manual-gate-tag` | `manual-gate-tag` or `environment-approval`. The copied caller explicitly selects `environment-approval`. |
| `trigger-branch` | No | `''` | Branch owned by this deployment workflow. Set it explicitly on every stage. |
| `github-context-json` | Yes | None | Pass `${{ toJSON(github) }}` unchanged. |
| `caller-inputs-json` | Yes | None | Pass `${{ toJSON(inputs) }}` unchanged. |

No action outputs. Build selection comes from the caller's `build-run-name` and `target-environment` dispatch inputs, or the automatic dispatch payload. Do not invent additional action inputs with these names.

The selector accepts a Release tag, exact BUILD name, or numeric BUILD run ID; blank selects the latest successful BUILD from the selected branch. It validates branch/build identity, prefers Release assets, and can fall back to retained Actions artifacts. See [deployment modes and recovery](../usage/deploying.md).

### Caller Settings And Permissions

| Caller | Trigger | Declared token permissions |
| --- | --- | --- |
| `BUILD` | Branch pushes, manual dispatch, export dispatch | `contents: write`, `actions: write`, `id-token: write` |
| `EXPORT` | Manual dispatch with commit message | `contents: write`, `actions: write`, `id-token: write` |
| `IMPORT` | Manual dispatch | `contents: read`, `id-token: write` |
| `DEPLOY-<branch>` | Manual dispatch and, in approval mode, branch-scoped build dispatch | `contents: write`, `actions: read`, `id-token: write` |
| `CLEANUP-RELEASES` | Delete events, daily at 03:17 UTC, manual dispatch | `contents: write` |

`id-token: write` permits OIDC authentication; it does not grant Dataverse permissions. `contents: write` supports commits, dispatches, Releases, and/or deployment tags depending on the caller. Grant only what each job needs, subject to organization policy.

Shipped action callers run on `ubuntu-latest` with `timeout-minutes: 360`.

> [!CAUTION]
> The deployment caller uses a concurrency group per environment with
> `cancel-in-progress: true`: a newer run can cancel an earlier job without necessarily
> stopping its Dataverse import. Review this policy for long-running production
> deployments; approval and concurrency are separate controls.

The cleanup caller invokes a **reusable workflow**, unlike the four actions. Its `max-releases-per-branch` number input defaults to `10`. Use a positive retention count; the caller's expression treats zero as the default. Active deployment-pointer Releases may be retained beyond the cap. See [cleanup behavior](../usage/building-releases.md#github-release-cleanup).

## Azure DevOps Templates

The [caller pipelines](../../copy-to-your-repo/pipelines) declare the shared repository resource using the alias `ALM4Dataverse`. Keep this alias because templates also check it out by name. They run PowerShell 7 on `windows-2022` and request 360-minute jobs, subject to your hosted capacity limit.

| Template | Parameter | Type | Default | Meaning |
| --- | --- | --- | --- | --- |
| [build](../../pipelines/templates/build.yml) | `buildEnvironmentName` | String | `''` | Nonempty selects a validation service connection and `Environment-<name>` variable group. |
| build | `useAlm4DataverseExtension` | Boolean | `true` | Use the ALM4Dataverse connection-variable task. |
| [export](../../pipelines/templates/export.yml) | `commitMessage` | String | Required | Commit message for exported changes. |
| export | `useAlm4DataverseExtension` | Boolean | `true` | Connection-variable task selection. |
| [import](../../pipelines/templates/import.yml) | `useAlm4DataverseExtension` | Boolean | `true` | Connection-variable task selection. |
| [deploy stage](../../pipelines/templates/stages/deploy-environment.yml) | `environmentName` | String | Required | Service connection, Azure DevOps environment, and `Environment-<name>` variable group. |
| deploy stage | `useAlm4DataverseExtension` | Boolean | `true` | Connection-variable task selection. |
| deploy stage | `timeoutInMinutes` | Number | `360` | Deployment job timeout in minutes. |

With `useAlm4DataverseExtension: false`, the Microsoft Power Platform Build Tools task is used and **client-secret authentication is required**. WIF requires the ALM4Dataverse extension. Tool installation keeps `AddToolsToPath: false` so the configured PAC version is used.

EXPORT and IMPORT resolve their development service connection from `Dev-$(Build.SourceBranchName)`. Azure DevOps's `Build.SourceBranchName` is the final branch path component: `feature/customer-import` resolves to `Dev-customer-import`, unlike GitHub's full branch name. Avoid branch-leaf collisions or customize the naming logic consistently.

DEPLOY expects a pipeline resource alias `build`, whose source names the application's BUILD pipeline, including its folder if applicable. The deployment job downloads that resource's `artifacts` and runs its packaged scripts. It updates the annotated `deployed/<environmentName>` tag after success. Grant repository tag creation and force-update permissions only to the trusted build identity and required scope.

## Setup Script Parameters

Both [setup-azdo.ps1](../../setup-azdo.ps1) and [setup-github.ps1](../../setup-github.ps1) accept:

| Parameter | Type | Default | Meaning |
| --- | --- | --- | --- |
| `TenantId` | String | Interactive selection | Constrain setup's Microsoft sign-in to a tenant. |
| `UseDeviceAuthentication` | Switch | Off | Request device-code authentication instead of the normal interactive sign-in. |
| `ALM4DataverseRef` | String | Embedded release ref | Choose the shared code ref used during setup. Repository-source scripts resolve the local branch/commit, falling back to `stable`. |

Download a released script to review it and pass parameters. For example, after reviewing the downloaded GitHub setup script:

```powershell
.\setup-github.ps1 -TenantId '00000000-0000-0000-0000-000000000001' -UseDeviceAuthentication -ALM4DataverseRef 'stable'
```

The downloadable release scripts embed their helpers and dependency versions. Raw repository-source scripts require the adjacent shared helper and defaults files; downloading just the raw script is not equivalent to downloading a Release asset. Setup is interactive and makes changes to repositories and cloud configuration, not a dry run.

## Direct PowerShell Usage

> [!NOTE]
> Direct scripts are building blocks for advanced automation. Prefer the supplied callers
> for authentication, artifacts, tagging, and promotion. Direct scripts do **not** create
> CI runs, GitHub Releases, deployment gates, or source commits.

Use PowerShell 7 with Git and a .NET SDK compatible with the selected PAC tool, access to the PowerShell Gallery/NuGet feeds, and trusted scripts. The installer uses the current directory for configuration and any lock file. Authenticate non-interactively before connected operations; `connect.ps1` uses `DefaultAzureCredential`, confirms access with `WhoAmI`, and initializes PAC authentication.

| Script | Parameters | Working directory and effect |
| --- | --- | --- |
| [installdependencies.ps1](../../pipelines/scripts/installdependencies.ps1) | None | Application or artifact root; installs/imports configured modules and PAC, honoring `scriptDependencies.lock.json` when present. |
| [connect.ps1](../../pipelines/scripts/connect.ps1) | `Url` (required string) | Authenticates to the supplied Dataverse URL using the process's Azure identity. |
| [build.ps1](../../pipelines/scripts/build.ps1) | `SourceDirectory`, `ArtifactStagingDirectory` (required strings) | Application root; packs both solution types, runs checker/build hooks, copies assets, snapshots scripts, writes dependency lock. No validation-environment deployment on its own. |
| [export.ps1](../../pipelines/scripts/export.ps1) | `SourceDirectory`, `ArtifactStagingDirectory`, `BranchName` (required); `TempDirectory`; `EnvironmentName` (default `Unknown`); `DefaultBranchName` (optional); `PassThru` (switch, off) | Application root; exports and updates source and Dataverse versions. `BranchName` is the exact source branch; `DefaultBranchName` identifies the repository default branch for the default-version warning and otherwise resolves from `origin/HEAD`. Always pass a real writable temporary directory. `EnvironmentName` is a label, not authentication. `PassThru` additionally returns elapsed seconds and package timings; it does not disable source or version updates. |
| [deploy.ps1](../../pipelines/scripts/deploy.ps1) | `ArtifactsPath` (required); `UseUnmanagedSolutions` (switch, off by default) | Artifact root; imports, upgrades, activates processes, publishes, and runs deployment hooks. |
| [import.ps1](../../pipelines/scripts/import.ps1) | `SourceDirectory`, `ArtifactStagingDirectory` (required strings) | Application root; builds and deploys unmanaged. Already requires a connection. |
| [resolvedependencycache.ps1](../../pipelines/scripts/resolvedependencycache.ps1) | `BaseDirectory` (default `.`); `AlmScriptsRoot` (default script directory) | Emits `module_cache_enabled`, `module_cache_key`, `pac_cache_enabled`, `pac_cache_key` for GitHub caching. |

For a local build, run from your application checkout with the ALM4Dataverse checkout next to it:

```powershell
$almRoot = (Resolve-Path '../ALM4Dataverse').Path
$sourceRoot = (Get-Location).Path
$artifactRoot = Join-Path ([IO.Path]::GetTempPath()) 'contoso-artifacts'
New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null

& "$almRoot/pipelines/scripts/installdependencies.ps1"
& "$almRoot/pipelines/scripts/build.ps1" -SourceDirectory $sourceRoot -ArtifactStagingDirectory $artifactRoot
```

For direct EXPORT calls, connect to the development environment first and pass
the exact branch name. Supply the repository default branch when known; otherwise
EXPORT resolves it from `origin/HEAD` for the default-version warning.

```powershell
$exportArtifacts = Join-Path ([IO.Path]::GetTempPath()) 'contoso-export-artifacts'
$exportTemp = Join-Path ([IO.Path]::GetTempPath()) 'contoso-export-temp'
New-Item -ItemType Directory -Path $exportArtifacts, $exportTemp -Force | Out-Null

& "$almRoot/pipelines/scripts/export.ps1" `
    -SourceDirectory $sourceRoot `
    -ArtifactStagingDirectory $exportArtifacts `
    -TempDirectory $exportTemp `
    -BranchName 'feature/customer-import' `
    -DefaultBranchName 'main' `
    -EnvironmentName 'Development'
```

Use a fresh artifact directory for each build. If checker rules or custom hooks require
a connection, establish one first.

> [!CAUTION]
> The local deployment example below changes Dataverse. Confirm the target and use
> the **artifact's own** scripts and dependency lock.

```powershell
Push-Location $artifactRoot
try {
    & './alm/pipelines/scripts/installdependencies.ps1'
    & './alm/pipelines/scripts/connect.ps1' -Url $env:DATAVERSE_URL
    & './alm/pipelines/scripts/deploy.ps1' -ArtifactsPath '.'
}
finally {
    Pop-Location
}
```

Supply service-account, connection-reference, and environment-variable values to the process beforehand. Never put secrets into source-controlled commands or commit build output containing sensitive hook data.
