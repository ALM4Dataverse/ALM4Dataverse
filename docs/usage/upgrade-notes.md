# Upgrade Notes

Use this page when you move an application to a newer shared ref. It lists changes that
need action on your side. Each entry gives what you'll see if the action is missed and
what to do. Routine fixes and new optional features are in the
[release notes](https://github.com/ALM4Dataverse/ALM4Dataverse/releases); the
[update procedure](updating.md#update-an-application) explains how to roll an upgrade
out safely.

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

**You'll see:** setup opens its normal browser sign-in even though you passed the switch.

**Do this:** run setup on a workstation with a browser. The switch is still accepted so
existing commands don't fail.

### Branch Environments Must Be Configured In `alm-config.psd1`

**You'll see:** existing branch deployment and BUILD-validation settings are no longer
inferred from workflow or pipeline files. If `alm-config.psd1` has no `branches` map,
setup starts with the repository's default branch and empty environment mappings.

**Do this:** run interactive setup, configure the branch and its environments, then
commit `alm-config.psd1`. To regenerate the caller files afterward, run
`setup-github.ps1 -ApplyConfig` or `setup-azdo.ps1 -ApplyConfig` from the application
repository. See [setup metadata and branch environments](../config/alm-config.md#setup-metadata-and-branch-environments).

### Re-Running Setup Keeps More Of Your Files

Re-running setup now keeps an existing `AGENTS.md`, files under `data/` and, on Azure
DevOps, `secretVariables` lists and extra DEPLOY stage parameters. Earlier releases
overwrote them, so check whether a previous re-run removed customizations you still need.
See [re-running setup](updating.md#re-run-setup-carefully).
