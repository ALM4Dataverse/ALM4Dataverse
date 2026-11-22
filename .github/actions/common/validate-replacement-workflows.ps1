<#
.SYNOPSIS
    Stops a build while generated workflows are waiting in replace-github-workflows/.
.DESCRIPTION
    Setup puts the generated workflows in replace-github-workflows/ because the default
    token cannot change .github/workflows. Replacing .github/workflows with that folder
    removes it, so its presence means the generated workflows are not applied yet.
.PARAMETER RepositoryRoot
    Root of the checked-out caller repository.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepositoryRoot
)

$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath (Join-Path $RepositoryRoot 'replace-github-workflows')) {
    throw 'replace-github-workflows/ exists, so the generated workflows have not been applied. Delete .github/workflows, rename replace-github-workflows to .github/workflows, and commit. Then run the build again.'
}
