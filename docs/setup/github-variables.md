# GitHub Variables & Secrets Configuration

This document describes how to configure the variables and secrets consumed by the ALM4Dataverse GitHub Actions workflows.

## Overview

Each environment requires credentials and settings stored in one of two places:

| | GitHub Environments | Prefixed repo-level secrets/variables |
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

| Secret | Description |
|---|---|
| `DATAVERSESERVICEACCOUNTUPN` | Optional — store as a secret if the value is sensitive |

**Client secret:**

| Secret | Description |
|---|---|
| `AZURE_CLIENT_SECRET` | App Registration client secret value |
| `DATAVERSESERVICEACCOUNTUPN` | Optional — store as a secret if the value is sensitive |

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

## Approach 2 — Prefixed repo-level secrets/variables

Store all credentials as repository-level secrets and variables in **Settings > Secrets and variables > Actions**.

Derive a prefix from the effective GitHub environment name:

| GitHub environment | Prefix |
|---|---|
| `Dev-main` | `DEV_MAIN_` |
| `TEST-main` | `TEST_MAIN_` |
| `PROD` | `PROD_` |

### Secrets

| Secret | Description |
|---|---|
| `{PREFIX}AZURE_CLIENT_ID` | App Registration (client) ID |
| `{PREFIX}AZURE_CLIENT_SECRET` | Client secret value — omit if using WIF |
| `{PREFIX}AZURE_TENANT_ID` | Entra ID tenant (directory) ID |
| `{PREFIX}DATAVERSE_SERVICE_ACCOUNT_UPN` | Dataverse service account UPN |

### Variables

| Variable | Description | Example |
|---|---|---|
| `{PREFIX}DATAVERSE_URL` | Dataverse environment URL | `https://yourorg.crm.dynamics.com` |
| `{PREFIX}DATAVERSE_CONN_REFS` | JSON — connection reference values | See below |
| `{PREFIX}DATAVERSE_ENV_VARS` | JSON — environment variable values | See below |
| `{PREFIX}DataverseConnRef_{schema_name}` | Individual connection reference value | `12345678-...` |
| `{PREFIX}DataverseEnvVar_{schema_name}` | Individual Dataverse environment variable | `https://api.contoso.com` |

### Connection references JSON format

```json
{
  "contoso_sharedsharepointonline": "12345678-1234-1234-1234-123456789abc"
}
```

### Environment variables JSON format

```json
{
  "contoso_APIEndpoint": "https://api.test.contoso.com",
  "contoso_FeatureXEnabled": "true"
}
```

### WIF federated credential configuration

Even when using prefixed repo-level secrets, workflows still run within a named GitHub environment. Use the same federated credential subject format as Approach 1 — one federated credential per GitHub environment.

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
