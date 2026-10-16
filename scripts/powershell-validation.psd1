@{
    # Local validation and CI import these exact versions to keep findings comparable.
    Tools = @{
        Pester = '5.7.1'
        PSScriptAnalyzer = '1.24.0'
        'powershell-yaml' = '0.4.12'
    }
    AnalyzerSettings = @{
        IncludeDefaultRules = $true
        ExcludeRules = @(
            'PSAvoidUsingWriteHost'
        )
    }
    # Each tuple must match exactly once. Source is executable text, not a line number;
    # do not refresh entries just to hide new findings or stale suppressions.
    Exceptions = @(
        @{
            Path = 'setup-azdo.ps1'
            Rule = 'PSAvoidUsingPlainTextForPassword'
            Function = 'Add-EntraIdFederatedCredential'
            Source = '[Parameter(Mandatory)][string]$CredentialName'
            Reason = 'This is the display name of a federated identity credential, not a secret.'
        }
        @{
            Path = 'setup-github.ps1'
            Rule = 'PSAvoidUsingPlainTextForPassword'
            Function = 'Add-EntraIdFederatedCredential'
            Source = '[Parameter(Mandatory)][string]$CredentialName'
            Reason = 'This is the display name of a federated identity credential, not a secret.'
        }
        @{
            Path = 'setup-common.ps1'
            Rule = 'PSAvoidUsingPlainTextForPassword'
            Function = 'Get-CredentialSummaryText'
            Source = '[Parameter()]$Credentials'
            Reason = 'This public helper consumes a structured authentication configuration. Changing its object contract requires a separate credential-handling audit.'
        }
        @{
            Path = 'setup-github.ps1'
            Rule = 'PSAvoidUsingPlainTextForPassword'
            Function = 'Set-GitHubPrefixedEnvironmentCredential'
            Source = '[Parameter(Mandatory)][object]$Credentials'
            Reason = 'The setup API consumes structured authentication configuration for GitHub credential provisioning; SecureString is not a compatible replacement.'
        }
        @{
            Path = 'setup-github.ps1'
            Rule = 'PSAvoidUsingPlainTextForPassword'
            Function = 'Get-GitHubCredentialsForEnvironment'
            Source = '[Parameter()][object]$ExistingCredential'
            Reason = 'This is existing authentication configuration including non-secret identity metadata; changing its object contract requires a separate audit.'
        }
        @{
            Path = 'setup-github.ps1'
            Rule = 'PSAvoidUsingPlainTextForPassword'
            Function = 'Get-GitHubEnvironmentConfiguration'
            Source = '[Parameter()][object]$ExistingCredential'
            Reason = 'This is existing authentication configuration including non-secret identity metadata; changing its object contract requires a separate audit.'
        }
        @{
            Path = 'setup-azdo.ps1'
            Rule = 'PSAvoidUsingPlainTextForPassword'
            Function = 'Get-PowerPlatformSCCredential'
            Source = '[Parameter()][object]$ExistingCredential'
            Reason = 'This is existing service-connection authentication configuration; changing its object contract requires a separate audit.'
        }
        @{
            Path = 'setup-azdo.ps1'
            Rule = 'PSAvoidUsingPlainTextForPassword'
            Function = 'Get-AzDoEnvironmentConfiguration'
            Source = '[Parameter()][object]$ExistingCredential'
            Reason = 'This is existing service-connection authentication configuration; changing its object contract requires a separate audit.'
        }
        @{
            Path = 'setup-azdo.ps1'
            Rule = 'PSAvoidUsingConvertToSecureStringWithPlainText'
            Function = '<script>'
            Source = 'ConvertTo-SecureString -String $adoAccessToken.Token -AsPlainText -Force'
            Reason = 'The existing OAuth API supplies a plaintext access token; conversion adapts it to the downstream SecureString contract, not a hardcoded secret.'
        }
        @{
            Path = 'setup-common.ps1'
            Rule = 'PSUseShouldProcessForStateChangingFunctions'
            Function = 'New-SpectreTable'
            Source = 'New-SpectreTable'
            Reason = 'Builds a transient console table. Console dependency initialization is a rendering prerequisite, not a user-selected provisioning operation.'
        }
        @{
            Path = 'setup-common.ps1'
            Rule = 'PSUseShouldProcessForStateChangingFunctions'
            Function = 'New-SpectrePanel'
            Source = 'New-SpectrePanel'
            Reason = 'Builds a transient console panel. Console dependency initialization is a rendering prerequisite, not a user-selected provisioning operation.'
        }
        @{
            Path = 'setup-common.ps1'
            Rule = 'PSUseShouldProcessForStateChangingFunctions'
            Function = 'New-SpectreInfoGrid'
            Source = 'New-SpectreInfoGrid'
            Reason = 'Builds a transient console grid. Console dependency initialization is a rendering prerequisite, not a user-selected provisioning operation.'
        }
        @{
            Path = 'setup-common.ps1'
            Rule = 'PSUseShouldProcessForStateChangingFunctions'
            Function = 'New-SpectreMetricColumn'
            Source = 'New-SpectreMetricColumn'
            Reason = 'Builds transient console renderables. Console dependency initialization is a rendering prerequisite, not a user-selected provisioning operation.'
        }
        @{
            Path = 'setup-common.ps1'
            Rule = 'PSUseShouldProcessForStateChangingFunctions'
            Function = 'Set-SetupWizardContext'
            Source = 'Set-SetupWizardContext'
            Reason = 'Updates only script-local UI state needed to render the wizard; it does not change repository or service configuration.'
        }
        @{
            Path = 'setup-common.ps1'
            Rule = 'PSUseShouldProcessForStateChangingFunctions'
            Function = 'Set-SetupPhaseContext'
            Source = 'Set-SetupPhaseContext'
            Reason = 'Updates only script-local UI state needed to render the wizard; it does not change repository or service configuration.'
        }
        @{
            Path = 'setup-common.ps1'
            Rule = 'PSUseShouldProcessForStateChangingFunctions'
            Function = 'Set-SetupPromptDocContext'
            Source = 'Set-SetupPromptDocContext'
            Reason = 'Updates only script-local prompt metadata; it does not change repository or service configuration.'
        }
        @{
            Path = 'setup-common.ps1'
            Rule = 'PSUseShouldProcessForStateChangingFunctions'
            Function = 'New-SetupHeroPanel'
            Source = 'New-SetupHeroPanel'
            Reason = 'Formats console heading text. Console dependency initialization is a rendering prerequisite, not a user-selected provisioning operation.'
        }
        @{
            Path = 'setup-common.ps1'
            Rule = 'PSUseShouldProcessForStateChangingFunctions'
            Function = 'New-SetupTipsPanel'
            Source = 'New-SetupTipsPanel'
            Reason = 'Builds a transient console tips panel. Console dependency initialization is a rendering prerequisite, not a user-selected provisioning operation.'
        }
        @{
            Path = 'setup-common.ps1'
            Rule = 'PSUseShouldProcessForStateChangingFunctions'
            Function = 'Remove-SetupConsoleCancelHandler'
            Source = 'Remove-SetupConsoleCancelHandler'
            Reason = 'Detaches a process-local event handler during cleanup. Confirmation must not leave the handler attached after a prompt completes.'
        }
        @{
            Path = 'setup-azdo.ps1'
            Rule = 'PSUseShouldProcessForStateChangingFunctions'
            Function = 'New-AzDoBranchSetupState'
            Source = 'New-AzDoBranchSetupState'
            Reason = 'Returns an in-memory branch-selection object without changing a repository or service.'
        }
        @{
            Path = 'setup-github.ps1'
            Rule = 'PSUseShouldProcessForStateChangingFunctions'
            Function = 'New-GitHubBranchSetupState'
            Source = 'New-GitHubBranchSetupState'
            Reason = 'Returns an in-memory branch-selection object without changing a repository or service.'
        }
        @{
            Path = 'setup-github.ps1'
            Rule = 'PSUseShouldProcessForStateChangingFunctions'
            Function = 'New-GitHubEnvironmentWifSubject'
            Source = 'New-GitHubEnvironmentWifSubject'
            Reason = 'Formats and returns an OIDC subject string; it does not provision a federated identity credential.'
        }
        @{
            Path = 'pipelines/scripts/build.ps1'
            Rule = 'PSUseShouldProcessForStateChangingFunctions'
            Function = 'New-SolutionCheckSeverityCount'
            Source = 'New-SolutionCheckSeverityCount'
            Reason = 'Returns an in-memory severity counter dictionary; it does not change build artifacts or service configuration.'
        }
        @{
            Path = 'pipelines/scripts/build.ps1'
            Rule = 'PSUseShouldProcessForStateChangingFunctions'
            Function = 'New-Count'
            Source = 'New-Count'
            Reason = 'Returns an in-memory severity counter dictionary inside the parallel worker; it does not change build artifacts or service configuration.'
        }
        @{
            Path = 'tests/GitHubDeployment.Tests.ps1'
            Rule = 'PSUseShouldProcessForStateChangingFunctions'
            Function = 'Set-DeploymentDispatchFixture'
            Source = 'Set-DeploymentDispatchFixture'
            Reason = 'Sets isolated test environment values that AfterEach restores. Confirmation would prevent deterministic fixture setup.'
        }
        @{
            Path = 'tests/PipelineDeployment.Tests.ps1'
            Rule = 'PSUseShouldProcessForStateChangingFunctions'
            Function = 'Set-DataverseRecord'
            Source = 'Set-DataverseRecord'
            Reason = 'An empty local command stub for Pester mocks; it performs no Dataverse request or mutation.'
        }
        @{
            Path = 'tests/PipelineExport.Tests.ps1'
            Rule = 'PSUseShouldProcessForStateChangingFunctions'
            Function = 'Set-DataverseSolution'
            Source = 'Set-DataverseSolution'
            Reason = 'An empty local command stub for Pester mocks; it performs no Dataverse request or mutation.'
        }
    )
}