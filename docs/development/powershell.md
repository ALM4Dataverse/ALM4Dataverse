# PowerShell Development

## Commenting Standard

Review every entry point, helper and embedded program when changing a contract.
Comments are written individually after reading the implementation, callers and
tests. Do not generate help blocks from names, bulk-insert comments, or use scripts
to draft prose. Automated inventories and validation are useful; automated comment
authorship is not part of this repository's workflow.

- Give executable entry points accurate comment-based help for purpose, meaningful
  parameters, prerequisites, side effects, outputs and errors. Examples must match
  actual invocation contracts and must not include credentials.
- Document shared and non-trivial helpers where their contract is not evident:
  return shape, sentinel/null behavior, ordering, caller-owned state, failure
  propagation and mutation/confirmation boundaries.
- Use short inline comments for non-obvious reasons, invariants and compatibility
  constraints. Do not narrate assignments, loops, assertions or readable names.
  A trivial private helper does not need boilerplate merely to increase a count.
- Assess existing comments too. Correct misleading claims and remove redundant
  narration; preserve explanations of constraints that still apply.
- Keep one authoritative explanation near the behavior it owns. Review source
  templates and generators together, using the correct host/embedded comment
  syntax. Do not accidentally change a YAML scalar or a here-string's emitted code.
- Keep comment-only work behavior-neutral: preserve executable tokens, literals,
  configuration, test assertions and generated contracts. Run existing validation,
  including the changed-file coverage gate, rather than assuming prose cannot
  affect parsing or help discovery.
- Never claim complete dry-run support, runtime compatibility, security assurance
  or live integration coverage based only on comments or mocked tests.

Complete coverage means every file and relevant symbol/block is assessed for
useful documentation, not a compulsory comment on every line. Maintain comments
and help alongside future behavior changes as required by
[repository instructions](../../AGENTS.md).
Assistant-authored prose is not represented as human-authored or human-approved;
maintainers review it through the normal pull-request process.

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
    Build/export cases also cover ordered inline mappings, generated mapping-file
    lifetime, build-command staging and preservation of mapped source changes.
- Export configuration, logging, concurrency limits, worker failures and cleanup:
    `ParallelExport`. These tests run real thread jobs with an isolated fake
    Dataverse module and temporary Git repositories; they do not contact Dataverse.
- Dependency installation, cache outputs, and update automation:
    `PipelineDependencies`, `DependencyCache`, and `DependencyUpdates`.
- Azure DevOps and GitHub baseline selection: `BuildBaseline` and
    `GitHubBuildBaseline`.
- GitHub deployment gates, environment mapping, and authentication:
    `GitHubDeployment` and `GitHubEnvironment`.
- Coverage calculations, validation enforcement, and release packaging:
    `Coverage`, `Validation`, and `Release`.
- Documentation links, examples and configuration reference coverage: `Documentation`.
- Shared setup prompts, rendering, configuration and selectors: `SetupCommon`.
- Provider identity, Dataverse users, solutions and environments: `SetupEnvironment`.
- Provider authentication, lookup failures, mutation guards and generated files:
    `SetupProviders`.
- Repository selection, synchronization, publication and cleanup: `SetupRepository`.
- Branch-aware setup wizard decisions and editor callbacks: `SetupWizard`.

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

Run setup suites in a fresh PowerShell process to report command coverage for all
three setup scripts:

```powershell
pwsh -NoProfile -File ./tests/helpers/Invoke-SetupTests.ps1
pwsh -NoProfile -File ./tests/helpers/Invoke-SetupTests.ps1 -TestPath tests/SetupEnvironment.Tests.ps1
```

The setup runner uses the pinned Pester version, fails on test failures, and prints
per-file coverage and the largest uncovered functions. A single-suite percentage
reports only that suite's coverage. Use the full validation command for analyzer
checks, saved artifacts and enforcement of the 65% changed-file gate.

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

> [!WARNING]
> The legacy `-UseDeviceAuthentication` installer switch remains accepted for
> compatibility but does not select device-code authentication. Setup continues
> to use its existing authentication flow.

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

All three setup scripts meet the same 65% whole-file command coverage threshold as
other executable source files. Startup commands remain part of the denominator;
there are no setup exemptions or reduced thresholds.

Setup tests cover prompt and rendering contracts, configuration editing, wizard
steps, branch/environment mapping, identity reuse and creation, service-account
ownership, Dataverse solution discovery, provider permissions, generated files,
repository publication, cleanup and mutation guards. Service and native-command
boundaries are mocked; configuration and workflow files are generated in temporary
directories. Both generated standalone installers are syntax-checked.

> [!IMPORTANT]
> Coverage does not certify an entire interactive installation, real console
> rendering, authentication or live resource provisioning. Review the all-file
> coverage report when extending setup behavior and add meaningful regression
> scenarios for the affected paths.

The automated suite does not certify real PAC/Dataverse integrations or parallel
solution-checker execution. Parallel export runtime scenarios use controlled
service responses; checker parsing, result handling, and thresholds are tested
with controlled command responses.

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

Required mock signatures, hook entry points, fixed callback arguments, and
parameters used inside nested callbacks have justified local
`SuppressMessageAttribute` declarations. Production declarations name the exact
parameter. Blanket unused-parameter suppressions are restricted to empty test
command stubs; a regression test enforces that boundary. Two naming suppressions
preserve external Dataverse cmdlet names in their corresponding test stubs.

Internal helpers use approved verbs and singular nouns, even when they return
collections. Dead internal parameters and their callers have been removed.
Regression tests require zero findings for unused parameters, singular nouns,
and approved verbs without adding global rule exclusions.

Each exception names the exact file, function, rule, source expression, and reason.
Unexpected findings fail validation. Exceptions that match zero or multiple
findings also fail and must be reviewed, not automatically refreshed.

Validation fails at the analyzer gate when new findings are introduced; tests and
coverage are not run after analyzer failure. Use focused Pester runs while
addressing analyzer findings. Parallel export has local justifications for its
explicitly parameter-bound worker and mandatory resource teardown; its start
helpers use tested `ShouldProcess` guards.

## CI Checks

The Repository Validation workflow runs on pull requests, pushes to `main`, version
tags, and manual dispatch. It runs the local validator on Windows and Linux using
PowerShell 7, checks checked-in and setup-generated GitHub workflows with
`actionlint`, and validates checked-in and setup-generated Azure DevOps pipelines
against Microsoft's Azure Pipelines schema. Windows additionally parses the
generated installers with Windows PowerShell 5.1. This is a syntax check, not a
full setup runtime compatibility test.

Test and coverage reports are retained as workflow artifacts for 14 days,
including when validation fails. The per-file coverage table also appears in the
GitHub Actions job summary. A file below 65% fails the matrix job and the
**Validation Required** check.

Repository maintainers should require **Validation Required** in the branch
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
