# Repository Guidelines

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
