BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repoRoot 'pipelines/scripts/common.ps1')
    Add-Type -AssemblyName System.IO.Compression

    function Add-TestZipEntry {
        param(
            [System.IO.Compression.ZipArchive]$Archive,
            [string]$Name,
            [string]$Content
        )

        $entry = $Archive.CreateEntry($Name)
        $stream = $entry.Open()
        try {
            $writer = [System.IO.StreamWriter]::new($stream, [System.Text.Encoding]::UTF8)
            try {
                $writer.Write($Content)
            }
            finally {
                $writer.Dispose()
            }
        }
        finally {
            $stream.Dispose()
        }
    }

    function New-TestCodeAppSolutionPackage {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates isolated ZIP fixtures under Pester TestDrive.')]
        param(
            [string]$SolutionFile,
            [switch]$IncludeCanvasApp,
            [switch]$IncludeRootComponent
        )

        $canvasAppXml = ''
        if ($IncludeCanvasApp) {
            $canvasAppXml = @'
<CanvasApp>
  <Name>contoso_portal</Name>
  <DisplayName>Portal</DisplayName>
  <CanvasAppType>4</CanvasAppType>
  <CodeAppPackageUris>
    <CodeAppPackageUri>/CanvasApps/contoso_portal_CodeAppPackages/old.js_ContentType_application/javascript</CodeAppPackageUri>
  </CodeAppPackageUris>
</CanvasApp>
'@
        }
        $rootComponentXml = ''
        if ($IncludeRootComponent) {
            $rootComponentXml = '<RootComponent type="300" schemaName="contoso_portal" />'
        }

        $stream = [System.IO.File]::Open(
            $SolutionFile,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        $archive = [System.IO.Compression.ZipArchive]::new(
            $stream,
            [System.IO.Compression.ZipArchiveMode]::Create,
            $false
        )
        try {
            Add-TestZipEntry -Archive $archive -Name 'customizations.xml' -Content "<ImportExportXml><CanvasApps>$canvasAppXml</CanvasApps></ImportExportXml>"
            Add-TestZipEntry -Archive $archive -Name 'solution.xml' -Content "<ImportExportXml><SolutionManifest><RootComponents>$rootComponentXml</RootComponents></SolutionManifest></ImportExportXml>"
            Add-TestZipEntry -Archive $archive -Name 'CanvasApps/contoso_portal_CodeAppPackages/old.js' -Content 'old app'
            Add-TestZipEntry -Archive $archive -Name 'Other/unrelated.txt' -Content 'preserve me'
        }
        finally {
            $archive.Dispose()
        }
    }

    function New-TestCodeAppProject {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an isolated project fixture under Pester TestDrive.')]
        param([string]$ProjectPath)

        $buildPath = Join-Path $ProjectPath 'dist'
        $assetsPath = Join-Path $buildPath 'assets'
        New-Item -ItemType Directory -Path $assetsPath -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $ProjectPath 'power.config.json') -Value '{"appDisplayName":"Portal"}'
        Set-Content -LiteralPath (Join-Path $buildPath 'index.html') -Value '<html></html>'
        Set-Content -LiteralPath (Join-Path $assetsPath 'app.js') -Value 'console.log("built");'
    }
}

Describe 'Solution Code App package updates' {
    It 'replaces the existing app bundle and updates package URIs while preserving unrelated solution files' {
        $solutionFile = Join-Path $TestDrive 'Example.zip'
        $projectPath = Join-Path $TestDrive 'Portal'
        New-TestCodeAppSolutionPackage -SolutionFile $solutionFile -IncludeCanvasApp -IncludeRootComponent
        New-TestCodeAppProject -ProjectPath $projectPath

        Update-SolutionCodeAppPackage -SolutionFile $solutionFile -CodeAppPath $projectPath -SolutionName 'Example'

        $archive = [System.IO.Compression.ZipFile]::OpenRead($solutionFile)
        try {
            $entries = @($archive.Entries | ForEach-Object { $_.FullName })
            $entries | Should -Contain 'CanvasApps/contoso_portal_CodeAppPackages/index.html'
            $entries | Should -Contain 'CanvasApps/contoso_portal_CodeAppPackages/assets/app.js'
            $entries | Should -Not -Contain 'CanvasApps/contoso_portal_CodeAppPackages/old.js'
            $entries | Should -Contain 'Other/unrelated.txt'

            $unrelatedEntry = $archive.GetEntry('Other/unrelated.txt')
            $unrelatedReader = [System.IO.StreamReader]::new($unrelatedEntry.Open())
            try {
                $unrelatedReader.ReadToEnd() | Should -Be 'preserve me'
            }
            finally {
                $unrelatedReader.Dispose()
            }

            $manifestEntry = $archive.GetEntry('customizations.xml')
            $manifestReader = [System.IO.StreamReader]::new($manifestEntry.Open())
            try {
                [xml]$manifest = $manifestReader.ReadToEnd()
            }
            finally {
                $manifestReader.Dispose()
            }
            $uris = @($manifest.SelectNodes("//*[local-name()='CodeAppPackageUri']") | ForEach-Object { $_.InnerText })
            $uris.Count | Should -Be 2
            foreach ($uri in $uris) {
                $packagePath = $uri.TrimStart('/') -replace '_ContentType_.*$', ''
                $archive.GetEntry($packagePath) | Should -Not -BeNullOrEmpty
            }
        }
        finally {
            $archive.Dispose()
        }
    }

    It 'fails without modifying the package when the configured app is absent' {
        $solutionFile = Join-Path $TestDrive 'Example.zip'
        $projectPath = Join-Path $TestDrive 'Portal'
        New-TestCodeAppSolutionPackage -SolutionFile $solutionFile
        New-TestCodeAppProject -ProjectPath $projectPath
        $originalHash = (Get-FileHash -LiteralPath $solutionFile -Algorithm SHA256).Hash

        {
            Update-SolutionCodeAppPackage -SolutionFile $solutionFile -CodeAppPath $projectPath -SolutionName 'Example'
        } | Should -Throw '*not present in solution*'

        (Get-FileHash -LiteralPath $solutionFile -Algorithm SHA256).Hash | Should -Be $originalHash
    }

    It 'fails when the configured app is not a solution root component' {
        $solutionFile = Join-Path $TestDrive 'Example.zip'
        $projectPath = Join-Path $TestDrive 'Portal'
        New-TestCodeAppSolutionPackage -SolutionFile $solutionFile -IncludeCanvasApp
        New-TestCodeAppProject -ProjectPath $projectPath

        {
            Update-SolutionCodeAppPackage -SolutionFile $solutionFile -CodeAppPath $projectPath -SolutionName 'Example'
        } | Should -Throw '*not a root component*'
    }

    It 'leaves the solution package unchanged when WhatIf is requested' {
        $solutionFile = Join-Path $TestDrive 'Example.zip'
        $projectPath = Join-Path $TestDrive 'Portal'
        New-TestCodeAppSolutionPackage -SolutionFile $solutionFile -IncludeCanvasApp -IncludeRootComponent
        New-TestCodeAppProject -ProjectPath $projectPath
        $originalHash = (Get-FileHash -LiteralPath $solutionFile -Algorithm SHA256).Hash

        Update-SolutionCodeAppPackage -SolutionFile $solutionFile -CodeAppPath $projectPath -SolutionName 'Example' -WhatIf

        (Get-FileHash -LiteralPath $solutionFile -Algorithm SHA256).Hash | Should -Be $originalHash
    }
}
