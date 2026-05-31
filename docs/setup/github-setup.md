# GitHub Actions Setup Guide

This guide describes how to set up ALM4Dataverse for use with GitHub Actions.

> **Automated setup**: For most users, the easiest option is to run `setup-github.ps1` which automates
> all of the steps below. See [GitHub Variables & Secrets](github-variables.md) for the credential configuration reference.

> `setup-github.ps1` automatically selects deployment mode per repository:
> - Uses GitHub environments + approvals + `promotion-mode: environment-approval` when supported.
> - Falls back to prefixed repo-level credentials + `promotion-mode: manual-gate-tag` when not.

> **Azure DevOps users**: if you are using Azure DevOps, follow the [Azure DevOps setup guide](azdo-manual-setup.md) instead.

---

## Overview

ALM4Dataverse provides four reusable workflows hosted in the ALM4Dataverse repository.
You call them from your own repository's workflow files, which you copy from the
`copy-to-your-repo/.github/workflows/` folder.

| Your workflow | Reusable workflow called | Purpose |
|---|---|---|
| `BUILD.yml` | `build.yml` | Pack solutions, upload artifacts, tag commit |
| `EXPORT.yml` | `export.yml` | Export from dev Dataverse, commit to repo |
| `IMPORT.yml` | `import.yml` | Build from source, import into dev Dataverse |
| `DEPLOY-main.yml` | `deploy.yml` | Deploy artifacts to each environment |

---

## Prerequisites

### 1. GitHub repository

Create or use an existing GitHub repository for your Dataverse application source code.

### 2. App Registration in Entra ID

For each Dataverse environment (Dev, Test, UAT, Production…), create an App Registration
in Entra ID to act as a service principal.

1. Navigate to the [Azure Portal](https://portal.azure.com) > **Entra ID** > **App registrations**
2. Click **New registration**
3. Name: `{ProjectName} - {EnvironmentName} - deployment` (e.g. `MyProject - PROD - deployment`)
4. Select "Accounts in this organizational directory only"
5. Click **Register**
6. Note the **Application (client) ID** and **Directory (tenant) ID**

You do not need to create a client secret if you use Workload Identity Federation (see below).
If you prefer client secret authentication, go to **Certificates & secrets** > **New client secret**
and copy the **Value** immediately after creation.

📖 **Reference**: [Register an app with Entra ID](https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-register-app)

### 3. Configure authentication for the App Registration

Choose one of the following authentication methods.

#### Option A: Workload Identity Federation / OIDC (recommended)

Workload Identity Federation lets GitHub Actions authenticate to Azure using short-lived
OIDC tokens with no secrets to manage or rotate.

1. In the App Registration, go to **Certificates & secrets** > **Federated credentials**
2. Click **Add credential**
3. Select **Other issuer**
4. Fill in:
   - **Issuer**: `https://token.actions.githubusercontent.com`
   - **Subject identifier**: depends on how the workflow runs (see below)
   - **Name**: e.g. `github-{environment-name}` (alphanumeric and hyphens only)
   - **Audience**: `api://AzureADTokenExchange`
5. Click **Add**

**Subject identifier format for GitHub Actions:**

| Workflow scenario | Subject identifier |
|---|---|
| Default ALM4Dataverse workflows (Approach 1, 2, and 3) | `repo:{owner}/{repo}:environment:{environment-name}` |

> **Examples** for repo `MyOrg/MyApp`:
> - Environment-based: `repo:MyOrg/MyApp:environment:TEST-main`

ALM4Dataverse reusable workflows run within a named GitHub environment across all
credential approaches:

- `EXPORT` / `IMPORT` default to `Dev-{branch}` when `environment-name` is not passed.
- `DEPLOY` uses the target environment name (for example `TEST-main`, `PROD`).

Create one federated credential per GitHub environment (Dev-main, TEST-main, PROD, etc.).

> ℹ️ **GitHub Environments and GitHub Free**: GitHub Environments themselves (for storing
> secrets and variables) work on all plans including GitHub Free.  Only *environment
> protection rules* (required reviewers, wait timers) require GitHub Pro, Team, or Enterprise
> for private repositories.  GitHub Free users can use Approach 1, 2, or 3 with environment-based
> WIF subjects — they just cannot configure approval gates via protection rules (use the
> [gate tag mechanism](#deployment-gates-for-github-free) instead).

📖 **References**:
- [Workload identity federation](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation)
- [GitHub OIDC with Azure](https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-azure)

#### Option B: Client secret (traditional)

1. In the App Registration, go to **Certificates & secrets** > **New client secret**
2. Add a description and expiry period
3. Copy the **Value** immediately — you cannot view it again

### 4. Application user in each Dataverse environment

1. Go to the [Power Platform Admin Center](https://admin.powerplatform.microsoft.com)
2. Select the environment > **Settings** > **Users + permissions** > **Application users**
3. Click **New app user** > add your App Registration
4. Assign the **System Administrator** security role
5. Click **Create**

📖 **Reference**: [Create an application user](https://learn.microsoft.com/en-us/power-platform/admin/manage-application-users)

---

## Repository Setup

### Copy workflow templates to your repository

Copy all files from `copy-to-your-repo/` in the ALM4Dataverse repository into the root
of your application repository, preserving the folder structure:

```
your-repo/
├── .github/
│   └── workflows/
│       ├── BUILD.yml
│       ├── EXPORT.yml
│       ├── IMPORT.yml
│       └── DEPLOY-main.yml   ← all environments; manual from stage 1 by default
├── alm-config.psd1
└── data/
```

### Configure `alm-config.psd1`

Edit `alm-config.psd1` to list the solutions you want to manage:

```powershell
@{
    solutions = @(
        @{ name = 'YourSolutionUniqueName' }
        @{ name = 'AnotherSolution' }
    )
}
```

### Configure deployment environments in `DEPLOY-main.yml`

`DEPLOY-main.yml` uses one **stage/job per environment**.

To configure it, edit only:

- each stage's `promotion-mode` value:
  - `manual-gate-tag` (GitHub Free compatible; manual deployment + gate tag)
  - `environment-approval` (auto-chain after previous stage success; relies on environment protection rules)
- the `repository_dispatch` trigger **only when using** `environment-approval`
- `workflow_dispatch.inputs.target-environment`
- the `deploy-*` jobs (one per environment, with `needs` chaining)
- keep the context payload lines unchanged in each stage:
  - `trigger-branch: <workflow-branch-name>`
  - `github-context-json: ${{ toJSON(github) }}`
  - `caller-inputs-json: ${{ toJSON(inputs) }}`

If you used `setup-github.ps1`, this value is generated automatically based on
repository capability detection:

- `environment-approval` when GitHub environment approvals are available.
- `manual-gate-tag` when approvals are unavailable (prefixed credential fallback).

Behavior remains simple:

- **`manual-gate-tag`**: every stage is triggered manually from **Actions** > **DEPLOY-main** > **Run workflow**; `target-environment` remains mandatory, while `build-run-name` can be supplied explicitly or left blank to use the latest successful BUILD from the selected branch.
- **`environment-approval`**: when BUILD succeeds, it sends a `repository_dispatch` event and stage 1 starts automatically for matching branch workflows; later stages auto-chain only after the previous stage succeeds and any environment approval rules pass. For a manual replay, `target-environment` can be left blank to start from the first configured stage, or set to a specific environment name to jump directly to that stage.

  The dispatch event type is branch-scoped using:
  `alm4dataverse-build-deploy-{branch-token}`
  where `{branch-token}` is the lowercase branch name with non-alphanumeric
  characters replaced by `-` (for example `main` → `main`,
  `feature/my-work` → `feature-my-work`).

  Each DEPLOY stage must pass the matching branch via:
  `trigger-branch: <workflow-branch-name>`.

See [Deployment Gates for GitHub Free](#deployment-gates-for-github-free).

If your default branch is not `main`:
- Rename `DEPLOY-main.yml` to `DEPLOY-{branchname}.yml`
- Ensure your BUILD dispatch payload branch value matches the DEPLOY workflow branch name.

### Workflow job timeouts

ALM4Dataverse aligns GitHub Actions timeout defaults with the Azure DevOps templates:

- Reusable workflows (`build.yml`, `export.yml`, `import.yml`, `deploy.yml`) default to `timeout-minutes: 360`.
- Copied workflow stubs (`BUILD.yml`, `EXPORT.yml`, `IMPORT.yml`, `DEPLOY-*.yml`) pass `timeout-minutes: 360` explicitly.

GitHub-hosted runners enforce a maximum of 360 minutes per job, so this value uses the full hosted-runner limit.

You can override per workflow/stage by editing the caller workflow `with:` block.

Example (single-stage override):

```yaml
jobs:
  deploy-prod:
    uses: ALM4Dataverse/ALM4Dataverse/.github/workflows/deploy.yml@stable
    with:
      environment-name: PROD
      previous-environment-name: TEST-main
      promotion-mode: manual-gate-tag
      github-context-json: ${{ toJSON(github) }}
      caller-inputs-json: ${{ toJSON(inputs) }}
      timeout-minutes: 120
```

---

## Credential Configuration

ALM4Dataverse supports three approaches for per-environment credentials.
They can be mixed: use whichever fits each environment.

Reusable workflows do **not** take credential/value `workflow_call` inputs (for example
`dataverse-url`, `dataverse-connection-refs`, `dataverse-env-vars`) or secret inputs
(`azure-client-id`, `azure-tenant-id`, etc.). Values are resolved from GitHub
environment variables/secrets or prefixed repo-level secrets/variables.

See [GitHub Secrets & Variables Reference](../config/github-secrets.md) for the full
list of secrets and variables required for each approach.

---

### Approach 1: Workload Identity Federation / OIDC (recommended)

WIF lets the workflow authenticate to Azure using a short-lived OIDC token issued by
GitHub — no secrets to store or rotate.

> **Prerequisite**: configure a federated credential on each App Registration as
> described in [Prerequisites → Workload Identity Federation](#option-a-workload-identity-federation--oidc-recommended).

#### 1.1 Create GitHub Environments

For each Dataverse environment:

1. Go to **Settings** > **Environments** in your GitHub repository
2. Click **New environment**
3. Name it to match your deployment target (e.g. `Dev-main`, `TEST-main`, `PROD`)
4. Click **Configure environment**

#### 1.2 Add variables (no client secret needed)

Inside each environment, add:

| Name | Type | Value |
|------|------|-------|
| `AZURE_CLIENT_ID` | Variable | App registration client ID |
| `AZURE_TENANT_ID` | Variable | Entra ID tenant ID |
| `DATAVERSESERVICEACCOUNTUPN` | Secret or Variable | UPN of the service account for activating processes |
| `DATAVERSE_URL` | Variable | Dataverse environment URL (e.g. `https://yourorg-test.crm.dynamics.com`) |

> **Do NOT set `AZURE_CLIENT_SECRET`** — when it is absent the workflows automatically
> obtain an OIDC token via GitHub's built-in token endpoint.

For connection references and environment variables, add individual entries:

| Name | Type | Value |
|------|------|-------|
| `DataverseConnRef_<schema_name>` | Variable | Connection ID GUID |
| `DataverseEnvVar_<schema_name>` | Variable | Environment variable value |

#### 1.3 Add protection rules (optional)

In the environment settings, you can add:
- **Required reviewers** — users or teams who must approve before deployment starts
- **Wait timer** — a delay (in minutes) before deployment runs
- **Deployment branches** — restrict which branches can deploy to this environment

> ⚠️ **Licence requirement**: Environment protection rules (required reviewers, wait timer,
> deployment branches) require **GitHub Pro, Team, or Enterprise** for private repositories.
> Public repositories can use protection rules on any plan.
> See [GitHub licence limitations](#github-licence-limitations) below.

#### 1.4 Configure your DEPLOY workflow (WIF)

`DEPLOY-main.yml` uses explicit stage jobs and calls the reusable `deploy.yml`
workflow for each environment:

```yaml
jobs:
  deploy-test:
    uses: ALM4Dataverse/ALM4Dataverse/.github/workflows/deploy.yml@stable
    with:
      environment-name: TEST-main
      previous-environment-name: ''
      promotion-mode: manual-gate-tag
      github-context-json: ${{ toJSON(github) }}
      caller-inputs-json: ${{ toJSON(inputs) }}

  deploy-prod:
    needs: deploy-test
    if: ${{ github.event_name == 'workflow_dispatch' || needs['deploy-test'].result == 'success' }}
    uses: ALM4Dataverse/ALM4Dataverse/.github/workflows/deploy.yml@stable
    with:
      environment-name: PROD
      previous-environment-name: TEST-main
      promotion-mode: manual-gate-tag
      github-context-json: ${{ toJSON(github) }}
      caller-inputs-json: ${{ toJSON(inputs) }}
    secrets: inherit
```

To switch promotion strategy, change only:

```yaml
promotion-mode: manual-gate-tag   # or environment-approval
```

- `manual-gate-tag` (default): every stage requires a manual trigger; higher environment(s) must also satisfy the previous-stage gate tag.
- `environment-approval`: auto-chain to each next stage; approval handled by
  GitHub environment protection rules.

See [Deployment Gates for GitHub Free](#deployment-gates-for-github-free) for full details.

---

### Approach 2: GitHub Environments with client secret

Use this approach if you prefer or require client secret authentication while still
using GitHub Environments for approval gates.

#### 2.1 Create GitHub Environments

Follow the same steps as Approach 1.

#### 2.2 Add secrets and variables (including client secret)

Inside each environment, add:

| Name | Type | Value |
|------|------|-------|
| `AZURE_CLIENT_ID` | Variable | App registration client ID |
| `AZURE_CLIENT_SECRET` | Secret | App registration client secret |
| `AZURE_TENANT_ID` | Variable | Entra ID tenant ID |
| `DATAVERSESERVICEACCOUNTUPN` | Secret or Variable | UPN of the service account for activating processes |
| `DATAVERSE_URL` | Variable | Dataverse environment URL (e.g. `https://yourorg-test.crm.dynamics.com`) |

For connection references and environment variables, add individual entries:

| Name | Type | Value |
|------|------|-------|
| `DataverseConnRef_<schema_name>` | Variable | Connection ID GUID |
| `DataverseEnvVar_<schema_name>` | Variable | Environment variable value |

Example:

| Name | Value |
|------|-------|
| `DataverseConnRef_contoso_sharedsharepointonline` | `12345678-1234-1234-1234-123456789abc` |
| `DataverseEnvVar_contoso_APIEndpoint` | `https://api.test.contoso.com` |

#### 2.3 Configure your DEPLOY workflow (client secret)

The YAML structure is identical to Approach 1 — `secrets: inherit` passes both
`AZURE_CLIENT_ID` and `AZURE_CLIENT_SECRET` (see [1.4](#14-configure-your-deploy-workflow-wif)).

---

### Approach 3: Prefixed global secrets

Store all credentials as repository-level secrets/variables using a naming convention
that includes the environment name as a prefix.  This approach works on **all GitHub
licence levels** including GitHub Free on private repositories.

The reusable workflows auto-map prefixed names to the unprefixed runtime variables used
by ALM4Dataverse scripts. You keep `secrets: inherit` and do not manually map prefixed
secret names in the workflow YAML.

This is also the automatic fallback used by `setup-github.ps1` when GitHub environment
approval rules are not available for the selected repository.

> ⚠️ **No approval gates**: Without environment protection rules there is no built-in
> approval mechanism.  Anyone who can trigger the DEPLOY workflow can deploy to any
> environment.  For production environments, consider restricting who can trigger the
> workflow by using branch protection rules on `main` and limiting merge permissions.

#### 3.1 Add secrets and variables

In **Settings** > **Secrets and variables** > **Actions**, add:

| Name | Type | Value |
|------|------|-------|
| `TEST_MAIN_AZURE_CLIENT_ID` | Secret | App registration client ID |
| `TEST_MAIN_AZURE_CLIENT_SECRET` | Secret | Client secret (omit if using WIF) |
| `TEST_MAIN_AZURE_TENANT_ID` | Secret | Tenant ID |
| `TEST_MAIN_DATAVERSE_SERVICE_ACCOUNT_UPN` | Secret | Service account UPN |
| `TEST_MAIN_DATAVERSE_URL` | Variable | Dataverse URL |
| `TEST_MAIN_DATAVERSE_CONN_REFS` | Variable | JSON — see below |
| `TEST_MAIN_DATAVERSE_ENV_VARS` | Variable | JSON — see below |

Optional (instead of JSON):

| Name | Type | Value |
|------|------|-------|
| `TEST_MAIN_DataverseConnRef_<schema_name>` | Variable | Connection ID GUID |
| `TEST_MAIN_DataverseEnvVar_<schema_name>` | Variable | Environment variable value |

Repeat with a `PROD_` prefix for production (and similar for other environments).

For dev environments used in EXPORT/IMPORT, use a prefix like `DEV_MAIN_`.

The prefix is matched from the effective environment name (for example `Dev-main` →
`DEV_MAIN_`) with fallback support for a literal `PREFIX_` prefix.

**Connection references JSON format** (variable `TEST_MAIN_DATAVERSE_CONN_REFS`):

```json
{
  "contoso_sharedsharepointonline": "12345678-1234-1234-1234-123456789abc",
  "contoso_sharedcommondataserviceforapps": "98765432-9876-9876-9876-987654321xyz"
}
```

**Environment variables JSON format** (variable `TEST_MAIN_DATAVERSE_ENV_VARS`):

```json
{
  "contoso_APIEndpoint": "https://api.test.contoso.com",
  "contoso_BatchSize": "50"
}
```

#### 3.2 Configure workflows for prefixed credentials

No extra credential wiring is needed in the copied workflow stubs:

- `EXPORT.yml`: keep `secrets: inherit` (no prefixed `secrets:` block)
- `IMPORT.yml`: keep `secrets: inherit` (no prefixed `secrets:` block)
- `DEPLOY-main.yml`: keep the default stage jobs with `secrets: inherit`

The same two deployment promotion strategies still apply exactly as shown in
[1.4](#14-configure-your-deploy-workflow-wif); the only difference is where values
come from (auto-mapped prefixed repo secrets/variables instead of GitHub environment
values).

---

## Deployment Gates for GitHub Free

On GitHub Free (private repos), environment protection rules — and therefore
mandatory approval gates — are not available.  ALM4Dataverse provides a **git tag
gate mechanism** that enforces ordered promotion and prevents automatic runaway
deployments without using any time-limited construct.

### How it works

```
BUILD (auto) → [human decision] → DEPLOY-main manual-run (TEST stage) → [human decision] → DEPLOY-main manual-run (PROD stage)
```

1. **BUILD** runs automatically on every push to `main`.
2. A team member manually triggers **DEPLOY-main** by going to **Actions** > **DEPLOY-main** > **Run workflow**, setting `target-environment` to the desired stage (for example `TEST-main`), and either entering the exact BUILD name shown in the run title (for example `repo-main-2025-05-27T14:23:11Z-4`) or leaving `build-run-name` blank to use the latest successful BUILD from the selected branch.
3. When the selected stage succeeds it pushes two lightweight git tags:
   ```
  {build-run-name}/deployed/TEST-main
  deployed/TEST-main
   ```
4. After inspecting that deployment, a team member manually triggers **DEPLOY-main** again for the desired next stage.
5. In `manual-gate-tag` mode, the selected stage checks via the GitHub API whether
  the previous stage gate tag exists (`{build-run-name}/deployed/{previous-environment}`).
   If it doesn't — because TEST never succeeded for that build — the workflow
   **fails immediately** with a clear error:
  > *Deployment gate check FAILED: the tag `repo-main-2025-05-27T14-23-11Z-4/deployed/TEST-main` does not exist.
   > Deploy to the previous environment first, then re-trigger this workflow.*
6. If the tag is present, deployment proceeds and on success pushes:
   ```
  {build-run-name}/deployed/PROD
  deployed/PROD
   ```

The gate tags serve as a **permanent, auditable trail** of which build was deployed
to which environment and in what order.

The `deployed/{environment}` tag is a **movable pointer** that is updated on every
successful deployment, making it easy to see the build currently live in each
environment.

### Key properties

| Property | Detail |
|---|---|
| No time limits | Gate tags are permanent — they don't expire |
| Ordered promotion enforced | Cannot deploy to a later stage without successful deployment of the previous stage for the same build |
| Targeted redeploy supported | Enter `target-environment` explicitly to deploy a specific stage |
| Single workflow file | Everything lives in `DEPLOY-main.yml` — no extra files to manage |
| GitHub Free compatible | Uses only `contents: write` permission and the GitHub REST API |
| Works with all credential approaches | WIF, client secret, or prefixed global secrets |

### Adding more stages (UAT)

Add another stage job and chain it between TEST and PROD.

Example additions:

1. Add `UAT-main` to `target-environment` options.
2. Add `deploy-uat` with `needs: deploy-test`.
3. Update `deploy-prod` to `needs: deploy-uat` and set its manual gate predecessor to `UAT-main`.

In `manual-gate-tag` mode, each manual promotion checks its previous stage tag.
In `environment-approval` mode, each stage auto-chains from the previous stage.

### GitHub Pro/Team/Enterprise alternative

If you have environment protection rules available, set:

```yaml
promotion-mode: environment-approval
```

Then add **Required reviewers** to your higher environment in
**Settings > Environments**.

Flow with `environment-approval` mode:
```
BUILD (auto) → stage 1 (auto) → stage 2 (queued/approval) → stage 3 (queued/approval) → ...
```

In this mode, each stage runs only after the previous stage succeeds on automatic runs.
For manual runs, you can leave `target-environment` blank to start from the first
configured stage in `environment-approval` mode, or set it to deploy directly to a
specific stage.

---

## GitHub Licence Limitations

| Feature | Free (public) | Free (private) | Pro | Team | Enterprise |
|---------|:---:|:---:|:---:|:---:|:---:|
| GitHub Actions | ✅ | ✅ | ✅ | ✅ | ✅ |
| GitHub Environments (secrets/vars) | ✅ | ✅ | ✅ | ✅ | ✅ |
| Environment protection rules (approvals, wait timers) | ✅ | ❌ | ✅ | ✅ | ✅ |
| Deployment branches restriction | ✅ | ❌ | ✅ | ✅ | ✅ |
| Git tag deployment gates (ALM4Dataverse) | ✅ | ✅ | ✅ | ✅ | ✅ |
| Actions minutes included | Unlimited | 2 000/month | 3 000/month | 3 000/month | 50 000/month |

### Impact on private repository deployments (Free plan)

On a **private repository with GitHub Free**:

- You **can** store environment-specific secrets and variables in GitHub Environments.
- You **cannot** add protection rules to environments — but the git tag gate mechanism
  (see [Deployment Gates for GitHub Free](#deployment-gates-for-github-free)) provides
  an equivalent ordered-promotion guarantee without approval rules.
- Workflow minutes are limited to 2,000/month for the repository. Windows runners
  (used by ALM4Dataverse) consume minutes at 2× the Linux rate, so the effective
  budget is 1,000 minutes of pipeline time per month on the Free plan.

**Additional access controls on Free plan:**

- Use branch protection rules on `main` to restrict who can merge/push, which
  controls which builds are available for promotion.
- Restrict `workflow_dispatch` permission using repository collaborator roles —
  only users with at least **Write** access can trigger manual deployments in
  `DEPLOY-main.yml`.
- Consider upgrading to GitHub Pro/Team for production workloads requiring formal
  approval workflows.

---

## Grant permissions for workflow operations

### Write access for EXPORT and DEPLOY tags

The EXPORT workflow commits and pushes solution changes back to the repository.
After a successful export commit, it uses the GitHub CLI/API to dispatch `BUILD.yml`
on the same branch. The DEPLOY workflows push git tag gates and environment pointer
tags after successful deployments.

1. Go to **Settings** > **Actions** > **General**
2. Under **Workflow permissions**, select **Read and write permissions**
3. Click **Save**

### Repository dispatch token for EXPORT → BUILD

`EXPORT` triggers `BUILD` by sending a `repository_dispatch` event via the GitHub
CLI/API. By default it uses the workflow `GITHUB_TOKEN`.

If your repository policy requires a separate token, add a repository-level or
environment-level secret named `WORKFLOW_DISPATCH_TOKEN` (or legacy alias
`GH_WORKFLOW_TOKEN`).

Alternatively, each reusable workflow declares `permissions: contents: write` which
overrides the default on a per-job basis.

### Actions read for DEPLOY (artifact download)

The DEPLOY workflow downloads artifacts from the BUILD workflow run.  The reusable
workflow declares `permissions: actions: read`, which is granted automatically by the
caller's `GITHUB_TOKEN` on all plans.

---

## Usage

Once configured:

- **BUILD** — runs automatically on every push. View run status in the **Actions** tab.
- **EXPORT** — go to **Actions** > **EXPORT** > **Run workflow**, enter a commit message, and click **Run workflow**.
- **IMPORT** — go to **Actions** > **IMPORT** > **Run workflow** and click **Run workflow**.
- **DEPLOY-main** — for `manual-gate-tag` mode, enter `target-environment` and optionally `build-run-name`; if left blank, the workflow uses the latest successful BUILD from the selected branch. In `environment-approval` mode, stage 1 starts automatically after BUILD succeeds and later stages auto-chain after prior-stage success plus any required approvals; for a manual replay, `target-environment` can be left blank to start from the first configured stage, while entering a value targets a specific stage.

`EXPORT.yml` commits changes back to the same branch it was run from, then sends a `repository_dispatch` event with branch and commit metadata. `BUILD.yml` listens for that dispatch and checks out the exact exported commit.

### Finding a BUILD run name for manual deploy (optional)

1. Go to **Actions** and select the **BUILD** workflow
2. Copy the exact BUILD name shown in the run title (for example `repo-main-2025-05-27T14:23:11Z-4`). The **Set build number** step shows the same exact value.
3. Enter that BUILD name into **DEPLOY-main** when you want to deploy a specific build; otherwise, leave `build-run-name` blank to use the latest successful BUILD from the selected branch.

When ALM4Dataverse creates git tags from that BUILD name, it automatically sanitizes characters that git refs do not like. For example, `repo-main-2025-05-27T14:23:11Z-4` becomes the source tag `vrepo-main-2025-05-27T14-23-11Z-4`.

For backward compatibility, numeric run IDs from the run URL are still accepted too.

### Viewing deployment tags

Deployment tags are stored in the repository and are visible in the **Tags** section
of the repository (under **Code** > **Tags**).

- `{build-run-name}/deployed/{environment}` is the permanent audit/gate tag.
- `deployed/{environment}` is the movable pointer showing what is currently deployed.

Example:

```
repo-main-2025-05-27T14-23-11Z-4/deployed/TEST-main   ← TEST was successfully deployed for that build
repo-main-2025-05-27T14-23-11Z-4/deployed/PROD        ← PROD was successfully deployed for that build
deployed/TEST-main                                 ← TEST currently points at that build
deployed/PROD                                      ← PROD currently points at that build
```

---

## References

- [GitHub Actions reusable workflows](https://docs.github.com/en/actions/using-workflows/reusing-workflows)
- [GitHub Environments and deployment protection rules](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment)
- [GitHub Actions billing and usage limits](https://docs.github.com/en/billing/managing-billing-for-github-actions/about-billing-for-github-actions)
- [GitHub REST API — Git refs](https://docs.github.com/en/rest/git/refs)
- [GitHub Secrets & Variables Reference](../config/github-secrets.md)
