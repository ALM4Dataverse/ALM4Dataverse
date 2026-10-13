[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'context', Justification = 'Required hook entry-point contract available to repository-specific implementations.')]
param($context)
<# Example - uncomment and enter your table name
Get-DataverseRecord -TableName new_exampleconfigtable |
  Set-DataverseRecordsFolder -OutputPath $PSScriptRoot/new_exampleconfigtable -withdeletions
#>