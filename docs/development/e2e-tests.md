# End-to-End Tests

Two maintainer workflows run a complete EXPORT, BUILD and DEPLOY cycle against real
Dataverse environments, using the commit under test:

- [E2E GitHub Actions](../../.github/workflows/e2e-github.yml) drives a dedicated GitHub test application.
- [E2E Azure DevOps](../../.github/workflows/e2e-azdo.yml) drives a dedicated Azure DevOps test project.

Both run from **Actions > Run workflow**, and on pull requests from branches in this
repository that change runtime, template, setup or E2E files. Pull requests from forks
are skipped because they receive no environment secrets.

> [!CAUTION]
> Each run rewrites the test application's `main` branch, changes the Dev and Test
> environments and cancels any other run in the test applications. Use only dedicated,
> non-production resources.

## What A Run Does

1. Waits until neither test application has an active run.
2. Refreshes the shared code:
   - The GitHub test application uses this repository's shared actions, pinned to the commit under test.
   - For Azure DevOps, the commit under test is force-pushed to `main` of the project's shared `ALM4Dataverse` repository.
3. Clears the application repository and regenerates it. Every tracked file except `solutions/` is deleted; `solutions/` is kept so EXPORT compares against the previous export. The files are then regenerated from `copy-to-your-repo` using the setup scripts' own generator functions, loaded without running the wizard:
   - The callers are adapted so DEPLOY targets only `TEST-main`.
   - `alm-config.psd1` lists only the E2E solution.
4. Raises the unpacked solution version to the version in Dev when it is lower. Both applications share Dev and Test, and Dev holds the latest exported version. Without this step, an application that is behind would deploy a version lower than the one already in Test.
5. Commits and pushes with skip-CI markers, so the refresh itself does not start BUILD.
6. Writes a unique marker to the default value of an environment variable definition in Dev.
7. Starts EXPORT, then follows the BUILD that EXPORT's commit starts and the DEPLOY that BUILD starts. A failed stage fails the run and links to the child run.
8. Passes only when the marker's default value in Test matches.

Test is never reset, so every run exercises the managed upgrade path.

## Shared Environment Lock

There is one Dev and one Test environment for both platforms, so only one cycle may use
them at a time:

- Both workflows' jobs use the concurrency group `alm4dataverse-e2e-dataverse`, with `cancel-in-progress: false`. A running cycle is never cancelled to make room for another one.
- At start-up a run also waits until both test applications are idle. This covers manual runs in the test applications and child runs left by an earlier failure.
- If a run fails, times out or is cancelled, its last step cancels every active run in its test application and waits for them to stop before the job ends and releases the lock.

> [!NOTE]
> GitHub keeps only one pending job per concurrency group. If a third run is queued
> while one runs and one waits, GitHub cancels the waiting run. Re-run it when needed.

## Required Resources

These resources must exist before the first run; the workflows don't create them.

| Resource | Requirement |
| --- | --- |
| Dataverse Dev and Test environments | One pair for both platforms. Dev contains unmanaged solution `ALM4DataverseE2E` with a text environment variable definition `alm4dv_E2EMarker`. Test should have received at least one managed deployment of it. |
| GitHub test application | A repository configured once with [GitHub setup](../setup/github-setup.md) for `main`, with `Dev-main` and `TEST-main` environments and credentials. `TEST-main` must have no protection rules, because the run cannot approve deployments. |
| Azure DevOps test project | A project configured once with [Azure DevOps setup](../setup/azdo-automated-setup.md). It contains the application repository, a shared repository named `ALM4Dataverse`, and the `EXPORT`, `BUILD`, `IMPORT` and `DEPLOY-main` pipelines in folder `\<application repository>`, with variable groups and service connections for Dev and `TEST-main`. The `TEST-main` environment must have no approval checks. |
| Exported solution source | `solutions/ALM4DataverseE2E` exists in both application repositories from an earlier export. |
| Deployment identities | The service principals used by the test applications already exist, with federated credentials and Dataverse application users in Dev and Test. |
| Orchestrator identity | An Entra ID app registration with a federated credential for this repository's `e2e` GitHub environment. It needs System Administrator in Dev and Test, and Azure DevOps organisation membership with permission to push to both project repositories (including force-push to the shared repository) and to queue and cancel pipelines. |

## Workflow Settings

Create a GitHub environment named `e2e` in this repository. Optionally require reviewers
there to control who can start a cycle.

| Variable | Value |
| --- | --- |
| `AZURE_CLIENT_ID` | Orchestrator app registration client ID. |
| `AZURE_TENANT_ID` | Entra ID tenant ID. |
| `E2E_DEV_URL` | Dev environment URL. |
| `E2E_TEST_URL` | Test environment URL. |
| `E2E_GITHUB_APP_REPO` | GitHub test application, as `owner/name`. |
| `E2E_AZDO_ORG_URL` | Azure DevOps organisation URL, for example `https://dev.azure.com/contoso`. |
| `E2E_AZDO_PROJECT` | Azure DevOps test project name. |
| `E2E_AZDO_APP_REPO` | Azure DevOps application repository name. |
| `E2E_AZDO_USE_EXTENSION` | Optional. `false` regenerates callers without the ALM4Dataverse extension tasks; default `true`. |

| Secret | Value |
| --- | --- |
| `E2E_GITHUB_TOKEN` | Fine-grained token for the GitHub test application only, with contents and actions read and write. Both workflows use it, for the idle check as well as the GitHub cycle. |

## Results And Reruns

The job summary lists each child run with its result and link, and the commit under
test. A failure message names the stage, its result and the child run URL. To retry,
re-run the E2E workflow; don't re-run a child run in the test application, because the
orchestrator will not follow it.

The scripts are [Invoke-GitHubE2E.ps1](../../.github/scripts/e2e/Invoke-GitHubE2E.ps1),
[Invoke-AzDoE2E.ps1](../../.github/scripts/e2e/Invoke-AzDoE2E.ps1) and the shared
[E2E module](../../.github/scripts/e2e/E2E.psm1). The offline `E2E` Pester suite covers
regeneration against the real templates, the lock and run matching, with service calls
mocked. It does not prove that a live cycle succeeds.
