# Git Tag Catalog

This catalog covers tags created or consumed in an application repository
(`origin`) by its pipelines and workflows: solution version reservations,
package-content claims, build identity, and deployment tracking. Shared
ALM4Dataverse repository refs used to select the automation source, and tags
used only by workflows running in that shared repository, are outside this
catalog.

## Tag inventory

| Tag pattern | Created by | Purpose and behavior |
| --- | --- | --- |
| `alm4dv/solution-version/<solution>/<version>` | EXPORT, Azure DevOps and GitHub Actions | Lightweight, append-only reservation for a solution version. Points to the source `HEAD` from which EXPORT is running. A collision advances the candidate version; a failed push is retried only when another export won the same reservation. |
| `alm4dv/solution-content/<lowercase-solution>/<version>` | BUILD, Azure DevOps and GitHub Actions | Annotated, append-only claim associating a solution version with the SHA-256 fingerprint of its packaged ZIP content. Identical content may reuse the version; different content under that version fails the build. Used when the version-collision guard is enabled. |
| `v<major>.<minor>.<run>-<branch>` | BUILD, Azure DevOps and GitHub Actions | Annotated source-build identity tag. Its branch suffix is normalized for SemVer/Git-ref use; the tag points to the exact source commit packaged by that BUILD. GitHub also uses this tag for its prerelease Release. |
| `deployed/<environment>` | Successful DEPLOY, Azure DevOps and GitHub Actions | Movable, annotated pointer to the source commit and BUILD identity last deployed to that environment. Used by `@<environment>` BUILD validation baselines. GitHub also records the BUILD Release tag. |
| `deployed/<build-key>/<environment>` | Successful DEPLOY, GitHub Actions only | Per-BUILD/per-environment deployment gate in `manual-gate-tag` promotion mode. A later stage checks that the predecessor-stage tag exists before deploying. Not used in `environment-approval` mode or by Azure DevOps. |
| `alm4dataverse/metadata/<release-tag>` | GitHub Release cleanup workflow | Durable annotated metadata record created before a managed Release is deleted. Preserves the build name, branch, source commit, run ID, and original Release tag, but **does not preserve Release assets**. |

The `alm4dv/...` and BUILD identity patterns are shared by both pipeline
providers. GitHub deployment gates and Release-metadata tags are GitHub-specific.
Azure DevOps does not create GitHub Releases or per-BUILD promotion gates.

## Solution version reservation

During EXPORT, the candidate solution version is reserved remotely using the
`alm4dv/solution-version/<solution>/<version>` lightweight tag. The tag points
to the checked-out source `HEAD`; it records that the version number has been
claimed, not that the later Dataverse update completed successfully. If the
remote already has that reservation, EXPORT advances the version according to
the configured additive/non-additive versioning behavior and tries again.
Concurrent exports are resolved by the remote tag creation race.

These reservation tags are not cleaned up by the Release-cleanup workflow. A
local reservation that exists without a corresponding remote tag is treated as
a conflict and must be reconciled before EXPORT can continue.

## Solution content claim

When BUILD's version-collision guard is enabled, BUILD fingerprints the
packaged ZIP content after checks pass and claims the solution/version pair
with an annotated `alm4dv/solution-content/<lowercase-solution>/<version>` tag.
The annotation contains:

```text
ALM4Dataverse-Solution-Content-SHA256: <64 lowercase hexadecimal characters>
```

The remote tag is the shared claim: a later build can reuse that solution
version only if the recorded fingerprint matches. An existing lightweight,
unrecognized, or mismatched claim fails rather than silently accepting
ambiguous content. For a mismatch, increment the solution version before
building. These claims are not the same as EXPORT's version-reservation tags;
historical reservation tags alone cannot establish the content of packages
published before the guard was enabled.

## BUILD source identity and GitHub Releases

BUILD derives a SemVer prerelease version from the configured version line, CI
run number, and normalized branch name. The resulting source tag has the form
`v<version>`, for example `v2.1.42-main` or `v1.0.43-feat-abc`. The tag is
annotated and points to the source commit used to create the artifacts.

The source tag is created late in BUILD after artifact generation and checks.
A rerun can reuse the tag only when it resolves to the same source commit;
BUILD fails rather than moving a tag that identifies a different commit. On
GitHub, this tag also identifies the BUILD prerelease Release and its
`artifacts.zip` asset. Azure DevOps publishes pipeline artifacts and the same
source tag, but does not create a GitHub Release.

## Deployment pointers and gates

After a deployment succeeds, each provider moves the annotated
`deployed/<environment>` pointer to the deployed BUILD source commit. Its
message records the build identity, run ID, and source commit; GitHub also
records the BUILD Release tag. This pointer is used by BUILD validation's
`@<environment>` baseline selector to identify the most recently deployed
BUILD. When a pointer is absent, baseline validation skips the baseline and
validates the candidate only; errors other than a genuinely missing pointer
still fail validation.

GitHub DEPLOY additionally supports two promotion modes:

- `manual-gate-tag` creates `deployed/<build-key>/<environment>` after a
  successful stage. The next stage requires the prior stage's gate for the
  same build. The gate tags are append-only evidence and are not the current
  environment pointer.
- `environment-approval` relies on GitHub Environment protection and does
  not create or check per-build gate tags. The `deployed/<environment>`
  pointer is still updated after success in either mode.

Do not manually create a gate to bypass a failed deployment, or move an
environment pointer without reconciling it with the actual Dataverse state.
The pointer and gate tags are operational records, not substitutes for
deployment verification.

## GitHub Release cleanup and retention

The cleanup workflow operates only on Releases with complete ALM build
metadata. Before deleting a managed Release, it writes or reuses the
annotated `alm4dataverse/metadata/<release-tag>` companion tag. Deployment
pointer tags under `deployed/` protect their referenced Releases from cleanup.
The metadata tag allows deployment selection to recover build identity after
the Release or its Actions run is no longer available, but it cannot restore
deleted Release assets.

Cleanup does not remove source BUILD tags, solution reservation/content
claims, gate tags, or Actions artifacts. See [GitHub Release cleanup](../usage/building-releases.md#github-release-cleanup)
for the retention rules and limitations.

## Operational guidance

- Treat solution reservation tags, solution content claims, BUILD source tags,
  and metadata tags as durable records. Do not move or delete them to resolve
  a deployment issue.
- Only `deployed/<environment>` is designed to move. Its writers need
  permission to create and force-update Git tags.
- BUILD and EXPORT identities need permission to publish their respective
  tags. GitHub BUILD/DEPLOY and cleanup callers need `contents: write` for
  their GitHub tag and Release operations.
- Do not retag a BUILD version to point to a different source commit.
- For current deployment and recovery behavior, see [Deployment tags](../usage/deploying.md#deployment-tags)
  and [BUILD validation baselines](../usage/building-releases.md#optional-baseline-release).
