# Glossary

Terms used throughout the ALM4Dataverse documentation. Several common words, such as
"environment", have more than one meaning here; this page says which is which.

## Environments

- **Dataverse environment**: a Power Platform environment with a Dataverse database,
  identified by its URL, for example `https://contoso-test.crm.dynamics.com`. EXPORT reads
  from it; DEPLOY and IMPORT change it. ALM4Dataverse never creates one.
- **Target**: the Dataverse environment an operation changes, together with the CI
  settings that point at it.
- **GitHub environment**: a named set of GitHub Actions variables, secrets and protection
  rules, such as `Dev-main` or `PROD`. Its `DATAVERSE_URL` variable selects the Dataverse
  environment.
- **Azure DevOps environment**: a pipeline resource that records deployment history and
  can hold approval checks. It holds no credentials or settings; those live in a service
  connection and a variable group with the same name.
- **Development environment**: the Dataverse environment makers use for a branch, named
  `Dev-<branch>` by convention. See
  [branch and environment names](../usage/branching-strategies.md#branch-and-environment-names).
- **BUILD validation environment**: an optional non-production Dataverse environment that
  BUILD deploys every candidate package to. It is updated in place and shared by all branches.

## Identities

- **Setup identity**: your own account, used only while running the setup scripts.
- **Entra app registration** (application identity, service principal): the identity
  pipelines authenticate as, using a client secret or workload identity federation.
- **Application user**: the Dataverse user record for the app registration in each
  environment. It needs a security role, normally System Administrator, to import solutions.
- **Service account** (process owner): a real, licensed Dataverse user, identified by
  `DataverseServiceAccountUpn`, who owns and activates flows and workflows after
  deployment. It is not the application user.
- **WIF / OIDC**: workload identity federation. The CI platform presents a short-lived
  token that Entra trusts, so no client secret is stored. Recommended where available.

## Operations

- **EXPORT**: copies the configured solutions (and optional data) from a development
  environment into the branch, increments changed solution versions, and commits.
- **BUILD**: packs a source commit into a numbered, deployable package (the artifact),
  optionally running Solution Checker and deployment validation.
- **DEPLOY**: installs an existing successful build's artifact into one or more targets,
  in order. It never rebuilds.
- **IMPORT**: builds the current branch and installs it unmanaged into the development
  environment, to seed or synchronize it.
- **Hook**: a PowerShell script you register to run at a fixed point in an operation.
  See [Writing hooks](../usage/writing-hooks.md).

## Packages And Versions

- **Artifact** (build package): the output of BUILD. It contains packed solutions,
  assets, the configuration, a snapshot of the shared deployment scripts, and a
  dependency lock. On GitHub it is also attached to a prerelease as `artifacts.zip`.
- **Build identity**: the exact build being deployed, such as an Azure DevOps run or a
  GitHub Release tag, BUILD name or run ID. Promote by build identity, not solution version.
- **BUILD version**: the SemVer version of a build, such as `1.0.42-main`, made from the
  branch's MAJOR.MINOR, the run number and the branch name. Every build keeps the suffix.
- **Solution version**: the four-part Dataverse version of one solution, such as
  `1.4.0.7`. EXPORT increments it; one build can contain solutions at different versions.
- **Managed / unmanaged**: BUILD packs both. DEPLOY installs managed by default; IMPORT
  always installs unmanaged.
- **Update / upgrade**: DEPLOY updates a solution in place when its Major.Minor version is
  unchanged, and stages an upgrade otherwise. Upgrades can remove components and data.
- **Assets**: extra repository folders copied into the artifact, typically data and the
  deployment hooks that use it.
- **Mapping**: a SolutionPackager rule that injects a file built from source, such as a
  plug-in assembly or web resource, into a solution when it is packed.

## Tags And Promotion

- **Deployment pointer**: the movable Git tag `deployed/<environment>`, recording the last
  build successfully deployed to a target. Used to select BUILD validation baselines.
- **Baseline**: a previous build that BUILD validation installs before the candidate, to
  test the upgrade path a real target will take.
- **Gate tag**: in GitHub `manual-gate-tag` promotion, a tag recording that a build
  succeeded in a stage. The next stage requires it. It records order, not approval.
- **Reservation / content claim**: append-only tags that stop two branches using the same
  solution version, or one version identifying different package content. See the
  [Git tag catalog](../config/git-tags.md).

## Repositories

- **Application repository**: your repository, holding solution source, `alm-config.psd1`,
  data, hooks and small caller files. See [application repository layout](application-repository.md).
- **Shared repository**: ALM4Dataverse itself, or your fork, holding the reusable scripts,
  templates and actions. Azure DevOps imports a copy into your project; GitHub callers
  reference it directly.
- **Caller**: the small workflow or pipeline file in your application repository that
  triggers an operation and passes its settings to the shared implementation.
