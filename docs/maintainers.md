# Maintainer Guide

This page is for maintainers of the shared ALM4Dataverse implementation or a fork.
Application teams should start with [updating and customizing](usage/updating.md).

> [!CAUTION]
> Cloud setup, dependency-PR creation, and release publication change real resources.
> Do not run them as offline tests.

## Source Map

| Location | Responsibility |
| --- | --- |
| [Shared defaults](../alm-config-defaults.psd1) | Default module/PAC versions, import timeout, and checker settings. |
| [PowerShell runtime](../pipelines/scripts) | Configuration/hook handling, dependencies, authentication, export, build, import, and deployment. |
| [Azure DevOps templates](../pipelines/templates) | Platform authentication, jobs, artifacts, validation, and deployment pointers. |
| [GitHub actions](../.github/actions) | Composite action wrappers and their shared credential/build/promotion helpers. |
| [Application templates](../copy-to-your-repo) | Files copied or generated into consuming repositories. |
| [Azure DevOps setup](../setup-azdo.ps1), [GitHub setup](../setup-github.ps1), [shared setup helpers](../setup-common.ps1) | Interactive provisioning and caller generation. |
| [Release preparation](../prepare-release.ps1) | Generate standalone setup assets from a source checkout. |
| [Maintainer workflows](../.github/workflows) and [scripts](../.github/scripts) | Release publication, dependency updates, cleanup, and regression checks. |

> [!IMPORTANT]
> Change a contract's runtime implementation, supplied caller, setup generator, and
> [reference](config/pipelines.md) together. Preserve documentation entry paths where
> practical. Treat generated workflow expressions and YAML as executable configuration.

## Local Checks

For comment/help changes, follow the
[commenting standard](development/powershell.md#commenting-standard) and
[repository instructions](../AGENTS.md). Review generated
installers and caller templates as well as the source: prose inside embedded code
can alter emitted content even when the outer script still parses.

Use PowerShell 7.2 or newer from the repository root. YAML-related checks require `powershell-yaml`;
the documentation checker also uses `ConvertFrom-Markdown`/Markdig supplied with PowerShell.
Install the pinned validation tools from the trusted PowerShell Gallery:

```powershell
$policy = Import-PowerShellDataFile ./scripts/powershell-validation.psd1
foreach ($tool in $policy.Tools.GetEnumerator()) {
    Install-Module -Name $tool.Key -RequiredVersion $tool.Value -Repository PSGallery -Scope CurrentUser -Force
}
```

Run these checks without Dataverse or platform credentials:

```powershell
& ./scripts/Test-PowerShell.ps1
```

| Check | What it verifies | Boundary |
| --- | --- | --- |
| Workflow and pipeline validation | `actionlint` checks checked-in and setup-generated GitHub workflows; the pinned [Microsoft Azure Pipelines schema](https://github.com/microsoft/azure-pipelines-vscode/blob/9e40e814abd20917f273dd587497086f0476a563/service-schema.json) checks checked-in and setup-generated Azure pipeline YAML through Microsoft's language service. | The generic Azure schema does not include organization-specific extensions or expand templates against a live Azure DevOps organization. Known ALM4Dataverse extension tasks and inputs are allowlisted. |
| Dependency workflow | Data-file parsing, version JSON, update pattern, and branch naming. | Uses fixtures; does not query Gallery or create a PR. |
| Deployment options | Actual deployment scripts with missing, null, empty, false, and true keys under strict mode; generated/copied workflow promotion guards. | Dataverse calls are mocked; generator tests create temporary callers. |
| Environment mapping | Direct/prefixed variables, selected-secret precedence, and preservation of existing runtime values. | Synthetic process values only; no Azure login. |
| Parallel export | Concurrency limits, failures, logs, hooks, version stability and resource cleanup. | Real thread jobs with a fake Dataverse module and temporary Git repositories; no live service calls. |
| Documentation | Local files/heading links, PowerShell/YAML/JSON fenced syntax, and presence of config/action/template names in references. | Not an external-link crawler, live example execution, or semantic proof of all documented behavior. |

For a focused documentation check:

```powershell
& ./.github/scripts/test-documentation.ps1 -Paths README.md,docs/config/alm-config.md -SkipCoverage
```

Omit `-SkipCoverage` for the full reference-name check. Review editor Markdown/PowerShell
diagnostics and `git diff --check` as well. The Repository Validation workflow runs the
same shared validator on Windows and Linux. See [PowerShell development](development/powershell.md)
for suite organization, coverage gates and saved reports.

> [!TIP]
> Use `ContainsKey` before reading optional hashtable properties under strict mode.
> `PSObject.Properties.Name` does not enumerate hashtable entries. Include missing/null-key
> cases when testing optional configuration.

## Dependency Updates

The [Update Script Dependencies workflow](../.github/workflows/update-dependencies.yml)
runs daily at **02:00 UTC** and supports manual dispatch. It needs `contents: write`,
`pull-requests: write`, permission to create PRs, PowerShell Gallery access, Git, and `gh`.

1. [check-outdated-dependencies.ps1](../.github/scripts/check-outdated-dependencies.ps1) reads `scriptDependencies`, compares Gallery versions, writes `outdated-deps.json`, and sets the `has_updates` step output.
2. [update-dependency-prs.ps1](../.github/scripts/update-dependency-prs.ps1) creates or updates a dependency PR, changing the shared default module version.
3. Maintainers review upstream changes, run local checks, and test representative export/build/deploy operations before merging.

New branches use `deps/update-<lowercase-module-name>-to-<version>`. An existing matching
open dependency PR is reused, including its existing branch name.

> [!CAUTION]
> The updater rebases, commits, pushes with `--force-with-lease`, and edits PRs. Use its
> workflow/disposable checkout, not a working copy containing unrelated work. Its base is
> the current branch, with `main` fallback for `deps/*` and `copilot/*`; dispatch it on
> the intended base branch.

The checker warns if a Gallery query fails, so inspect warnings before treating a run
with no updates as a complete result. It does **not** update `pacCliVersion`, action
versions, or runner images. Review those separately and verify installer/cache/lock
behavior when changing them. Existing build artifacts retain their old locked versions.

## Prepare Standalone Setup Scripts

[prepare-release.ps1](../prepare-release.ps1) requires PowerShell 7 and accepts:

| Parameter | Required | Meaning |
| --- | --- | --- |
| `TagName` | Yes | Ref embedded into the generated setup scripts. |
| `OutputDir` | Yes | Directory for the generated Azure DevOps and GitHub setup scripts. |
| `UpstreamRepo` | No | Upstream repository URL; defaults to the public ALM4Dataverse repository. Set it for a fork. |

It embeds shared setup helpers, the release ref, upstream URL, and the setup module
version read from defaults, then checks that required placeholders were replaced.
Source scripts need adjacent helpers; the resulting release assets are standalone.

For a local preparation check, use a temporary output directory and an illustrative tag:

```powershell
$outputDirectory = Join-Path ([IO.Path]::GetTempPath()) ('alm-release-' + [guid]::NewGuid().ToString('N'))
& ./prepare-release.ps1 -TagName 'v1.2.3' -OutputDir $outputDirectory
```

> [!IMPORTANT]
> Release preparation generates files only; it does not push Git, publish a Release,
> or run setup. Parse and review the generated scripts without executing them merely
> to check syntax: setup provisions real resources.

## Publish A Shared Release

The [stable-release workflow](../.github/workflows/stable-release.yml) responds to pushed
version tags in the configured three/four-part `v` formats, such as `v1.2.3` or `v1.2.3.4`.
This publishes the shared ALM4Dataverse code and standalone setup scripts; it is separate
from branch-suffixed BUILD prereleases and does not promote a BUILD artifact.
Releasing is a deliberate remote operation:

1. Review the intended source commit, docs, compatibility changes, local checks, and non-production hosted/Dataverse test results.
2. Create and push the intended version tag through the maintainer's authorized release process.
3. The workflow prepares standalone setup scripts and force-moves `stable` to that version commit.
4. It creates/updates a non-draft, non-prerelease GitHub Release, generates setup links/notes, and uploads/replaces both setup-script assets.
5. Verify the version Release, assets, `stable` ref, and onboarding links. Communicate required caller/configuration changes.

The workflow requires `contents: write` and permission to move `stable`.

> [!CAUTION]
> Release publication moves `stable`, so consumers following it can pick up changed
> automation. Commit-pinned consumers need an explicit update. Do not move an existing
> immutable version tag as a routine correction.

The default download links use GitHub's latest Release selection; check that they expose
the intended assets after publication.

## Live Verification Boundaries

Before release, test relevant changes using intended non-production credentials on both
platforms where they affect shared behavior. Include authentication modes, source export,
managed/unmanaged imports, upgrade paths, hooks, deployment gates, retention/baselines,
and retries proportionately to the change. Validate generated caller behavior in hosted
runs as well as offline YAML checks.

Use dedicated test environments and inspect data effects. Do not run tests against
production just because a connection is available. Document any platform, plan, or
authentication mode that was not exercised.
