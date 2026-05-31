@{
    # ALM for Dataverse configuration
    #
    # Paths in this file are relative to the directory this file is in (the repo root).
    #
    # FORK CONFIGURATION:
    # To customize this configuration in a fork, create a fork-almconfig.psd1 file
    # in the ALM4Dataverse repository root.
    # Fork configuration is merged with this file (this file's values take precedence).
    # Arrays are concatenated, hashtables are merged.
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
    # - serviceAccountUpnConfigKey: (optional) name of the environment configuration key containing
    #   the service account UPN to use when activating processes in this solution.
    #   The default is 'DataverseServiceAccountUpn'
    # - solutionCheck: (optional) per-solution PAC checker settings merged with global solutionCheck
    #   settings below. Use enabled = $false to skip checker for a specific solution.
    solutions = @(
        # Example:
        # @{
        #   name = 'ContosoCore'
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
    # preDeploy, dataMigrations, postDeploy:
    #   - ArtifactsPath: path to the artifacts directory
    #   - UseUnmanagedSolutions: boolean indicating if unmanaged solutions are being deployed
    #
    hooks = @{
        # Called by `pipelines/scripts/export.ps1` before exporting solutions.
        preExport  = @()

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
