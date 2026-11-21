# Setup end-to-end harness

[`tools/SetupE2e/Invoke-SetupE2e.ps1`](../../tools/SetupE2e/Invoke-SetupE2e.ps1) runs the
real `setup-azdo.ps1` or `setup-github.ps1` in a pseudo-terminal, records every keystroke
and screen frame, and can replay a recorded sequence. Use it to verify the interactive
setup experience end to end against disposable organizations.

> [!WARNING]
> A run provisions real Azure DevOps or GitHub resources, creates Entra app
> registrations, and changes Dataverse environments. Run it only against a dedicated
> project and non-production environments with a dedicated test account.

## Prerequisites

- PowerShell 7.2 or newer for the harness itself.
- Azure Artifacts access for the pinned `Rnwood.Dataverse.Data.PowerShell` module on the
  first run, plus `git`, `gh` when recording GitHub setup, and network access to both
  platforms.
- `setupPowerShellPath` in the configuration when the current host runtime cannot load
  the pinned Dataverse module. PowerShell 7.7/.NET 11 currently fails to construct the
  Dataverse organization client; PowerShell 7.6 works. See
  [ALM4Dataverse/Rnwood.Dataverse.Data.PowerShell#1541](https://github.com/ALM4Dataverse/Rnwood.Dataverse.Data.PowerShell/issues/1541).
- One interactive sign-in per service. The harness recorders keep that sign-in so later
  steps run unattended; it never records tokens.

## Configuration

1. Copy [`config.example.psd1`](../../tools/SetupE2e/config.example.psd1) to
   `tools/SetupE2e/config.local.psd1`. The local file is ignored by Git.
2. Fill in the disposable organization, project, repository, environment names and
   Dataverse URLs. Keep real tenant, environment or user identifiers out of committed
   files.
3. Optionally add `setupPowerShellPath` to select the child PowerShell used by setup.

Scenarios live in [`scenarios.psd1`](../../tools/SetupE2e/scenarios.psd1). Every `Wait`
text must appear verbatim on the rendered screen. The harness expands
`{{section.key}}` placeholders and the key tokens `{ENTER}`, `{TAB}`, `{ESC}`,
`{SPACE}`, `{BACKSPACE}`, `{DELETE}`, `{UP}`, `{DOWN}`, `{LEFT}`, `{RIGHT}`, `{HOME}`,
`{END}`, `{PGUP}` and `{PGDN}`. Use double braces for literal braces.

## Run

```powershell
./tools/SetupE2e/Invoke-SetupE2e.ps1 -ListScenarios
./tools/SetupE2e/Invoke-SetupE2e.ps1 -Interactive -Provider azdo
./tools/SetupE2e/Invoke-SetupE2e.ps1 -Scenario azdo-new-repository
./tools/SetupE2e/Invoke-SetupE2e.ps1 -Scenario github-existing-repository
```

`github-existing-repository` expects the configured application repository to exist
with no ALM4Dataverse configuration and a configured fork of the shared workflow
repository. Align the fork with the shared branch before the run so the version check
does not stop at a reconciliation prompt. The scenario creates Entra app registrations
and a GitHub environment per deployment target, so use a disposable repository and
tenant.

Each run writes to `TestResults/setup-e2e/<timestamp>-<provider>-<mode>/`:

| File | Content |
| --- | --- |
| `session.cast` | asciinema v2 recording with real timing. |
| `transcript.txt` | Keystrokes interleaved with the rendered screens and timestamps. |
| `events.jsonl` | Structured steps, notes, assertions, captures and completion state. |
| `latest.txt` | Current screen, updated while the run is live. |
| `state.json` | Sequence and readiness state used by interactive drivers. |
| `control.jsonl` | Appended commands for interactive mode. |
| `screens/`, `images/` | Text and optional PNG snapshots. |

Run artifacts contain organization, project, environment and user names. They are
ignored by Git; do not publish raw recordings.

## Interactive driving

Start with `-Interactive`, then append one JSON object per line to `control.jsonl`
using the `action` names `wait`, `type`, `keys`, `select`, `capture`, `assert`, `note`,
`sleep` and `stop`. Read `latest.txt` and `state.json` between commands. Interactive
`wait` probes are capped at ten seconds so a wrong guess cannot block corrective input;
send another wait to keep polling. Waits and assertions are non-fatal in interactive
mode, but `select` throws when its item never appears so a wrong screen cannot activate a
different menu entry. `select` waits for a highlighted menu to render, narrows a searchable menu by
typing the requested label, or moves the highlight with Down on a short menu, then
presses Enter.

## View a recording in a browser

`Write-SetupE2eHtmlViewer` in the harness script turns a run directory into a
self-contained HTML replay with a playhead, playback speed, and a clickable synchronised
input list. It embeds the captured frames, so no data leaves the workstation:

```powershell
. ./tools/SetupE2e/Invoke-SetupE2e.ps1
$path = Write-SetupE2eHtmlViewer -RunDirectory ./TestResults/setup-e2e/<run-directory>
Start-Process $path
```

The page needs no network access and is written inside the ignored run directory.

## Recorded scenario actions

| Action | Fields | Behavior |
| --- | --- | --- |
| `Wait` | `Text`, optional `TimeoutSeconds` | Samples the screen until the text appears. |
| `Assert` | `Text`, optional `TimeoutSeconds` | Like `Wait`, but records the intent as an assertion. |
| `Type` | `Text`, optional `TypingDelayMilliseconds` | Types characters one at a time. |
| `Keys` | `Keys` | Sends key tokens or printable text. |
| `Select` | `Text` | Filters a searchable menu or moves the highlight to the item containing the text, then presses Enter. |
| `AnswerIfPresent` | `Text`, optional `Type`, `Keys` and `TimeoutSeconds` | Answers an optional y/n or text prompt when it appears; continues when it does not. |
| `Capture` | `Label` | Writes a numbered screen snapshot. |
| `Sleep` | `Milliseconds` | Waits without touching the terminal. |
| `Note` | `Text` | Writes a marker into the transcript and events. |

`Select` makes scenarios independent of account-specific list ordering: repositories,
environments and solutions appear in different positions in every organization.

`Wait` samples the whole visible screen, including content the terminal has not
repainted yet. Make repeated text unique to the current step, for example wait for
`Credentials - WIF - <app> - TEST - deployment` instead of `Credentials - WIF`, and add
a short `Sleep` after a selection that replaces a screen with a different instance of
the same title. Otherwise a stale frame can satisfy the wait and the next action runs
against the wrong prompt.

## GitHub notes

- The generated **APPLY-CONFIG** workflow commits workflow files, and GitHub never lets
  the built-in Actions token create or update workflow files on the default branch. Store
  a token with the Workflows permission (`workflow` scope for a classic personal access
  token, or **Workflows: read and write** for a fine-grained token) as the
  `ALM4DATAVERSE_APPLY_TOKEN` repository secret before validating a commit run. Preview
  runs do not need it. See
  [apply configuration token](../config/github-secrets.md#apply-configuration-token).
- A workflow dispatch needs the workflow file on the default branch. Push the scaffold
  file, then dispatch it by its exact file name, or the API answers `404 workflow not
  found on the default branch`.
- Disposable repositories used for validation should be private. Private repositories on
  the free plan have no branch protection or rulesets, so a direct apply commit is
  accepted once the token has the workflow permission.

## Azure DevOps notes

- Environments created for deployment stages carry approval checks. The harness controls
  only the terminal, so approve checks through the Approvals API after the run queues a
  deployment, or approve them manually. A `.http`-free example using the authenticated
  REST client is in the validation log referenced by the pull request that added this
  guide.
- Pipeline definitions are named `<repository>-BUILD`, `<repository>-EXPORT`,
  `<repository>-IMPORT` and `<repository>-DEPLOY-<branch>`. Pipeline completion triggers
  resolve the BUILD resource by name, so a project with two application repositories must
  not contain two pipelines named `BUILD`. Setup adopts and renames older unqualified
  definitions that point at the same repository, and rewrites generated DEPLOY callers to
  the qualified name.
- Pipeline completion triggers are registered from the YAML that exists on each
  definition's branch when the definition is created. Setup now seeds a new repository's
  default branch with the first direct-commit publication, so main's generated callers
  exist before its `DEPLOY-<branch>` definition is created. Without that seeding, a
  deployment configured for a branch that is only created later never fires from BUILD
  completion until its YAML changes; regenerate or apply configuration again after such a
  branch is created outside setup.
- Deleted Git repositories stay in the project recycle bin. Purge them before reusing a
  repository name in a repeat run; otherwise repository creation fails with `409`.

## Cleanup

Remove or recycle-run specific resources after a validation:

- Azure DevOps: pipelines, environments, service connections, variable groups, and the
  application/shared repositories. Purge recycled repositories.
- GitHub: the disposable repositories and the environments created on them.
- Dataverse: application users and service-account role assignments created for the test
  environments.
