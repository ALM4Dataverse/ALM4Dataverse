<#
.SYNOPSIS
    Provides an opt-in postExport hook for repository-owned configuration data.
.PARAMETER context
    Hook context supplied by the pipeline; this empty example uses no fields.
.DESCRIPTION
    Does nothing until the sample is enabled and its table name is replaced.
    The pipeline has already connected; exported folders belong beside this script
    so the data asset can travel with the solution artifacts.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'context', Justification = 'Required hook entry-point contract available to repository-specific implementations.')]
param($context)
<# Example - uncomment and enter your table name
Get-DataverseRecord -TableName new_exampleconfigtable |
  Set-DataverseRecordsFolder -OutputPath $PSScriptRoot/new_exampleconfigtable -withdeletions
#>