# GitHub Secrets & Variables Reference

This document describes every secret and variable used by the ALM4Dataverse GitHub
Actions workflows, and how they map to each of the three credential approaches.

> The reusable workflows do **not** accept credential/value `workflow_call` inputs
> (for example `dataverse-url`, `dataverse-connection-refs`, `dataverse-env-vars`)
> or secret inputs (`azure-client-id`, `azure-tenant-id`, etc.). Configure values
> using GitHub environment variables/secrets or prefixed repo-level secrets/variables.

---

## Approach comparison

| | WIF / OIDC | GitHub Environments + client secret | Prefixed global secrets |
|---|---|---|---|
| Secrets to manage | None | Client secret (rotate periodically) | Client secret (rotate periodically) |
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
  - Stores credentials as prefixed repository-level secrets/variables
  - Uses derived prefixes such as `DEV_MAIN_`, `TEST_`, `PROD_` (or `PREFIX_`)
  - Generates deploy stages with `promotion-mode: manual-gate-tag` and manual dispatch from stage 1 onward

You can still change either mode manually after setup by editing your workflow YAML
and credential locations.

---

## Repository dispatch token for EXPORT → BUILD

The reusable `EXPORT` workflow triggers `BUILD` by sending a `repository_dispatch`
event via the GitHub CLI/API after it pushes an export commit.

By default, this uses `GITHUB_TOKEN`. If your repository requires a separate token,
store one as a repository-level or environment-level secret named
`WORKFLOW_DISPATCH_TOKEN` (or legacy alias `GH_WORKFLOW_TOKEN`).

This token is separate from the Dataverse/Azure credentials shown below.

---

## Approach 1: Workload Identity Federation (OIDC)

Store the following in each GitHub environment (Settings > Environments > {Environment Name}).
**No client secret is needed.**

### Secrets (sensitive values)

| Secret name | Description |
|---|---|
| `DATAVERSESERVICEACCOUNTUPN` | UPN (email) of the Dataverse service account used to activate processes after deployment (optional as secret; can also be a variable) |

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

### Entra ID federated credential setup

For each GitHub environment (Dev-main, TEST-main, PROD, …), add a federated credential
to the corresponding App Registration:

| Field | Value |
|---|---|
| Issuer | `https://token.actions.githubusercontent.com` |
| Subject identifier | `repo:{owner}/{repo}:environment:{environment-name}` |
| Audience | `api://AzureADTokenExchange` |

**Examples** (repo `MyOrg/MyApp`):

| GitHub environment | Subject identifier |
|---|---|
| `Dev-main` | `repo:MyOrg/MyApp:environment:Dev-main` |
| `TEST-main` | `repo:MyOrg/MyApp:environment:TEST-main` |
| `PROD` | `repo:MyOrg/MyApp:environment:PROD` |

> ℹ️ **GitHub Free users**: GitHub Environments (for storing secrets/variables) work on
> all plans.  Only environment *protection rules* (required reviewers, wait timers) require
> Pro/Team/Enterprise for private repos.  You can still use the environment-based subject
> format on GitHub Free.

**Approach 3 (prefixed global secrets) — WIF subject:**

The current reusable workflows still run in a GitHub environment context when using
prefixed repo-level secrets/variables:

- `EXPORT.yml` / `IMPORT.yml`: default environment is `Dev-{branch}`
- `DEPLOY-main.yml`: uses the target environment name (for example `TEST-main`, `PROD`)

So for WIF, use the same environment-based subject format:

| Field | Value |
|---|---|
| Issuer | `https://token.actions.githubusercontent.com` |
| Subject identifier | `repo:{owner}/{repo}:environment:{environment-name}` |
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

For each Dataverse environment variable, add a GitHub environment **variable** (or
**secret** if the value is sensitive):

| Variable name | Description |
|---|---|
| `DataverseEnvVar_<schema_name>` | Value for the named Dataverse environment variable |

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
| `DATAVERSESERVICEACCOUNTUPN` | UPN (email) of the Dataverse service account used to activate processes after deployment (optional as secret; can also be a variable) |

### Variables (non-sensitive values)

| Variable name | Description | Example value |
|---|---|---|
| `AZURE_CLIENT_ID` | Azure app registration (client) ID | `00000000-0000-0000-0000-000000000001` |
| `AZURE_TENANT_ID` | Entra ID tenant (directory) ID | `00000000-0000-0000-0000-000000000002` |
| `DATAVERSE_URL` | URL of the target Dataverse environment | `https://yourorg-test.crm.dynamics.com` |
| `DATAVERSESERVICEACCOUNTUPN` | UPN of the Dataverse service account | `svc-dataverse@contoso.com` |

### Per-solution connection references and environment variables

Same as Approach 1 — add `DataverseConnRef_*` and `DataverseEnvVar_*` variables in
the GitHub environment.

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

## Approach 3: Prefixed global secrets

Store the following as repository-level secrets and variables
(Settings > Secrets and variables > Actions).

The reusable workflows automatically map prefixed names to the unprefixed runtime
variables expected by the PowerShell scripts. No per-workflow `secrets:` mapping is
required in `EXPORT.yml`, `IMPORT.yml`, or `DEPLOY-main.yml`.

Use an environment-specific prefix in each name.  The recommended prefix format is
`{ENV}_{BRANCH}_` for branch-scoped environments or `{ENV}_` for shared environments.

Mapping uses either:

- A derived prefix from the effective environment name (for example `Dev-main` → `DEV_MAIN_`)
- Or the literal fallback prefix `PREFIX_`

Examples in the tables below use `TEST_MAIN_` (for `TEST-main` environment) and
`PROD_` (for `PROD` environment).  Adjust to match your environment names.

### Secrets

| Secret name | Description |
|---|---|
| `{PREFIX}AZURE_CLIENT_ID` | Azure app registration (client) ID |
| `{PREFIX}AZURE_CLIENT_SECRET` | Azure client secret value (omit if using WIF) |
| `{PREFIX}AZURE_TENANT_ID` | Entra ID tenant (directory) ID |
| `{PREFIX}DATAVERSE_SERVICE_ACCOUNT_UPN` | UPN of the Dataverse service account |

### Variables

| Variable name | Description | Example value |
|---|---|---|
| `{PREFIX}DATAVERSE_URL` | Dataverse environment URL | `https://yourorg-test.crm.dynamics.com` |
| `{PREFIX}DATAVERSE_CONN_REFS` | JSON — connection reference values | See below |
| `{PREFIX}DATAVERSE_ENV_VARS` | JSON — environment variable values | See below |
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

### Environment variables JSON format

Create a single repository variable `{PREFIX}DATAVERSE_ENV_VARS` containing a JSON
object that maps each Dataverse environment variable schema name to its value:

```json
{
  "contoso_APIEndpoint": "https://api.test.contoso.com",
  "contoso_BatchSize": "50",
  "contoso_FeatureXEnabled": "true"
}
```

> **Sensitive env var values**: If any Dataverse environment variable value is sensitive,
> store the JSON as a **secret** rather than a variable, or consider using the GitHub
> Environments approach where individual values can be stored as secrets.

### Example: complete set of secrets/variables for two environments

#### TEST-main (`TEST_MAIN_` prefix)

| Name | Type | Value |
|------|------|-------|
| `TEST_MAIN_AZURE_CLIENT_ID` | Secret | `00000000-0000-0000-0000-000000000003` |
| `TEST_MAIN_AZURE_CLIENT_SECRET` | Secret | `<client secret>` |
| `TEST_MAIN_AZURE_TENANT_ID` | Secret | `00000000-0000-0000-0000-000000000002` |
| `TEST_MAIN_DATAVERSE_SERVICE_ACCOUNT_UPN` | Secret | `svc-dataverse@contoso.com` |
| `TEST_MAIN_DATAVERSE_URL` | Variable | `https://yourorg-test.crm.dynamics.com` |
| `TEST_MAIN_DATAVERSE_CONN_REFS` | Variable | `{"contoso_sharedsharepointonline":"abc..."}` |
| `TEST_MAIN_DATAVERSE_ENV_VARS` | Variable | `{"contoso_APIEndpoint":"https://api.test.contoso.com"}` |

#### PROD (`PROD_` prefix)

| Name | Type | Value |
|------|------|-------|
| `PROD_AZURE_CLIENT_ID` | Secret | `00000000-0000-0000-0000-000000000005` |
| `PROD_AZURE_CLIENT_SECRET` | Secret | `<client secret>` |
| `PROD_AZURE_TENANT_ID` | Secret | `00000000-0000-0000-0000-000000000002` |
| `PROD_DATAVERSE_SERVICE_ACCOUNT_UPN` | Secret | `svc-dataverse@contoso.com` |
| `PROD_DATAVERSE_URL` | Variable | `https://yourorg.crm.dynamics.com` |
| `PROD_DATAVERSE_CONN_REFS` | Variable | `{"contoso_sharedsharepointonline":"def..."}` |
| `PROD_DATAVERSE_ENV_VARS` | Variable | `{"contoso_APIEndpoint":"https://api.contoso.com"}` |

---

## How credentials flow to the PowerShell scripts

The ALM4Dataverse PowerShell scripts use the following OS environment variables:

| OS env var | Source |
|---|---|
| `AZURE_CLIENT_ID` | GitHub environment variable, or auto-mapped from prefixed repo secret/variable |
| `AZURE_TENANT_ID` | GitHub environment variable, or auto-mapped from prefixed repo secret/variable |
| `AZURE_CLIENT_SECRET` | GitHub environment secret, or auto-mapped from prefixed repo secret |
| `AZURE_FEDERATED_TOKEN_FILE` | Set by the WIF setup step — picked up by `DefaultAzureCredential` (WIF auth only) |
| `DATAVERSE_URL` | GitHub environment variable, or auto-mapped from prefixed repo variable |
| `DATAVERSESERVICEACCOUNTUPN` | GitHub environment variable/secret, or auto-mapped from prefixed repo secret/variable |
| `DataverseConnRef_<name>` | GitHub environment variable (direct), prefixed repo variable auto-mapped, **or** expanded from prefixed JSON |
| `DataverseEnvVar_<name>` | GitHub environment variable (direct), prefixed repo variable auto-mapped, **or** expanded from prefixed JSON |

**WIF flow**: when `AZURE_CLIENT_SECRET` is absent, the reusable workflow requests a
short-lived OIDC token from GitHub's token endpoint, writes it to a temp file under
`$RUNNER_TEMP`, and sets `AZURE_FEDERATED_TOKEN_FILE`.  `DefaultAzureCredential`
then uses its `WorkloadIdentityCredential` to exchange this token for an Entra ID
access token — no secrets are stored anywhere.

**Client secret flow**: when `AZURE_CLIENT_SECRET` is present, `DefaultAzureCredential`
uses `EnvironmentCredential` with `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, and
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
