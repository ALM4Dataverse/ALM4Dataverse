# Building Releases

```mermaid
flowchart LR
    A[Repository Branch<br/>&lt;branchname&gt;] --> B[BUILD Pipeline]
    B --> C[Deployment artifacts]
    B --> D[GitHub only: Release assets]
    B -. Optional deployment validation .-> E[Dataverse validation environment]

    style A fill:#e1f5fe
    style C fill:#f3e5f5
    style D fill:#f3e5f5
    style E fill:#f3e5f5
    style B fill:#fff3e0
```

The `BUILD` pipeline collates a numbered release by extracting and building the assets required to deploy from source control. This can then be used later to deploy to any number of environments using the exact same, unchanged assets. When configured, BUILD also deploys its generated artifacts to a Dataverse validation environment, exercising the deployment process before promotion. BUILD can additionally run PAC Solution Checker against packed solutions.

## SemVer BUILD versions

The shared configuration defaults `buildVersion.default` to `1.0`. Override
that default or add full branch-name overrides in `alm-config.psd1` when
branches need distinct version lines. See
[BUILD SemVer configuration](../config/alm-config.md#build-semver) for details.

> [!NOTE]
> **Advanced: version and artifact identity.** BUILD uses the CI run number as
> PATCH and the normalized branch name as the prerelease identifier; for example,
> `2.1.42-main` or `1.0.43-feat-abc` for `feat/abc`. Slashes and other branch
> punctuation become hyphens. The repository name remains in the displayed run
> name, not in the SemVer version. All BUILD versions and source tags retain
> this branch suffix; there is no stable build promotion workflow or pipeline.
>
> Every successful BUILD artifact includes `build-version.json`, which records
> the version, source branch and commit, provider, and exact run ID. DEPLOY and
> baseline validation consume the selected successful BUILD and its exact
> provider-specific artifacts; they do not change or rebuild the package.

## Prerequisites And Outputs

Run [EXPORT](exporting-changes.md) first if configured solution folders are not yet in source control. The `solutions` order must satisfy dependencies; configured asset paths must exist. Package-only BUILD does not require a Dataverse target, but Solution Checker and connected hooks need a suitable authenticated identity.

| Platform | Build output | How DEPLOY selects it |
| --- | --- | --- |
| Azure DevOps | Pipeline artifact `artifacts`, optional `solution-check-report`, SemVer prerelease source tag, and `build-version.json` | The `build` pipeline resource, selected automatically or through **Run pipeline > Resources** |
| GitHub Actions | Actions artifacts, successful BUILD prerelease assets, SemVer source tag, and `build-version.json` | Exact Release tag, BUILD name, or numeric BUILD run ID; latest-successful selection is also available |

> [!NOTE]
> The build/run identity is not the same as a solution version. Multiple solutions in one
> build can have different versions, and several builds may reference one source commit.
> Use the exact build identity when deploying or selecting a baseline.

On GitHub Actions, each successful branch BUILD publishes the same separate
deployment archives as both Actions artifacts and GitHub prerelease assets:

- `artifacts.zip` — the deployment artifacts, including solutions, configured
  assets, scripts, configuration, and dependency locks.
- `solution-check-report.zip` — published when a solution-check report exists.

The prerelease assets and Actions artifacts contain the same deployment package.
Both retain the branch-suffixed BUILD tag and version.

The `BUILD` job triggers automatically when any changes are made in the associated repo, including when `EXPORT` completes (unless no changes were found). The copied GitHub workflow and Azure Pipeline trigger on pushes to branches; setting a repository's PR or branch policy to require successful validation is a separate configuration step.

GitHub EXPORT explicitly dispatches BUILD with the exported branch and SHA. Repository-dispatch definitions must exist on the default branch. To build manually, select BUILD in **Actions > Run workflow** on GitHub or **Pipelines > BUILD > Run pipeline** in Azure DevOps, then select the intended branch.

### Artifact Layout

```text
artifacts/
  alm-config.psd1
  build-version.json
  scriptDependencies.lock.json
  solutions/
    ContosoCore.zip
    ContosoCore_managed.zip
  alm/
    alm-config-defaults.psd1
    pipelines/scripts/
  data/
  solution-check/
```

The `data` directory represents configured assets; it is not mandatory. `solution-check`
exists only when checks generate reports.

> [!NOTE]
> **Advanced: packaged tooling.** The `alm` directory snapshots the shared repository,
> including its deployment scripts/defaults. The lock records the exact loaded PowerShell
> module versions and installed PAC version. Deployment uses these packaged scripts,
> settings, and versions instead of rebuilding source or using newer deployment scripts.
> Target-specific credentials/settings are still supplied at runtime.

Treat artifacts as executable deployment content: they include hooks and scripts.
Limit write access and never package secret values or sensitive data inadvertently.

## BUILD validation

BUILD validation has two optional parts: deploying the generated solution
packages to a Dataverse environment, and statically analyzing those packages
with PAC Solution Checker.

### Dataverse validation environment

This is a configured Dataverse environment that BUILD connects to using its
configured service connection or GitHub environment credentials. BUILD first
authenticates and calls `WhoAmI` to confirm access. After generating the
deployment artifacts, it runs the normal deployment script from those
artifacts against the validation environment. This imports the packaged
solutions using the configured deployment and upgrade behavior and runs
configured deployment hooks. A failure to import, upgrade, or complete a hook
fails the BUILD run.

Automated setup can configure one shared validation environment for generated
BUILD pipelines/workflows, so builds from different branches deploy to that
same environment. It is separate from each branch's `Dev-<branchname>`
environment and from the environments in `DEPLOY-<branchname>`.

> [!CAUTION]
> Choose a non-production target that is safe to update repeatedly. BUILD does not reset
> it: solutions and hooks can change target state, and concurrent builds can interfere.
> Serialize builds or use separate validation targets. A baseline deployment does not
> restore a snapshot or guarantee a downgrade; keep the target compatible with the
> intended upgrade path and refresh it deliberately when needed.
>
> Successful validation proves deployment completed, not that end-user behavior is correct.

Automated setup wires the validation environment into BUILD. For manual
configuration, Azure DevOps uses the `buildEnvironmentName` parameter in
`pipelines/BUILD.yml`, with a matching Power Platform service connection and
`Environment-<name>` variable group. GitHub Actions uses the same name for the
BUILD job's GitHub `environment` and the action's `environment-name` input.
The credentials and deployment settings must be available to that job. See
[Azure DevOps setup](../setup/azdo-manual-setup.md) and
[GitHub setup](../setup/github-setup.md).

### Optional baseline release

BUILD validation can deploy a previously successful BUILD package before the
candidate package. This is useful when the validation environment needs the
same installed-solution baseline that a target environment currently has.
Both packages are deployed with the normal deployment process and their own
packaged configuration. If a configured `@environment-name` has no successful
deployment pointer yet, BUILD warns and validates only the candidate. Other
baseline resolution, download, or deployment failures fail BUILD before the
candidate is deployed.

Configure `buildValidation.baselineRelease` in `alm-config.psd1`:

- Leave it empty to deploy only the current candidate.
- Use `@<environment-name>` to resolve the most recently successfully
  deployed BUILD run recorded for that deployment environment.
- Use a fixed build identifier: an Azure DevOps BUILD run ID or build number;
  or a GitHub BUILD run ID or GitHub Release tag. GitHub resolves a run ID to
  its Release and downloads the durable `artifacts.zip` asset, not the
  expiring Actions artifact.

Automated setup asks for a baseline source deployment environment separately
from the Dataverse validation target. It also offers a no-baseline choice.
On initial use, the selected source may not yet have a successful deployment;
the first BUILD then warns and deploys only the candidate. After a successful
`DEPLOY` to the source, subsequent builds use that deployed version as the
baseline. Do not select the BUILD validation target as the baseline source:
BUILD does not update deployment pointers when it writes to its validation
environment.

> [!NOTE]
> **Advanced: older deployment pointers.** For environments deployed before build-ID
> pointers were introduced, the resolver uses the existing source-commit pointer to find
> a unique successful build. If more than one successful build matches that commit,
> configure a fixed build identifier to avoid guessing which package was deployed.

GitHub release cleanup keeps Releases referenced by active deployment pointers,
so their packaged baseline assets remain available. A fixed GitHub baseline
Release must also be retained (cleanup may remove an old Release that is no
longer an active deployment). Azure DevOps baseline artifacts must be retained
by the project’s pipeline retention policy. If the referenced Release or
pipeline artifact has been removed, BUILD fails with a resolution/download
error; choose a retained baseline or adjust retention.

### PAC Solution Checker

When `solutionCheck.enabled` is `$true` globally or for an individual
solution, BUILD runs `pac solution check` against that solution's packed
solution zip before deploying. This is a static solution-quality check; it
reports rule findings and does not replace deployment validation or run
functional tests in an environment. If the checker fails its threshold, BUILD
fails and the validation deployment does not proceed.

`solutionCheck.failThreshold` determines the severity at which findings (or
higher) cause BUILD to fail (default: `Critical`), and
`solutionCheck.maxParallel` limits how many solution checks run concurrently (default: `4`). The checker
uses the runner's non-interactive Azure identity context. A Dataverse
deployment validation environment is optional for PAC Solution Checker if that
identity context is otherwise available. See [Solution Check configuration](../config/alm-config.md#solution-check-pac-solution-check)
for configuration examples, settings, authentication behavior, and reports.

To monitor:

**Azure DevOps:**

1) Navigate to the **Pipelines** area of your AzDO project.
2) Select the **All** tab and navigate to the folder with the same name as your repo. (If you only have one repo, this will be the same as your project name by default.)
3) Select the `BUILD` pipeline and then select an instance of the job.
4) The view will switch automatically to show progress. Wait until it is shown as successful.

**GitHub Actions:**

1) Navigate to the **Actions** tab of your repository.
2) Select the **BUILD** workflow from the left panel.
3) Select the running workflow run. Wait until it is shown as successful (green checkmark).
4) Open the repository's **Releases** page and find the Release for the build tag.

What happens:

- Solutions are packed from `solutions/<unique-name>` into both managed and unmanaged packages through the Dataverse PowerShell module/PAC tooling.
- The optional PAC Solution Checker and Dataverse deployment validation run as described in [BUILD validation](#build-validation).
- If you've configured any hook extensions in `alm-config.psd1`, these will be executed and can add to the build steps and the assets.
- Any additional paths configured in `assets` will be copied to the build assets.
- The configuration, shared scripts/defaults, and dependency lock are copied to the build assets. Runner images, external services, and runtime environment settings are not frozen by this snapshot.

The BUILD result is useful as a merge gate: a failed build or enabled solution check marks that branch's build as failed. ALM4Dataverse does not automatically add branch protection or PR policies. Configure those in your source-control platform if a PR must not merge until validation succeeds:

- **Azure DevOps**: add a **Build validation** branch policy for the target branch and select the BUILD pipeline.
- **GitHub**: add the BUILD status check to the target branch's ruleset or branch protection required checks. The copied BUILD workflow is triggered by pushes, not by `pull_request`; it checks the pushed branch commit. If policy requires validation of the generated PR merge result, configure a PR-triggered workflow or merge-queue validation separately.

Solution check report outputs:

- In build artifacts under `solution-check/`
  - `summary.md`
  - `solution-check-summary.json`
  - per-solution PAC logs/output
- As a dedicated CI artifact named `solution-check-report` for quick access from pipeline/workflow results.

If checks fail, the logs clearly state which solution breached the configured threshold and what the highest severity was.

What to do next:

- Check the run result, enabled validation results, and reports before promoting.
- GitHub DEPLOY prefers Release assets with Actions-artifact fallback; Azure DevOps DEPLOY uses the selected pipeline artifact. See [Deploying](deploying.md).
- Failed GitHub builds may upload partial artifacts for diagnosis. Do not use them as successful release packages.

## GitHub Release cleanup

The copied CLEANUP-RELEASES workflow runs on delete events, daily at **03:17 UTC**, and
manually. Keep it on the default branch for scheduled runs. It operates only on Releases
recognized by ALM4Dataverse build metadata, not arbitrary Releases.

For existing branches it retains the newest `max-releases-per-branch` builds (default
`10`), plus Releases referenced by active annotated `deployed/<environment>` pointers.
For deleted branches it removes managed Releases except those protected by active
pointers. The count can therefore exceed the configured cap.

Before deleting a Release, cleanup creates an annotated
`alm4dataverse/metadata/<release-tag>` tag containing branch, build name, source commit,
and BUILD run ID. This metadata preserves identity, **not the deleted asset files**.
Cleanup does not delete the source version tag, the gate tags, or Actions artifacts.
Legacy lightweight environment pointers do not contain the Release-tag metadata used
by the retention protection; review older deployments before cleanup.

To change retention, adjust the caller's default or run CLEANUP-RELEASES manually with
a positive `max-releases-per-branch`.

> [!CAUTION]
> Cleanup has no dry-run input. Check which baselines and recovery builds you must retain
> first. A fixed baseline not referenced by an active pointer can still be deleted.
> GitHub baseline validation requires its Release asset; ordinary DEPLOY's Actions
> fallback only helps while that artifact remains retained. Metadata tags do not preserve
> deleted asset files.

Azure DevOps retention is controlled by project/pipeline policy, not this GitHub workflow.
Retain deployed and baseline builds explicitly where needed. On GitHub, Actions artifacts
request 90-day retention subject to platform policy; Release cleanup is a separate policy.
