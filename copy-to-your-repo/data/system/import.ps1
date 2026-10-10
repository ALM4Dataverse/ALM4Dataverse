param($context)
### Phase 1 - Upsert new and updated records

<# Example - uncomment and enter your table name
Get-DataverseRecordsFolder -InputPath $PSScriptRoot/new_exampleconfigtable |
  Set-DataverseRecord -TableName new_exampleconfigtable -Verbose
#>

### Phase 2 - Remove deleted records

<# Example - uncomment and enter your table name
Get-DataverseRecordsFolder -InputPath $PSScriptRoot/new_exampleconfigtable -deletions |
     Remove-DataverseRecord -Connection $c -Verbose -IfExists
#>