# Quickstart: Azure DevOps

This is the shortest path from nothing to a first deployment with Azure DevOps. It uses
automated setup and defaults throughout; each step links to the detail if you need it.
For GitHub Actions, use the [GitHub quickstart](quickstart-github.md).

Expect about an hour, most of it answering setup prompts and waiting for the first
EXPORT, BUILD and DEPLOY.

## Before You Start

Check that you have all of these. Setup stops when it needs something you don't have.

- [ ] A Windows computer with Windows PowerShell 5.1 or PowerShell 7 and a browser.
      Setup downloads Git and its PowerShell modules itself.
- [ ] An Azure DevOps organization that can run pipelines on Microsoft-hosted agents.
      New organizations must request or buy that capacity first; see
      [organization requirements](../setup/azdo-organisation-requirements.md).
- [ ] An Azure DevOps project where you are a Project Administrator, or Project
      Collection Administrator rights so setup can create one.
- [ ] A **development** Dataverse environment containing your unmanaged solutions, and at
      least one **test** Dataverse environment to deploy to, all in the same Entra ID
      tenant as your Azure DevOps organization and your own account.
- [ ] The **unique names** of the solutions to manage, in dependency order (a solution
      comes after every solution it depends on).
- [ ] An existing, licensed **user account** in each environment to own and activate flows
      and other processes (the "process owner").
- [ ] Permission to create Entra ID app registrations and Dataverse application users, or
      an administrator who can do it with you.

New to the vocabulary? The [glossary](../concepts/glossary.md) explains the terms used
below.

## 1. Run Setup

Open PowerShell in an empty working folder, download the released setup script, and
read it before running it:

```powershell
Invoke-WebRequest 'https://github.com/ALM4Dataverse/ALM4Dataverse/releases/latest/download/setup-azdo.ps1' -OutFile './setup-azdo.ps1'
.\setup-azdo.ps1
```

When setup asks, choose:

| Prompt | Recommended answer |
| --- | --- |
| ALM4Dataverse extension | Use it. It allows workload identity federation, which needs no secret. |
| Project | Your project, or create one with a long-lived name. |
| Repository | Create a new repository for this application, or select its existing one. |
| Development environment | Your development Dataverse environment. |
| Solutions | Your solutions, in dependency order. |
| Deployment environments | Your test environment first. Add production later, once the first deployment works. |
| Application identity | Let setup create one per environment, using **workload identity federation**. |
| Process owner | The user account from the checklist. |
| BUILD validation | Skip it for now. You can enable it later; see [BUILD validation](../usage/building-releases.md#build-validation). |

Setup also imports the shared `ALM4Dataverse` repository into your project, creates the
BUILD, EXPORT, IMPORT and DEPLOY-main pipelines, and creates a variable group and service
connection for each environment. At the end it lists what it changed. If it opened pull
requests, review and complete them before continuing.

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
