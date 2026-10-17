# Adding Dataverse Components

Use this guide to get common Dataverse components into an ALM4Dataverse release.
For the full solution configuration reference, see [Solutions](../config/alm-config.md#solutions). For export, build, and
deployment behavior, see [Exporting changes](exporting-changes.md),
[Building releases](building-releases.md), and [Deploying](deploying.md).

## Solutions

Create or select a solution in Power Apps, set its publisher and unique name, then add
components in that solution. See Microsoft's
[Create a solution in Power Apps](https://learn.microsoft.com/en-us/power-apps/maker/data-platform/create-solution)
guide for the maker-portal steps.

Add the solution's unique name to `solutions` in the root hashtable in
`alm-config.psd1`. Merge it into the existing settings rather than replacing other
configuration:

```powershell
@{
    solutions = @(
        @{ name = 'ContosoCore' }
        @{ name = 'ContosoApp' }
    )
}
```

Keep solutions in dependency order: a solution that depends on another solution should
come after it. If the application already has the solution, no configuration change is
needed to add components to it.

## Plug-ins

### Plug-in Packages (Preferred)

For a Dataverse plug-in package (`PluginPackage` solution component with dependent
assemblies), follow Microsoft's instructions to [create and register a plug-in package
using PAC CLI](https://learn.microsoft.com/en-us/power-platform/developer/howto/cli-create-package)
or [using Visual Studio](https://learn.microsoft.com/en-us/power-platform/developer/howto/vs-create-package).

**Simple workflow:** Build and register or update the package in DEV, add the package
and required plug-in types and steps to the solution, then run EXPORT. If this is a new
solution, add its unique name as described in [Solutions](#solutions).

**Build and map the package from repository source:** Create the package project in
`plugins/Contoso.Plugins/` using Microsoft's instructions above. This rebuilds the
package from the latest source during BUILD and includes it in the published solution,
so code changes don't require registering the package in DEV and exporting it again.
Add this mapping to the existing solution entry in `alm-config.psd1`:

```powershell
@{
    solutions = @(
        @{
            name = 'ContosoPlugins'
            mappings = @(
                @{
                    type = 'FileToFile'
                    source = 'plugins/Contoso.Plugins/bin/Release/Contoso.Plugins.1.0.0.nupkg'
                    destination = 'pluginpackages\Contoso.Plugins\package\Contoso.Plugins.nupkg'
                    buildCommand = @{
                        name = 'Build Contoso plug-in package'
                        executable = 'dotnet'
                        arguments = @('build', 'plugins/Contoso.Plugins/Contoso.Plugins.csproj', '--configuration', 'Release')
                    }
                }
            )
        }
    )
}
```

Use the actual package output filename and the package path and filename from the
unpacked solution. `buildCommand` runs during BUILD, so build the package before EXPORT
as well. See the [SolutionPackager mapping reference](../config/alm-config.md#build-processing)
for path rules.

### Traditional Plug-in Assemblies

Use Microsoft's guides to [write a plug-in](https://learn.microsoft.com/en-us/power-apps/developer/data-platform/write-plug-in)
and [register a plug-in](https://learn.microsoft.com/en-us/power-apps/developer/data-platform/register-plug-in).
Register or update the assembly and its plug-in types and steps in DEV, and include the
required components in the solution you export.

**Simple workflow:** Register or update the assembly in DEV as part of the solution and
run EXPORT.

**Build the DLL from repository source:** Create the project at
`plugins/Contoso.Plugin/Contoso.Plugin.csproj`, then add this mapping to the existing
solution entry in `alm-config.psd1`. This builds the checked-in project and packages its
latest DLL with the solution, so source changes don't require registering the assembly
in DEV and exporting it again:

```powershell
@{
    solutions = @(
        @{
            name = 'ContosoPlugins'
            mappings = @(
                @{
                    type = 'FileToFile'
                    source = 'plugins/Contoso.Plugin/bin/Release/Contoso.Plugin.dll'
                    destination = 'PluginAssemblies\Contoso.Plugin.dll'
                    buildCommand = @{
                        name = 'Build Contoso plug-in'
                        executable = 'dotnet'
                        arguments = @('build', 'plugins/Contoso.Plugin/Contoso.Plugin.csproj', '--configuration', 'Release')
                    }
                }
            )
        }
    )
}
```

The `buildCommand` runs during BUILD, not EXPORT. For an existing solution, the mapped
source path must be available when EXPORT compares the previous package. See the
[SolutionPackager mapping reference](../config/alm-config.md#build-processing).

## Web Resources

### Simple Web Resources

For a small static JavaScript, HTML, CSS, or image file, use the
[Microsoft web resource instructions](https://learn.microsoft.com/en-us/power-apps/maker/model-driven-apps/create-edit-web-resources)
to add it to the solution in DEV, then run EXPORT.

**Map repository files into the solution:** Create
`webresources/contoso/` and put the static files there. Add this `Folder` mapping to the
existing solution entry in `alm-config.psd1`. This keeps the files in source control
and includes the latest files in the published solution during BUILD, without manually
adding each change to the DEV solution and exporting it again:

```powershell
@{
    solutions = @(
        @{
            name = 'ContosoApp'
            mappings = @(
                @{
                    type = 'Folder'
                    source = 'webresources/contoso'
                    destination = 'WebResources\Contoso'
                }
            )
        }
    )
}
```

For an individual file, use `FileToFile` instead. These mappings put files into the
solution package; they do not go in `assets`. Keep package paths consistent with the
web-resource names referenced by the app. See the
[mapping reference](../config/alm-config.md#build-processing) for path rules.

### Bundled Web Resources (for example, Vite)

Vite's [production build guide](https://vite.dev/guide/build) describes its default
`dist` output.

**Simple workflow:** Build locally, add the files from `dist` as web resources in the
DEV solution, then run EXPORT.

**Build and map repository output:** Keep the Vite project and lockfile in
`webresources/contoso/`. Add this mapping to the existing solution entry in
`alm-config.psd1` to build the project during BUILD and pack `dist`. This builds the
latest source for each release and includes the generated files in the published
solution, without manually uploading them to DEV and exporting again:

```powershell
solutions = @(
    @{
        name = 'ContosoApp'
        mappings = @(
            @{
                type = 'Folder'
                source = 'webresources/contoso/dist'
                destination = 'WebResources\Contoso'
                buildCommand = @{
                    name = 'Build Contoso web resources'
                    executable = 'npm'
                    arguments = @('run', 'build')
                    workingDirectory = 'webresources/contoso'
                }
            }
        )
    }
)
```

Configure Vite's output and asset paths so the HTML resource and every emitted file
resolve correctly after upload to Dataverse, then test them from the deployed app.

The `buildCommand` above runs during BUILD only. EXPORT does not run it, and mapped
source paths for an existing solution must be available when EXPORT reconstructs and
compares the previous package. See [Build Processing](../config/alm-config.md#build-processing)
and [Export Processing](../config/alm-config.md#export-processing) for these mapping
requirements and other supported options.

## Power Apps Code Apps

Follow Microsoft's [Code Apps quickstart](https://learn.microsoft.com/en-us/power-apps/developer/code-apps/how-to/create-an-app-from-scratch)
to create the app. Keep its project and npm lockfile in source control. Add the
repository-relative project path to the owning solution's `codeApps` setting:

```powershell
@{
    solutions = @(
        @{
            name = 'ContosoApp'
            codeApps = @('code-apps/ContosoCodeApp')
        }
    )
}
```

BUILD and IMPORT install dependencies and run each app's build before packaging it.
By default, DEPLOY and IMPORT patch the built files into the app's existing component in
the owning solution before importing it. The Code App must already be included as a root
component in that solution; otherwise deployment fails before any solution is imported.
Set `codeAppPublishMethod = 'pac'` to use `pac code push` after import instead. Keep code
app projects out of `assets`.

The PAC method requires Power Platform API RBAC access; Dataverse permissions alone
aren't sufficient. The solution-package default avoids this broader permission
requirement. See [solution settings](../config/alm-config.md#solutions) for details and
[Node.js for Code Apps](../config/alm-config.md#nodejs-for-code-apps) for version
selection and conditional installation.
