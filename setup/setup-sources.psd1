@{
    Common = @(
        'common/console-runtime-and-rendering.ps1'
        'common/file-change-review.ps1'
        'common/wizard-context-and-flow.ps1'
        'common/prompt-interaction.ps1'
        'common/setup-input-and-guidance.ps1'
        'common/change-planning.ps1'
        'common/solution-configuration.ps1'
        'common/alm-config-reading-and-settings.ps1'
        'common/branch-environment-selection.ps1'
        'common/branch-validation-mapping.ps1'
        'common/module-management.ps1'
        'common/setup-progress.ps1'
        'common/authentication.ps1'
    )
    AzDoBootstrap = @(
        'azdo/bootstrap.ps1'
    )
    AzDo = @(
        'azdo/organization-and-project-setup.ps1'
        'azdo/repository-selection-and-import.ps1'
        'azdo/environment-repository-selection-and-scaffolding.ps1'
        'azdo/pipeline-and-environment-provisioning.ps1'
        'azdo/identity-and-variable-groups.ps1'
        'azdo/repository-setup-state.ps1'
        'azdo/branch-environment-selection.ps1'
        'azdo/pipeline-and-pull-request-publication.ps1'
        'azdo/branch-setup-preview-and-apply.ps1'
        'azdo/branch-aware-setup.ps1'
    )
    GitHubBootstrap = @(
        'github/bootstrap.ps1'
    )
    GitHub = @(
        'github/repository-api-and-access.ps1'
        'github/repository-setup-state.ps1'
        'github/repository-forks-and-creation.ps1'
        'github/identity-provisioning.ps1'
        'github/dataverse-environment-and-configuration.ps1'
        'github/workflow-template-updates.ps1'
        'github/repository-publication-and-setup-artifacts.ps1'
        'github/shared-workflow-repository.ps1'
        'github/branch-aware-setup.ps1'
    )
}
