<#
.SYNOPSIS
    Maps caller variables and explicitly selected secrets into action runtime values.
.DESCRIPTION
    Reads VARS_JSON, SELECTED_SECRETS_JSON and RESOLVED_ENVIRONMENT_NAME. Writes the
    process environment plus GITHUB_ENV for subsequent steps. Explicit secrets
    overwrite existing values; variable mappings fill only blank targets, preferring
    the normalized environment prefix over unprefixed fallbacks. Null/blank values
    are skipped but false and zero survive JSON serialization. Only supplied secrets
    are masked; variables are not implicitly treated as secrets.
    GITHUB_ENV must be writable. Malformed variable JSON warns and falls back empty;
    malformed/non-object selected secret JSON throws before mappings are applied.
#>
$ErrorActionPreference = 'Stop'

function ConvertTo-HashtableSafe([string]$jsonText) {
    # Optional vars context is best-effort: blank/null/parse failure becomes an
    # empty map. Successfully parsed values are returned without object validation.
    if ([string]::IsNullOrWhiteSpace($jsonText)) {
        return @{}
    }

    try {
        $result = $jsonText | ConvertFrom-Json -AsHashtable
        if ($null -eq $result) {
            return @{}
        }

        return $result
    }
    catch {
        Write-Warning 'Could not parse JSON context for prefixed mapping. Continuing without it.'
        return @{}
    }
}

function Write-GitHubEnv([string]$name, [string]$value) {
    # A unique delimiter preserves multiline values in the runner environment file.
    $delimiter = "EOF_$([Guid]::NewGuid().ToString('N'))"
    Add-Content -Path $env:GITHUB_ENV -Value "$name<<$delimiter"
    Add-Content -Path $env:GITHUB_ENV -Value $value
    Add-Content -Path $env:GITHUB_ENV -Value $delimiter
}

function Get-PrefixFromEnvironment([string]$environmentName) {
    # Match setup's environment naming convention; punctuation becomes underscores
    # and empty/punctuation-only names disable prefixed lookup.
    if ([string]::IsNullOrWhiteSpace($environmentName)) {
        return ''
    }

    $normalized = ($environmentName.Trim().ToUpperInvariant() -replace '[^A-Z0-9]+', '_').Trim('_')
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return ''
    }

    return "$normalized`_"
}

$aliasTargets = @{
    'DATAVERSE_SERVICE_ACCOUNT_UPN' = 'DATAVERSESERVICEACCOUNTUPN'
    'DATAVERSE_CONN_REFS'           = 'DATAVERSE_CONNECTION_REFS'
}

$derivedPrefix = Get-PrefixFromEnvironment $env:RESOLVED_ENVIRONMENT_NAME
$prefixCandidates = @()
if (-not [string]::IsNullOrWhiteSpace($derivedPrefix)) {
    $prefixCandidates = @($derivedPrefix)
}

$variableData = ConvertTo-HashtableSafe $env:VARS_JSON

$selectedSecrets = @{}
if (-not [string]::IsNullOrWhiteSpace($env:SELECTED_SECRETS_JSON)) {
    try {
        $selectedSecrets = $env:SELECTED_SECRETS_JSON | ConvertFrom-Json -AsHashtable
        if ($selectedSecrets -isnot [System.Collections.IDictionary]) {
            throw 'Expected a JSON object.'
        }
    }
    catch {
        throw 'SELECTED_SECRETS_JSON must contain a JSON object.'
    }
}

function ConvertTo-ValueText([object]$rawValue) {
    # Keep strings verbatim; structured values (including false/zero) become compact
    # JSON so a truthiness test cannot accidentally drop an explicit setting.
    if ($rawValue -is [string]) {
        return [string]$rawValue
    }

    return $rawValue | ConvertTo-Json -Compress -Depth 50
}

$sources = @(
    @{ Name = 'variables'; Data = $variableData; IsSensitive = $false }
)

# These are the unprefixed runtime values used by the ALM scripts. Prefixed variable
# names continue to be handled below for repository-level configuration.
$directMappings = @(
    @{ SourceLabel = 'variables'; Source = $variableData; Names = @('AZURE_CLIENT_ID'); TargetName = 'AZURE_CLIENT_ID'; IsSensitive = $false },
    @{ SourceLabel = 'variables'; Source = $variableData; Names = @('AZURE_TENANT_ID'); TargetName = 'AZURE_TENANT_ID'; IsSensitive = $false },
    @{ SourceLabel = 'variables'; Source = $variableData; Names = @('DATAVERSE_URL'); TargetName = 'DATAVERSE_URL'; IsSensitive = $false },
    @{ SourceLabel = 'variables'; Source = $variableData; Names = @('DATAVERSESERVICEACCOUNTUPN', 'DATAVERSE_SERVICE_ACCOUNT_UPN'); TargetName = 'DATAVERSESERVICEACCOUNTUPN'; IsSensitive = $false },
    @{ SourceLabel = 'variables'; Source = $variableData; Names = @('DATAVERSE_CONNECTION_REFS', 'DATAVERSE_CONN_REFS'); TargetName = 'DATAVERSE_CONNECTION_REFS'; IsSensitive = $false }
)

foreach ($variableName in $variableData.Keys) {
    if ($variableName -like 'DataverseConnRef_*' -or $variableName -like 'DataverseEnvVar_*') {
        $directMappings += @{
            SourceLabel = 'variables'
            Source = $variableData
            Names = @($variableName)
            TargetName = $variableName
            IsSensitive = $false
        }
    }
}

$setCount = 0
# Selected secrets are intentional overrides, including over existing job values.
# Later variable passes must not replace them.
foreach ($entry in $selectedSecrets.GetEnumerator()) {
    $targetName = [string]$entry.Key
    if ($null -eq $entry.Value) {
        continue
    }

    $valueText = ConvertTo-ValueText $entry.Value
    if ([string]::IsNullOrWhiteSpace($valueText)) {
        continue
    }

    [System.Environment]::SetEnvironmentVariable($targetName, $valueText)
    Write-GitHubEnv -name $targetName -value $valueText
    Write-Output "::add-mask::$valueText"
    $setCount++
    Write-Host "Mapped explicitly supplied secret to '$targetName'."
}

foreach ($mapping in $directMappings) {
    # Resolve aliases together so an environment-specific alias can beat an
    # unprefixed canonical name before either is written to the runtime target.
    $sourceName = $null
    $valueText = $null
    $candidateNames = @(
        foreach ($prefix in $prefixCandidates) {
            foreach ($name in $mapping.Names) {
                "$prefix$name"
            }
        }
    ) + $mapping.Names

    foreach ($candidateName in $candidateNames) {
        if (-not $mapping.Source.ContainsKey($candidateName)) {
            continue
        }

        $candidateValue = $mapping.Source[$candidateName]
        if ($null -eq $candidateValue) {
            continue
        }

        $candidateText = ConvertTo-ValueText $candidateValue
        if ([string]::IsNullOrWhiteSpace($candidateText)) {
            continue
        }

        $sourceName = $candidateName
        $valueText = $candidateText
        break
    }

    if ($null -eq $sourceName -or -not [string]::IsNullOrWhiteSpace([System.Environment]::GetEnvironmentVariable($mapping.TargetName))) {
        continue
    }

    [System.Environment]::SetEnvironmentVariable($mapping.TargetName, $valueText)
    Write-GitHubEnv -name $mapping.TargetName -value $valueText
    if ($mapping.IsSensitive) {
        Write-Output "::add-mask::$valueText"
    }

    $setCount++
    Write-Host "Mapped direct $($mapping.SourceLabel) '$sourceName' -> '$($mapping.TargetName)'"
}

# General prefixed variables precede the general unprefixed fallback; both only
# fill blank targets, allowing hooks to consume additional arbitrary configuration.
foreach ($source in $sources) {
    foreach ($entry in $source.Data.GetEnumerator()) {
        $fullName = [string]$entry.Key
        $matchedPrefix = $null

        foreach ($candidate in $prefixCandidates) {
            if ($fullName.StartsWith($candidate, [System.StringComparison]::OrdinalIgnoreCase)) {
                $matchedPrefix = $candidate
                break
            }
        }

        if ($null -eq $matchedPrefix) {
            continue
        }

        $targetName = $fullName.Substring($matchedPrefix.Length)
        if ([string]::IsNullOrWhiteSpace($targetName)) {
            continue
        }

        $targetNames = @($targetName)
        if ($aliasTargets.ContainsKey($targetName)) {
            $targetNames += $aliasTargets[$targetName]
        }

        $rawValue = $entry.Value
        if ($null -eq $rawValue) {
            continue
        }

        $valueText = ConvertTo-ValueText $rawValue

        if ([string]::IsNullOrWhiteSpace($valueText)) {
            continue
        }

        foreach ($name in ($targetNames | Select-Object -Unique)) {
            if (-not [string]::IsNullOrWhiteSpace([System.Environment]::GetEnvironmentVariable($name))) {
                continue
            }

            [System.Environment]::SetEnvironmentVariable($name, $valueText)
            Write-GitHubEnv -name $name -value $valueText
            if ($source.IsSensitive) {
                Write-Output "::add-mask::$valueText"
            }

            $setCount++
            Write-Host "Mapped prefixed $($source.Name) '$fullName' -> '$name'"
        }
    }
}

foreach ($source in $sources) {
    foreach ($entry in $source.Data.GetEnumerator()) {
        $targetName = [string]$entry.Key
        $isEnvironmentPrefixed = $false
        foreach ($candidate in $prefixCandidates) {
            if ($targetName.StartsWith($candidate, [System.StringComparison]::OrdinalIgnoreCase)) {
                $isEnvironmentPrefixed = $true
                break
            }
        }

        if ($isEnvironmentPrefixed -or [string]::IsNullOrWhiteSpace($targetName) -or $null -eq $entry.Value) {
            continue
        }

        $valueText = ConvertTo-ValueText $entry.Value
        if ([string]::IsNullOrWhiteSpace($valueText)) {
            continue
        }

        $targetNames = @($targetName)
        if ($aliasTargets.ContainsKey($targetName)) {
            $targetNames += $aliasTargets[$targetName]
        }

        foreach ($name in ($targetNames | Select-Object -Unique)) {
            if (-not [string]::IsNullOrWhiteSpace([System.Environment]::GetEnvironmentVariable($name))) {
                continue
            }

            [System.Environment]::SetEnvironmentVariable($name, $valueText)
            Write-GitHubEnv -name $name -value $valueText
            if ($source.IsSensitive) {
                Write-Output "::add-mask::$valueText"
            }

            $setCount++
            Write-Host "Mapped unprefixed $($source.Name) '$targetName' -> '$name'"
        }
    }
}

# azure/login's secret-auth input is emitted for the next step only. No subscription
# ID is added because these actions authenticate for Dataverse, not ARM deployment.
if (-not [string]::IsNullOrWhiteSpace($env:AZURE_CLIENT_ID) -and
    -not [string]::IsNullOrWhiteSpace($env:AZURE_TENANT_ID) -and
    -not [string]::IsNullOrWhiteSpace($env:AZURE_CLIENT_SECRET)) {
    $azureCredentials = [ordered]@{
        clientId     = $env:AZURE_CLIENT_ID
        clientSecret = $env:AZURE_CLIENT_SECRET
        tenantId     = $env:AZURE_TENANT_ID
    } | ConvertTo-Json -Compress

    Write-GitHubEnv -name 'ALM_AZURE_CREDENTIALS' -value $azureCredentials
    Write-Output "::add-mask::$azureCredentials"
}

Write-Host "Environment mapping complete. Variables set: $setCount"