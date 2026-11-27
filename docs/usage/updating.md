# Updating And Customizing ALM4Dataverse

Treat shared automation as a versioned dependency. Test updates with representative
solutions, data hooks, and authentication before rolling them out across applications.

## Understand What Is Pinned

| Item | When it is selected | Effect of an update |
| --- | --- | --- |
| Shared actions/templates/scripts | Caller reference or shared repository resource | Changes future operations/builds. |
| Application configuration, solution source, and assets | Source commit selected for BUILD | Included in that new build's package. |
| Deployment scripts/defaults and dependency lock | Copied/generated during BUILD | Remain inside existing artifacts after shared code changes. |
| Target credentials, connections, and values | Deployment runtime | Can change the effect of deploying an unchanged package. |
| Hosted runner and external services | Runtime | Not frozen by the artifact. |

> [!TIP]
> Pin an immutable commit SHA for the strongest reproducibility, or a controlled version
> tag according to your policy. `main`, `stable`, and the latest setup download can change.
> Record the tested ref rather than assuming all consumers update together.

## Update An Application

1. Record the current shared ref, successful production build identities, target settings, and required backups. Retain artifacts needed for recovery/baseline validation.
2. Review the [upgrade notes](upgrade-notes.md) and upstream [release notes](https://github.com/ALM4Dataverse/ALM4Dataverse/releases), and compare changed caller files, default settings, action/template inputs, and hook behavior.
3. Update shared references and any required caller/configuration changes on a reviewable application branch.
4. Run EXPORT/IMPORT only against intended development targets. BUILD a new package and exercise checker/baseline validation where configured.
5. Deploy the exact new build to a representative non-production target. Verify upgrades, data changes, connections, ownership, and a repeated deployment.
6. Promote that same build through normal controls, then roll out the shared update to other consumers.

> [!IMPORTANT]
> Updating the caller or shared repository does not patch old Release assets. Existing
> artifacts still run their packaged deployment scripts. Rebuild to include a deployment-code
> fix, and distinguish reverting automation source from recovering Dataverse solution/data state.
>
> A newer DEPLOY template may require a helper that an older artifact does not contain.
> The template checks for the packaged helper and gives a rebuild instruction instead of
> silently loading a helper from a different shared-code version.

### GitHub Actions

Review every remote action/workflow `uses:` reference, including BUILD, EXPORT, IMPORT,
each DEPLOY job, and the reusable cleanup workflow. Keep those references consistent
with the code source you intend future builds to package; see [action contracts](../config/pipelines.md).
GitHub requires a literal ref in `uses:`, not a runtime expression.

For a fork, change the action/workflow owner consistently. Your shared workflow repository
can [track upstream releases](#track-upstream-releases) and open a pull request for each
new one. Ensure dispatch-driven
caller definitions exist on the default branch. Review
permissions, job environments, OIDC subjects, selected secret mappings, and promotion
conditions when adopting newer callers.

### Azure DevOps

Fetch and review upstream changes in the shared Azure Repos repository, then merge them
through your normal review process, or let the shared repository
[track upstream releases](#track-upstream-releases) and open that pull request for you.
Update an application's repository resource `ref`
if it pins a different branch/tag. Preserve the alias `ALM4Dataverse` used by templates.

Compare copied callers as well as shared templates: build pipeline resource paths,
branch filters, stage lists, extension mode, variable-group declarations, and explicitly
mapped secrets may require coordinated updates. Existing pipeline/resource permissions
and approval checks are not replaced by updating Git files.

## Track Upstream Releases

Every shared repository that setup creates is a copy of an upstream GitHub repository:
a GitHub fork or private copy, or an imported Azure Repos repository. It contains
automation that opens a pull request merging each new upstream release into it, so you
review updates instead of fetching them by hand. It is off until you enable it.

| Shared repository on | Automation | Enable it by |
| --- | --- | --- |
| GitHub | [Track Upstream Release workflow](../../.github/workflows/track-upstream-release.yml) | Setting the repository variable `UPSTREAM_TRACKING_ENABLED` to `true`; see [GitHub](#github-shared-repository). |
| Azure Repos | [Track Upstream Release pipeline](../../pipelines/maintenance/track-upstream-release.yml) | Creating a pipeline from that file; see [Azure DevOps](#azure-devops-shared-repository). |

Both run daily at **03:30 UTC** and on demand. The upstream defaults to
`ALM4Dataverse/ALM4Dataverse`; set `UPSTREAM_REPOSITORY` when your shared repository was
created from another fork, such as your organization's. The upstream can be public or
private.

What a run does:

1. Lists the upstream's GitHub releases and picks the newest. Drafts are ignored;
   prereleases count only when you enable them.
2. Works out which release your shared repository already contains, from
   `.github/upstream-release.json` or from upstream release tags in its history.
3. Merges the new release into a branch named after it, `update/upstream-release/<tag>`,
   and opens a pull request. Its description lists the release notes, the files where
   your repository differs from the release, and a checklist for the
   [fork difference audit](../../AGENTS.md#fork-difference-audit).
4. When the merge conflicts, still opens the pull request, as a draft, with the conflict
   markers committed and the conflicted files listed. Resolve them with your platform's
   conflict tools or a local checkout, then mark the pull request ready.

Each release gets its own pull request, and the automation never changes a pull request
after opening it. When a newer release is proposed, each older update pull request is:

- **Closed, and its branch deleted,** when nobody has worked on it.
- **Left open, with a comment linking the new pull request,** when anyone has pushed to
  its branch (including amended or force-pushed commits), edited its title or description,
  commented on it or reviewed it (on Azure DevOps, voted on it), even while the run that
  replaces it is in progress. Work done by the Copilot coding agent counts too. Merge it
  first, or close it when you no longer need it.

A scheduled run never proposes an older release than an open pull request does, for
example the newest stable release after you requested a prerelease. Closing a pull
request without merging declines that release; the next newer release opens a new one.
If you retarget an update pull request to another branch, the run stops rather than
reusing its branch; merge, close or retarget it back first.

> [!NOTE]
> When your repository has neither, for example because earlier updates were
> squash-merged, the first run fails and lists what it checked and the recent upstream
> releases. Run it once manually with `current-tag` (Azure Pipelines: `currentTag`) set to
> the release your repository contains. Merging the resulting pull request records the
> release in `.github/upstream-release.json`, so later runs need no input. If that release
> is already the newest, the pull request only adds that file.

Run it manually to override the defaults:

| Run input (GitHub / Azure Pipelines) | Effect |
| --- | --- |
| `target-tag` / `targetTag` | Merge this release instead of the newest one, including a prerelease or a declined release. |
| `current-tag` / `currentTag` | Release your repository already contains; only needed when the run cannot detect it. An open pull request for the same release built from another release is replaced, unless people worked on it. |
| `include-prereleases` / `includePrereleases` | `true` or `false` overrides the repository or pipeline setting for this run. |
| `dry-run` / `dryRun` | Report what would happen without pushing or changing pull requests. |

> [!IMPORTANT]
> Merging the pull request updates the shared code that application builds use, according
> to how each application pins it. Test it as described in
> [update an application](#update-an-application) before relying on it.

### GitHub Shared Repository

Set the repository variable `UPSTREAM_TRACKING_ENABLED` to `true`. GitHub disables
scheduled workflows in a new fork until you enable Actions in its **Actions** tab. The
workflow does nothing in the upstream repository itself.

| Setting | Kind | Purpose |
| --- | --- | --- |
| `UPSTREAM_REPOSITORY` | Variable | Upstream `owner/name`. Default `ALM4Dataverse/ALM4Dataverse`. |
| `UPSTREAM_BASE_BRANCH` | Variable | Branch the pull request targets. Default: the repository's default branch. |
| `UPSTREAM_INCLUDE_PRERELEASES` | Variable | `true` to consider prereleases on scheduled runs. |
| `UPSTREAM_TRACKING_APP_CLIENT_ID`, `UPSTREAM_TRACKING_APP_PRIVATE_KEY` | Variable, secret | Recommended. A GitHub App installed on the repository with read and write access to contents, issues, pull requests and workflows. |
| `UPSTREAM_TRACKING_TOKEN` | Secret | Alternative to the App: a fine-grained personal access token with the same permissions. |
| `UPSTREAM_REPOSITORY_PRIVATE` | Variable | `true` when the upstream is private and the App is also installed on it with contents read access. |
| `UPSTREAM_READ_TOKEN` | Secret | Alternative for a private upstream: a token with contents read access to it. |
| `UPSTREAM_TRACKING_ASSIGN_COPILOT`, `UPSTREAM_TRACKING_COPILOT_TOKEN` | Variable, secret | Optional. With `true`, each new pull request gets an `@copilot` comment asking the Copilot coding agent to resolve conflicts and complete the audit. The secret is a personal access token (fine-grained: pull requests read and write) of a user with a Copilot licence and write access, because Copilot ignores mentions from apps. [Copilot Setup Steps](../../.github/workflows/copilot-setup-steps.yml) installs the validation modules so that Copilot can run the checks. |

Without an App or `UPSTREAM_TRACKING_TOKEN`, the workflow uses the built-in
`GITHUB_TOKEN`. That needs **Settings > Actions > General > Allow GitHub Actions to create
and approve pull requests**. It cannot push upstream changes to `.github/workflows`, so
such releases fail with setup guidance, and its pull requests do not start other
workflows.

### Azure DevOps Shared Repository

Create a pipeline from `pipelines/maintenance/track-upstream-release.yml` in the shared
repository. Its schedule runs on `main`; change the `branches` filter if your default
branch differs.

Grant the project's build service identity (*`<Project>` Build Service (`<Organization>`)*)
these permissions on the shared repository: **Contribute**, **Create branch**,
**Contribute to pull requests** and **Force push**. Force push lets it delete the branch
of a pull request it replaces, and replace a branch left by a failed run. The pull request
is created by that identity, so your branch policies apply to it as usual.

| Pipeline variable | Purpose |
| --- | --- |
| `UPSTREAM_REPOSITORY` | Upstream `owner/name`. Default `ALM4Dataverse/ALM4Dataverse`. |
| `UPSTREAM_BASE_BRANCH` | Branch the pull request targets. Default `main`. |
| `UPSTREAM_INCLUDE_PRERELEASES` | `true` to consider prereleases on scheduled runs. |
| `UPSTREAM_READ_TOKEN` (secret) | Required for a private upstream: a GitHub token with contents read access to it. A public upstream is read anonymously. |

Azure DevOps limits a pull-request description to 4,000 characters, so the file list and
conflicts are posted as an *Upstream release details* comment. The Copilot hand-off is not
available for Azure Repos.

## Re-Run Setup Carefully

Use a reviewed released setup script. Select existing resources deliberately, review
generated diffs, and keep custom hooks/settings under source control.

Setup checks the shared repository automatically and asks for an update strategy only
when the configured ref differs. Review that strategy before continuing, especially when
the shared repository has local changes.

Setup copies the scaffold again when it re-runs. It keeps these application files and
settings:

- `alm-config.psd1`, which is merged with your solution selection rather than replaced.
- `AGENTS.md` and everything under `data/`, which are created only when missing.
- On GitHub: `secrets-json` mappings in every workflow.
- On Azure DevOps: `secretVariables` lists in BUILD, EXPORT and IMPORT, and extra stage
  parameters for DEPLOY environments that remain selected.

Other scaffold files that differ from the release are replaced. That includes BUILD,
EXPORT and IMPORT, which setup regenerates from `alm-config.psd1` on both platforms, and
every `DEPLOY-<branch>` caller. To apply committed configuration changes, run
`setup-github.ps1 -ApplyConfig` or `setup-azdo.ps1 -ApplyConfig`, or run the APPLY-CONFIG
pipeline or workflow in the repository, which opens a pull request with the regenerated
files. On GitHub, the built-in token cannot change workflow files, so the pull request puts
them in `replace-github-workflows/`. Replace `.github/workflows` with that folder and commit,
or BUILD fails; see [apply configuration](../config/github-secrets.md#apply-configuration).

> [!CAUTION]
> Setup is not a generic merge tool for arbitrary customization. If interrupted, inspect
> resources and commits already created before retrying.

## Choose The Smallest Extension Point

- **Application configuration:** solution order/options, assets, checker settings, module versions, and import timeout belong in the application data file.
- **Hooks:** use the documented lifecycle points for data or organization changes. Package deployment scripts as assets, fail clearly, and make retries safe.
- **Caller customization:** choose permissions, approvals, concurrency, and runtime secret mappings in the platform. Branches, environments and deployment targets belong in `alm-config.psd1`; setup regenerates the callers from it.
- **Shared fork:** change reusable behavior only when configuration/hooks are insufficient, and regression-test all affected consumers.

> [!NOTE]
> **Advanced: shared fork defaults.** A fork can set defaults for every consuming
> application in [alm-config-defaults.psd1](../../alm-config-defaults.psd1), including
> shared hooks referenced with `[alm]`. See
> [fork configuration](../config/alm-config.md#advanced---fork-configuration) for the
> merge rules.

## Rotate Credentials And Review Access

Rotate client secrets before expiry and update the appropriate platform secret/service
connection. Verify a non-production run before removing the old credential. WIF removes
the client secret but still requires correct trust, application-user roles, and periodic
access review. Branch/environment renames may require updated OIDC subjects and callers.

Do not rebuild solely to rotate a runtime credential, and never add that credential to
the artifact. Review process-owner accounts, connection access, approvals, tag-write
permissions, and artifact retention alongside authentication.

Maintaining a shared fork or publishing setup assets? Use the [maintainer guide](../maintainers.md).
