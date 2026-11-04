# Responsibilities And Limits

ALM4Dataverse automates moving Dataverse solutions from source control into
environments. It doesn't run your environments, test your application or decide who may
release it. This page lists what you remain responsible for, so you can plan for it
before production depends on the automation.

## What ALM4Dataverse Does

- Exports solutions from a development environment into source control (EXPORT).
- Builds a numbered package from a commit and keeps it unchanged (BUILD).
- Deploys that exact package to each target in order, applying that target's
  connections, environment-variable values and process ownership (DEPLOY).
- Rebuilds a development environment from source (IMPORT).
- Runs your hooks at fixed points in those operations.
- Records what was deployed where, using Git tags.

## What You Are Responsible For

### Environments And Recovery

- **Creating and managing Dataverse environments.** Setup connects to environments that
  already exist; it doesn't create, copy or reset them.
- **Backups and recovery.** Deploying an older build is not a guaranteed rollback:
  solution downgrades, removed components and data migrations may not reverse. Plan
  forward fixes and environment restores. See
  [retry, redeploy and recovery](../usage/deploying.md#retry-redeploy-and-recovery).
- **The BUILD validation environment.** When enabled, BUILD deploys every candidate into
  it without resetting it, and all branches share it. Use a disposable non-production
  environment.

### Quality

- **Testing your application.** A successful deployment means the automation completed,
  not that the application works. Solution Checker checks package quality, not
  behavior.
- **Reviewing changes before they reach a deployment branch.** The supplied callers
  don't require pull requests or status checks. Configure branch policies or rulesets
  yourself; see [branching strategies](../usage/branching-strategies.md).
- **Making hooks safe to repeat.** Retries and redeployments run hooks again. See
  [writing hooks](../usage/writing-hooks.md).

### Access And Approval

- **Who can approve a deployment.** On Azure DevOps, setup creates an approvers team per
  target containing only you; add the right people. On GitHub, required reviewers depend
  on your plan, and the manual gate-tag fallback enforces order, not approval. See
  [GitHub plan limitations](../setup/github-setup.md#github-licence-limitations).
- **Protecting the automation.** Anyone who can change workflows, pipelines, hooks or
  `alm-config.psd1` on a deployment branch can change what runs with deployment
  credentials. Treat those changes as privileged.
- **Application identity permissions.** Standard setup gives each application user the
  System Administrator role. Use separate identities for production and
  non-production, and reduce roles if your organization requires it.

### Credentials And Settings

- **Secret storage and rotation.** Client secrets expire; workload identity federation
  avoids that. Store secrets only in the CI platform, never in the repository. See
  [credential rotation](../usage/updating.md#rotate-credentials-and-review-access).
- **Target-specific values.** Connection reference IDs, environment-variable values and
  custom secrets for each target are yours to supply and keep current.

### Platform And Costs

- **CI capacity and plan features.** Hosted-agent parallelism, Actions minutes, storage
  and environment features depend on your Azure DevOps or GitHub plan.
- **Build retention.** Old builds you might need to redeploy must still exist. Review
  [retention](../usage/building-releases.md#github-release-cleanup) on GitHub and
  pipeline retention on Azure DevOps.
- **Hosted runner changes.** A build snapshots its deployment scripts and dependency
  versions, not the hosted runner image or the target environment's state.

### Shared Code

- **Choosing and upgrading the shared version.** Callers reference a specific ref of
  the shared code. Upgrade deliberately; see [updating](../usage/updating.md) and the
  [upgrade notes](../usage/upgrade-notes.md).
- **Re-running setup.** Setup keeps some customizations and replaces others; see
  [re-running setup](../usage/updating.md#re-run-setup-carefully).
