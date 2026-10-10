param($context)
<# Example - uncomment and enter your table name
Get-DataverseRecord -TableName new_exampleconfigtable |
  Set-DataverseRecordsFolder -OutputPath $PSScriptRoot/new_exampleconfigtable -withdeletions
#>