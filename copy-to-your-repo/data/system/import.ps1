<#
.SYNOPSIS
    Provides an opt-in postDeploy hook for configuration data packaged as an asset.
.PARAMETER context
    Deployment hook context; this disabled example does not consume its fields.
.DESCRIPTION
    Runs no data operations until the examples are enabled for a real table.
    Upserts precede deletions so dependent records can be updated before obsolete
    records are removed. The caller supplies the active Dataverse connection.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'context', Justification = 'Required hook entry-point contract available to repository-specific implementations.')]
param($context)
### Phase 1 - Upsert new and updated records

<# Example - uncomment and enter your table name
Get-DataverseRecordsFolder -InputPath $PSScriptRoot/new_exampleconfigtable |
  Set-DataverseRecord -TableName new_exampleconfigtable -Verbose
#>

### Phase 2 - Remove deleted records

<# Example - uncomment and enter your table name
Get-DataverseRecordsFolder -InputPath $PSScriptRoot/new_exampleconfigtable -deletions |
  Remove-DataverseRecord -TableName new_exampleconfigtable -Verbose -IfExists
#>