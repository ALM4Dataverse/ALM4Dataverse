# GitHub Variables & Secrets Configuration

This document describes how to configure the variables and secrets consumed by the ALM4Dataverse GitHub Actions workflows.

## Overview

Each environment requires credentials and settings stored in one of two places:

| | GitHub environments for secrets + values | Prefixed repo variables + secrets |
|---|---|---|
| Location | Settings > Environments > *{EnvironmentName}* | Settings > Secrets and variables > Actions |
| Approval gates | ✅ Pro/Team/Enterprise for private repos | ❌ |
| Name prefix | Not required | Required (e.g. `TEST_MAIN_`) |

Both approaches support **Workload Identity Federation (WIF/OIDC)** or **client secret** authentication.

---

## GitHub environment names

ALM4Dataverse workflows use the following GitHub environment names:

| Workflow | GitHub environment |
|---|---|
| Export / Import | `Dev-{branch}` (e.g. `Dev-main`) |
| Deploy | The deployment environment name (e.g. `TEST-main`, `PROD`) |

---

## Approach 1 — GitHub Environments

Store each environment's credentials in **Settings > Environments > *{EnvironmentName}***.
This approach is preferred, but not all GitHub repos have access to the environment feature. See below for an alternative.

### Variables

| Variable | Description | Example |
|---|---|---|
| `AZURE_CLIENT_ID` | App Registration (client) ID | `00000000-0000-0000-0000-000000000001` |
| `AZURE_TENANT_ID` | Entra ID tenant (directory) ID | `00000000-0000-0000-0000-000000000002` |
| `DATAVERSE_URL` | Dataverse environment URL | `https://yourorg.crm.dynamics.com` |
| `DATAVERSESERVICEACCOUNTUPN` | Dataverse service account UPN | `svc-dataverse@contoso.com` |
| `DataverseConnRef_{schema_name}` | Connection ID for each connection reference | `12345678-...` |
| `DataverseEnvVar_{schema_name}` | Value for each Dataverse environment variable | `https://api.contoso.com` |

### Secrets

**WIF/OIDC** — no client secret needed. Omit `AZURE_CLIENT_SECRET`; the workflow requests an OIDC token automatically.

For client-secret authentication, add `AZURE_CLIENT_SECRET` to the environment secrets
and explicitly list it in the workflow's `secrets-json` JSON object. Sensitive Dataverse
environment-variable values should also be stored as individual secrets and mapped to
their `DataverseEnvVar_<schema_name>` runtime names in `secrets-json`.

| Secret | Description |
|---|---|
| `AZURE_CLIENT_SECRET` | App Registration client secret value |

| Secret | Description |
|---|---|
| `AZURE_CLIENT_SECRET` | App Registration client secret value |

### WIF federated credential configuration

For each GitHub environment, add a federated credential to the App Registration in Entra ID:

| Field | Value |
|---|---|
| Issuer | `https://token.actions.githubusercontent.com` |
| Subject identifier | `repo:{owner}@{owner-id}/{repo}@{repo-id}:environment:{environment-name}` |
| Audience | `api://AzureADTokenExchange` |

**Examples** for repo `MyOrg/MyApp` with owner ID `123456` and repository ID `456789`:

| Environment | Subject identifier |
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

> ℹ️ GitHub Environments (for storing secrets/variables) are available on all plans. Environment *protection rules* (required reviewers, wait timers) require Pro/Team/Enterprise for private repositories.

---

## Approach 2 — Prefixed repo-level variables and secrets

This approach is recommended only if your repo doesn't have access to the environments feature in GitHub.

Store non-sensitive settings as repository-level variables in **Settings > Secrets and variables > Actions**.
Store sensitive values as prefixed repository secrets in the same settings page. This approach does
not require access to GitHub environment secrets. Prefixed variables are resolved automatically;
prefixed secrets must be explicitly mapped in each workflow's `secrets-json` input.

Derive a prefix from the effective GitHub environment name:

| GitHub environment | Prefix |
|---|---|
| `Dev-main` | `DEV_MAIN_` |
| `TEST-main` | `TEST_MAIN_` |
| `PROD` | `PROD_` |

### Variables

| Variable | Description | Example |
|---|---|---|
| `{PREFIX}AZURE_CLIENT_ID` | App Registration (client) ID | `00000000-0000-0000-0000-000000000001` |
| `{PREFIX}AZURE_TENANT_ID` | Entra ID tenant (directory) ID | `00000000-0000-0000-0000-000000000002` |
| `{PREFIX}DATAVERSE_SERVICE_ACCOUNT_UPN` | Dataverse service account UPN | `svc-dataverse@contoso.com` |
| `{PREFIX}DATAVERSE_URL` | Dataverse environment URL | `https://yourorg.crm.dynamics.com` |
| `{PREFIX}DATAVERSE_CONN_REFS` | JSON — connection reference values | See below |
| `{PREFIX}DataverseConnRef_{schema_name}` | Individual connection reference value | `12345678-...` |
| `{PREFIX}DataverseEnvVar_{schema_name}` | Individual Dataverse environment variable | `https://api.contoso.com` |

### Connection references JSON format

```json
{
  "contoso_sharedsharepointonline": "12345678-1234-1234-1234-123456789abc"
}
```

### Individual Dataverse environment variables

Store non-sensitive values as individual prefixed repository variables, for example
`TEST_MAIN_DataverseEnvVar_contoso_APIEndpoint`. Store sensitive values as individual
prefixed repository secrets, such as `TEST_MAIN_DATAVERSE_API_KEY`, and map each secret
to its `DataverseEnvVar_<schema_name>` runtime name in `secrets-json`.

### Secrets and workflow mapping

Create prefixed repository secrets as needed. Omit the client secret when using WIF/OIDC.

| Name | Type | Value |
|------|------|-------|
| `TEST_MAIN_AZURE_CLIENT_SECRET` | Secret | App registration client secret |
| `TEST_MAIN_DATAVERSE_API_KEY` | Secret | Sensitive Dataverse environment-variable value |

Map each secret explicitly to the runtime name expected by the scripts. For example, a
`TEST-main` deployment stage uses:

```yaml
# Add any custom secrets explicitly to this JSON object.
secrets-json: >-
  {
    "AZURE_CLIENT_SECRET": ${{ toJSON(secrets.TEST_MAIN_AZURE_CLIENT_SECRET) }},
    "DataverseEnvVar_contoso_APIKey": ${{ toJSON(secrets.TEST_MAIN_DATAVERSE_API_KEY) }}
  }
```

Use the matching prefix for each deployment stage (for example, `PROD_` for `PROD`).
EXPORT and IMPORT use the prefix for their `Dev-{branch}` environment. Add other secrets
by name in the same JSON object; prefixed repository secrets are not auto-discovered.

### WIF federated credential configuration

Workflows still declare the named GitHub environment for the OIDC subject and pass that
name to the action, but this approach stores no variables or secrets in the environment.
Use the same federated credential subject format as Approach 1 — one federated credential
per GitHub environment.

---

## Application user

Create an application user in each Dataverse environment for the App Registration and assign the **System Administrator** security role.

📖 [Create an application user in Dataverse](https://learn.microsoft.com/en-us/power-platform/admin/manage-application-users)

---

## References

- [GitHub Secrets & Variables Reference](../config/github-secrets.md)
- [GitHub Setup Guide](github-setup.md)
- [Workload identity federation](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation)
- [GitHub OIDC with Azure](https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-azure)
- [GitHub encrypted secrets](https://docs.github.com/en/actions/security-guides/encrypted-secrets)
- [GitHub Environments](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment)
