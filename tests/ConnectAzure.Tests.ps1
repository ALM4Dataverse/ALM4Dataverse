BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $script:connectAzScript = Join-Path $repoRoot 'pipelines/scripts/connect-az.ps1'

    function Connect-AzAccount {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        param(
            [switch]$ServicePrincipal,
            $Tenant,
            [PSCredential]$Credential,
            $ApplicationId,
            $FederatedToken,
            [switch]$SkipContextPopulation
        )
    }
    function az {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock command signature; Pester inspects these arguments.')]
        param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    }
}

Describe 'Azure DevOps Az PowerShell sign-in' {
    It 'includes Az.Accounts for Azure CLI and PowerShell authentication' {
        (Import-PowerShellDataFile (Join-Path $repoRoot 'alm-config-defaults.psd1')).scriptDependencies.ContainsKey('Az.Accounts') | Should -BeTrue
    }

    BeforeEach {
        $script:savedAuthEnvironment = @{
            AZURE_CLIENT_ID = $env:AZURE_CLIENT_ID
            AZURE_TENANT_ID = $env:AZURE_TENANT_ID
            AZURE_CLIENT_SECRET = $env:AZURE_CLIENT_SECRET
            AZURE_FEDERATED_TOKEN_FILE = $env:AZURE_FEDERATED_TOKEN_FILE
        }
        $script:savedExitCode = $global:LASTEXITCODE
        $env:AZURE_CLIENT_ID = 'application-id'
        $env:AZURE_TENANT_ID = 'tenant-id'
        $env:AZURE_CLIENT_SECRET = $null
        $env:AZURE_FEDERATED_TOKEN_FILE = $null
        Mock Connect-AzAccount {}
        Mock az { $global:LASTEXITCODE = 0 }
    }

    AfterEach {
        foreach ($name in $script:savedAuthEnvironment.Keys) {
            [System.Environment]::SetEnvironmentVariable($name, $script:savedAuthEnvironment[$name])
        }
        $global:LASTEXITCODE = $script:savedExitCode
    }

    It 'connects using a service-principal client secret' {
        $env:AZURE_CLIENT_SECRET = 'client-secret'

        & $script:connectAzScript

        Should -Invoke Connect-AzAccount -Times 1 -Exactly -ParameterFilter {
            $ServicePrincipal -and $Tenant -eq 'tenant-id' -and
            $Credential.UserName -eq 'application-id' -and
            $Credential.GetNetworkCredential().Password -eq 'client-secret' -and
            $SkipContextPopulation
        }
        Should -Invoke az -Times 1 -Exactly -ParameterFilter {
            $Arguments -contains 'login' -and
            $Arguments -contains '--service-principal' -and
            $Arguments -contains '--username' -and
            $Arguments -contains 'application-id' -and
            $Arguments -contains '--tenant' -and
            $Arguments -contains 'tenant-id' -and
            $Arguments -contains '--allow-no-subscriptions' -and
            $Arguments -contains '--output' -and
            $Arguments -contains 'none' -and
            $Arguments -contains '--password=client-secret'
        }
    }

    It 'connects using the WIF token file' {
        $tokenPath = Join-Path $TestDrive 'federated-token'
        Set-Content -LiteralPath $tokenPath -Value 'federated-token'
        $env:AZURE_FEDERATED_TOKEN_FILE = $tokenPath
        $env:AZURE_CLIENT_SECRET = '$(AZURE_CLIENT_SECRET)'

        & $script:connectAzScript

        Should -Invoke Connect-AzAccount -Times 1 -Exactly -ParameterFilter {
            $ServicePrincipal -and $Tenant -eq 'tenant-id' -and
            $ApplicationId -eq 'application-id' -and
            $FederatedToken -eq 'federated-token' -and $SkipContextPopulation
        }
        $env:AZURE_CLIENT_SECRET | Should -BeNullOrEmpty
        Should -Invoke az -Times 1 -Exactly -ParameterFilter {
            $Arguments -contains '--federated-token' -and
            $Arguments -contains 'federated-token'
        }
    }

    It 'fails when neither supported service-connection credential is available' {
        { & $script:connectAzScript } | Should -Throw '*did not provide AZURE_CLIENT_SECRET or AZURE_FEDERATED_TOKEN_FILE*'

        Should -Invoke Connect-AzAccount -Times 0 -Exactly
        Should -Invoke az -Times 0 -Exactly
    }

    It 'fails if the WIF token file is missing' {
        $env:AZURE_FEDERATED_TOKEN_FILE = Join-Path $TestDrive 'missing-token'

        { & $script:connectAzScript } | Should -Throw '*was not found*'

        Should -Invoke Connect-AzAccount -Times 0 -Exactly
        Should -Invoke az -Times 0 -Exactly
    }

    It 'fails if Azure CLI login returns a nonzero exit code' {
        $env:AZURE_CLIENT_SECRET = 'client-secret'
        Mock az { $global:LASTEXITCODE = 1 }

        { & $script:connectAzScript } | Should -Throw '*Azure CLI login failed with exit code 1*'

        Should -Invoke az -Times 1 -Exactly
    }
}
