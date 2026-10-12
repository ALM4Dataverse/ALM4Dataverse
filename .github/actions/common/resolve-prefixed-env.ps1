$ErrorActionPreference = 'Stop'

function ConvertTo-HashtableSafe([string]$jsonText) {
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
    $delimiter = "EOF_$([Guid]::NewGuid().ToString('N'))"
    Add-Content -Path $env:GITHUB_ENV -Value "$name<<$delimiter"
    Add-Content -Path $env:GITHUB_ENV -Value $value
    Add-Content -Path $env:GITHUB_ENV -Value $delimiter
}

function Get-PrefixFromEnvironment([string]$environmentName) {
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
$prefixCandidates = @('PREFIX_')
if (-not [string]::IsNullOrWhiteSpace($derivedPrefix) -and $derivedPrefix -ne 'PREFIX_') {
    $prefixCandidates = @($derivedPrefix) + $prefixCandidates
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
    @{ SourceLabel = 'variables'; Source = $variableData; Names = @('DATAVERSESERVICEACCOUNTUPN'); TargetName = 'DATAVERSESERVICEACCOUNTUPN'; IsSensitive = $false },
    @{ SourceLabel = 'variables'; Source = $variableData; Names = @('DATAVERSE_CONNECTION_REFS', 'DATAVERSE_CONN_REFS'); TargetName = 'DATAVERSE_CONNECTION_REFS'; IsSensitive = $false }
)

$setCount = 0
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
    $sourceName = $null
    $valueText = $null

    foreach ($candidateName in $mapping.Names) {
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