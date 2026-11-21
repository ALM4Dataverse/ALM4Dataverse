# Upgrade Notes

Use this page when you move an application to a newer shared ref. It lists changes that
need action on your side. Each entry gives what you'll see if the action is missed and
what to do. Routine fixes and new optional features are in the
[release notes](https://github.com/ALM4Dataverse/ALM4Dataverse/releases); the
[update procedure](updating.md#update-an-application) explains how to roll an upgrade
out safely.

## Setup

### Azure DevOps Pipeline Names Include The Repository Name

**You'll see:** the pipelines setup creates are named `<repository>-BUILD`,
`<repository>-EXPORT`, `<repository>-IMPORT` and `<repository>-DEPLOY-<branch>`. Existing
pipelines named `BUILD`, `EXPORT`, `IMPORT` or `DEPLOY-<branch>` are renamed in place when
their repository matches, and generated DEPLOY callers reference the qualified BUILD name.
Without the qualified names, two application repositories in one project both named
`BUILD` make the DEPLOY pipeline resource ambiguous and BUILD completion no longer starts
DEPLOY.

**Do this:** run the interactive setup script once for the application repository so it
renames the existing pipelines and rewrites the DEPLOY caller's BUILD reference. Running
`-ApplyConfig` alone keeps the current BUILD reference, because that mode does not change
pipeline definitions. Check that the existing pipelines were renamed instead of
duplicated. If you created pipelines manually, rename them to include the repository
name.

### GitHub BUILD Workflow Requires Regeneration

**You'll see:** BUILD fails before any job runs with a template error such as
`The following format string references more arguments than were supplied:
{0}-{1}-{2}-{3}` when BUILD validation is disabled, which is the default. The generated
run name had four placeholders but only three values.

**Do this:** regenerate `.github/workflows/BUILD.yml` by running
`setup-github.ps1 -ApplyConfig -Commit` from the application repository, or by running the
APPLY-CONFIG workflow. The corrected generator supplies the fourth value.

### GitHub DEPLOY Selects The Requested BUILD's Source Branch

**You'll see:** a DEPLOY workflow dispatched with a numeric `build-run-name`, or a BUILD
started through `repository_dispatch` from EXPORT, fails with
`Selected BUILD branch 'main' does not match deployment branch 'develop'` even though the
selected BUILD built `develop`. The shared resolver read Release lists as one nested
array, so it missed the branch in the Release metadata and fell back to the run's
`head_branch` (`main` for dispatch runs).

**Do this:** update the application's shared workflow source to a ref that contains the
resolver fix, or re-run setup to update the shared workflow repository. No configuration
change is required.

### Caller Pipelines And Workflows Are Generated From `alm-config.psd1`

**You'll see:** BUILD, DEPLOY, EXPORT and IMPORT pipelines or workflows stop immediately
with a shared template version error: the caller file is missing the version the shared
templates expect, or carries an older one. The error names the setup script and the ref
the caller points to, and asks you to regenerate the caller. Interactive setup no longer
offers to create or edit those files by hand.

**Do this:** treat the generated caller files as read-only. Change configuration only in
`alm-config.psd1`, then regenerate the callers by running
`setup-github.ps1 -ApplyConfig` or `setup-azdo.ps1 -ApplyConfig` from the application
repository, or by running the APPLY-CONFIG pipeline or workflow that setup added to the
repository, which applies the committed `alm-config.psd1` and commits the regenerated
files. See [GitHub manual setup](../setup/github-manual-setup.md) or
[Azure DevOps manual setup](../setup/azdo-manual-setup.md).

### Setup Publishes Every Branch In One Change

**You'll see:** guided setup asks once where to publish, instead of once per branch, and
writes the workflows or pipelines for every configured branch in a single commit or pull
request. Applying committed configuration with `-ApplyConfig -Commit`, or with the
APPLY-CONFIG pipeline or workflow, commits directly to the repository's default branch.

**Do this:** when reviewing the publication, check that every configured branch appears
in the single change. To review the changes before they are committed, run the
APPLY-CONFIG pipeline or workflow with its preview option enabled (or
`-ApplyConfig -PreviewOnly` on a workstation); `-ApplyConfig -Commit` always commits
directly to the repository's default branch.

### Guided Setup Defers More Writes Until Apply

**You'll see:** shared workflow repository reconciliation, shared repository version
updates, and client-secret rotation now wait for **Apply changes**, and creating a shared
repository or Entra application asks for confirmation first. The preview marks changes
already applied during setup as **Already applied**.

**Do this:** review the preview before applying if you relied on the version step or
credential step completing immediately. Declining a creation confirmation returns to the
menu or repository-name prompt without creating anything. With `-ApplyConfig`, no
repository version changes are made.

## Configuration

### `mappingFile` And Solution-Level `buildCommands` Were Removed

**You'll see:** configuration validation fails and names the unsupported setting.

**Do this:** replace `mappingFile` with a `mappings` list on the solution, and solution-level
`buildCommands` with `buildCommand` entries on the mappings that produce the files. ALM4Dataverse
now generates the SolutionPackager mapping file itself. See
[build processing](../config/alm-config.md#build-processing).

### Mapping Support Needs A Newer Data Module

**You'll see:** BUILD or EXPORT stops early, saying a `-MappingFile` parameter is
unavailable and asking you to update the module.

**Do this:** remove any old `Rnwood.Dataverse.Data.PowerShell` pin from
`scriptDependencies`, or raise it to the version in
[`alm-config-defaults.psd1`](../../alm-config-defaults.psd1).

## Builds And Deployments

### Old Builds Lack Newer Deployment Helpers

**You'll see:** on Azure DevOps, DEPLOY fails with "The selected build artifact does not
include pipelines/scripts/connect-az.ps1".

**Do this:** run BUILD on the upgraded shared ref and deploy the new build. A build
keeps the deployment scripts it was built with, so an upgrade never changes old builds.
DEPLOY reports a missing helper instead of loading one from a different version.

### GitHub Gate Tags Were Renamed

**You'll see:** with `manual-gate-tag` promotion, a later stage refuses a build that
already passed its predecessor before the upgrade.

**Do this:** gates are now `deployed/<build-name>/<environment>`, not
`<build-name>/deployed/<environment>`. Redeploy the same build through the predecessor
stages to record the new gates, after checking that your hooks are safe to repeat. Don't
create gate tags by hand. See [deployment tags](deploying.md#deployment-tags).

### Older Environment Pointers Lack Release Metadata

**You'll see:** CLEANUP-RELEASES deletes a GitHub Release that is still deployed, because
the environment's `deployed/<environment>` pointer is an older lightweight tag without the
Release metadata that cleanup protects.

**Do this:** before the first cleanup after upgrading, redeploy the current build to each
environment (or deploy a new one) so its pointer is rewritten with the metadata. See
[GitHub Release cleanup](building-releases.md#github-release-cleanup).

## Secrets

### Azure DevOps Secrets Must Be Listed In The Caller

**You'll see:** a hook or `DataverseEnvVar_*` setting stored as a **secret** variable in
a variable group arrives empty.

**Do this:** list those variable names in the caller's `secretVariables` parameter
instead of editing the shared templates. Earlier releases had no supported way to pass
them. See
[secret values](../config/azdo-environment-variable-group.md#secret-values).

### GitHub Immutable OIDC Subjects

**You'll see:** after accepting setup's offer to enable immutable OIDC subjects, Azure
sign-in fails with a subject mismatch for a credential that setup didn't create.

**Do this:** the setting applies to the whole repository. Setup updates the credentials it
manages; update any other federated credentials that trust this repository to the
immutable format. See
[federated credential setup](../config/github-secrets.md#entra-id-federated-credential-setup).

## Setup

### `-UseDeviceAuthentication` Is Ignored

**You'll see:** setup chooses browser or device-code sign-in automatically even though
you passed the switch.

**Do this:** nothing. Setup signs in with a browser when the host can open one and shows
a device code when it cannot, such as in a Dev Container, SSH session or CI. The switch
is still accepted so existing commands don't fail.

### Branch Environments Must Be Configured In `alm-config.psd1`

**You'll see:** if `alm-config.psd1` has no `branches` map but the repository already has
DEPLOY or BUILD workflows or pipelines, interactive setup shows a notice that it has
converted those existing settings into `branches`. The branches are saved to
`alm-config.psd1` when setup completes, and the file-change review shows the diff. This
one-time conversion reads the committed workflow or pipeline files; it is the only time
setup does so. After the `branches` map is committed, those files are no longer read for
branch settings. If the conversion fails, setup says so and starts with empty branch
mappings, so you re-enter the values.

Repositories without legacy evidence start with the repository's default branch and empty
environment mappings.

**Do this:** in interactive setup, check the converted branches and environments, then
commit `alm-config.psd1`. If conversion failed, configure the branch and its environments
again, then commit the file. To regenerate the caller files afterward, run
`setup-github.ps1 -ApplyConfig` or `setup-azdo.ps1 -ApplyConfig` from the application
repository. See [setup metadata and branch environments](../config/alm-config.md#setup-metadata-and-branch-environments).

`-ApplyConfig` does not offer the branch, environment, solution, BUILD validation or OIDC
editors. To change those settings, edit and commit `alm-config.psd1`, then run
`-ApplyConfig` again to regenerate the caller files.

### Re-Running Setup Keeps More Of Your Files

Re-running setup now keeps an existing `AGENTS.md`, files under `data/` and, on Azure
DevOps, `secretVariables` lists and extra DEPLOY stage parameters. Earlier releases
overwrote them, so check whether a previous re-run removed customizations you still need.
See [re-running setup](updating.md#re-run-setup-carefully).
