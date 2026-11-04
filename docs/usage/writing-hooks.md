# Writing Hooks

Hooks are PowerShell scripts that ALM4Dataverse runs at fixed points in EXPORT, BUILD,
DEPLOY and IMPORT. Use them for work that isn't a solution component: configuration
data, organization changes, data migrations, extra build outputs, or checks.

This guide covers writing, registering, testing and debugging a hook. The
[hook reference](../config/alm-config.md#hooks) lists every hook point, the operations
that run it, and the exact `$Context` values it receives.

> [!TIP]
> Check for a declarative option before writing a hook. Organization settings,
> SolutionPackager mappings, Code Apps and connection references are all configured
> directly in [`alm-config.psd1`](../config/alm-config.md).

## Choose The Hook Point

| You want to... | Use |
| --- | --- |
| Capture configuration records into source control | `postExport` |
| Do per-solution work during export, such as extra files for that solution | `postExportSolution` or `parallelExportSolution` |
| Generate or validate files before packing | `preBuild` |
| Inspect or add to the packed artifact | `postBuild` |
| Prepare the target before solutions are imported | `preDeploy` |
| Move data that needs both old and new schema | `dataMigrations` |
| Load configuration data or finish setup after import | `postDeploy` |

Deployment hooks run in **three** situations: DEPLOY to a target, IMPORT to a
development environment, and BUILD validation against its validation environment.
Write them so they're correct in all three, or detect the target as described below.

## Write The Script

Start from this shape:

```powershell
param([hashtable]$Context)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "Running $($Context.HookType) against $env:DATAVERSE_URL"

$recordsPath = Join-Path $PSScriptRoot 'records'
if (-not (Test-Path -LiteralPath $recordsPath)) {
    throw "Expected configuration records at '$recordsPath'."
}

Get-DataverseRecordsFolder -InputPath $recordsPath |
    Set-DataverseRecord -TableName contoso_setting
```

Rules that keep hooks predictable:

- **Fail loudly.** Keep `$ErrorActionPreference = 'Stop'`, throw on unexpected state,
  and check `$LASTEXITCODE` after every native command such as `dotnet`, `npm` or `pac`.
  A hook that writes an error and continues lets a broken deployment report success.
- **Resolve paths from the script.** Use `$PSScriptRoot` or `$Context.BaseDirectory`.
  Deployment hooks run from the build artifact, not from your repository checkout.
- **Make it safe to repeat.** Retries, redeployments, BUILD validation and IMPORT all
  rerun deployment hooks, even when every solution import is skipped. Prefer upserts,
  `-IfExists` deletes and checks for work that's already done.
- **Never log secrets.** Don't print whole environment-variable or configuration
  collections, and don't put secret values on a native command line.
- **Guard optional settings.** Under strict mode, test `ContainsKey` before reading an
  optional configuration key.

## Register And Package It

Add the script path to the hook list in `alm-config.psd1`. Paths are relative to the
repository root:

```powershell
@{
    hooks = @{
        postDeploy = @('data/settings/import.ps1')
    }
    assets = @('data')
}
```

Export and build hooks run from your source checkout, so registration is enough.
**Deployment hooks run from the artifact**, so their scripts and any files they read
must also be inside a folder listed in `assets`. A deployment hook that isn't packaged
fails with a missing-file error.

Changes to a deployment hook take effect only in a **new BUILD**. Redeploying an existing
build runs the hook version packaged with that build.

## What A Hook Can Use

Every connected operation signs in before its hooks run:

| Available | EXPORT | BUILD | DEPLOY | IMPORT |
| --- | --- | --- | --- | --- |
| Default Dataverse connection (`Rnwood.Dataverse.Data.PowerShell` cmdlets work without `-Connection`) | Yes | When BUILD validation is configured | Yes | Yes |
| `$env:DATAVERSE_URL`, the connected environment's URL | Yes | When BUILD validation is configured | Yes | Yes |
| PAC CLI authenticated to that environment | Yes | When BUILD validation is configured | Yes | Yes |
| Azure CLI signed in as the application identity | GitHub only | GitHub, when BUILD validation is configured | Yes | GitHub only |
| Az PowerShell signed in as the application identity | No | No | Yes | No |

Az PowerShell and Azure CLI sessions have no subscription selected. Select one
explicitly if a hook calls subscription-scoped commands. Without BUILD validation, BUILD
build hooks run with no Dataverse or Azure connection.

Extra PowerShell modules come from [`scriptDependencies`](../config/alm-config.md#script-dependencies);
they are installed and version-locked with the build.

### Settings And Secrets

Hooks read target-specific values from environment variables. Store them with the
target's other settings:

- **GitHub Actions:** add variables to the GitHub environment (or as repository
  variables) and they're available automatically. Secrets must be selected in the
  action's `secrets-json` input. See [GitHub secrets and variables](../config/github-secrets.md).
- **Azure DevOps:** add variables to the target's `Environment-<name>` variable group.
  Non-secret variables are available automatically; list each secret in the template's
  `secretVariables` parameter. See [variable groups](../config/azdo-environment-variable-group.md#secret-values).

Azure DevOps exposes variable names in uppercase on the runner. Windows environment
variables are case-insensitive, but read names in uppercase if you also run hooks on
Linux, for example `$env:CONTOSO_API_BASEURL`.

### Identify The Target

`$Context` doesn't say which environment a deployment hook is targeting, or whether it's
running for DEPLOY or BUILD validation. `$Context.UseUnmanagedSolutions` is `$true` only
for IMPORT. When a hook must behave differently per target:

- compare `$env:DATAVERSE_URL` with known URLs, or
- define a variable such as `ContosoTargetName` for each target, and read it with a clear failure when it's missing.

```powershell
$targetName = [Environment]::GetEnvironmentVariable('CONTOSOTARGETNAME')
if ([string]::IsNullOrWhiteSpace($targetName)) {
    throw 'Set ContosoTargetName in this target''s environment settings.'
}
if ($targetName -eq 'PROD') {
    Write-Host 'Skipping sample data in production.'
    return
}
```

## Test A Hook

1. **Parse it.** Run `[System.Management.Automation.Language.Parser]::ParseFile()` or open
   the script in an editor with PowerShell diagnostics.
2. **Run it locally against a non-production environment.** Sign in, connect, then call
   the hook with a context like the one the pipeline supplies:

   ```powershell
   $almRoot = (Resolve-Path '../ALM4Dataverse').Path
   & "$almRoot/pipelines/scripts/installdependencies.ps1"
   & "$almRoot/pipelines/scripts/connect.ps1" -Url 'https://contoso-dev.crm.dynamics.com'

   $config = Import-PowerShellDataFile ./alm-config.psd1
   & ./data/settings/import.ps1 -Context @{
       HookType              = 'postDeploy'
       BaseDirectory         = (Get-Location).Path
       Config                = $config
       ArtifactsPath         = (Get-Location).Path
       UseUnmanagedSolutions = $false
   }
   ```

   `connect.ps1` uses `DefaultAzureCredential`, so sign in first with `az login` or set
   the `AZURE_*` variables for a non-production application identity. The local
   `Config` is your unmerged file; the pipeline passes it merged with the shared defaults.
3. **Run it twice.** The second run should succeed and change nothing unexpected.
4. **Exercise it through the pipeline.** Run IMPORT on a development branch, or BUILD with
   validation enabled, before deploying to a shared target.

For local BUILD and DEPLOY runs of the full scripts, see
[direct PowerShell usage](../config/pipelines.md#direct-powershell-usage).

## Debug A Failing Hook

- The log shows each hook's script path as it starts. Find the first error after it.
- A missing script in DEPLOY usually means the folder isn't in `assets`, or the build
  predates the hook. Rebuild after fixing.
- A hook that works in DEPLOY but not BUILD validation is reading a setting that only
  the DEPLOY target has. Add the setting to the validation environment too.
- A hook that changed data before failing leaves those changes in place. Check the
  target state before retrying.

## Share Hooks Across Applications

A shared fork of ALM4Dataverse can ship hooks for every consuming repository. Reference
them with the `[alm]` placeholder, for example `'[alm]/custom-hooks/audit.ps1'`, and add
them to the fork's `alm-config-defaults.psd1`. See
[hook script paths](../config/alm-config.md#hook-script-path-placeholder) and
[updating and customizing](updating.md#choose-the-smallest-extension-point).

## Examples

- [Data import and export](../config/example-hooks/data-import-export.md): version configuration records with your solutions.
