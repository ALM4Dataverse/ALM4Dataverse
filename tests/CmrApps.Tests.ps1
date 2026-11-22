BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repoRoot 'pipelines/scripts/common.ps1')
    . (Join-Path $repoRoot 'pipelines/scripts/cmr-apps.ps1')

    function Write-CmrTestProject {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][string]$AppId,
            [Parameter(Mandatory)][string]$EnvironmentId,
            [string]$DisplayName = 'Contacts'
        )

        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        $config = [ordered]@{
            appId = $AppId
            environmentId = $EnvironmentId
            appDisplayName = $DisplayName
            repoType = 'native'
            buildPath = 'dist'
            connectionReferences = @{
                Dataverse = @{
                    id = '/providers/Microsoft.PowerApps/apis/shared_commondataserviceforapps'
                    dataSets = @{
                        Default = @{
                            dataSources = @{
                                contacts = @{}
                            }
                        }
                    }
                }
            }
        }
        $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $Path 'ms.config.json')
        Set-Content -LiteralPath (Join-Path $Path 'package.json') -Value '{"scripts":{"build":"vite build"}}'
        Set-Content -LiteralPath (Join-Path $Path 'package-lock.json') -Value '{"lockfileVersion":3,"packages":{}}'
    }

    function Write-CmrTestArtifact {
        param(
            [Parameter(Mandatory)][string]$ArtifactsPath,
            [Parameter(Mandatory)][string]$AppId,
            [string]$TargetDisplayName = 'Contacts (ALM4Dataverse)',
            [string]$DeploymentMode = 'artifact',
            [string]$BuildPath = 'dist',
            [string]$BuildEntryPoint = 'index.html',
            [string]$Cloud = 'public',
            [object[]]$DataSources = @(
                @{
                    connectorId = 'shared_commondataserviceforapps'
                    tables = @('contacts')
                }
            )
        )

        $appPath = Join-Path $ArtifactsPath (Join-Path 'cmr-apps' $AppId)
        $buildPathRoot = Join-Path $appPath $BuildPath
        New-Item -ItemType Directory -Path $buildPathRoot -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $buildPathRoot $BuildEntryPoint) -Value '<html>contacts</html>'
        if ($DeploymentMode -eq 'source') {
            $sourceRoot = Join-Path $appPath 'source'
            New-Item -ItemType Directory -Path (Join-Path $sourceRoot 'src') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $sourceRoot 'package.json') -Value '{"scripts":{"build":"npm run build"}}'
            Set-Content -LiteralPath (Join-Path $sourceRoot 'package-lock.json') -Value '{"lockfileVersion":3,"packages":{}}'
            Set-Content -LiteralPath (Join-Path $sourceRoot 'src/main.ts') -Value 'export const app = true'
        }
        $manifest = [ordered]@{
            schemaVersion = 1
            schema = ''
            targetDisplayName = $TargetDisplayName
            deploymentMode = $DeploymentMode
            buildPath = $BuildPath
            buildCommand = 'npm run build'
            buildEntryPoint = $BuildEntryPoint
            cloud = $Cloud
            version = '1.0.0'
            dataSources = $DataSources
        }
        $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $appPath 'cmr-app.json')
        return $appPath
    }

    function Invoke-CmrTestNpm {
        $script:cmrObservedAuth = @{
            UseServicePrincipal = $env:MS_CLI_USE_SP_AUTH
            ClientId = $env:MS_CLI_SP_CLIENT_ID
            ClientSecret = $env:MS_CLI_SP_CLIENT_SECRET
            TenantId = $env:MS_CLI_SP_TENANT_ID
            CI = $env:CI
            UseHttpForward = $env:MS_CLI_USE_HTTP_FORWARD
            ForwardUrl = $env:MS_CLI_HTTP_FORWARD_URL
            ForwardToken = $env:MS_CLI_HTTP_FORWARD_AUTH_TOKEN
            ForwardTenantId = $env:MS_CLI_HTTP_FORWARD_TENANT_ID
        }
        $global:LASTEXITCODE = 0
        '{"ok":true}'
    }
}

Describe 'CMR app configuration and build artifacts' {
    It 'rejects malformed or duplicate app IDs and invalid deployment modes' {
        $sourceRoot = Join-Path $TestDrive 'source'
        New-Item -ItemType Directory -Path $sourceRoot -Force | Out-Null

        @(Get-CmrAppEntry -Config @{ cmrApps = @() } -BaseDirectory $sourceRoot -AllowMissingProject) | Should -HaveCount 0

        {
            Get-CmrAppEntry -Config @{ cmrApps = @('not-a-guid') } -BaseDirectory $sourceRoot -AllowMissingProject
        } | Should -Throw '*must contain a non-zero appId GUID*'

        {
            Get-CmrAppEntry -Config @{ cmrApps = @(@{ appId = [guid]::NewGuid().ToString(); deploymentMode = 'unknown' }) } -BaseDirectory $sourceRoot -AllowMissingProject
        } | Should -Throw '*deploymentMode*invalid*'
    }

    It 'fails explicitly when the CMR CLI returns no output' {
        { ConvertFrom-CmrCliOutput -Output '' -Operation 'app list' } |
            Should -Throw '*CMR CLI operation*app list*returned no output*'
    }

    It 'builds client assets and stages only deployment metadata without source identifiers' {
        $sourceRoot = Join-Path $TestDrive 'source'
        $artifactRoot = Join-Path $TestDrive 'artifacts'
        $appId = [guid]::NewGuid().ToString()
        $environmentId = [guid]::NewGuid().ToString()
        $appPath = Join-Path $sourceRoot (Join-Path 'cmr-apps' $appId)
        Write-CmrTestProject -Path $appPath -AppId $appId -EnvironmentId $environmentId
        New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null

        Mock Invoke-CmrNpmCommand {}
        Mock Invoke-CmrCli {
            if ($Arguments -contains 'pack') {
                $buildPath = Join-Path $WorkingDirectory 'dist'
                New-Item -ItemType Directory -Path $buildPath -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $buildPath 'index.html') -Value '<html>built</html>'
            }
            '{}'
        }

        Build-CmrApp -Config @{
            cmrApps = @($appId)
            cmrCliVersion = '1.0.1'
            cmrNodeVersion = '24.11.1'
        } -SourceDirectory $sourceRoot -ArtifactStagingDirectory $artifactRoot

        $artifactAppPath = Join-Path $artifactRoot (Join-Path 'cmr-apps' $appId)
        Test-Path (Join-Path $artifactAppPath 'dist/index.html') | Should -BeTrue
        Test-Path (Join-Path $artifactAppPath 'cmr-app.json') | Should -BeTrue
        Test-Path (Join-Path $artifactAppPath 'ms.config.json') | Should -BeFalse
        Test-Path (Join-Path $artifactAppPath 'package.json') | Should -BeFalse
        Test-Path (Join-Path $artifactAppPath 'package-lock.json') | Should -BeFalse
        $manifestText = Get-Content -LiteralPath (Join-Path $artifactAppPath 'cmr-app.json') -Raw
        $manifestText | Should -Not -Match ([regex]::Escape($appId))
        $manifestText | Should -Not -Match ([regex]::Escape($environmentId))
        $manifest = $manifestText | ConvertFrom-Json
        $manifest.dataSources[0].connectorId | Should -Be 'shared_commondataserviceforapps'
        $manifest.dataSources[0].tables | Should -Contain 'contacts'
        Should -Invoke Invoke-CmrNpmCommand -Times 1 -Exactly -ParameterFilter { $Arguments -contains 'ci' }
        Should -Invoke Invoke-CmrCli -Times 1 -Exactly -ParameterFilter { $Arguments -contains 'pack' }
    }

    It 'stages filtered source files when source deployment is configured' {
        $sourceRoot = Join-Path $TestDrive 'source'
        $artifactRoot = Join-Path $TestDrive 'artifacts'
        $appId = [guid]::NewGuid().ToString()
        $environmentId = [guid]::NewGuid().ToString()
        $appPath = Join-Path $sourceRoot (Join-Path 'cmr-apps' $appId)
        Write-CmrTestProject -Path $appPath -AppId $appId -EnvironmentId $environmentId
        New-Item -ItemType Directory -Path (Join-Path $appPath 'src'), (Join-Path $appPath 'dist'), (Join-Path $appPath 'node_modules/example') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $appPath 'src/main.ts') -Value 'export const app = true'
        Set-Content -LiteralPath (Join-Path $appPath 'dist/index.html') -Value '<html>built</html>'
        Set-Content -LiteralPath (Join-Path $appPath 'node_modules/example/index.js') -Value 'dependency'
        New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null
        Mock Invoke-CmrNpmCommand {}
        Mock Invoke-CmrCli { '{}' }

        Build-CmrApp -Config @{
            cmrApps = @(@{ appId = $appId; deploymentMode = 'source' })
            cmrCliVersion = '1.0.1'
            cmrNodeVersion = '24.11.1'
        } -SourceDirectory $sourceRoot -ArtifactStagingDirectory $artifactRoot

        $sourceArtifact = Join-Path $artifactRoot (Join-Path (Join-Path 'cmr-apps' $appId) 'source')
        Test-Path (Join-Path $sourceArtifact 'src/main.ts') | Should -BeTrue
        Test-Path (Join-Path $sourceArtifact 'package-lock.json') | Should -BeTrue
        Test-Path (Join-Path $sourceArtifact 'ms.config.json') | Should -BeFalse
        Test-Path (Join-Path $sourceArtifact 'node_modules') | Should -BeFalse
        Test-Path (Join-Path $sourceArtifact 'dist') | Should -BeFalse
        $manifest = Get-Content -LiteralPath (Join-Path (Split-Path $sourceArtifact -Parent) 'cmr-app.json') -Raw | ConvertFrom-Json
        $manifest.deploymentMode | Should -Be 'source'
        $manifest.buildCommand | Should -Be 'npm run build'
    }

    It 'rejects secret-like filenames in the source deployment payload' {
        $sourceRoot = Join-Path $TestDrive 'source'
        $artifactRoot = Join-Path $TestDrive 'artifacts'
        $appId = [guid]::NewGuid().ToString()
        $appPath = Join-Path $sourceRoot (Join-Path 'cmr-apps' $appId)
        Write-CmrTestProject -Path $appPath -AppId $appId -EnvironmentId ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path (Join-Path $appPath 'src'), (Join-Path $appPath 'dist') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $appPath 'src/client-private.key') -Value 'not-a-secret'
        Set-Content -LiteralPath (Join-Path $appPath 'dist/index.html') -Value '<html>built</html>'
        New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null
        Mock Invoke-CmrNpmCommand {}
        Mock Invoke-CmrCli { '{}' }

        {
            Build-CmrApp -Config @{
                cmrApps = @(@{ appId = $appId; deploymentMode = 'source' })
                cmrCliVersion = '1.0.1'
                cmrNodeVersion = '24.11.1'
            } -SourceDirectory $sourceRoot -ArtifactStagingDirectory $artifactRoot
        } | Should -Throw '*unsafe file*client-private.key*'
    }
}

Describe 'CMR app export and deployment' {
    It 'exports platform-managed source without its nested Git metadata' {
        $sourceRoot = Join-Path $TestDrive 'source'
        $appId = [guid]::NewGuid().ToString()
        $environmentId = [guid]::NewGuid().ToString()
        $appPath = Join-Path $sourceRoot (Join-Path 'cmr-apps' $appId)
        Write-CmrTestProject -Path $appPath -AppId $appId -EnvironmentId $environmentId
        $expectedCloneUrl = 'https://example.environment.api.powerplatform.com/git/clone'

        Mock Invoke-CmrCli {
            if ($Arguments -contains 'info') {
                return (@{
                    appId = $appId
                    repoType = 'native'
                    displayName = 'Contacts'
                    cloneUrl = $expectedCloneUrl
                } | ConvertTo-Json -Compress)
            }
            if ($Arguments -contains 'clone') {
                $clonePath = [string]$Arguments[2]
                Write-CmrTestProject -Path $clonePath -AppId $appId -EnvironmentId $environmentId
                New-Item -ItemType Directory -Path (Join-Path $clonePath '.git') -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $clonePath 'source.ts') -Value 'export const app = true'
            }
            '{}'
        }

        Export-CmrApp -Config @{
            cmrApps = @($appId)
            cmrCliVersion = '1.0.1'
            cmrNodeVersion = '24.11.1'
        } -SourceDirectory $sourceRoot

        Test-Path (Join-Path $appPath 'source.ts') | Should -BeTrue
        Test-Path (Join-Path $appPath '.git') | Should -BeFalse
        Should -Invoke Invoke-CmrCli -Times 1 -Exactly -ParameterFilter {
            $Arguments -contains 'clone' -and $GitAuthorizationUrl -eq $expectedCloneUrl
        }
    }

    It 'provisions SSO table data sources and deploys a ZIP containing built assets and target config' {
        $artifactRoot = Join-Path $TestDrive 'artifacts'
        $sourceAppId = [guid]::NewGuid().ToString()
        $null = Write-CmrTestArtifact -ArtifactsPath $artifactRoot -AppId $sourceAppId
        $targetAppId = [guid]::NewGuid().ToString()
        $environmentId = [guid]::NewGuid().ToString()
        $script:cmrDeployCalls = [System.Collections.Generic.List[object]]::new()
        $script:cmrZipEntries = @()

        Mock Invoke-CmrCli {
            $script:cmrDeployCalls.Add([pscustomobject]@{
                Arguments = @($Arguments)
                WorkingDirectory = $WorkingDirectory
            })
            if ($Arguments[1] -eq 'list') {
                return '{"items":[]}'
            }
            if ($Arguments[1] -eq 'create') {
                $workspace = [string]$Arguments[2]
                New-Item -ItemType Directory -Path $workspace -Force | Out-Null
                @{
                    appDisplayName = 'Contacts (ALM4Dataverse)'
                    appId = $targetAppId
                    environmentId = $environmentId
                    repoType = 'none'
                } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $workspace 'ms.config.json')
                return (@{ appId = $targetAppId } | ConvertTo-Json -Compress)
            }
            if ($Arguments[1] -eq 'deploy') {
                $archivePath = [string]$Arguments[3]
                $archive = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
                try {
                    $script:cmrZipEntries = @($archive.Entries | ForEach-Object { $_.FullName })
                    $configEntry = $archive.GetEntry('ms.config.json')
                    $reader = [System.IO.StreamReader]::new($configEntry.Open())
                    try {
                        $script:cmrZipConfig = $reader.ReadToEnd() | ConvertFrom-Json
                    }
                    finally {
                        $reader.Dispose()
                    }
                }
                finally {
                    $archive.Dispose()
                }
            }
            '{}'
        }

        Deploy-CmrApp -Config @{
            cmrApps = @(@{ appId = $sourceAppId; targetDisplayName = 'Contacts (ALM4Dataverse)' })
            cmrCliVersion = '1.0.1'
            cmrNodeVersion = '24.11.1'
        } -ArtifactsPath $artifactRoot -EnvironmentContext @{ EnvironmentId = $environmentId }

        $script:cmrZipEntries | Should -Contain 'dist/index.html'
        $script:cmrZipEntries | Should -Contain 'ms.config.json'
        $script:cmrZipEntries | Should -Not -Contain 'package.json'
        $script:cmrZipConfig.appId | Should -Be $targetAppId
        $script:cmrZipConfig.environmentId | Should -Be $environmentId
        $script:cmrZipConfig.repoType | Should -Be 'none'
        $dataSourceCall = @($script:cmrDeployCalls | Where-Object { $_.Arguments[1] -eq 'add' })[0]
        $dataSourceCall.Arguments | Should -Contain '--use-sso'
        $dataSourceCall.Arguments | Should -Contain '--dataverse-environment-id'
        Should -Invoke Invoke-CmrCli -Times 1 -Exactly -ParameterFilter { $Arguments[1] -eq 'deploy' }
    }

    It 'deploys source through the target managed Git repository without an artifact' {
        $artifactRoot = Join-Path $TestDrive 'artifacts'
        $sourceAppId = [guid]::NewGuid().ToString()
        $null = Write-CmrTestArtifact -ArtifactsPath $artifactRoot -AppId $sourceAppId -DeploymentMode 'source'
        $targetAppId = [guid]::NewGuid().ToString()
        $environmentId = [guid]::NewGuid().ToString()
        $cloneUrl = 'https://target.environment.api.powerplatform.com/git/clone'
        $script:cmrDeployCalls = [System.Collections.Generic.List[object]]::new()
        $script:cmrGitCalls = [System.Collections.Generic.List[object]]::new()

        Mock Invoke-CmrCli {
            $script:cmrDeployCalls.Add([pscustomobject]@{ Arguments = @($Arguments); WorkingDirectory = $WorkingDirectory })
            if ($Arguments[1] -eq 'list') {
                return '{"items":[]}'
            }
            if ($Arguments[1] -eq 'create') {
                $workspace = [string]$Arguments[2]
                New-Item -ItemType Directory -Path $workspace -Force | Out-Null
                New-Item -ItemType Directory -Path (Join-Path $workspace '.git') -Force | Out-Null
                @{
                    appDisplayName = 'Contacts (ALM4Dataverse)'
                    appId = $targetAppId
                    environmentId = $environmentId
                    repoType = 'native'
                } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $workspace 'ms.config.json')
                return (@{ appId = $targetAppId } | ConvertTo-Json -Compress)
            }
            if ($Arguments[1] -eq 'info') {
                return (@{
                    appId = $targetAppId
                    environmentId = $environmentId
                    repoType = 'native'
                    cloneUrl = $cloneUrl
                } | ConvertTo-Json -Compress)
            }
            '{}'
        }
        Mock Invoke-CmrGitCommand {
            $script:cmrGitCalls.Add([pscustomobject]@{
                Arguments = @($Arguments)
                GitAuthorizationUrl = $GitAuthorizationUrl
                AccessToken = $AccessToken
            })
            if ($Arguments -contains 'status') { return ' M src/main.ts' }
            if ($Arguments -contains '--show-current') { return 'main' }
            if ($Arguments -contains 'rev-parse') { return '0123456789abcdef0123456789abcdef01234567' }
            return @()
        }
        Mock Get-PowerPlatformApiAccessToken { 'pipeline-access-token' }

        Deploy-CmrApp -Config @{
            cmrApps = @(@{ appId = $sourceAppId; deploymentMode = 'source' })
            cmrCliVersion = '1.0.1'
            cmrNodeVersion = '24.11.1'
        } -ArtifactsPath $artifactRoot -EnvironmentContext @{ EnvironmentId = $environmentId }

        $createCall = @($script:cmrDeployCalls | Where-Object { $_.Arguments[1] -eq 'create' })[0]
        $createCall.Arguments | Should -Contain 'native'
        $deployCall = @($script:cmrDeployCalls | Where-Object { $_.Arguments[1] -eq 'deploy' })[0]
        $deployCall.Arguments | Should -Contain '--commit'
        $deployCall.Arguments | Should -Not -Contain '--artifact'
        $deployCall.Arguments | Should -Contain '0123456789abcdef0123456789abcdef01234567'
        $pushCall = @($script:cmrGitCalls | Where-Object { $_.Arguments[0] -eq 'push' })[0]
        $pushCall.Arguments | Should -Contain $cloneUrl
        $pushCall.GitAuthorizationUrl | Should -Be $cloneUrl
        $pushCall.AccessToken | Should -Be 'pipeline-access-token'
        Should -Invoke Invoke-CmrCli -Times 1 -Exactly -ParameterFilter { $Arguments[1] -eq 'deploy' -and $Arguments -contains '--commit' }
    }

    It 'reports the target environment policy when external artifact deployment is disabled' {
        $artifactRoot = Join-Path $TestDrive 'artifacts'
        $sourceAppId = [guid]::NewGuid().ToString()
        $null = Write-CmrTestArtifact -ArtifactsPath $artifactRoot -AppId $sourceAppId -DataSources @()
        $environmentId = [guid]::NewGuid().ToString()

        Mock Invoke-CmrCli {
            if ($Arguments[1] -eq 'list') {
                return '{"items":[]}'
            }
            if ($Arguments[1] -eq 'create') {
                $workspace = [string]$Arguments[2]
                New-Item -ItemType Directory -Path $workspace -Force | Out-Null
                @{
                    appDisplayName = 'Contacts (ALM4Dataverse)'
                    appId = [guid]::NewGuid().ToString()
                    environmentId = $environmentId
                    repoType = 'none'
                } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $workspace 'ms.config.json')
                return '{"appId":"00000000-0000-0000-0000-000000000001"}'
            }
            if ($Arguments[1] -eq 'deploy') {
                throw 'AllowExternalArtifactDeployment is disabled'
            }
            '{}'
        }

        {
            Deploy-CmrApp -Config @{
                cmrApps = @($sourceAppId)
                cmrCliVersion = '1.0.1'
                cmrNodeVersion = '24.11.1'
            } -ArtifactsPath $artifactRoot -EnvironmentContext @{ EnvironmentId = $environmentId }
        } | Should -Throw '*Enable that environment setting*'
    }
}

Describe 'CMR CLI authentication' {
    BeforeEach {
        $script:cmrAuthEnvironmentNames = @(
            'AZURE_CLIENT_ID',
            'AZURE_TENANT_ID',
            'AZURE_CLIENT_SECRET',
            'MS_CLI_USE_SP_AUTH',
            'MS_CLI_SP_CLIENT_ID',
            'MS_CLI_SP_CLIENT_SECRET',
            'MS_CLI_SP_TENANT_ID',
            'CI',
            'MS_CLI_USE_HTTP_FORWARD',
            'MS_CLI_HTTP_FORWARD_URL',
            'MS_CLI_HTTP_FORWARD_AUTH_TOKEN',
            'MS_CLI_HTTP_FORWARD_TENANT_ID'
        )
        $script:cmrSavedAuthEnvironment = @{}
        foreach ($name in $script:cmrAuthEnvironmentNames) {
            $script:cmrSavedAuthEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        }

        $env:AZURE_CLIENT_ID = 'test-client-id'
        $env:AZURE_TENANT_ID = 'test-tenant-id'
        $env:AZURE_CLIENT_SECRET = 'test-client-secret'
        $env:MS_CLI_USE_SP_AUTH = 'old-sp'
        $env:MS_CLI_SP_CLIENT_ID = 'old-client'
        $env:MS_CLI_SP_CLIENT_SECRET = 'old-secret'
        $env:MS_CLI_SP_TENANT_ID = 'old-tenant'
        $env:CI = 'true'
        $env:MS_CLI_USE_HTTP_FORWARD = 'old-forward'
        $env:MS_CLI_HTTP_FORWARD_URL = 'http://old-forward'
        $env:MS_CLI_HTTP_FORWARD_AUTH_TOKEN = 'old-token'
        $env:MS_CLI_HTTP_FORWARD_TENANT_ID = 'old-forward-tenant'
        $script:cmrObservedAuth = $null
        Mock Get-CmrNodeRuntime {
            [pscustomobject]@{ NodeDirectory = '/node'; NodePath = '/node/node' }
        }
        Mock Get-PowerPlatformApiAccessToken { 'pipeline-access-token' }
        Mock Get-Command { [pscustomobject]@{ Source = 'Invoke-CmrTestNpm' } } -ParameterFilter { $Name -eq 'npm' }
    }

    AfterEach {
        foreach ($name in $script:cmrAuthEnvironmentNames) {
            [Environment]::SetEnvironmentVariable($name, $script:cmrSavedAuthEnvironment[$name], 'Process')
        }
    }

    It 'uses service-principal auth and restores prior CLI environment values' {
        $workingDirectory = Join-Path $TestDrive 'work'
        New-Item -ItemType Directory -Path $workingDirectory -Force | Out-Null
        Invoke-CmrCli -Arguments @('app', 'info') -WorkingDirectory $workingDirectory -CliVersion '1.0.1' -NodeVersion '24.11.1' | Should -Match '"ok":true'

        $script:cmrObservedAuth.UseServicePrincipal | Should -Be 'true'
        $script:cmrObservedAuth.ClientId | Should -Be 'test-client-id'
        $script:cmrObservedAuth.ClientSecret | Should -Be 'test-client-secret'
        $script:cmrObservedAuth.TenantId | Should -Be 'test-tenant-id'
        $script:cmrObservedAuth.CI | Should -Be 'true'
        $script:cmrObservedAuth.UseHttpForward | Should -BeNullOrEmpty
        $script:cmrObservedAuth.ForwardUrl | Should -BeNullOrEmpty
        $script:cmrObservedAuth.ForwardToken | Should -BeNullOrEmpty
        $script:cmrObservedAuth.ForwardTenantId | Should -BeNullOrEmpty
        $env:MS_CLI_USE_SP_AUTH | Should -Be 'old-sp'
        $env:MS_CLI_SP_CLIENT_SECRET | Should -Be 'old-secret'
        $env:MS_CLI_USE_HTTP_FORWARD | Should -Be 'old-forward'
        $env:MS_CLI_HTTP_FORWARD_URL | Should -Be 'http://old-forward'
        Should -Invoke Get-PowerPlatformApiAccessToken -Times 0 -Exactly
    }

    It 'rejects workload identity for CMR API operations' {
        $env:AZURE_CLIENT_SECRET = $null
        $workingDirectory = Join-Path $TestDrive 'work'
        New-Item -ItemType Directory -Path $workingDirectory -Force | Out-Null
        {
            Invoke-CmrCli -Arguments @('app', 'info') -WorkingDirectory $workingDirectory -CliVersion '1.0.1' -NodeVersion '24.11.1'
        } | Should -Throw '*CMR API operations require AZURE_CLIENT_SECRET*client-secret app-only access with HTTP 403*uploadBuild*'

        $env:MS_CLI_USE_HTTP_FORWARD | Should -Be 'old-forward'
        $env:MS_CLI_HTTP_FORWARD_AUTH_TOKEN | Should -Be 'old-token'
        Should -Invoke Get-PowerPlatformApiAccessToken -Times 0 -Exactly
        Should -Invoke Get-Command -Times 0 -Exactly -ParameterFilter { $Name -eq 'npm' }
    }

    It 'runs local app packing without credentials when CI would otherwise force service-principal auth' {
        $env:AZURE_CLIENT_ID = $null
        $env:AZURE_TENANT_ID = $null
        $env:AZURE_CLIENT_SECRET = $null
        $workingDirectory = Join-Path $TestDrive 'work'
        New-Item -ItemType Directory -Path $workingDirectory -Force | Out-Null

        Invoke-CmrCli -Arguments @('app', 'pack', '--non-interactive', '--json') -WorkingDirectory $workingDirectory -CliVersion '1.0.1' -NodeVersion '24.11.1' | Should -Match '"ok":true'

        $script:cmrObservedAuth.CI | Should -BeNullOrEmpty
        $script:cmrObservedAuth.UseServicePrincipal | Should -BeNullOrEmpty
        $script:cmrObservedAuth.ClientId | Should -BeNullOrEmpty
        $script:cmrObservedAuth.ClientSecret | Should -BeNullOrEmpty
        $script:cmrObservedAuth.TenantId | Should -BeNullOrEmpty
        $env:CI | Should -Be 'true'
        $env:MS_CLI_USE_SP_AUTH | Should -Be 'old-sp'
        $env:MS_CLI_SP_CLIENT_SECRET | Should -Be 'old-secret'
        Should -Invoke Get-PowerPlatformApiAccessToken -Times 0 -Exactly
    }

    It 'acquires a token for managed Git when service-principal auth is selected' {
        $workingDirectory = Join-Path $TestDrive 'work'
        New-Item -ItemType Directory -Path $workingDirectory -Force | Out-Null
        $cloneUrl = 'https://test.environment.api.powerplatform.com/appframework/git/repositories/test'

        Invoke-CmrCli -Arguments @('app', 'clone') -WorkingDirectory $workingDirectory -CliVersion '1.0.1' -NodeVersion '24.11.1' -GitAuthorizationUrl $cloneUrl | Should -Match '"ok":true'

        Should -Invoke Get-PowerPlatformApiAccessToken -Times 1 -Exactly
    }
}

Describe 'CMR CLI version selection' {
    It 'resolves floating npm selectors to exact versions and leaves exact selectors unchanged' {
        $script:CmrResolvedCliVersions = @{}
        Mock Get-CmrNodeRuntime { [pscustomobject]@{ NpmPath = 'npm' } }
        Mock Invoke-CheckedNativeCommand {
            if ($Arguments -contains 'version') {
                return '1.0.1'
            }
            return '["1.0.1","1.1.0-beta.1","1.1.0-beta.2"]'
        }

        Resolve-CmrCliVersion -VersionSpecifier '' -NodeVersion '24.11.1' | Should -Be '1.0.1'
        Resolve-CmrCliVersion -VersionSpecifier 'prerelease' -NodeVersion '24.11.1' | Should -Be '1.1.0-beta.2'
        Resolve-CmrCliVersion -VersionSpecifier '1.2.3' -NodeVersion '24.11.1' | Should -Be '1.2.3'
        Should -Invoke Invoke-CheckedNativeCommand -Times 2 -Exactly
    }

    It 'rejects unsupported floating selectors' {
        { Assert-CmrCliVersionSpecifier -VersionSpecifier 'canary' } | Should -Throw '*is invalid*'
    }
}
