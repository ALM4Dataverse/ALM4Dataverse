BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repoRoot 'pipelines/scripts/common.ps1')
    . (Join-Path $repoRoot 'setup-common.ps1')
}

Describe 'Setup status callback state' {
    BeforeAll {
        if (-not ('Spectre.Console.AnsiConsole' -as [type])) {
            Add-Type -TypeDefinition @'
namespace Spectre.Console {
    public class StatusContext {}
    public class Style {
        public static object Parse(string value) { return null; }
    }
    public class StatusDisplay {
        public bool AutoRefresh { get; set; }
        public object SpinnerStyle { get; set; }
        public object Start(string status, System.Func<StatusContext, object> callback) {
            return callback(new StatusContext());
        }
    }
    public static class AnsiConsole {
        public static StatusDisplay Status() { return new StatusDisplay(); }
    }
}
'@
        }
    }

    It 'does not repeat a completed operation when the output panel fails' {
        Mock Initialize-SpectreConsole {}
        Mock Show-SetupActivityOutputPanel { throw 'Display failed' }
        $executionState = @{ Count = 0 }
        $result = Invoke-WithSpectreStatus -Status 'Test operation' -CaptureOutputInPanel -ScriptBlock {
            $executionState.Count++
            [pscustomobject]@{ Value = 42 }
        }
        $executionState.Count | Should -Be 1
        $result.Value | Should -Be 42
    }
}

Describe 'Setup configuration and validation helpers' {
    It 'declares the emitted branch-mapping element type for both strategies' -ForEach @(
        @{ Strategy = 'Simple'; ExpectedCount = 1 }
        @{ Strategy = 'GitflowLike'; ExpectedCount = 3 }
    ) {
        $environment = [pscustomobject]@{ ShortName = 'prod'; FriendlyName = 'Production' }
        $mappings = @(Get-DefaultBranchEnvironmentMappingsFromStrategy -Strategy $Strategy -EnvironmentConfigurations @($environment))
        $mappings.Count | Should -Be $ExpectedCount
        $declaredTypes = @((Get-Command Get-DefaultBranchEnvironmentMappingsFromStrategy).OutputType.Type)
        $declaredTypes | Should -Contain ([object[]])
        foreach ($mapping in $mappings) {
            $mapping | Should -BeOfType ([pscustomobject])
            @($declaredTypes | Where-Object { $_.IsInstanceOfType($mapping) }).Count | Should -BeGreaterThan 0
        }
    }

    It 'reads optional hashtable and object values under strict mode without losing false or zero' {
        Set-StrictMode -Version Latest
        Get-OptionalObjectPropertyValue -InputObject $null -PropertyName key | Should -BeNullOrEmpty
        Get-OptionalObjectPropertyValue -InputObject @{} -PropertyName key | Should -BeNullOrEmpty
        Get-OptionalObjectPropertyValue -InputObject ([pscustomobject]@{ other = 1 }) -PropertyName key | Should -BeNullOrEmpty
        Get-OptionalObjectPropertyValue -InputObject @{ key = $false } -PropertyName key | Should -BeFalse
        Get-OptionalObjectPropertyValue -InputObject ([pscustomobject]@{ key = 0 }) -PropertyName key | Should -Be 0
        ConvertTo-SpectreMarkupLiteral '[value]' | Should -Be '[[value]]'
        ConvertTo-SpectreMarkupLiteral $null | Should -Be ''
    }

    It 'normalizes branch names, URLs, credential names, tenant identifiers, and docs links' {
        ConvertFrom-GitRefToBranchName 'refs/heads/topic' | Should -Be topic
        ConvertFrom-GitRefToBranchName main | Should -Be main
        ConvertTo-UrlSafeName ' /test feature// ' | Should -Be test-feature
        ConvertTo-NormalizedEnvironmentUrl ' https://example.com/path/?query=1 ' | Should -Be 'https://example.com'
        ConvertTo-NormalizedEnvironmentUrl 'invalid/' | Should -Be invalid
        ConvertTo-NormalizedEnvironmentUrl 'ftp://example.com/' | Should -Be 'ftp://example.com'
        ConvertTo-NormalizedEnvironmentUrl '' | Should -BeNullOrEmpty
        Test-IsValidTenantIdentifier 'example.onmicrosoft.com' | Should -BeTrue
        Test-IsValidTenantIdentifier '00000000-0000-0000-0000-000000000001' | Should -BeTrue
        Test-IsValidTenantIdentifier ' ' | Should -BeFalse
        { Assert-ValidTenantIdentifier -TenantIdentifier invalid -Source TestTenant } | Should -Throw '*TestTenant*is invalid*'
        Assert-ValidTenantIdentifier -TenantIdentifier example.com
        Get-Alm4DataverseDocUrl -RelativePath '/docs\config' -Ref main | Should -Be 'https://github.com/ALM4Dataverse/ALM4Dataverse/tree/main/docs/config'
        Get-Alm4DataverseDocumentationRef | Should -Be stable
        Get-DefaultSetupBranchName -BaseBranch '///' -Context '///' | Should -Match '^alm4dataverse/setup-main-\d{14}$'
    }

    It 'summarizes credentials without exposing any secret fields' {
        Get-CredentialSummaryText $null | Should -Be ''
        Get-CredentialSummaryText ([pscustomobject]@{ Name = 'Connection'; IsExistingServiceConnection = $true; Secret = 'fake-secret' }) | Should -Be 'Existing service connection - Connection'
        Get-CredentialSummaryText ([pscustomobject]@{ IsExistingServiceConnection = $true }) | Should -Be 'Existing service connection'
        Get-CredentialSummaryText ([pscustomobject]@{ ApplicationId = 'app-id'; AuthType = 'Federated'; Secret = 'fake-secret' }) | Should -Be 'Federated - app-id'
        Get-CredentialSummaryText ([pscustomobject]@{}) | Should -Be Credential
    }

    It 'creates or replaces solution selections while preserving unrelated configuration' -ForEach @(
        @{ Initial = '@{ assets = @("data") }' }
        @{ Initial = '@{ assets = @("data"); solutions = @(@{ name = "Old" }) }' }
    ) {
        Set-StrictMode -Version Latest
        $configPath = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.psd1')
        Set-Content $configPath -Value $Initial
        $solutions = @(@{ name = "O'Brien"; deployUnmanaged = $true }, @{ name = 'Managed' })
        Set-AlmConfigSolutionsInFile -ConfigPath $configPath -Solutions $solutions | Should -BeTrue
        $config = Import-PowerShellDataFile $configPath
        $config.assets | Should -Be @('data')
        $config.solutions[0].name | Should -Be "O'Brien"
        $config.solutions[0].deployUnmanaged | Should -BeTrue
        $config.solutions[1].ContainsKey('deployUnmanaged') | Should -BeFalse
        Set-AlmConfigSolutionsInFile -ConfigPath $configPath -Solutions $solutions | Should -BeFalse
    }

    It 'creates configuration from a template and toggles checker configuration idempotently' {
        $configPath = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.psd1')
        $templatePath = Join-Path $TestDrive 'template.psd1'
        Set-Content $templatePath -Value '@{ assets = @("data") }'
        Set-AlmConfigSolutionCheckEnabledInFile -ConfigPath $configPath -Enabled $true -CreateIfMissing -TemplatePath $templatePath | Should -BeTrue
        (Import-PowerShellDataFile $configPath).solutionCheck.enabled | Should -BeTrue
        Set-AlmConfigSolutionCheckEnabledInFile -ConfigPath $configPath -Enabled $false | Should -BeTrue
        (Import-PowerShellDataFile $configPath).solutionCheck.enabled | Should -BeFalse
        Set-AlmConfigSolutionCheckEnabledInFile -ConfigPath $configPath -Enabled $false | Should -BeFalse
        (Import-PowerShellDataFile $configPath).assets | Should -Be @('data')
    }

    It 'adds and updates baseline selectors without replacing other validation settings' -ForEach @(
        @{ Initial = '@{}'; HasPreserved = $false }
        @{ Initial = '@{ buildValidation = @{ other = 42 } }'; HasPreserved = $true }
        @{ Initial = '@{ buildValidation = @{ baselineRelease = "old"; other = 42 } }'; HasPreserved = $true }
    ) {
        $configPath = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.psd1')
        Set-Content $configPath -Value $Initial
        Set-AlmConfigBuildValidationBaselineReleaseInFile -ConfigPath $configPath -BaselineRelease "release's name" | Should -BeTrue
        $config = Import-PowerShellDataFile $configPath
        $config.buildValidation.baselineRelease | Should -Be "release's name"
        if ($HasPreserved) { $config.buildValidation.other | Should -Be 42 }
        Set-AlmConfigBuildValidationBaselineReleaseInFile -ConfigPath $configPath -BaselineRelease "release's name" | Should -BeFalse
        Set-AlmConfigBuildValidationBaselineReleaseInFile -ConfigPath $configPath -BaselineRelease '' | Should -BeTrue
    }

    It 'rejects missing, malformed, or non-hashtable configuration before editing' {
        $configPath = Join-Path $TestDrive 'invalid.psd1'
        { Set-AlmConfigBuildValidationBaselineReleaseInFile -ConfigPath $configPath -BaselineRelease '' } | Should -Throw '*not found*'
        Set-Content $configPath -Value '@{'
        { Set-AlmConfigBuildValidationBaselineReleaseInFile -ConfigPath $configPath -BaselineRelease '' } | Should -Throw '*Could not parse*'
        Set-Content $configPath -Value '42'
        { Set-AlmConfigSolutionCheckEnabledInFile -ConfigPath $configPath -Enabled $true } | Should -Throw '*root hashtable*'
        Set-Content $configPath -Value '@{ buildValidation = "not a hashtable" }'
        { Set-AlmConfigBuildValidationBaselineReleaseInFile -ConfigPath $configPath -BaselineRelease '' } | Should -Throw '*must be a hashtable*'
    }

    It 'maps simple and Gitflow strategies and detects the same environment on multiple branches' {
        $dev = [pscustomobject]@{ ShortName = 'DEV'; FriendlyName = 'Development'; Url = 'https://dev.example.com/path' }
        $prod = [pscustomobject]@{ ShortName = 'PROD'; FriendlyName = 'Production'; Url = 'https://prod.example.com/' }
        $simple = @(Get-DefaultBranchEnvironmentMappingsFromStrategy -Strategy Simple -EnvironmentConfigurations @($dev, $prod))
        $simple[0].Environments.Count | Should -Be 2
        $gitflow = @(Get-DefaultBranchEnvironmentMappingsFromStrategy -Strategy GitflowLike -EnvironmentConfigurations @($dev, $prod))
        $gitflow[0].Environments | Should -Be @($dev)
        $gitflow[2].Environments | Should -Be @($prod)
        Test-BranchEnvironmentMappingDuplicate -BranchMappings $gitflow | Should -BeFalse
        Test-BranchEnvironmentMappingDuplicate -BranchMappings @(@{ BranchName = 'main'; Environments = @($dev) }, @{ BranchName = 'develop'; Environments = @($dev) }) | Should -BeTrue
        $noProduction = @(Get-DefaultBranchEnvironmentMappingsFromStrategy -Strategy GitflowLike -EnvironmentConfigurations @($dev))
        $noProduction[2].Environments.Count | Should -Be 0
    }
}

Describe 'Setup shared mutation guards' {
    It 'does not create directories under WhatIf but preserves normal creation' {
        $directory = Join-Path $TestDrive 'guarded-directory'
        New-DirectoryIfMissing -Path $directory -WhatIf
        Test-Path $directory | Should -BeFalse
        New-DirectoryIfMissing -Path $directory -Confirm:$false
        Test-Path $directory -PathType Container | Should -BeTrue
    }

    It 'does not create or modify configuration under WhatIf' -ForEach @(
        @{ Setter = 'Set-AlmConfigSolutionsInFile'; Settings = @{ Solutions = @(@{ name = 'Example' }) } }
        @{ Setter = 'Set-AlmConfigSolutionCheckEnabledInFile'; Settings = @{ Enabled = $true } }
        @{ Setter = 'Set-AlmConfigBuildValidationBaselineReleaseInFile'; Settings = @{ BaselineRelease = '@TEST' } }
    ) {
        $configPath = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.psd1')
        & $Setter -ConfigPath $configPath -CreateIfMissing @Settings -WhatIf | Should -BeFalse
        Test-Path $configPath | Should -BeFalse
        Set-Content $configPath -Value '@{ preserved = 42 }'
        $before = [System.IO.File]::ReadAllBytes($configPath)
        & $Setter -ConfigPath $configPath @Settings -WhatIf | Should -BeFalse
        [System.IO.File]::ReadAllBytes($configPath) | Should -Be $before
    }

    It 'does not authenticate or create application secrets under WhatIf' {
        Mock Get-AuthToken { throw 'Unexpected authentication' }
        Mock Invoke-RestMethod { throw 'Unexpected Graph request' }
        New-EntraIdApplicationSecret -ApplicationObjectId application-id -TenantId example.com -WhatIf
        Should -Invoke Get-AuthToken -Times 0 -Exactly
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'returns the generated secret after an approved Graph request' {
        Mock Get-AuthToken { [pscustomobject]@{ AccessToken = 'fake-token' } }
        Mock Invoke-RestMethod { [pscustomobject]@{ secretText = 'fake-generated-secret' } }
        New-EntraIdApplicationSecret -ApplicationObjectId application-id -TenantId example.com -Confirm:$false | Should -Be 'fake-generated-secret'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://graph.microsoft.com/v1.0/applications/application-id/addPassword' -and $Method -eq 'Post' -and
                $Headers.Authorization -eq 'Bearer fake-token' -and ($Body | ConvertFrom-Json).passwordCredential.displayName -eq 'ALM4Dataverse Setup'
        }
    }

    It 'propagates authentication failures before issuing a secret creation request' {
        Mock Get-AuthToken { throw 'Authentication denied' }
        Mock Invoke-RestMethod { throw 'Unexpected Graph request' }
        { New-EntraIdApplicationSecret -ApplicationObjectId application-id -TenantId example.com -Confirm:$false } | Should -Throw '*Authentication denied*'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }
}

Describe 'Setup publication decisions' {
    BeforeEach {
        Mock Write-SetupGuidance {}
        Mock Read-TextWithDefault { $DefaultValue }
    }

    It 'supports direct, alternate-branch, and PR publication without contacting a provider' -ForEach @(
        @{ Selection = 0; Mode = 'Direct'; ExpectedBranch = 'main' }
        @{ Selection = 1; Mode = 'Direct'; ExpectedBranch = 'main' }
        @{ Selection = 2; Mode = 'PullRequest'; ExpectedBranch = '' }
    ) {
        Mock Select-FromMenu { $Selection }
        $plan = Get-RepoChangePublishPlan -ProviderName GitHub -RepositoryName Repo -BaseBranch main -DefaultCommitMessage 'Commit' -DefaultPullRequestTitle 'PR'
        $plan.Mode | Should -Be $Mode
        $plan.TargetBranch | Should -Be main
        if ($ExpectedBranch) { $plan.BranchName | Should -Be $ExpectedBranch }
        else { $plan.BranchName | Should -Match '^alm4dataverse/Repo-main-\d{14}$'; $plan.PullRequestTitle | Should -Be PR }
    }

    It 'supports branch-targeted publication choices' -ForEach @(
        @{ Selection = 0; Mode = 'Direct' }
        @{ Selection = 1; Mode = 'PullRequest' }
    ) {
        Mock Select-FromMenu { $Selection }
        $plan = Get-BranchTargetedRepoChangePublishPlan -ProviderName GitHub -RepositoryName Repo -TargetBranch develop -DefaultCommitMessage 'Commit' -DefaultPullRequestTitle 'PR'
        $plan.Mode | Should -Be $Mode
        $plan.TargetBranch | Should -Be develop
    }

    It 'rejects cancelled publication choices' {
        Mock Select-FromMenu { $null }
        { Get-RepoChangePublishPlan -ProviderName GitHub -RepositoryName Repo -BaseBranch main -DefaultCommitMessage 'Commit' -DefaultPullRequestTitle 'PR' } | Should -Throw '*No repository publish option selected*'
        { Get-BranchTargetedRepoChangePublishPlan -ProviderName GitHub -RepositoryName Repo -TargetBranch main -DefaultCommitMessage 'Commit' -DefaultPullRequestTitle 'PR' } | Should -Throw '*No repository publish option selected*'
    }
}
