# Data Import and Export for Config/System Data

Use hooks to version small, intentional sets of configuration or lookup records with
your solutions.

> [!CAUTION]
> This is not an environment backup or a general-purpose production data migration
> service. Exported records become repository content. Choose tables/columns explicitly,
> review privacy requirements, and never export passwords, tokens, or customer data
> unintentionally.

The supplied [export script](../../../copy-to-your-repo/data/system/export.ps1) and
[import script](../../../copy-to-your-repo/data/system/import.ps1) contain commented
examples; they do nothing until customized. EXPORT commits the record files, BUILD
copies them as assets, and DEPLOY/IMPORT run the import hook. BUILD validation also
runs deployment hooks against its validation environment.

For further information about this approach see the following articles:

- [Rob Wood - Versioning config data in D365/Power Apps - beyond the Configuration Migration Tool](https://rnwood.co.uk/posts/versioning-config-data-in-power-platform-beyond-the-cmt)
- [Rob Wood - Versioning config data in D365/Power Apps - beyond the CMT - part 2](https://rnwood.co.uk/posts/versioning-config-data-in-power-platform-beyond-the-cmt-part2/)

The following configuration is required to ensure the example scripts below are executed and that the resulting `data` folder is copied to build assets (so it's available to deploy from).

Merge these entries into the existing application configuration:

```powershell
@{
  hooks = @{
    postExport = @('data/system/export.ps1')
    postDeploy = @('data/system/import.ps1')
  }
  assets = @('data')
}
```

## Exporting

Add your tables with the pattern below, reproducing the block for each table. By default, all non-system columns will be output. You can add `-columns new_column1, new_column2` if you'd rather list them individually.

Edit the [export hook](../../../copy-to-your-repo/data/system/export.ps1):

```powershell
param([hashtable]$Context)

$ErrorActionPreference = 'Stop'

Get-DataverseRecord -TableName new_exampleconfigtable |
  Set-DataverseRecordsFolder -OutputPath $PSScriptRoot/new_exampleconfigtable -withdeletions

Get-DataverseRecord -TableName new_anotherconfigtable |
  Set-DataverseRecordsFolder -OutputPath $PSScriptRoot/new_anotherconfigtable -withdeletions
```

When `EXPORT` runs, a folder will be created, with a JSON file representing each record.

The filename is the ID of the record. For some records (for example Teams automatically created when Business Units are created) this is an unstable system-generated value. You can specify a list of column names to `-idproperties` to use these instead. For example  `-idproperties new_name` or  `-idproperties firstname, lastname`

`-withdeletions` is optional. It records the records you've deleted in a subfolder called `deletions` so you can take action to mirror this as deletions or deactivations. See the section below for options when processing these.

> [!NOTE]
> **Advanced: record identity.** Primary IDs work when the same logical records are
> created with the same IDs across environments. Natural-key matching may be needed for
> pre-existing target records. Test lookup resolution as well as top-level records.

## Importing/Deploying

Add your tables with the pattern below, reproducing the block for each table. Upsert
referenced tables before the tables that depend on them. For circular dependencies,
break the chain first, then set the remaining lookup field in a second step.

> [!CAUTION]
> The example's second phase deletes target records. Review dependency order, test
> deletion markers in non-production, and make repeated runs safe before enabling it
> for production data. Deletes may need the reverse order from upserts.

Edit the [import hook](../../../copy-to-your-repo/data/system/import.ps1):

```powershell
param([hashtable]$Context)

$ErrorActionPreference = 'Stop'

### Phase 1 - Upsert new and updated records

Get-DataverseRecordsFolder -InputPath $PSScriptRoot/new_exampleconfigtable |
  Set-DataverseRecord -TableName new_exampleconfigtable -Verbose

Get-DataverseRecordsFolder -InputPath $PSScriptRoot/new_anotherconfigtable |
  Set-DataverseRecord -TableName new_anotherconfigtable -Verbose

### Phase 2 - Remove/deactivate deleted records

Get-DataverseRecordsFolder -InputPath $PSScriptRoot/new_anotherconfigtable -deletions |
  Remove-DataverseRecord -TableName new_anotherconfigtable -Verbose -IfExists

Get-DataverseRecordsFolder -InputPath $PSScriptRoot/new_exampleconfigtable -deletions |
  Remove-DataverseRecord -TableName new_exampleconfigtable -Verbose -IfExists
```

The first phase creates or updates records.

The standard process will upsert records matching them to existing records on the primary ID. This can be varied with the `-matchon` option for `Set-DataverseRecord`. For example `-matchon firstname, lastname`.

The second phase deals with any records that have been removed from the source. You can either delete them, deactivate them, or add custom logic to rename them with a prefix.

Review deletion order for related tables: upserts normally follow dependency order,
while deletes may need the reverse. Deletion markers can be replayed on later releases,
so use repeatable operations such as `-IfExists` and retain the intended history.
For deactivation, use that table's valid `statecode`/`statuscode` combination instead of
assuming one status value works for every table.

> [!TIP]
> Reuse the pipeline's default Dataverse connection; an undefined `$c` variable is not
> needed. Resolve record folders from `$PSScriptRoot` so the same script works from source
> and packaged artifacts. Keep related scripts/files in `assets` and fail on errors.

Test upserts, relationships, deletion markers, and a second run against a non-production
target before enabling deletion in production.

For schema-changing migrations that need both old and new columns, use the
[`dataMigrations` hook](../alm-config.md#hooks) and review its single-solution timing caveat.
