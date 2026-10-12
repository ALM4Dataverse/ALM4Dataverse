# GitHub Secrets & Variables Reference

This document describes every secret and variable used by the ALM4Dataverse GitHub
Actions workflows, and how they map to each of the three credential approaches.

> The composite actions receive repository variables as JSON and one `secrets-json` input
> containing only the named secret values selected by the caller. The resolver
> never enumerates the GitHub `secrets` context.

---

## Approach comparison

| | WIF / OIDC | GitHub Environments + client secret | Prefixed repo variables + repository secrets |
|---|---|---|---|
| Secrets to manage | None | Client secret (rotate periodically) | Client secret if used; sensitive Dataverse values as needed |
| Approval gates | ✅ (Pro/Team/Enterprise for private repos) | ✅ (Pro/Team/Enterprise for private repos) | ❌ |
| Licence requirement | All plans (protection rules require Pro+) | All plans (protection rules require Pro+) | All plans |
| Connection refs / env vars | Individual `DataverseConnRef_*` / `DataverseEnvVar_*` in environment | Individual `DataverseConnRef_*` / `DataverseEnvVar_*` in environment | Prefixed `DataverseConnRef_*` / `DataverseEnvVar_*` **or** prefixed JSON variables |
| Entra ID setup | Federated credential per GitHub environment | Client secret | Client secret |

See [GitHub Setup Guide](../setup/github-setup.md) for detailed configuration steps.

---

## Automated setup behavior (`setup-github.ps1`)

`setup-github.ps1` automatically detects whether the selected repository supports
GitHub environment approvals and configures credentials accordingly:

- **Environment mode** (approvals available)
  - Creates/updates GitHub environments (for example `Dev-main`, `TEST`, `PROD`)
  - Stores credentials in those environments
  - Configures required reviewers on each environment
  - Generates deploy stages with `promotion-mode: environment-approval`

- **Fallback mode** (approvals unavailable)
  - Stores non-sensitive settings as prefixed repository variables
  - Stores any client secret in its matching GitHub environment
  - Uses derived variable prefixes such as `DEV_MAIN_`, `TEST_`, `PROD_` (or `PREFIX_`)
  - Generates deploy stages with `promotion-mode: manual-gate-tag` and manual dispatch from stage 1 onward

You can still change either mode manually after setup by editing your workflow YAML
and credential locations.

---

## Repository dispatch token for EXPORT → BUILD

The composite `EXPORT` action triggers `BUILD` by sending a `repository_dispatch`
event via the GitHub CLI/API after it pushes an export commit.

By default, this uses `GITHUB_TOKEN`. If your repository requires a separate token,
store one as an environment secret named `WORKFLOW_DISPATCH_TOKEN` (or legacy alias
`GH_WORKFLOW_TOKEN`) and add it to the Export workflow's `secrets-json` JSON object.

This token is separate from the Dataverse/Azure credentials shown below.

## Release and cleanup permissions

The BUILD caller needs `contents: write` to create the build tag and GitHub
Release, plus `actions: write` to publish the existing Actions artifacts. DEPLOY
needs `actions: read` for the BUILD fallback and `contents: write` for deployment
gate tags. `CLEANUP-RELEASES` needs `contents: write` to delete managed Releases
and create durable `alm4dataverse/metadata/` tags before deletion.

---

## Approach 1: Workload Identity Federation (OIDC)

Store the following in each GitHub environment (Settings > Environments > {Environment Name}).
**No client secret is needed.**

> Do **not** add `AZURE_CLIENT_SECRET`.  When the workflows detect its absence they
> automatically request an OIDC token from GitHub and set `AZURE_FEDERATED_TOKEN_FILE`
> for `DefaultAzureCredential`.

### Variables (non-sensitive values)

| Variable name | Description | Example value |
|---|---|---|
| `AZURE_CLIENT_ID` | Azure app registration (client) ID | `00000000-0000-0000-0000-000000000001` |
| `AZURE_TENANT_ID` | Entra ID tenant (directory) ID | `00000000-0000-0000-0000-000000000002` |
| `DATAVERSE_URL` | URL of the target Dataverse environment | `https://yourorg-test.crm.dynamics.com` |
| `DATAVERSESERVICEACCOUNTUPN` | UPN of the Dataverse service account | `svc-dataverse@contoso.com` |

Store each sensitive Dataverse environment-variable value as an individual secret and
map it to its `DataverseEnvVar_<schema_name>` runtime name in `secrets-json`.

### Entra ID federated credential setup

For each GitHub environment (Dev-main, TEST-main, PROD, …), add a federated credential
to the corresponding App Registration:

| Field | Value |
|---|---|
| Issuer | `https://token.actions.githubusercontent.com` |
| Subject identifier | `repo:{owner}@{owner-id}/{repo}@{repo-id}:environment:{environment-name}` |
| Audience | `api://AzureADTokenExchange` |

**Examples** for repo `MyOrg/MyApp` with owner ID `123456` and repository ID `456789`:

| GitHub environment | Subject identifier |
|---|---|
| `Dev-main` | `repo:MyOrg@123456/MyApp@456789:environment:Dev-main` |
| `TEST-main` | `repo:MyOrg@123456/MyApp@456789:environment:TEST-main` |
| `PROD` | `repo:MyOrg@123456/MyApp@456789:environment:PROD` |

The numeric IDs are the GitHub `repository_owner_id` and `repository_id` values.
They are included when the repository uses GitHub's immutable subject claims. The
automated setup script reads the repository setting and configures the matching subject;
existing repositories retain the legacy format unless immutable subjects are enabled.

For an existing legacy repository, setup offers to enable immutable subjects when WIF
is selected. Review the [GitHub changelog](https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens/#opt-in-for-existing-repositories)
first because other repository consumers that trust legacy subjects may need updates.

> ℹ️ **GitHub Free users**: GitHub Environments (for storing secrets/variables) work on
> all plans.  Only environment *protection rules* (required reviewers, wait timers) require
> Pro/Team/Enterprise for private repos.  You can still use the environment-based subject
> format on GitHub Free.

**Approach 3 (prefixed repository variables) — WIF subject:**

The copied caller jobs still run in a GitHub environment context when using
prefixed repository variables:

- `EXPORT.yml` / `IMPORT.yml`: default environment is `Dev-{branch}`
- `DEPLOY-main.yml`: uses the target environment name (for example `TEST-main`, `PROD`)

So for WIF, use the same environment-based subject format:

| Field | Value |
|---|---|
| Issuer | `https://token.actions.githubusercontent.com` |
| Subject identifier | `repo:{owner}@{owner-id}/{repo}@{repo-id}:environment:{environment-name}` |
| Audience | `api://AzureADTokenExchange` |

Create one federated credential per GitHub environment you deploy against
(for example `Dev-main`, `TEST-main`, `PROD`).

You can use one App Registration (and one set of federated credentials) for all
environments, or create separate App Registrations per environment for stronger
isolation.

📖 **References**:
- [Workload identity federation](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation)
- [GitHub OIDC with Azure](https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-azure)

### Per-solution connection references

For each connection reference used in your solutions, add a GitHub environment **variable**:

| Variable name | Description |
|---|---|
| `DataverseConnRef_<schema_name>` | Connection ID for the named connection reference |

### Per-solution environment variable values

For each non-sensitive Dataverse environment variable, add a GitHub environment
**variable**:

| Variable name | Description |
|---|---|
| `DataverseEnvVar_<schema_name>` | Value for the named Dataverse environment variable |

For each sensitive value, add its target name such as `DataverseEnvVar_contoso_APIKey`
to the `secrets-json` object with the corresponding individual GitHub secret reference.
Only entries explicitly listed there are passed.

### Example: complete Dev-main environment (WIF)

| Name | Type | Value |
|------|------|-------|
| `AZURE_CLIENT_ID` | Variable | `00000000-0000-0000-0000-000000000001` |
| `AZURE_TENANT_ID` | Variable | `00000000-0000-0000-0000-000000000002` |
| `DATAVERSESERVICEACCOUNTUPN` | Variable | `svc-dataverse@contoso.com` |
| `DATAVERSE_URL` | Variable | `https://yourorg-dev.crm.dynamics.com` |
| `DataverseConnRef_contoso_sharedsharepointonline` | Variable | `12345678-1234-1234-1234-123456789abc` |
| `DataverseEnvVar_contoso_APIEndpoint` | Variable | `https://api.dev.contoso.com` |

---

## Approach 2: GitHub Environments with client secret

Store the following in each GitHub environment.

### Secrets (sensitive values)

| Secret name | Description |
|---|---|
| `AZURE_CLIENT_SECRET` | Azure app registration client secret |

### Variables (non-sensitive values)

| Variable name | Description | Example value |
|---|---|---|
| `AZURE_CLIENT_ID` | Azure app registration (client) ID | `00000000-0000-0000-0000-000000000001` |
| `AZURE_TENANT_ID` | Entra ID tenant (directory) ID | `00000000-0000-0000-0000-000000000002` |
| `DATAVERSE_URL` | URL of the target Dataverse environment | `https://yourorg-test.crm.dynamics.com` |
| `DATAVERSESERVICEACCOUNTUPN` | UPN of the Dataverse service account | `svc-dataverse@contoso.com` |

### Per-solution connection references and environment variables

Same as Approach 1 — add `DataverseConnRef_*` and non-sensitive `DataverseEnvVar_*`
values in the GitHub environment. Store sensitive environment-variable values as
individual secrets and explicitly map them in `secrets-json`.

### Example: complete Dev-main environment (client secret)

| Name | Type | Value |
|------|------|-------|
| `AZURE_CLIENT_ID` | Variable | `00000000-0000-0000-0000-000000000001` |
| `AZURE_CLIENT_SECRET` | Secret | `<client secret value>` |
| `AZURE_TENANT_ID` | Variable | `00000000-0000-0000-0000-000000000002` |
| `DATAVERSESERVICEACCOUNTUPN` | Variable | `svc-dataverse@contoso.com` |
| `DATAVERSE_URL` | Variable | `https://yourorg-dev.crm.dynamics.com` |
| `DataverseConnRef_contoso_sharedsharepointonline` | Variable | `12345678-1234-1234-1234-123456789abc` |
| `DataverseEnvVar_contoso_APIEndpoint` | Variable | `https://api.dev.contoso.com` |

---

## Approach 3: Prefixed repository variables and secrets

Store non-sensitive configuration as prefixed repository variables and genuine secrets
as prefixed repository secrets (Settings > Secrets and variables > Actions). This manual
approach does not require storing values in GitHub environments.

The composite actions automatically map prefixed variable names to the unprefixed runtime
variables expected by the PowerShell scripts. Prefixed repository secrets are not
auto-discovered; explicitly map each one to its runtime name in each workflow's
`secrets-json` input using `toJSON(secrets.PREFIXED_SECRET_NAME)`.

Use an environment-specific prefix in each name.  The recommended prefix format is
`{ENV}_{BRANCH}_` for branch-scoped environments or `{ENV}_` for shared environments.

Mapping uses either:

- A derived prefix from the effective environment name (for example `Dev-main` → `DEV_MAIN_`)
- Or the literal fallback prefix `PREFIX_`

Examples in the tables below use `TEST_MAIN_` (for `TEST-main` environment) and
`PROD_` (for `PROD` environment).  Adjust to match your environment names.

### Variables

| Variable name | Description | Example value |
|---|---|---|
| `{PREFIX}AZURE_CLIENT_ID` | Azure app registration (client) ID | `00000000-0000-0000-0000-000000000001` |
| `{PREFIX}AZURE_TENANT_ID` | Entra ID tenant (directory) ID | `00000000-0000-0000-0000-000000000002` |
| `{PREFIX}DATAVERSE_SERVICE_ACCOUNT_UPN` | Dataverse service account UPN | `svc-dataverse@contoso.com` |
| `{PREFIX}DATAVERSE_URL` | Dataverse environment URL | `https://yourorg-test.crm.dynamics.com` |
| `{PREFIX}DATAVERSE_CONN_REFS` | JSON — connection reference values | See below |
| `{PREFIX}DataverseConnRef_<schema_name>` | Individual connection reference value | `12345678-1234-1234-1234-123456789abc` |
| `{PREFIX}DataverseEnvVar_<schema_name>` | Individual Dataverse environment variable value | `https://api.test.contoso.com` |

### Connection references JSON format

Create a single repository variable `{PREFIX}DATAVERSE_CONN_REFS` containing a JSON
object that maps each connection reference schema name to its connection ID:

```json
{
  "contoso_sharedsharepointonline": "12345678-1234-1234-1234-123456789abc",
  "contoso_sharedcommondataserviceforapps": "98765432-9876-9876-9876-987654321xyz"
}
```

### Individual Dataverse environment-variable values

Store non-sensitive values in individual prefixed repository variables, such as
`TEST_MAIN_DataverseEnvVar_contoso_APIEndpoint`. Store sensitive values in individual
prefixed repository secrets and map each one to its `DataverseEnvVar_<schema_name>`
runtime name in `secrets-json`.

> Client IDs, tenant IDs, URLs, connection IDs, and service-account UPNs are not
> credentials; store them as variables, not GitHub Secrets.

### Example: complete set of secrets/variables for two environments

#### TEST-main (`TEST_MAIN_` prefix)

| Name | Type | Value |
|------|------|-------|
| `TEST_MAIN_AZURE_CLIENT_ID` | Variable | `00000000-0000-0000-0000-000000000003` |
| `TEST_MAIN_AZURE_TENANT_ID` | Variable | `00000000-0000-0000-0000-000000000002` |
| `TEST_MAIN_DATAVERSE_SERVICE_ACCOUNT_UPN` | Variable | `svc-dataverse@contoso.com` |
| `TEST_MAIN_DATAVERSE_URL` | Variable | `https://yourorg-test.crm.dynamics.com` |
| `TEST_MAIN_DATAVERSE_CONN_REFS` | Variable | `{"contoso_sharedsharepointonline":"abc..."}` |
| `TEST_MAIN_DataverseEnvVar_contoso_APIEndpoint` | Variable | `https://api.test.contoso.com` |

#### PROD (`PROD_` prefix)

| Name | Type | Value |
|------|------|-------|
| `PROD_AZURE_CLIENT_ID` | Variable | `00000000-0000-0000-0000-000000000005` |
| `PROD_AZURE_TENANT_ID` | Variable | `00000000-0000-0000-0000-000000000002` |
| `PROD_DATAVERSE_SERVICE_ACCOUNT_UPN` | Variable | `svc-dataverse@contoso.com` |
| `PROD_DATAVERSE_URL` | Variable | `https://yourorg.crm.dynamics.com` |
| `PROD_DATAVERSE_CONN_REFS` | Variable | `{"contoso_sharedsharepointonline":"def..."}` |
| `PROD_DataverseEnvVar_contoso_APIEndpoint` | Variable | `https://api.contoso.com` |

---

Store `{PREFIX}AZURE_CLIENT_SECRET` (for client-secret authentication) and sensitive
Dataverse values as individual repository secrets, such as
`TEST_MAIN_DATAVERSE_API_KEY`. Map each sensitive value to its runtime name, such as
`DataverseEnvVar_contoso_APIKey`, in `secrets-json` for each workflow stage.

## How credentials flow to the PowerShell scripts

The ALM4Dataverse PowerShell scripts use the following OS environment variables:

| OS env var | Source |
|---|---|
| `AZURE_CLIENT_ID` | GitHub environment variable, or auto-mapped from prefixed repo variable |
| `AZURE_TENANT_ID` | GitHub environment variable, or auto-mapped from prefixed repo variable |
| `AZURE_CLIENT_SECRET` | Explicitly passed in `secrets-json` from the selected repository or GitHub environment secret |
| `DATAVERSE_URL` | GitHub environment variable, or auto-mapped from prefixed repo variable |
| `DATAVERSESERVICEACCOUNTUPN` | GitHub environment variable, or auto-mapped from prefixed repo variable |
| `DataverseConnRef_<name>` | GitHub environment variable (direct), prefixed repo variable auto-mapped, **or** expanded from prefixed JSON |
| `DataverseEnvVar_<name>` | Auto-mapped from a prefixed repository variable or explicitly selected secret |

The composite actions use one `azure/login@v3` step for both credential flows. When
`AZURE_CLIENT_SECRET` is absent, Azure Login uses `AZURE_CLIENT_ID` and
`AZURE_TENANT_ID` for GitHub OIDC. When it is present, the action supplies Azure
Login's `creds` JSON input, and `DefaultAzureCredential` also uses
`EnvironmentCredential` with `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, and
`AZURE_CLIENT_SECRET`.

---

## References

- [GitHub Setup Guide](../setup/github-setup.md)
- [Workload identity federation overview](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation)
- [GitHub OIDC with Azure](https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-azure)
- [Connection references overview](https://learn.microsoft.com/en-us/power-apps/maker/data-platform/create-connection-reference)
- [Environment variables overview](https://learn.microsoft.com/en-us/power-apps/maker/data-platform/environmentvariables)
- [GitHub encrypted secrets](https://docs.github.com/en/actions/security-guides/encrypted-secrets)
- [GitHub variables](https://docs.github.com/en/actions/learn-github-actions/variables)
- [GitHub Environments](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment)
