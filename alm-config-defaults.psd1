@{
    scriptDependencies = @{
        "Rnwood.Dataverse.Data.PowerShell" = "3.0.3"
    }

    # Power Apps CLI version used by pipeline scripts.
    # Supports: '' (latest stable), 'prerelease', or an exact version.
    pacCliVersion = '2.7.4'

    # Timeout in seconds for each solution import operation.
    # Increase this value if solution imports time out in large or complex environments.
    importTimeoutSeconds = 10800

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
