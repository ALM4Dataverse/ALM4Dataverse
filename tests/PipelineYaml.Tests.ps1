BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $policy = Import-PowerShellDataFile (Join-Path $repoRoot 'scripts/powershell-validation.psd1')
    Import-Module powershell-yaml -RequiredVersion $policy.Tools['powershell-yaml']
    $yamlRoots = @(
        '.github/workflows'
        '.github/actions'
        'copy-to-your-repo/.github/workflows'
        'pipelines'
        'copy-to-your-repo/pipelines'
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
}
