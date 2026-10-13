# PowerShell Development

## Local Validation

Use PowerShell 7.2 or newer and Git. Install the pinned validation tools from
the repository root:

```powershell
$policy = Import-PowerShellDataFile ./scripts/powershell-validation.psd1
foreach ($tool in $policy.Tools.GetEnumerator()) {
    Install-Module -Name $tool.Key -RequiredVersion $tool.Value -Repository PSGallery -Scope CurrentUser -Force
}
```

Run the same checks used by CI:

```powershell
./scripts/Test-PowerShell.ps1
```

The command validates tracked and non-ignored untracked PowerShell files and
executes Pester. It syntax-checks `.ps1`, `.psm1`, `.psd1`, `.psrc`, and `.pssc`,
runs the configured PSScriptAnalyzer rules on scripts, modules, and `.psd1` files,
and parses `.ps1xml` and `.cdxml` as XML.

Test results are written to `TestResults/powershell.xml`. Command coverage for
executable scripts and modules is written to `TestResults/coverage.xml` in JaCoCo
format, with per-file results in `TestResults/coverage-files.json` and
`TestResults/coverage-summary.md`. `TestResults/coverage-all-files.json` also reports
every executable source file, including unchanged files. The changed-file report
controls the coverage gate; the all-file report identifies remaining coverage gaps.

Tests use temporary repositories and mocked Dataverse/package operations.
They do not provision resources, contact Dataverse, or push Git changes.
Release packaging tests generate and parse both standalone setup installers.

## Test Organisation

Suites live under `tests/`, grouped by the behaviour they own:

- Pipeline build, connection, deployment/import, export, and shared helpers:
    `PipelineBuild`, `PipelineConnection`, `PipelineDeployment`, `PipelineExport`,
    and `PipelineCommon`.
- Dependency installation, cache outputs, and update automation:
    `PipelineDependencies`, `DependencyCache`, and `DependencyUpdates`.
- Azure DevOps and GitHub baseline selection: `BuildBaseline` and
    `GitHubBuildBaseline`.
- GitHub deployment gates, environment mapping, and authentication:
    `GitHubDeployment` and `GitHubEnvironment`.
- Coverage calculations, validation enforcement, and release packaging:
    `Coverage`, `Validation`, and `Release`.
- Shared setup decisions and provider authentication, lookup failures, cleanup,
    credential writes, and mutation guards: `SetupCommon` and `SetupProviders`.

Each suite is named `<Suite>.Tests.ps1`. Tests invoke the production scripts and
helpers, assert resulting artifacts and decisions, and mock external service and
command boundaries. Temporary configurations, archives, and Git repositories
isolate test cases. Tests restore environment values and working directories.

Run a specific suite while iterating:

```powershell
Invoke-Pester -Path ./tests/PipelineBuild.Tests.ps1 -Output Detailed
```

A focused Pester run verifies behaviour; it does not replace the full validation
command or its per-file coverage gate.

### Setup Mutation Guards

Reviewed configuration, directory, repository, pipeline/workflow, credential,
and provisioning helpers support `-WhatIf` and `-Confirm`. A declined operation
returns before authentication, prompts, service requests, or filesystem changes.
Confirmation messages identify the target without including credential values.
Normal approved operations retain their existing behavior.

> [!CAUTION]
> This protection applies to the reviewed helpers, not the complete interactive
> setup scripts. The wizards do not yet support a complete dry run. Do not treat
> `$WhatIfPreference` as a safe dry-run switch for an entire setup session.

Failed Azure DevOps lookups propagate permission and authentication failures
instead of treating them as missing resources. Best-effort cleanup failures
emit static verbose diagnostics without replacing the original operation failure
or discarding an otherwise successful result.

## Coverage Gate

Each added, modified, copied, or renamed `.ps1` or `.psm1` source file must have
at least **65% command coverage across the entire file**, not just changed lines.
The check compares the unrounded percentage; a repository-wide average cannot
compensate for an under-covered file.

Files under `tests/`, `*.Tests.ps1`, and `*.Tests.psm1` are excluded from source
coverage. Deleted files are not checked. Data, manifest, configuration, and XML
files do not have an executable coverage threshold. Files with no executable
commands are reported as not applicable.

Local runs include staged, unstaged, and non-ignored untracked changes against
`HEAD`. To compare committed revisions:

```powershell
./scripts/Test-PowerShell.ps1 -BaseRef origin/main -HeadRef HEAD
```

CI compares the pull request base commit or the previous push commit with the
checked-out commit. Manual and tag runs compare with the first parent. A first
commit or a new branch push with no previous commit checks all source files.
An unavailable comparison commit fails validation rather than skipping coverage.

Coverage reports are generated before reporting test or threshold failures.
Existing tests may pass while coverage fails; add meaningful tests rather than
excluding under-covered source files or reducing the threshold.

### Setup Coverage Limits

> [!WARNING]
> `setup-azdo.ps1`, `setup-github.ps1`, and `setup-common.ps1` remain below the
> whole-file threshold. Changes to these files still fail the coverage gate.
> There are no setup exemptions or reduced thresholds.

Shared setup tests cover configuration editing, publication decisions, branch and
environment mapping, optional values, validation, and completed-operation handling.
Provider tests also cover mocked authentication failures, missing-resource
classification, credential writes, cleanup failures, and `-WhatIf` guards.
They do not cover the complete interactive wizards, console rendering, real
authentication, or live resource provisioning. Both generated standalone installers
are syntax-checked.

Reaching 65% across these large setup files needs broader wizard/provider scenario
tests or a separately scoped refactor that separates interactive orchestration
from independently testable decisions. Until then, use the all-file coverage report
to distinguish tested helpers from untested setup workflows.

The automated suite also does not certify real PAC/Dataverse integrations or
parallel-runspace execution. Checker parsing, result handling, and thresholds are
tested with controlled command responses.

## Analyzer Policy

The policy enables PSScriptAnalyzer's default rule set using
`IncludeDefaultRules = $true`, rather than maintaining a small `IncludeRules`
allowlist. New default rules supplied by a future pinned analyzer upgrade are
therefore included automatically. Rules requiring explicit configuration, such as
target-specific compatibility checks, are not enabled by this setting alone.

The only global exclusion is `PSAvoidUsingWriteHost`. Host output is intentional
for Azure DevOps logging commands, GitHub workflow commands, and interactive
setup progress. Data returned to callers should still use the success output stream.

Naming, aliases, unused parameters, output types, empty catches, encoding,
whitespace, and state-changing function checks remain enabled. A high finding
count is not justification for excluding a rule. Contract-specific false positives
should be reviewed individually rather than hidden by a global exclusion.

Fix findings where the intended behavior is clear. Do not introduce exceptions
solely to make CI pass.

Nine existing credential-contract exceptions are recorded individually in
`scripts/powershell-validation.psd1`. Two concern credential display names rather
than secret values. The others preserve existing structured authentication and
OAuth token contracts pending a separate credential-handling audit. These
exceptions are not a claim that all credential handling has been security-reviewed.

Eighteen state-change findings have exact exceptions for console rendering,
script-local UI state, process-local cleanup, in-memory counters and selection
objects, OIDC subject formatting, and test fixtures/stubs. Rendering prerequisites
may initialize console dependencies; these exceptions do not imply that the
complete wizard is safe to run under `-WhatIf`. Actual provisioning and file-change
helpers identified by this rule use `ShouldProcess` guards instead of exceptions.

Each exception names the exact file, function, rule, source expression, and reason.
Unexpected findings fail validation. Exceptions that match zero or multiple
findings also fail and must be reviewed, not automatically refreshed.

The expanded rule set currently exposes additional violations. Validation fails
at the analyzer gate until those findings are fixed or individually justified;
tests and coverage are not run after analyzer failure. Use focused Pester runs
while addressing analyzer findings.

## CI Checks

The PowerShell Checks workflow runs on pull requests, pushes to `main`, version
tags, and manual dispatch. It runs the local validator on Windows and Linux using
PowerShell 7. Windows additionally parses the generated installers with Windows
PowerShell 5.1. This is a syntax check, not a full setup runtime compatibility test.

Test and coverage reports are retained as workflow artifacts for 14 days,
including when validation fails. The per-file coverage table also appears in the
GitHub Actions job summary. A file below 65% fails the matrix job and the
**PowerShell Required** check.

Repository maintainers should require **PowerShell Required** in the branch
ruleset. The workflow alone does not configure branch protection or make the
existing release workflow wait for validation.

Pull requests created using `GITHUB_TOKEN` do not automatically trigger the
pull-request workflow. Dependency automation needs a GitHub App token or another
explicit validation trigger before its pull requests can satisfy a required check.

## Regression Tests

Run the focused suite directly when iterating:

```powershell
Invoke-Pester -Path ./tests -Output Detailed
```

Add tests against the production script or helper when fixing behavior. Cover
missing and null optional values, explicit false and zero values, empty query
results, and failure paths where relevant. Avoid copying production logic into tests.
