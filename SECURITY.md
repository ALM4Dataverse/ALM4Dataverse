# Security Policy

## Reporting A Vulnerability

Please report security problems privately, not in a public issue, discussion or pull
request.

Use GitHub's private reporting: open the repository's **Security** tab, select
**Report a vulnerability**, and describe the problem. Include the shared ref or release
you used, the platform (Azure DevOps or GitHub Actions), the steps to reproduce it, and
its impact.

Don't include real credentials, tokens, tenant or environment identifiers, or customer
data. Replace them with placeholders; maintainers will ask for anything else they need.

Maintainers will acknowledge the report, agree a fix and disclosure timeline with you,
and credit you in the advisory unless you prefer otherwise.

## Supported Versions

Fixes are made on `main` and published in a new release. Older releases aren't patched.
Existing build artifacts keep the deployment scripts they were built with, so you must
upgrade and rebuild to pick up a fix; see [updating](docs/usage/updating.md).

## Scope

In scope: the shared scripts, Azure DevOps templates, GitHub actions, setup scripts and
the files they copy into application repositories.

Out of scope: weaknesses in Microsoft Dataverse, Power Platform, Azure DevOps or GitHub
themselves (report those to the vendor), and the configuration of your own environments,
identities and approvals. [Responsibilities and limits](docs/concepts/responsibilities.md)
describes what ALM4Dataverse does and doesn't protect.

## If You Exposed A Secret

If a client secret, token or connection string was committed or printed in a log,
revoke or rotate it at its source first, then remove it from history and logs. See
[rotating credentials](docs/usage/updating.md#rotate-credentials-and-review-access).
