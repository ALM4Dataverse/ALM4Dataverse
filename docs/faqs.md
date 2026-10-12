# Frequently Asked Questions

## Should I Use Azure DevOps Or GitHub?

Start with the platform your organization already uses and licenses. Both run the same
core ALM4Dataverse scripts, but their pricing and deployment controls differ:

- **Azure DevOps** is usually the simpler low-cost choice for private repositories that need deployment approvals. A small team can start free, but **every job must finish within 60 minutes** on its free hosted tier.
- **GitHub** fits teams already using GitHub and public/open-source projects. For private organization repositories, budget for Team or Enterprise Cloud, depending on the approval controls you need. ALM4Dataverse's GitHub support is still **PREVIEW**.

> [!NOTE]
> **Pricing checked: 12 October 2026.** Figures below are advertised USD prices for
> Azure DevOps Services and GitHub's cloud plans, excluding taxes. Billing terms,
> regional pricing, contracts, and existing license entitlements can change the total.
> Dataverse/Power Platform licenses, environment capacity, and service-account licenses
> are separate. Check the linked official prices before purchasing.

### What Can I Use For Free?

| Requirement | Azure DevOps Services | GitHub Free |
| --- | --- | --- |
| Private source repositories | Unlimited repositories; first **5 Basic users** free. | Unlimited repositories and collaborators, with a limited private-repository feature set. |
| Hosted jobs for private repositories | **1 concurrent job**, **1,800 minutes/month**, maximum **60 minutes per job**. | **2,000 minutes/month** for standard Linux runners, maximum **6 hours per hosted job**. The environment restriction below prevents using the supplied private-repository setup unchanged. |
| Private deployment environments and approvals | Environment approvals/checks are available without a separate premium approval plan. | Private environments are not available on Free; public environments and required-reviewer approvals are available. |
| Private build-artifact storage | Pipeline Artifacts do not incur Azure Artifacts package-feed storage charges; retention policies still apply. | **500 MB**, shared with GitHub Packages storage. |

Azure's hosted free grant requires linking a valid Azure subscription through organization
billing. The allowances are shared across the Azure DevOps organization or GitHub billing
account, not granted again for each repository, pipeline, or user.

For **public GitHub repositories**, standard GitHub-hosted runner execution is free;
larger runners remain billable. Azure DevOps no longer allows new public projects, and
existing public projects are due to become private in 2027, so use its private-project
allowances when planning a new setup.

> [!CAUTION]
> Do not make an application repository public just to obtain free CI. Solution source,
> configuration, and exported records may contain confidential business information.

### How Long Can A Job Run?

The **maximum runtime of one job** is separate from the **monthly minutes allowance**.
The job limit covers setup, all solution operations, and hooks in that job, not each
individual step or solution. This is especially important for long Dataverse imports,
upgrades, and BUILD validation that deploys both a baseline and a candidate release.

| Runner and plan | Maximum runtime per job |
| --- | --- |
| Azure DevOps Microsoft-hosted, free private-project tier | **60 minutes**, even with unused monthly minutes. |
| Azure DevOps Microsoft-hosted, paid parallel job | **360 minutes (6 hours)**; unlimited monthly minutes does not mean unlimited job duration. |
| GitHub-hosted, any plan | **360 minutes (6 hours)**, including public repositories. Buying more minutes or upgrading the plan does not raise this limit. |

> [!IMPORTANT]
> **A 90-minute deployment cannot finish on Azure DevOps's free hosted tier**, even if
> it is your only run that month. Budget for a paid hosted parallel job (**$40/month**)
> or a suitably configured self-hosted agent. The supplied ALM4Dataverse jobs request
> 360 minutes, but that setting cannot override the platform's lower free-tier limit.

The separate `importTimeoutSeconds` setting defaults to **10,800 seconds (3 hours)**.
Increasing it only extends the import wait; it cannot extend the runner's job limit.
Shorter configured job or step timeouts can stop work sooner than the platform maximum.
If a job times out, the Dataverse operation may still be running: inspect solution
history before retrying. See [timeout troubleshooting](usage/troubleshooting.md#solution-import-upgrade-or-process-activation).

### What Costs Money Beyond Those Limits?

For organization-owned repositories, separate **user licenses** from **runner usage**:

| Cost | Azure DevOps Services | GitHub |
| --- | --- | --- |
| Additional users or private-repository features | Basic is **$6/user/month** after the first five free users. Eligible existing licenses can cover access. | Team is **$4/user/month**; Enterprise Cloud starts at **$21/user/month**. Paid seats apply to billable users, not just users after the first five. |
| More hosted runtime | **$40/month per paid parallel job**, with unlimited monthly minutes and a **6-hour per-job limit**. The first purchase upgrades the free slot; two simultaneous paid jobs require two purchases. | Team includes **3,000 minutes/month** and Enterprise Cloud **50,000**. Extra standard Linux x64 minutes cost **$0.006/minute**; standard Windows minutes cost **$0.010/minute**. |
| Additional artifact storage | Pipeline Artifacts remain exempt from package-feed storage billing. The separate Azure Artifacts feed allowance/prices are not the build ZIP storage allowance. | Team includes **2 GB** and Enterprise Cloud **50 GB** of shared Actions/Packages storage. Excess artifact storage is **$0.25/GB/month**, accrued hourly. |

The supplied Azure pipelines use Windows agents; the supplied GitHub workflows use
`ubuntu-latest`, so use the Linux rate when estimating their Actions costs. Retries and
failed jobs also consume runtime. Configure usage budgets and artifact retention;
GitHub may block further usage at the allowance if paid overages are not enabled.

**Example:** five users consuming 5,000 hosted job-minutes in a month would pay **$40**
for one Azure hosted slot, with no Basic seat charge. GitHub Team would cost **$20**
for five seats plus **$12** for 2,000 extra standard Linux minutes: **$32**, before any
storage overage. These are illustrative totals with no other account usage; the Team
option does **not** include private deployment required-reviewer approvals.

> [!IMPORTANT]
> **A paid GitHub environment is not the same as a deployment approval gate.** Team
> supports private environments, but their required-reviewer rules and wait timers need
> Enterprise Cloud. Pro supports private environments for personal repositories, with
> the same approval limitation. ALM4Dataverse's manual gate tags record promotion order;
> they do not provide independent approval. Prefixed credentials do not remove the
> supplied jobs' environment requirement. See the [GitHub plan limitations](setup/github-setup.md#github-licence-limitations).

Official sources: [Azure DevOps pricing](https://azure.microsoft.com/en-us/pricing/details/devops/azure-devops-services/),
[Azure hosted-job rules](https://learn.microsoft.com/en-us/azure/devops/pipelines/licensing/concurrent-jobs?view=azure-devops),
[Azure artifact storage billing](https://learn.microsoft.com/en-us/azure/devops/artifacts/artifact-storage?view=azure-devops#faqs),
[GitHub pricing](https://github.com/pricing),
[GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions),
[GitHub Actions runtime limits](https://docs.github.com/en/actions/reference/limits),
and [GitHub environment protection rules](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments).

> [!NOTE]
> **Advanced: self-hosted runners.** Azure includes one free self-hosted parallel job
> with unlimited minutes; additional slots cost **$15/month** each, before any existing
> entitlements. Azure imposes no service-level runtime cap on self-hosted jobs; GitHub
> allows up to **5 days per self-hosted job** and does not charge for runner execution.
> The supplied 360-minute job timeout still applies unless you change it, and import
> timeouts must also allow for the expected operation duration. In both cases you pay
> for and maintain the machines, adapt the supplied hosted-runner configuration, and
> still need the appropriate repository/environment plan. Self-hosting does not unlock
> GitHub's private approval features.

## Why should I use this instead of Power Platform Pipelines?

Choose the approach that fits your delivery process. Power Platform Pipelines provides
an integrated maker-facing deployment experience. ALM4Dataverse is intended for teams
that want Git-based source control, branch/PR policies, reusable Azure DevOps or GitHub
automation, and PowerShell hooks for data and other deployment tasks.

ALM4Dataverse also means operating repositories, identities, pipeline permissions,
retention, and custom hooks. It is not a replacement for Dataverse governance, licensing,
backups, or functional testing. Start with the [workflow overview](../README.md#how-it-works)
and [setup choices](../README.md#getting-started).

## Why would I use this instead of my own Pipelines/Workflows?

It supplies shared implementations for packing, dependency-aware solution deployment,
connection references, Dataverse values, process ownership/activation, release selection,
and extension hooks. You configure those behaviors instead of maintaining copies of
each step. Review the [configuration](config/alm-config.md) and [pipeline contracts](config/pipelines.md)
to decide whether the existing behavior fits; hooks and forks remain options where it does not.

## Why do I need to set up 2 source control repos instead of just 1?

The application repository owns solution source, configuration, data, and caller files.
The shared repository owns reusable automation, so multiple applications can consume
one tested implementation.

- **Azure DevOps:** setup imports a shared repository into your project and callers reference it as `ALM4Dataverse`.
- **GitHub:** callers can use the public shared actions directly; you do not need a second repository in your organization unless you maintain a fork.

> [!NOTE]
> **Advanced: packaged automation.** Each build includes the shared deployment scripts
> it used. Updating the shared reference affects future builds, not existing release
> artifacts. See [updating](usage/updating.md).

## Can I Use Multiple Solutions Or Only Data?

Yes. List solutions by unique name in dependency order, with foundational solutions first.
An empty `solutions = @()` is supported for assets/hooks-only repositories. Configure
assets and hooks explicitly, and still provide the identities/settings required by any
connected operation. Unmanaged deployment can be selected per solution, but managed
deployment is the normal downstream default.

## Why Are An Application User And A Service-Account User Both Needed?

The Entra application authenticates automation through a Dataverse application user.
`DataverseServiceAccountUpn` identifies an existing Dataverse user for process ownership
and activation. They are different identities. That user needs the relevant permissions,
licensing, and access to connections; a UPN setting does not create a user or connection.
See [Azure DevOps settings](config/azdo-environment-variable-group.md) or
[GitHub settings](config/github-secrets.md).

## Does IMPORT Overwrite My Development Environment?

IMPORT builds the selected source and deploys it unmanaged. It is not a three-way merge,
a clean environment reset, or a guarantee that obsolete unmanaged components disappear.

> [!IMPORTANT]
> EXPORT and review maker changes before integrating upstream source and running IMPORT.
> Follow the [development synchronization procedure](usage/importing-changes.md) to preserve
> your work before updating the environment.

## Why Did EXPORT Produce No Commit Or No New Solution Version?

An unchanged export produces no commit. Data/hook-only changes can produce a commit
without changing a solution version. Additive solution changes increment the revision;
non-additive changes increment minor and reset build/revision. See [versioning](usage/exporting-changes.md#version-increments).

## Why Was A Solution Skipped During Deployment?

The shared import call skips a solution whose version is already installed. Do not
change a package in place and expect the same version to force a reimport. Surrounding
hooks, process activation, and publishing still run. Investigate source/version and
target state before rerunning; see [troubleshooting](usage/troubleshooting.md).

## Can I Roll Back By Deploying An Older Build?

Not reliably.

> [!CAUTION]
> An old package cannot undo every solution upgrade, component deletion, unmanaged layer,
> or data migration. Keep required artifacts and environment backups, and use a tested
> forward-fix or restore strategy. Tags record identity; they are not backups.
> See [recovery guidance](usage/deploying.md#retry-redeploy-and-recovery).

## Does BUILD Prove My Application Works?

BUILD always packages source. Optional Solution Checker provides static analysis;
optional deployment validation exercises installation/upgrade against a configured
Dataverse environment. Neither replaces functional tests. Validation modifies its target
and does not reset it automatically. PR checks must also be configured separately.
See [BUILD validation](usage/building-releases.md#build-validation).

## Is GitHub Free Enough?

For a public repository, it can be. For the supplied private-repository setup, no:
the jobs require environments, which need an eligible paid plan. Paying only for extra
Actions minutes does not unlock them. See [Azure DevOps or GitHub?](#should-i-use-azure-devops-or-github)
for the free limits, paid costs, and distinction between environments and approval gates.

## Where Do I Start When A Run Fails?

Record the operation, source branch/SHA, exact BUILD identity, target, and first failing
step. Check [troubleshooting](usage/troubleshooting.md) before retrying an import or
changing permissions. Remove secrets and sensitive record contents from any shared logs.
