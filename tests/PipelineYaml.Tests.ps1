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
}
