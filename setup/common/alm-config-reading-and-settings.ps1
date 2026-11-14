function Get-AlmConfigForSetup {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$ConfigPath
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        return @{}
    }

    try {
        return (Import-PowerShellDataFile -LiteralPath $ConfigPath)
    }
    catch {
        throw "Could not import ALM setup configuration '$ConfigPath': $($_.Exception.Message)"
    }
}

function ConvertFrom-AlmConfigContentForSetup {
    <#
    .SYNOPSIS
        Imports a committed alm-config.psd1 value without changing the repository.
    .DESCRIPTION
        Writes the supplied data-file text to a uniquely named temporary PSD1,
        imports it with Import-PowerShellDataFile, and removes the temporary file.
        Invalid data or filesystem failures throw with setup context.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowEmptyString()][string]$ConfigContent = ''
    )

    if ([string]::IsNullOrWhiteSpace($ConfigContent)) {
        return @{}
    }

    $temporaryPath = Join-Path ([System.IO.Path]::GetTempPath()) ("alm-config-setup-" + [guid]::NewGuid().ToString('n') + '.psd1')
    try {
        Set-Content -LiteralPath $temporaryPath -Value $ConfigContent -NoNewline
        $configuration = Import-PowerShellDataFile -LiteralPath $temporaryPath
        if ($configuration -isnot [System.Collections.IDictionary]) {
            throw 'The root value must be a hashtable.'
        }
        return $configuration
    }
    catch {
        throw "Could not import committed alm-config.psd1 content: $($_.Exception.Message)"
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction Stop
        }
    }
}

function Get-AlmSetupBranchConfiguration {
    <#
    .SYNOPSIS
        Returns one branch's setup settings by case-insensitive branch name.
    .DESCRIPTION
        A missing branches map or branch returns an empty hashtable. Malformed branch
        maps and branch values throw rather than silently reverting to workflow discovery.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary], [System.Collections.Hashtable])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][string]$BranchName
    )

    if (-not $Config.Contains('branches') -or $null -eq $Config.branches) {
        return @{}
    }
    if ($Config.branches -isnot [System.Collections.IDictionary]) {
        throw 'The branches setting in alm-config.psd1 must be a hashtable keyed by branch name.'
    }

    foreach ($configuredBranchName in $Config.branches.Keys) {
        if ([string]$configuredBranchName -ieq $BranchName) {
            $branchConfiguration = $Config.branches[$configuredBranchName]
            if ($branchConfiguration -isnot [System.Collections.IDictionary]) {
                throw "Configuration for branch '$BranchName' in alm-config.psd1 must be a hashtable."
            }
            return $branchConfiguration
        }
    }

    return @{}
}

function Assert-AlmSetupConfigurationForApply {
    <#
    .SYNOPSIS
        Validates the minimum setup metadata required to generate repository artifacts.
    .DESCRIPTION
        ApplyConfig requires an explicit provider, shared repository/ref, and at least
        one branch. It never infers missing values from existing caller files.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Configuration,
        [Parameter(Mandatory)][ValidateSet('GitHub', 'azDO')][string]$Provider
    )

    if ([string](Get-OptionalObjectPropertyValue -InputObject $Configuration -PropertyName 'provider') -ine $Provider) {
        throw "ApplyConfig requires alm-config.psd1 to declare provider = '$Provider'."
    }

    foreach ($propertyName in @('repository', 'ref')) {
        if (
            -not $Configuration.Contains($propertyName) -or
            $Configuration[$propertyName] -isnot [string] -or
            [string]::IsNullOrWhiteSpace($Configuration[$propertyName])
        ) {
            throw "ApplyConfig requires a non-empty '$propertyName' string in alm-config.psd1."
        }
    }

    if (-not $Configuration.Contains('branches') -or $Configuration.branches -isnot [System.Collections.IDictionary] -or $Configuration.branches.Count -eq 0) {
        throw 'ApplyConfig requires a non-empty branches map in alm-config.psd1.'
    }

    foreach ($branchName in $Configuration.branches.Keys) {
        if ([string]::IsNullOrWhiteSpace([string]$branchName)) {
            throw 'ApplyConfig requires every branches map key to be a non-empty branch name.'
        }
        if ($Configuration.branches[$branchName] -isnot [System.Collections.IDictionary]) {
            throw "Configuration for branch '$branchName' in alm-config.psd1 must be a hashtable."
        }
    }

    return $Configuration
}

function Get-AlmSetupBuildValidationEnvironmentMap {
    <#
    .SYNOPSIS
        Builds a branch-to-environment map for generated BUILD callers.
    .DESCRIPTION
        Includes only enabled branches and throws when an enabled branch lacks a
        branch name or validation environment.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][array]$BranchStates
    )

    $environments = [ordered]@{}
    foreach ($branchState in $BranchStates) {
        if (-not [bool](Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'BuildValidationEnabled')) {
            continue
        }

        $branchName = [string](Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'BranchName')
        $environmentConfiguration = Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'BuildValidationEnvironmentConfiguration'
        $environmentName = [string](Get-OptionalObjectPropertyValue -InputObject $environmentConfiguration -PropertyName 'ShortName')
        if ([string]::IsNullOrWhiteSpace($environmentName)) {
            $environmentName = [string](Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'BuildValidationEnvironmentName')
        }
        if ([string]::IsNullOrWhiteSpace($branchName) -or [string]::IsNullOrWhiteSpace($environmentName)) {
            throw 'Enabled BUILD validation state must include a branch name and environment name.'
        }

        $environments[$branchName] = $environmentName
    }

    return $environments
}

function Get-AlmSetupConfiguration {
    <#
    .SYNOPSIS
        Builds the provider-neutral setup portion of alm-config.psd1.
    .DESCRIPTION
        Serializes shared provider/repository/ref keys, flat provider-specific options,
        and each branch's development, deployment and BUILD validation environments.
        Disabled BUILD validation is written explicitly to prevent legacy global
        selectors from being inherited by that branch.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][ValidateSet('GitHub', 'azDO')][string]$Provider,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Ref,
        [Parameter(Mandatory)][array]$BranchStates,
        [Parameter()][System.Collections.IDictionary]$ProviderOptions = @{}
    )

    $settings = [ordered]@{
        provider = $Provider
        repository = $Repository
        ref = $Ref
    }
    foreach ($option in $ProviderOptions.GetEnumerator()) {
        $settings[[string]$option.Key] = $option.Value
    }

    $branches = [ordered]@{}
    foreach ($branchState in $BranchStates) {
        $branchName = [string](Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'BranchName')
        if ([string]::IsNullOrWhiteSpace($branchName)) {
            throw 'Branch setup state must include a non-empty BranchName.'
        }

        $devEnvironment = Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'DevEnvironmentConfiguration'
        $developmentEnvironmentName = [string](Get-OptionalObjectPropertyValue -InputObject $devEnvironment -PropertyName 'ShortName')
        $deploymentEnvironmentNames = @(
            Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'DeploymentEnvironments' |
                ForEach-Object { [string](Get-OptionalObjectPropertyValue -InputObject $_ -PropertyName 'ShortName') } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )

        $buildValidationEnabled = [bool](Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'BuildValidationEnabled')
        $buildEnvironment = Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'BuildValidationEnvironmentConfiguration'
        $buildEnvironmentName = [string](Get-OptionalObjectPropertyValue -InputObject $buildEnvironment -PropertyName 'ShortName')
        if ([string]::IsNullOrWhiteSpace($buildEnvironmentName)) {
            $buildEnvironmentName = [string](Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'BuildValidationEnvironmentName')
        }
        if ($buildValidationEnabled -and [string]::IsNullOrWhiteSpace($buildEnvironmentName)) {
            throw "BUILD validation for branch '$branchName' is enabled but has no environment name."
        }

        $branches[$branchName] = [ordered]@{
            developmentEnvironment = $developmentEnvironmentName
            deploymentEnvironments = $deploymentEnvironmentNames
            buildValidation = [ordered]@{
                environmentName = $(if ($buildValidationEnabled) { $buildEnvironmentName } else { '' })
                baselineRelease = $(if ($buildValidationEnabled) { [string](Get-OptionalObjectPropertyValue -InputObject $branchState -PropertyName 'BuildValidationBaselineRelease') } else { '' })
            }
        }
    }
    $settings.branches = $branches
    return $settings
}

function Set-AlmConfigSetupSettingsInFile {
    <#
    .SYNOPSIS
        Updates selected top-level setup settings while preserving unrelated source.
    .PARAMETER Settings
        A hashtable of provider, repository, ref, provider options and branch settings.
        Values must be PowerShell data types; scriptblocks and arbitrary objects fail.
    .DESCRIPTION
        Replaces only the selected root values or inserts missing keys. Existing
        comments and unrelated configuration remain untouched. Missing files require
        CreateIfMissing. Parse, shape and unsupported-value errors throw; writes are
        not transactional. Returns whether the file text changed.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings,
        [Parameter()][switch]$CreateIfMissing,
        [Parameter()][string]$TemplatePath
    )

    if (-not $PSCmdlet.ShouldProcess($ConfigPath, 'Update ALM setup settings')) {
        return $false
    }

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        if (-not $CreateIfMissing) {
            throw "alm-config.psd1 not found: $ConfigPath"
        }

        if (-not [string]::IsNullOrWhiteSpace($TemplatePath) -and (Test-Path -LiteralPath $TemplatePath)) {
            Copy-Item -LiteralPath $TemplatePath -Destination $ConfigPath -Force
        }
        else {
            Set-Content -LiteralPath $ConfigPath -Value "@{`n}`n" -NoNewline
        }
    }

    $configContent = Get-Content -LiteralPath $ConfigPath -Raw
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($configContent, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        throw "Could not parse existing alm-config.psd1 '$ConfigPath': $($parseErrors[0].Message)"
    }

    $rootHashtable = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.HashtableAst]
    }, $false)
    if (-not $rootHashtable) {
        throw "Could not find the root hashtable in '$ConfigPath'."
    }

    $lineEnding = if ($configContent -match "`r`n") { "`r`n" } else { "`n" }
    $replacements = @()
    $insertions = @()
    foreach ($setting in $Settings.GetEnumerator()) {
        $keyName = [string]$setting.Key
        if ([string]::IsNullOrWhiteSpace($keyName)) {
            throw 'ALM setup setting names cannot be empty.'
        }

        $serializedValue = ConvertTo-SetupPowerShellDataLiteral -Value $setting.Value
        $settingEntry = $rootHashtable.KeyValuePairs | Where-Object {
            $keyText = $_.Item1.Extent.Text.Trim()
            $keyText.Trim("'").Trim('"') -ieq $keyName
        } | Select-Object -First 1

        if ($settingEntry) {
            $valueExtent = $settingEntry.Item2.Extent
            $replacements += [pscustomobject]@{
                StartOffset = $valueExtent.StartOffset
                EndOffset   = $valueExtent.EndOffset
                Value       = $serializedValue
            }
        }
        else {
            $escapedKey = $keyName.Replace("'", "''")
            $insertions += "    '$escapedKey' = $serializedValue"
        }
    }

    $updatedContent = $configContent
    if ($insertions.Count -gt 0) {
        $insertOffset = $rootHashtable.Extent.EndOffset - 1
        $prefix = if ($insertOffset -gt 0 -and $configContent.Substring(0, $insertOffset).EndsWith($lineEnding)) { '' } else { $lineEnding }
        $insertText = $prefix + ($insertions -join $lineEnding) + $lineEnding
        $replacements += [pscustomobject]@{
            StartOffset = $insertOffset
            EndOffset   = $insertOffset
            Value       = $insertText
        }
    }

    foreach ($replacement in @($replacements | Sort-Object StartOffset -Descending)) {
        $updatedContent = $updatedContent.Substring(0, $replacement.StartOffset) +
            $replacement.Value +
            $updatedContent.Substring($replacement.EndOffset)
    }

    $hasChanges = ($updatedContent -ne $configContent)
    if ($hasChanges) {
        Set-Content -LiteralPath $ConfigPath -Value $updatedContent -NoNewline
    }

    return $hasChanges
}
