# Quickstart: GitHub Actions

This is the shortest path from nothing to a first deployment with GitHub Actions
(PREVIEW). It uses automated setup and defaults throughout; each step links to the
detail if you need it. For Azure DevOps, use the
[Azure DevOps quickstart](quickstart-azdo.md).

Expect about an hour, most of it answering setup prompts and waiting for the first
EXPORT, BUILD and DEPLOY.

## Before You Start

Check that you have all of these. Setup stops when it needs something you don't have.

- [ ] A Windows computer with Windows PowerShell 5.1 or PowerShell 7, Git, and a browser.
- [ ] A GitHub account that can create or administer the application repository. Use a
      **public** repository, or a private one on a plan with environments; see
      [plan limitations](../setup/github-setup.md#github-licence-limitations).
- [ ] A **development** Dataverse environment containing your unmanaged solutions, and at
      least one **test** Dataverse environment to deploy to.
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
Invoke-WebRequest 'https://github.com/ALM4Dataverse/ALM4Dataverse/releases/latest/download/setup-github.ps1' -OutFile './setup-github.ps1'
.\setup-github.ps1
```

When setup asks, choose:

| Prompt | Recommended answer |
| --- | --- |
| Repository | Create a new repository for this application, or select its existing one. |
| Solutions | Your solutions, in dependency order. |
| Development environment | Your development Dataverse environment. |
| Deployment environments | Your test environment first. Add production later, once the first deployment works. |
| Application identity | Let setup create one per environment. Use **workload identity federation**, which needs no secret. |
| Process owner | The user account from the checklist. |
| BUILD validation | Skip it for now. You can enable it later; see [BUILD validation](../usage/building-releases.md#build-validation). |

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
