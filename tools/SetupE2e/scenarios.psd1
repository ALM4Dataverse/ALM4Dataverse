@{
    # Scenarios are recorded interactions with the real setup scripts. Add steps in
    # the order the operator sees them; every Wait text must appear on screen.
    # Select moves the highlight to a matching item before pressing Enter, so
    # scenarios do not depend on account-specific list ordering.
    'azdo-smoke' = @{
        Provider    = 'azdo'
        Description = 'Starts Azure DevOps setup and stops at the repository mode choice without signing in.'
        Steps       = @(
            @{ Action = 'Wait'; Text = 'Set up a new application repository'; TimeoutSeconds = 180 }
            @{ Action = 'Capture'; Label = 'mode-choice' }
            @{ Action = 'Note'; Text = 'Smoke scenario reached the first prompt; start a separate interactive run to drive setup.' }
        )
    }

    # Requires a disposable project: the scenario creates pipelines, environments,
    # service connections and variable groups and reuses the signed-in account.
    'azdo-new-repository' = @{
        Provider    = 'azdo'
        Description = 'Creates a new application repository with main+develop environments, TestSolution1, and direct publication.'
        Steps       = @(
            @{ Action = 'Wait'; Text = 'Set up a new application repository' }
            @{ Action = 'Select'; Text = 'Set up a new application repository' }
            @{ Action = 'Wait'; Text = 'Use existing Azure login' }
            @{ Action = 'Select'; Text = 'Use existing Azure login' }
            @{ Action = 'Wait'; Text = 'Select an Azure DevOps organization' }
            @{ Action = 'Select'; Text = '{{azdo.organization}}' }
            @{ Action = 'Wait'; Text = 'Select the target Azure DevOps project' }
            @{ Action = 'Select'; Text = '{{azdo.project}}' }
            @{ Action = 'Wait'; Text = 'Select the main repository' }
            @{ Action = 'Select'; Text = 'Create a new repository' }
            @{ Action = 'Wait'; Text = 'Enter the name for the new main repository' }
            @{ Action = 'Type'; Text = '{{azdo.applicationRepositoryName}}' }
            @{ Action = 'Keys'; Keys = '{ENTER}' }
            @{ Action = 'Wait'; Text = 'Use ALM4Dataverse AzDO extension' }
            @{ Action = 'Keys'; Keys = '{ENTER}' }
            @{ Action = 'Wait'; Text = 'Select the shared repository' }
            @{ Action = 'Select'; Text = 'Use existing repository: {{azdo.sharedRepositoryName}}' }
            @{ Action = 'Wait'; Text = 'Azure DevOps ALM4Dataverse setup menu'; TimeoutSeconds = 300 }
            @{ Action = 'Select'; Text = 'Check and update shared repository version' }
            @{ Action = 'Wait'; Text = 'Check and update shared repository' }
            @{ Action = 'Keys'; Keys = '{ENTER}' }
            @{ Action = 'Wait'; Text = 'Azure DevOps ALM4Dataverse setup menu'; TimeoutSeconds = 300 }
            @{ Action = 'Select'; Text = 'Configure branches, dev and deployment envs' }
            @{ Action = 'Wait'; Text = 'Choose a branching strategy' }
            @{ Action = 'Select'; Text = 'main + develop' }
            @{ Action = 'Wait'; Text = "Configure a DEV environment for branch 'main'" }
            @{ Action = 'Keys'; Keys = 'n{ENTER}' }
            @{ Action = 'Wait'; Text = "Target Deployment Environments for branch 'main'" }
            @{ Action = 'Select'; Text = 'Add an environment' }
            @{ Action = 'Wait'; Text = 'Configure a deployment environment menu' }
            @{ Action = 'Select'; Text = 'Dataverse environment' }
            @{ Action = 'Wait'; Text = '{{dataverse.prod.name}} -' }
            @{ Action = 'Select'; Text = '{{dataverse.prod.name}}' }
            @{ Action = 'Wait'; Text = 'Configure a deployment environment menu' }
            @{ Action = 'Select'; Text = 'Short name' }
            @{ Action = 'Wait'; Text = 'Enter a short name for this environment' }
            @{ Action = 'Type'; Text = 'PROD' }
            @{ Action = 'Keys'; Keys = '{ENTER}' }
            @{ Action = 'Wait'; Text = 'Credentials - Not configured' }
            @{ Action = 'Select'; Text = 'Credentials' }
            @{ Action = 'Wait'; Text = "Select Service Principal credentials for 'PROD'" }
            @{ Action = 'Select'; Text = 'Create new App Registration' }
            @{ Action = 'Wait'; Text = 'Select authentication type for the new service connection' }
            @{ Action = 'Select'; Text = 'Workload Identity Federation' }
            @{ Action = 'Wait'; Text = 'Credentials - WIF' }
            @{ Action = 'Select'; Text = 'Service account' }
            @{ Action = 'Wait'; Text = "Select Dataverse Service Account for 'PROD'" }
            @{ Action = 'Keys'; Keys = '{ENTER}' }
            @{ Action = 'Wait'; Text = 'Service Account UPN' }
            @{ Action = 'Type'; Text = '{{serviceAccount}}' }
            @{ Action = 'Keys'; Keys = '{ENTER}' }
            @{ Action = 'Wait'; Text = 'Done - Ready' }
            @{ Action = 'Select'; Text = 'Done - Ready' }
            @{ Action = 'Wait'; Text = "Target Deployment Environments for branch 'main'" }
            @{ Action = 'Select'; Text = 'Done' }
            @{ Action = 'Wait'; Text = "Configure a DEV environment for branch 'develop'" }
            @{ Action = 'Keys'; Keys = '{ENTER}' }
            @{ Action = 'Wait'; Text = "Configure DEV environment for branch 'develop' menu" }
            @{ Action = 'Select'; Text = 'Dataverse environment' }
            @{ Action = 'Wait'; Text = '{{dataverse.dev.name}} -' }
            @{ Action = 'Select'; Text = '{{dataverse.dev.name}}' }
            @{ Action = 'Wait'; Text = "Configure DEV environment for branch 'develop' menu" }
            @{ Action = 'Select'; Text = 'Credentials' }
            @{ Action = 'Wait'; Text = "Select Service Principal credentials for 'Dev-develop'" }
            @{ Action = 'Select'; Text = 'Create new App Registration' }
            @{ Action = 'Wait'; Text = 'Select authentication type for the new service connection' }
            @{ Action = 'Select'; Text = 'Workload Identity Federation' }
            @{ Action = 'Wait'; Text = 'Credentials - WIF' }
            @{ Action = 'Select'; Text = 'Service account' }
            @{ Action = 'Wait'; Text = "Select Dataverse Service Account for 'Dev-develop'" }
            @{ Action = 'Keys'; Keys = '{ENTER}' }
            @{ Action = 'Wait'; Text = 'Service Account UPN' }
            @{ Action = 'Type'; Text = '{{serviceAccount}}' }
            @{ Action = 'Keys'; Keys = '{ENTER}' }
            @{ Action = 'Wait'; Text = 'Done - Ready' }
            @{ Action = 'Select'; Text = 'Done - Ready' }
            @{ Action = 'Wait'; Text = "Target Deployment Environments for branch 'develop'" }
            @{ Action = 'Select'; Text = 'Add an environment' }
            @{ Action = 'Wait'; Text = 'Configure a deployment environment menu' }
            @{ Action = 'Select'; Text = 'Dataverse environment' }
            @{ Action = 'Wait'; Text = '{{dataverse.test.name}} -' }
            @{ Action = 'Select'; Text = '{{dataverse.test.name}}' }
            @{ Action = 'Wait'; Text = 'Configure a deployment environment menu' }
            @{ Action = 'Select'; Text = 'Short name' }
            @{ Action = 'Wait'; Text = 'Enter a short name for this environment' }
            @{ Action = 'Type'; Text = 'TEST' }
            @{ Action = 'Keys'; Keys = '{ENTER}' }
            @{ Action = 'Wait'; Text = 'Credentials - Not configured' }
            @{ Action = 'Select'; Text = 'Credentials' }
            @{ Action = 'Wait'; Text = "Select Service Principal credentials for 'TEST'" }
            @{ Action = 'Select'; Text = 'Create new App Registration' }
            @{ Action = 'Wait'; Text = 'Select authentication type for the new service connection' }
            @{ Action = 'Select'; Text = 'Workload Identity Federation' }
            @{ Action = 'Wait'; Text = 'Credentials - WIF' }
            @{ Action = 'Select'; Text = 'Service account' }
            @{ Action = 'Wait'; Text = "Select Dataverse Service Account for 'TEST'" }
            @{ Action = 'Keys'; Keys = '{ENTER}' }
            @{ Action = 'Wait'; Text = 'Service Account UPN' }
            @{ Action = 'Type'; Text = '{{serviceAccount}}' }
            @{ Action = 'Keys'; Keys = '{ENTER}' }
            @{ Action = 'Wait'; Text = 'Done - Ready' }
            @{ Action = 'Select'; Text = 'Done - Ready' }
            @{ Action = 'Wait'; Text = "Target Deployment Environments for branch 'develop'" }
            @{ Action = 'Select'; Text = 'Done' }
            @{ Action = 'Wait'; Text = "Enable Dataverse deployment validation during BUILD for branch 'main'" }
            @{ Action = 'Keys'; Keys = '{ENTER}' }
            @{ Action = 'Wait'; Text = "Enable Dataverse deployment validation during BUILD for branch 'develop'" }
            @{ Action = 'Keys'; Keys = '{ENTER}' }
            @{ Action = 'Wait'; Text = 'Configure deployment branch mappings' }
            @{ Action = 'Select'; Text = 'Done' }
            @{ Action = 'Wait'; Text = 'Azure DevOps ALM4Dataverse setup menu'; TimeoutSeconds = 300 }
            @{ Action = 'Select'; Text = 'Configure solutions' }
            @{ Action = 'Wait'; Text = 'Select your DEV environment' }
            @{ Action = 'Select'; Text = 'Use existing environment: {{dataverse.dev.name}}' }
            @{ Action = 'Wait'; Text = 'No solutions selected yet'; TimeoutSeconds = 300 }
            @{ Action = 'Select'; Text = 'Add a solution' }
            @{ Action = 'Wait'; Text = 'Select a solution to add' }
            @{ Action = 'Select'; Text = '{{solutionName}}' }
            @{ Action = 'Wait'; Text = 'Selected solutions' }
            @{ Action = 'Select'; Text = 'Done' }
            @{ Action = 'Wait'; Text = 'Azure DevOps ALM4Dataverse setup menu'; TimeoutSeconds = 300 }
            @{ Action = 'Select'; Text = 'Choose publication method' }
            @{ Action = 'Wait'; Text = 'Which branch should receive the Azure DevOps changes' }
            @{ Action = 'Select'; Text = "Commit to 'develop'" }
            @{ Action = 'Wait'; Text = 'How should the Azure DevOps changes for branch' }
            @{ Action = 'Select'; Text = "Commit directly to 'develop'" }
            @{ Action = 'Wait'; Text = 'Azure DevOps ALM4Dataverse setup menu'; TimeoutSeconds = 300 }
            @{ Action = 'Capture'; Label = 'ready-to-apply' }
            @{ Action = 'Select'; Text = 'Apply changes' }
            @{ Action = 'Wait'; Text = 'Ready to open'; TimeoutSeconds = 1200 }
            @{ Action = 'Capture'; Label = 'setup-complete' }
        )
    }

    # Requires the configured application repository to exist with no ALM4Dataverse
    # settings, and the shared repository fork to be disposable. App Registration
    # creation writes to Entra ID immediately and is not deferred until Apply.
    'github-existing-repository' = @{
        Provider    = 'github'
        Description = 'Configures an existing empty GitHub repository with main+develop environments, TestSolution1, WIF credentials, and direct publication to develop.'
        Steps       = @(
            @{ Action = 'Wait'; Text = 'Configure an existing repository'; TimeoutSeconds = 180 }
            @{ Action = 'Select'; Text = 'Configure an existing repository' }
            @{ Action = 'Wait'; Text = 'Use existing GitHub login' }
            @{ Action = 'Select'; Text = 'Use existing GitHub login' }
            @{ Action = 'Wait'; Text = 'Use existing Azure login' }
            @{ Action = 'Select'; Text = 'Use existing Azure login' }
            @{ Action = 'Wait'; Text = 'Select the repository to set up ALM4Dataverse in'; TimeoutSeconds = 120 }
            @{ Action = 'Select'; Text = 'Use existing repository: {{github.owner}}/{{github.applicationRepository}}' }
            @{ Action = 'Wait'; Text = 'GitHub Actions ALM4Dataverse setup menu'; TimeoutSeconds = 600 }
            @{ Action = 'Select'; Text = 'Select shared workflow repository' }
            @{ Action = 'Wait'; Text = 'Select shared workflow repository'; TimeoutSeconds = 180 }
            @{ Action = 'Select'; Text = 'Use existing fork: {{github.sharedRepository}}' }
            @{ Action = 'Wait'; Text = 'GitHub Actions ALM4Dataverse setup menu'; TimeoutSeconds = 600 }
            @{ Action = 'Select'; Text = 'Check and update shared workflow repository version' }
            @{ Action = 'Sleep'; Milliseconds = 2000 }
            @{ Action = 'Wait'; Text = 'GitHub Actions ALM4Dataverse setup menu'; TimeoutSeconds = 600 }

            @{ Action = 'Select'; Text = 'Configure branches, dev and deployment envs' }
            @{ Action = 'Wait'; Text = 'Configure deployment branch mappings'; TimeoutSeconds = 60 }
            @{ Action = 'Select'; Text = 'Add a branch mapping' }
            @{ Action = 'Wait'; Text = 'Branch name' }
            @{ Action = 'Type'; Text = 'develop' }
            @{ Action = 'Keys'; Keys = '{ENTER}' }
            @{ Action = 'Wait'; Text = "Configure a DEV Dataverse environment for branch 'develop'" }
            @{ Action = 'Type'; Text = 'y' }
            @{ Action = 'Keys'; Keys = '{ENTER}' }
            @{ Action = 'Wait'; Text = "Configure DEV environment for branch 'develop' menu" }
            @{ Action = 'Select'; Text = 'Dataverse environment' }
            @{ Action = 'Wait'; Text = "Select the DEV Dataverse environment for branch 'develop'" }
            @{ Action = 'Select'; Text = '{{dataverse.dev.name}} (' }
            @{ Action = 'Wait'; Text = 'Credentials - Not configured' }
            @{ Action = 'Select'; Text = 'Credentials' }
            @{ Action = 'Wait'; Text = "Select App Registration credentials for 'Dev-develop'" }
            @{ Action = 'Keys'; Keys = '{ENTER}' }
            @{ Action = 'Wait'; Text = 'Select authentication type for the new App Registration' }
            @{ Action = 'Keys'; Keys = '{ENTER}' }
            @{ Action = 'Wait'; Text = 'Credentials - WIF - {{github.applicationRepository}} - Dev-develop - deployment'; TimeoutSeconds = 180 }
            @{ Action = 'Sleep'; Milliseconds = 1000 }
            @{ Action = 'Select'; Text = 'Service account' }
            @{ Action = 'Wait'; Text = "Select Dataverse Service Account for 'Dev-develop'" }
            @{ Action = 'Keys'; Keys = '{ENTER}' }
            @{ Action = 'Wait'; Text = 'Service Account UPN' }
            @{ Action = 'Type'; Text = '{{serviceAccount}}' }
            @{ Action = 'Keys'; Keys = '{ENTER}' }
            @{ Action = 'Wait'; Text = 'Done - Ready' }
            @{ Action = 'Select'; Text = 'Done - Ready' }
            @{ Action = 'Sleep'; Milliseconds = 2000 }
            @{ Action = 'Wait'; Text = "Target deployment environments for branch 'develop'" }
            @{ Action = 'Select'; Text = 'Add an environment' }
            @{ Action = 'Wait'; Text = "Configure deployment environment for branch 'develop' menu" }
            @{ Action = 'Select'; Text = 'Dataverse environment' }
            @{ Action = 'Wait'; Text = "Select a Dataverse environment for branch 'develop'" }
            @{ Action = 'Select'; Text = '{{dataverse.test.name}} (' }
            @{ Action = 'Wait'; Text = "Configure deployment environment for branch 'develop' menu" }
            @{ Action = 'Select'; Text = 'Short name' }
            @{ Action = 'Wait'; Text = 'Enter a short name for this environment' }
            @{ Action = 'Type'; Text = 'TEST' }
            @{ Action = 'Keys'; Keys = '{ENTER}' }
            @{ Action = 'Wait'; Text = 'Credentials - Not configured' }
            @{ Action = 'Select'; Text = 'Credentials' }
            @{ Action = 'Wait'; Text = "Select App Registration credentials for 'TEST'" }
            @{ Action = 'Keys'; Keys = '{ENTER}' }
            @{ Action = 'Wait'; Text = 'Select authentication type for the new App Registration' }
            @{ Action = 'Keys'; Keys = '{ENTER}' }
            @{ Action = 'Wait'; Text = 'Credentials - WIF - {{github.applicationRepository}} - TEST - deployment'; TimeoutSeconds = 180 }
            @{ Action = 'Sleep'; Milliseconds = 1000 }
            @{ Action = 'Select'; Text = 'Service account' }
            @{ Action = 'Wait'; Text = "Select Dataverse Service Account for 'TEST'" }
            @{ Action = 'Keys'; Keys = '{ENTER}' }
            @{ Action = 'Wait'; Text = 'Service Account UPN' }
            @{ Action = 'Type'; Text = '{{serviceAccount}}' }
            @{ Action = 'Keys'; Keys = '{ENTER}' }
            @{ Action = 'Wait'; Text = 'Done - Ready' }
            @{ Action = 'Select'; Text = 'Done - Ready' }
            @{ Action = 'Sleep'; Milliseconds = 2000 }
            @{ Action = 'Wait'; Text = "Target deployment environments for branch 'develop'" }
            @{ Action = 'Select'; Text = 'Done' }
            @{ Action = 'Wait'; Text = "Enable Dataverse deployment validation during BUILD for branch 'develop'" }
            @{ Action = 'Type'; Text = 'n' }
            @{ Action = 'Keys'; Keys = '{ENTER}' }
            @{ Action = 'Wait'; Text = 'Configure deployment branch mappings' }

            @{ Action = 'Select'; Text = 'Edit a branch mapping' }
            @{ Action = 'Wait'; Text = 'Select branch mapping to edit' }
            @{ Action = 'Select'; Text = 'main' }
            @{ Action = 'Wait'; Text = 'Edit deployment environments' }
            @{ Action = 'Select'; Text = 'Edit deployment environments' }
            @{ Action = 'Wait'; Text = "Target deployment environments for branch 'main'" }
            @{ Action = 'Select'; Text = 'Add an environment' }
            @{ Action = 'Wait'; Text = "Configure deployment environment for branch 'main' menu" }
            @{ Action = 'Select'; Text = 'Dataverse environment' }
            @{ Action = 'Wait'; Text = "Select a Dataverse environment for branch 'main'" }
            @{ Action = 'Select'; Text = '{{dataverse.prod.name}} (' }
            @{ Action = 'Wait'; Text = "Configure deployment environment for branch 'main' menu" }
            @{ Action = 'Select'; Text = 'Short name' }
            @{ Action = 'Wait'; Text = 'Enter a short name for this environment' }
            @{ Action = 'Type'; Text = 'PROD' }
            @{ Action = 'Keys'; Keys = '{ENTER}' }
            @{ Action = 'Wait'; Text = 'Credentials - Not configured' }
            @{ Action = 'Select'; Text = 'Credentials' }
            @{ Action = 'Wait'; Text = "Select App Registration credentials for 'PROD'" }
            @{ Action = 'Keys'; Keys = '{ENTER}' }
            @{ Action = 'Wait'; Text = 'Select authentication type for the new App Registration' }
            @{ Action = 'Keys'; Keys = '{ENTER}' }
            @{ Action = 'Wait'; Text = 'Credentials - WIF - {{github.applicationRepository}} - PROD - deployment'; TimeoutSeconds = 180 }
            @{ Action = 'Sleep'; Milliseconds = 1000 }
            @{ Action = 'Select'; Text = 'Service account' }
            @{ Action = 'Wait'; Text = "Select Dataverse Service Account for 'PROD'" }
            @{ Action = 'Keys'; Keys = '{ENTER}' }
            @{ Action = 'Wait'; Text = 'Service Account UPN' }
            @{ Action = 'Type'; Text = '{{serviceAccount}}' }
            @{ Action = 'Keys'; Keys = '{ENTER}' }
            @{ Action = 'Wait'; Text = 'Done - Ready' }
            @{ Action = 'Select'; Text = 'Done - Ready' }
            @{ Action = 'Sleep'; Milliseconds = 2000 }
            @{ Action = 'Wait'; Text = "Target deployment environments for branch 'main'" }
            @{ Action = 'Select'; Text = 'Done' }
            @{ Action = 'Wait'; Text = 'Edit deployment environments' }
            @{ Action = 'Sleep'; Milliseconds = 2000 }
            @{ Action = 'Select'; Text = 'Done' }
            @{ Action = 'Wait'; Text = 'Configure deployment branch mappings' }
            @{ Action = 'Select'; Text = 'Done' }
            @{ Action = 'Wait'; Text = 'GitHub Actions ALM4Dataverse setup menu'; TimeoutSeconds = 600 }

            @{ Action = 'Select'; Text = 'Configure solutions' }
            @{ Action = 'Wait'; Text = 'Select your DEV environment' }
            @{ Action = 'Select'; Text = 'Use existing environment: {{dataverse.dev.name}}' }
            @{ Action = 'Wait'; Text = 'Configure solution order'; TimeoutSeconds = 300 }
            @{ Action = 'Select'; Text = 'Add a solution' }
            @{ Action = 'Wait'; Text = 'Select a solution to add' }
            @{ Action = 'Select'; Text = '{{solutionName}}' }
            @{ Action = 'Wait'; Text = 'Configure solution order' }
            @{ Action = 'Select'; Text = 'Done' }
            @{ Action = 'Wait'; Text = 'GitHub Actions ALM4Dataverse setup menu'; TimeoutSeconds = 600 }

            @{ Action = 'Select'; Text = 'Configure GitHub OIDC identity' }
            @{ Action = 'AnswerIfPresent'; Text = 'Enable immutable GitHub OIDC subjects for'; Type = 'y'; TimeoutSeconds = 15 }
            @{ Action = 'Sleep'; Milliseconds = 1000 }
            @{ Action = 'Wait'; Text = 'GitHub Actions ALM4Dataverse setup menu'; TimeoutSeconds = 600 }

            @{ Action = 'Select'; Text = 'Choose publication method' }
            @{ Action = 'Wait'; Text = 'Which branch should receive the GitHub changes' }
            @{ Action = 'Select'; Text = "Commit to 'develop'" }
            @{ Action = 'Wait'; Text = 'How should the GitHub changes for branch' }
            @{ Action = 'Select'; Text = "Commit directly to 'develop'" }
            @{ Action = 'Wait'; Text = 'GitHub Actions ALM4Dataverse setup menu'; TimeoutSeconds = 600 }
            @{ Action = 'Capture'; Label = 'ready-to-apply' }

            @{ Action = 'Select'; Text = 'Apply changes' }
            @{ Action = 'Wait'; Text = 'Review setup changes'; TimeoutSeconds = 1200 }
            @{ Action = 'Select'; Text = 'Done reviewing' }
            @{ Action = 'Wait'; Text = 'Ready to open'; TimeoutSeconds = 1800 }
            @{ Action = 'Capture'; Label = 'setup-complete' }
        )
    }
}
