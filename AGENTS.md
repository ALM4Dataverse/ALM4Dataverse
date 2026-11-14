# Repository Guidelines

This is the shared ALM4Dataverse implementation, not an application repository.
Application repositories receive the files in `copy-to-your-repo/`, whose
[`AGENTS.md`](copy-to-your-repo/AGENTS.md) is for agents working on applications.

## Orientation

- Read the [source map](docs/maintainers.md#source-map) to find where a behavior lives.
- A user-visible contract usually spans the runtime script under `pipelines/scripts`,
  the Azure DevOps template under `pipelines/templates`, the GitHub action under
  `.github/actions`, the callers in `copy-to-your-repo`,   the setup entrypoints (`setup-azdo.ps1`, `setup-github.ps1`) and shared helper
  modules under `setup/`, plus the reference in `docs/config`. Change them together.
- Builds snapshot `pipelines/scripts` and `alm-config-defaults.psd1` into the artifact.
  Deployment code must work with what the artifact contains and fail with a rebuild
  instruction when a newer helper is missing.
- Never put credentials, tokens or real tenant, environment or user identifiers in
  source, tests or examples.

## Checks

Run from the repository root in PowerShell 7.2 or newer, without platform credentials:

- `./scripts/Test-PowerShell.ps1` runs syntax and analyzer checks, then every Pester
  suite (including workflow and pipeline schema validation), then the coverage gate:
  every added or modified PowerShell helper source file needs at least 65% command
  coverage across the whole file. The two root setup entrypoints are syntax- and
  release-tested, but are excluded from command coverage.
- `./.github/scripts/test-documentation.ps1` checks Markdown links and anchors, fenced
  PowerShell, YAML and JSON, and that every configuration key, hook, action input and
  template parameter is documented in `docs/config`.
- `git diff --check`.

For a focused run, pass `-Path` to `Invoke-Pester` with the relevant `tests/*.Tests.ps1`
files. See [local checks](docs/maintainers.md#local-checks) and
[PowerShell development](docs/development/powershell.md).

## Documentation

Keep end-user guides task-focused and put exhaustive detail in the `docs/config`
references; link rather than repeat facts. Preserve existing documentation file paths,
because setup output and application `AGENTS.md` files link to them. Add user-visible
changes that need action on upgrade to [upgrade notes](docs/usage/upgrade-notes.md).

When a change affects guided setup steps, prompts, navigation, previews, or generated
artifacts, update the affected step-by-step guide(s) in the same change:
[GitHub setup](docs/setup/github-setup.md) and/or
[Azure DevOps setup](docs/setup/azdo-automated-setup.md). Keep every user-visible step
documented. Capture screenshots from the current setup implementation; never use
illustrative, reconstructed, or mock screenshots. For text-only output, include
verbatim output captured from the current setup helpers or preview generators rather
than hand-authored approximations. Use reserved example values and exclude credentials
and real tenant, environment, or user identifiers.
Regenerate the full screenshot set with
`pwsh -NoLogo -NoProfile -File ./tools/SetupScreenshotCapture/Capture-SetupScreenshots.ps1`;
use `-Scene <name>` for one image and `-ListScenes` to list scene names. This
PowerShell-only tool runs the real helpers in a PTY-backed terminal, captures the
rendered terminal frames with an explicit monospaced font, and downloads pinned
NuGet libraries on first use. It requires PowerShell 7.6/.NET 10 and NuGet access
on first use; do not add `.cs` or `.csproj` files to the screenshot workflow.

## Comments and Help

Follow the [commenting standard](docs/development/powershell.md#commenting-standard)
for all new and modified code.
Write each comment individually after reading its implementation and relevant
callers/tests; never script-generate or bulk-insert commentary. Explain contracts
and non-obvious reasons, not readable statements. Review embedded code and generated
sources without changing executable content during comment-only work.

Whenever you add or change behavior, review and update the affected script help,
function contracts, inline rationale, configuration examples, templates and
generator commentary in the same change. Check relevant callers and tests so
comments describe actual defaults, return values, side effects and failure behavior.
Remove or correct stale comments; do not leave contradictory explanations behind.
Document new non-obvious contracts and decisions, but do not add boilerplate to
self-explanatory code. Validate help placement, embedded syntax and generated
outputs using the existing checks described in the development guide.

## Pull Request Descriptions

When creating or updating a pull request, keep end-user information separate from implementation details:

- Use `## End-user changes` for observable behavior, configuration options, and user impact in plain language.
- Use `## Implementation details` for internal design, compatibility handling, and test implementation.
- Use `## Validation` for commands and results, including any failures or known limitations.
- Do not mix internal mechanics into the end-user section. Omit a section only when there is nothing relevant to report.
