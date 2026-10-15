# GitHub Secrets & Variables Reference

This is the canonical reference for credentials and target-specific values used by
the GitHub Actions integration. Follow the [configuration checklist](../setup/github-variables.md)
when adding an environment, and the [setup guide](../setup/github-setup.md) for initial setup.

Make three separate choices: how the app authenticates (WIF or client secret), where
values are stored (environment or repository values), and how promotion is
controlled (environment approval or manual gate tags). Storage location does not determine
authentication or grant approval capabilities.

> [!IMPORTANT]
> The composite actions receive repository variables as JSON and one `secrets-json` input
> containing only the named secret values selected by the caller. The resolver
> never enumerates the GitHub `secrets` context.

---

## Approach comparison

| Choice | Recommended starting point | Alternative |
| --- | --- | --- |
| Authentication | WIF/OIDC, with no client secret | Client secret when federation is unavailable |
| Settings storage | GitHub environment variables and explicitly selected secrets | Repository variables (optional environment prefix) and explicitly mapped repository secrets |
| Promotion | Environment approvals where the repository supports required reviewers | Manual dispatch with same-build predecessor gate tags |

> [!IMPORTANT]
> **Plan restrictions.** GitHub Free supports environments/secrets only for public
> repositories. Pro/Team support private environments, but required reviewers and wait
> timers remain public-repository features on those plans. Private approval rules require
> the appropriate Enterprise capability. Check [environment availability](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments#prerequisites)
> and [protection-rule availability](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments).
>
> Repository values do not remove the shipped jobs' environment dependency; setup also
> stores client secrets there. Use a supported plan, or explicitly adapt jobs, secret
> storage, and OIDC subjects together for an environment-free workflow.

See [GitHub Setup Guide](../setup/github-setup.md) for detailed configuration steps.

---

## Automated setup behavior (`setup-github.ps1`)

`setup-github.ps1` automatically detects whether the selected repository supports
GitHub environment approvals and configures credentials accordingly:

- **Environment mode** (setup detects approvals as available)
  - Creates/updates GitHub environments (for example `Dev-main`, `TEST`, `PROD`)
  - Stores credentials in those environments
  - Configures required reviewers on each environment
  - Generates deploy stages with `promotion-mode: environment-approval`

- **Fallback mode** (approvals unavailable)
  - Stores non-sensitive settings as repository variables, optionally prefixed by environment
  - Stores any client secret in its matching GitHub environment
  - Supports derived variable prefixes such as `DEV_MAIN_`, `TEST_`, and `PROD_`; prefixes are optional
  - Detects existing unprefixed repository credentials and keeps them unprefixed when setup is rerun
  - Generates deploy stages with `promotion-mode: manual-gate-tag` and manual dispatch from stage 1 onward

You can still change either mode manually after setup by editing your workflow YAML
and credential locations. Confirm that the resulting environments and protection rules
really exist and are supported by your plan before treating a target as protected.

---

## Repository dispatch token for EXPORT → BUILD

The composite `EXPORT` action triggers `BUILD` by sending a `repository_dispatch`
event via the GitHub CLI/API after it pushes an export commit.

By default, this uses `GITHUB_TOKEN`. If your repository requires a separate token,
store one as an environment secret named `WORKFLOW_DISPATCH_TOKEN` (or legacy alias
`GH_WORKFLOW_TOKEN`) and add it to the Export workflow's `secrets-json` JSON object.

This token is separate from the Dataverse/Azure credentials shown below.

## Release and cleanup permissions

The supplied BUILD and EXPORT callers declare `contents: write`, `actions: write`,
and `id-token: write`. DEPLOY declares `actions: read`, `contents: write`, and
`id-token: write`; IMPORT declares `contents: read` and `id-token: write`.
`CLEANUP-RELEASES` declares `contents: write`. See the
[caller permissions reference](pipelines.md#caller-settings-and-permissions).

---

## Approach 1: Workload Identity Federation (OIDC)

Store the following in each GitHub environment (Settings > Environments > {Environment Name}).
**No client secret is needed.**

> [!IMPORTANT]
> Leave `AZURE_CLIENT_SECRET` unset for WIF. The actions use `azure/login@v3` for OIDC
> authentication with `id-token: write` and `allow-no-subscriptions: true`. Dataverse
> scripts and PAC reuse the resulting non-interactive Azure identity context.

### Variables (non-sensitive values)

| Variable name | Description | Example value |
| --- | --- | --- |
| `AZURE_CLIENT_ID` | Azure app registration (client) ID | `00000000-0000-0000-0000-000000000001` |
| `AZURE_TENANT_ID` | Entra ID tenant (directory) ID | `00000000-0000-0000-0000-000000000002` |
| `DATAVERSE_URL` | URL of the target Dataverse environment | `https://yourorg-test.crm.dynamics.com` |
| `DATAVERSESERVICEACCOUNTUPN` | UPN of the Dataverse service account | `svc-dataverse@contoso.com` |

BUILD only resolves these action inputs when `environment-name` is nonempty.
EXPORT requires the client ID, tenant ID, and URL. IMPORT, DEPLOY, and authenticated
BUILD additionally validate that `DATAVERSESERVICEACCOUNTUPN` is present, including
when individual solutions have custom owner keys. This is a real enabled Dataverse
user with the required licensing, roles, and connection access, not the app registration.

`AZURE_TENANT_ID` can be a tenant GUID or tenant domain. Use the Dataverse base URL
for `DATAVERSE_URL`, not a maker-portal URL. These identifiers and URLs normally belong
in variables; genuine secrets belong in Secrets.

Store each sensitive Dataverse environment-variable value as an individual secret and
map it to its `DataverseEnvVar_<schema_name>` runtime name in `secrets-json`.

### Entra ID federated credential setup

For each GitHub environment (Dev-main, TEST-main, PROD, …), add a federated credential
to the corresponding App Registration:

| Field | Value |
| --- | --- |
| Issuer | `https://token.actions.githubusercontent.com` |
| Subject identifier | `repo:{owner}@{owner-id}/{repo}@{repo-id}:environment:{environment-name}` |
| Audience | `api://AzureADTokenExchange` |

> [!IMPORTANT]
> The subject above is the **immutable** format. A repository using legacy subjects needs
> `repo:{owner}/{repo}:environment:{environment-name}` instead. Check its OIDC setting
> before copying a subject. Matching is exact, including case and GitHub's escaping of
> `:` as `%3A` in context values.

**Examples** for repo `MyOrg/MyApp` with owner ID `123456` and repository ID `456789`:

| GitHub environment | Subject identifier |
| --- | --- |
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

> [!NOTE]
> **Advanced: custom job subjects.** An environment-based subject requires a job that
> declares that environment. If you
> remove `environment` from a custom job, configure the corresponding branch or PR
> subject instead. Changing only secret locations does not change the OIDC subject.

**Approach 3 (repository variables with optional prefixes) — WIF subject:**

The copied caller jobs still run in a GitHub environment context when using
repository variables:

- `EXPORT.yml` / `IMPORT.yml`: default environment is `Dev-{branch}`
- `DEPLOY-main.yml`: uses the target environment name (for example `TEST-main`, `PROD`)

So for WIF, use the same environment-based subject format:

| Field | Value |
| --- | --- |
| Issuer | `https://token.actions.githubusercontent.com` |
| Subject identifier | `repo:{owner}@{owner-id}/{repo}@{repo-id}:environment:{environment-name}` |
| Audience | `api://AzureADTokenExchange` |

Create one federated credential per GitHub environment you deploy against
(for example `Dev-main`, `TEST-main`, `PROD`).

When BUILD validation is enabled, include its named validation environment as well.
Repository dispatch runs execute the workflow from the default branch, even when the
payload identifies another source branch; account for that when using branch-based
OIDC or environment deployment-branch policies in a custom setup.

You can use one App Registration (and one set of federated credentials) for all
environments, or create separate App Registrations per environment for stronger
isolation.

**References**:

- [Workload identity federation](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation)
- [GitHub OIDC with Azure](https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-azure)

### Per-solution connection references

For each connection reference used in your solutions, add a GitHub environment **variable**:

| Variable name | Description |
| --- | --- |
| `DataverseConnRef_<schema_name>` | Connection ID for the named connection reference |

### Per-solution environment variable values

For each non-sensitive Dataverse environment variable, add a GitHub environment
**variable**:

| Variable name | Description |
| --- | --- |
| `DataverseEnvVar_<schema_name>` | Value for the named Dataverse environment variable |

For each sensitive value, add its target name such as `DataverseEnvVar_contoso_APIKey`
to the `secrets-json` object with the corresponding individual GitHub secret reference.
Only entries explicitly listed there are passed.

To select an individual secret, add it to the action's `secrets-json` input. This is
a field inside the existing action `with` mapping:

```yaml
secrets-json: >-
    {
      "AZURE_CLIENT_SECRET": ${{ toJSON(secrets.AZURE_CLIENT_SECRET) }},
      "DataverseEnvVar_contoso_APIKey": ${{ toJSON(secrets.DATAVERSE_API_KEY) }}
    }
```

GitHub does not automatically forward every secret to a composite action. Use JSON
serialization for each value, including empty values, so quotes and newlines remain valid.
The resolver skips null, empty, and whitespace-only values; this mechanism is not a
general way to clear an existing Dataverse value with an empty string.

> [!NOTE]
> **Advanced: custom process owners.** For `serviceAccountUpnConfigKey = 'ContosoFlowOwner'`,
> supply `CONTOSOFLOWOWNER` in the caller's `env` mapping or as a repository variable.
> Prefix the variable with the active environment name (for example,
> `TEST_MAIN_CONTOSOFLOWOWNER`) to override an unprefixed repository value.

### Example: complete Dev-main environment (WIF)

| Name | Type | Value |
| --- | --- | --- |
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
| --- | --- |
| `AZURE_CLIENT_SECRET` | Azure app registration client secret |

Use the secret's **value**, not its ID. A nonempty client secret selects client-secret
authentication; remove its mapping/value when switching to WIF. Rotate expiring secrets
in each location that supplies them and validate the new credential before deleting the old one.

### Client-Secret Variables (Non-Sensitive Values)

| Variable name | Description | Example value |
| --- | --- | --- |
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
| --- | --- | --- |
| `AZURE_CLIENT_ID` | Variable | `00000000-0000-0000-0000-000000000001` |
| `AZURE_CLIENT_SECRET` | Secret | `<client secret value>` |
| `AZURE_TENANT_ID` | Variable | `00000000-0000-0000-0000-000000000002` |
| `DATAVERSESERVICEACCOUNTUPN` | Variable | `svc-dataverse@contoso.com` |
| `DATAVERSE_URL` | Variable | `https://yourorg-dev.crm.dynamics.com` |
| `DataverseConnRef_contoso_sharedsharepointonline` | Variable | `12345678-1234-1234-1234-123456789abc` |
| `DataverseEnvVar_contoso_APIEndpoint` | Variable | `https://api.dev.contoso.com` |

---

## Approach 3: Repository variables and secrets

Store non-sensitive configuration as repository variables and genuine secrets as
repository secrets (Settings > Secrets and variables > Actions). This manual approach
does not require storing values in GitHub environments. Variable names may be unprefixed
or use an environment-specific prefix; when both are defined, the active environment's
prefixed value takes precedence.

The composite actions automatically map repository variables to runtime variables
expected by the PowerShell scripts. Environment-specific prefixes are optional and are
removed during mapping; when both prefixed and unprefixed values exist, the prefixed value
wins. Repository secrets are not auto-discovered; explicitly map each one to its runtime name in each workflow's
`secrets-json` input using `toJSON(secrets.PREFIXED_SECRET_NAME)`.

When using an environment-specific prefix, the recommended format is
`{ENV}_{BRANCH}_` for branch-scoped environments or `{ENV}_` for shared environments.

Environment-prefixed variables use the effective environment name (for example
`Dev-main` → `DEV_MAIN_`). The prefix is optional; unprefixed variables fill values not
provided for the active environment.

Examples in the tables below use `TEST_MAIN_` (for `TEST-main` environment) and
`PROD_` (for `PROD` environment).  Adjust to match your environment names.

### Variables

| Variable name | Description | Example value |
| --- | --- | --- |
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
  "contoso_sharedcommondataserviceforapps": "98765432-9876-9876-9876-987654321abc"
}
```

### Individual Dataverse environment-variable values

Store non-sensitive values in individual repository variables, optionally using an
environment prefix such as `TEST_MAIN_DataverseEnvVar_contoso_APIEndpoint`. Store sensitive values in individual
prefixed repository secrets and map each one to its `DataverseEnvVar_<schema_name>`
runtime name in `secrets-json`.

> [!TIP]
> Client IDs, tenant IDs, URLs, connection IDs, and service-account UPNs are not
> credentials; store them as variables, not GitHub Secrets.

### Example: complete set of secrets/variables for two environments

#### TEST-main (`TEST_MAIN_` prefix)

| Name | Type | Value |
| --- | --- | --- |
| `TEST_MAIN_AZURE_CLIENT_ID` | Variable | `00000000-0000-0000-0000-000000000003` |
| `TEST_MAIN_AZURE_TENANT_ID` | Variable | `00000000-0000-0000-0000-000000000002` |
| `TEST_MAIN_DATAVERSE_SERVICE_ACCOUNT_UPN` | Variable | `svc-dataverse@contoso.com` |
| `TEST_MAIN_DATAVERSE_URL` | Variable | `https://yourorg-test.crm.dynamics.com` |
| `TEST_MAIN_DATAVERSE_CONN_REFS` | Variable | `{"contoso_sharedsharepointonline":"abc..."}` |
| `TEST_MAIN_DataverseEnvVar_contoso_APIEndpoint` | Variable | `https://api.test.contoso.com` |

#### PROD (`PROD_` prefix)

| Name | Type | Value |
| --- | --- | --- |
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
| --- | --- |
| `AZURE_CLIENT_ID` | GitHub environment variable, or auto-mapped from an unprefixed or environment-prefixed repository variable |
| `AZURE_TENANT_ID` | GitHub environment variable, or auto-mapped from an unprefixed or environment-prefixed repository variable |
| `AZURE_CLIENT_SECRET` | Explicitly passed in `secrets-json` from the selected repository or GitHub environment secret |
| `DATAVERSE_URL` | GitHub environment variable, or auto-mapped from an unprefixed or environment-prefixed repository variable |
| `DATAVERSESERVICEACCOUNTUPN` | GitHub environment variable, or auto-mapped from an unprefixed or environment-prefixed repository variable |
| `DataverseConnRef_<name>` | GitHub environment variable (direct), repository variable auto-mapped, **or** expanded from connection-reference JSON |
| `DataverseEnvVar_<name>` | Direct or repository variable (unprefixed or environment-prefixed), or explicitly selected secret |

The composite actions use one `azure/login@v3` step for both credential flows. When
`AZURE_CLIENT_SECRET` is absent, Azure Login uses `AZURE_CLIENT_ID` and
`AZURE_TENANT_ID` for GitHub OIDC. When it is present, the action supplies Azure
Login's `creds` JSON input, and `DefaultAzureCredential` also uses
`EnvironmentCredential` with `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, and
`AZURE_CLIENT_SECRET`.

### Mapping Order And Aliases

1. Explicit nonempty `secrets-json` entries set their exact runtime names, overriding existing values.
2. Existing nonempty runtime values are preserved when variables are mapped.
3. Environment-specific prefixed variables fill unset values.
4. Unprefixed variables fill remaining unset values.

The prefix is the effective environment name, uppercased, with runs of non-alphanumeric
characters replaced by `_`, plus a trailing `_`: `TEST-main` becomes `TEST_MAIN_`.
When both prefixed and unprefixed values target the same runtime variable, the
environment-specific value takes precedence.

For prefixed variables, `DATAVERSE_SERVICE_ACCOUNT_UPN` also populates
`DATAVERSESERVICEACCOUNTUPN`, and `DATAVERSE_CONN_REFS` also populates
`DATAVERSE_CONNECTION_REFS`. The direct standard service-account name is
`DATAVERSESERVICEACCOUNTUPN`. The direct JSON connection map accepts
`DATAVERSE_CONNECTION_REFS` or `DATAVERSE_CONN_REFS`.

> [!TIP]
> Configure each connection reference in either JSON or an individual variable, not both.
> The calling action expands JSON before deployment. This supplies connection IDs; it
> does not create Power Platform connections or grant sharing permissions.

`WORKFLOW_DISPATCH_TOKEN` is the runtime name for the optional EXPORT dispatch token.
The copied EXPORT mapping also accepts the stored secret name `GH_WORKFLOW_TOKEN` as
a legacy alias.

> [!NOTE]
> **Advanced: internal values.** `ALM_AZURE_CREDENTIALS`, `VARS_JSON`,
> `SELECTED_SECRETS_JSON`, and `RESOLVED_ENVIRONMENT_NAME` are produced by the actions.
> Do not create them as application settings.

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
