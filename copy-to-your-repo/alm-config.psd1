@{
    # ALM for Dataverse configuration
    #
    # Paths in this file are relative to the directory this file is in (the repo root).
    #
    # FORK CONFIGURATION:
    # To customize defaults in a fork, edit alm-config-defaults.psd1
    # in the ALM4Dataverse repository root.
    # Fork configuration is merged with this file (this file's values take precedence).
    # Arrays append this file's items after defaults; hashtables are merged recursively.
    # This allows forks to add custom defaults without modifying this template.
    #
    # HOOK SCRIPT PATHS AND [ALM] REPLACEMENT:
    # Hook script paths can use the [alm] placeholder to reference the ALM4Dataverse
    # repository root. For example:
    #   '[alm]/custom-hooks/myScript.ps1' -> executes the script from the fork's copy of ALM4Dataverse
    # This is useful for running custom hook scripts provided by the ALM4Dataverse fork.
    # The placeholder is replaced with the absolute path to the ALM repo root before execution.

    # Solutions to process, in dependency order.
    # Each entry is a hashtable with keys
    # - name: unique solution name.
    # - deployUnmanaged: (optional) boolean indicating whether to deploy unmanaged version.
    # - mappings: (optional) ordered SolutionPackager directives used by BUILD and EXPORT.
    #   Each item can include a buildCommand that runs before packing during BUILD.
    # - serviceAccountUpnConfigKey: (optional) name of the environment configuration key containing
    #   the service account UPN to use when activating processes in this solution.
    #   The default is 'DataverseServiceAccountUpn'
    # - solutionCheck: (optional) per-solution PAC checker settings merged with global solutionCheck
    #   settings below. Use enabled = $false to skip checker for a specific solution.
    solutions = @(
        # Example:
        # @{
        #   name = 'ContosoCore'
        #   mappings = @(
        #     @{
        #       type = 'FileToFile'
        #       source = 'plugins/Contoso.Plugin/bin/Release/Contoso.Plugin.dll'
        #       destination = 'PluginAssemblies\Contoso.Plugin.dll'
        #       buildCommand = @{
        #         name = 'Build plugin'
        #         executable = 'dotnet'
        #         arguments = @('build', 'plugins/Contoso.Plugin/Contoso.Plugin.csproj', '--configuration', 'Release')
        #         workingDirectory = '.'
        #       }
        #     }
        #     @{
        #       type = 'Folder'
        #       source = 'webresources'
        #       destination = 'WebResources'
        #     }
        #     @{
        #       type = 'FileToPath'
        #       source = 'custom-resources'
        #       destination = 'Other\*.json'
        #     }
        #   )
        #   solutionCheck = @{
        #     enabled = $true
        #     # Use 'none' to omit --ruleSet.
        #     ruleSet = 'none'
        #     # Globs are expanded to concrete files before calling pac.
        #     excludedFiles = @(
        #       'CanvasApps/**/*.msapp'
        #     )
        #     ruleLevelOverride = @(
        #       @{ Id = 'meta-remove-dup-reg'; OverrideLevel = 'Medium' }
        #     )
        #     failThreshold = 'High'
        #   }
        # }
    )

    # BUILD SemVer settings. PATCH is the CI run number; the branch/provider
    # prerelease suffix is removed when the successful build is promoted.
    # MAJOR.MINOR also maps to solution Major.Build; solution Minor tracks upgrades.
    buildVersion = @{
        # MAJOR.MINOR used for branches without a specific entry.
        default = '1.0'

        # Keys are full branch names; values are MAJOR.MINOR.
        branches = @{
            main = '1.0'
            # 'develop' = '1.1'
            # 'release/1.x' = '1.0'
        }
    }

    # Export limits count package operations, including managed and unmanaged
    # packages of one solution. Both limits accept 1..8; hooks are not throttled.
    # Missing/null/empty settings use defaults; explicit parallel = $false is kept.
    export = @{
        parallel = $true
        maxParallel = 2
        maxConcurrentOperations = 4
    }

    # Build-command and packing stages each use maxParallel (1..8), independently
    # of solutionCheck.maxParallel. parallel = $false makes both stages sequential.
    build = @{
        parallel = $true
        maxParallel = 2
    }

    # Extra folders/files to include in build artifacts (copied verbatim).
    assets = @(
        'data'
    )

    # Hook scripts executed by the pipeline scripts.
    #
    # Each hook is a list of script paths (relative to repo/artifact root).
    # Hooks are optional; leave them empty (@()) when not needed.
    #
    # Hook scripts receive a -Context parameter with a hashtable containing:
    # - HookType: the type of hook being executed
    # - BaseDirectory: the base directory for the hook (source or artifacts root)
    # - Config: the loaded alm-config.psd1 configuration
    # - Additional context specific to the hook type (see details below)
    #
    # Hook-specific context:
    #
    # preBuild, postBuild:
    #   - SourceDirectory: path to the source directory
    #   - ArtifactStagingDirectory: path to the artifact staging directory
    #
    # preExport, postExport:
    #   - SourceDirectory: path to the source directory
    #   - ArtifactStagingDirectory: path to the artifact staging directory
    #   - TempDirectory: path to temporary directory for export operations
    #   - EnvironmentName: name of the Dataverse environment being exported from
    #
    # preExportSolution, postExportSolution:
    #   - SourceDirectory, ArtifactStagingDirectory, TempDirectory, EnvironmentName
    #   - SolutionName, SolutionConfig, SolutionIndex
    #   - Connection: the cloned Dataverse connection for this hook; it is the default in parallel workers
    #   - OperationBudget and CancellationToken: available for parallel exports
    #
    # preDeploy, dataMigrations, postDeploy:
    #   - ArtifactsPath: path to the artifacts directory
    #   - UseUnmanagedSolutions: boolean indicating if unmanaged solutions are being deployed
    #
    hooks = @{
        # Called by `pipelines/scripts/export.ps1` before exporting solutions.
        preExport  = @()

        # Called before each solution's export begins.
        preExportSolution = @()

        # Called after each solution is unpacked and compared. In parallel export mode,
        # hooks for different solutions run concurrently with the remaining exports.
        postExportSolution = @()

        # Called by `pipelines/scripts/export.ps1` after exporting/unpacking/version bump logic.
        postExport = @(
            'data/system/export.ps1'
        )

        # Called by `pipelines/scripts/deploy.ps1` before staging/importing solutions.
        preDeploy  = @()

        # Called by `pipelines/scripts/deploy.ps1` after publish customizations.
        postDeploy = @(
            'data/system/import.ps1'
        )

        # Called by `pipelines/scripts/build.ps1` before packing solutions.
        preBuild   = @()

        # Called by `pipelines/scripts/build.ps1` after packing solutions/copying assets.
        postBuild  = @()

        # Called by `pipelines/scripts/deploy.ps1` after solutions are staged but before upgrades.
        # Use this for data migration scripts (e.g., moving data from one column to another before they disappear).
        dataMigrations = @()
    }

    # PowerShell modules required by the scripts in addition to the default modules.
    # or to override with specific versions.

    # Key = module name,
    # Value = version ('' = latest stable version, 'prerelease' = latest prerelease, or specific version).
    scriptDependencies = @{
        # Example:
        # 'PnP.PowerShell' = '1.12.0'
    }

    # Power Apps CLI version used by pipeline scripts.
    # Optional override. Defaults from ALM4Dataverse are used when omitted.
    # Supports: '' (latest stable), 'prerelease', or a specific version.
    # pacCliVersion = '2.7.4'

    # Timeout in seconds for each solution import operation (default: 10800).
    # Increase this value if solution imports time out in large or complex environments.
    # importTimeoutSeconds = 10800

    # Optional BUILD validation baseline.
    # Empty string deploys only the current build; an Azure DevOps BUILD run ID
    # or build number, or GitHub BUILD run ID/release tag selects a fixed baseline.
    # GitHub run IDs resolve to Release assets, not expiring Actions artifacts.
    # '@environment-name' selects the most recently successful BUILD release
    # deployed to that environment.
    buildValidation = @{
        baselineRelease = ''
    }

    # PAC solution check settings used by BUILD.
    # Set enabled = $true globally or per-solution to activate checks.
    # Per-solution settings are merged with these global settings.
    #
    # Supported severities for failThreshold and OverrideLevel:
    # Critical, High, Medium, Low, Informational.
    #
    # ruleSet values:
    # - 'Solution Checker' (default)
    # - 'AppSource Certification'
    # - GUID
    # - 'none' (do not pass --ruleSet)
    #
    # solutionCheck = @{
    #     enabled = $true
    #     geo = 'Europe'
    #     failThreshold = 'Critical'
    #     ruleSet = 'Solution Checker'
    #     excludedFiles = @(
    #         'WebResources/**/*.png'
    #     )
    #     ruleLevelOverride = @(
    #         @{ Id = 'meta-remove-dup-reg'; OverrideLevel = 'Medium' }
    #     )
    #     maxParallel = 4
    # }
}
