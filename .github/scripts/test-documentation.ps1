#Requires -Version 7.0
#Requires -Modules powershell-yaml

param(
    [string[]]$Paths = @(),
    [switch]$SkipCoverage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
if ($Paths.Count -eq 0) {
    $Paths = @((Join-Path $repoRoot 'README.md')) +
        @(Get-ChildItem (Join-Path $repoRoot 'docs') -Filter '*.md' -Recurse | Select-Object -ExpandProperty FullName) +
        @((Join-Path $PSScriptRoot 'README.md'))
}

$failures = [System.Collections.Generic.List[string]]::new()
$headingCache = @{}
$linkCount = 0
$exampleCount = 0
$null = ConvertFrom-Markdown -InputObject '# Documentation validation'
$pipelineBuilder = [Markdig.MarkdownPipelineBuilder]::new()
$null = [Markdig.MarkdownExtensions]::UseAutoIdentifiers($pipelineBuilder, [Markdig.Extensions.AutoIdentifiers.AutoIdentifierOptions]::GitHub)
$markdownPipeline = $pipelineBuilder.Build()

function Get-HeadingIds {
    param([string]$Path)

    if (-not $headingCache.ContainsKey($Path)) {
        $html = [Markdig.Markdown]::ToHtml((Get-Content -LiteralPath $Path -Raw), $markdownPipeline)
        $headingCache[$Path] = @(
            [regex]::Matches($html, '\bid="([^"]+)"') |
                ForEach-Object { [System.Net.WebUtility]::HtmlDecode($_.Groups[1].Value) }
        )
    }
    return $headingCache[$Path]
}

foreach ($path in $Paths) {
    $file = Get-Item -LiteralPath $path
    $text = Get-Content -LiteralPath $file.FullName -Raw
    $null = Get-HeadingIds -Path $file.FullName
    $document = [Markdig.Markdown]::Parse($text)

    foreach ($node in [Markdig.Syntax.MarkdownObjectExtensions]::Descendants($document)) {
        if ($node -is [Markdig.Syntax.Inlines.LinkInline] -and $node.Url -and
            $node.Url -notmatch '^(?:[a-z][a-z0-9+.-]*:|//)') {
            $linkCount++
            $parts = $node.Url -split '#', 2
            $relativePath = [Uri]::UnescapeDataString(($parts[0] -split '\?', 2)[0])
            $target = if ($relativePath) {
                [IO.Path]::GetFullPath((Join-Path $file.DirectoryName $relativePath))
            }
            else {
                $file.FullName
            }

            if (-not (Test-Path -LiteralPath $target)) {
                $failures.Add("$($file.Name): missing link target '$($node.Url)'.")
            }
            elseif ($parts.Count -gt 1 -and $parts[1] -and [IO.Path]::GetExtension($target) -eq '.md') {
                $fragment = [Uri]::UnescapeDataString($parts[1])
                if ($fragment -notin @(Get-HeadingIds -Path $target)) {
                    $failures.Add("$($file.Name): missing heading '$($node.Url)'.")
                }
            }
        }

        if ($node -is [Markdig.Syntax.FencedCodeBlock]) {
            $language = [string]$node.Info
            $code = $node.Lines.ToString()
            try {
                switch ($language.ToLowerInvariant()) {
                    'powershell' {
                        $tokens = $null
                        $parseErrors = $null
                        [void][System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$tokens, [ref]$parseErrors)
                        if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
                        $exampleCount++
                    }
                    'yaml' { $null = ConvertFrom-Yaml $code; $exampleCount++ }
                    'json' { $null = ConvertFrom-Json $code; $exampleCount++ }
                }
            }
            catch {
                $failures.Add("$($file.Name): invalid $language example near line $($node.Line + 1): $($_.Exception.Message)")
            }
        }
    }
}

if (-not $SkipCoverage) {
    $configReference = Get-Content (Join-Path $repoRoot 'docs/config/alm-config.md') -Raw
    $defaults = Import-PowerShellDataFile (Join-Path $repoRoot 'alm-config-defaults.psd1')
    $template = Import-PowerShellDataFile (Join-Path $repoRoot 'copy-to-your-repo/alm-config.psd1')
    foreach ($key in @($defaults.Keys) + @($template.Keys) + @($defaults.solutionCheck.Keys) + @($template.hooks.Keys)) {
        if (-not $configReference.Contains([string]$key)) {
            $failures.Add("Configuration reference is missing '$key'.")
        }
    }

    $pipelineReference = Get-Content (Join-Path $repoRoot 'docs/config/pipelines.md') -Raw
    foreach ($actionFile in Get-ChildItem (Join-Path $repoRoot '.github/actions') -Filter 'action.yml' -Recurse) {
        $action = Get-Content $actionFile.FullName -Raw | ConvertFrom-Yaml
        foreach ($section in @('inputs', 'outputs')) {
            if ($action.ContainsKey($section)) {
                foreach ($key in $action[$section].Keys) {
                    if (-not $pipelineReference.Contains([string]$key)) {
                        $failures.Add("Action reference is missing '$key' from $($actionFile.Directory.Name) $section.")
                    }
                }
            }
        }
    }
    foreach ($templateFile in Get-ChildItem (Join-Path $repoRoot 'pipelines/templates') -Filter '*.yml' -Recurse) {
        $pipeline = Get-Content $templateFile.FullName -Raw | ConvertFrom-Yaml
        foreach ($parameter in $pipeline.parameters) {
            if (-not $pipelineReference.Contains([string]$parameter.name)) {
                $failures.Add("Template reference is missing '$($parameter.name)' from $($templateFile.Name).")
            }
        }
    }
}

if ($failures.Count) {
    throw ($failures -join [Environment]::NewLine)
}
Write-Host "PASS: $($Paths.Count) documentation files, $linkCount local links, $exampleCount parsed examples."
if (-not $SkipCoverage) {
    Write-Host 'PASS: Configuration keys, hook names, action inputs/outputs, and template parameters are documented.'
}
