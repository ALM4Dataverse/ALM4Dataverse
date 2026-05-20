# ALM Configuration (alm-config.psd1)

The `alm-config.psd1` file in your repo is the central configuration file for the ALM4Dataverse pipeline system. It defines which solutions to deploy, assets to include, hook scripts to run, and dependencies required for the build, export, and deployment processes.

## Location

The configuration file should be placed in the repository root. The pipelines expect to find it at the root of your repository alongside your solution folders.

## Configuration Sections

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
- `name` (required): Unique solution name that matches your solution folder in the source directory
- `deployUnmanaged` (optional, default: false): Boolean indicating whether to deploy the unmanaged version instead of managed
- `serviceAccountUpnConfigKey` (optional, default: 'DataverseServiceAccountUpn'): Name of the environment configuration key containing the service account UPN to use when activating processes in this solution

### Assets

Extra folders or files to include in build artifacts, copied verbatim to the artifacts directory.

```powershell
assets = @(
    'data',
    'config',
    'documentation'
)
```

Paths are relative to the repository root. This is useful for including data migration scripts, configuration files, or other resources needed during deployment.

### Hooks

Hook scripts are executed at various stages of the build, export, and deployment processes and can be used to add custom steps. Each hook is a list of script paths relative to the repository root that will be executed at one stage of the standard process. 'Pre' hooks occur before the standard steps and 'post' hooks occur after.

Scripts can use the built-in `Rnwood.Dataverse.Data.PowerShell` PowerShell module to complete a wide range of activities. [See the project site](https://github.com/rnwood/Rnwood.Dataverse.Data.PowerShell) for full documentation. The current environment is automatically set to the target environment.

You can also include any other PowerShell module from the [PowerShell Gallery](https://powershellgallery.com) by including it in the `scriptDependencies` section. See below.

Example hooks:

- [Data import and export](example-hooks/data-import-export.md) (for example config/system data)
- [Organization/environment settings](example-hooks/organization-settings.md) (for example enabling the 'PCF allowed' switch)
- [Azure resource deployment with Bicep](example-hooks/azure-bicep.md) (for example deploying supporting Azure resources alongside Dataverse solutions)


```powershell
hooks = @{
    preExport      = @()
    postExport     = @('data/system/export.ps1')
    preDeploy      = @()
    dataMigrations = @()
    postDeploy     = @('data/system/import.ps1')
    preBuild       = @()
    postBuild      = @()
}
```

**Available Hooks:**

- **preExport**: Called before exporting solutions from a Dataverse environment
- **postExport**: Called after exporting and unpacking solutions
- **preBuild**: Called before packing solutions during the build process
- **postBuild**: Called after packing solutions and copying assets
- **preDeploy**: Called before staging and importing solutions
- **dataMigrations**: Called during deployment after solutions are staged but before upgrades. Use this for data migration scripts that need to relocate data before columns are removed
- **postDeploy**: Called after publish customizations

#### Hook Context

Each hook script receives a `$Context` parameter containing:

- `HookType`: The type of hook being executed
- `BaseDirectory`: The base directory for the hook (source or artifacts root)
- `Config`: The loaded alm-config.psd1 configuration
- Additional context specific to the hook type:
  - **preBuild, postBuild**: `SourceDirectory`, `ArtifactStagingDirectory`
  - **preExport, postExport**: `SourceDirectory`, `ArtifactStagingDirectory`, `TempDirectory`, `EnvironmentName`
  - **preDeploy, dataMigrations, postDeploy**: `ArtifactsPath`, `UseUnmanagedSolutions`

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

When build assets are generated, the version that has been selected is frozen and baked into the configuration file that will be used when deploying.
This ensures that the same exact version of all dependencies is always used for each release, even across extended time period and environments.

## Advanced - Fork Configuration

To customize this configuration in a custom fork, you can edit the `alm-config-defaults.psd1` file in the ALM4Dataverse repository root.

Fork configuration is merged with `alm-config.psd1` as follows:
- **Hashtables**: Merged (fork values override template values)
- **Arrays**: Concatenated (fork values appended to template values)
- **This file's values take precedence** when merging

This allows forks to add custom defaults that contribute custom config to each repo using the pipelines and without needing to make edits in each of those repos. For example, standard hook scripts can be added to extend ALM4Dataverse across every consuming repo. See the note above about `[alm]` placeholder allowing you to put the scripts in your fork of this repo.
