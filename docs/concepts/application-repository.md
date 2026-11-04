# Application Repository Layout

An application repository holds everything specific to one application: solution
source, its ALM configuration, data, hooks and the small caller files that run the
shared automation. This page shows what a typical repository contains after setup and
a first EXPORT, and who changes each part.

## Typical Layout

```text
alm-config.psd1                 # ALM configuration: solutions, assets, hooks, options
AGENTS.md                       # Instructions for AI coding agents
solutions/
  ContosoCore/                  # Unpacked solution, written by EXPORT
    Other/Solution.xml          #   includes the solution version
    ...
  ContosoApp/
data/
  system/
    export.ps1                  # Example postExport hook (no-op until customized)
    import.ps1                  # Example postDeploy hook (no-op until customized)
.github/workflows/              # GitHub Actions callers: BUILD, EXPORT, IMPORT,
                                #   DEPLOY-<branch>, CLEANUP-RELEASES
pipelines/                      # Azure DevOps callers: BUILD, EXPORT, IMPORT, DEPLOY-<branch>
```

Only one platform's callers run: `.github/workflows/` on GitHub, `pipelines/` on Azure
DevOps. Automated setup copies the whole scaffold, so the other platform's folder is
also present. It is inert, and you can delete it; setup adds it back on a re-run.
Additional folders are yours to add, for example `plugins/`, `webresources/` or
`code-apps/` for components built from source; see
[Adding Dataverse components](../usage/adding-dataverse-components.md).

## Who Changes What

| Path | Changed by | Notes |
| --- | --- | --- |
| `solutions/<unique-name>/` | **EXPORT** | Deleted and re-created from the development environment on every export. Hand edits are lost at the next EXPORT unless the same change is made in Dataverse. Review it in pull requests; don't edit it directly. |
| `solutions/<unique-name>/Other/Solution.xml` version | **EXPORT** | Incremented when the solution changes. See [version increments](../usage/exporting-changes.md#version-increments). |
| `alm-config.psd1` | You | Solution list and order, assets, hooks, mappings and options. See the [configuration reference](../config/alm-config.md). |
| Hook scripts and their data folders | You, plus your export hooks | Export hooks typically write data files here, which EXPORT then commits. |
| Source projects mapped into solutions | You | Built during BUILD by `buildCommand` mappings. |
| Caller workflows/pipelines | Setup, then you | Re-running setup keeps secret mappings and deployment stage settings but can replace other edits; review the diff. See [re-running setup](../usage/updating.md#re-run-setup-carefully). |
| `data/` and `AGENTS.md` | Setup creates them, then you | Setup never overwrites them once they exist. Add application-specific agent notes to `AGENTS.md`. |

## What Never Goes In The Repository

- Client secrets, tokens, passwords or connection strings. Store them in the CI
  platform; see [GitHub secrets](../config/github-secrets.md) or
  [Azure DevOps variable groups](../config/azdo-environment-variable-group.md).
- Target-specific values such as connection IDs and Dataverse environment-variable
  values. These are supplied per target at deployment time.
- Build output, such as `bin/`, `obj/`, `node_modules/` or `dist/`. Add a `.gitignore`
  for the source projects you add. BUILD regenerates mapped outputs.
- Customer or personal data exported by hooks unintentionally. Choose tables and
  columns deliberately.

## What BUILD Packages

BUILD turns a commit of this repository into an artifact. It packs each folder under
`solutions/`, copies the paths listed in `assets`, and adds the configuration, a snapshot
of the shared deployment scripts and a dependency lock. Everything a deployment hook
needs at deploy time must therefore be listed in `assets`. See
[artifact layout](../usage/building-releases.md#artifact-layout).

## Related Pages

- [Glossary](glossary.md)
- [ALM configuration reference](../config/alm-config.md)
- [Writing hooks](../usage/writing-hooks.md)
