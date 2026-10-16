# ALM Configuration (alm-config.psd1)

The `alm-config.psd1` file in your application repository configures both Azure DevOps and GitHub Actions. It defines solutions, deployment assets, hooks, dependencies, import timeouts, build validation, and Solution Checker settings. Credentials and target-specific values belong in your CI platform's environment configuration, not in this file.

## Location

Place the file at the application repository root; unpacked solutions live in `solutions/<unique-name>/`. Start with the [supplied configuration](../../copy-to-your-repo/alm-config.psd1).

ALM4Dataverse loads [shared defaults](../../alm-config-defaults.psd1), then merges your application configuration into them:

| Value type | Merge behavior |
| --- | --- |
| Hashtable | Merge recursively; application values override matching defaults. |
| Array | Append application items after default items; no deduplication. An empty array does not clear defaults. |
| Scalar | The application value wins, including `$false` and an empty string. |
| `$null` | Keep the default value. |

The same rules merge global and per-solution checker settings. Defaults are versioned
with ALM4Dataverse, so review them when upgrading.

> [!NOTE]
> **Advanced: loaded configuration.** `_main` and `_defaults` in a hook's configuration
> are internal snapshots, not settings to put in your file.

## Minimal Configuration

```powershell
@{
    solutions = @(
        @{ name = 'ContosoCore' }
    )
    assets = @()
    hooks = @{}
}
```

The supplied template additionally includes the `data` asset and example data hooks. Configure those scripts for your tables or leave their example operations commented out. An empty `solutions = @()` is supported for data-only or hook-only projects.

## Settings At A Glance

| Setting | Type | Default or template value |
| --- | --- | --- |
| `solutions` | Array of hashtables | Empty in the template; list solutions in dependency order. |
| `buildVersion` | Hashtable | Shared default is `'1.0'`; optional MAJOR.MINOR override and full-branch overrides. |
| `export` | Hashtable | Up to two concurrent package exports; a shared limit of four operations with version updates. |
| `assets` | Array of paths | `@('data')` in the template. |
| `hooks` | Hashtable of script-path arrays | Empty except the template's `postExport` and `postDeploy` data hooks. |
| `scriptDependencies` | Hashtable of module names and versions | `Rnwood.Dataverse.Data.PowerShell = '3.2.0'`. |
| `pacCliVersion` | String | `'2.7.4'`. |
| `importTimeoutSeconds` | Number of seconds | `10800` per import. |
| `buildValidation.baselineRelease` | String | `''`; no baseline. |
| `solutionCheck` | Hashtable | Disabled; full settings below. |

## Configuration Sections

### BUILD SemVer

`buildVersion` assigns a MAJOR.MINOR version line to each branch. Set a shared
default and, when needed, full branch-name overrides:

```powershell
buildVersion = @{
    default = '1.0'
    branches = @{
        main          = '2.0'
        develop       = '1.5'
        'release/1.x' = '1.4'
    }
}
```

The shared configuration defaults `buildVersion.default` to `'1.0'`. Set
`default` to override the base for unlisted branches, and add entries under
`branches` for branch-specific release lines.

> [!NOTE]
> **Advanced: version derivation.** Branch keys are full branch names, including
> any slash-separated prefix. Values must be two non-negative SemVer integers
> without leading zeroes, such as `'2.1'`; BUILD and EXPORT fail early if the
> selected value is invalid.
>
> The CI run number supplies PATCH, and the normalized branch name is the
> SemVer prerelease identifier. For example, `main` might produce
> `2.1.42-main`, while `feat/abc` with the default `1.0` base might produce
> `1.0.43-feat-abc`. Slashes and other branch punctuation become hyphens.
> Numeric-only branch slugs with leading zeroes get a `b` prefix to remain
> valid SemVer identifiers (for example, branch `01` becomes `b01`). Every
> build retains this branch suffix in its version and source tag; no stable
> build promotion is provided.
>
> For solution versions, the configured MAJOR.MINOR maps to the Dataverse
> solution's `Major.Build` components. The solution's `Minor` component remains
> the non-additive upgrade counter used by DEPLOY.
>
> `build-version.json` in each artifact records its version, branch, provider,
> source commit, and exact CI run ID. Azure DevOps and GitHub keep the original
> branch-suffixed build identity for deployment and baseline selection.

### Solutions

Defines the Dataverse solutions to be processed by the pipeline, in dependency order.

```powershell
solutions = @(
    @{
        name                      = 'MySolution'
        deployUnmanaged           = $false  # Optional
        serviceAccountUpnConfigKey = 'MySolutionServiceAccountUpn'  # Optional
    }
)
```

**Properties:**

- `name` (required): Dataverse unique solution name, not display name; must match `solutions/<name>` in source control.
- `deployUnmanaged` (optional, default: false): Boolean indicating whether to deploy the unmanaged version instead of managed
- `serviceAccountUpnConfigKey` (optional, default: 'DataverseServiceAccountUpn'): Name of the environment configuration key containing the service account UPN to use when activating processes in this solution
- `solutionCheck` (optional): Per-solution PAC checker settings merged with global `solutionCheck` settings (see below). Set `solutionCheck.enabled = $false` to skip checking a specific solution.
- `mappings` (optional): Ordered SolutionPackager mapping entries used during BUILD and EXPORT; each entry may include the build command that produces its source during BUILD; see [Build Processing](#build-processing).

`BUILD` packs both managed and unmanaged packages. `DEPLOY` selects the package using `deployUnmanaged`; `IMPORT` always selects unmanaged packages for every solution. Use managed deployment for controlled downstream environments unless you have a specific reason to retain unmanaged customizations.

The service account is a real Dataverse user used to own and activate processes, not the
application user used to authenticate.

> [!NOTE]
> **Advanced: per-solution process owners.** Supply the selected key in the runner
> environment; deployment uppercases it before reading it. For example,
> `serviceAccountUpnConfigKey = 'ContosoFlowOwner'` requires `CONTOSOFLOWOWNER`. This matters
> on Linux, where environment variables are case-sensitive. See the
> [Azure DevOps variable reference](azdo-environment-variable-group.md) or
> [GitHub variable reference](github-secrets.md).

### Export Processing

```powershell
export = @{
    parallel = $true
    maxParallel = 2
    maxConcurrentOperations = 4
}
```

| Setting | Type | Default | Behavior |
| --- | --- | --- | --- |
| `export.parallel` | Boolean | `$true` | Export managed and unmanaged packages concurrently; `$false` retains sequential export. |
| `export.maxParallel` | Integer, `1` to `8` | `2` | Maximum simultaneous package exports, including both packages of the same solution. |
| `export.maxConcurrentOperations` | Integer, `1` to `8` | `4` | Shared limit for package exports and environment version updates. Per-solution parallel hooks can use their provided `OperationBudget` to share this limit. |

Missing, null, or empty optional settings use the defaults; an explicit `$false`
is preserved. Invalid types or out-of-range limits fail with a configuration error.
Unpacking, change detection, and version updates run in configured solution order.
Pre-export and post-export hooks keep their existing order and context.
When mappings are configured, EXPORT generates the mapping XML from the same
entries and uses it to unpack both packages and compare managed solution
packages. `buildCommand` is BUILD-only and is not run during EXPORT. If an
existing solution is being compared, mapped source paths must already exist so
the previous package can be reconstructed; the first export has no previous
package to compare.

See [Export Logs](../usage/exporting-changes.md#export-logs) for progress messages,
per-solution summaries and retained diagnostics.

### Build Processing

```powershell
build = @{
    parallel = $true
    maxParallel = 2
}
```

| Setting | Type | Default | Behavior |
| --- | --- | --- | --- |
| `build.parallel` | Boolean | `$true` | Run eligible build commands and solution packs in parallel within their respective stages; `$false` runs both stages sequentially. |
| `build.maxParallel` | Integer, `1` to `8` | `2` | Maximum concurrent build commands or solution packs within each stage. |

Missing, null, or empty optional settings use the defaults; an explicit `$false`
is preserved. Invalid types or out-of-range limits fail with a configuration error.

`mappings` is an ordered array of entries. Each entry directly represents one
SolutionPackager directive and may include a `buildCommand` to produce its
source before packing. This example builds a plugin DLL, maps a web-resource
folder, and maps matching files from another folder:

```powershell
solutions = @(
    @{
        name = 'ContosoCore'
        mappings = @(
            @{
                type = 'FileToFile'
                source = 'plugins/Contoso.Plugin/bin/Release/Contoso.Plugin.dll'
                destination = 'PluginAssemblies\Contoso.Plugin.dll'
                buildCommand = @{
                    name = 'Build plugin'
                    executable = 'dotnet'
                    arguments = @('build', 'plugins/Contoso.Plugin/Contoso.Plugin.csproj', '--configuration', 'Release')
                    workingDirectory = '.'
                }
            }
            @{
                type = 'Folder'
                source = 'webresources'
                destination = 'WebResources'
            }
            @{
                type = 'FileToPath'
                source = 'other-resources'
                destination = 'Other\*.json'
            }
        )
    }
)
```

Each entry has these properties:

- `type` (required): `Folder`, `FileToFile`, or `FileToPath`, matching the
  SolutionPackager directive.
- `source` (required): Path to the source file or folder. Relative paths are
  resolved from the repository root; absolute paths and `%variable%`
  environment-variable references are also supported.
- `destination` (required): Path or pattern in the solution package. Relative
  paths are resolved from that solution's folder; absolute paths and
  `%variable%` references are also supported.
- `buildCommand` (optional): Command to run before packing this mapping's
  source during BUILD. EXPORT does not run build commands. It uses `executable`,
  an `arguments` array, optional `workingDirectory`, and optional `parallel`
  (default `$true`).

Source paths are checked after build commands run. The mapping array's order is
preserved in the generated mapping XML and therefore determines precedence
when rules overlap.

The directives follow the [official SolutionPackager mapping specification](https://learn.microsoft.com/en-us/power-platform/alm/solution-packager-tool):

- `Folder` maps folder hierarchies and does not support wildcards or file names.
- `FileToFile` requires a filename in both `map` and `to`; filename wildcards
  are not supported, although the folder wildcard `\**` is.
- `FileToPath` requires a filename or filename pattern in `map` (for example,
  `*.ext` or `*.*`); `to` must be a folder path without a filename.
- Earlier directives take precedence. A matched file must exist in at least
  one alternative location or SolutionPackager reports an error.

ALM4Dataverse generates the XML mapping file from `mappings` in a temporary
location for packing and unpacking and removes it afterward; users do not
maintain a separate mapping file. The former `mappingFile` and solution-level
`buildCommands` settings are not accepted. BUILD and export package comparison
require a version of `Rnwood.Dataverse.Data.PowerShell` that supports
`Compress-DataverseSolutionFile -MappingFile`. EXPORT also requires
`Expand-DataverseSolutionFile -MappingFile` when parallel export is enabled, or
`Export-DataverseSolution -MappingFile` when it is disabled. The pipeline fails
early with an instruction to update the module dependency if a required
parameter is unavailable. The mapping-aware unpack cmdlets retain automatic
`.msapp` folder preprocessing.

Build commands use an executable and an argument array (not a shell command
string); each argument is passed as a distinct process argument.
`workingDirectory` is optional and defaults to the repository root; relative
working directories are resolved from that root. Commands are grouped by
consecutive `parallel` values in mapping order. Parallel commands run
concurrently, limited by `build.maxParallel`; set an individual command's
`parallel = $false` to run it sequentially. Groups execute in order, and all
commands finish before solution packing begins. When `build.parallel = $false`,
all commands run sequentially in solution and mapping order.

### Assets

Extra folders or files to include in build artifacts, copied verbatim to the artifacts directory.

```powershell
assets = @(
    'data',
    'config',
    'documentation'
)
```

Paths are relative to the repository root and retain that layout inside the artifact.
Every listed path must exist or the build fails.

> [!IMPORTANT]
> Include every application-owned deployment hook and its supporting files in `assets`.
> Listing a hook does not automatically package its script. Do not include credentials
> or environment-specific secrets in assets.

### Hooks

Hook scripts are executed at various stages of the build, export, and deployment processes and can be used to add custom steps. Each hook is a list of script paths relative to the repository root that will be executed at one stage of the standard process. 'Pre' hooks occur before the standard steps and 'post' hooks occur after.

Scripts can use the built-in `Rnwood.Dataverse.Data.PowerShell` PowerShell module to complete a wide range of activities. [See the project site](https://github.com/ALM4Dataverse/Rnwood.Dataverse.Data.PowerShell) for full documentation. The current environment is automatically set to the target environment.

You can also include any other PowerShell module from the [PowerShell Gallery](https://powershellgallery.com) by including it in the `scriptDependencies` section. See below.

Example hooks:

- [Data import and export](example-hooks/data-import-export.md) (for example config/system data)
- [Organisation/environment settings](example-hooks/organization-settings.md) (for example enabling the 'PCF allowed' switch)

```powershell
hooks = @{
    preExport              = @()
    preExportSolution      = @()
    parallelExportSolution = @()
    postExportSolution     = @()
    postExport             = @('data/system/export.ps1')
    preDeploy              = @()
    dataMigrations         = @()
    postDeploy             = @('data/system/import.ps1')
    preBuild               = @()
    postBuild              = @()
}
```

**Available Hooks:**

- **preExport**: Called before exporting solutions from a Dataverse environment
- **preExportSolution**: Called before each solution's exports begin
- **parallelExportSolution**: Started alongside each solution's export workers. EXPORT waits for this hook to finish before unpacking and comparing that solution. With sequential export, the hook runs synchronously before the solution is exported.
- **postExportSolution**: Called after each solution is unpacked and compared. With parallel export enabled, hooks for different solutions can run concurrently with remaining exports.
- **postExport**: Called after exporting and unpacking solutions
- **preBuild**: Called before packing solutions during the build process
- **postBuild**: Called after packing solutions and copying assets
- **preDeploy**: Called before staging and importing solutions
- **dataMigrations**: Called during deployment after solutions are staged but before upgrades. Use this for data migration scripts that need to relocate data before columns are removed
- **postDeploy**: Called after publish customizations

Hooks run in their listed order, and a missing or failing hook fails the operation. `IMPORT` runs the build hooks and then the deployment hooks; it does not run export hooks. BUILD validation also runs the selected package's deployment hooks, including data migrations.

> [!CAUTION]
> **Advanced: migration timing.** Multi-solution managed deployments stage imports in
> dependency order and apply upgrades in reverse order after `dataMigrations`. A single
> solution uses `Auto` mode, which may complete its upgrade before this hook. Do not
> assume removed components remain available; design and test a staged migration release
> when the migration requires them.

#### Hook Context

Each hook script receives a `$Context` parameter containing:

- `HookType`: The type of hook being executed
- `BaseDirectory`: The base directory for the hook (source or artifacts root)
- `Config`: The loaded alm-config.psd1 configuration
- Additional context specific to the hook type:
  - **preBuild, postBuild**: `SourceDirectory`, `ArtifactStagingDirectory`
  - **preExport, postExport**: `SourceDirectory`, `ArtifactStagingDirectory`, `TempDirectory`, `EnvironmentName`
  - **preExportSolution, parallelExportSolution, postExportSolution**: the export context above, plus `SolutionName`, `SolutionConfig`, and `SolutionIndex`
  - Per-solution hooks also receive a cloned `Connection`. In parallel export mode, the hook worker sets that clone as its default connection for the duration of the hook, so existing Dataverse commands resolve to the right client. Hooks can also pass `$Context.Connection` explicitly. Parallel hooks receive the shared `OperationBudget` and `CancellationToken`.
  - `postExportSolution` hook output is collected by solution in `SolutionHookResults` and passed to the `postExport` hook.
  - `parallelExportSolution` hook output is collected by solution in `ParallelExportSolutionHookResults` and passed to the `postExport` hook.
  - **preDeploy, dataMigrations, postDeploy**: `ArtifactsPath`, `UseUnmanagedSolutions`

Start a hook with a parameter block. Resolve application-owned files from `$PSScriptRoot` or `$Context.BaseDirectory`, not from assumptions about the runner's working directory. Guard optional configuration keys when using strict mode:

Per-solution hooks for different solutions may run concurrently when `export.parallel` is enabled. `parallelExportSolution` also runs concurrently with package exports for the same solution; EXPORT waits for it before unpacking. Keep hook side effects solution-scoped and use the provided `OperationBudget` for Dataverse operations. Hooks listed for a single phase run in their configured order; solution-to-solution completion order is not guaranteed. With sequential exports, all per-solution hooks run synchronously.

```powershell
param([hashtable]$Context)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Context.Config.ContainsKey('customSettings')) {
        $settings = $Context.Config.customSettings
        Write-Host "Loaded $($settings.Count) custom settings."
}
```

> [!IMPORTANT]
> Throw on failures and check `$LASTEXITCODE` after native commands. Do not log secrets.
> Make hooks safe to retry: skipping an unchanged solution import does not skip the
> surrounding hooks.

#### Hook Script Path Placeholder

Hook script paths can use the `[alm]` placeholder to reference the ALM4Dataverse repository root:

```powershell
hooks = @{
    postExport = @('[alm]/custom-hooks/myScript.ps1')
}
```

The placeholder is replaced with the absolute path before execution, allowing you to use custom hook scripts provided by the ALM4Dataverse fork.

### Script Dependencies

PowerShell modules required by the scripts, with optional version pinning.

```powershell
scriptDependencies = @{
    'Pnp.PowerShell' = '2.12.1'      # Specific version
    'PSFramework'                       = ''           # Latest stable
    'MyModule'                          = 'prerelease' # Latest prerelease
}
```

**Version Specifications:**

- Empty string (`''`): Installs the latest stable version
- `'prerelease'`: Installs the latest prerelease version
- Specific version (e.g., `'2.12.1'` or `'1.0.0-beta.1'`): Installs that exact version

The build writes the exact loaded module versions and installed PAC version to `scriptDependencies.lock.json` in the artifact. Deployment's dependency installer reads this lock instead of resolving floating versions again. The application configuration itself is copied unchanged, alongside a snapshot of the shared ALM4Dataverse repository.

> [!NOTE]
> **Advanced: reproducibility and caching.** Packages must still be obtainable from their
> feeds. The lock does not freeze the hosted runner image or all external services/tools.
> GitHub actions cache modules and PAC by operating system and version specifications;
> cache hits are an optimization, not a substitute for the lock or installation step.

### PAC CLI Version

The pipeline scripts require Power Apps CLI (`pac`) for solution operations (for example export/unpack). `installdependencies.ps1` installs PAC automatically using the configured version.

```powershell
pacCliVersion = '2.7.4'
```

**Version Specifications:**

- Empty string (`''`): Installs the latest stable version
- `'prerelease'`: Installs the latest prerelease version
- Specific version (for example `'2.7.4'`): Installs that exact version

For reproducible builds/deployments, pin an explicit version.

> [!NOTE]
> **Advanced: PAC on Azure DevOps.**
> Azure DevOps templates intentionally set `PowerPlatformToolInstaller@2` with `AddToolsToPath: false`.
> This prevents the Power Platform Build Tools `pac` from being added to `PATH` and ensures
> the pinned `pacCliVersion` installed by `installdependencies.ps1` is the one used.

### Import Timeout

The `importTimeoutSeconds` setting is passed to `Import-DataverseSolution` for each individual solution import. The default is 10800 seconds (3 hours). A client-side timeout does not establish that the server-side Dataverse operation has stopped.

```powershell
importTimeoutSeconds = 10800
```

Increase this value if solution imports time out in large or complex environments.

The CI job also has a timeout covering installation, all imports, and hooks. Shipped jobs request 360 minutes, but your platform's lower limit still applies.

| Platform | Job timeout configuration | Capacity considerations |
| --- | --- | --- |
| Azure DevOps | `timeoutInMinutes`; exposed as a parameter by the deployment-stage template | Free private Microsoft-hosted jobs allow 60 minutes; paid hosted jobs allow 360. Check your organization's entitlement for other grants. |
| GitHub Actions | `jobs.<job-id>.timeout-minutes` in the caller workflow | GitHub-hosted jobs allow 6 hours. Self-hosted jobs also have platform limits; they are not unlimited. |

For Azure DevOps, set these fields within the existing deployment-stage entry:

```yaml
template: pipelines/templates/stages/deploy-environment.yml@ALM4Dataverse
parameters:
    environmentName: TEST-main
    timeoutInMinutes: 120
```

For GitHub, set `timeout-minutes` beside `runs-on` on the job, **not** under the composite action's `with`. See [GitHub limits](https://docs.github.com/en/actions/reference/limits) and [Microsoft-hosted agent limits](https://learn.microsoft.com/en-us/azure/devops/pipelines/agents/hosted#capabilities-and-limitations) before changing runner or timeout settings.

#### What to do after a timeout

> [!WARNING]
> After a job timeout, the solution import may still be running inside Dataverse.
> **Do not immediately retry**: a concurrent import of the same solution can cause conflicts.

1. Open the target Dataverse environment.
2. Navigate to **Settings → Solutions → Solution history** (or go to **make.powerapps.com → Solutions → See history** for the relevant solution).
3. Wait until the import operation shown there reaches a terminal state (**Succeeded** or **Failed**).
4. Inspect the final result and any pending upgrade, correct the cause, then retry the same selected build. Consider whether hooks partially ran and whether repeating them is safe.

### BUILD validation baseline

`buildValidation.baselineRelease` optionally configures a release that BUILD
deploys to the Dataverse validation environment before deploying the candidate
artifacts. Leave it empty to deploy only the candidate.

```powershell
buildValidation = @{
    baselineRelease = '@TEST'
}
```

Accepted values:

- `''` — no baseline; deploy only the candidate build.
- `@<environment-name>` — use the most recently successfully deployed BUILD
  run recorded by the `deployed/<environment-name>` pointer. If the pointer
  does not yet exist, BUILD warns and deploys only the candidate. This
  environment is separate from the BUILD validation target.
- A fixed successful build identifier. Azure DevOps accepts the numeric BUILD
  run ID or exact build number. GitHub Actions accepts a numeric BUILD run ID
  or the corresponding GitHub Release tag. A GitHub run ID is resolved to its
  Release tag, and the baseline is downloaded from that Release's
  `artifacts.zip` asset rather than the expiring Actions artifact.

The baseline and candidate each use the deployment script and configuration
packaged with their own build. If resolving, downloading, or deploying the
baseline fails, BUILD fails and does not deploy the candidate.

### Solution Check (PAC `solution check`)

`BUILD` can run `pac solution check` against packed solution zip files and fail the build based on a configurable severity threshold.

Configuration supports **global** defaults and **per-solution** overrides:

- Global settings are defined in top-level `solutionCheck`.
- Per-solution settings are defined in `solutions[].solutionCheck`.
- They are merged, so you can set shared defaults globally and only override what differs per solution.
- Arrays (`excludedFiles`, `ruleLevelOverride`) are merged by concatenation.
- `ruleSet = 'none'` means `--ruleSet` is omitted.

#### Global example

```powershell
solutionCheck = @{
    enabled = $true
    geo = 'Europe'
    failThreshold = 'Critical'
    ruleSet = 'Solution Checker'
    excludedFiles = @(
        'CanvasApps/**/*.msapp'
    )
    ruleLevelOverride = @(
        @{ Id = 'meta-remove-dup-reg'; OverrideLevel = 'Medium' }
    )
    maxParallel = 4
}
```

#### Per-solution override example

```powershell
solutions = @(
    @{
        name = 'ContosoCore'
        solutionCheck = @{
            enabled = $true
            failThreshold = 'High'
            ruleSet = 'none'
        }
    },
    @{
        name = 'LegacySolution'
        solutionCheck = @{
            enabled = $false
        }
    }
)
```

#### Settings reference

| Setting | Scope | Description |
| --- | --- | --- |
| `enabled` | Global + Solution | Enables/disables checker. Build runs checks only for solutions where merged `enabled` is `$true`. |
| `geo` | Global + Solution | PAC checker geography, e.g. `Europe`, `UnitedStates`, `Japan`. |
| `failThreshold` | Global + Solution | Build fails when findings include this severity or higher. Values: `Critical`, `High`, `Medium`, `Low`, `Informational`. Default: `Critical`. |
| `ruleSet` | Global + Solution | PAC rule set (for example `Solution Checker`, `AppSource Certification`, or GUID). Use `none` to omit `--ruleSet`. |
| `excludedFiles` | Global + Solution | One or more glob patterns. Patterns are expanded to concrete file paths before calling PAC `--excludedFiles`. |
| `ruleLevelOverride` | Global + Solution | Rule override definitions. Supported formats: JSON file path, hashtable, or array of rule override objects. |
| `maxParallel` | Global | Maximum number of solutions checked in parallel. Default: `4`. |

The other shipped defaults are `enabled = $false`, `geo = 'Europe'`, `ruleSet = 'Solution Checker'`, `excludedFiles = @()`, and `ruleLevelOverride = @()`. Severities are ordered `Critical`, `High`, `Medium`, `Low`, `Informational`. `maxParallel` is a global setting, even when a per-solution hashtable includes that key.

Relative exclusion patterns are resolved from `solutions/<name>` using PowerShell file
matching; unmatched patterns produce warnings.

> [!TIP]
> Prefer inline rule-override objects when portability matters. A JSON override path is
> passed to PAC as supplied, so it must be valid from the build's working directory.

#### Authentication behavior for solution check

ALM4Dataverse uses:

```text
pac auth create --managedIdentity
```

This uses Default Azure Credential and is designed to pick up an existing Azure identity context (for example Azure CLI sign-in, managed identity, or workload identity federation). If no non-interactive Azure identity context is available, solution check fails with a clear error.

> [!NOTE]
> `connect.ps1` also initializes PAC auth unconditionally so future PAC-based operations can reuse the same behavior.

#### Reports and failure visibility

When solution checks run, build output includes `solution-check/` artifacts:

- `solution-check/summary.md`
- `solution-check/solution-check-summary.json`
- per-solution logs and PAC output folders

Azure DevOps and GitHub build templates upload a dedicated `solution-check-report` artifact for easy viewing.

## Advanced - Fork Configuration

To customize this configuration in a custom fork, you can edit the `alm-config-defaults.psd1` file in the ALM4Dataverse repository root.

Fork configuration is merged with `alm-config.psd1` as follows:

- **Hashtables**: Merged recursively; the application repository's values override your fork defaults.
- **Arrays**: Default items first, followed by application items.
- There is no separately loaded `fork-almconfig.psd1` file.

This allows forks to add custom defaults that contribute custom config to each repo using the pipelines and without needing to make edits in each of those repos. For example, standard hook scripts can be added to extend ALM4Dataverse across every consuming repo. See the note above about `[alm]` placeholder allowing you to put the scripts in your fork of this repo.
