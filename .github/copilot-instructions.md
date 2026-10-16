# Repository Guidelines

## Comments and Help

Follow the [commenting standard](../docs/development/powershell.md#commenting-standard).
Write each comment individually after reading its implementation and relevant
callers/tests; never script-generate or bulk-insert commentary. Explain contracts
and non-obvious reasons, not readable statements. Review embedded code and generated
sources without changing executable content. Update comments when behavior changes.

## Pull Request Descriptions

When creating or updating a pull request, keep end-user information separate from implementation details:

- Use `## End-user changes` for observable behavior, configuration options, and user impact in plain language.
- Use `## Implementation details` for internal design, compatibility handling, and test implementation.
- Use `## Validation` for commands and results, including any failures or known limitations.
- Do not mix internal mechanics into the end-user section. Omit a section only when there is nothing relevant to report.
