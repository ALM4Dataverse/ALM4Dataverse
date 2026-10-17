# Instructions for AI Agents

This application repository uses [ALM4Dataverse](https://github.com/ALM4Dataverse/ALM4Dataverse)
to export, build, and deploy Microsoft Dataverse solutions. Application-specific
configuration, unpacked solutions, source projects, and hooks belong in this repository;
the shared automation and detailed guides live in the ALM4Dataverse repository.

Before adding or changing Dataverse components or ALM configuration:

1. Read the task guide for [adding solutions, plug-ins, web resources, and Code Apps](https://github.com/ALM4Dataverse/ALM4Dataverse/blob/main/docs/usage/adding-dataverse-components.md).
2. Check the [ALM configuration reference](https://github.com/ALM4Dataverse/ALM4Dataverse/blob/main/docs/config/alm-config.md) and the relevant [export](https://github.com/ALM4Dataverse/ALM4Dataverse/blob/main/docs/usage/exporting-changes.md), [build](https://github.com/ALM4Dataverse/ALM4Dataverse/blob/main/docs/usage/building-releases.md), or [deployment](https://github.com/ALM4Dataverse/ALM4Dataverse/blob/main/docs/usage/deploying.md) guide.
3. Use and extend the solution list and mappings in `alm-config.psd1`. Dataverse components must be part of a solution; the `assets` setting only copies extra files into the build artifact.

Prefer the shared documentation and the repository's existing configuration over
assumptions. Do not add credentials or environment-specific secrets to source control.
