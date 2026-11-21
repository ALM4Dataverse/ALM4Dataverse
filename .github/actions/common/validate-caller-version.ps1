<#
.SYNOPSIS
    Stops a workflow whose caller files were generated for another template version.
.DESCRIPTION
    Composite actions invoke this guard first. A missing or stale
    shared-template-version input fails with an instruction to regenerate the
    caller workflows from the shared repository ref they reference. Bump the
    expected literal together with setup/common/shared-template-version.ps1 and
    pipelines/templates/steps/validate-shared-template-version.yml.
.PARAMETER ActualVersion
    Version passed by the caller workflow's shared-template-version input.
#>
[CmdletBinding()]
param(
    [Parameter()][AllowEmptyString()][string]$ActualVersion = ''
)

$ErrorActionPreference = 'Stop'
if ($ActualVersion -ne '2') {
    throw "This workflow was generated for shared template version '$ActualVersion', but the ALM4Dataverse actions it references require version '2'. Re-run setup from the shared repository ref this workflow references (guided setup or setup-github.ps1 -ApplyConfig) to regenerate this file; do not edit it by hand."
}
