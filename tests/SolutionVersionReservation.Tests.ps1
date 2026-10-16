BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repoRoot 'pipelines/scripts/common.ps1')
}

Describe 'Solution version tag reservations' {
    BeforeEach {
        $fixtureName = [guid]::NewGuid().ToString('N')
        $fixtureRoot = Join-Path $TestDrive $fixtureName
        $script:repositoryPath = Join-Path $fixtureRoot 'work'
        $script:remotePath = Join-Path $fixtureRoot 'remote.git'
        New-Item -ItemType Directory -Path $script:repositoryPath, $script:remotePath -Force | Out-Null
        # A local bare origin exercises actual remote-tag reservations without publishing anything
        # to the project's remote; each case starts with an independent tag namespace.
        & git init --bare --quiet $script:remotePath
        if ($LASTEXITCODE -ne 0) { throw 'Failed to initialize the test remote repository.' }
        & git init --quiet $script:repositoryPath
        if ($LASTEXITCODE -ne 0) { throw 'Failed to initialize the test working repository.' }
        & git -C $script:repositoryPath config user.name 'Version Reservation Tests'
        & git -C $script:repositoryPath config user.email 'version-reservation-tests@example.com'
        Set-Content -LiteralPath (Join-Path $script:repositoryPath 'README.txt') -Value 'fixture'
        & git -C $script:repositoryPath add README.txt
        & git -C $script:repositoryPath commit --quiet -m initial
        if ($LASTEXITCODE -ne 0) { throw 'Failed to create the test commit.' }
        & git -C $script:repositoryPath remote add origin $script:remotePath
        & git -C $script:repositoryPath push --quiet origin HEAD:refs/heads/main
        if ($LASTEXITCODE -ne 0) { throw 'Failed to initialize the test remote branch.' }
    }

    It 'resolves the default branch from origin when it is not supplied' {
        Mock Invoke-AlmGitCommand {
            [pscustomobject]@{ ExitCode = 0; Output = "ref: refs/heads/main`tHEAD`nremote-sha HEAD" }
        }
        Resolve-AlmDefaultBranchName -RepositoryPath $script:repositoryPath | Should -Be 'main'
    }

    It 'reserves the requested version as a remote tag' {
        $reserved = Register-AlmSolutionVersion -RepositoryPath $script:repositoryPath -SolutionName Example -Version ([version]'1.0.0.1') -IsAdditive $true

        $reserved.ToString() | Should -Be '1.0.0.1'
        $remoteTag = & git -C $script:repositoryPath ls-remote --refs origin 'refs/tags/alm4dv/solution-version/Example/1.0.0.1'
        $LASTEXITCODE | Should -Be 0
        $remoteTag | Should -Not -BeNullOrEmpty
    }

    It 'increments additive candidates when another branch already reserved them' {
        $first = Register-AlmSolutionVersion -RepositoryPath $script:repositoryPath -SolutionName Example -Version ([version]'1.0.0.1') -IsAdditive $true
        $second = Register-AlmSolutionVersion -RepositoryPath $script:repositoryPath -SolutionName Example -Version $first -IsAdditive $true

        $second.ToString() | Should -Be '1.0.0.2'
    }

    It 'increments the minor and resets revision when a non-additive candidate is already reserved' {
        $first = Register-AlmSolutionVersion -RepositoryPath $script:repositoryPath -SolutionName Example -Version ([version]'1.1.0.0') -IsAdditive $false
        $second = Register-AlmSolutionVersion -RepositoryPath $script:repositoryPath -SolutionName Example -Version $first -IsAdditive $false

        $second.ToString() | Should -Be '1.2.0.0'
    }

    It 'retries when another export wins the reservation push race' {
        # Deterministically make the candidate appear only after the first rejected push,
        # reproducing the check-then-push race without relying on concurrent process timing.
        $script:pushAttempts = 0
        $script:raceWon = $false
        Mock Invoke-AlmGitCommand {
            $argumentText = $Arguments -join ' '
            if ($Arguments[0] -eq 'check-ref-format') {
                return [pscustomobject]@{ ExitCode = 0; Output = '' }
            }
            if ($Arguments[0] -eq 'ls-remote') {
                if ($argumentText -match '1\.0\.0\.1' -and $script:raceWon) {
                    return [pscustomobject]@{ ExitCode = 0; Output = 'remote-sha refs/tags/alm4dv/solution-version/Example/1.0.0.1' }
                }
                return [pscustomobject]@{ ExitCode = 0; Output = '' }
            }
            if ($Arguments[0] -eq 'show-ref') {
                return [pscustomobject]@{ ExitCode = 1; Output = '' }
            }
            if ($Arguments[0] -eq 'push') {
                $script:pushAttempts++
                if ($script:pushAttempts -eq 1) {
                    $script:raceWon = $true
                    return [pscustomobject]@{ ExitCode = 1; Output = 'tag already exists' }
                }
                return [pscustomobject]@{ ExitCode = 0; Output = '' }
            }
            return [pscustomobject]@{ ExitCode = 0; Output = '' }
        }

        $reserved = Register-AlmSolutionVersion -RepositoryPath $script:repositoryPath -SolutionName Example -Version ([version]'1.0.0.1') -IsAdditive $true

        $reserved.ToString() | Should -Be '1.0.0.2'
        $script:pushAttempts | Should -Be 2
    }

    It 'fails explicitly when an increment would exceed the Dataverse component limit' {
        { Get-NextAlmSolutionVersion -Version ([version]::new(1, 0, 0, [int]::MaxValue)) -IsAdditive $true } | Should -Throw '*Cannot increment solution revision beyond*'
        { Get-NextAlmSolutionVersion -Version ([version]::new(1, [int]::MaxValue, 0, 0)) -IsAdditive $false } | Should -Throw '*Cannot increment solution minor beyond*'
    }
}
