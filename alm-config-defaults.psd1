@{
    # Consumer configuration overrides scalars, recursively merges hashtables and
    # appends arrays. Keep shared defaults here rather than in copied repositories.
    scriptDependencies = @{
        "Rnwood.Dataverse.Data.PowerShell" = "3.2.0"
    }

    # Power Apps CLI version used by pipeline scripts.
    # Supports: '' (latest stable), 'prerelease', or an exact version.
    pacCliVersion = '2.13.1'

    # Node.js version required for BUILD/IMPORT when a solution configures codeApps.
    # Set a major version to use an installed compatible release or download the latest stable patch.
    nodeVersion = '22'

    # Timeout in seconds for each solution import operation.
    # Increase this value if solution imports time out in large or complex environments.
    importTimeoutSeconds = 10800

    # Branch release base used by BUILD SemVer and solution versions.
    # The MAJOR.MINOR pair is mapped to Dataverse solution Major.Build.
    buildVersion = @{
        default = '1.0'
        branches = @{}
    }

    # Package exports and version updates share an operation budget; hooks do not.
    # Both integer limits accept 1..8; parallel = $false retains sequential export.
    export = @{
        parallel = $true
        maxParallel = 2
        maxConcurrentOperations = 4
    }

    # Build-command and packing stages each use this limit (1..8), independently
    # of checker concurrency. All build commands finish before packing starts.
    build = @{
        parallel = $true
        maxParallel = 2
    }

    # PAC solution check configuration used during BUILD.
    # Set enabled = $true globally or per-solution to activate checks.
    solutionCheck = @{
        enabled = $false

        # Geographic region for solution checker service.
        geo = 'Europe'

        # Build fails when the highest finding severity is >= this threshold.
        # Supported: Critical, High, Medium, Low, Informational
        failThreshold = 'Critical'

        # Rule set to run. Use 'none' to omit --ruleSet.
        # Examples: 'Solution Checker', 'AppSource Certification', '<GUID>'
        ruleSet = 'Solution Checker'

        # Globs resolved per solution to concrete files and passed to --excludedFiles.
        excludedFiles = @()

        # Rule level overrides. Can be a JSON file path, hashtable, or array.
        # Example item: @{ Id = 'meta-remove-dup-reg'; OverrideLevel = 'Medium' }
        ruleLevelOverride = @()

        # Maximum number of solutions to check in parallel.
        maxParallel = 4
    }
}
