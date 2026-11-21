@{
    # Reserved example values only. Copy this file to config.local.psd1, replace the
    # values with a dedicated test organization and environments, and keep the copy
    # out of source control.
    azdo                = @{
        organization               = 'example-organization'
        project                    = 'ALM4Dataverse setup tests'
        applicationRepositoryName  = 'alm4d-example-app'
        sharedRepositoryName       = 'ALM4Dataverse'
    }
    github              = @{
        owner                 = 'example-owner'
        applicationRepository = 'alm4d-example-app'
        sharedRepository      = 'example-owner/ALM4Dataverse'
    }
    dataverse           = @{
        dev  = @{ name = 'alm4d-dev'; url = 'https://alm4d-dev.crm.dynamics.com' }
        test = @{ name = 'alm4d-test'; url = 'https://alm4d-test.crm.dynamics.com' }
        prod = @{ name = 'RWPROD'; url = 'https://rwprod.crm.dynamics.com' }
    }
    # Licensed user that owns flows and processes; not the application identity.
    serviceAccount      = 'automation@example.invalid'
    solutionName        = 'TestSolution1'
    # Optional PowerShell 7.2-7.6 executable for setup. The pinned Dataverse module
    # fails to load its client on .NET 11, so a portable 7.6 build keeps runs
    # repeatable while the harness uses the current host.
    setupPowerShellPath = ''
    # Branch to deployment environment short-name mapping used by scenarios.
    branches            = @{
        develop = @('TEST')
        main    = @('PROD')
    }
}
