function Get-AlmSharedTemplateVersion {
    <#
    .SYNOPSIS
        Returns the shared template version embedded in generated caller files.
    .DESCRIPTION
        Shared templates and composite actions stop caller files that were generated
        for a different version. Bump this value whenever a shared template or action
        change requires callers to be regenerated, and update the expected literals in
        pipelines/templates/steps/validate-shared-template-version.yml and
        .github/actions/common/validate-caller-version.ps1 in the same change; the
        repository tests enforce that all three agree.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return '2'
}
