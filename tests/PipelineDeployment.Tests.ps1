BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $script:deployScript = Join-Path $repoRoot 'pipelines/scripts/deploy.ps1'
    . (Join-Path $repoRoot 'pipelines/scripts/common.ps1')

    function Import-DataverseSolution {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        [CmdletBinding()]
        param($InFile, $Mode, $TimeoutSeconds, $EnvironmentVariables, $ConnectionReferences,
            [switch]$OverwriteUnmanagedCustomizations, [switch]$SkipIfSameVersion,
            [switch]$UseUpdateIfVersionMajorMinorMatches)
    }
    function Invoke-DataverseSolutionUpgrade {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        [CmdletBinding()]
        param($SolutionName, [switch]$IfExists)
    }
    function Get-DataverseRecord {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        param($TableName, $FilterValues, $Links, $Columns)
    }
    function Set-DataverseRecord {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        param($TableName, $Id, $InputObject)
    }
    function Set-DataverseOrganizationSettings {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'External Dataverse cmdlet name required by the mock contract.')]
        [CmdletBinding(SupportsShouldProcess = $true)]
        param([switch]$OrgDbOrgSettings, $InputObject)

        $target = if ($OrgDbOrgSettings) { 'OrgDbOrgSettings' } else { 'organization' }
        $settingCount = @($InputObject.PSObject.Properties).Count
        $null = $PSCmdlet.ShouldProcess("$target ($settingCount settings)", "Update $target settings")
    }
    function Get-DataverseWhoAmI {}
    function Publish-DataverseCustomizations {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'External Dataverse cmdlet name required by the mock contract.')]
        param()
    }
    function Compress-DataverseSolutionFile {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        [CmdletBinding()]
        param($Path, $OutputPath, $PackageType)
    }
    function Invoke-DeploymentTestDotnet {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        param($Verb, $Operation)
    }
    function Invoke-DeploymentTestPac {
        $global:LASTEXITCODE = 0
    }

    # Settings is literal solution-entry syntax, allowing missing/null/false keys to remain distinct.
    # Keep BUILD in-runspace and skip remote claims because these fixtures have no Git remote.
    function Write-DeploymentConfig {
        param([string]$Settings = '')
        Set-Content -LiteralPath (Join-Path $TestDrive 'alm-config.psd1') -Value @"
@{
    solutions = @(@{ name = 'Example'; $Settings })
    build = @{ parallel = `$false; versionCollisionGuard = `$false }
    hooks = @{}
}
"@
    }
}

Describe 'Deployment options' {
    BeforeEach {
        $script:savedDefaultUpn = $env:DATAVERSESERVICEACCOUNTUPN
        $script:savedCustomUpn = $env:CUSTOMUPN
        $env:DATAVERSESERVICEACCOUNTUPN = 'default@example.com'
        $env:CUSTOMUPN = 'custom@example.com'
        Mock Import-DataverseSolution {}
        Mock Invoke-DataverseSolutionUpgrade {}
        Mock Publish-DataverseCustomizations {}
        Mock Update-SolutionCodeAppPackage {}
        Mock Get-DataverseRecord {
            if ($TableName -eq 'systemuser') {
                return @{ fullname = 'Service Account'; Id = 'user-id' }
            }
            return @()
        }
    }

    AfterEach {
        $env:DATAVERSESERVICEACCOUNTUPN = $script:savedDefaultUpn
        $env:CUSTOMUPN = $script:savedCustomUpn
    }

    It 'applies static and dynamic organization settings in pre- and post-deployment order' {
        $eventLogPath = Join-Path $TestDrive 'deployment-events.jsonl'
        $savedEventLogPath = $env:ALM4DATAVERSE_TEST_EVENT_LOG
        $env:ALM4DATAVERSE_TEST_EVENT_LOG = $eventLogPath
        Set-Content -LiteralPath (Join-Path $TestDrive 'alm-config.psd1') -Value @'
@{
    solutions = @(@{ name = 'Example' })
    organizationSettings = @{
        IsCustomControlsInCanvasAppsEnabled = $true
        ComputedStage = { param($Context) $Context.HookType }
    }
    orgDbOrgSettings = @{
        IsLockDownOfUnmanagedCustomizationEnabled = $false
    }
    powerPlatformSettings = @{
        PowerApps_AllowCodeApps = $true
        ComputedEnvironmentId = { param($Context) $Context.EnvironmentId }
    }
    postDeployOrganizationSettings = @{
        ComputedStage = { param($Context) $Context.HookType }
    }
    postDeployOrgDbOrgSettings = @{
        IsLockDownOfUnmanagedCustomizationEnabled = $true
    }
    postDeployPowerPlatformSettings = @{
        PowerApps_AllowCodeApps = $false
    }
}
'@
        Mock Set-DataverseOrganizationSettings {
            $target = if ($OrgDbOrgSettings) { 'orgdb' } else { 'organization' }
            $loggedEvent = [pscustomobject]@{
                Kind = 'settings'
                Target = $target
                Values = $InputObject
            }
            Add-Content -LiteralPath $env:ALM4DATAVERSE_TEST_EVENT_LOG -Value ($loggedEvent | ConvertTo-Json -Compress)
        }
        Mock Invoke-Hook {
            $loggedEvent = [pscustomobject]@{ Kind = 'hook'; Target = $HookType }
            Add-Content -LiteralPath $env:ALM4DATAVERSE_TEST_EVENT_LOG -Value ($loggedEvent | ConvertTo-Json -Compress)
        }
        Mock Import-DataverseSolution {
            Add-Content -LiteralPath $env:ALM4DATAVERSE_TEST_EVENT_LOG -Value '{"Kind":"import"}'
        }
        Mock Publish-DataverseCustomizations {
            Add-Content -LiteralPath $env:ALM4DATAVERSE_TEST_EVENT_LOG -Value '{"Kind":"publish"}'
        }
        Mock Get-DataverseWhoAmI { [pscustomobject]@{ OrganizationId = 'org-id' } }
        Mock Invoke-RestMethod {
            if ($Uri -like 'https://login.microsoftonline.com/*') {
                $loggedEvent = [pscustomobject]@{ Kind = 'auth' }
                Add-Content -LiteralPath $env:ALM4DATAVERSE_TEST_EVENT_LOG -Value ($loggedEvent | ConvertTo-Json -Compress)
                return [pscustomobject]@{ access_token = 'fake-power-platform-token' }
            }
            if ($Method -eq 'Get') {
                $loggedEvent = [pscustomobject]@{ Kind = 'resolve' }
                Add-Content -LiteralPath $env:ALM4DATAVERSE_TEST_EVENT_LOG -Value ($loggedEvent | ConvertTo-Json -Compress)
                return [pscustomobject]@{
                    value = @([pscustomobject]@{ id = 'environment-id'; dataverseId = 'org-id' })
                }
            }

            $loggedEvent = [pscustomobject]@{
                Kind = 'settings'
                Target = 'powerplatform'
                Values = ConvertFrom-Json -InputObject $Body
                Uri = $Uri
                Authorization = $Headers.Authorization
            }
            Add-Content -LiteralPath $env:ALM4DATAVERSE_TEST_EVENT_LOG -Value ($loggedEvent | ConvertTo-Json -Compress)
        }

        $savedApiClientId = $env:AZURE_CLIENT_ID
        $savedApiTenantId = $env:AZURE_TENANT_ID
        $savedApiClientSecret = $env:AZURE_CLIENT_SECRET
        $env:AZURE_CLIENT_ID = 'client-id'
        $env:AZURE_TENANT_ID = 'tenant-id'
        $env:AZURE_CLIENT_SECRET = 'client-secret'

        try {
            & $script:deployScript -ArtifactsPath $TestDrive
            $events = @(Get-Content -LiteralPath $eventLogPath | ForEach-Object { ConvertFrom-Json $_ })
        }
        finally {
            $env:ALM4DATAVERSE_TEST_EVENT_LOG = $savedEventLogPath
            $env:AZURE_CLIENT_ID = $savedApiClientId
            $env:AZURE_TENANT_ID = $savedApiTenantId
            $env:AZURE_CLIENT_SECRET = $savedApiClientSecret
        }

        $eventNames = foreach ($loggedEvent in $events) {
            switch ($loggedEvent.Kind) {
                'settings' { "settings:$($loggedEvent.Target)" }
                'hook' { "hook:$($loggedEvent.Target)" }
                default { $loggedEvent.Kind }
            }
        }
        ($eventNames -join ',') | Should -Be 'settings:organization,settings:orgdb,auth,resolve,settings:powerplatform,hook:preDeploy,import,hook:dataMigrations,publish,hook:postDeploy,settings:organization,settings:orgdb,auth,settings:powerplatform'
        $settingEvents = @($events | Where-Object Kind -eq 'settings' | Where-Object Target -ne 'powerplatform')
        $settingEvents.Count | Should -Be 4
        $settingEvents[0].Values.iscustomcontrolsincanvasappsenabled | Should -BeTrue
        $settingEvents[0].Values.computedstage | Should -Be 'preDeploy'
        $settingEvents[1].Target | Should -Be 'orgdb'
        $settingEvents[1].Values.IsLockDownOfUnmanagedCustomizationEnabled | Should -BeFalse
        $settingEvents[2].Values.computedstage | Should -Be 'postDeploy'
        $settingEvents[3].Target | Should -Be 'orgdb'
        $settingEvents[3].Values.IsLockDownOfUnmanagedCustomizationEnabled | Should -BeTrue
        $powerPlatformEvents = @($events | Where-Object { $_.Kind -eq 'settings' -and $_.Target -eq 'powerplatform' })
        $powerPlatformEvents.Count | Should -Be 2
        $powerPlatformEvents[0].Values.PowerApps_AllowCodeApps | Should -BeTrue
        $powerPlatformEvents[0].Values.ComputedEnvironmentId | Should -Be 'environment-id'
        $powerPlatformEvents[0].Uri | Should -Be 'https://api.powerplatform.com/environmentmanagement/environments/environment-id/settings?api-version=2024-10-01'
        $powerPlatformEvents[0].Authorization | Should -Be 'Bearer fake-power-platform-token'
        $powerPlatformEvents[1].Values.PowerApps_AllowCodeApps | Should -BeFalse
        Should -Invoke Get-DataverseWhoAmI -Times 1 -Exactly
        Should -Invoke Invoke-RestMethod -Times 5 -Exactly
    }

    It 'uses managed packages when deployUnmanaged is <Label>' -ForEach @(
        @{ Label = 'missing'; Settings = '' }
        @{ Label = 'false'; Settings = 'deployUnmanaged = $false' }
        @{ Label = 'null'; Settings = 'deployUnmanaged = $null' }
    ) {
        Write-DeploymentConfig -Settings $Settings
        & $script:deployScript -ArtifactsPath $TestDrive
        Should -Invoke Import-DataverseSolution -Times 1 -Exactly -ParameterFilter {
            $InFile -like '*Example_managed.zip' -and $Mode -eq 'Auto'
        }
    }

    It 'honors per-solution unmanaged deployment without upgrade behavior' {
        Write-DeploymentConfig -Settings 'deployUnmanaged = $true'
        & $script:deployScript -ArtifactsPath $TestDrive
        Should -Invoke Import-DataverseSolution -Times 1 -Exactly -ParameterFilter {
            $InFile -like '*Example.zip' -and $Mode -eq 'NoUpgrade' -and
            -not $OverwriteUnmanagedCustomizations -and -not $UseUpdateIfVersionMajorMinorMatches
        }
        Should -Invoke Invoke-DataverseSolutionUpgrade -Times 0 -Exactly
    }

    It 'uses unmanaged packages for the import switch' {
        Write-DeploymentConfig
        & $script:deployScript -ArtifactsPath $TestDrive -UseUnmanagedSolutions
        Should -Invoke Import-DataverseSolution -Times 1 -Exactly -ParameterFilter {
            $InFile -like '*Example.zip' -and $Mode -eq 'NoUpgrade'
        }
        Should -Invoke Invoke-DataverseSolutionUpgrade -Times 0 -Exactly
    }

    It 'patches configured code apps into solution packages before importing by default' {
        $codeAppPath = Join-Path $TestDrive 'apps/Portal'
        New-Item -ItemType Directory -Path $codeAppPath -Force | Out-Null
        Write-DeploymentConfig -Settings "codeApps = @('apps/Portal')"
        Mock Update-SolutionCodeAppPackage {}
        Mock Import-DataverseSolution {
            Should -Invoke Update-SolutionCodeAppPackage -Times 1 -Exactly -ParameterFilter {
                $SolutionName -eq 'Example'
            }
        }
        Mock Invoke-DeploymentTestPac {}

        & $script:deployScript -ArtifactsPath $TestDrive

        Should -Invoke Update-SolutionCodeAppPackage -Times 1 -Exactly -ParameterFilter {
            $SolutionName -eq 'Example' -and $SolutionFile -like '*Example_managed.zip'
        }
        Should -Invoke Invoke-DeploymentTestPac -Times 0 -Exactly
    }

    It 'fails before importing when a configured code app is absent from the solution package' {
        $codeAppPath = Join-Path $TestDrive 'apps/Portal'
        New-Item -ItemType Directory -Path $codeAppPath -Force | Out-Null
        Write-DeploymentConfig -Settings "codeApps = @('apps/Portal')"
        Mock Update-SolutionCodeAppPackage { throw "Configured app is not present" }

        { & $script:deployScript -ArtifactsPath $TestDrive } |
            Should -Throw '*not present*'
        Should -Invoke Import-DataverseSolution -Times 0 -Exactly
    }

    It 'pushes configured code apps with PAC when explicitly selected' {
        $codeAppPath = Join-Path $TestDrive 'apps/Portal'
        New-Item -ItemType Directory -Path $codeAppPath -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $codeAppPath 'power.config.json') -Value '{}'
        Write-DeploymentConfig -Settings "codeApps = @('apps/Portal'); codeAppPublishMethod = 'pac'"
        $savedDataverseUrl = $env:DATAVERSE_URL
        $env:DATAVERSE_URL = 'https://example.crm.dynamics.com'
        Mock Get-Command { [pscustomobject]@{ Source = 'Invoke-DeploymentTestPac' } } -ParameterFilter { $Name -eq 'pac' }
        Mock Invoke-DeploymentTestPac { $global:LASTEXITCODE = 0 }

        try {
            & $script:deployScript -ArtifactsPath $TestDrive

            Should -Invoke Invoke-DeploymentTestPac -Times 1 -Exactly -ParameterFilter {
                $args -contains 'code' -and
                $args -contains 'push' -and
                $args -contains '--environment' -and
                $args -contains 'https://example.crm.dynamics.com' -and
                $args -contains '--solutionName' -and
                $args -contains 'Example'
            }
            Should -Invoke Update-SolutionCodeAppPackage -Times 0 -Exactly
        }
        finally {
            $env:DATAVERSE_URL = $savedDataverseUrl
        }
    }

    It 'fails PAC code app pushes when the target environment URL is missing' {
        $codeAppPath = Join-Path $TestDrive 'apps/Portal'
        New-Item -ItemType Directory -Path $codeAppPath -Force | Out-Null
        Write-DeploymentConfig -Settings "codeApps = @('apps/Portal'); codeAppPublishMethod = 'pac'"
        $savedDataverseUrl = $env:DATAVERSE_URL
        Remove-Item Env:DATAVERSE_URL -ErrorAction SilentlyContinue

        try {
            { & $script:deployScript -ArtifactsPath $TestDrive } |
                Should -Throw '*DATAVERSE_URL is required*'
        }
        finally {
            $env:DATAVERSE_URL = $savedDataverseUrl
        }
    }

    It 'fails and includes PAC output when its API request fails despite a zero exit code' {
        $codeAppPath = Join-Path $TestDrive 'apps/Portal'
        New-Item -ItemType Directory -Path $codeAppPath -Force | Out-Null
        Write-DeploymentConfig -Settings "codeApps = @('apps/Portal'); codeAppPublishMethod = 'pac'"
        $savedDataverseUrl = $env:DATAVERSE_URL
        $env:DATAVERSE_URL = 'https://example.crm.dynamics.com'
        Mock Get-Command { [pscustomobject]@{ Source = 'Invoke-DeploymentTestPac' } } -ParameterFilter { $Name -eq 'pac' }
        Mock Invoke-DeploymentTestPac {
            $global:LASTEXITCODE = 0
            'HTTP error status: 403 for POST https://example.environment.api.powerplatform.com/powerapps/apps?api-version=1: Forbidden'
        }

        try {
            { & $script:deployScript -ArtifactsPath $TestDrive } |
                Should -Throw '*HTTP error status: 403*'
        }
        finally {
            $env:DATAVERSE_URL = $savedDataverseUrl
        }
    }

    It 'selects package and service-account defaults for <Label>' -ForEach @(
        @{ Label = 'missing keys'; Settings = ''; Unmanaged = $false; Package = 'Example_managed.zip'; Upn = 'default@example.com' }
        @{ Label = 'per-solution overrides'; Settings = "deployUnmanaged = `$true; serviceAccountUpnConfigKey = 'CustomUpn'"; Unmanaged = $false; Package = 'Example.zip'; Upn = 'custom@example.com' }
        @{ Label = 'false and empty keys'; Settings = "deployUnmanaged = `$false; serviceAccountUpnConfigKey = ''"; Unmanaged = $false; Package = 'Example_managed.zip'; Upn = 'default@example.com' }
        @{ Label = 'null keys'; Settings = 'deployUnmanaged = $null; serviceAccountUpnConfigKey = $null'; Unmanaged = $false; Package = 'Example_managed.zip'; Upn = 'default@example.com' }
        @{ Label = 'IMPORT overriding managed preference'; Settings = "deployUnmanaged = `$false; serviceAccountUpnConfigKey = 'CustomUpn'"; Unmanaged = $true; Package = 'Example.zip'; Upn = 'custom@example.com' }
        @{ Label = 'IMPORT with missing keys'; Settings = ''; Unmanaged = $true; Package = 'Example.zip'; Upn = 'default@example.com' }
    ) {
        Set-StrictMode -Version Latest
        Write-DeploymentConfig -Settings $Settings
        & $script:deployScript -ArtifactsPath $TestDrive -UseUnmanagedSolutions:$Unmanaged
        Should -Invoke Import-DataverseSolution -Times 1 -Exactly -ParameterFilter {
            [IO.Path]::GetFileName($InFile) -eq $Package
        }
        Should -Invoke Get-DataverseRecord -Times 1 -Exactly -ParameterFilter {
            $TableName -eq 'systemuser' -and $FilterValues.domainname -eq $Upn
        }
    }

    It 'imports source by building artifacts and deploying unmanaged packages without upgrades' {
        Write-DeploymentConfig
        New-Item -ItemType Directory -Path (Join-Path $TestDrive 'data'), (Join-Path $TestDrive 'solutions/Example'), (Join-Path $TestDrive 'artifacts/solutions') -Force | Out-Null
        Mock Compress-DataverseSolutionFile { Set-Content -LiteralPath $OutputPath -Value 'packed' }
        Mock Copy-Item { New-Item -ItemType Directory -Path $Destination -Force | Out-Null } -ParameterFilter { $Destination -match '[\\/]alm$' }
        Mock Get-Module { [pscustomobject]@{ Version = [version]'3.0.4'; PrivateData = @{ PSData = @{ Prerelease = 'preview.1' } } } } -ParameterFilter { $Name -eq 'Rnwood.Dataverse.Data.PowerShell' }
        Mock Get-Command { [pscustomobject]@{ Source = 'Invoke-DeploymentTestDotnet' } } -ParameterFilter { $Name -eq 'dotnet' }
        Mock Test-Path { $true } -ParameterFilter { $Path -match '[\\/]\.alm4dataverse[\\/]tools$' }
        Mock Invoke-DeploymentTestDotnet { $global:LASTEXITCODE = 0; 'microsoft.powerapps.cli.tool 2.13.1 pac' }
        $savedExitCode = $global:LASTEXITCODE
        try {
            & (Join-Path $repoRoot 'pipelines/scripts/import.ps1') -SourceDirectory $TestDrive -ArtifactStagingDirectory (Join-Path $TestDrive 'artifacts')
            Should -Invoke Compress-DataverseSolutionFile -Times 1 -Exactly
            Should -Invoke Import-DataverseSolution -Times 1 -Exactly -ParameterFilter { $InFile -like '*Example.zip' -and $Mode -eq 'NoUpgrade' }
            Should -Invoke Invoke-DataverseSolutionUpgrade -Times 0 -Exactly
        }
        finally { $global:LASTEXITCODE = $savedExitCode }
    }
}
