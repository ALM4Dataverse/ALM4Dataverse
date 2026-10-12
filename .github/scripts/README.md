# Maintainer Scripts

See the [maintainer guide](../../docs/maintainers.md) for prerequisites, release
preparation/publication, test boundaries, and dependency-update operation.

## Files

| Script | Purpose |
| --- | --- |
| [check-outdated-dependencies.ps1](check-outdated-dependencies.ps1) | Query PowerShell Gallery for newer configured module versions; output `outdated-deps.json` and `has_updates`. |
| [update-dependency-prs.ps1](update-dependency-prs.ps1) | Consume that file, update Git branches, and create/update remote PRs. Not an offline check. |
| [test-dependency-workflow.ps1](test-dependency-workflow.ps1) | Offline dependency-data/update-pattern smoke checks. |
| [test-deployment-options.ps1](test-deployment-options.ps1) | Strict-mode deployment-option checks and generated/copied workflow guard checks. |
| [test-environment-mapping.ps1](test-environment-mapping.ps1) | Offline direct/prefixed variable and selected-secret precedence checks. |
| [test-documentation.ps1](test-documentation.ps1) | Local links/anchors, fenced example syntax, and reference-name coverage. |

## Automated Dependency Update Workflow

The [workflow](../workflows/update-dependencies.yml) runs daily at **02:00 UTC** or from
**Actions > Update Script Dependencies > Run workflow**. It checks `scriptDependencies`,
not the PAC CLI version. New branches use `deps/update-<module>-to-<version>`; existing
matching open PR branches are reused. Commits use `chore(deps): update <module> to <version>`.

> [!CAUTION]
> The PR script rebases and pushes with `--force-with-lease`. Run it only in its intended
> automation/disposable checkout with authorized GitHub credentials, not as a local test.
> See [dependency maintenance](../../docs/maintainers.md#dependency-updates).

## Testing

Run from the repository root in PowerShell 7. Install `powershell-yaml` if required,
as described in the [local check prerequisites](../../docs/maintainers.md#local-checks).

```powershell
& ./.github/scripts/test-dependency-workflow.ps1
& ./.github/scripts/test-deployment-options.ps1
& ./.github/scripts/test-environment-mapping.ps1
& ./.github/scripts/test-documentation.ps1
```

> [!NOTE]
> These checks do not contact Dataverse, authenticate to Azure, or create remote resources.
> They do not replace hosted integration tests or prove custom hooks are safe to replay.
