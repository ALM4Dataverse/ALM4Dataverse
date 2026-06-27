<#
.SYNOPSIS
    Exports Dataverse solutions from a specified environment and unpacks them into the source directory.
.DESCRIPTION
    This script exports the Dataverse solutions defined in alm-config.psd1 from the connected
    Dataverse environment. It exports both managed and unmanaged versions of each solution
    and saves them to the specified artifact staging directory.

    After exporting, it unpacks each solution into the source directory's solution folders.
    If any changes are detected in the unpacked solutions compared to the existing source,
    it increments the solution version in both the source and the environment.

    Hooks defined in alm-config.psd1 are invoked at various stages of the export process
    to allow for custom pre- and post-export actions.
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$SourceDirectory,
    
    [Parameter(Mandatory=$true)]
    [string]$ArtifactStagingDirectory,

    [string]$TempDirectory = "([IO.Path]::GetTempPath())\$([IO.Path]::GetTempFileName())",
    
    [Parameter(Mandatory=$false)]
    [string]$EnvironmentName = "Unknown"
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot 'common.ps1')

Write-Host "##[section]Exporting Solutions from $EnvironmentName"

# Read solutions configuration
$solutionsConfig = Get-AlmConfig -BaseDirectory $SourceDirectory

Invoke-Hooks -HookType "preExport" -BaseDirectory $SourceDirectory -Config $solutionsConfig -AdditionalContext @{
    SourceDirectory = $SourceDirectory
    ArtifactStagingDirectory = $ArtifactStagingDirectory
    TempDirectory = $TempDirectory
    EnvironmentName = $EnvironmentName
}

foreach ($solution in $solutionsConfig.solutions) {
    $solutionName = $solution.name
    
    # Determine source format: per-solution override → global config → default ('Yaml')
    $globalSourceFormat = if ($solutionsConfig.sourceFormat) { [string]$solutionsConfig.sourceFormat } else { 'Yaml' }
    $solutionSourceFormat = if ($solution.sourceFormat) { [string]$solution.sourceFormat } else { $globalSourceFormat }

    # Resolve map file if specified (path relative to SourceDirectory)
    $mapFile = $null
    if ($solution.mapFile) {
        $mapFile = Join-Path $SourceDirectory ([string]$solution.mapFile)
        if (-not (Test-Path $mapFile)) {
            Write-Host "##[warning]Map file not found for solution '$solutionName': $mapFile"
            $mapFile = $null
        }
        else {
            Write-Host "##[debug]Using map file: $mapFile"
        }
    }

    Write-Host "##[group]Exporting and unpacking solution: $solutionName (format: $solutionSourceFormat) to folder $SourceDirectory/solutions/$solutionName"
    
    if (-not (Test-Path "$SourceDirectory/solutions")) {
        New-Item -ItemType Directory -Path "$SourceDirectory/solutions" | Out-Null
    } 

    if ((Test-Path $SourceDirectory/solutions/$solutionName)) {
        $oldPackArgs = @{
            PackageType = 'Managed'
            OutputPath  = "$TempDirectory/$solutionName-managed.old.zip"
            Path        = "$SourceDirectory/solutions/$solutionName"
        }
        if ($mapFile) { $oldPackArgs['MapFile'] = $mapFile }
        Compress-DataverseSolutionFile @oldPackArgs
        Remove-Item -Recurse -Force "$SourceDirectory/solutions/$solutionName"
    }

    $exportArgs = @{
        Verbose        = $true
        SolutionName   = $solutionName
        OutFolder      = "$SourceDirectory/solutions/$solutionName"
        UnpackMsApp    = $true
        SourceFormat   = $solutionSourceFormat
    }
    if ($mapFile) { $exportArgs['MapFile'] = $mapFile }
    Export-DataverseSolution @exportArgs
    
    Write-Host "##[endgroup]"
   
    Write-Host "##[group]Checking for solution changes: $solutionName"

    # For XML format, normalize Solution.xml so the comparison isn't skewed by indentation differences.
    if ($solutionSourceFormat -eq 'Xml') {
        $solutionXmlPath = "$SourceDirectory/solutions/$solutionName/Other/Solution.xml"
        [xml]$solutionXml = Get-Content -Path $solutionXmlPath
        $solutionXml.Save($solutionXmlPath)
    }

    # Test if anything changed and increment version if so
    $gitStatus = git -C "$SourceDirectory" status --porcelain solutions/$solutionName
    if ([string]::IsNullOrEmpty($gitStatus)) {
        Write-Host "##[debug]No changes detected in solution: $solutionName"
    } else {
        Write-Host "##[debug]Changes detected in solution: $solutionName`n$gitStatus"

        if ((Test-Path "$TempDirectory/$solutionName-managed.old.zip")) {       
            $newPackArgs = @{
                PackageType = 'Managed'
                OutputPath  = "$TempDirectory/$solutionName-managed.new.zip"
                Path        = "$SourceDirectory/solutions/$solutionName"
            }
            if ($mapFile) { $newPackArgs['MapFile'] = $mapFile }
            Compress-DataverseSolutionFile @newPackArgs

            $changesareadditive = (Compare-DataverseSolutionComponents -FileToFile -SolutionFile "$TempDirectory/$solutionName-managed.new.zip" -TargetSolutionFile "$TempDirectory/$solutionName-managed.old.zip" -TestIfAdditive -Verbose)
            if ($changesareadditive) {
                Write-Host "##[debug]Changes are additive only."
            } else {
                Write-Host "##[debug]Changes include non-additive changes."
            }

            Remove-Item -Path "$TempDirectory/$solutionName-managed.old.zip","$TempDirectory/$solutionName-managed.new.zip"
        } else {
            $changesareadditive = $true
        }

        $currentVersion = Get-SolutionVersion -SolutionFolder "$SourceDirectory/solutions/$solutionName" -SolutionName $solutionName -Format $solutionSourceFormat

        if ($changesareadditive) {
            $newversion = [version] "$($currentVersion.Major).$($currentVersion.Minor).$([Math]::Max(0, $currentVersion.Build)).$([Math]::Max(0, $currentVersion.Revision) + 1)"
        } else {
            $newversion = [version] "$($currentVersion.Major).$([Math]::Max(0, $currentVersion.Minor)+1).0.0"
        }

        Set-SolutionVersion -SolutionFolder "$SourceDirectory/solutions/$solutionName" -SolutionName $solutionName -Format $solutionSourceFormat -Version $newversion

        Set-DataverseSolution -UniqueName $solutionName -Version $newversion.ToString()
        Write-Host "##[debug]Updated environment solution version to $newversion"
    }

 
    
    Write-Host "##[endgroup]"
}

Invoke-Hooks -HookType "postExport" -BaseDirectory $SourceDirectory -Config $solutionsConfig -AdditionalContext @{
    SourceDirectory = $SourceDirectory
    ArtifactStagingDirectory = $ArtifactStagingDirectory
    TempDirectory = $TempDirectory
    EnvironmentName = $EnvironmentName
}

Write-Host "##[section]Export completed successfully!"
