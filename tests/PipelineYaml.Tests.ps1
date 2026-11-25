BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $policy = Import-PowerShellDataFile (Join-Path $repoRoot 'scripts/powershell-validation.psd1')
    Import-Module powershell-yaml -RequiredVersion $policy.Tools['powershell-yaml']
    $yamlRoots = @(
        '.github/workflows'
        '.github/actions'
        'copy-to-your-repo/.github/workflows'
        'pipelines'
    )
    $script:yamlFiles = @(
        foreach ($root in $yamlRoots) {
            Get-ChildItem -LiteralPath (Join-Path $repoRoot $root) -Recurse -File |
                Where-Object { $_.Extension -in '.yml', '.yaml' }
        }
    )
}

Describe 'Workflow and pipeline YAML validation' {
    It 'parses every repository workflow, action, and Azure DevOps pipeline YAML file' {
        $failures = [System.Collections.Generic.List[string]]::new()
        foreach ($file in $script:yamlFiles) {
            try {
                $null = ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $file.FullName -Raw) -ErrorAction Stop
            }
            catch {
                $relativePath = [System.IO.Path]::GetRelativePath($repoRoot, $file.FullName)
                $failures.Add(('{0}: {1}' -f $relativePath, $_.Exception.Message))
            }
        }

        $failures | Should -BeNullOrEmpty
    }

    It 'delimits BUILD tag refspecs and verifies Azure deployment tag commits before moving pointers' {
        $buildTemplate = Get-Content -LiteralPath (Join-Path $repoRoot 'pipelines/templates/build.yml') -Raw
        $deploymentTemplate = Get-Content -LiteralPath (Join-Path $repoRoot 'pipelines/templates/stages/deploy-environment.yml') -Raw

        $buildTemplate | Should -Match 'refs/tags/\$\{tagName\}:refs/tags/\$\{tagName\}'
        $deploymentTemplate | Should -Match '\$targetCommit -ine \[string\]\$metadata\.sourceCommit'
        $deploymentTemplate.IndexOf('$targetCommit -ine [string]$metadata.sourceCommit') |
            Should -BeLessThan $deploymentTemplate.IndexOf('git tag -f -a "$environmentTag"')
    }

    It 'configures a committer identity before creating the annotated environment tag' {
        $deploymentTemplate = Get-Content -LiteralPath (Join-Path $repoRoot 'pipelines/templates/stages/deploy-environment.yml') -Raw

        $deploymentTemplate | Should -Match '\$env:BUILD_REQUESTEDFOR'
        $deploymentTemplate | Should -Match '\$env:BUILD_REQUESTEDFOREMAIL'
        $deploymentTemplate.IndexOf('git config user.name') |
            Should -BeGreaterThan -1
        $deploymentTemplate.IndexOf('git config user.email') |
            Should -BeGreaterThan $deploymentTemplate.IndexOf('git config user.name')
        $deploymentTemplate.IndexOf('git config user.email') |
            Should -BeLessThan $deploymentTemplate.IndexOf('git tag -f -a "$environmentTag"')
    }

    It 'runs the Azure DevOps apply-config setup from the shared checkout path' {
        $applyConfigTemplate = Get-Content -LiteralPath (Join-Path $repoRoot 'pipelines/templates/apply-config.yml') -Raw
        # checkout with path: alm places the repository under Agent.BuildDirectory,
        # not under the source repository's Build.SourcesDirectory.
        $applyConfigTemplate | Should -Match '\$\(Agent\.BuildDirectory\)/alm/setup-azdo\.ps1'
        $applyConfigTemplate | Should -Not -Match 'Build\.SourcesDirectory\)/alm'
    }

    It 'handles legacy Azure DevOps collection URIs and scopes GitHub action credentials' {
        $applyConfigTemplate = Get-Content -LiteralPath (Join-Path $repoRoot 'pipelines/templates/apply-config.yml') -Raw
        $legacyHostCheck = $applyConfigTemplate.IndexOf("if (`$organizationUri.Host -match '^([^.]+)\.visualstudio\.com$')")
        $pathFallback = $applyConfigTemplate.IndexOf('$organizationName = @($organizationUri.AbsolutePath')
        $legacyHostCheck | Should -BeGreaterThan -1
        $legacyHostCheck | Should -BeLessThan $pathFallback

        $applyConfigAction = Get-Content -LiteralPath (Join-Path $repoRoot '.github/actions/apply-config/action.yml') -Raw
        $applyConfigAction | Should -Match 'token: \$\{\{ inputs\.github-token \|\| github\.token \}\}'
        ([regex]::Matches($applyConfigAction, 'persist-credentials: false')).Count | Should -Be 2
        $applyConfigAction | Should -Match "\`$env:GIT_CONFIG_COUNT = '3'"
        $applyConfigAction | Should -Match "\`$env:GIT_CONFIG_KEY_1 = 'user.name'"
        $applyConfigAction | Should -Match "\`$env:GIT_CONFIG_KEY_2 = 'user.email'"
        $applyConfigAction | Should -Not -Match 'git config --global http\.https://github\.com/\.extraheader'
        $applyConfigAction | Should -Match 'git config --global --unset-all \$gitExtraHeaderKey'
    }

    It 'keeps the branch validation map authoritative over the fallback variable group' {
        $buildTemplate = Get-Content -LiteralPath (Join-Path $repoRoot 'pipelines/templates/build.yml') -Raw

        # The template must never hand an object map to the length() expression
        # function; the documented contract accepts strings and arrays only.
        $buildTemplate | Should -Not -Match 'length\(parameters\.buildValidationEnvironments\)'

        # The fallback variable and group exist only under the empty-map guard, so a
        # matching branch entry cannot duplicate them; the branch group comes later
        # and is the only group an entry can emit.
        $emptyMapGuard = $buildTemplate.IndexOf("eq(convertToJson(parameters.buildValidationEnvironments), '{}')")
        $emptyMapGuard | Should -BeGreaterThan -1
        $fallbackVariable = $buildTemplate.IndexOf('value: ${{ parameters.buildEnvironmentName }}')
        $fallbackGroup = $buildTemplate.IndexOf("group: 'Environment-`${{ parameters.buildEnvironmentName }}'")
        $branchGroup = $buildTemplate.IndexOf("group: 'Environment-`${{ branch.value }}'")
        $emptyMapGuard | Should -BeLessThan $fallbackVariable
        $fallbackVariable | Should -BeLessThan $fallbackGroup
        $fallbackGroup | Should -BeLessThan $branchGroup
        ([regex]::Matches($buildTemplate, 'group: ''Environment-\$\{\{ parameters\.buildEnvironmentName \}\}''')).Count |
            Should -Be 1
    }

    It 'signs in to Az PowerShell from the selected Azure DevOps service connection before DEPLOY' {
        $deploymentTemplate = Get-Content -LiteralPath (Join-Path $repoRoot 'pipelines/templates/stages/deploy-environment.yml') -Raw

        $deploymentTemplate | Should -Match 'connect-az\.ps1'
        $deploymentTemplate | Should -Match 'AZURE_CLIENT_ID: \$\(AZURE_CLIENT_ID\)'
        $deploymentTemplate | Should -Match 'AZURE_TENANT_ID: \$\(AZURE_TENANT_ID\)'
        $deploymentTemplate | Should -Match 'AZURE_FEDERATED_TOKEN_FILE: \$\(AZURE_FEDERATED_TOKEN_FILE\)'
        $artifactCheck = $deploymentTemplate.IndexOf('Test-Path -LiteralPath $connectAzScript -PathType Leaf')
        $artifactCall = $deploymentTemplate.IndexOf('& $connectAzScript')
        $artifactCheck | Should -BeGreaterThan -1
        $deploymentTemplate | Should -Match 'Rebuild the artifact using the updated ALM4Dataverse shared ref'
        $artifactCheck |
            Should -BeLessThan $artifactCall
        $artifactCall |
            Should -BeLessThan $deploymentTemplate.IndexOf('deploy.ps1')
    }

    It 'passes the export default branch through the environment and ignores unresolved macros' {
        $exportTemplate = Get-Content -LiteralPath (Join-Path $repoRoot 'pipelines/templates/export.yml') -Raw

        $exportTemplate | Should -Match ([regex]::Escape('DEFAULT_BRANCH_NAME: $(Build.Repository.DefaultBranch)'))
        $exportTemplate | Should -Match ([regex]::Escape('$defaultBranchName = $env:DEFAULT_BRANCH_NAME'))
        $exportTemplate | Should -Match ([regex]::Escape('$defaultBranchName -match ''^\$\(.+\)$'''))
        $exportTemplate | Should -Match ([regex]::Escape('-DefaultBranchName $defaultBranchName'))
        $exportTemplate | Should -Not -Match ([regex]::Escape('-DefaultBranchName "$(Build.Repository.DefaultBranch)"'))
    }

    It 'maps caller-listed secret variables into every connected <Template> script step' -ForEach @(
        @{ Template = 'build.yml'; ConnectedSteps = 2 }
        @{ Template = 'export.yml'; ConnectedSteps = 1 }
        @{ Template = 'import.yml'; ConnectedSteps = 1 }
        @{ Template = 'stages/deploy-environment.yml'; ConnectedSteps = 1 }
    ) {
        $path = Join-Path $repoRoot "pipelines/templates/$Template"
        $pipeline = Get-Content -LiteralPath $path -Raw | ConvertFrom-Yaml
        $parameter = @($pipeline.parameters | Where-Object { $_.name -eq 'secretVariables' })
        $parameter.Count | Should -Be 1
        $parameter[0].type | Should -Be 'object'
        @($parameter[0].default).Count | Should -Be 0

        $text = Get-Content -LiteralPath $path -Raw
        $mappings = [regex]::Matches($text, '\$\{\{ each secretVariable in parameters\.secretVariables \}\}:\s+\$\{\{ secretVariable \}\}: \$\(\$\{\{ secretVariable \}\}\)')
        $mappings.Count | Should -Be $ConnectedSteps
        [regex]::Matches($text, 'connect\.ps1').Count | Should -Be $ConnectedSteps
    }
    It 'keeps the setup, Azure DevOps and GitHub shared template version literals in sync' {
        $versionSourcePath = Join-Path $repoRoot 'setup/common/shared-template-version.ps1'
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($versionSourcePath, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-AlmSharedTemplateVersion' }, $true)
        $null -ne $definition | Should -BeTrue
        Set-Item -Path 'Function:Get-AlmSharedTemplateVersion' -Value $definition.Body.GetScriptBlock()
        $setupVersion = Get-AlmSharedTemplateVersion

        $azdoGuard = Get-Content -LiteralPath (Join-Path $repoRoot 'pipelines/templates/steps/validate-shared-template-version.yml') -Raw
        $azdoVersion = [regex]::Match($azdoGuard, '-ne ''(?<version>[^'']+)''').Groups['version'].Value
        $githubGuard = Get-Content -LiteralPath (Join-Path $repoRoot '.github/actions/common/validate-caller-version.ps1') -Raw
        $githubVersion = [regex]::Match($githubGuard, '-ne ''(?<version>[^'']+)''').Groups['version'].Value

        $azdoVersion | Should -Be $setupVersion
        $githubVersion | Should -Be $setupVersion
    }

    It 'guards every shared template and action entry point against stale caller versions' {
        foreach ($templateName in @('build.yml', 'export.yml', 'import.yml', 'stages/deploy-environment.yml')) {
            $templatePath = Join-Path $repoRoot "pipelines/templates/$templateName"
            $template = Get-Content -LiteralPath $templatePath -Raw
            $template | Should -Match ([regex]::Escape('validate-shared-template-version.yml'))
            $template | Should -Match 'sharedTemplateVersion'
        }
        foreach ($actionName in @('build', 'export', 'import', 'deploy')) {
            $actionPath = Join-Path $repoRoot ".github/actions/$actionName/action.yml"
            $action = Get-Content -LiteralPath $actionPath -Raw
            $action | Should -Match 'shared-template-version'
            $action | Should -Match ([regex]::Escape('validate-caller-version.ps1'))
        }
    }

    It 'stops the GitHub build action while generated workflows await replacement' {
        $action = Get-Content -LiteralPath (Join-Path $repoRoot '.github/actions/build/action.yml') -Raw
        $action | Should -Match ([regex]::Escape('validate-replacement-workflows.ps1'))
    }
}
