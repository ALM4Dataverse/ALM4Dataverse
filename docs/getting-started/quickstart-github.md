# Quickstart: GitHub Actions

This is the shortest path from nothing to a first deployment with GitHub Actions. It
uses automated setup and defaults throughout; each step links to the detail if you need
it. For Azure DevOps, use the
[Azure DevOps quickstart](quickstart-azdo.md).

Expect about an hour, most of it answering setup prompts and waiting for the first
EXPORT, BUILD and DEPLOY.

## Choose A Setup Route

Both routes end the same way: the caller workflows in `.github/workflows/` are generated
automatically from `alm-config.psd1` — you never edit them by hand. The difference is who
creates everything else.

| | Automated setup | Manual setup |
| --- | --- | --- |
| Who does the work | One guided script, run in PowerShell locally or in Azure Cloud Shell with internet access | You create the repository settings, environments and credentials yourself, step by step |
| `alm-config.psd1` | Setup writes it from your answers | You write and commit it yourself |
| Caller workflows | Generated from `alm-config.psd1` by setup at the end | Generated from `alm-config.psd1` by the APPLY-CONFIG workflow (or `-ApplyConfig` locally) |
| Choose when | Recommended: any computer or Azure Cloud Shell can run it | Running PowerShell locally is restricted, or you want to create each resource yourself |

The automated route is the default. Its prerequisites and guided steps are in
[GitHub automated setup](../setup/github-setup.md); the manual route's prerequisites and
steps are in [GitHub manual setup](../setup/github-manual-setup.md).

New to the vocabulary? The [glossary](../concepts/glossary.md) explains the terms used
below.

## 1. Run Setup

Open PowerShell in an empty working folder, download the released setup script, and
read it before running it:

```powershell
Invoke-WebRequest 'https://github.com/ALM4Dataverse/ALM4Dataverse/releases/latest/download/setup-github.ps1' -OutFile './setup-github.ps1'
.\setup-github.ps1
```

You can also run setup in [Azure Cloud Shell](../setup/github-setup.md#run-in-azure-cloud-shell);
choose PowerShell and use the one-line bootstrap there.

Follow the [guided setup steps](../setup/github-setup.md#guided-setup). For a first
deployment, choose your solutions in dependency order, your test environment first, a
workload identity federated application identity, and skip BUILD validation; you can
enable it later (see [BUILD validation](../usage/building-releases.md#build-validation)).
At the end, setup lists what it changed. If it opened pull requests, review and merge
them before continuing.

## 2. Export Your Solutions

In your application repository on GitHub, open **Actions**, select **EXPORT**, choose
**Run workflow** on `main` and enter a commit message such as `Initial export`.

EXPORT copies the solutions from development into `solutions/` and commits them. Look at
that commit: it is now the source of truth for your application. See
[exporting changes](../usage/exporting-changes.md).

## 3. Check The Build

EXPORT starts **BUILD** automatically for its new commit. When BUILD succeeds, it
publishes a GitHub prerelease tagged with the build version, for example `v1.0.42-main`.
That package is what every environment will receive, unchanged.

If BUILD fails, open the failing step and look it up in
[troubleshooting](../usage/troubleshooting.md).

## 4. Deploy To Test

A successful BUILD starts **DEPLOY-main** for the first deployment environment. If the
GitHub environment has required reviewers, approve the run. On a plan without required
reviewers, setup configures manual promotion instead: run DEPLOY-main yourself and select
the target. Then open the application in your test environment and check that it works.

To deploy again or choose a different build, run DEPLOY-main manually; see
[deploying](../usage/deploying.md).

## 5. Add Production

When test deployments are working:

1. Re-run setup and add your production environment. Use a separate application
   identity for production.
2. Make sure the production GitHub environment has **required reviewers**, so a person
   approves every production deployment. Setup configures them when your plan supports
   them; otherwise it uses manual gate tags, which enforce order but not approval.
3. Promote a build that was tested: run DEPLOY-main manually, choose the production
   target and enter that build's release tag as `build-run-name`.

## Next Steps

- Understand what ALM4Dataverse does and doesn't do for you:
  [responsibilities and limits](../concepts/responsibilities.md).
- Learn what each file in your repository is for:
  [application repository layout](../concepts/application-repository.md).
- Supply connection references, environment-variable values and secrets per target:
  [GitHub variables checklist](../setup/github-variables.md).
- Choose how branches map to environments:
  [branching strategies](../usage/branching-strategies.md).
- Add configuration data, plug-ins, web resources or Code Apps:
  [writing hooks](../usage/writing-hooks.md) and
  [adding Dataverse components](../usage/adding-dataverse-components.md).
