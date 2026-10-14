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
}
