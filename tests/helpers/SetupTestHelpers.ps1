function Get-SetupProviderAst {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$EntryPoint
    )

    $providerKey = switch ([System.IO.Path]::GetFileNameWithoutExtension($EntryPoint)) {
        'setup-azdo' { 'AzDo' }
        'setup-github' { 'GitHub' }
        default { throw "Unknown setup entrypoint '$EntryPoint'." }
    }
    $setupRoot = Join-Path $RepositoryRoot 'setup'
    $manifestPath = Join-Path $setupRoot 'setup-sources.psd1'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Setup source manifest was not found at '$manifestPath'."
    }

    $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
    $sourceAsts = [System.Collections.Generic.List[System.Management.Automation.Language.ScriptBlockAst]]::new()
    foreach ($relativePath in $manifest[$providerKey]) {
        $sourcePath = Join-Path $setupRoot $relativePath
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "Setup source file was not found at '$sourcePath'."
        }

        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
        if (@($parseErrors).Count -gt 0) {
            throw "Could not parse setup source '$sourcePath': $($parseErrors[0].Message)"
        }
        $sourceAsts.Add($ast)
    }

    $providerAst = [pscustomobject]@{ SourceAsts = $sourceAsts.ToArray() }
    $providerAst | Add-Member -MemberType ScriptMethod -Name Find -Value {
        param([scriptblock]$Predicate, [bool]$SearchNestedScriptBlocks)
        foreach ($sourceAst in $this.SourceAsts) {
            $definition = $sourceAst.Find($Predicate, $SearchNestedScriptBlocks)
            if ($null -ne $definition) {
                return $definition
            }
        }
        return $null
    }
    $providerAst | Add-Member -MemberType ScriptMethod -Name FindAll -Value {
        param([scriptblock]$Predicate, [bool]$SearchNestedScriptBlocks)
        $matchingNodes = [System.Collections.Generic.List[object]]::new()
        foreach ($sourceAst in $this.SourceAsts) {
            foreach ($node in $sourceAst.FindAll($Predicate, $SearchNestedScriptBlocks)) {
                $matchingNodes.Add($node)
            }
        }
        return ,$matchingNodes.ToArray()
    }

    return $providerAst
}

function Get-SetupProviderFunctionDefinitionAst {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$EntryPoint
    )

    $ast = Get-SetupProviderAst -RepositoryRoot $RepositoryRoot -EntryPoint $EntryPoint
    return $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $false)
}

function Get-SetupProviderFunctionDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$EntryPoint,
        [Parameter(Mandatory)][string]$Name
    )

    $definition = Get-SetupProviderFunctionDefinitionAst -RepositoryRoot $RepositoryRoot -EntryPoint $EntryPoint |
        Where-Object Name -eq $Name |
        Select-Object -First 1
    if (-not $definition) {
        throw "Setup function '$Name' was not found for '$EntryPoint'."
    }
    return $definition
}

function Import-SetupProviderFunction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$EntryPoint
    )

    foreach ($definition in Get-SetupProviderFunctionDefinitionAst -RepositoryRoot $RepositoryRoot -EntryPoint $EntryPoint) {
        Set-Item -Path "Function:$($definition.Name)" -Value $definition.Body.GetScriptBlock()
    }
}
