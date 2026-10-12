# Updating And Customizing ALM4Dataverse

Treat shared automation as a versioned dependency. Test updates with representative
solutions, data hooks, and authentication before rolling them out across applications.

## Understand What Is Pinned

| Item | When it is selected | Effect of an update |
| --- | --- | --- |
| Shared actions/templates/scripts | Caller reference or shared repository resource | Changes future operations/builds. |
| Application configuration, solution source, and assets | Source commit selected for BUILD | Included in that new build's package. |
| Deployment scripts/defaults and dependency lock | Copied/generated during BUILD | Remain inside existing artifacts after shared code changes. |
| Target credentials, connections, and values | Deployment runtime | Can change the effect of deploying an unchanged package. |
| Hosted runner and external services | Runtime | Not frozen by the artifact. |

> [!TIP]
> Pin an immutable commit SHA for the strongest reproducibility, or a controlled version
> tag according to your policy. `main`, `stable`, and the latest setup download can change.
> Record the tested ref rather than assuming all consumers update together.

## Update An Application

1. Record the current shared ref, successful production build identities, target settings, and required backups. Retain artifacts needed for recovery/baseline validation.
2. Review upstream release notes and compare changed caller files, default settings, action/template inputs, and hook behavior.
3. Update shared references and any required caller/configuration changes on a reviewable application branch.
4. Run EXPORT/IMPORT only against intended development targets. BUILD a new package and exercise checker/baseline validation where configured.
5. Deploy the exact new build to a representative non-production target. Verify upgrades, data changes, connections, ownership, and a repeated deployment.
6. Promote that same build through normal controls, then roll out the shared update to other consumers.

> [!IMPORTANT]
> Updating the caller or shared repository does not patch old Release assets. Existing
> artifacts still run their packaged deployment scripts. Rebuild to include a deployment-code
> fix, and distinguish reverting automation source from recovering Dataverse solution/data state.

### GitHub Actions

Review every remote action/workflow `uses:` reference, including BUILD, EXPORT, IMPORT,
each DEPLOY job, and the reusable cleanup workflow. Keep those references consistent
with the code source you intend future builds to package; see [action contracts](../config/pipelines.md).
GitHub requires a literal ref in `uses:`, not a runtime expression.

For a fork, change the action/workflow owner consistently. Ensure dispatch-driven
caller definitions exist on the default branch. Review
permissions, job environments, OIDC subjects, selected secret mappings, and promotion
conditions when adopting newer callers.

### Azure DevOps

Fetch and review upstream changes in the shared Azure Repos repository, then merge them
through your normal review process. Update an application's repository resource `ref`
if it pins a different branch/tag. Preserve the alias `ALM4Dataverse` used by templates.

Compare copied callers as well as shared templates: build pipeline resource paths,
branch filters, stage lists, extension mode, variable-group declarations, and explicitly
mapped secrets may require coordinated updates. Existing pipeline/resource permissions
and approval checks are not replaced by updating Git files.

## Re-Run Setup Carefully

Use a reviewed released setup script. Select existing resources deliberately, review
generated diffs, and keep custom hooks/settings under source control.

> [!CAUTION]
> Setup may preserve some mappings/checks while regenerating callers; it is not a generic
> merge tool for arbitrary customization. If interrupted, inspect resources and commits
> already created before retrying.

## Choose The Smallest Extension Point

- **Application configuration:** solution order/options, assets, checker settings, module versions, and import timeout belong in the application data file.
- **Hooks:** use the documented lifecycle points for data or organization changes. Package deployment scripts as assets, fail clearly, and make retries safe.
- **Caller customization:** choose branches, environments, permissions, approvals, concurrency, and runtime secret mappings in the platform caller.
- **Shared fork:** change reusable behavior only when configuration/hooks are insufficient, and regression-test all affected consumers.

> [!NOTE]
> **Advanced: shared fork defaults.** Edit [alm-config-defaults.psd1](../../alm-config-defaults.psd1).
> Application scalars override defaults; nested hashtables merge, arrays append, and
> `$null` retains defaults. There is no automatically loaded `fork-almconfig.psd1`.
> Shared hook paths can start with `[alm]`; application hook paths are relative to the
> operation's base directory. See the [merge and hook reference](../config/alm-config.md).

## Rotate Credentials And Review Access

Rotate client secrets before expiry and update the appropriate platform secret/service
connection. Verify a non-production run before removing the old credential. WIF removes
the client secret but still requires correct trust, application-user roles, and periodic
access review. Branch/environment renames may require updated OIDC subjects and callers.

Do not rebuild solely to rotate a runtime credential, and never add that credential to
the artifact. Review process-owner accounts, connection access, approvals, tag-write
permissions, and artifact retention alongside authentication.

Maintaining a shared fork or publishing setup assets? Use the [maintainer guide](../maintainers.md).
