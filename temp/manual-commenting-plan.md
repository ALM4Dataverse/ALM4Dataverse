# Repository-wide manual commenting plan

Status: implementation and validation completed on 16 October 2026; approved for
PR publication. The review ledger contains final evidence and limitations.
Initial baseline: commit `1b29582`, inspected 16 October 2026.
Publication baseline: `4aa15e7`, integrated after main advanced during this work.
The added inline-mapping/build-command contracts were manually assessed too;
the final source inventory remains 76 files, with 312 production functions.

## 1. Requirement and scope

Review the complete first-party codebase and bring its comments and callable
documentation up to a consistent, useful standard. Every added or revised comment
must be written individually after reading its implementation and relevant callers
and tests. This is not a comment-generation or bulk-insertion project.

"Fully covered" means every in-scope file, function, entry point, embedded program,
and non-obvious decision has been assessed and its documentation needs resolved.
It does not mean commenting every statement or meeting a comment-density target.
Straightforward code should remain straightforward, without redundant narration.

Include production scripts, private helpers, tests and test infrastructure,
configuration, composite actions, workflows, pipeline templates, distributed
examples, and embedded PowerShell, shell, JavaScript and C# where present.
Review existing comments for accuracy as well as adding missing documentation.

Review Markdown examples and linked guidance for consistency with those contracts.
Images, third-party dependencies, generated release artifacts and tool output do
not receive direct comment edits. Their first-party source/generation logic remains
in scope. No refactoring, renaming, behavior changes, new analyzer exceptions or
coverage-policy changes are part of this work.

## 2. Current-state findings

- The tracked source/configuration inventory contains 76 files: 51 PowerShell
  scripts, three PowerShell data files, 21 YAML files and one JavaScript file.
  The full baseline inventory is in section 6.
- The initial read-only PowerShell AST inventory found 308 production function definitions.
  Of these, 225 are in the three setup scripts: 94 shared, 69 Azure DevOps and
  62 GitHub. These large files need multiple bounded review batches.
- A textual inventory found 43 production `.SYNOPSIS` markers. This is not a
  documentation-coverage score: markers can describe scripts rather than functions
  and say nothing about accuracy, completeness or correct help attachment.
- Sampled pipeline entry points already have comment-based help. Many helpers in
  build, deployment resolution and shared setup do not. Existing useful comments
  explain matters such as Windows PowerShell dependency compatibility and schema
  limitations; other comments merely restate an assignment or a directory creation.
- Setup includes embedded C# and generated workflow content. Release preparation
  inserts the shared setup library into two standalone installers. Comment
  placement must preserve these source-to-output relationships.
- Existing validation includes PSScriptAnalyzer, Pester, Markdown link/example
  checks, actionlint, Azure Pipelines schema checks and generated-installer parsing.
  Executable PowerShell changes are subject to a 65% whole-file command-coverage
  gate, including comment-only changes to those files.
- Existing guidance is in [PowerShell development](../docs/development/powershell.md).
  The current analyzer policy is not a comprehensive comment-quality gate.

This inspection establishes scope and representative gaps. It does not claim
that every function body has already undergone the detailed review planned below.

## 3. Gaps and documentation standard

| Surface | Required treatment |
|---|---|
| Executable entry points | Correctly attached PowerShell help: purpose, prerequisites, parameter semantics, externally visible outputs, side effects and meaningful invocation examples. |
| Shared or non-trivial functions | Individually authored contract help describing purpose, meaningful parameters, return shape, sentinel/null behavior, error behavior and relevant state changes. Include `.INPUTS`, `.OUTPUTS`, `.NOTES` and examples only where useful and accurate. |
| Small private helpers | Assess every helper. Add a concise contract or rationale only where names, types and implementation leave something material unclear. A recorded no-comment-needed decision is valid. |
| Complex implementation blocks | Explain why a policy, ordering constraint, fallback, retry, parser assumption, compatibility branch or cleanup rule exists. State invariants rather than narrating syntax. |
| Configuration | Explain units, valid ranges, default/merge precedence, missing/null/false/zero distinctions and effects of overrides where not already clear. Keep values and keys unchanged. |
| YAML and embedded scripts | Explain trigger/branch/SHA selection, permissions, credential source, expression evaluation timing, dependency order, conditions, artifact flow and deliberate scaffolds where non-obvious. Use the host and embedded language's own comment syntax in the correct layer. |
| Tests | Explain unusual fixtures, mocks, isolation, concurrency timing and regression intent not conveyed by test names. Do not annotate every assertion or add boilerplate help to each test. |
| JavaScript and embedded C# | Document non-obvious contracts, diagnostic filtering, indexing/position assumptions, cancellation/lifetime rules and interop constraints. Avoid JSDoc/XML boilerplate on trivial internals. |
| Existing comments | Retain accurate explanations; correct stale statements; remove misleading or purely repetitive comments. Do not preserve noise just to increase totals. |

For each actual comment:

1. Read the enclosing implementation, relevant callers, configuration and tests.
2. Identify the concrete maintenance question the comment must answer.
3. Write the explanation in the author's own words, specific to that location.
4. Verify every stated default, range, return shape, exception, side effect and
   compatibility claim against the code and available tests.
5. Place it at the narrowest useful scope; prefer one authoritative explanation
   and a reference over repeated prose.
6. Have the reviewer challenge accuracy, necessity and future maintenance cost.

Do not document intended behavior as if it already exists. If intent cannot be
established from code, tests or an authoritative contract, record an open question
and resolve it before declaring the unit complete. Do not invent historical
rationales, security guarantees, full dry-run support or live-integration coverage.

### Manual-authorship boundary

Allowed automation: read-only file/symbol inventories, search, diff inspection,
syntax/token comparisons, help discovery, existing lint/tests and existing release
or workflow generation used for validation.

Not allowed: scripts that draft or insert comments; AST-to-help generators;
regex comment injection; documentation generators used to author prose; templated
fill-ins; or whole-file/repository bulk comment generation. No tool may infer
prose from a symbol name and apply it across the codebase.

All prose is individually composed and applied as small, context-reviewed edits.
If an assistant performs the work, that remains assistant-authored prose, not a
claim that a human typed it. Human review is a separate completion gate.
Existing generators may carry an already-reviewed source comment into an output;
they must not originate new commentary. Do not add a second generator to do so.

## 4. Approach and options

| Option | Assessment |
|---|---|
| Add comments everywhere | Reject: duplicates readable code, creates drift and rewards volume over understanding. |
| Require full help blocks on every private function | Reject: unnecessary boilerplate on trivial helpers, while missing inline rationale and embedded-code concerns. |
| Generator followed by manual cleanup | Reject: violates the explicit manual-authorship requirement. |
| Complete manual assessment with risk-first, bounded edits | Recommend: accounts for every file and symbol while placing comments only where they add durable value. |

Start with a small calibration batch, then use the same standard throughout.
Keep changes comment/documentation-only. Report unrelated implementation defects
separately; do not silently fix or describe them away.

## 5. Execution sequence and review workflow

### Phase 0: Establish the review ledger and calibration

- Reconcile section 6 with the current tracked tree, including any newly added
  source extensions, embedded programs or renamed files. Record exclusions and
  reasons explicitly; no first-party code category is silently excluded.
- Extend the ledger within this plan with one entry per function/entry point and
  named complex block as it is reviewed. Use qualified names/enclosing scope
  and the review commit, not line numbers alone.
- Each unit records: file, symbol/block, current gap, decision, evidence consulted,
  author, reviewer, validation and status. Valid outcomes are `documented`,
  `existing comments verified`, or `no comment needed` with a specific reason.
  `Pending` and `blocked` are not completion outcomes.
- Calibrate on one representative helper from
  [shared pipeline code](../pipelines/scripts/common.ps1), one setup helper from
  [shared setup code](../setup-common.ps1), and one non-obvious block in the
  [build action](../.github/actions/build/action.yml).
- Obtain approval of depth and style before expanding to the remaining units.
  Do not accept a generic file-level "reviewed" checkbox as symbol-level evidence.

### Phase 1: Shared pipeline contracts and execution

Review group A, beginning with configuration, hook and authentication contracts,
then dependency/cache/baseline resolution, build/checker orchestration,
export/concurrency, import and deployment. Trace output artifacts and failures
through callers before describing them. Cover thread-job scope, worker arguments,
throttling, output ordering and mandatory cleanup.

### Phase 2: GitHub action orchestration

Review group B end to end: inputs -> environment/auth resolution -> deployment
selection -> build validation -> pipeline invocation -> outputs.
Document decisions around missing resources, branch/environment mapping and
validation gates without exposing credential values.

### Phase 3: Setup library and provider wizards

Review group C in dependency order: shared console/configuration/authentication
helpers; provider identity and resource lookup/provisioning; repository and
branch-aware publication; wizard orchestration and startup.

Split each large file by actual function families after reading its current
structure. Cover embedded C#, cancellation, console state, callbacks, output
streams, `ShouldProcess` boundaries, cleanup, authentication failures and generated
content. Explicitly distinguish per-helper mutation guards from a full-wizard
dry run, which is not currently supported.

### Phase 4: User-consumed YAML and configuration

Review groups D and E against their production consumers. Check GitHub and Azure
DevOps variants together, including source templates and setup-generated variants.
Comment each format's actual contract without implying identical provider behavior.
Explain hook context, paths, ordering and failure propagation.

### Phase 5: Maintainer automation and validation infrastructure

Review group F: release placeholder substitution and shared-library embedding;
dependency update behavior and permissions; cleanup and stable-release workflows;
documentation/link validation; coverage comparison; pinned tools and exact
analyzer exceptions; Azure Pipelines diagnostic allowlisting.

Keep machine-sensitive literals and exception-match source expressions untouched.
Explain narrow exceptions without claiming broader safety guarantees.

### Phase 6: Tests and supporting documentation

Review every group G file, including test-only helper functions and embedded
fixtures. Check that test names plus selective comments explain unusual contracts,
failure simulations, environment restoration and concurrency behavior.

Update the existing [development guide](../docs/development/powershell.md) with
the approved commenting standard and add a concise pointer in
[repository instructions](../.github/copilot-instructions.md).
Reconcile relevant content in [maintainer guidance](../docs/maintainers.md),
[configuration documentation](../docs/config),
[setup documentation](../docs/setup), [usage documentation](../docs/usage),
the [main README](../README.md) and
[automation README](../.github/scripts/README.md).
Review all tracked Markdown code examples; update only those affected by clarified
contracts. Avoid a second competing API reference.

### Phase 7: Whole-repository reconciliation and sign-off

Re-enumerate the tracked tree and symbols, resolve additions/renames, and close
every outstanding ledger unit. Review cross-file contracts for contradictory
terminology or assumptions. Validate the final combined tree, not only individual
patches. Publish a completion summary with all exceptions and validation evidence.

### Batching and dependencies

- Use approximately 5-10 substantive functions or one tightly coupled small file
  set per review batch. Reduce the batch for dense provisioning/concurrency code;
  do not enlarge it merely to reduce the number of PRs.
- Phases 1-6 follow calibration. Provider and template commentary depends on
  establishing the relevant shared contracts. Final sign-off depends on every
  group and documentation reconciliation being complete.
- Each PR identifies exact reviewed units, decisions not to comment, unresolved
  questions and validation results. Use the repository's `End-user changes`,
  `Implementation details` and `Validation` sections where applicable.
- Do not mark a whole large setup file complete after reviewing a small portion.
  Avoid a single enormous comment-only PR.
- Estimate delivery after calibration measures time for research, writing, review
  and validation. Do not promise a schedule based on lines or comment counts.

## 6. Complete baseline file checklist

All entries below have completed manual assessment. The
[review ledger](../docs/development/commenting-review.md) records the applicable
symbol/block outcomes, including intentional no-comment-needed decisions.

### A. Pipeline runtime: 10 files

- [x] [build.ps1](../pipelines/scripts/build.ps1)
- [x] [common.ps1](../pipelines/scripts/common.ps1)
- [x] [connect.ps1](../pipelines/scripts/connect.ps1)
- [x] [deploy.ps1](../pipelines/scripts/deploy.ps1)
- [x] [export.ps1](../pipelines/scripts/export.ps1)
- [x] [import.ps1](../pipelines/scripts/import.ps1)
- [x] [installdependencies.ps1](../pipelines/scripts/installdependencies.ps1)
- [x] [parallel-export.ps1](../pipelines/scripts/parallel-export.ps1)
- [x] [resolvebuildvalidationbaseline.ps1](../pipelines/scripts/resolvebuildvalidationbaseline.ps1)
- [x] [resolvedependencycache.ps1](../pipelines/scripts/resolvedependencycache.ps1)

### B. GitHub actions and resolution: 8 files

- [x] [build action](../.github/actions/build/action.yml)
- [x] [deploy action](../.github/actions/deploy/action.yml)
- [x] [export action](../.github/actions/export/action.yml)
- [x] [import action](../.github/actions/import/action.yml)
- [x] [deploy-build-validation.ps1](../.github/actions/common/deploy-build-validation.ps1)
- [x] [resolve-deployment.ps1](../.github/actions/common/resolve-deployment.ps1)
- [x] [resolve-prefixed-env.ps1](../.github/actions/common/resolve-prefixed-env.ps1)
- [x] [validate-auth.ps1](../.github/actions/common/validate-auth.ps1)

### C. Setup: 3 files, subdivided into function-family batches

- [x] [setup-common.ps1](../setup-common.ps1)
- [x] [setup-azdo.ps1](../setup-azdo.ps1)
- [x] [setup-github.ps1](../setup-github.ps1)

### D. Pipeline templates and distributed workflows: 13 files

- [x] [build template](../pipelines/templates/build.yml)
- [x] [export template](../pipelines/templates/export.yml)
- [x] [import template](../pipelines/templates/import.yml)
- [x] [deployment stage](../pipelines/templates/stages/deploy-environment.yml)
- [x] [GitHub BUILD example](../copy-to-your-repo/.github/workflows/BUILD.yml)
- [x] [GitHub CLEANUP-RELEASES example](../copy-to-your-repo/.github/workflows/CLEANUP-RELEASES.yml)
- [x] [GitHub DEPLOY-main example](../copy-to-your-repo/.github/workflows/DEPLOY-main.yml)
- [x] [GitHub EXPORT example](../copy-to-your-repo/.github/workflows/EXPORT.yml)
- [x] [GitHub IMPORT example](../copy-to-your-repo/.github/workflows/IMPORT.yml)
- [x] [Azure DevOps BUILD example](../copy-to-your-repo/pipelines/BUILD.yml)
- [x] [Azure DevOps DEPLOY-main scaffold](../copy-to-your-repo/pipelines/DEPLOY-main.yml)
- [x] [Azure DevOps EXPORT example](../copy-to-your-repo/pipelines/EXPORT.yml)
- [x] [Azure DevOps IMPORT example](../copy-to-your-repo/pipelines/IMPORT.yml)

### E. Configuration and data hooks: 4 files

- [x] [alm-config-defaults.psd1](../alm-config-defaults.psd1)
- [x] [distributed alm-config.psd1](../copy-to-your-repo/alm-config.psd1)
- [x] [system export hook](../copy-to-your-repo/data/system/export.ps1)
- [x] [system import hook](../copy-to-your-repo/data/system/import.ps1)

### F. Release, automation and validation: 13 files

- [x] [prepare-release.ps1](../prepare-release.ps1)
- [x] [check-outdated-dependencies.ps1](../.github/scripts/check-outdated-dependencies.ps1)
- [x] [test-dependency-workflow.ps1](../.github/scripts/test-dependency-workflow.ps1)
- [x] [test-documentation.ps1](../.github/scripts/test-documentation.ps1)
- [x] [update-dependency-prs.ps1](../.github/scripts/update-dependency-prs.ps1)
- [x] [cleanup-releases workflow](../.github/workflows/cleanup-releases.yml)
- [x] [stable-release workflow](../.github/workflows/stable-release.yml)
- [x] [update-dependencies workflow](../.github/workflows/update-dependencies.yml)
- [x] [validation workflow](../.github/workflows/validation.yml)
- [x] [Test-PowerShell.ps1](../scripts/Test-PowerShell.ps1)
- [x] [coverage.ps1](../scripts/coverage.ps1)
- [x] [powershell-validation.psd1](../scripts/powershell-validation.psd1)
- [x] [validate-azure-pipelines.js](../scripts/validate-azure-pipelines.js)

### G. Tests and test infrastructure: 25 files

- [x] [BuildBaseline.Tests.ps1](../tests/BuildBaseline.Tests.ps1)
- [x] [Coverage.Tests.ps1](../tests/Coverage.Tests.ps1)
- [x] [DependencyCache.Tests.ps1](../tests/DependencyCache.Tests.ps1)
- [x] [DependencyUpdates.Tests.ps1](../tests/DependencyUpdates.Tests.ps1)
- [x] [Documentation.Tests.ps1](../tests/Documentation.Tests.ps1)
- [x] [GitHubBuildBaseline.Tests.ps1](../tests/GitHubBuildBaseline.Tests.ps1)
- [x] [GitHubDeployment.Tests.ps1](../tests/GitHubDeployment.Tests.ps1)
- [x] [GitHubEnvironment.Tests.ps1](../tests/GitHubEnvironment.Tests.ps1)
- [x] [ParallelExport.Tests.ps1](../tests/ParallelExport.Tests.ps1)
- [x] [PipelineBuild.Tests.ps1](../tests/PipelineBuild.Tests.ps1)
- [x] [PipelineCommon.Tests.ps1](../tests/PipelineCommon.Tests.ps1)
- [x] [PipelineConnection.Tests.ps1](../tests/PipelineConnection.Tests.ps1)
- [x] [PipelineDependencies.Tests.ps1](../tests/PipelineDependencies.Tests.ps1)
- [x] [PipelineDeployment.Tests.ps1](../tests/PipelineDeployment.Tests.ps1)
- [x] [PipelineExport.Tests.ps1](../tests/PipelineExport.Tests.ps1)
- [x] [PipelineYaml.Tests.ps1](../tests/PipelineYaml.Tests.ps1)
- [x] [Release.Tests.ps1](../tests/Release.Tests.ps1)
- [x] [SetupCommon.Tests.ps1](../tests/SetupCommon.Tests.ps1)
- [x] [SetupEnvironment.Tests.ps1](../tests/SetupEnvironment.Tests.ps1)
- [x] [SetupProviders.Tests.ps1](../tests/SetupProviders.Tests.ps1)
- [x] [SetupRepository.Tests.ps1](../tests/SetupRepository.Tests.ps1)
- [x] [SetupWizard.Tests.ps1](../tests/SetupWizard.Tests.ps1)
- [x] [SolutionVersionReservation.Tests.ps1](../tests/SolutionVersionReservation.Tests.ps1)
- [x] [Validation.Tests.ps1](../tests/Validation.Tests.ps1)
- [x] [Invoke-SetupTests.ps1](../tests/helpers/Invoke-SetupTests.ps1)

## 7. Verification matrix

| Criterion | Scenario/check | Expected evidence |
|---|---|---|
| Complete scope | Reconcile tracked source files and symbol/block ledger with the final tree. | All 76 baseline files accounted for, additions included, no unexplained omissions or pending units. |
| Manual authorship | Review each bounded prose patch and its ledger evidence. | Individually composed, context-specific comments; no generation/insertion scripts or boilerplate batches. |
| Accurate help | Inspect help attachment and use `Get-Help` for changed callable/script help in an isolated, non-executing context. | Parameters, outputs, examples and notes attach to the intended command and match implementation. Do not run setup scripts merely to load help. |
| Useful comments | Reviewer checks each addition and each no-comment-needed decision. | Comments explain contracts or non-obvious reasons; readable statements remain unannotated. |
| No behavior change | Inspect comment/documentation diff and compare executable tokens/structure where applicable. | No command, parameter, config value, YAML scalar, emitted file, literal or control-flow changes. Parsing alone is not proof of equivalence. |
| Embedded/generation safety | Inspect source and regenerated output; run release and provider-generation tests. | Here-string boundaries, indentation, placeholders, generated workflows and installer syntax remain correct. Compare emitted content, allowing only intended comment differences. |
| PowerShell regressions | Run related Pester suites while iterating, then `.\scripts\Test-PowerShell.ps1` for the combined tree. | Analyzer and Pester pass; existing 65% per-changed-file command-coverage gate passes without exclusions or threshold changes. |
| Provider/schema regressions | Run existing actionlint and Azure Pipelines schema validation through repository CI, including setup-generated variants. | Existing Windows/Linux checks pass; Windows PowerShell 5.1 parses generated installers. No claim of full 5.1 runtime certification. |
| JavaScript regressions | Parse-check changed JavaScript and run its existing pipeline/YAML test coverage. | No syntax or diagnostic-filtering regressions; existing schema-validation job passes. |
| Documentation consistency | Run the existing documentation checker, explicitly including this plan while it remains in `temp`. | Local links and fenced examples pass; existing config/action/template reference coverage remains intact. |
| External effects | Use mocked/isolated existing tests, never live setup/deploy as comment verification. | No provisioning, secret disclosure, pushes or deployment needed for this work. |

Focused PowerShell test example, using the repository's pinned tool version:

```powershell
$policy = Import-PowerShellDataFile .\scripts\powershell-validation.psd1
Import-Module Pester -RequiredVersion $policy.Tools.Pester
Invoke-Pester -Path .\tests\PipelineBuild.Tests.ps1, .\tests\PipelineCommon.Tests.ps1 -Output Detailed
```

Use the relevant suites documented in the development guide for each batch.
For setup work, use the existing isolated runner:

```powershell
pwsh -NoProfile -File .\tests\helpers\Invoke-SetupTests.ps1
```

Required final checks include:

```powershell
.\scripts\Test-PowerShell.ps1
.\.github\scripts\test-documentation.ps1
.\.github\scripts\test-documentation.ps1 -Paths .\temp\manual-commenting-plan.md -SkipCoverage
node --check .\scripts\validate-azure-pipelines.js
```

The documentation checker imports the pinned `powershell-yaml` module through its
normal validation environment; use the policy version for standalone runs too.
Existing CI supplies actionlint and the Azure language-service/schema dependencies.
Use those existing checks rather than introducing another validation toolchain.

## 8. Risks and mitigations

- **Comment drift:** document stable contracts and invariants near their owner;
  require associated comments to be reviewed when behavior later changes.
- **Misleading certainty:** cite code/tests in the ledger; escalate unknown intent
  rather than asserting an invented reason.
- **Behavior changes disguised as comments:** preserve literals and executable
  tokens, especially here-strings, backtick continuations, YAML blocks and emitted
  source. Inspect generated output, not just outer-script parsing.
- **Help attachment effects:** keep help in valid positions; verify discovery and
  required directives without executing provisioning entry points.
- **Huge reviews:** split setup by function family and close units incrementally.
- **Existing failing checks or coverage gaps:** record baseline failures and report
  separately. Do not weaken gates or expand into unrelated fixes without approval.
- **Secrets and external systems:** use sanitized examples and existing isolated
  tests. No live environment access is required for this repository-only task.
- **Inventory drift:** reconcile again at completion. Snapshot counts are a
  baseline, not a substitute for checking the final tree.

## 9. Definition of done

1. Every first-party source/configuration file and applicable embedded program is
   accounted for, with every function, entry point and complex block assessed.
2. All externally consumed contracts and all non-obvious decisions have accurate,
   useful documentation; simpler code has reasoned no-comment-needed decisions.
3. Existing misleading comments are resolved and related documentation agrees.
4. Each comment was individually authored and reviewed; no bulk prose-generation
   or insertion mechanism was used.
5. No runtime behavior, user configuration, generated executable content, test
   assertions, analyzer policy or coverage threshold changed.
6. Required targeted and final checks pass, with human review evidence attached.
   Any unresolved blocker prevents an unqualified claim of full completion.

## 10. Assumptions, approval and overrides

- The initial request was plan-only. The subsequent instruction, "Implement fully.
  Don't stop until every task is completed and you've pushed a PR", authorizes
  implementation and publication.
- "Hand written" means individually authored in context, not script-generated;
  it does not imply that assistant-authored comments were typed by a human.
- Full coverage is complete assessment and resolved documentation needs, not a
  compulsory comment on every line or every trivial private function.
- Existing code behavior is the source of truth. No Dataverse schema changes or
  environment metadata writes are proposed, so schema substitutions do not apply.
- A human reviewer is needed for calibration and final prose sign-off.

Approval checkpoint: satisfied by the subsequent full-implementation instruction.
The bounded manual standard still applies; no additional calibration-only stop is
required. The implementation record is maintained in
[the review ledger](../docs/development/commenting-review.md).

User-approved overrides: proceed through all phases and publish a PR without
intermediate approval stops. Assistant authorship/review is recorded explicitly;
human sign-off is left to the normal maintainer PR review, not claimed by the agent.
The completed, separately assessed component blocks are published in one integrated
PR to deliver the requested full-repository result, rather than stopping after
individual calibration or partial-coverage PRs.
