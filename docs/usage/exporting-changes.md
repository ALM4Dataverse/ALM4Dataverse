# Exporting Changes

```mermaid
flowchart LR
    A[Development Environment<br/>Dev-&lt;branchname&gt;] --> B[EXPORT Pipeline]
    B --> C[Repository Branch<br/>&lt;branchname&gt;]
    
    style A fill:#f3e5f5
    style C fill:#e1f5fe
    style B fill:#fff3e0
```

The `EXPORT` pipeline for each repo takes the state of the solution(s) (and other assets like data if you include them) in your development environment, and exports them to the source control repo.

## Before You Export

- Save and publish the intended maker changes, and confirm the configured solutions contain all required components.
- Check the selected branch and its development Dataverse URL. EXPORT writes to that branch directly; it does not open a pull request.
- Coordinate with other makers using the same development environment. All configured solution changes are exported, not just the caller's changes.
- Ensure the automation identity can export solutions, update solution versions, and push to the branch. Branch protection may require an integration branch instead of exporting directly to `main`.
- Review data hooks before running them: exported records become repository contents and must not contain secrets or inappropriate personal data.

> [!TIP]
> Export frequently; there is no need to wait until you are ready to deploy. Each export
> captures your work in source control and creates a useful history.

Exporting takes all changes to the configured solutions (and other assets) from the
associated environment. There is no method to select individual changes, so coordinate
with other makers sharing that environment.

> [!NOTE]
> **Advanced: branch-specific development targets.**
>
> ALM4Dataverse uses a convention-based approach to associate each branch with a development environment:
>
> - **Azure DevOps**: looks for a service connection named `Dev-<Build.SourceBranchName>` (e.g. `Dev-main`). A branch such as `feature/customer-import` uses its last path component: `Dev-customer-import`.
> - **GitHub Actions**: uses the GitHub environment named `Dev-<branchname>` (e.g. `Dev-main`).
>
> GitHub uses the full branch name, so that same feature branch defaults to
> `Dev-feature/customer-import`. An explicit action `environment-name` can override
> credential resolution; update the job environment and OIDC credential consistently.
> See [branching strategies](branching-strategies.md).

## Run EXPORT

**Azure DevOps:**

1) Navigate to the **Pipelines** area of your AzDO project.
2) Select the **All** tab and navigate to the folder with the same name as your repo.
3) Select the `EXPORT` pipeline and click **Run pipeline**.
4) If you're using multiple branches, select the correct branch. Otherwise it defaults to `main`.
5) Enter the commit message.
   This is the message that will be logged in source control history. If you include ticket numbers in `#1234 #2345` format, the changes will also be shown against those tickets in the 'Development' section.
6) Click **Run**. The view will switch automatically to show progress. Wait until it is shown as successful.

**GitHub Actions:**

1) Navigate to the **Actions** tab of your repository.
2) Select the **EXPORT** workflow and click **Run workflow**.
3) If you're using multiple branches, select the correct branch. Otherwise it defaults to `main`.
4) Enter the commit message and click **Run workflow**.
5) Select the running workflow run to follow its progress. Wait until it is shown as successful (green checkmark).

## What Happens

1. Dependencies are installed and the application identity connects to the development environment.
2. `preExport` hooks run.
3. Each configured solution is exported to `solutions/<unique-name>`, including unpacked canvas-app content. Existing source is replaced by the export.
4. Solution changes are compared with the prior source; changed solutions have their versions updated in both source and Dataverse.
5. `postExport` hooks run, including configured data exports.
6. All working-tree changes are committed with the supplied message and pushed. Azure DevOps uses the requesting user's name/email; GitHub uses the triggering actor and a GitHub noreply address.

No detected changes means no new commit. Data-only hook changes can create a commit without incrementing any solution version.

> [!NOTE]
> **Advanced: triggering BUILD.** On Azure DevOps the push triggers BUILD. On GitHub,
> EXPORT explicitly sends a repository-dispatch event after pushing, because a push made
> with `GITHUB_TOKEN` does not normally trigger another push workflow. BUILD checks out
> the exact exported commit; the BUILD caller must exist on the default branch.

### Version Increments

| Detected solution change | Version effect | Example |
| --- | --- | --- |
| Additive change, or first export with no prior source | Increment revision | `1.2.3.4` becomes `1.2.3.5` |
| Non-additive component change | Increment minor and reset build/revision | `1.2.3.4` becomes `1.3.0.0` |
| No source changes | No increment | Version remains unchanged |

This matters during deployment: matching major/minor versions permit updates; a different major/minor can require an upgrade that removes obsolete components. Detection is based on solution component comparison, not a guarantee that a business change is backward-compatible. The CI build/release identity is separate from each solution's version.

## Verify And Continue

Review the resulting commit for unintended solution/data changes, then check [BUILD](building-releases.md).

> [!WARNING]
> If the push fails because the branch advanced, do not force-push over others' changes.
> Coordinate the export/source changes, synchronize the development environment as
> appropriate, and rerun. EXPORT may already have updated Dataverse versions before a
> later Git failure. See [importing changes](importing-changes.md) for safe synchronization.

## Viewing Exported Changes

**Azure DevOps:**

1) Navigate to **Repos** in Azure DevOps and select the correct repo and branch.
2) Switch to the **History** view.
3) Each commit is displayed with its message. Click a commit to see the full set of changes.

**GitHub:**

1) Navigate to your repository and select the correct branch.
2) Click **Commits** (shown above the file list).
3) Each commit is listed with its message. Click a commit to see the full diff.
