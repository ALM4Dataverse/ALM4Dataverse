# Manual commenting review record

Baseline: `1b29582`, 16 October 2026. Scope and acceptance criteria are in the
[approved plan](../../temp/manual-commenting-plan.md); ongoing guidance is the
[commenting standard](powershell.md#commenting-standard).

Before publication, main advanced to `4aa15e7` (inline mappings and build commands).
The branch integrates that commit without replacing its executable behavior.
The affected runtime, shared-setup, test and configuration contracts were manually
reassessed; the final inventory is 76 files and 312 production functions. Initial
validation below is retained as history and is superseded by final integration
evidence where indicated.

The user approved full implementation, including publication of a PR, after
reviewing the plan. The proposed calibration-only stop was superseded by that
instruction. This record describes assistant-authored, individually composed
comments and assistant review; it does not assert human authorship or human
sign-off. Maintainer review remains part of the normal PR process.

## Reading this record

- **Documented**: individually added or corrected contract/rationale comments.
- **Verified**: existing explanations or descriptive names already communicate the
  contract; no additional comment was useful.
- **No comment needed**: intentionally unannotated simple code, with its reason.
- A file-level entry covers its entry point, top-level orchestration, embedded
  blocks and configuration. Named helpers have additional entries below or in the
  corresponding implementation review sections.
- Counts are an inventory baseline, not a comment-density metric. Blank lines,
  assertions and trivial statements are not documentation targets.

## Automation, templates and distributed examples

All files below were read against their consumers/references before commentary
was written. Executable expressions, configuration values, fixture strings and
assertions are preserved.

| File | Decision and assessed contracts |
| --- | --- |
| [defaults](../../alm-config-defaults.psd1) | Documented merge ownership, export operation budget and independent build-stage/checker concurrency; reconciled the 3.2.0 upstream dependency default and build-command stage. |
| [consumer configuration](../../copy-to-your-repo/alm-config.psd1) | Documented package counts, export/build-stage limits, missing/false behavior and independent checker limit; verified solution order, hook contexts, paths, dependency versions and baseline examples. Reassessed upstream inline mapping/build-command examples and their ordered, stage-specific execution contract. |
| [export hook](../../copy-to-your-repo/data/system/export.ps1) | Documented disabled example, supplied context/connection and packaged data ownership; sample remains inactive. |
| [import hook](../../copy-to-your-repo/data/system/import.ps1) | Documented disabled example, upsert-before-delete order and caller connection; sample remains inactive. |
| [build template](../../pipelines/templates/build.yml) | Documented optional validation connection, fixed checkout paths, compile-time provider selection/runtime macro distinction, baseline download condition, failure diagnostics and immutable version tags. Assessed both embedded `Resolve-ConnectionVariable` helpers: first expanded candidate or null, then caller validation. |
| [export template](../../pipelines/templates/export.yml) | Documented branch mutation, persisted Git credentials, credential candidate/sentinel contract and detached-checkout push/commit exit policy. Embedded resolver has the same first-usable-or-null contract, explained locally. |
| [import template](../../pipelines/templates/import.yml) | Documented fresh unmanaged build/import and embedded resolver's handling of unexpanded task outputs. |
| [deployment stage](../../pipelines/templates/stages/deploy-environment.yml) | Documented sanitized stage versus original environment identity, artifact-bundled scripts, embedded credential resolver, success-only pointer updates and metadata/legacy tag fallback. `ConvertTo-TagSegment` is documented as legacy sanitization, not SemVer validation. |
| [GitHub BUILD](../../copy-to-your-repo/.github/workflows/BUILD.yml) | Corrected summary; documented dispatch branch/SHA ownership and release/dispatch/OIDC permission reasons. Existing secret/environment guidance verified. |
| [GitHub DEPLOY](../../copy-to-your-repo/.github/workflows/DEPLOY-main.yml) | Documented destination concurrency and targeted replay versus prior-environment promotion checks; verified automatic/manual stage conditions and promotion-mode instructions. |
| [GitHub EXPORT](../../copy-to-your-repo/.github/workflows/EXPORT.yml) | Documented shared destination lock with IMPORT; existing branch environment, nondeployment context and explicit secret transport comments verified. |
| [GitHub IMPORT](../../copy-to-your-repo/.github/workflows/IMPORT.yml) | Documented environment credential scope without deployment recording and shared non-cancelling Dev lock. |
| [GitHub cleanup caller](../../copy-to-your-repo/.github/workflows/CLEANUP-RELEASES.yml) | Corrected cap description to preserve active baselines; documented default inputs for nonmanual events. |
| [Azure BUILD caller](../../copy-to-your-repo/pipelines/BUILD.yml) | Documented required repository alias and optional validation environment, not just a build label. |
| [Azure deployment scaffold](../../copy-to-your-repo/pipelines/DEPLOY-main.yml) | Documented intentionally empty stages and selected BUILD artifact ownership; no live target added. |
| [Azure EXPORT caller](../../copy-to-your-repo/pipelines/EXPORT.yml) | Documented branch-name variable group/service connection convention, including short-name semantics. |
| [Azure IMPORT caller](../../copy-to-your-repo/pipelines/IMPORT.yml) | Documented branch-specific settings, service connection and newly built unmanaged packages. |
| [dependency discovery](../../.github/scripts/check-outdated-dependencies.ps1) | Documented repository-root/GitHub output prerequisites, JSON/output effects, numeric version comparison and warning/skip behavior for failed lookups. |
| [dependency smoke check](../../.github/scripts/test-dependency-workflow.ps1) | Documented isolated local convention checks, not production execution, and restored/deleted temporary working directory. |
| [dependency PR updater](../../.github/scripts/update-dependency-prs.ps1) | Documented disposable checkout, branch/identity/remote effects, aggregate failures, module-prefix PR reuse and stale-old-version match. Verified rebase/lease explanations. Embedded PR-body Markdown left unchanged. |
| [documentation checker](../../.github/scripts/test-documentation.ps1) | Documented default/explicit scope, SkipCoverage boundary, parse-not-execute examples, no external fetch, aggregate errors and presence-only reference checks. `Get-HeadingId`: documented renderer-derived cached anchors; URL decoding/order explained locally. |
| [release preparation](../../prepare-release.ps1) | Verified existing script help; documented shared-library text embedding and `Invoke-ProcessSetupScript` scope inputs, writes, process-exit failures and required-placeholder checks. Removed obvious assignment/directory narration. |
| [PowerShell validator](../../scripts/Test-PowerShell.ps1) | Documented comparison parameters, source scope, pinned imports, analyzer-before-tests and saved failure reports. Explained source-bound exact exceptions and diagnostic all-file versus enforced changed-file coverage. |
| [coverage helpers](../../scripts/coverage.ps1) | Documented `Get-ModifiedPowerShellFile` committed/working-tree modes, zero-base behavior, normalized existing non-test paths and Git failures; documented `Get-PowerShellFileCoverage` absolute-path matching, returned fields, no-command status and unrounded inclusive threshold. |
| [validation policy](../../scripts/powershell-validation.psd1) | Documented exact pinned imports and one-match exception identity; all exception reasons, values and source expressions retained. |
| [Azure schema validator](../../scripts/validate-azure-pipelines.js) | Documented pinned external dependency ownership, exact-text position adapter and task-scoped diagnostic filtering. `findTaskForLine` and `isKnownExtensionDiagnostic` have local rationale. `getLine`: no comment needed, direct offset-to-line expression. `main`: orchestration/adapter and existing CLI errors communicate inputs/output; no duplicative function banner. |
| [cleanup workflow](../../.github/workflows/cleanup-releases.yml) | Documented `getBuildMetadata` ownership/completeness, `ensureMetadataTag` predeletion durability, `branchExists` 404-only absence, `getActiveDeploymentReleaseTags` annotated-pointer contract and post-cutoff baseline protection. `getReleaseBranch`: no comment needed, direct nullable metadata projection. Pagination, sorting and logged deletion results are self-explanatory. |
| [stable release workflow](../../.github/workflows/stable-release.yml) | Documented lack of validation dependency, moving stable pointer, optional generated notes, existing broad create/update retry and best-effort asset cleanup limitations. Shell release-note payload and uploaded content unchanged. |
| [dependency workflow](../../.github/workflows/update-dependencies.yml) | Documented GITHUB_TOKEN PR-validation trigger limitation; existing schedule, module setup and conditional updater are explicit. |
| [validation workflow](../../.github/workflows/validation.yml) | Documented platform responsibilities and always-run stable required-check aggregation, without claiming ruleset configuration or full 5.1 runtime support. |

### Related documentation

The development guide now owns the standard, with pointers from repository
instructions and the maintainer guide. Existing configuration, setup, usage and
README contracts remain applicable: this work changes no user behavior or option.
The documentation checker validates their examples, local links and reference
coverage; it is not a semantic proof of live integration behavior.

## Final integration validation evidence

Publication baseline: `4aa15e7161b1e8ac9884e3b3c4ce621debe5f5fd`.

- Re-ran `scripts\Test-PowerShell.ps1 -BaseRef origin/main` with that exact
  upstream base: **544 passed, 0 failed**, eight existing non-applicable
  provider-matrix instances skipped. All 54 PowerShell files parsed/analyzed;
  the same 27 exact analyzer exceptions remain.
- All 26 changed source-script entries passed the existing coverage gate,
  including the two no-command hooks. Minimum executable-file coverage remained
  **65.4197601370645%**; the threshold is unchanged at 65%.
- Final inventory reconciliation passed for **76 code/configuration files,
  312 production functions and 63 outer test helper definitions**. Embedded
  definitions and complex blocks have explicit decisions in the relevant sections.
- All **73 modified code/configuration files** preserve the current upstream's
  executable PowerShell token streams, literal/here-string payloads, parsed YAML
  values except embedded comment-only lines, and non-comment JavaScript lines.
  PowerShell BOM presence and valid help attachment were checked again.
- Pinned actionlint and Azure schema checks passed again; all seven non-scaffold
  Azure pipeline files validated. Both newly generated standalone installers,
  now embedding the upstream 3.2.0 dependency version, parsed in PowerShell 5.1.
- Final Markdown check: **27 files, 390 local links, 50 parsed examples**, plus
  configuration/action/template reference coverage. JavaScript syntax and
  staged/unstaged whitespace checks passed.
- Focused upstream-integration checks: **99 runtime tests** and **six shared
  setup preservation/WhatIf tests** passed, with no failures.

The three upstream merge conflicts were resolved manually, preserving the new
inline-mapping/build-command behavior rather than reverting it to the initial
baseline. No validation gates, assertions or skip conditions were changed.
The following initial-baseline evidence is historical, not the final test count.

## Initial combined validation evidence

- Full `scripts\Test-PowerShell.ps1`: 54 PowerShell files parsed/analyzed with the
  existing 27 exact analyzer exceptions; 525 tests passed, no failures, eight
  non-applicable provider-matrix instances skipped by existing conditions.
  No tests, skip conditions or thresholds changed.
- All changed executable PowerShell files passed the 65% whole-file command
  coverage gate. The minimum was 65.4197601370645%; no-command example hooks were
  correctly reported as not applicable.
- Focused support suites: 48 tests passed with no skips or failures.
- Pinned actionlint 1.7.12 passed all checked-in GitHub workflows; the existing
  Azure validator with language service 0.9.2 and the CI-pinned Microsoft schema
  passed all seven checked-in non-scaffold pipeline files.
- Both generated standalone setup installers parsed in Windows PowerShell 5.1.
  This is syntax evidence, not a claim of full interactive runtime compatibility.
- PowerShell help was inspected through the AST without executing provisioning
  entry points. Attached synopsis blocks were discovered without empty summaries.
- A read-only comparison against `1b29582` confirmed identical executable
  PowerShell token kind/text streams, preserving here-string payloads. Parsed YAML
  values matched except authored comment-only lines in embedded scripts; JavaScript
  non-comment lines matched. BOM/newline representation was normalized for the
  comparison, not rewritten in source.
- PowerShell BOM presence was preserved for every changed script/data file,
  including sources consumed by Windows PowerShell.
- Final reconciliation passed for all 76 tracked code/configuration files, all
  308 production function definitions and all 62 outer test helper definitions.
  The test assessment additionally accounts for embedded definitions (72 total).
  Every baseline checklist entry is closed; no integration placeholders remain.
- Final documentation validation passed for 27 Markdown files, 385 local links
  and 49 parsed examples, plus configuration/action/template reference coverage.
- `node --check scripts\validate-azure-pipelines.js` and `git diff --check` passed.

Runtime tests use the repository's existing mocks/isolated fixtures: no live
Dataverse provisioning, deployment, or release publication was performed.

## Pipeline runtime and action review

### Runtime/action manual commenting ledger (groups A and B)

Initial baseline: `1b29582` (`HEAD` when assessed), 16 October 2026.
The later upstream integration assessment below uses `4aa15e7` (`origin/main`),
including #97's inline mappings and mapping build commands, as its executable baseline.
Scope: exactly ten `pipelines\scripts\*.ps1`, four
`.github\actions\common\*.ps1` and four composite `action.yml` files.
Author/assessment: Copilot; no human or independent review is claimed.
Each decision below follows reading the implementation, including nested bodies.
Prose was individually composed and applied with `apply_patch`; automation was
restricted to read-only inventories, diffs and validation. No executable repair,
configuration-value change, commit or push is part of this assignment.

#### Evidence and validation key

Paths in evidence shorthand are relative to the repository root.

- **C**: [tests\PipelineCommon.Tests.ps1](../../tests/PipelineCommon.Tests.ps1); common helpers' build/export/deploy callers.
- **B**: [tests\PipelineBuild.Tests.ps1](../../tests/PipelineBuild.Tests.ps1); `import.ps1` and build action call sites.
- **X**: [tests\PipelineExport.Tests.ps1](../../tests/PipelineExport.Tests.ps1), [tests\ParallelExport.Tests.ps1](../../tests/ParallelExport.Tests.ps1);
  export action and [pipelines\templates\export.yml](../../pipelines/templates/export.yml) call sites.
- **V**: [tests\SolutionVersionReservation.Tests.ps1](../../tests/SolutionVersionReservation.Tests.ps1); `export.ps1` version branch.
- **D**: [tests\PipelineDeployment.Tests.ps1](../../tests/PipelineDeployment.Tests.ps1); import, validation and deploy action calls.
- **I**: [tests\PipelineDependencies.Tests.ps1](../../tests/PipelineDependencies.Tests.ps1), [tests\DependencyCache.Tests.ps1](../../tests/DependencyCache.Tests.ps1);
  installer/build lock producer and all four action cache/install steps.
- **A**: [tests\PipelineConnection.Tests.ps1](../../tests/PipelineConnection.Tests.ps1), [tests\GitHubEnvironment.Tests.ps1](../../tests/GitHubEnvironment.Tests.ps1);
  common authentication and all action login/mapping/validation steps.
- **Z**: [tests\BuildBaseline.Tests.ps1](../../tests/BuildBaseline.Tests.ps1);
  [pipelines\templates\build.yml](../../pipelines/templates/build.yml) baseline selection/download call sites.
- **G**: [tests\GitHubDeployment.Tests.ps1](../../tests/GitHubDeployment.Tests.ps1); deploy action resolver/gate/tag consumers.
- **R**: [tests\GitHubBuildBaseline.Tests.ps1](../../tests/GitHubBuildBaseline.Tests.ps1); build action validation caller;
  build Release producer, metadata formats and deployment pointer producer.
- **Y**: [tests\PipelineYaml.Tests.ps1](../../tests/PipelineYaml.Tests.ps1); distributed
  `copy-to-your-repo\.github\workflows\{BUILD,DEPLOY-main,EXPORT,IMPORT}.yml`
  action calls, selected-input environment expressions and permission declarations.

All entries also use the complete enclosing production implementation as evidence.
Initial validation shared across entries: 14 PowerShell files parse and their 17,101
non-comment/non-newline tokens match `1b29582` after CRLF normalization; all four action
YAML documents parse with byte-equivalent JSON representations of their parsed
values, including every embedded script/default scalar. `git diff --check` passes
for the assigned paths. PSScriptAnalyzer 1.24.0 with repository settings has unchanged
findings: two in build.ps1 and none in the other 13 scripts. Those two pre-existing
findings remain subject to existing repository exceptions, not new suppressions.
Focused Pester execution and final limitations are recorded at the end.

#### A1. `pipelines\scripts\common.ps1`

| Symbol/block | Decision | Concrete reason / evidence |
|---|---|---|
| Script/library help and dot-source entry | existing comments verified | Correctly identifies shared pipeline function definitions; loading does not itself connect or run a pipeline. C. |
| `Get-SolutionPackagerMappingEntry` | documented | Normalized ordered output, rejected obsolete keys, strict mapping/command key schema and original BuildCommand reference are distinct from later command-value validation. Read build/export mapping consumers and B's removed-key, invalid-type and malformed-command fixtures added by #97. |
| Mapping type switch / key validation / entry construction | no comment needed | Explicit cases, allowed-key lists and returned property names completely expose the schema; enclosing helper help explains normalization and deferred validation. B, X upstream mapping callers. |
| `ConvertTo-SolutionPackagerMappingXml` | documented | Destination becomes map and Source becomes to; relative roots, ordered XML escaping, optional source-existence checks and no command execution are caller contracts. B covers all mapping types, ordering, ampersands and missing sources; X's first-export caller uses AllowMissingSource. |
| Mapping XML placeholder branch | documented | Percent placeholders must reach SolutionPackager unchanged rather than being prematurely resolved or checked; build/export consume the returned XML with different existence-check policies. B, X. |
| Mapping XML DOM construction / ordinary destination join | no comment needed | Explicit attribute assignments and DOM operations implement the documented direction/escaping without hidden writes; rooted and placeholder exclusions are visible conditions. B's XML assertions. |
| `Invoke-CheckedNativeCommand` | documented | Captured stderr, string outputs, nonzero-exit policy, AllowFailure and preference restoration are material to native callers. C. |
| `Merge-AlmConfigValue` | documented | Null fallback, recursive table merge, array concatenation and explicit false/zero differ from truthy defaulting. C. |
| `Get-AlmConfig` | documented | Required config path, retained `_main`/`_defaults`, full-config logging and lack of path rebasing matter to installer/hooks. C, I. |
| Config load/merge/preserve-default loops | existing comments verified | Existing comments agree with key-wise recursive merge and retention of missing top-level defaults; no new narration needed. C. |
| `Resolve-AlmBranchBaseVersion` | documented | Case-sensitive full branch overrides and MAJOR.MINOR-to-Major.Build mapping are not apparent from ordinary SemVer conventions. C, V. |
| `Invoke-AlmGitCommand` | documented | ExitCode/combined Output object intentionally does not throw for failed Git status; callers inspect collisions. V. |
| `Resolve-AlmDefaultBranchName` | documented | Explicit branch wins; live origin HEAD lookup rather than local symbolic ref can fail. V, X. |
| `Get-NextAlmSolutionVersion` | documented | Additive Revision versus destructive Minor/reset policy preserves branch Major.Build; overflow throws. V, X. |
| `Register-AlmSolutionVersion` | documented | Remote lightweight-tag reservation mutates local/remote Git, retries collisions, retains successful tags and is not transactional with Dataverse. V, X. |
| Reservation rejected-push cleanup/recheck | documented | Rejected push is retried only if remote ownership now proves a collision; local-only collisions and transport errors must not be hidden. V. |
| `Resolve-AlmBuildVersion` | documented | Numeric PATCH, sanitized prerelease branch, retained original identity and provider metadata are distinct output contracts. C, Y. |
| Numeric branch identifier prefix | no comment needed | Explicit regex/prefix directly enforces non-leading-zero SemVer identifiers; function contract explains normalization and tests cover `01`. C. |
| `Write-AlmBuildVersionInfo` | documented | Existing-directory requirement, full SHA normalization, numeric run ID, overwrite and returned path are externally visible. C, B, Y. |
| `Initialize-PacAuthentication` | documented | Existing Azure context prerequisite, create/select fallback, identity check and Quiet scope are not ordinary Dataverse connection setup. C, A. |
| `Invoke-Hook` | documented | Ordered hooks, current-location relative paths, output/error propagation, shared config and AdditionalContext precedence require an explicit contract. C, X, D. |
| Hook context merge and `[alm]` substitution | documented | Replaced redundant context narration with shared-reference/overwrite rationale; verified existing absolute ALM-root substitution comment. C. |
| Hook invocation/finally and missing script branch | no comment needed | Contract now covers failure propagation and no rollback; local finally visibly closes log groups without additional prose. C. |

#### A2. `pipelines\scripts\build.ps1`

| Symbol/block | Decision | Concrete reason / evidence |
|---|---|---|
| Script entry/help, parameters, prerequisites and artifact contract | documented | Existing packing/assets/hooks description retained; added process dependencies, failure/report behavior, non-publication boundary and invocation. B, Y. |
| `Get-PacCliInstalledPackageVersion` | documented | Empty sentinel, tool-list source and removal of NuGet build metadata matter to exact dependency locking. B, I. |
| `Get-AlmBuildSetting` | documented | Boolean-only opt-out, null/empty defaults, integer 1-8 validation even when sequential are significant. B. |
| `Get-SolutionBuildCommandPlan` | documented | Required plan fields, argument/Boolean validation, default working directory, relative-path resolution without containment enforcement, output fields and contiguous parallel-flag groups require explicit contracts. B's default/opt-out, malformed arguments and real overlap-barrier tests; build orchestration consumer establishes cross-group ordering. |
| Command planner name fallback / plan property construction | no comment needed | Visible mapping-index fallback and named output fields implement the enclosing contract directly; omitted commands do not alter the flag grouping. B's command ordering fixtures. |
| `Invoke-SolutionBuildCommand` | documented | Captures output and invocation errors into result data, reads LASTEXITCODE with null treated as zero and restores location; entering the location can still throw and no rollback is promised. B's nonzero-exit-before-pack test and sequential command caller. |
| Build-command invocation result object | no comment needed | Four literal fields match the caller's log/error replay, and the function help already describes capture and failure boundaries. B. |
| `New-SolutionCheckSeverityCount` | no comment needed | A literal ordered zero-count dictionary exposes its full shape; adding help would restate five assignments. B. |
| `Convert-SolutionCheckSeverityToRank` | no comment needed | Explicit five-way mapping and unsupported-value exception are unambiguous; caller threshold use is documented. B. |
| `Convert-SolutionCheckRankToSeverity` | documented | Unknown rank returns None rather than matching the reverse conversion's throwing policy. B. |
| `Get-SolutionCheckHighestSeverity` | documented | Missing/zero counts produce None; callers must not interpret that sentinel as a severity. B. |
| `ConvertFrom-SolutionCheckSeverityText` | documented | Text-summary accumulation, unmatched zero categories and worker-parser synchronization are non-obvious. B. |
| `Resolve-SolutionCheckExcludedFile` | documented | Solution-relative/rooted paths, recursive wildcard resolution, deduplication and warn-not-fail missing patterns are significant. B. |
| `ConvertTo-SolutionCheckRuleOverrideFile` | documented | String pass-through without validation differs from JSON-writing structured values and blank sentinel. B. |
| `Write-SolutionCheckSummary` | documented | Required result fields, Error precedence, overwrite/append and provider-specific summary side effects are caller contracts. B. |
| `Invoke-SolutionCheck` | documented | Merge semantics, enabled planning, independent global throttle, thresholds, worker failures and reports-before-throw require context. B. |
| Enabled scan / per-solution plan / rule-set/exclusion coercion | no comment needed | Function contract plus explicit branches and validation messages expose defaults/type handling; Merge-AlmConfigValue is authoritative for merge details. B, C. |
| Checker parallel worker scope | documented | Isolated runspaces require local helpers; explicitly ties copies to outer parser/count/highest helpers. B. |
| `Invoke-SolutionCheck` worker `New-Count` | no comment needed | Same visible literal count shape as outer helper; runspace rationale documented on enclosing worker block. B. |
| `Invoke-SolutionCheck` worker `ConvertFrom-CountText` | documented | Enclosing worker comment establishes duplicated parser equivalence; outer parser comment gives summary-count contract. B. |
| `Invoke-SolutionCheck` worker `Get-Highest` | documented | Enclosing worker equivalence comment and outer highest helper establish None semantics without duplicated help. B. |
| Worker PAC capture/log/result/catch | documented | Aggregate-failure rationale explains converting errors to data so all solution reports survive. B. |
| Threshold evaluation, final report and thrown aggregate | documented | Report-before-failure policy added at function and result aggregation boundaries; actual inclusive comparison verified. B. |
| Duplicate solution names / preBuild / pack plans | no comment needed | Case-insensitive duplicate error and indexed plan construction are explicit; hook behavior is defined in common.ps1. Rechecked after #97 moved pack-plan construction after command execution; mapping-specific lifetimes are assessed separately below. B, C. |
| Pack command lookup before module selection | documented | Required autoload ordering before recording module path is tested explicitly. B. |
| Mapping validation / MappingFile capability guard | documented | Schema and cmdlet capability are checked before commands run, while source-existence checking waits for generated outputs. B's command-created source and unsupported-cmdlet tests. |
| Build-command group scheduler | documented | Consecutive flag groups preserve sequential barriers across solutions; global sequential mode overrides command opt-in. Read grouped scheduler and planner together; B's real overlap-barrier fixture proves within-group concurrency, and command opt-out fixtures cover sequential execution. |
| Parallel build-command worker body | documented | Isolated runspaces require a duplicate of Invoke-SolutionBuildCommand's capture, exit-code and location-restoration logic; maintainers must keep those paths aligned. B's parallel command failure and ordering coverage. |
| Build-command deterministic log replay / failure stop | no comment needed | Explicit indexed sort, grouped output and ErrorMessage throw show that the current group finishes before later groups can start; scheduler rationale states the ordering boundary. B. |
| Mapping XML generation / pack-plan MappingFile / finally cleanup | documented | XML is generated after build commands and source checks, retained until all pack workers finish, then deleted even on failure; it is scratch rather than a deployment asset. B's generated-source, mapped-pack and XML cleanup assertions. |
| Parallel packing import/capture/sort/replay | documented | Explains isolated module import and deterministic config-order grouped log replay despite worker completion order. B. |
| Sequential packing branch | no comment needed | Direct calls duplicate the same PackageType Both contract and visibly avoid parallel runspaces; no hidden fallback. B. |
| Asset and script/config copies | existing comments verified | Existing section comments match copied content and missing-asset failure; script help identifies artifact contents. B. |
| Dependency lock module/PAC resolution | documented | Pins actual loaded/installed versions rather than requested floating selectors; missing versions fail, not silently degrade. B, I. |
| postBuild call | no comment needed | Straight invocation using documented hook context, after lock creation; no unusual cleanup or state rule. C, B. |

#### A3-A6. Single-entry scripts

Reviewed files: [connect.ps1](../../pipelines/scripts/connect.ps1),
[deploy.ps1](../../pipelines/scripts/deploy.ps1),
[export.ps1](../../pipelines/scripts/export.ps1) and
[import.ps1](../../pipelines/scripts/import.ps1).

| File / symbol/block | Decision | Concrete reason / evidence |
|---|---|---|
| `connect.ps1` script help | documented | Corrected false connection-string synopsis; documented existing Azure context, PAC setup before default client, WhoAmI and invocation. A. |
| `connect.ps1` PAC/client/WhoAmI body | no comment needed | Straight three-stage sequence matches revised help; no retry or rollback claim. A. |
| `deploy.ps1` script help | documented | Corrected runtime environment prefixes; added dependency order, connection, service UPN, stages, non-transactionality and unmanaged switch dominance. D, Y. |
| `deploy.ps1` config/hooks/package/UPN plan | existing comments verified | Artifacts-root config and IMPORT unmanaged intent match callers; configured UPN key is optional and defaulted explicitly. D, C. |
| `deploy.ps1` connection/environment variable enumeration | existing comments verified | Existing literal-prefix comments reflect actual matching and Substring calls; executable behavior unchanged. D. |
| `deploy.ps1` staging modes / timeout / migrations | documented | Added holding-solution rationale and reverse dependency-removal ordering around migrations. Seconds/default remain unchanged. D. |
| `deploy.ps1` reverse upgrades / restore forward activation order | existing comments verified | Existing reverse-order comment agrees with both Reverse calls and unmanaged skip. D. |
| `deploy.ps1` service account resolution / workflow query | documented | Corrected owner-filter comment that wrongly read Activated; help explains required environment value and user lookup failure. D. |
| `deploy.ps1` deactivate/reassign/reactivate | documented | Ordering is material to changing process ownership and activation identity, not merely field assignment narration. D. |
| `deploy.ps1` final publish / postDeploy | existing comments verified | Existing publish comment and hook phase match calls; no rollback implied. D, C. |
| `import.ps1` script help | documented | Normal build/checker policy precedes forced unmanaged deployment, which still performs process/publish side effects. D, B. |
| `import.ps1` build step / deploy step and status checks | existing comments verified | Existing step comments match build then unmanaged deploy; false status and throws prevent reporting success. D. |
| `export.ps1` script help/parameters/output | documented | Corrected diagnostic versus package artifact destination; described supplied scratch path, branch policy, reservation side effects and PassThru shape. Updated for inline mapping direction, no build-command execution and expanded change detection in #97. X, V. |
| `export.ps1` default-branch warning / preExport | no comment needed | Explicit HasBranchOverride check and warning state policy clearly; hook contract is authoritative. X, C. |
| `export.ps1` mapping schema / AllowMissingSource / capability guards | documented | First export may create mapped sources; attached build commands are never run. Parallel workers only download, so mapped expansion stays on the main thread, while both export modes need mapped baseline compression. X's sequential mapping/no-command fixture and parallel expansion caller. |
| `export.ps1` queue startup / configured-order processing | documented | Scheduler contract explains overlap while main loop waits per solution; no claim of config-order worker completion. X. |
| `export.ps1` old package/remove/unpack and XML normalization | existing comments verified | Existing XML comment correctly explains matching serialization before Git status; old package is preserved for component comparison. Rechecked #97's common MappingFile for old/new compression and unpacking; new source-validation rationale is recorded separately. X. |
| `export.ps1` mapped old-baseline source validation | documented | Existing mapped sources are checked before removing the old solution directory, preventing destructive deletion on an invalid baseline. X's mapping-aware baseline fixtures; common XML helper contract. |
| `export.ps1` Git status / additive comparison | existing comments verified | Existing version-on-change comment agrees with no-update tests; new solution is explicitly additive without comparison baseline. X. |
| `export.ps1` mapped-source Git pathspec construction | documented | Changes outside the solution but inside the repository must trigger versioning; unresolved placeholders, outside-root paths and repository root itself are excluded to avoid unrelated bumps. X's external-to-solution source-change fixture and explicit path exclusion branches. |
| `export.ps1` Major.Build base reset/increment/reservation | documented | Branch base occupies nonadjacent version components; change counters reset before checked increment and reservation. X, V. |
| `export.ps1` environment version write semaphore | documented | Shares operation budget with background package exports, not merely other main-thread writes. X. |
| `export.ps1` postExport / cleanup / diagnostics finally | documented | Mapping XML is consumed only on the main thread and can be removed before stopping download workers; stop-before-summary permits teardown timings and prevents scratch writes after directory deletion. Summary labels are whole-run status. X's generated-mapping cleanup and resource teardown fixtures. |
| `export.ps1` final PassThru object | documented | Script help distinguishes optional successful return object and timings from host diagnostics. X. |

#### A7. `pipelines\scripts\installdependencies.ps1`

| Symbol/block | Decision | Concrete reason / evidence |
|---|---|---|
| Script help/entry | documented | Current-directory config/lock, CurrentUser installation, exact import, dotnet/PAC location, numeric minimum and CI PATH side effects are observable contracts. I. |
| Lock replacement and module selector branches | existing comments verified | Existing version-selector list matches latest stable, latest prerelease or exact install flags; lock replacement matches tests. I. |
| Minimum numeric module comparison | no comment needed | Explicit prerelease stripping and version comparison show numeric-only minimum; documented at script level. I. |
| Exact installed-manifest import block | existing comments verified | Existing comments correctly explain locating installed version explicitly with prerelease support rather than ambiguous module autoload. I. |
| `Get-PacCliInstalledPackageVersion` | documented | Listing source, empty sentinel and build metadata stripping match build.ps1's local helper and caller failure check. I, B. |
| `Resolve-PacCliVersionSpecifier` | documented | Distinguishes blank stable/latest, preview selector and exact NuGet syntax from ranges/wildcards/metadata. I. |
| PAC tool directory / install/update argument construction | no comment needed | Named CLI arguments visibly preserve exact selector for both operations; helper contract explains accepted syntax. I. |
| Existing PAC update/uninstall/reinstall | documented | Failed update must not leave stale tool selection; fallback reuses selector. I. |
| Process PATH / GITHUB_PATH / Azure prependpath | documented | Current process versus subsequent independent step environment lifetime is non-obvious. I, Y. |
| PAC executable/version postconditions | no comment needed | Explicit exceptions reject missing binary or unresolvable listing; help already states installation effects. I. |

#### A8. `pipelines\scripts\parallel-export.ps1`

| Symbol/block | Decision | Concrete reason / evidence |
|---|---|---|
| Library entry | documented | Dot-source does not launch workers; returned state owns resources needing finally cleanup. X. |
| `Get-AlmExportSetting` | documented | Separate package-worker and Dataverse-operation limits, validated integers 1-8, null/empty defaults, explicit false. X. |
| `Format-AlmLogLine` | documented | CI command must remain first on the line; context prefix placement is behavior-critical. X. |
| `Send-AlmExportEvent` | documented | Live shared queue/signal ordering permits progress without draining terminal output early. X. |
| `Expand-AlmExportSolution` | documented | Both-package unpack depends on managed companion adjacent to returned unmanaged path. Reconciled #97's optional MappingFile forwarding contract; blank values retain ordinary layout. X's optional-mapping forwarding assertion and export main-thread caller. |
| `Start-AlmExportPipeline` | documented | Mutable state ownership, borrowed connection, prerequisites, initialization-only behavior, duplicate failures and declined ShouldProcess return. X. |
| Original OrganizationDetail initialization before Clone | documented | Avoid independent refresh of incomplete metadata on worker clones; barrier fixture exercises warm details. X. |
| State allocation / per-solution package enqueue | no comment needed | Literal state members and managed/unmanaged loop expose ownership and paths, explained by function contract. X. |
| `Start-AlmQueuedExport` | documented | Queue mutation, independent client per package, in-process reference binding and completion record contract are important. X. |
| Thread-job parameter/import/helper scope | existing comments verified | Suppression justification accurately states explicit ArgumentList binding rather than using-scope serialization. X. |
| Thread-job budget wait/export/catch/finally | documented | Acquired flag prevents releasing an unowned slot when cancellation interrupts wait. X. |
| Job metadata and state lists | no comment needed | AlmSolutionName/AlmPhase fields directly match Receive helper and active/all-job lists serve explicit distinct consumers. X. |
| `Receive-AlmExportJob` | documented | Terminal state, exactly one result, error record rejection, diagnostics/log side effects and retained ownership need a contract. X. |
| Nested group filtering / provider group replay | documented | Receive contract identifies filtering nested markers; Format helper owns directive preservation explanation. X. |
| `Write-AlmExportEvent` | documented | Live progress queue remains separate from terminal job output to avoid losing completion records. X. |
| `Wait-AlmSolutionExport` | documented | Advances all workers, needs two packages, returns only unmanaged path, throws on failures/declined startup and retains cleanup obligation. X. |
| WaitAny signal/job handles / completion bookkeeping | no comment needed | Contract explains all-worker progress; explicit handles and terminal-state checks make wake-up paths readable. X. |
| `Stop-AlmExportPipeline` | documented | Single-use teardown disposes owned clients/handles/work directory but not default connection or external logs. X. |
| Teardown ShouldProcess suppression / forced cleanup | existing comments verified | Existing justification accurately protects mandatory cleanup under ambient WhatIf; focused tests cover resource retention policy. X. |

#### A9-A10. Baseline and cache entry points

Reviewed files:
[resolvebuildvalidationbaseline.ps1](../../pipelines/scripts/resolvebuildvalidationbaseline.ps1)
and [resolvedependencycache.ps1](../../pipelines/scripts/resolvedependencycache.ps1).

| File / symbol/block | Decision | Concrete reason / evidence |
|---|---|---|
| `resolvebuildvalidationbaseline.ps1` script help | documented | Raw configuration, Azure task variable (not return object), pointer fetch mutation, candidate-only cases and error policy differ from GitHub resolver. Z. |
| `Get-AzureBuild` | documented | Nested helper consumes script project/token and propagates REST failure, not autonomous auth. Z. |
| `Assert-SuccessfulBuild` | documented | Canonical ID returned only after definition/completion/success validation; used by both selector routes. Z. |
| `Resolve-FixedBuildIdentifier` | documented | Numeric input means ID; named lookup is exact case-sensitive, first 100 server matches and rejects ambiguity. Z. |
| `Find-SuccessfulBuildForCommit` | documented | Legacy pointer pages are traversed; implementation takes one match per page and rejects multiple page matches, not a false guarantee of all-match uniqueness. Z. |
| Empty baseline / emitted variable | documented | Script help defines cleared variable as candidate-only rather than error. Z. |
| Remote pointer absence versus Git failure | documented | Only ls-remote code 2 is expected missing pointer; reset LASTEXITCODE prevents false pipeline failure. Z. |
| Annotated pointer metadata / legacy commit fallback / Pop-Location | documented | Run ID disambiguates repeated builds; fallback requires full commit; finally restores caller location. Z. |
| Existing unused-parameter suppressions | existing comments verified | All named parameters are referenced in nested REST/selection functions as stated. Z. |
| `resolvedependencycache.ps1` script help | documented | Requested selectors, RUNNER_OS partition, lock precedence, output destinations and install-not-replaced boundary. I. |
| `ConvertTo-VersionSpecifier` | documented | Blank latest normalization and case/space equivalence define cache identity, not install syntax. I. |
| `Get-HashHex` | no comment needed | Explicit UTF8 SHA256 lower-hex transformation is small and complete; no security/authentication claim. I. |
| `Write-StepOutput` | documented | Single-line output helper supports host fallback; cache flags/hashes do not require multiline encoding. I. |
| Common/config path resolution and dot-source | no comment needed | Direct existence checks and exceptions define failures; BaseDirectory help names required config. I. |
| Lock-file overrides | existing comments verified | Existing diagnostics correctly distinguish lock/config source; each available key overwrites requested selection. I. |
| Module sorting/serialization/hash | documented | Order-independent stable identity despite hashtable iteration order needs rationale. I. |
| PAC cache enable/output block | no comment needed | Explicit always-true PAC flag is unchanged; script help does not claim floating caches resolve actual installed versions. I. |

#### B1. `.github\actions\common\resolve-prefixed-env.ps1`

| Symbol/block | Decision | Concrete reason / evidence |
|---|---|---|
| Script entry/environment contract | documented | Process plus GITHUB_ENV lifetime, sensitive selection, false/zero preservation, error policy and precedence are externally visible. A. |
| `ConvertTo-HashtableSafe` | documented | Does not validate successfully parsed shape; blank/null/parse failure returns empty and parsing only is best effort. A. |
| `Write-GitHubEnv` | documented | Unique delimiter preserves multiline values for subsequent runner steps. A. |
| `Get-PrefixFromEnvironment` | documented | Uppercase/punctuation normalization and disabling unusable prefixes match environment mapping callers. A, Y. |
| Alias table / prefix candidates / selected-secret parse | no comment needed | Literal alias pairs and strict dictionary check are direct; entry contract distinguishes variable and secret error policy. A. |
| `ConvertTo-ValueText` | documented | Compact JSON preserves non-string false/zero/arrays instead of dropping explicit settings. A. |
| Direct mappings and dynamic Dataverse variable collection | existing comments verified | Existing comment correctly separates canonical runtime mapping from arbitrary prefixed variables. A. |
| Explicit selected secret pass | documented | Intentionally overwrites existing values and masks supplied values before later variable fill passes. A. |
| Direct mapping candidate order / aliases | documented | Prefixed alias must outrank unprefixed canonical name; checked by service-account alias regression. A. |
| General prefixed and unprefixed passes | documented | Blank-only fills and prefixed-first ordering define hook/custom variable precedence. A. |
| Azure login JSON emission | documented | Subsequent-step credential object is conditional on all fields; no ARM subscription contract inferred. A, Y. |
| Mask/count/host completion diagnostics | no comment needed | Host messages expose names/count, values only through explicit mask output; no universal secrecy guarantee added. A. |

#### B2. `.github\actions\common\validate-auth.ps1`

| Symbol/block | Decision | Concrete reason / evidence |
|---|---|---|
| Script entry and RequireServiceAccount switch | documented | Presence/tenant-shape check is not identity or authorization validation; import/deploy require service UPN while export does not. A. |
| Required fields / GUID-or-DNS regex / optional UPN body | no comment needed | Explicit field-specific exceptions and conditional switch fully express implementation once validation boundary is stated. A. |

#### B3. `.github\actions\common\resolve-deployment.ps1`

| Symbol/block | Decision | Concrete reason / evidence |
|---|---|---|
| Script entry/environment/output contract | documented | INPUT JSON/branch policy, GitHub API inputs, appended outputs, no mutation/deploy and historical run absence behavior. G. |
| `Get-GitHubApiHeader` | no comment needed | Literal standard authorization/Accept/API-version fields, no fallback or credential provisioning logic to explain. G. |
| `Invoke-GitHubApi` | documented | Opted-in 404 only becomes null; caller must pre-encode dynamic path components and other errors propagate. G. |
| `Resolve-BuildRunDisplayName` | documented | Priority across older run payload forms matters to selection identity. G. |
| `Resolve-BuildRunCanonicalName` | documented | Display/ID fallback dominates legacy repo/branch/date construction; does not promise date fallback for all ID-bearing objects. G. |
| `ConvertTo-BuildReleaseTag` | documented | Legacy normalization deliberately differs from gate dot/hyphen transformations. G. |
| `ConvertTo-GateTagSegment` | documented | Retains slash path structure, not URL encoding; rejects empty sanitized identity. G. |
| `Resolve-WorkflowDispatchBranch` | documented | Missing/unknown ref type differs from explicit tag rejection and missing ref sentinel. G. |
| `Test-IsBuildWorkflowRun` | documented | Accepts conventional path OR display name; does not validate success. G. |
| `Get-BuildRunById` | no comment needed | Single wrapper delegates optional 404 behavior already documented on Invoke-GitHubApi; no extra selection policy. G. |
| `Get-GitHubReleaseByTag` | documented | Missing Release is an expected fallback, not a failure to deploy by itself. G. |
| `Resolve-GitTagCommitSha` | documented | Peels nested annotated tags and requires commit identity before source comparison. G. |
| `Get-BuildMetadataForTag` | documented | Legacy companion tag namespace, annotated-only requirement, null for incomplete/absent metadata and exact returned shape. G. |
| `Get-ReleaseInformation` | documented | Machine marker/linked-run/full-SHA format, decoded branch and throw policy tie to Release producer. G, R. |
| `Find-LatestManagedReleaseForBranch` | documented | At most 100 pages; ALM prerelease/case-sensitive branch filter; newest numeric BUILD run not Release publication date. G. |
| `Test-GitHubReleasePrerelease` | documented | Object/dictionary input support and missing-property false govern release filtering. G, R. |
| `Find-ReleaseForBuildRun` | documented | Exact run match among ALM prereleases, null absent and ambiguous failure protect pointer identity. G. |
| `Find-BuildRunByName` | documented | Legacy case-insensitive first-match behavior is not uniqueness checking; bounded pagination and later success gate retained. G. |
| `Find-LatestSuccessfulBuildRunForBranch` | documented | Conventional workflow successful branch API query returns first, with no-match exception. G. |
| JSON input extraction / caller branch/promotion checks | no comment needed | Field assignments and early exceptions fully state required branch/mode/target checks; script contract names role. G, Y. |
| Manual tag normalization / latest Release selection | documented | Current Release/legacy/companion lookup precedes run lookup; empty selector prefers retained branch Release. G. |
| Branch metadata check / BUILD lookup routes | no comment needed | Explicit priority branches and errors are readable with helper contracts; no implied equivalence between tag and display name. G. |
| Synthetic historical run fallback | documented | Metadata outlives Actions run; empty ID disables build artifact fallback. G. |
| Malformed tag/run Release repair / SHA validation | no comment needed | Warning/error text states recovery and tag/source equality; never infer verification of dispatch payload beyond actual checks. G. |
| Artifact source and gate/pointer output construction | documented | Separate per-build gate and movable environment pointer semantics, with both modes retaining pointer output. G. |
| Appended GITHUB_OUTPUT fields / host summary | no comment needed | Direct named output assignments match deploy action consumers; no hidden data transformation. G, Y. |

#### B4. `.github\actions\common\deploy-build-validation.ps1`

| Symbol/block | Decision | Concrete reason / evidence |
|---|---|---|
| Script help/parameters/prerequisites | documented | Raw candidate config, only missing pointer/blank skip, retained Release package source, existing connection, cleanup and no rollback. R. |
| `Get-GitHubApiHeader` | no comment needed | Literal header table matches repository REST version and current token, no additional logic. R. |
| `Invoke-GitHubApi` | documented | Only explicitly allowed 404 yields null; other API failures cannot silently skip baseline. R. |
| `Get-ReleaseInformation` | documented | Validates branch presence but returns no Branch; baseline is not constrained to candidate branch. R. |
| `Get-ReleaseByTag` | documented | Optional missing result delegated to selection policy, using encoded tag segment. R. |
| `Resolve-CommitFromTagReference` | documented | Nested annotated refs peeled to full SHA; non-commit/invalid objects throw. R. |
| `Test-GitHubReleasePrerelease` | documented | Dictionary/object shape and missing false determine managed lookup inclusion. R. |
| `Find-UniqueReleaseForCommit` | documented | Legacy commit cannot identify repeated runs; 100-page prerelease scan returns null/one or throws multiple. R. |
| `Find-ReleaseForRunId` | documented | No Actions fallback: missing or ambiguous retained Release fails baseline lookup. R. |
| `Resolve-Baseline` | documented | ID/tag/@pointer resolution, annotated run metadata priority, only absent pointer null; Release tag message field is not selection authority. R. |
| `Resolve-BaselineReleaseTag` | documented | Noisy/array tag candidates need unique run-metadata match; single normal tag stays direct. R. |
| `Expand-BaselineArchive` | documented | Destination is replaced and deploy script required; structural check is not authenticity assurance. R. |
| `Save-BaselineReleaseAsset` | documented | Single tag, exact asset, gh token process mutation, replacement/extraction and owned download-directory cleanup. R. |
| Config read / candidate-only routes / credential check | documented | Script help limits benign absence; credential gate occurs before configured lookup, not before candidate-only deployment. R. |
| Baseline-then-candidate invocation / finally | documented | Each package uses its own bundled implementation with current connection/dependencies; baseline failure stops candidate; final cleanup does not undo Dataverse. R. |

#### B5. `.github\actions\build\action.yml`

All new action comments are YAML comments outside scalar values. Embedded PowerShell
and JavaScript content, including messages, JSON defaults and release metadata
strings, is unchanged.

| Symbol/block | Decision | Concrete reason / evidence |
|---|---|---|
| Metadata/inputs/outputs and caller permission boundary | documented | Caller owns contents/OIDC permission grants; run name, SemVer, source ref and output identities are distinct. Y, B, G. |
| Checkout source code | documented | Selected checkout can differ from workflow SHA while implementation stays action-relative. Y. |
| Resolve SemVer build version / embedded PowerShell | documented | Explicit branch override is required for non-branch ref; original branch retained separately from checked-out source. C, Y. |
| Resolve dependency cache keys / module and PAC restore steps | documented | Requested-version keys do not replace current-process installation/import. I. |
| Set build number / embedded PowerShell | documented | Exact caller display name is independent of version tag. G, C. |
| Resolve prefixed repo variables and explicit secrets | documented | Optional validation environment gates mapping, not packing/checker policy; restricted secret selection. A. |
| Validate authentication inputs | no comment needed | Named validator call with RequireServiceAccount is direct; validator help defines presence-only scope. A. |
| Log in to Azure with GitHub OIDC | documented | Secret-versus-OIDC expression choice and subscription-less login are not obvious from name alone. A, Y. |
| Build artifacts and validate deployment / embedded PowerShell | documented | Installation/connection/build share process; HEAD metadata and reference JSON expansion precede optional baseline validation. B, R. |
| Upload build artifacts | documented | Always preserves partial artifacts but does not permit failed tag/Release publication. B, Y. |
| Upload solution check report | documented | Same always-diagnostics policy; missing report tolerated by explicit ignore setting. B. |
| Tag source with build version / embedded PowerShell | documented | Same-commit rerun idempotency never permits moving published source identity. G, C. |
| Download artifact archives for GitHub Release | documented | Uses uploaded archive IDs to preserve package root; deploy archive mandatory and checker optional. R, G. |
| Embedded `Download-ArtifactArchive` | documented | YAML comment directly above step explains artifact-ID download, nonempty-file requirement and layout purpose without altering scalar. R. |
| Create GitHub Release / JS metadata/body/assets | documented | Machine branch/build/run/source format consumed by resolvers, not merely human Release notes. G, R. |
| JS existing Release ownership/get/update/create | documented | Existing Release must belong to same BUILD; 404 alone enables create. G, R. |
| JS paginated asset replacement / output | documented | Replace assets by name on rerun; keep BUILD as prerelease for managed lookup. G, R. |
| Trigger DEPLOY via repository_dispatch / embedded PowerShell | documented | Branch event routing and published SHA/tag/run identity differ from receiving workflow ref; gh errors fail handoff. G, Y. |

#### B6. `.github\actions\deploy\action.yml`

| Symbol/block | Decision | Concrete reason / evidence |
|---|---|---|
| Metadata/inputs/composite/caller environment and permissions | documented | Approval boundary belongs to job, not composite; contents write/OIDC/Actions-read needs identified without changing grants. G, Y. |
| Resolve deployment execution context | documented | Branch/build selection precedes credentials/artifact execution and may use retained Release after run expiry. G. |
| Check deployment gate tag / embedded PowerShell | documented | Checks predecessor gate existence only; approval mode delegates enforcement to caller job. G, Y. |
| Download Release artifacts / embedded PowerShell | documented | Retained assets preferred; continue-on-error permits only explicit run-ID fallback, not unchecked deployment. G. |
| Remove failed Release extraction before BUILD fallback | documented | Prevent stale scripts/config remaining when artifact sources switch after partial extraction. G. |
| Download build artifacts | no comment needed | Exact run-ID/token/repository and conditional fallback are explicit with preceding policy comment. G. |
| Fail when Release and BUILD assets are unavailable | documented | No run ID means failed Release download must stop rather than proceed with partial content. G. |
| Resolve dependency cache keys / module/PAC restore steps | documented | Bundled artifact config/defaults/lock, not newer caller configuration, determine dependencies. I, D. |
| Resolve prefixed repo variables and explicit secrets | documented | GITHUB_ENV is required across step process boundary before validator/login. A. |
| Validate authentication inputs | no comment needed | Direct RequireServiceAccount call; common validator contract covers meaningful semantics. A. |
| Log in to Azure | documented | Conditional secret/OIDC input selection is stated independently of generic step name. A. |
| Install dependencies, connect, and deploy / embedded PowerShell | documented | Reference JSON expansion and process-local connection/modules explain step cohesion; bundled scripts run. D. |
| Push deployment tags / embedded PowerShell | documented | Success-only gate/pointer publication, accepted existing gate, annotated identity and non-atomic pointer delete/create are material behavior. G. |
| Pointer message / annotated object parsing / ref replacement | documented | Run/source metadata supports later baseline disambiguation; invalid SHA/errors remain failure, no atomicity claim. G, R. |

#### B7. `.github\actions\export\action.yml`

| Symbol/block | Decision | Concrete reason / evidence |
|---|---|---|
| Metadata/inputs/outputs/composite permissions/token boundary | documented | Source/reservation tag writes and OIDC permissions belong to caller; dispatch token affects final dispatch only. X, Y. |
| Checkout source code | documented | Persisted Git credentials needed for both reservation and final source push. X, V. |
| Resolve dependency cache keys / module/PAC restore steps | documented | Cache restores accelerate but cannot replace module installation/import in export process. I, X. |
| Resolve prefixed repo variables and explicit secrets | documented | Dev-branch mapping default chooses credentials; separate dev label is diagnostic only. A, X. |
| Validate authentication inputs | no comment needed | No service UPN needed for export; direct call matches validator/export body. A. |
| Log in to Azure | documented | Secret/OIDC input behavior explicit. A. |
| Install dependencies, connect, and export / embedded PowerShell | documented | Explicit scratch paths, default-branch warning context and shared process connection are required. X. |
| Upload export diagnostics | documented | Always upload permits failure worker/timing evidence; absent diagnostics ignored explicitly. X. |
| Commit and push changes / embedded PowerShell | documented | Stages whole working tree, including hook updates, and emits pushed only after source handoff succeeds. X, Y. |
| Trigger BUILD via repository_dispatch / embedded PowerShell | documented | Actual committed SHA prevents branch-tip race; no-change skip and explicit dispatch-token precedence stated. X, Y. |

#### B8. `.github\actions\import\action.yml`

| Symbol/block | Decision | Concrete reason / evidence |
|---|---|---|
| Metadata/inputs/composite and permission boundary | documented | Current source unmanaged import differs from published BUILD deployment; caller owns OIDC/environment. D, Y. |
| Checkout source code | documented | self is configuration/source while implementation stays action-relative. Y. |
| Resolve dependency cache keys / module/PAC restore steps | documented | Requested-version caches are not floating-version locks or install replacements. I. |
| Resolve prefixed repo variables and explicit secrets | documented | Same Dev-branch default as export; selected-secret override versus blank-fill variables. A. |
| Validate authentication inputs | documented | Process activation makes service UPN mandatory unlike export. A, D. |
| Log in to Azure | documented | Secret-present credential object versus OIDC expression selection. A. |
| Install dependencies, connect, and import / embedded PowerShell | documented | Reference JSON mapping and same-process build/checker then unmanaged deploy contract, not direct zip import. D, B. |

#### Upstream integration assessment: `4aa15e7`

The merge of `origin/main` (#97, inline mappings/build commands) was assessed after
the initial validation below. Manually resolved conflict blocks in
[build.ps1](../../pipelines/scripts/build.ps1),
[export.ps1](../../pipelines/scripts/export.ps1) and
[parallel-export.ps1](../../pipelines/scripts/parallel-export.ps1), and reviewed the
automatic merge of [common.ps1](../../pipelines/scripts/common.ps1).
Read `git diff 1b29582..origin/main` for all four files, their merged bodies and
the new B/X fixture bodies before adapting comments. Kept upstream executable
content, rather than retaining the obsolete pre-mapping pack-plan construction.
Hook execution and Major.Build version reservation remain upstream behavior;
their existing decisions still apply. No files were staged by this task.

The four new functions have explicit rows above, bringing the assigned runtime
inventory from **79 to 83 function definitions**, including nested checker helpers.
Mapping and build-command scriptblocks are separately assessed in those rows.
No new here-string or embedded-language body was introduced in these four runtime
files. Existing generated/embedded decisions elsewhere in this section are unchanged.

##### Integration validation

- Focused Pester 5.7.1 through `New-PesterConfiguration` with
  `Run.PassThru=true` and `Output.Verbosity=None`: **99 passed, 0 failed, 0 skipped,
  0 failed containers** across PipelineCommon, PipelineBuild, PipelineExport and
  ParallelExport. These include #97's mapping direction/order/escaping, removed
  configuration keys, generated build source, command failure, real command
  overlap, mapped export change detection and optional MappingFile forwarding.
- TEMP/TMP were redirected to workspace-owned `temp\runtime-upstream-tests`,
  restored in finally, and the scratch directory deleted; absence was verified.
- All four merged files parse. Ordered case-sensitive token Kind/Text comparison,
  excluding comments/newlines/end-of-input and normalizing CRLF, matches
  `origin/main` exactly: common **2,831**, build **4,306**, export **1,707** and
  parallel-export **1,900** executable tokens. Literal strings and embedded payloads
  participate in this comparison.
- PSScriptAnalyzer 1.24.0 with `scripts\powershell-validation.psd1` settings
  matches `origin/main` by rule/severity/source extent: build retains its two
  existing ShouldProcess findings; the other three files have zero findings.
  No new suppression or analyzer exception was added.
- `git diff --check` passes for the four owned runtime paths; no conflict markers
  remain in those sources. Git's unmerged status remains until the parent stages
  the resolutions. Parent owns final merge staging, full-suite/coverage validation
  and PR update; this task did not run the full runner concurrently.
- Validation uses mocks and local concurrency probes, not a live Dataverse service.
  In particular, cross-group ordering and placeholder/path exclusions were assessed
  from the implementation; the overlap fixture is not claimed as an exhaustive
  concurrency or path-validation test matrix.

#### Initial verification results and limitations

- Completed source/symbol/block assessment for all 18 assigned files and all 79
  PowerShell function definitions, including the three checker worker helpers.
  The build action's embedded artifact-download function and Release JS blocks
  have separate decisions above.
- Executable token identity and parsed YAML-value identity pass; this verifies
  unchanged embedded code/string/configuration content, not live service behavior.
- Configured analyzer findings are unchanged from `1b29582`. No new analyzer exceptions
  were introduced. The first raw token comparison reported mismatches caused by
  Git stdout LF versus worktree CRLF within multiline tokens; the corrected
  comparison normalizes CRLF and all tokens match.
- `actionlint` is not installed in this environment; no package was installed
  merely for documentation changes. YAML parsing and focused YAML tests are the
  local structural checks; parent owns repository-wide workflow validation.
- Focused Pester 5.7.1: **196 passed, 0 failed, 0 skipped, 0 failed containers**
  across PipelineCommon, PipelineBuild, PipelineConnection, PipelineDependencies,
  PipelineDeployment, PipelineExport, ParallelExport, SolutionVersionReservation,
  DependencyCache, BuildBaseline, GitHubBuildBaseline, GitHubDeployment,
  GitHubEnvironment and PipelineYaml test files. Invoked through New-PesterConfiguration
  with Run.PassThru=true and Output.Verbosity=None, without full-suite coverage.
  TEMP/TMP were redirected to a workspace-owned `temp\runtime-test-work` directory
  and restored; that scratch directory was deleted and its absence verified.
- The first focused command returned exit 1, with verbose output exceeding the
  tool response limit and no visible summary. A clean rerun of the same selectors
  with warning/verbose/debug/information streams suppressed produced the passing
  result above; no source/test behavior was changed between those invocations.
- Full repository suite/coverage is explicitly delegated to the parent coordinator,
  not claimed by this task.
- Pre-existing implementation limitations deliberately left unchanged: export's
  declared scratch default partially interpolates a literal path expression;
  Azure legacy commit lookup takes only the first match per page (so its multiple
  match check is not full within-page uniqueness); parsed variable JSON is not
  shape-validated by ConvertTo-HashtableSafe; historical Release metadata can
  resolve an empty BUILD run ID while later pointer publishing requires numeric ID;
  environment pointer ref replacement is delete/create and not atomic. Comments
  describe actual behavior and do not claim these are fixed.

## Shared setup review

### Scope and evidence

- File: [setup-common.ps1](../../setup-common.ps1); initial baseline: `1b29582`. Integration follow-up reviewed `git diff 1b29582..origin/main -- setup-common.ps1` after main advanced to `4aa15e7161b1e8ac9884e3b3c4ce621debe5f5fd` (#97); final executable comparison uses that upstream baseline.
- Author/assessment: Copilot, 16 October 2026. Every function body was read individually, including all branches of the large selectors. No human-review claim is made; independent human review remains a separate gate.
- Only comments were edited. No generated prose, comment-insertion scripts, executable changes, suppression changes, commits or pushes.
- `C`: `tests\SetupCommon.Tests.ps1`, read in full: status callback execution count, selectors, prompt/rendering contracts, normalization, optional values, config source preservation, mutation guards and publication decisions.
- `W`: `tests\SetupWizard.Tests.ps1` contract/test inventory and provider callback call sites: branch orchestration, DEV/deployment editors, baseline selection and review cancellation.
- `P`: targeted `setup-github.ps1` and `setup-azdo.ps1` callers: exact-version import/PSModulePath, authentication result consumption, status operations, provider callbacks and config writers.
- `R`: implementation read; no dedicated focused test located for this helper. Its documentation is limited to directly observable implementation behavior.
- `V`: `scripts\Test-PowerShell.ps1` validation runner and `scripts\powershell-validation.psd1` policy.
- `M`: #97 integration follow-up: re-read the complete updated `Set-AlmConfigSolutionsInFile` body, both provider configuration-writer call sites and the new `SetupCommon.Tests.ps1` test `preserves existing per-solution mappings and custom properties when replacing selections`. Its nested mappings/buildCommand/custom-setting fixture verifies retained source properties and removal of legacy `mappingFile`/`buildCommands`. No new named functions were introduced; the file still has 94.

All entries below refer to `setup-common.ps1`; reasons describe the resolved gap or why no additional prose is useful. “Documented” means individually authored contract/rationale was added, not that behavior was changed. “Existing comments verified” means retained commentary was checked against the body.

### Per-function outcomes

| Function | Outcome | Specific reason / resolved maintenance question | Evidence |
|---|---|---|---|
| New-DirectoryIfMissing | no comment needed | Single guarded directory creation; literal-path existence check, ShouldProcess and suppressed item output are explicit. No whole-wizard dry-run claim added. | C mutation guards |
| Expand-SetupConsoleArchive | documented | Clarifies archive extraction ownership, no cleanup/download, and propagated errors used by cache retries. | R; dependency callers |
| Get-SetupConsoleDependencyAssemblyPath | documented | Records exact framework lookup, existing package-root requirement, cache invalidation/retry paths and path-versus-loaded-assembly return. | R; framework loader |
| Initialize-SetupConsoleFrameworkDependency | documented | Explains Core no-op, ordered .NET Framework dependencies, simple-name reuse and load-error propagation. Existing pinned compatibility comment retained. | R; Initialize-SpectreConsole |
| Initialize-SetupConsoleCancellationSupport | documented | Describes one-time type compilation and the C# Start/Stop registration contract, including unsupported hosts and overlap rejection. | R; C menu fixture; selection wrapper |
| Initialize-SpectreConsole | documented | Adds initialization/cache/output contract; verifies existing edition/version, incomplete extraction and retry rationales. | R; C mock console initialization |
| ConvertTo-SpectreMarkupLiteral | documented | States null-to-empty and bracket escaping, distinguishing data from styling. | C strict-mode/markup tests |
| Get-OptionalObjectPropertyValue | documented | Preserves false/zero/empty versus null/missing, for hashtables and PS objects. | C strict-mode optional-value test |
| Test-SetupResourceNotFound | documented | Makes 404-only classification explicit so permission errors do not become creation paths. | R; HTTP classifier test inventory in SetupProviders.Tests.ps1 |
| Invoke-GenericStaticMethod | documented | Records arity/count overload selection, reflection type matching, first failure and possible candidate execution. | R; C default-text prompt |
| Test-SetupDebugEnabled | documented | Explains explicit opt-in tokens and blank/other-value off behavior. | R; menu debug caller |
| Write-SetupDebug | no comment needed | Straightforward conditional host message; debug opt-in contract lives in its predicate. | R |
| New-SpectreTable | documented | Literal column labels and unrendered mutable result are the meaningful contract. Existing lazy-type suppression remains intact. | C table/rendering callers |
| Add-SpectreTableRow | documented | Explicit mutation without output, and literal rather than markup cell handling. | C rendering and selectors |
| New-SpectrePanel | documented | Separates trusted content/HeaderMarkup from escaped Header and documents precedence. | C guidance/completion/metric rendering |
| New-SpectreInfoGrid | documented | Clarifies literal cells and unsorted hashtable order. | C completion rendering |
| New-SpectreMetricColumn | documented | Documents optional card shape, null skipping, fallback text/color and trusted style parsing. | C two-card/escaping test |
| Show-SpectreMetricCard | documented | Empty-card fast path avoids even console initialization; rendering otherwise delegates. | R; C overview mocks |
| Show-SolutionSelectionOverview | no comment needed | Three labeled metric records and clamped remaining count are already self-explanatory. | R |
| Show-EnvironmentConfigurationOverview | documented | Display readiness is a heuristic, not full validation; distinguishes recognized auth counts and service-account uniqueness. | C pending/mixed-auth cases |
| Show-KeyValueSummaryTable | no comment needed | Direct literal key/value projection through documented table helpers; no hidden transformation. | R |
| Set-SetupWizardContext | documented | Records script-scope navigation/display state and zero-based step index. | C searchable menu/back test; W |
| Set-SetupPhaseContext | documented | Separates zero-based phase state from step state. | R |
| Clear-SetupPhaseContext | no comment needed | Single idempotent script-variable removal with silent missing state. | R |
| Get-SetupPhaseContext | no comment needed | Single script-variable read with silent missing state; no transformation. | R |
| Clear-SetupWizardContext | no comment needed | Direct silent script-variable removal; cleanup policy documented by wizard owner. | C fixture cleanup; W |
| Get-SetupWizardContext | no comment needed | Direct script-variable read; navigation semantics documented at setter/wizard/menu. | C menu/back test |
| Get-SetupCurrentSectionMessage | no comment needed | Direct optional script-variable retrieval with no additional contract. | C prompt fixture; R |
| Set-SetupPromptDocContext | documented | Distinguishes replacing stored state from displaying guidance. | C guidance context test |
| Clear-SetupPromptDocContext | no comment needed | Single silent script-variable removal; section reset is documented at Write-Section. | C fixture/section callers |
| Get-SetupPromptDocContext | no comment needed | Direct optional script-variable lookup; stored shape is explicit in setter. | C guidance context assertion |
| Request-SetupWizardBack | documented | Explains why navigation throws rather than returning through nested prompts. | C wizard-back test; W |
| Test-IsSetupWizardBackException | documented | Exact marker/type matching through inner exceptions is a protocol, not general error classification. | C wizard-back test; R |
| New-SetupHeroPanel | documented | Corrects the misleading name's implication: returns banner text, not a panel. | R; dashboard |
| New-SetupTipsPanel | no comment needed | Static escaped control hints composed into a panel; readable content is its own explanation. | R |
| Write-SetupDashboard | documented | Native full-width bar has an inline fallback for unsupported cursor APIs. | C rendering fixture; R |
| Test-IsUserInterruptException | documented | Explains exception-chain inspection around async/reflection wrappers. | R; selection/status/error-handling callers |
| Invoke-SetupWizard | documented | Specifies step shape, passed-through output, rerun/back semantics, context cleanup and absence of rollback. | W; C navigation |
| Confirm-SetupReviewAction | documented | Approval emits nothing; either cancellation/null throws. | W cancelled-review contract |
| Show-SetupPromptGuidance | documented | Prompt-local display intentionally preserves section documentation context. | C guidance/prompt rendering |
| Get-SetupPromptInlineText | documented | All validated prompt kinds currently produce the same escaped markup label. | C text/secret/yes-no tests |
| Write-SetupConsoleBar | documented | Records boolean fallback, plain text, row/switch precedence, color/cursor restoration and failure behavior. | C bottom-row delegation/fallback; R |
| Show-SetupStatusBarAtBottom | documented | Inline host fallback cannot be erased by native bottom-row cleanup; filtering hint is conditional. | C fallback/search-hint test |
| Clear-SetupStatusBarAtBottom | documented | Explicit best-effort native-row cleanup, not inline output removal. | C bottom-row delegation test |
| Add-SetupConsoleCancelHandler | documented | Registration result and same-delegate cleanup ownership explain accessor/reflection fallback. | R |
| Remove-SetupConsoleCancelHandler | documented | Mirrors registration compatibility path; cleanup failure is verbose-only. | R |
| Show-SelectionPromptWithInterruptHandling | documented | Return shape, normalized cancellation, unsupported-host token fallback and finally cleanup are explicit. | C async selection stub; R |
| Write-SetupPromptFrame | documented | Separates section redraw/content preservation from optional guidance suppression. | C prompt fixture; selectors |
| Wait-ForUserAcknowledgement | documented | Only first choice succeeds, emits nothing, and cancellation throws. | R |
| Read-SecretText | documented | Masking does not produce SecureString; preserves nonblank whitespace, describes blank/AllowEmpty and cleanup. | C secret whitespace/default test |
| Write-Section | documented | Explains script section state, doc-context reset, console clear and guidance gating. | C rendering/selectors; R |
| Select-FromMenu | documented | Extends existing help with zero-based/null/back protocol, duplicates and best-effort console restoration. Retains verified single-item host workaround rationale. | C literal labels, empty/single-choice, searchable/back tests |
| Read-YesNo | documented | Yes-default/DefaultNo boolean contract plus finally cleanup and error propagation. | C yes/no defaults |
| ConvertFrom-GitRefToBranchName | documented | Only refs/heads is shortened; other refs are unchanged. | C normalization test |
| ConvertTo-UrlSafeName | documented | Existing allowed-character help extended with collapse/trim, possible empty results and lack of uniqueness/provider validation. | C normalization and branch fallback tests |
| ConvertTo-NormalizedEnvironmentUrl | documented | Distinguishes authority normalization for HTTP(S) from permissive fallback and null blank input. | C URL variants |
| Test-IsValidTenantIdentifier | documented | Existing help qualified as permissive syntax checking, not tenant discovery/full DNS validation. | C domain/GUID/blank cases |
| Assert-ValidTenantIdentifier | existing comments verified | Existing synopsis accurately describes throwing validation wrapper; Source only decorates the explicit error text. | C invalid-source and valid-domain cases |
| Get-Alm4DataverseDocumentationRef | documented | Explicit/script/stable precedence and lack of trimming/encoding are relevant to link behavior. | C docs default/explicit tests; R |
| Get-Alm4DataverseDocUrl | documented | Tree link construction, separator normalization and trusted unencoded inputs. | C docs path/ref assertion |
| Get-SetupGuidanceHeaderMarkup | no comment needed | Single escaped bold header result after initialization; no concealed policy. | C guidance render path |
| Write-SetupPanelBottomBorderOverlay | documented | Explains cursor-before-panel input, visible-width approximation, trusted markup and best-effort overlay/restoration. | C guidance render fixture; R |
| Write-SetupGuidance | documented | Describes blank-line/link-only handling, context update timing, header validation, fallback ref and overlay failure limits. | C stored-context/escaped-guidance test |
| Read-TextWithDefault | documented | Details default-before-AllowEmpty precedence, default preservation versus typed trim, retry and cleanup. | C text/default/empty tests |
| Get-DefaultSetupBranchName | documented | Sanitization fallbacks and UTC-second suggestion are not uniqueness guarantees. | C all-invalid branch/context fallback |
| Get-RepoChangePublishPlan | documented | Records six-field plan, direct/alternate/PR targets, null PR fields, cancellation and no provider contact. | C publication cases; P |
| Get-BranchTargetedRepoChangePublishPlan | documented | Distinguishes fixed target from general publication helper, PR source and prompting-only behavior. | C branch-targeted cases; P |
| Get-CredentialSummaryText | documented | Records identity precedence, existing-connection labeling and deliberate avoidance of secret fields. | C credential summary tests |
| Show-EnvironmentConfigurationTable | documented | Required row fields differ from optional UPN; credential rendering is summary-only. | C environment selector tests |
| Select-OrderedSolution | documented | Describes object identity, required names, add deduplication, manual ordering and null/Done returns. | C add/reorder/remove/clear tests |
| Set-AlmConfigSolutionsInFile | documented | Documents input name/unmanaged projection, first case-insensitive existing-name match, source-backed retention of other properties, legacy mappingFile/buildCommands removal, restricted data import, AST extent preservation, creation/errors/guard and post-creation change flag. Adapted to #97 rather than retaining the old claim that all other properties are discarded. | C source preservation/idempotency/WhatIf; P; M |
| Set-AlmConfigSolutionCheckEnabledInFile | documented | Explicitly warns whole solutionCheck replacement discards subsettings; preserves unrelated root values and documents I/O/error/change semantics. | C template/toggle/idempotency/WhatIf |
| Set-AlmConfigBuildValidationBaselineReleaseInFile | documented | Baseline-only updates preserve siblings, empty selectors allowed without resolution, malformed shape throws, creation/guard semantics explicit. | C baseline preservation/invalid config/WhatIf |
| Select-BuildValidationBaselineEnvironment | documented | Describes short-name deduplication, name/URL exclusions, @selector versus empty sentinel, and cancellation error. | C distinct-baseline test; W |
| Select-ConfiguredDeploymentEnvironment | documented | Positional add/edit callback contracts, null preservation, shallow identity, list return and no rollback documented. | C callback assertions; P; W |
| Get-DefaultBranchEnvironmentMappingsFromStrategy | documented | Production-name heuristic, first-match behavior, branch ordering/empty targets and object shape documented. | C Simple/Gitflow/no-prod cases |
| Test-BranchEnvironmentMappingDuplicate | documented | Scope is cross-branch deployment identity, not DEV assignments or duplicates within one branch; URL/name fallback explicit. | C duplicate and normalization cases; W |
| Show-BranchEnvironmentMappingTable | documented | Configured versus discovered DEV precedence is a display projection, not validation. | C branch editor display paths; R |
| Select-BranchEnvironmentMapping | documented | Documents callback positions/results, shallow copy, exact bootstrap shape, BranchOnly meaning, built-in exclusivity/sort and null bypass of final validation. | C bootstrap/callback/rename/assignment/remove tests; P; W |
| Get-ModulePathDelimiter | no comment needed | One platform PathSeparator return; no non-obvious policy. | R; P PSModulePath callers |
| Install-NuGetProviderIfMissing | documented | Current-user mutation only on missing discovery, with caller error-preference semantics. | R; exact-module caller |
| Get-ModuleAvailableExact | documented | First disk-discoverable exact-version module or null, not loaded-module state. | R; import helper |
| Save-ModuleExact | documented | Downloads pinned version/dependencies but does not add destination to PSModulePath. | R; P module startup |
| Import-RequiredModuleVersion | documented | Path precondition, recheck after download, force import/version verification and host-only normal output. | R; P module startup |
| Resolve-DevelopmentDefaultAlm4DataverseRef | documented | Candidate precedence, branch/detached-SHA/fallback outcomes, error propagation and preference restoration. | R; P development startup |
| ConvertTo-SetupActivityOutputLine | documented | Stream severity markup and null/blank filtering/trim behavior. | R; C captured-status regression |
| Show-SetupActivityOutputPanel | documented | Lines are already trusted markup; MaxLines counts entries, not embedded physical lines; tail/placeholder policy documented. | R; C post-operation display-failure regression |
| Invoke-WithSpectreStatus | documented | Capture merges streams, consumes strings, returns last non-string object and avoids replay after start; uncaptured fallback may rerun callback. | C at-most-once captured operation regression; P |
| Invoke-WithErrorHandling | documented | Retry can repeat partial side effects, skip returns null, back/cancel bypass menu; status changes callback semantics. | C retry-count/result test; P |
| Show-SetupCompletionScreen | documented | Link input union/label precedence, trusted URLs, display-only success message and cleared console. | C strings/dictionary/custom-object next links |
| Get-AuthToken | documented | MSAL prerequisite, cached client construction limits, scope formation, username preference versus identity enforcement, account-list mode, cache bytes and silent/interactive errors. | R; P account-list/authentication and token consumers |
| New-EntraIdApplicationSecret | documented | Object-ID versus app-ID, pre-auth ShouldProcess, plaintext secret return, retained credentials and propagated failures. | C WhatIf/Graph body/secret return/auth failure |
| Resolve-DataverseEnvironmentFriendlyName | documented | Provider catalog and normalized endpoint lookup; fallback on blank/miss/catalog error without blocking setup. | R; P provider catalog |
| Resolve-EntraIdApplicationByAppId | documented | Tenant/app cache key, first projected Graph result, cached misses/REST failures versus propagated authentication errors. | R; P application discovery |

### Embedded and complex-block outcomes

| Block | Outcome | Reason / evidence |
|---|---|---|
| Library startup/source-to-installer role | documented | File contains only function definitions. Added loading contract without inventing startup authentication; provider entry points initialize helpers later. |
| Dependency archive refresh | documented | Exact dependency DLL controls cache validity; extraction failure and missing-DLL refresh paths checked in full. |
| Spectre edition/version selection | existing comments verified | Windows PowerShell .NET Framework dependency selection and Core framework preference match pinned package logic. |
| Spectre partial-directory/archive recovery | existing comments verified | Existing comments describe incomplete extraction and one extraction-exception retry; independent missing-assembly refresh remains visible. |
| Embedded C# `ALM4Dataverse.SetupConsoleCancellation` type/lifetime | documented | Individually authored explanation sits immediately before the string-array program so **all embedded source string literals remain byte-for-byte token-equivalent**. It covers runspace boundary, lock ownership and source identity. No C# literal edits were made. |
| Embedded C# `ALM4Dataverse.SetupConsoleCancellation.Start()` | documented | Outer contract describes single-source ownership, overlap exception and null on subscription failure; source cleanup in subscription catch read. |
| Embedded C# `ALM4Dataverse.SetupConsoleCancellation.Stop(CancellationTokenSource source)` | documented | Outer explanation describes matching-source detachment and disposal; null input and cleanup catch read. |
| Embedded C# `ALM4Dataverse.SetupConsoleCancellation.OnCancel(object sender, ConsoleCancelEventArgs eventArgs)` | documented | Outer rationale explains capture under lock, Cancel outside lock, concurrent disposal race, exception swallowing and conditional termination suppression. |
| Reflection generic overload attempts | documented | Failed candidates preserve the first error; no promise of side-effect-free probing. |
| Native console bar cursor/color cleanup | documented | Returns false on console errors, prioritizes AtBottom and RestoreCursorPosition; no claim of universal host support. |
| Selection prompt cancellation/cleanup | documented | C# registration versus local fallback and async exception normalization checked; disposal owned by finally. |
| Single-item menu workaround | existing comments verified | Retained host-workaround explanation; added cancel only when exactly one effective/original item and no generic back. C tests cancellation. |
| Menu label/index/back protocol | documented | Escaped display labels map back with case-sensitive comparison, first duplicate wins; navigation marker is separate from null cancellation. |
| AST source-preserving config edits | documented | Extents replace only intended values; root assumption explained. Whole checker replacement is explicitly distinguished from nested baseline preservation. C tests source/idempotency/shape/WhatIf paths. |
| `Set-AlmConfigSolutionsInFile` imported-name/source pairing | documented | #97 uses restricted data import for existing names and AST extents for retained values. First case-insensitive name match selects the source entry; copying requires the corresponding source index to exist. Inline mappings/buildCommand/custom values are preserved from source, not incoming selection fields. Evidence: M complete body/callers and nested-property regression. |
| `Set-AlmConfigSolutionsInFile` direct-solution AST filtering | documented | Anonymous Find/FindAll/Where-Object callbacks were read individually. Parent/ancestor checks keep direct solution hashtables in positional order and exclude nested mapping hashtables/arrays, preventing property data from shifting the solution lookup. Evidence: M nested mappings/buildCommand/custom-setting fixture. No new named helper exists. |
| `Set-AlmConfigSolutionsInFile` property-retention filter | documented | Existing name/deployUnmanaged keys are replaced by setup's selected values; legacy mappingFile/buildCommands keys are intentionally omitted while other keys retain original key/value source text. Evidence: M checks mappings, nested buildCommand arguments, customSetting, deployUnmanaged, legacy-key removal and selected-solution count. |
| Empty-main branch bootstrap | documented | Exact initial signal documented; configured repositories bypass strategy inference. C bootstrap tests both strategies. |
| Branch environment assignment identity | documented | URL/name identity, exclusion across branches and ShortName sort described at owning helper. Callback/Done/null validation limits are explicit. |
| Status capture/replay boundary | documented | Captured operations track Started/Completed; panel failure returns stored result. Uncaptured path does not have this guarantee. C execution-count regression. |
| MSAL client reuse and disk cache | documented | Initial authority/client reuse, account-list side effects and raw serialized-cache handling are documented without claiming encryption, enforced tenant switching or live authentication coverage. |
| Entra application lookup error boundary | documented | Authentication is outside REST catch; warning/null and cache behavior apply to REST failures, not authentication errors. |

### Validation

- PowerShell parser: **pass**, zero parse errors.
- Initial read-only ordered token comparison with `1b29582`, excluding comment/newline/end tokens: **pass**, all **17,068 executable tokens unchanged** (including strings and embedded C# source).
- PSScriptAnalyzer **1.24.0**, repository `AnalyzerSettings`: **pass for regression comparison**, **11 unchanged baseline findings**. No new exceptions or suppressions. Baseline findings are not claimed absent.
- `git diff --check -- setup-common.ps1`: **pass**.
- Pester **5.7.1**, focused `tests\SetupCommon.Tests.ps1` and `tests\SetupWizard.Tests.ps1`: **65 passed, 0 failed, 1 skipped**, zero failed containers. The skipped case is provider-specific existing test selection; no skip was added.
- Post-#97 integration parser/token check against `origin/main` at `4aa15e7`: **pass**, zero parse errors, all **17,301 executable tokens unchanged**, including literal/embedded payloads; **94 functions** remain. Only comments differ from upstream in this file.
- Post-integration PSScriptAnalyzer **1.24.0**, repository settings: **11 unchanged findings** compared with `4aa15e7`; `git diff --check -- setup-common.ps1` passed.
- Post-integration focused Pester **5.7.1**, only solution-selection preservation (existing and new inline-mapping/custom-setting regression) and configuration WhatIf cases: **6 passed, 0 failed**, zero failed containers; 39 unrelated tests not selected. No full suite was run concurrently with parent validation.
- No full suite or coverage gate run here; parent coordinates repository-wide validation.
- No live NuGet downloads, module installation, real authentication or service provisioning were performed to validate comments. Remaining risk is those existing integration paths, not a claimed tested guarantee.

### Unresolved issues

No blocking documentation ambiguities remain in this assigned file. Existing implementation limitations were documented rather than changed: uncaptured status fallback can replay a callback, checker writing replaces all checker subsettings, and cached MSAL client construction does not re-key by tenant/client. No human approval/review beyond the supplied implementation approval is asserted.

## Azure DevOps setup review

### Scope and authorship

Scope: [setup-azdo.ps1](../../setup-azdo.ps1) only, against commit `1b29582`,
assessed 16 October 2026.
Author and prose reviewer: Copilot (assistant-authored assessment, not human review).
User approval was supplied in the delegated implementation request. No commits or pushes.
Every function body and the complete startup/orchestration body were read. Prose was
individually authored with `apply_patch`; inventories and comparisons were read-only.
All rows below are closed documentation decisions; full combined-tree validation and
any independent/human sign-off belong to the coordinating task.

### Evidence key

- **Body/callers**: the named implementation and its relevant callers in this script;
  no live Azure DevOps, Graph or Dataverse operations were used.
- **R**: `tests/SetupRepository.Tests.ps1`: repository selection, clone fallback/cleanup,
  explicit divergence choices, seed publication, clean-index publication, Git failures,
  branch discovery/default fallback and ancestry classification.
- **E**: `tests/SetupEnvironment.Tests.ps1`: WIF reuse, secret keep/rotation without fixture
  mutation, manual/new/cached credentials, role creation/reuse/missing prerequisites,
  solution filtering/preselection/order, normalized configuration, target-edit callbacks,
  pending configuration, Entra identities/federation and discovery cache/URL selection.
- **P**: `tests/SetupProviders.Tests.ps1`: resource absence versus permission failure,
  ShouldProcess boundaries, token-resource normalization, clone cleanup, YAML generation,
  quoted BUILD environment, deployment replacement/idempotence, pipeline branches,
  endpoint reuse/refresh, environment reuse and missing resource permissions.
- **W**: `tests/SetupWizard.Tests.ps1`: existing branch preservation, BUILD/baseline,
  duplicate/unmapped branch rejection, DEV source selection, skipped solution discovery,
  cancelled review, positional editor callbacks and standalone step execution.
- **H**: `tests/helpers/Invoke-SetupTests.ps1`: isolated AST-loaded setup functions and
  pinned Pester validation contract (read; focused tests used direct Pester configuration).
- **Policy**: `scripts/powershell-validation.psd1` and the analyzer matching logic in
  `scripts/Test-PowerShell.ps1`; no policy changes were made by this task.

The cited suites were inspected for relevant fixtures/assertions and run as a focused
four-file Pester selection. A suite citation indicates relevant scenario evidence, not
a claim that every helper has its own direct test. Rows explicitly note indirect or
body-only evidence where relevant.

### Per-function decisions (69)

| Function | Decision | Gap resolved / reason and evidence |
|---|---|---|
| Install-PortableGit | documented | Directory return, existing executable reuse without version check, pinned archive failures and caller-owned PATH; body and startup caller, no direct focused test. Existing TLS compatibility rationale retained. |
| ConvertTo-AzDoOrganizationName | documented | Clarified permissive extraction versus validation; accepted URL examples already accurate. Body; no direct test found in focused suites. |
| New-AzDoProject | documented | Current VSTeam organization versus display-only Organization, process-menu cancellation fallback, output and ShouldProcess sentinel; body, project-creation scenario in R. |
| Test-AzDoGitRepositoryCommit | documented | False includes lookup errors and therefore is not proof of an empty repository; body and R initialization caller scenarios (indirect). |
| Start-AzDoGitRepositoryImport | documented | API response is a request, not completion; context, separate waiter and declined mutation output; body and companion waiter, no focused direct test. |
| Wait-AzDoGitRepositoryImport | documented | Alternate ID/status fields, five-second polling, seconds timeout, returned status and failure states; full loop and starter contract, no focused direct test. |
| Get-AzDoSharedRepositorySyncState | documented | Clone ownership, branch/tag resolution and equal/diverged flags; native stderr versus exit-code rationale. R ancestry/clone-failure tests and caller cleanup. |
| Initialize-AzDoProjectAndRepository | documented | Result fields/null cancellation, script state, extension provisioning, explicit destructive history choices and main-clone lifetime; R initialization/fast-forward/divergence/failure fixtures. |
| Get-DataverseEnvironmentCatalog | documented | Script cache, explicit refresh, normalized token resource, status-only switch and empty-result failure; E cache/empty tests, P resource callback tests. |
| Select-DataverseEnvironment | documented | Normalized exclusion before preferred choice, null cancellation and no-remaining-target error; E URL preference/exclusion tests. |
| Get-OptionalObjectPropertyValue | documented | StrictMode-compatible missing sentinel without losing false/zero; body and W BUILD optional-state callers (indirect). |
| Select-AzDoMainRepository | documented | Main versus template repo, creation/selection object and cancellation/ID failures; R main selection tests. |
| Get-AzDoSharedRepositoryNameFromWorkingTree | documented | First-match file precedence and scaffold-specific regex/null semantics; R reference discovery fixture. |
| Get-AzDoDeploymentEnvironmentNamesFromWorkingTree | documented | Ordered distinct literal names and missing-file empty result; body, R discovery and E existing-stage callers. |
| Get-AzDoExtensionModeFromWorkingTree | documented | Absent/conflicting tri-state result and literal boolean parser limit; R extension-conflict fixture. |
| Select-AzDoSharedRepository | documented | Preferred/excluded repository behavior, new-name fallback and cancellation/errors; R preferred/new-blank-name tests. |
| Sync-CopyToYourRepoIntoGitRepo | documented | Config preservation before merge, scaffold overwrites, branch rename, extension fallback and companion cleanup; body and branch publication caller tests in R (indirect for copy details). |
| New-AzDoRepoWorkingTree | documented | Default-branch precedence, optional work-branch reset, bearer header and cleanup ownership; R checkout/empty/failure tests, P WhatIf/cleanup scenarios. |
| Get-AzDoDefaultAgentQueueId | documented | Hosted/Default/first precedence and missing ID failure; body, pipeline registration caller/P tests (indirect). |
| Get-AzDoSecurityNamespaceByName | documented | API/display-name resolution requires ID; removed redundant retrieval narration. Body and repository-permission caller; no focused direct test. |
| Get-AzDoSecurityNamespaceActionBit | documented | Long mask result and error for absent action bit; body and Contribute caller; no focused direct test. |
| Get-AzDoBuildServiceIdentity | documented | Graph svc descriptor decoding yields an ACL identity descriptor; suffix matching/malformed skipping/failure. Body and permission caller; no focused direct test. |
| Get-AzDoAccessControlEntry | documented | Null covers unreadable as well as absent entries; corrected misleading existing failure comment. Body and mask-merging caller; no focused direct test. |
| Set-AzDoAccessControlEntry | documented | OverwriteMask requires caller merging; namespace-object requirement/ShouldProcess. Body and sole mask-preserving caller; no focused direct test. |
| Initialize-AzDoBuildServiceRepositoryPermission | documented | Preserve observed unrelated bits, remove Contribute deny only, no inherited permission evaluation and zero-mask lookup fallback; body/callers. Existing repoV2 token rationale verified. |
| Initialize-AzDoYamlPipelineDefinition | documented | Explicit branch/ref requirement, YAML-sourced CI creation and limited existing-definition reconciliation; P create/current/path-or-branch-update tests. |
| Initialize-AzDoMainRepositoryPipeline | documented | Filename definition names and DEPLOY suffix branch versus repository default; P DEPLOY branch registration test. |
| Initialize-AzDoDeploymentApproverTeam | documented | Team return and current-user membership side effect, identity-resolution failures; body and variable-group caller; no focused direct membership test. |
| Initialize-AzDoVariableGroupApproval | documented | Existing approval is retained without approver/settings reconciliation; body and E environment application caller (indirect). Existing team-descriptor rationale verified. |
| Initialize-AzDoVariableGroupExclusiveLock | documented | Existing locks are not rewritten and variable group is shared locking resource; body, P variable-group creation caller (indirect). |
| Initialize-AzDoEnvironment | documented | Reuse preserves description, creation returns API object, lookup/create failure propagation; P environment creation/reuse tests. |
| Initialize-AzDoPipelinePermission | documented | Per-pipeline grant and warn/continue failure contract; corrected incomplete ResourceType comment to include actual environment/repository callers. P missing-permission tests. |
| Initialize-AzDoServiceEndpoint | documented | Normalized binding comparison, supplied-secret refresh, nontransactional remove/recreate and WIF refetch; P endpoint mode/reuse/refresh/missing-secret tests. |
| Initialize-EntraIdServicePrincipal | documented | First app-ID match, lookup-warning/create fallback and creation failure behavior; E service-principal creation/reuse scenarios. |
| Add-EntraIdFederatedCredential | documented | Existing help augmented with object-ID/client-ID distinction and issuer/subject reuse versus lookup/create failures; E exact issuer/subject assertions. |
| New-EntraIdApplication | documented | First display-name match, credential metadata and plaintext secret result, WIF null versus secret rotation, WhatIf; E identities/auth mode cases. |
| Get-PowerPlatformSCCredential | documented | Null secret marker, keep/rotate mutation distinction, cached object identity and extension-mode restrictions/cancellation. Corrected stale exact-name recommendation comment. E credentials tests; P failed lookup guard. |
| Get-DataverseServiceAccountUPN | documented | Selected UPN is only format-checked, not licensed/directory-verified; E ownership/manual-input cases. |
| Initialize-AzDoVariableGroup | documented | Seed variables only on creation, confirmed-not-found creation rule and no approval removal when false; P lookup failure/404 tests, E application-role scenarios. |
| Update-AzDoVariableGroup | documented | Incoming values win, original-object success return/null failure, no secret-metadata preservation and WhatIf; body and nonsecret setup variables contract, no focused direct update test. |
| Get-DataverseSolutionsSelection | documented | Ordered solution metadata, optional friendly-name shape, valid empty solutions versus cancellation failure; E filtering/preselection/empty/connection cases. |
| Update-AlmConfigInWorkingTree | documented | Null preserves list, empty clears it, other settings always reconciled and boolean change result; body and R publication caller/W skipped discovery (indirect). |
| Update-AzDoBuildPipelineInWorkingTree | documented | Whole-file generation, all-branch trigger, optional validation association, escaped quotes and WhatIf; P generated YAML quote/schema/idempotence fixture. Here-string unchanged. |
| Initialize-DataverseApplicationUser | documented | Interactive tenant token and root-BU admin association rather than authenticating as the app; E application-user create/reuse/missing prerequisite tests. |
| Initialize-DataverseServiceAccountUser | documented | Dataverse user/role creation does not provision Entra account or license; E service-account create/reuse/missing prerequisite tests. |
| Get-ExistingEnvironmentsFromWorkingTree | no comment needed | Trivial direct forwarding wrapper; typed output and delegated helper's missing-file/ordering contract suffice. Body and E stage-prepopulation caller. |
| Get-AzDoExistingEnvironmentServiceAccountUPN | documented | Null includes missing variable/group and lookup failure; body and E existing-state reconstruction cases. |
| Get-AzDoExistingEnvironmentState | documented | Partial metadata versus all-missing null, endpoint tenant precedence and scheme-only HasExistingSecret marker; E identity/auth-mode reconstruction tests and R state discovery. |
| Get-GitRepoFileContentFromRemoteBranch | documented | Fetched-origin then local lookup without checkout/fetch; missing/blank content null; R branch discovery fixture. |
| ConvertTo-NormalizedGitBranchName | documented | Repeated origin prefix stripping is not refs/heads normalization; body and R remote-branch fixtures. |
| Resolve-GitExistingBranchRef | documented | Commit-resolving origin/local precedence and no fetch/null sentinel; R clone discovery callers. |
| Get-AzDoDeploymentEnvironmentNamesFromPipelineContent | documented | Text/scaffold parser, ordered distinct names, empty output and no expression evaluation; R mapping discovery. |
| Get-AzDoBuildEnvironmentNameFromPipelineContent | documented | First scalar/optional quotes, empty/missing null not assumed Build; R validation state fixture. |
| Get-SolutionCheckEnabledFromConfigContent | documented | Literal-only text detection with false fallback, no execution of remote config; R build-validation discovery. |
| Get-AzDoBuildValidationEnabledFromRepoClone | documented | Legacy OR of BUILD association/checker enabled and committed-ref source versus uncommitted edits; R validation discovery. |
| Get-AzDoDeployPipelineBranchMappingsFromRepoClone | documented | Filename BranchName versus SourceBranch and duplicate collapse, not consistency validation; R main/release mapping fixture. |
| Get-AzDoRegisteredDeployPipelineBranch | documented | Definition-name precedence over YAML filename and registered-only discovery source; body, R state fixture and P DEPLOY definition registration. |
| Get-AzDoRepositoryExistingSetupState | documented | Combined sources, default-branch-only fallback, alternate mapping shapes and omitted unresolved metadata; R discovered/fallback state tests. |
| Get-AzDoInitialBranchMapping | documented | Editor adapter removes null targets and defaults only when no usable states; body and W retained-branch setup fixtures. |
| New-AzDoBranchSetupState | documented | Separates discovered DEV state from future configuration/publication while retaining target identity/order; body, W branch editing tests; existing Policy exception verified. |
| Get-AzDoEnvironmentConfiguration | documented | Prompted credential/ownership collection, URL normalization and role flags without Dataverse role mutation; E normalized config and W BUILD configuration tests. |
| Get-DataverseEnvironmentsSelection | documented | Ordered editor callbacks, edited-row exclusion, DEV protection and missing-state completion/reuse; E duplicate URL/name and prepopulation/pending tests. |
| Update-DeployPipelineInWorkingTree | documented | Exact scaffold/indentation parser, empty-list removal versus missing-file error, ordered append and change boolean; P generation/idempotence/missing-template tests. |
| New-AzDoPullRequest | documented | Short branch names receive refs/heads, return response/declined sentinel and API errors; R publishing fixtures and P ShouldProcess cases. |
| Publish-AzDoRepoChange | documented | Whole-clone staging, clean-index push without PR, result fields plus native success-stream output, local author state/restoration; R clean-index/failure/publication scenarios. |
| Publish-AzDoBranchSetupChange | documented | Destructive disposable-clone contract, target/default/orphan seeding, missing PR target creation, null Solutions and no rollback; R branch publication matrix. |
| Get-AzDoPublishSummaryText | documented | Counts content changes, not no-change pushes or confirmed PR URLs; body and publication result construction, no focused direct summary test. |
| Set-AzDoEnvironmentConfiguration | documented | DEV/BUILD pipeline roles, existing endpoint marker, federation ordering/manual fallback, checks and example-only variables, nontransactional guard; E WIF/secret resource application tests. |
| Invoke-AzDoBranchAwareSetup | documented | Reviewed state versus publication, pre-review credential side effects, positional callbacks, standalone-step bypass, nullable solutions and shared BUILD/baseline; W orchestration scenarios. |

### Startup and generated/complex blocks

| Block | Decision | Evidence / reason |
|---|---|---|
| Script entry/help and legacy switch | documented | Help now states Windows interactive prerequisite, tenant hint, release/development ref, compatibility-only switch, external mutations and lack of full-installer dry run. Parameter body and startup call chain; H confirms tests load functions without running installer. |
| Release placeholders/common-library bootstrap | existing comments verified | Local setup-common versus embedded release marker and deferred Git ref resolution match code. Removed repetitive placeholder narration; corrected stale documentation path to actual Azure DevOps setup guide. Body and plan's release boundary. |
| Module/Git initialization | documented | Replaced stale “patch them” wording with exact module/dependency compatibility resolution; portable Git/PATH verification and version fallback remain intact. Startup body and imported helper calls. |
| Azure authentication and organization discovery | existing comments verified | Account-choice cancellation, bearer context, direct REST discovery before VSTeam account setup, stable-ID dedup and collision-only URI labels match implementation. No token literals/headers altered. Body; no live startup test claimed. |
| Shared repository seeding/synchronization | documented | Function contract covers explicit rebase/reset choice and cleanup lifetime; added native stderr/exit-code rationale. R seed, ancestry, divergence and failed-Git tests. |
| Scaffold preparation before wizard | documented | Startup comment explicitly warns resource provisioning precedes repository publication/review. Existing config preservation is owned by copy helper. Body and R integration fixtures. |
| BUILD YAML here-string | documented | Explanation placed outside here-string: whole-file scaffold, all branches, optional environment and scalar escaping. P YAML generation tests; exact checkout-filtered here-string byte comparison passes (one region). |
| DEPLOY string assembly | documented | Function help states exact line/indentation recognition and ordered target replacement/removal. No generated strings modified. P generation/idempotence and R publication fixtures. |
| Token callback scriptblocks | documented | Catalog/role helper comments explain resource authority and tenant context; callback implementation unchanged. P valid/invalid resource and authentication failure scenarios; E role tests. |
| Branch/environment editor callbacks | documented | Contract comments explain positional arguments, edited-row duplicate checks and standalone-step bypass. W callback and standalone-step scenarios, E target editor fixtures. |
| Global BUILD/baseline and skipped solution discovery | documented | Inline rationale separates shared validation target from deployment baseline. Wizard help explains null SolutionData preserves existing lists. W BUILD/baseline and no-DEV cases. |
| Per-branch publication and subsequent authorization | documented | Explains independently persistent pushes and that PR mode does not mean generated branch files are effective before merge. R publication modes; startup ordering inspected directly. |
| Final DEV/BUILD/deployment application and cleanup/completion | existing comments verified | Role-specific pipeline arguments, optional/skippable applications, best-effort clone cleanup and PR links match code. E role/permission application and W reviewed-state contracts; no rollback/live success guarantee added. |
| Embedded program inventory | no comment needed | No embedded C#/JavaScript/shell program occurs in this source; generated BUILD YAML and DEPLOY string assembly are explicitly covered above. AST/string/body inventory. |

### Qualified callback and generated-content inventory

AST reconciliation confirms **zero nested named function definitions**: the complete
named-function inventory is the 69 rows above. The following qualified names identify
anonymous callback contracts and generated payload owners, rather than inventing
additional PowerShell function symbols. Their documentation lives with their owning
functions or immediately beside the relevant invariant.

| Qualified unit | Decision | Caller/test evidence and specific reason |
|---|---|---|
| Get-DataverseEnvironmentCatalog::$fetchCatalog | documented | Catalog help explains cache/refresh and status presentation; invoked directly or by Invoke-WithSpectreStatus. E cache refresh and P token-resource tests. |
| Get-DataverseEnvironmentCatalog::Get-DataverseEnvironment.AccessToken | documented | Resource authority and discovery fallback are covered by owning help; provider invokes callback with resource. P malformed/valid resource and authentication-failure assertions. |
| Get-DataverseSolutionsSelection::Get-DataverseConnection.AccessToken | existing comments verified | Existing normalization-failure diagnostic preserves supplied resource, while connection receives returned token. E solution connection/filtering cases and the callback body; no separate normalization claim beyond implementation. |
| Initialize-DataverseApplicationUser::Get-DataverseConnection.AccessToken | documented | Owning comment specifies interactive tenant-scoped authentication rather than the app identity; connection callback captures EnvironmentUrl/TenantId. E application-user role fixtures and body. |
| Initialize-DataverseServiceAccountUser::Get-DataverseConnection.AccessToken | documented | Owning comment distinguishes Dataverse user/role writes from directory account/license provisioning; callback normalizes resource and uses tenant. E service-user role fixtures and body. |
| Get-DataverseEnvironmentsSelection::AddEnvironmentScriptBlock | documented | Owner help states current-selections positional argument, null/no-change and duplicate checks; called by Select-ConfiguredDeploymentEnvironment. E add/duplicate fixtures; shared helper invocation/body inspected. |
| Get-DataverseEnvironmentsSelection::EditEnvironmentScriptBlock | documented | Owner help states selections/target/index arguments and exclusion of edited row; E edit/duplicate fixtures plus shared helper's null-retains-row handling. |
| Invoke-AzDoBranchAwareSetup::Configure branches.Action::EditDevEnvironmentScriptBlock | documented | Owner help specifies allMappings/mappingToEdit positional order; callback chooses DEV, preserves current choice on selection cancellation and returns credential configuration. W positional editor tests and body. |
| Invoke-AzDoBranchAwareSetup::Configure branches.Action::EditDeploymentEnvironmentsScriptBlock | documented | Owner help and mapping-completed rationale cover integrated editing and skipped standalone steps. W positional editor/duplicate target fixtures; Get-DataverseEnvironmentsSelection caller contract. |
| Invoke-AzDoBranchAwareSetup::Configure branches.Action | documented | Branch state validation and mapping-completed invariant are explained next to state transition; Invoke-SetupWizard invokes Action. W retained branches, unmapped/duplicate rejection and callback scenarios. |
| Invoke-AzDoBranchAwareSetup::Configure DEV access.Action | documented | Shared mapping-completed explanation accounts for bypass while retaining standalone callback behavior; W standalone-step scenario exercises the alternative path. |
| Invoke-AzDoBranchAwareSetup::Configure deployment environments.Action | documented | Same explicit completion invariant applies to this role-specific step; owner help covers ordered environment selection, and W standalone-step/empty-branch cases exercise it. |
| Invoke-AzDoBranchAwareSetup::Configure BUILD validation.Action | documented | Inline rationale explains globally shared validation and separate baseline; W BUILD/baseline and cancelled required environment tests. |
| Invoke-AzDoBranchAwareSetup::Select solutions.Action | documented | Owner help states no DEV means null SolutionData and preserved solution lists; temporary config seed has explicit finally cleanup. W skipped discovery, multiple DEV sources and retained branches. |
| Invoke-AzDoBranchAwareSetup::Review choices.Action | no comment needed | Straightforward summary rendering followed by Confirm-SetupReviewAction; step name and direct call convey the contract without narration. W cancelled-review and normal review invocation assertions. |
| Update-AzDoBuildPipelineInWorkingTree::$newContent | documented | Entire generated BUILD YAML here-string is explained outside the payload; P quoting, extension boolean and generated schema fixture. Exact byte comparison preserves the payload. |
| Update-DeployPipelineInWorkingTree::$newStages | documented | Owning help explains exact scaffold replacement and promotion order; P YAML stage replacement/idempotence tests and publication caller in R. No generated string literal changed. |
| setup-azdo.ps1::__SETUP_COMMON_LIB__ | existing comments verified | Release insertion marker is not another helper body in this file. Bootstrap comment explains local import versus embedded library; source contains no embedded C# helper members to inventory. Parent owns setup-common/release verification. |

### Validation and limitations

- Parser: no errors; AST inventory contains exactly **69 functions**.
- Read-only comparison: **23,493** non-comment/non-newline executable token kinds/text equal to
  `HEAD`, including literals and here-string tokens (file newline representation
  normalized for that comparison).
- Additional byte check uses `git cat-file --filters HEAD:setup-azdo.ps1` so Windows
  checkout CRLF conversion is accounted for: the single complete here-string region
  is **byte-identical**. A preliminary raw-blob comparison differed only because the
  Git blob is LF and the Windows checkout is CRLF; no generated content was changed.
- Pinned PSScriptAnalyzer 1.24.0 with repository settings reports five diagnostics;
  rule/source diagnostics also match a direct baseline analyzer run, and all
  correspond to existing exact Policy exceptions (three credential-metadata
  parameters, plaintext-token adaptation and transient branch-state construction).
  No new suppression or exception was introduced.
- Focused pinned Pester 5.7.1 invocation of E/P/R/W completed with exit code 0;
  explicit failure/container/zero-test guards did not fire. This was a mocked,
  non-coverage focused run, not full-suite or live integration certification.
- `git diff --check -- setup-azdo.ps1` passed.
- Help discovery: `Get-Help -Full` matched AST help for all **35 function help blocks**
  plus script help in an isolated process that loaded only function bodies, never the
  installer entry point. Ordinary inline comments deliberately do not manufacture
  boilerplate help for small helpers.
- Full suite, 65% command-coverage gate, release-generation cross-checks, combined-tree
  validation and independent prose sign-off are delegated to the coordinating task.
- Existing implementation limitations (not changed): ACL lookup conflates absence
  and errors; endpoint recreation can leave partial resources; permission/federation
  warnings allow manual completion; variable-value merging does not preserve secret
  metadata. Comments describe these boundaries without treating them as new fixes.

## GitHub setup review

### setup-github.ps1 manual commenting review

- Baseline: `1b29582`; implementation date: 16 October 2026.
- Scope: [setup-github.ps1](../../setup-github.ps1). Only that source file and the assigned ledger were authored by this agent before ledger assembly. Other worktree changes belong to parallel work.
- Author and accuracy self-check: GitHub Copilot. No human-review claim is made.
- Method: read all 62 function bodies, startup/application flow, generated text, local call sites and related tests; individually compose prose with `apply_patch`. No comment drafting/insertion generator was used.
- Decisions below are complete assessment outcomes, not coverage percentages. “Documented” includes correcting existing help and adding narrow rationale where full help would be redundant.

### Evidence consulted

| Key | Evidence |
| --- | --- |
| C | Function bodies and their call sites in `setup-github.ps1`, including credential discovery, wizard callbacks, publication and final environment application. |
| S | `setup-common.ps1`: `Invoke-WithErrorHandling`, `Resolve-DevelopmentDefaultAlm4DataverseRef`, `Get-CredentialSummaryText`; common helpers loaded by the test fixtures. |
| P | `tests/SetupProviders.Tests.ps1`: token callback normalization/failure, individual ShouldProcess refusal, four credential writers, owner filtering, capability-probe cleanup, generated BUILD/DEPLOY quoting, stage guards and newline-stable secret merges. |
| E | `tests/SetupEnvironment.Tests.ps1`: existing/cached/manual credentials, secret keep/rotation, WIF/Secret application, Dataverse user/role reuse and missing-resource errors, ordered solution selection, catalog caching, URL normalization, repository-variable precedence and discovery. |
| R | `tests/SetupRepository.Tests.ps1`: publication with existing/seeded/missing targets, no-change branch pushes, PR reuse, preference/location restoration, cross-branch discovery and sync ancestry. |
| W | `tests/SetupWizard.Tests.ps1`: branch/DEV preservation, global BUILD validation/baseline, duplicate and empty mappings, cancellation before publication, positional editor callbacks, standalone environment steps and default/retired branch publication. |
| G | `.github/actions/build/action.yml` and `.github/actions/deploy/action.yml`: explicit source-ref/source-branch, caller permissions, artifact selection, promotion/gate inputs and credential inputs. |
| L | `prepare-release.ps1` placeholder substitution/library embedding and `tests/Release.Tests.ps1` standalone parsing expectations. Release tests were consulted, not separately executed by this agent. |

Tests use AST-extracted functions and mocked provider commands; they are not live GitHub, Graph or Dataverse integration evidence. Where a row cites an indirect scenario, its exact contract was checked against C rather than inferred from test coverage.

### Function decisions

| Function | Outcome | Specific decision and evidence |
| --- | --- | --- |
| `Install-PortableGitHubCli` | documented | Explain Windows architecture selection, unchecked existing-binary reuse, replacement and archive cleanup. C: bootstrap caller; L: installer packaging. No direct download test claimed. |
| `Invoke-GhApi` | documented | Define truthy-body JSON input, JSON/raw/null output and textual allowed-not-found classification; distinguish nonzero exits. C: all REST callers; P/E use mocked API boundaries, not direct live wrapper validation. |
| `Initialize-GitHubEnvironment` | documented | Clarify unconditional PUT, positive user reviewer IDs, absent reviewer body and lack of ShouldProcess. C: environment application and repository-variable secret path; E/P. |
| `Set-GitHubEnvironmentSecret` | documented | Retain stdin/newline rationale; add trailing-CR/LF, failure and per-write ShouldProcess contract. P: normalized argument and refusal/failure assertions. |
| `Set-GitHubEnvironmentVariable` | documented | State unchanged value transport, no result and native failure semantics. P: variable arguments, failure preference restoration, WhatIf. |
| `Set-GitHubRepoSecret` | documented | Verify existing newline rationale and document repository scope and refusal/result behavior. P: repository-secret normalization and native failure. |
| `Set-GitHubRepoVariable` | documented | Explain unchanged variable value and failure diagnostics, not redundant CLI narration. P: writer invocation and refusal/failure cases; E: unprefixed writes. |
| `Get-GitHubEnvironmentCapability` | documented | Record that this “Get” creates a probe and returns diagnostic flags, with best-effort deletion that may leave it behind. P: successful/unavailable probes and cleanup failure. |
| `Get-GitHubEnvironmentPrefix` | documented | Define normalization, trailing separator, empty-name error and possible collisions. C: state reader/writer naming; E: prefixed/unprefixed storage fixtures. |
| `Set-GitHubPrefixedEnvironmentCredential` | documented | Distinguish repository variables from environment secrets even in repository mode; null secret preserves stored value. C/E/P: storage/application and ShouldProcess. |
| `Get-GitHubRepoList` | documented | Correct unsupported write-access claim: gh repo list is capped at 100 and does not validate permissions. C: repository menu; R: repository metadata consumers. No permission guarantee remains. |
| `Get-GitHubRepo` | documented | Define returned metadata fields and failure behavior. C: new/shared repository callers; R: synchronization and publication context. |
| `Get-GitHubRepositoryIdentity` | documented | Retain effective-setting rationale; document mandatory numeric IDs and explicit subject-mode metadata, original customization return. C: startup and immutable opt-in. P: related mutation refusal only; no live API claim. |
| `Set-GitHubRepositoryImmutableSubject` | documented | Explain preservation of default/custom claims and confirmation/re-read requirements. Existing empty-201 rationale verified. C: startup opt-in and effective flag reuse; P: ShouldProcess refusal. |
| `New-GitHubEnvironmentWifSubject` | documented | Document name/ID versus legacy subject and verbatim environment naming requirement. C: trust writer; E: WIF/Secret application paths. |
| `Test-GitHubEnvironmentConfigurationUsesWif` | documented | Concise comment explains null/partial records and StrictMode-safe property checks; full help unnecessary for a boolean predicate. C: DEV/deploy/BUILD detection in startup; W: partial configuration shape. |
| `Initialize-GitHubSharedWorkflowAccessPolicy` | documented | Verify owner-policy rationale; add public no-op, missing-details warning and API propagation. C: selected shared repository caller; G: cross-repository action usage. |
| `Get-GitHubActionsVariableValue` | documented | Define repository/environment scope, no local fallback and null sentinel. C/E: precedence discovery calls and variable fixtures. |
| `Test-GitHubActionSecretExistence` | documented | Explain metadata-only boolean, scope selection and error propagation; no claim that secret values can be read. C/E: existing Secret/WIF inference. |
| `Get-GitHubWorkflowReferenceFromRepoClone` | documented | Describe local candidate precedence, returned repository/ref and regex limits. R: shared action reference discovery; C: existing setup state. |
| `Get-GitHubDeploymentEnvironmentNamesFromRepoClone` | documented | Clarify branch-named local file, encounter-order deduplication and missing-file empty result. C: compatibility fallback; R: empty/default setup. |
| `Get-GitHubDeploymentEnvironmentNamesFromWorkflowContent` | documented | Short contract distinguishes literal input extraction from YAML evaluation. R: mapped branch/environment fixture; C: remote-ref mapper. |
| `Get-GitHubBuildEnvironmentNameFromWorkflowContent` | documented | Identify first environment-name input and null behavior rather than confusing it with job environment. R: build-validation discovery; C: state reconstruction. |
| `Get-SolutionCheckEnabledFromConfigContent` | documented | State literal regex detection, false fallback and non-execution of PSD1. R: solutionCheck discovery fixture; C: build validation fallback. |
| `Get-GitHubBuildValidationEnabledFromRepoClone` | documented | Explain OR compatibility across workflow association and config flag; committed branch data rather than worktree. R: validation discovery; C. |
| `Get-GitRepoFileContentFromRemoteBranch` | documented | Define origin-first/local-second lookup, nonblank text/null and no fetch/checkout. R: git-show discovery mocks; C: branch discovery consumers. |
| `Get-GitHubDeployWorkflowBranchMappingsFromRepoClone` | documented | Differentiate filename BranchName from containing SourceBranch, local refs and deduplication. R: cross-branch mappings; W: availability publication; C. |
| `Get-GitHubExistingEnvironmentState` | documented | Explain per-field storage precedence, aggregate StorageScope, secret-existence inference, unreadable secret value and tenant fallback. E: both storage precedence and auth-mode discovery. |
| `Get-GitHubRepositoryExistingSetupState` | documented | Describe placeholder stages and required default mapping; do not hide missing credentials. R: mapped Missing stage and empty setup; W: reconstruction consumers. |
| `Get-GitHubInitialBranchMapping` | documented | Short rationale captures legacy aggregate fallback and DEV-only default retention. C: branch wizard seeding; W: DEV-only/target-only mappings; R: empty setup. |
| `New-GitHubBranchSetupState` | documented | Small constructor needs only null-versus-empty mutable-state semantics, not full boilerplate help. C/W: new/retired/default branch records. |
| `Get-GitHubOwnedReposForOwner` | documented | Retain private-account endpoint rationale; document first-page limitation and normalized full_name objects. P: case-insensitive owner filtering and unmatched owner. |
| `Resolve-GitHubRepoFullNameFromSource` | documented | Add local-origin inspection and unverified fallback semantics to existing synopsis. C: startup source resolution; R: upstream/shared repository context. |
| `Resolve-UpstreamGitRemoteSource` | documented | Explain accepted pass-through sources, owner/repo expansion and no connectivity check. C: startup and canonical sync source; R: sync discovery. |
| `Resolve-GitTargetRefFromRemote` | documented | State first-match mapping, missing/failed query errors and prerequisite fetched objects. C: sync caller fetch ordering; R: ancestry tests mock this boundary. |
| `Get-GitHubForkSyncState` | documented | Explain destructive WorkRoot preparation, canonical best-effort comparison, ancestry outputs and caller cleanup ownership. R: divergent/fast-forward/ahead and clone failure. |
| `Get-GitHubForksOfRepositoryForOwner` | documented | Verify missing-parent lookup comment; document first-page and immediate-parent constraints. P: owner and parent filtering; C: shared repository menu. |
| `Initialize-GitHubSharedWorkflowFork` | documented | Describe creation modes, automatic initial alignment versus prompted ancestry flow, mutation/cleanup contract. Move help before existing suppression attribute so PowerShell discovers it; executable token order unchanged. C/R and P owner-list evidence. |
| `New-GitHubRepositoryInteractive` | documented | Expand synopsis with prompt validation, README creation, cancellation, metadata return and early ShouldProcess behavior. C: startup creation caller; P: WhatIf. |
| `Initialize-EntraIdServicePrincipal` | documented | Distinguish app client ID from object ID and define first-existing/create return without a mutation guard. E: app/SP create/reuse; C: manual and new credentials. |
| `Add-EntraIdFederatedCredential` | documented | Replace create-only description with named reconcile, exact issuer/subject reuse, patch reread and warning-on-list-failure behavior; clarify object ID and exact subject parameters. E: current/outdated federation; C: environment trust writer. |
| `New-EntraIdApplication` | documented | Specify first display-name match, ensured SP and fresh Secret even on reused app. Remove assignment/query narration. E: existing/new WIF/Secret; P: WhatIf. |
| `Get-GitHubCredentialsForEnvironment` | documented | Record copy versus cached identity, null existing secret, explicit rotation and pre-review Graph mutations; remove menu narration. E: reuse, rotate, manual, create, cancellation. |
| `Get-GitHubExistingEnvironmentSelectionSummary` | documented | Compact contract records metadata-only display and null for empty/partial state. C: selection callers; S: credential summary implementation; E: normalized environment configuration. |
| `Get-DataverseEnvironmentCatalog` | documented | Explain script cache, enclosing TenantId callback, authority normalization/fallback and empty refresh failure. P: malformed/valid resource and auth failure; E: cache/refresh/empty. |
| `Select-DataverseEnvironment` | documented | Define exclusion-before-preference, shortcut flag, ordinary row retention and null cancellation. E: normalized URLs and exclusion; W: selector callback consumers. |
| `Initialize-DataverseApplicationUser` | documented | Document delegated connection, root-BU role, existing-user preservation and unguarded writes; replace numbered narration with role-ID invariant. E: reuse/create/missing connection/BU/role. |
| `Initialize-DataverseServiceAccountUser` | documented | Explain domainname lookup, missing-user creation and role association without claiming licensing validation. E: service-account user and missing-resource cases. |
| `Get-DataverseServiceAccountUPN` | documented | State manual-only shape validation, no user/license verification and cancellation error. E: existing/cached/manual invalid inputs; C. |
| `Get-DataverseSolutionsSelection` | documented | Define ordered config shape, omitted friendly-name on empty early returns, reuse flag and error cases. E: selection order, system filtering, empty/cancelled/connection failure. |
| `Get-GitHubEnvironmentConfiguration` | documented | Separate collected record from later application while acknowledging credential-selection side effects. E: normalized reused configuration; C/W. |
| `Set-GitHubEnvironmentConfiguration` | documented | Explain WIF object-ID condition, matching effective subject mode, secret preservation and non-transactional write order. E: WIF/Secret and repository-variable paths; P: WhatIf; C: startup callers. |
| `Get-SecretJsonInputBlock` | documented | Replace broad verbatim claim with zero-based inclusive block extent/indent/nearest-environment contract and parser limitations. P: merge fixture; C: merger implementation/callers. |
| `Merge-SecretJsonInput` | documented | Explain named/positional matches, retained expressions, indentation/platform newlines and bottom-up replacement invariant. P: LF/CRLF/mixed idempotence; C: generator/copy callers. |
| `Copy-WorkflowTemplatesToRepo` | documented | Document protected config/DEPLOY versus overwrites and secret merge; correct stale BUILD “copied verbatim” comment. Move help before suppression attributes for discovery. R: publication path; P: generation/merge; C. |
| `Update-AlmConfigInRepoClone` | documented | Explain null preserves versus empty clears solutions, targeted config setters and false-on-refusal contract. P: WhatIf; R: published config; W: skipped solution discovery. |
| `Update-BuildWorkflowInRepoClone` | documented | Add regeneration/output contract and host-side rationale for runtime expressions, validation secret and dispatch source branch/SHA. P: generated BUILD quoting/idempotence; G; C. |
| `Update-DeployWorkflowInRepoClone` | documented | Describe empty-stage deletion, ordered promotion modes and merge boundary; explain distinct IDs, predecessor guards and cancelling concurrency outside generated literals. P: unique IDs, both modes and guards; G; W. |
| `Publish-GitHubRepoChange` | documented | Explain staging/local identity, no-change push without PR, mixed native/result output and non-rollback/restoration contract. R: all publication modes, PR reuse, unchanged branch and native failures; S: operation wrapper. |
| `Publish-GitHubBranchSetupChange` | documented | Warn that RepoRoot must be disposable; explain branch seeding and target creation, definition override and skip behavior. R: seeded/missing target, PR/direct and restoration; W: default/retired definitions. |
| `Get-GitHubPublishSummaryText` | documented | Minimal comment clarifies why HasChanges=false branch pushes are not counted; full help unnecessary for display aggregation. C: final screen consumer; R: no-change result shape; W: aggregated results. |
| `Invoke-GitHubBranchAwareSetup` | documented | Add wizard contract plus shared-state, combined-editor sentinel and default/retired publication rationale. W: all GitHub orchestration scenarios; R: publishing; C/S: callback and operation boundaries. |

### Startup and generated-block decisions

| Unit | Outcome | Specific decision and evidence |
| --- | --- | --- |
| Script entry-point help | documented | Add attached script help covering prerequisites, parameters (including unused legacy switch), example, mutations and lack of whole-wizard dry run/rollback. C/S/L; help attachment checked through the AST. |
| Release/development bootstrap | documented | Consolidate ref selection rationale and remove placeholder-test narration; retain shared-library load/embed explanation verified against L. Exact module-version resolution comment replaces obsolete patching explanation. |
| CLI/Git prerequisite checks | existing comments verified | Portable CLI and Git checks are clear at their call sites; helper contract supplies download details. No extra narration added. C/L. |
| GitHub/Azure sign-in and tenant resolution | documented | Explain independent identities and cached username versus forced interaction; retain accurate tenant-token fallback comment. C/S/P token-callback evidence; no live sign-in run claimed. |
| Clone and cross-branch inspection | documented | Explain why fetching every origin ref precedes setup reconstruction; preserve explicit native exit handling and default checkout fallback. C/R. |
| Credential-storage and promotion selection | documented | Explain why discovered repository-variable layouts take precedence over available environment support. C/E/P capability probe; do not imply environment secrets are absent in repository-variable mode. |
| WIF repository-wide opt-in | documented | Explain impact on unrelated legacy trusts and required ordering before DEV/deploy/BUILD federated credential application. C/E and P individual mutation guard. |
| Publication versus credential application and cleanup | documented | Clarify that remote publication precedes final credential application and clone removal; record no transactional rollback. C/R/W/S. |
| DEV/BUILD versus deployment approvals and skip handling | documented | Explain no reviewer gate for DEV/BUILD and wrapper AllowSkip on BUILD/deployment; completion is not a live deployment test. C/E/S. |
| BUILD YAML here-strings | documented | Host comments explain GitHub runtime JSON/expressions, dispatch branch/SHA, validation association and caller permissions. P/G. All four here-string tokens are byte-identical to checkout-filtered baseline. Existing emitted comments retained. |
| DEPLOY YAML line-list program | documented | Host comments explain promotion ordering/status guards, branch dispatch, duplicate normalized IDs, permissions and cancel-in-progress concurrency. P/G/W. No generated string literal changed. |
| Copy callback and secret-expression preservation | documented | Explain regeneration boundaries and raw-expression text handling outside emitted YAML; do not add comments inside generated content. C/P/R. |
| Authentication callbacks | existing comments verified | Resource authority/fallback behavior is documented at catalog/user/solution helpers; existing verbose diagnostics intentionally do not print resource/token values. C/P/E. |
| Final completion screen | existing comments verified | Values and next-step links are self-describing; approval/skip qualification is documented at the application phase rather than duplicated into every label. C/W/S. |

### Validation and limitations

#### Anonymous callbacks and no-comment-needed decisions

The final recursive AST inventory contains exactly 62 named function definitions and
**zero nested named function definitions**. Every exact function name is present in
the function table. Generated YAML contains action invocations and expressions, not
additional named PowerShell/JavaScript/C# functions. The following qualified labels
identify anonymous blocks, not invented callable symbol names.

| Qualified block | Outcome | Reason and evidence |
| --- | --- | --- |
| `Get-DataverseEnvironmentCatalog` → `$fetchCatalog` → `-AccessToken` | documented | Enclosing help supplies cache, tenant capture and authority/fallback contract; P callback normalization/failure tests and E cache tests directly exercise it. No duplicate callback-local help needed. |
| `Initialize-DataverseApplicationUser` / `Initialize-DataverseServiceAccountUser` → `Get-DataverseConnection -AccessToken` | no comment needed | Both callbacks use the same visible authority-normalization/fallback sequence documented by the enclosing helper and catalog contract. E user tests execute callbacks and assert token resource/tenant; duplicate inline narration would add drift. |
| `Get-DataverseSolutionsSelection` → `Get-DataverseConnection -AccessToken` | no comment needed | Token delegation and enclosing TenantId are documented at the function boundary; the callback's default discovery resource and normalization are explicit. E discovery fixture invokes the callback and checks its returned token; P verifies the related fallback convention. |
| `Copy-WorkflowTemplatesToRepo` → `[Regex]::Replace` match evaluator | no comment needed | The immediately preceding authored comment identifies the selected repository/ref rewrite and BUILD exclusion. The evaluator only substitutes its captured action name; C and R publication fixtures establish the consumer. |
| `Invoke-GitHubBranchAwareSetup` → `Configure branches.Action` → `EditDevEnvironmentScriptBlock` | no comment needed | Positional `$allMappings, $mappingToEdit` contract and return/null paths are explicit; enclosing wizard help explains shared state. W executes the positional editor callback and checks resulting `Dev-main` configuration. |
| `Invoke-GitHubBranchAwareSetup` → `Configure branches.Action` → `EditDeploymentEnvironmentsScriptBlock` → `AddEnvironmentScriptBlock` | no comment needed | Duplicate URL/name rejection messages and configuration construction state the policy directly. W executes the add callback; enclosing generation help already explains promotion ordering. |
| `Invoke-GitHubBranchAwareSetup` → `Configure branches.Action` → `EditDeploymentEnvironmentsScriptBlock` → `EditEnvironmentScriptBlock` | no comment needed | The index-based exclusion of the edited row makes duplicate checking against other selections apparent; W executes the positional edit callback. Existing-credential reuse is documented by `Get-GitHubEnvironmentConfiguration` and E. |
| `Invoke-GitHubBranchAwareSetup` → `Configure DEV environments.Action` | documented | Shared-editor sentinel rationale explicitly explains why this otherwise separate action is bypassed; W separately executes standalone actions to preserve their contract. |
| `Invoke-GitHubBranchAwareSetup` → `Configure deployment environments.Action` → `AddEnvironmentScriptBlock` / `EditEnvironmentScriptBlock` | no comment needed | These standalone callbacks repeat the visible selection/duplicate/configuration flow, while the enclosing helper explains the sentinel and shared mutable state. W's standalone environment-step test executes both callbacks rather than relying only on the combined editor path. |
| `Invoke-GitHubBranchAwareSetup` → `Configure BUILD validation.Action` | documented | Function/state comments distinguish the one shared BUILD environment from per-branch DEV/deploy identities. W verifies validation/baseline and missing-environment rejection. |
| `Invoke-GitHubBranchAwareSetup` → `Configure solutions.Action` | no comment needed | The explicit zero/one/multiple DEV-branch cases and user-facing prompt state selection behavior. W tests no DEV, one source and multiple-source selection; E documents the called discovery result shape. |
| `Invoke-GitHubBranchAwareSetup` → `Review choices.Action` | no comment needed | Summary keys and final `Confirm-SetupReviewAction` call are self-describing. W asserts review invocation and proves cancellation prevents publication; repeating every displayed field in comments adds no contract. |
| Provider operations → `Invoke-WithSpectreStatus -ScriptBlock` / `Invoke-WithErrorHandling -ScriptBlock` | no comment needed | Short wrappers package native Output/ExitCode or invoke an already documented helper; local exit checks identify failure propagation. C/S and P/R/W cover caller operation/restoration behavior. Anonymous status wrappers do not require boilerplate help. |
| Pipeline filters, menu list projections and final next-step-link projection | no comment needed | Straightforward property filtering/formatting is directly readable; behavioral storage, mapping and publication policies are documented at their owning functions. E/R/W assert resulting records and publication state; comments would merely translate syntax. |

- PowerShell parser: zero errors; 62 functions.
- Exact executable-token comparison: **25,117** tokens match `git cat-file --filters HEAD:setup-github.ps1`, excluding comments/newlines/end marker. Token kind and full text compared; this includes here-strings and every string literal. Checkout filters account for the existing Windows CRLF representation; generated content was not changed.
- Attached help verified for the script and repaired `Initialize-GitHubSharedWorkflowFork`/`Copy-WorkflowTemplatesToRepo` blocks.
- PSScriptAnalyzer 1.24.0 using repository `AnalyzerSettings`: **6 unchanged baseline warnings**, zero new findings. Compared rule plus source extent against baseline: four `PSAvoidUsingPlainTextForPassword`, two `PSUseShouldProcessForStateChangingFunctions`. Existing policy exceptions/analyzer suppressions were not changed.
- Focused Pester 5.7.1: `SetupEnvironment.Tests.ps1`, `SetupProviders.Tests.ps1`, `SetupRepository.Tests.ps1`, `SetupWizard.Tests.ps1` completed successfully (exit 0; command explicitly fails on failed tests or failed containers). Output included host messages; no exact test-count claim is recorded here.
- `git diff --check -- setup-github.ps1`: passed.
- `actionlint` was not found on PATH; generated-workflow tests can parse YAML and assert output but their optional actionlint invocation was unavailable.
- Full suite, whole-file coverage gate and release-packaging execution are assigned to the parent. No commits/pushes or live service mutations were performed by this agent.
- Unrelated behavior observations retained, not fixed: repository listing does not validate advertised write access; repository listings are first-page limited; repository-variable mode can still require environments for secrets; per-helper WhatIf does not provide wizard-wide dry run. Comments describe these limits rather than changing executable behavior.

## Tests and test infrastructure review

### Test commenting assessment

Assistant-authored manual assessment, 16 October 2026. This is not a claim of
human review. Scope: [tests](../../tests), all 24 `tests\*.Tests.ps1` files and
`tests\helpers\Invoke-SetupTests.ps1` (25 files). All file bodies, lifecycle
blocks, Describe/Context/It blocks, mocks, callbacks and embedded fixtures were
read. Added prose was composed individually and applied with `apply_patch`;
no comment-generation/insertion script was used. Fixture strings are unchanged.
Straightforward assertions and test names were intentionally not narrated.

### Per-file assessment

| File | Decision and specific reason |
| --- | --- |
| BuildBaseline.Tests.ps1 | Documented shared selector fixture and process-wide native exit-state restoration. Numeric/name/pointer/pagination/error cases otherwise express their contracts in names and mocks. |
| Coverage.Tests.ps1 | Documented child-process Pester instrumentation isolation, executable module fixture, and disposable real-Git repository. Boundary percentages, source selection and rename assertions need no extra commentary. |
| DependencyCache.Tests.ps1 | Documented isolation of append-only action outputs and runner OS. Normalization, lock precedence and missing-path cases are explicit. |
| DependencyUpdates.Tests.ps1 | Documented why relative-path entry points run in a fixture working directory. Existing suppression justifications verified: empty CLI stubs expose Pester argument bindings. Update, rebase, stale-version and failure cases are self-describing. |
| Documentation.Tests.ps1 | No comment needed: fixture names distinguish valid/invalid local links, anchors and fenced languages; the deliberately unreachable external URL makes the no-fetch contract explicit. No named helpers. |
| GitHubBuildBaseline.Tests.ps1 | Documented recording-only deploy entry points in both archive and candidate; real extraction/order/cleanup is tested without live deployment. Metadata and selector cases are explicit. |
| GitHubDeployment.Tests.ps1 | Documented execution of the actual YAML publishing body, dispatch fixture shape, and real-Git namespace regression. Gate/pointer/metadata/fallback cases need no repeated descriptions. |
| GitHubEnvironment.Tests.ps1 | Documented clearing inherited process values and restoring tracked mappings. Alias, precedence, false/zero, masking and authentication cases already explain their differences. |
| ParallelExport.Tests.ps1 | Documented shared C# coordination and metadata warm-up trap, real importable worker module, release-before-stop cleanup, barrier-based occupancy measurement and distinct parent/worker unpack seams. Upstream mapping-forwarding stub and assertion reviewed; WhatIf, hooks, failure details and ownership assertions are explicit. |
| PipelineBuild.Tests.ps1 | Documented default in-runspace parallel shim versus two real-runspace opt-outs, separate build-command/pack-worker barriers, mapping XML snapshot lifetime and XML-escaping fixture. Pack-command resolution mock already explicitly throws on wrong ordering. Upstream command ordering/validation, mapping capability/directives and removed-setting cases reviewed; straightforward failures need no narration. |
| PipelineCommon.Tests.ps1 | Documented native output/exit-state simulator. Merge, SemVer, hook and PAC cases expose their contracts directly; cleanup of LASTEXITCODE is explicit. |
| PipelineConnection.Tests.ps1 | Documented fake process identities and restoration on failure. PAC and identity probe mocks isolate external operations. |
| PipelineDependencies.Tests.ps1 | Documented PATH/action-path isolation and fixture ownership while mocking installation. Upstream resolved/pinned module fixtures now use 3.2.1-preview.1; version selector and minimum-version cases are explicit and need no additional comments. |
| PipelineDeployment.Tests.ps1 | Documented literal solution-entry settings and sequential packing for the IMPORT fixture. Package/upgrade/service-account matrices need no redundant commentary. |
| PipelineExport.Tests.ps1 | Documented sequential mock visibility, nonobvious Major.Build mapping of 1.3 to 1.2.3.4, mapping capture/reset lifetime, unavailable BUILD-command sentinel and pathspec-sensitive status mock. Upstream old/new mapping reuse and duplicate-name-before-generation cases reviewed; additive/removal/reset/overflow/warning cases otherwise explain their intent. |
| PipelineYaml.Tests.ps1 | No comment needed: roots enumerate workflow/action/pipeline surfaces, aggregate parse failures retain paths, and tag verification ordering is explicit in the test name and IndexOf comparison. No named helpers. |
| Release.Tests.ps1 | No comment needed: TestDrive owns generated installers, unresolved-placeholder and parse assertions describe the generated-artifact contract, and workflow checks state stable-tag release policy. No named helpers. |
| SetupCommon.Tests.ps1 | Documented fake Spectre responsibilities/type lifetime, mutable callback state detecting repeated side effects, answer-by-label prompt queues and wrapper/console reset. Upstream selection-preservation fixture deliberately mixes retained inline mappings/custom values with removed solution-level mappingFile/buildCommands keys. Reviewed all selector, rendering, configuration, mutation-guard and publication blocks. |
| SetupEnvironment.Tests.ps1 | Documented fail-closed Dataverse fallbacks, provider AST loading without bootstrap, deferred token callback invocation and script-scoped discovery cache reset. Reviewed credential mode/reuse, users/roles, catalogs, editors and existing-state/storage blocks. |
| SetupProviders.Tests.ps1 | Documented fail-closed mutation stubs, function-only AST import, binding-only WhatIf samples, cleanup folder ownership and optional/required validator helper contracts. Reviewed authentication callbacks, lookup classification, guards, credential writes, owner filters, cleanup, generated workflows/pipelines and endpoint reconciliation. |
| SetupRepository.Tests.ps1 | Documented external-boundary fail-closed fixtures, TEMP/LASTEXITCODE lifetime and Git diff's distinct exit-1 semantics. Reviewed selection, working-tree failures, upstream sync/divergence, publication/PR updates and repository discovery. |
| SetupWizard.Tests.ps1 | Documented minimal Spectre fallback/type reuse, AST loading without startup and sentinel termination when exercising standalone environment-step callbacks. All branch, review, validation, editor, source-selection and workflow-retirement cases assessed. |
| SolutionVersionReservation.Tests.ps1 | Documented local bare-origin isolation and deterministic check/push race simulation. Increment/bounds/default-branch assertions are explicit. |
| Validation.Tests.ps1 | Documented outer TestResults isolation, name-only analyzer extent construction from current AST and child-validator early-failure/nonrecursion invariant. All orchestration, analyzer-policy and enforcement blocks assessed. |
| helpers\Invoke-SetupTests.ps1 | Documented repository-relative path contract, diagnostic-only coverage target, and empty/discovery/container failure handling. Existing settings match the main runner's coverage mode; no named functions. |

### Named PowerShell helpers and stubs

Each group below is file-specific. “Existing verified” includes suppression
justifications already attached to command stubs; no help boilerplate is needed
for empty signatures whose only purpose is Pester parameter inspection.

#### BuildBaseline.Tests.ps1

- `Invoke-BaselineFixture` — documented: holds config path and ADO identity fixed while varying selector.
- `git` — existing verified: empty signature with tag switches needed by mock routing.

#### Coverage.Tests.ps1

- Embedded `Get-FixtureValue` — documented outside its string: real imported-module command for coverage instrumentation; constant return requires no internal comment.
- Embedded `BeforeAll`, `Describe 'Module fixture'`, `It 'returns its value'`, and runner body — documented at containing fixture: isolated child Pester writes coverage JSON and fails on nested test failures.

#### DependencyUpdates.Tests.ps1

- `git`, `gh` — existing verified: empty CLI signatures expose verb/operation to Pester, with explicit unused-parameter justifications.

#### GitHubBuildBaseline.Tests.ps1

- `gh` — existing verified: remaining-arguments stub captures the download directory switch.
- Embedded deploy script bodies (unnamed) — documented: append package path to the common order log rather than deploying.

#### GitHubDeployment.Tests.ps1

- `Invoke-DeploymentTagStep` — documented: substitutes resolver outputs into production action text and executes that body.
- `Set-DeploymentDispatchFixture` — documented: caller selector plus event/payload identity.
- `gh` — existing verified: remaining-arguments stub permits exact publishing argument assertions.

#### ParallelExport.Tests.ps1

The outer `Expand-DataverseSolutionFile` is an existing-verified empty Pester
signature, including `MappingFile`, added upstream for `passes generated mapping
files to the solution unpack cmdlet`. No separate function comment is needed:
that test directly asserts the MappingFile binding. The runtime BeforeEach
replacement is documented because parent-runspace unpacking uses this seam
while thread workers import the implementation below.

All six following functions are embedded in the importable fixture module and
were reviewed without editing their source strings.

- `Get-DataverseConnection` — documented at containing fixture: returns shared default test client for worker connection ownership/warm-up tests.
- `Write-TestSolution` — documented at containing fixture: minimum unpacked Solution.xml for comparison and unchanged-version paths.
- `Export-DataverseSolution` — documented at containing fixture: Begin/End occupancy, shared release wait, controlled failure and file/folder output.
- `Expand-DataverseSolutionFile` — documented at containing fixture: delegates minimum unpacked solution creation; upstream added the MappingFile binding without changing this fake unpack behavior.
- `Compress-DataverseSolutionFile` — documented at containing fixture: writes comparison baseline marker, not a real solution archive.
- `Set-DataverseSolution` — documented at containing fixture: counts version updates across worker/runspace boundaries.

#### PipelineBuild.Tests.ps1

- `Compress-DataverseSolutionFile`, `Invoke-TestDotnet`, `Invoke-TestPac` (outer empty stubs) — existing verified: explicit Pester argument-inspection signatures.
- Embedded `Compress-DataverseSolutionFile` in `packs multiple solutions concurrently through real parallel runspaces` — documented outside fixture string: mutual started-file barrier forces actual runspace overlap; deadline bounds failure.
- Upstream embedded `Compress-DataverseSolutionFile` in `runs configured parallel build commands concurrently within the build limit` — documented outside fixture string: a deliberately simple pack-output writer with MappingFile binding, not the command-overlap probe. Its separate unnamed child script owns the two-marker barrier.
- Embedded `Export-ModuleMember` and module body — no additional comment needed beyond barrier/importable-module explanation.

#### PipelineCommon.Tests.ps1

- `Invoke-TestPac` — existing verified: empty area/operation signature for PAC call assertions.
- `Invoke-TestNativeCommand` — documented: splits returned output from simulated global native exit state.
- Embedded hook bodies (unnamed) — no comment needed: context echo and deliberate exception directly express hook contracts.

#### PipelineConnection.Tests.ps1

- `Invoke-ConnectionTestPac`, `Get-DataverseConnection` — existing verified: empty parameter-inspection signatures.
- `Get-DataverseWhoAmI` — no comment needed: empty discovery seam immediately replaced with success/failure mocks.

#### PipelineDependencies.Tests.ps1

- `dotnet` — existing verified: empty verb/operation/package signature for pinned CLI assertions.

#### PipelineDeployment.Tests.ps1

- `Write-DeploymentConfig` — documented: accepts literal per-solution syntax and disables worker packing for mock visibility.
- `Import-DataverseSolution`, `Invoke-DataverseSolutionUpgrade`, `Get-DataverseRecord`, `Set-DataverseRecord`, `Compress-DataverseSolutionFile`, `Invoke-DeploymentTestDotnet` — existing verified: empty cmdlet/native signatures with argument-inspection suppressions.
- `Publish-DataverseCustomizations` — existing verified: empty external-cmdlet seam with naming suppression preserving the real command name.

#### PipelineExport.Tests.ps1

- `Export-DataverseSolution`, `Compress-DataverseSolutionFile`, `Compare-DataverseSolutionComponents`, `Set-DataverseSolution`, `Register-AlmSolutionVersion`, `git` — existing verified: empty external/reservation seams; suppression justifications identify parameter inspection and external plural naming. Mock bodies define each case's behavior explicitly.

#### SetupEnvironment.Tests.ps1

- `Get-VSTeamServiceEndpoint` — existing verified: empty project-binding seam.
- `Get-DataverseConnection`, `Get-DataverseEnvironment`, `Get-DataverseRecord` — documented as fail-closed fallbacks: any unmocked call throws instead of accessing installed provider commands.
- `Set-DataverseRecord` — documented as fail-closed fallback with ShouldProcess boundary retained for pipeline writes and declined-operation tests.

#### SetupProviders.Tests.ps1

- `Get-DataverseEnvironment`, `Get-VSTeamServiceEndpoint`, `Get-VSTeamVariableGroup`, `Add-VSTeamVariableGroup`, `Initialize-AzDoVariableGroupExclusiveLock`, `Get-VSTeamBuildDefinition` — existing verified: empty signatures expose Pester bindings with precise suppression reasons.
- `Invoke-VSTeamRequest`, `Add-VSTeamServiceEndpoint`, `Remove-VSTeamServiceEndpoint` — documented: fail-closed provider boundaries, removal still honors ShouldProcess.
- `gh`, `git` in “Provider mutation guards” — no comment needed: explicit unexpected-call exceptions plus zero-call assertions define guards.
- `gh` in “GitHub credential writes” — no comment needed: explicit unmocked-call exception and per-case mock recording CLI arguments.
- `Invoke-GhApi` in “GitHub repository owner filtering” — existing verified: empty endpoint/AllowNotFound signature for provider result filtering.
- `git` in “Provider cleanup failure handling” — no comment needed: unmocked-call exception prevents real Git access.
- `Invoke-GhApi` in “Provider cleanup failure handling” — existing verified: empty endpoint/method/body/AllowNotFound signature supports PUT/DELETE cleanup routing.
- `Assert-GeneratedWorkflowActionlint` — documented: stdin content contract, optional local availability and required-CI prerequisite enforcement.
- `Assert-GeneratedAzurePipelineSchema` — documented: optional schema opt-out versus checked CI prerequisites, semantic validation beyond YAML parsing.

#### SetupRepository.Tests.ps1

- `git`, `gh` — documented: fail-closed external commands while generated file writes remain real.
- `Get-VSTeamProject`, `Get-VSTeamExtension`, `Install-VSTeamExtension` — no comment needed: empty discovery/installation seams mocked in lifecycle cases.
- `Set-VSTeamDefaultProject` — existing verified: ShouldProcess target plus explicit unexpected-live-configuration exception makes fallback contract clear.
- `Get-VSTeamBuildDefinition`, `Get-VSTeamGitRepository` — existing verified: empty provider signatures with Pester parameter justifications.
- `Add-VSTeamGitRepository` — existing verified: per-parameter mock justification and explicit unexpected-live-creation exception.

#### Validation.Tests.ps1

- Embedded `New-UnreviewedResource` — no comment needed: deliberately state-changing analyzer probe tests the rule remains enabled.
- Embedded `Parse-Things` — no comment needed: deliberately unapproved verb, unused parameter and empty catch supply the named analyzer regression findings.
- Embedded validator-entry body (unnamed) — documented at fixture copy: child process reports caught validation error and exits before recursive Pester invocation.

### Embedded C# named members

No C# string was modified; relevant fixture intent is documented outside strings.

- `ParallelExport.Tests.ps1`, `AlmExportTestClient`: `OrganizationDetail` getter,
  `Clone`, `Reset`, `BeginExport`, `AwaitRelease`, `EndExport`, `Dispose` —
  documented at containing fixture and barrier/cleanup sites. Reviewed metadata
  priming inheritance, static counter/event reset/disposal, Interlocked occupancy,
  locked peak update, bounded wait and owned-client disposal flag. Auto-properties
  `Default`, `Peak`, `VersionUpdates`, `Started`, `Release`, `DetailsRead`,
  `Disposed` need no separate commentary: their use in the barrier and assertions
  is direct.
- `PipelineBuild.Tests.ps1`, upstream `AlmBuildMappingTestCapture.MappingPath`
  and `AlmBuildMappingTestCapture.MappingXml` — documented outside their C#
  string: pack mocks snapshot generated mapping contents before production
  cleanup. The two static auto-property accessors need no individual comments;
  they store the exact values asserted after packing, not simulated SDK behavior.
- `PipelineExport.Tests.ps1`, upstream `AlmExportMappingTestCapture.MappingPath`,
  `AlmExportMappingTestCapture.MappingXml`,
  `AlmExportMappingTestCapture.CompressionMappingPaths` and
  `AlmExportMappingTestCapture.GitStatusArguments` — documented outside their C#
  string: snapshot mapping XML and record comparison/pathspec arguments before
  cleanup; BeforeEach clears both properties and both lists. Auto-property
  accessors and readonly list initialization need no separate commentary because
  the capture/reset/assertion sequence states the contract directly.
- `SetupCommon.Tests.ps1`: `Markup` constructor/`ToString`, `PanelHeader`
  constructor, `Panel` constructor/`ToString`, `TableColumn` constructor,
  `Table.AddColumn`, `Grid.AddRow`, `Columns` constructor,
  `SelectionPrompt<T>.AddChoice`/`ShowAsync`, `TextPrompt<T>.Show`,
  `StatusDisplay.Start`, `AnsiConsole.Status`/`MarkupLine`/`Write`/`Markup`/
  `Clear`/`Confirm`/`Ask<T>` — documented at containing fake Spectre fixture:
  capture supplied content/choices, consume queued answers, invoke callbacks,
  and support cancellation without real terminal interaction.
- `SetupCommon.Tests.ps1`: empty `Padding` constructor,
  `Grid.AddColumn()` and `Grid.AddColumn(GridColumn)`, `TextPrompt<T>`
  constructor, `AnsiConsole.WriteLine()`; constant-null `Style.Parse` —
  no comment needed individually: intentionally inert compatibility members in
  the documented fake rendering API. Empty `StatusContext` and `IRenderable`
  are shape-only types. Field-only `BoxBorder`/`GridColumn` and other fixture
  fields retain values inspected by wrapper tests.
- `SetupWizard.Tests.ps1`: embedded empty `AnsiConsole.MarkupLine` and
  `AnsiConsole.WriteLine` — documented outside fixture: minimal standalone
  no-op fallback, guarded to reuse an already-loaded richer fixture type.

### Related contracts checked

The approved plan's test guidance and manual-authorship boundary were read.
`docs\development\powershell.md` confirms suite boundaries, mock/runspace
isolation, setup diagnostic runner and coverage exclusions. The production
parallel-export client initialization explicitly primes `OrganizationDetail`
before cloning, matching the C# trap. Test fixture AST imports install function
bodies only, not provider installer startup. The action publishing helper reads
the current deploy action YAML rather than a copied algorithm. No statement here
asserts live-service integration coverage or a complete installer dry run.

### Caller and test evidence

The following identifies concrete consumers of the named helpers and fixtures;
the decisions above are based on those bodies and call sites, not names alone.
The final read-only AST inventory included nested definitions and separately
parsed PowerShell-bearing string literals. It matched every PowerShell symbol
listed above, including the two inline analyzer probes in Validation.

| File / symbols | Caller or test evidence supporting the assessment |
| --- | --- |
| BuildBaseline / `Invoke-BaselineFixture`, `git` | `validates a fixed BUILD run ID` passes selector 123 through a real config file to resolvebuildvalidationbaseline; annotated/legacy pointer cases route `git` by verb and TagType, and the missing-pointer case verifies exit state returns to zero. |
| Coverage / embedded `Get-FixtureValue` | Embedded `It 'returns its value'` directly invokes the imported command; outer `records execution of an imported module` requires nonzero total commands and 100 percent coverage read back from child-process JSON. |
| DependencyUpdates / `git`, `gh` | `creates a dependency PR and updates only its configured module version` asserts push/create/checkout calls; `recovers from an existing branch rebase failure` asserts abort, and the operation-failure matrix checks LASTEXITCODE. Empty signatures enable these parameter filters without real repository publication. |
| GitHubBuildBaseline / `gh`, embedded deploy entry point | `deploys a downloaded baseline before the candidate and removes temporary packages` checks both log entries, baseline-before-candidate order, one CLI download and no remaining baseline directories. Failed/missing-download cases require no deploy log. |
| GitHubDeployment / `Invoke-DeploymentTagStep`, `Set-DeploymentDispatchFixture`, `gh` | The publishing matrix calls both helpers after resolve-deployment and checks exact POST/DELETE arguments, annotation metadata and annotated-tag-object SHA. Gate failure must prevent any pointer move; dispatch selection cases consume the helper's repository payload. |
| ParallelExport / all six embedded PowerShell functions and `AlmExportTestClient` members | `bounds simultaneous operations to <Limit> and cleans up independent clients` starts real workers, waits for Started before reading Peak, then checks reclaimed operation slots, clone disposal and retained original connection. `preserves hooks, unchanged versions and summaries with parallel=<Parallel>` calls `Write-TestSolution` to seed a real Git baseline and checks zero version updates. Worker-failure case checks preserved multiline detail and budget recovery. |
| PipelineBuild / outer pack/dotnet/pac seams and embedded pack command | `packs solutions, copies assets/configuration, and locks actual installed versions` checks mocked pack arguments and parsed version locks. `packs multiple solutions concurrently through real parallel runspaces` provides the fixture module path and bypasses the parallel shim; the embedded command cannot finish until both marker files exist. Checker tests route `Invoke-TestPac` output to severity summaries and thresholds. |
| PipelineCommon / `Invoke-TestPac`, `Invoke-TestNativeCommand` | PAC authentication cases exercise create/select/who fallback and errors. Checked-native-command cases call the simulator with 0 or 7, check returned output, rejection and explicit AllowFailure. This is why the simulator changes global LASTEXITCODE but the fixture restores it afterward. |
| PipelineConnection / `Invoke-ConnectionTestPac`, `Get-DataverseConnection`, `Get-DataverseWhoAmI` | `authenticates PAC and verifies the default Dataverse connection` checks DefaultAzureCredential/SetAsDefault/Url and PAC identity verification; `propagates inaccessible identity failures` injects WhoAmI failure. Empty stubs are replaced before invocation. |
| PipelineDependencies / `dotnet` | Selector matrix calls installdependencies in the fixture directory, checks resolved RequiredVersion/AllowPrerelease, dotnet update and GITHUB_PATH content. Invalid selector requires zero dotnet calls. |
| PipelineDeployment / `Write-DeploymentConfig` and all seven external seams | Missing/false/null deployUnmanaged matrix passes literal Settings strings to the helper. Package/service-account matrix checks the selected archive and systemuser domainname. IMPORT case calls import.ps1, packs once and verifies unmanaged NoUpgrade without invoking the upgrade seam; the test restores native exit state in finally. |
| PipelineExport / all six empty signatures | `increments the revision for a first export` verifies unpack/pack, environment-version update and reservation arguments. Additive/removal matrix controls the component comparator. `leaves unchanged solution versions alone` returns empty Git status and requires no version update or reservation. Sequential fixture config keeps all seams in Pester's runspace. |
| SetupEnvironment / all five declared seams | Provider parameterized suites AST-load real installer functions without executing startup. `creates or reuses <Kind> users and their administrator association` invokes token callbacks through connection mocks and verifies record filters and CreateOnly writes. Discovery cases exercise callbacks separately; credential/editor cases check object identity and callback argument positions. |
| SetupProviders / discovery, variable-group and build-definition seams | Authentication-callback cases invoke the supplied token scriptblock with malformed and valid resources; lookup-failure cases distinguish 403/unclassified failure from confirmed 404 and require zero creation until absence is confirmed. Pipeline reconciliation cases inspect JSON payloads via the declared VSTeam signatures. |
| SetupProviders / fail-closed VSTeam writes and WhatIf `gh`/`git` | Parameterized mutation-guard block binds mandatory values only, invokes each selected production Helper with WhatIf, then asserts zero calls to authentication, prompts, filesystem and CLI commands. Endpoint reconciliation mocks the declared write/delete seams and checks drift-triggered deletion/recreation. |
| SetupProviders / credential-write `gh`, both `Invoke-GhApi` stubs and cleanup `git` | Credential-write matrix records exact CLI body/repository arguments and checks thrown native failures restore error preference. Owner-filter cases consume mixed-owner API results. Cleanup cases combine original clone failure with cleanup failure, and PUT/DELETE probe routing with success/failure outcomes and nonsensitive diagnostics. |
| SetupProviders / `Assert-GeneratedWorkflowActionlint` | Both build-validation and deployment-generation cases pass current generated content to the helper after YAML parsing. Prerequisite block enforces ACTIONLINT_REQUIRED before optional-local helper return can occur. Newline-stability case separately checks LF/CRLF/mixed payload idempotence without changing those strings. |
| SetupProviders / `Assert-GeneratedAzurePipelineSchema` | Build/deploy generation case passes each generated path after YAML parsing; semantic-invalid-pipeline case verifies schema rejection independently of syntax. The prerequisite block checks required schema/language-service/Node availability; missing local schema explicitly skips the semantic-negative case. |
| SetupRepository / all nine declared stubs | Selection cases use Get/Add repository seams; lifecycle cases exercise project/extension discovery and installation. Working-tree cases simulate clone/checkout failures and inspect actual fixture folder removal, location and preference restoration. Publication cases write real generated config/workflows while Git/gh mocks control branch/diff/PR state, including zero commit/PR for unchanged content. |
| SetupCommon / embedded Spectre members | Prompt cases enqueue answers, then assert escaped-menu mapping, cancellation/back signaling, secret whitespace and defaults. Rendering cases inspect fake renderable properties/output. Status regression deliberately throws from output-panel rendering after mutating shared execution state and requires exactly one callback execution with preserved result. |
| SetupWizard / embedded no-op console members | Provider branch-aware suites mock rendering and provisioning while invoking real orchestration bodies. `executes standalone environment-step contracts before branch editing` replaces Invoke-SetupWizard, skips its first action, executes remaining actions and throws a sentinel before normal orchestration continues; it then checks solutions/baseline/review calls. |
| Validation / embedded `New-UnreviewedResource`, `Parse-Things`, unnamed child entry | Exception-policy case analyzes the unreviewed mutating function and requires one ShouldProcess finding. Rule-policy case analyzes Parse-Things and requires verb/unused/empty-catch findings but no host-output finding. Enforcement cases copy source and launch the child entry to ensure analyzer or stale-exception failure occurs before nested Pester. |
| helpers\Invoke-SetupTests.ps1 / script entry | `docs\development\powershell.md` invokes it for all setup suites or a selected repository-relative TestPath. Its body resolves against repoRoot, reports all three setup files and fails on empty runs, failed tests or failed containers. Focused execution against SetupWizard completed successfully. |

### Initial validation before upstream integration

- PowerShell parser: all 25 assigned files passed.
- Read-only outer/embedded AST inventory and ledger-name check: all 72
  PowerShell function definitions accounted for, including repeated scoped names.
- Ordered non-comment/non-newline token comparison against HEAD: all 25 files
  identical, 33,308 tokens. Here-string/string token text was included, preserving
  executable fixtures as well as outer assertions (line endings normalized for
  the Git-content comparison).
- `git diff --check -- tests`: passed. The diff contains added comment lines
  only, with no removed/replaced test lines.
- Pester 5.7.1 focused invocation of `ParallelExport.Tests.ps1` and
  `PipelineBuild.Tests.ps1`: successful, 42 tests discovered; failure/empty-run
  checks did not fire.
- `tests\helpers\Invoke-SetupTests.ps1 -TestPath tests\SetupWizard.Tests.ps1`:
  successful, including the helper's coverage reporting and nonempty/failure
  checks. The helper's generated root `coverage.xml` was removed afterward.
- No implementation issues identified in this commenting review. No commits,
  pushes or delegation. Full suite and repository-wide gates remain owned by
  the parent task.

#### Parent pre-integration full-suite result and provider-specific skip limitation

Before integrating upstream `4aa15e7`, the parent reported 525 passed, 8 skipped,
no failures, with all
coverage gates passing. These eight skips are pre-existing conditional
`-Skip` expressions in suites expanded for both GitHub and Azure DevOps. They
select the applicable provider, not the operating system or runner platform;
they are not unconditional disabled tests and were not introduced by this
comment-only review. Each listed test runs for its applicable provider while
the other provider's expanded instance is skipped.

| File | Exact test name | Existing skip condition and scope |
| --- | --- | --- |
| SetupEnvironment.Tests.ps1 | `rejects duplicate target URLs or short names in add and edit callbacks` | `$Provider -eq 'GitHub'`: Azure DevOps editor callbacks only. |
| SetupEnvironment.Tests.ps1 | `prepopulates existing stages and completes missing configuration` | `$Provider -eq 'GitHub'`: Azure DevOps stage prepopulation only. |
| SetupEnvironment.Tests.ps1 | `refreshes outdated GitHub federated settings rather than adding another credential` | `$Provider -ne 'GitHub'`: GitHub federated-credential refresh only. |
| SetupEnvironment.Tests.ps1 | `recognizes unprefixed repository variables and prefers active-environment values` | `$Provider -ne 'GitHub'`: GitHub repository-variable discovery only. |
| SetupEnvironment.Tests.ps1 | `writes bare repository variable names when preserving unprefixed storage` | `$Provider -ne 'GitHub'`: GitHub repository-variable storage only. |
| SetupRepository.Tests.ps1 | `creates a project and resolves conflicting extension mode before installing dependencies` | `$Provider -ne 'Azure DevOps'`: Azure DevOps project/extension lifecycle only. |
| SetupRepository.Tests.ps1 | `updates an existing GitHub pull request rather than creating another` | `$Provider -ne 'GitHub'`: GitHub PR update only. |
| SetupWizard.Tests.ps1 | `keeps default-branch workflow availability and retires removed branch deployment workflows` | `$Provider -ne 'GitHub'`: GitHub workflow retirement/publication only. |

These results do not establish equivalent behavior for the skipped provider
instances, live services, or other operating systems. The separate
missing-Azure-schema local skip path is not one of these eight reported skips.

### Upstream integration assessment: 4aa15e7

The merge brought #97's inline mapping/build-command tests from
`1b29582..origin/main` into five already-reviewed suites. Those upstream diffs
and their embedded fixtures were read individually; selected comments were
updated or added without changing upstream executable tokens. The original
33,308-token and 72-definition inventory and focused/full-suite results above
describe the pre-integration review, not the expanded merged suite. Final
full validation is rerun by the parent.

#### Added and changed fixture/caller evidence

| File / exact fixture or symbol | Decision and evidence |
| --- | --- |
| ParallelExport.Tests.ps1 / outer `Expand-DataverseSolutionFile` | Existing verified: empty signature with MappingFile and unused-parameter justification supports `passes generated mapping files to the solution unpack cmdlet`. The assertion checks forwarding by `Expand-AlmExportSolution`; no extra function comment is needed. Runtime mock replacement is documented to distinguish parent-runspace unpacking from embedded worker-module unpacking. |
| ParallelExport.Tests.ps1 / embedded `Expand-DataverseSolutionFile` | Existing fixture explanation verified with upstream MappingFile parameter: still delegates to `Write-TestSolution`; it accepts mapping calls without simulating packager directive processing. No added comment inside the immutable string. |
| PipelineBuild.Tests.ps1 / `AlmBuildMappingTestCapture.MappingPath`, `MappingXml`, outer `Compress-DataverseSolutionFile` | Documented snapshot lifetime: the mock reads MappingFile while it exists, and `generates mapping XML in entry order with all supported directive types` inspects captured XML plus the subsequently deleted path. MappingFile in Get-Command's Parameters represents installed-command capability, independently of the synthetic installed-version string used for lock-file assertions. |
| PipelineBuild.Tests.ps1 / `Invoke-TestPac` | Existing verified: added remaining-arguments binding remains an empty Pester signature. Mapping tests assert zero PAC calls; solution-check tests still route area/operation output through this seam. No new PAC fallback behavior is claimed. |
| PipelineBuild.Tests.ps1 / parallel-stage fixture | Documented revised flow: both `runs configured parallel build commands concurrently within the build limit` and the existing pack-overlap case opt out of the in-runspace shim. `ALM_BUILD_TEST_PARALLEL_COMMAND_STAGE` records entry into command-plan parallel processing in the default-path test and is restored from the saved environment; this marker alone does not prove overlap. |
| PipelineBuild.Tests.ps1 / unnamed `build-command-worker.ps1` fixture | Documented: each child writes its own marker and must see both markers within ten seconds. It proves native build-command overlap separately from the later pack-worker barrier; this script uses the current process executable rather than relying on PATH for its child PowerShell. The finally block restores module-path/real-parallel environment overrides. |
| PipelineBuild.Tests.ps1 / embedded `Compress-DataverseSolutionFile` under command-overlap test | Documented: writes a pack marker only, accepts MappingFile, and is exported by the real fixture module so packing can complete in its own worker. This is a separate occurrence from the older identically named embedded pack-overlap function. No per-statement narration needed. |
| PipelineBuild.Tests.ps1 / unnamed `create-mapped-plugin.ps1` fixture | No extra comment needed: its three statements create the output directory and file. `runs a mapping buildCommand before validating its generated source file` configures the initially absent generated source and asserts both created content and captured mapping XML; the regression ordering is already explicit in the test name and assertions. |
| PipelineBuild.Tests.ps1 / command settings fixtures | No additional comments needed for `runs build commands in parallel by default before packing`, `runs an individually sequential build command without a nested parallel stage`, `fails the build when a configured build command exits unsuccessfully` and `rejects malformed build command arguments before running commands`: per-mapping parallel flags, explicit exit 7, malformed scalar arguments and zero-pack assertions state their differences directly. None of these fixtures were altered. |
| PipelineBuild.Tests.ps1 / directive and capability fixtures | Documented ampersand paths because they test XML attribute escaping in addition to ordered FileToFile/Folder/FileToPath elements. No additional comments needed for missing MappingFile capability, retired mappingFile/buildCommands settings, unsupported directive type or missing source: test names and pre-pack/zero-PAC assertions state those boundaries directly. Production build runs command plans before mapping-source existence validation and packing. |
| PipelineDependencies.Tests.ps1 / version fixtures | No comment needed: Install-Module/Get-Module results, exact-selector cases and locked RequiredVersion assertions were coherently advanced upstream from 3.0.4-preview.1 to 3.2.1-preview.1. This is the dependency-minimum fixture; the build suite's independent synthetic 3.0.4 lock-file snapshot was preserved exactly, not incorrectly rewritten as the new minimum. |
| PipelineExport.Tests.ps1 / `AlmExportMappingTestCapture` members and outer export/pack/git signatures | Documented generated-file snapshot/reset and call recording. `Export-DataverseSolution` and `Compress-DataverseSolutionFile` now accept MappingFile; `git` adds RemainingArguments with a specific suppression justification. Both lists and both properties are reset per case, preventing earlier mapping records from satisfying later assertions. |
| PipelineExport.Tests.ps1 / `uses inline mappings during sequential export without running build commands` | Documented deliberately unavailable `missing-build-tool`: EXPORT must use the mapping while leaving per-mapping BUILD work unexecuted. The source already exists, and captured XML plus post-return deletion verify real generated-file lifetime. No comment was inserted into the configuration string. |
| PipelineExport.Tests.ps1 / `detects changes to mapped source files outside the solution directory` | Documented pathspec-sensitive Git mock: it returns a change only when RemainingArguments includes plugins/Example.dll; unconditional status output would miss a regression in source-path selection. Assertions verify that argument, old/new compression, comparison and revised solution version. |
| PipelineExport.Tests.ps1 / duplicate-name and comparison fixtures | No extra comments needed: duplicate exact/case-varied names must fail before export/pack or mapping-path capture. `uses inline mappings for old and new packages when comparing export changes` explicitly checks both pack invocations receive mappings, records both paths and requires generated-file deletion. |
| SetupCommon.Tests.ps1 / `preserves existing per-solution mappings and custom properties when replacing selections` | Documented intentionally mixed legacy/current config. Fixture includes removed solution-level mappingFile/buildCommands, supported inline mapping/buildCommand, customSetting and an unselected solution. Setter assertions require preservation of inline/custom values, updated deployUnmanaged, deletion of legacy keys and removal of unselected records. Production `Set-AlmConfigSolutionsInFile` preserves retained source extents but excludes name/deployUnmanaged/mappingFile/buildCommands from copied properties. No string payload changed. |

#### Integration validation

- All five auto-merged test files parse successfully.
- Ordered executable-token comparison against `origin/main`: all five identical,
  9,157 tokens, including literal strings and here-string bodies (Git/file line
  endings normalized for comparison).
- `git diff --check -- tests` passed.
- No staging, commits, pushes or full-suite execution by this review task.
- Parent owns the final merged-suite validation and updated coverage results.
