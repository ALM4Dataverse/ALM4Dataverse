![ALM4Dataverse](logo.png)

This repo contains:
- an advanced and extendable application lifecycle management (ALM/CI-CD)
implementation for Dataverse.
- a set of process documentation and guidance on how to use and extend it.

Supports both **Azure DevOps** and **GitHub Actions** (PREVIEW).

Features:

- Handles zero to many Dataverse solutions per repo.
- Correctly determines the install/upgrade/update method for each solution based on the state of the target environment
- Supports branches, PRs etc with minimal re-configuration
- Supports including config/system/lookup data
- Easy to extend using the extensive PowerShell ecosystem.


## Getting Started

### GitHub Actions

1) Run the automated setup script in Windows PowerShell:

   ```powershell
   iwr https://github.com/ALM4Dataverse/ALM4Dataverse/releases/latest/download/setup-github.ps1 | iex
   ```

    The setup script automatically detects whether GitHub environment approvals are
    available for your repository and chooses the matching deployment strategy
    (`environment-approval` or `manual-gate-tag` with prefixed repo-level credentials).

   Or follow the [GitHub Actions Setup Guide](docs/setup/github-setup.md) to configure manually.

### Azure DevOps

1) Run the automated setup script in Windows PowerShell:

   ```powershell
   iwr https://github.com/ALM4Dataverse/ALM4Dataverse/releases/latest/download/setup-azdo.ps1 | iex
   ```

   Or follow the [Manual Setup Guide](docs/setup/azdo-manual-setup.md) if you prefer manual configuration.
   See the [Automated Setup Guide](docs/setup/azdo-automated-setup.md) for details.


## Documentation

- [Frequently asked question](docs/faqs.md)

### Initial Setup

#### GitHub Actions
- [GitHub Actions Setup Guide](docs/setup/github-setup.md)
- [GitHub Actions Automated Setup](docs/setup/github-automated-setup.md)

#### Azure DevOps
- [Azure DevOps Organization Requirements](docs/setup/azdo-organisation-requirements.md)
- [Automated Setup](docs/setup/azdo-automated-setup.md)
- [Manual Setup](docs/setup/azdo-manual-setup.md)

#### Usage Instructions

- [Exporting changes](docs/usage/exporting-changes.md) - `EXPORT` pipeline/workflow
  Capturing changes from your dev environments into source control.
- [Building releases](docs/usage/building-releases.md) - `BUILD` pipeline/workflow
  Generating release assets for later deployment.
- [Deploying](docs/usage/deploying.md) -`DEPLOY-<branchname>` pipeline/workflow
  Deploying release assets to environments in a controlled sequence
- [Importing changes](docs/usage/importing-changes.md) - `IMPORT` pipeline/workflow
  Seeding or updating dev environment from source control.

### Configuration Reference

- [ALM Configuration](docs/config/alm-config.md) - `alm-config.psd1`

#### GitHub Actions
- [GitHub Secrets & Variables](docs/config/github-secrets.md)

#### Azure DevOps
- [Environment Variable Group](docs/config/azdo-environment-variable-group.md)
- [Service Connection Configuration](docs/config/azdo-environment-service-connection.md)

#### Example 'Hook' Extensions

- [Data import and export](config/example-hooks/data-import-export.md) (for example config/system data)
- [Organization/environment settings](config/example-hooks/organization-settings.md) (for example enabling the 'PCF allowed' switch)