# Quickstart: Azure DevOps

This is the shortest path from nothing to a first deployment with Azure DevOps. It uses
automated setup and defaults throughout; each step links to the detail if you need it.
For GitHub Actions, use the [GitHub quickstart](quickstart-github.md).

Expect about an hour, most of it answering setup prompts and waiting for the first
EXPORT, BUILD and DEPLOY.

## Choose A Setup Route

Both routes end the same way: the caller pipelines in `pipelines/` are generated
automatically from `alm-config.psd1` — you never edit them by hand. The difference is who
creates everything else.

| | Automated setup | Manual setup |
| --- | --- | --- |
| Who does the work | One guided script, run in PowerShell locally or in Azure Cloud Shell with internet access | You create the project, repositories, connections, groups, environments and approvals yourself, step by step |
| `alm-config.psd1` | Setup writes it from your answers | You write and commit it yourself |
| Caller pipelines | Generated from `alm-config.psd1` by setup at the end | Generated from `alm-config.psd1` by the APPLY-CONFIG pipeline (or `-ApplyConfig` locally) |
| Choose when | Recommended: any computer or Azure Cloud Shell can run it | Running PowerShell locally is restricted, or you want to create each resource yourself |

The automated route is the default. Its prerequisites and guided steps are in
[Azure DevOps automated setup](../setup/azdo-automated-setup.md); the manual route's
prerequisites and steps are in
[Azure DevOps manual setup](../setup/azdo-manual-setup.md).

New to the vocabulary? The [glossary](../concepts/glossary.md) explains the terms used
below.

## 1. Run Setup

Open PowerShell in an empty working folder, download the released setup script, and
read it before running it:

```powershell
Invoke-WebRequest 'https://github.com/ALM4Dataverse/ALM4Dataverse/releases/latest/download/setup-azdo.ps1' -OutFile './setup-azdo.ps1'
.\setup-azdo.ps1
```

You can also run setup in [Azure Cloud Shell](../setup/azdo-automated-setup.md#run-in-azure-cloud-shell);
choose PowerShell and use the one-line bootstrap there.

Follow the [guided setup steps](../setup/azdo-automated-setup.md#guided-setup). For a
first deployment, use the ALM4Dataverse extension (workload identity federation needs
it), choose your solutions in dependency order, your test environment first, and skip
BUILD validation; you can enable it later (see
[BUILD validation](../usage/building-releases.md#build-validation)). At the end, setup
lists what it changed. If it opened pull requests, review and complete them before
continuing.

## 2. Export Your Solutions

In your project, open **Pipelines**, select **EXPORT**, choose **Run pipeline** on
`main` and enter a commit message such as `Initial export`.

EXPORT copies the solutions from development into `solutions/` and commits them. Look at
that commit: it is now the source of truth for your application. See
[exporting changes](../usage/exporting-changes.md).

## 3. Check The Build

EXPORT's commit triggers **BUILD**. A successful BUILD publishes a pipeline artifact
numbered with the build version, for example `1.0.42-main`. That package is what every
environment will receive, unchanged.

If BUILD fails, open the failing step and look it up in
[troubleshooting](../usage/troubleshooting.md).

## 4. Deploy To Test

A successful BUILD on `main` triggers **DEPLOY-main**. Each deployment stage waits for
approval from the `<environment> deployment approvers` team that setup created, which
initially contains only you. Approve the stage, then open the application in your test
environment and check that it works.

To deploy a different build, run DEPLOY-main manually and pick the build under
**Resources**; see [deploying](../usage/deploying.md).

## 5. Add Production

When test deployments are working:

1. Re-run setup and add your production environment. Use a separate application
   identity for production.
2. Add the people who approve production releases to the production approvers team.
3. Promote the build you tested: approve its production stage, or run DEPLOY-main
   manually with that build selected.

## Next Steps

- Understand what ALM4Dataverse does and doesn't do for you:
  [responsibilities and limits](../concepts/responsibilities.md).
- Learn what each file in your repository is for:
  [application repository layout](../concepts/application-repository.md).
- Supply connection references, environment-variable values and secrets per target:
  [Azure DevOps variable groups](../config/azdo-environment-variable-group.md).
- Choose how branches map to environments:
  [branching strategies](../usage/branching-strategies.md).
- Add configuration data, plug-ins, web resources or Code Apps:
  [writing hooks](../usage/writing-hooks.md) and
  [adding Dataverse components](../usage/adding-dataverse-components.md).
