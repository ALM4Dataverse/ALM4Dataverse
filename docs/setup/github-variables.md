# Configure A GitHub Environment

Use this checklist when adding or changing a development, validation, or deployment
environment. The [GitHub secrets and variables reference](../config/github-secrets.md)
contains the complete names, formats, aliases, precedence, and OIDC subjects.
For initial installation, start with [GitHub setup](github-setup.md).

## 1. Choose The Environment Name

| Purpose | Name used by the supplied workflows |
| --- | --- |
| EXPORT and IMPORT | `Dev-<branch>`, using the full GitHub branch name |
| BUILD deployment validation | The job's configured validation environment, for example `Build` |
| DEPLOY | The target name configured on that stage, for example `TEST-main` or `PROD` |

> [!IMPORTANT]
> The workflow job's `environment` and the action's `environment-name` must agree when
> using environment-scoped credentials. A GitHub environment is a set of CI settings;
> `DATAVERSE_URL` determines which actual Dataverse environment is changed.

## 2. Prepare The Dataverse Identities

Create or select an Entra app registration and add it as an application user in the
target Dataverse environment, with the required solution-operation permissions.
Separately, identify the user account that will own and activate processes.
Ensure that user exists, is enabled, and has the necessary licenses, roles, and
access to the connections used by the flows.

## 3. Choose Authentication And Storage

Prefer WIF/OIDC, with a federated credential matching the job's actual subject.
Alternatively, create an expiring client secret and record a rotation owner/date.
Both methods can use environment values or explicitly mapped repository values.

Check [plan restrictions](github-setup.md#github-licence-limitations) first.
Prefixed repository values do not remove the shipped jobs' dependency on GitHub environments.

### Environment Values

In **Settings > Environments > your environment**, add `AZURE_CLIENT_ID`,
`AZURE_TENANT_ID`, `DATAVERSE_URL`, and `DATAVERSESERVICEACCOUNTUPN` as variables.
Add individual `DataverseConnRef_<schema-name>` and non-sensitive
`DataverseEnvVar_<schema-name>` variables as needed.

Store `AZURE_CLIENT_SECRET` only for client-secret authentication. Store sensitive
Dataverse values as individual secrets. Every secret must be named explicitly in
the action's `secrets-json` mapping; use the
[mapping example](../config/github-secrets.md#per-solution-environment-variable-values).

### Prefixed Repository Values

In **Settings > Secrets and variables > Actions**, use the environment-derived prefix,
for example `TEST_MAIN_` for `TEST-main`. Store non-sensitive settings as variables.
Use the [prefixed reference](../config/github-secrets.md#approach-3-prefixed-repository-variables-and-secrets)
for exact names and supported aliases. Store secrets either in the selected GitHub
environment or as prefixed repository secrets explicitly mapped to unprefixed runtime names.

> [!NOTE]
> Secrets are not automatically discovered or migrated. GitHub cannot return stored
> secret values for setup to transfer to another location; map them explicitly.

## 4. Configure Protection And Concurrency

Where supported, configure required reviewers and deployment branch/tag restrictions.
Otherwise, use manual gate-tag promotion and restrict who can edit or run the workflows.
A manual trigger is not independent approval, and a gate tag is not an authorization boundary.

Use a shared concurrency group for jobs that can mutate the same Dataverse environment.
Keep BUILD validation on a non-production environment without production approval rules.

> [!CAUTION]
> Review `cancel-in-progress` carefully: stopping a runner does not necessarily stop
> a Dataverse import. A replacement job could otherwise overlap with that operation.

## 5. Verify Before Promotion

1. Check that the Dataverse URL and application identity are for the intended target.
2. Authorize the app user, process owner, and connection access in Dataverse.
3. Confirm variable prefixes, explicit secret mappings, and the WIF subject or secret expiry.
4. Run an appropriate non-production IMPORT, BUILD validation, or DEPLOY.
5. Verify the logs identify the expected organization and that flows activate correctly.
6. Confirm approvals and predecessor gates behave as intended before enabling production promotion.

Keep secrets out of logs, screenshots, commits, and artifacts. For the full runtime
mapping, see [GitHub secrets and variables](../config/github-secrets.md).
