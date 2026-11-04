# Contributing To ALM4Dataverse

Thanks for helping. This page explains how to raise problems, propose changes and get a
pull request merged.

## Questions, Bugs And Ideas

- **Questions and "how do I" help:** start a
  [discussion](https://github.com/ALM4Dataverse/ALM4Dataverse/discussions). Check the
  [FAQs](docs/faqs.md) and [troubleshooting](docs/usage/troubleshooting.md) first.
- **Bugs:** open an issue using the bug template. Include the shared ref, platform,
  operation and the first failing log lines, with secrets and identifiers removed.
- **Feature ideas:** open an issue using the feature template and describe the problem
  before the solution. Say whether configuration or a hook could already solve it.
- **Security problems:** don't open an issue; follow the [security policy](SECURITY.md).

## Before You Start A Change

For anything larger than a small fix, open an issue or discussion first so the approach
can be agreed. Many needs are met without changing shared code, by configuration, a
[hook](docs/usage/writing-hooks.md) or a fork's defaults; see the
[smallest extension point](docs/usage/updating.md#choose-the-smallest-extension-point).

Read the [maintainer guide](docs/maintainers.md) for the source map. One user-visible
contract usually spans the runtime script, the Azure DevOps template, the GitHub action,
the copied callers, the setup generators and the reference docs. Change them together,
for both platforms.

## Set Up And Run The Checks

You need PowerShell 7.2 or newer and Git. No Dataverse or CI credentials are needed:
the tests mock every external service.

```powershell
$policy = Import-PowerShellDataFile ./scripts/powershell-validation.psd1
foreach ($tool in $policy.Tools.GetEnumerator()) {
    Install-Module -Name $tool.Key -RequiredVersion $tool.Value -Repository PSGallery -Scope CurrentUser -Force
}

./scripts/Test-PowerShell.ps1
./.github/scripts/test-documentation.ps1
git diff --check
```

`Test-PowerShell.ps1` runs syntax and analyzer checks, every Pester suite, and the
coverage gate: each `.ps1` or `.psm1` file you add or modify needs at least 65% command
coverage across the whole file. See [PowerShell development](docs/development/powershell.md)
for test organization, analyzer policy and coverage details.

Don't run setup, release or dependency-update scripts against real organizations as a
test; they change real resources.

## Write The Change

- **Tests:** add or update Pester tests for every behavior change, including failure
  and missing-setting cases under strict mode.
- **Comments and help:** follow the
  [commenting standard](docs/development/powershell.md#commenting-standard). Write each
  comment by hand after reading the code, its callers and its tests.
- **Documentation:** update the affected guide and reference pages in the same pull
  request. Keep guides task-focused, keep exhaustive detail in `docs/config`, and link
  rather than repeat facts. Don't rename existing documentation files; setup output and
  application repositories link to them.
- **Upgrade impact:** if users must do something when they upgrade, add an entry to
  [upgrade notes](docs/usage/upgrade-notes.md).
- **No secrets:** never commit credentials, tokens or real tenant, environment or user
  identifiers, including in tests and examples.

## Open The Pull Request

Describe the change in three sections:

- `## End-user changes`: observable behavior, configuration options and user impact,
  in plain language.
- `## Implementation details`: internal design, compatibility handling and tests.
- `## Validation`: the commands you ran and their results, including failures or known
  limitations.

Omit a section only when it has nothing to report. Maintainers review every pull
request; code written with AI assistance gets the same review.

## License

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).
