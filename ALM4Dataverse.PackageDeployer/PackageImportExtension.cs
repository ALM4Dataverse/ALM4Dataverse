using System;
using System.Collections.Generic;
using System.ComponentModel.Composition;
using System.IO;
using System.Management.Automation;
using System.Text;
using Microsoft.Xrm.Tooling.PackageDeployment.CrmPackageExtentionBase;

namespace ALM4Dataverse.PackageDeployer
{
    [Export(typeof(IImportExtensions2))]
    public class PackageImportExtension : ImportExtension
    {
        private Dictionary<string, string> _runtimeSettings = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        public override string GetImportPackageDataFolderName => "PkgAssets";

        public override string GetNameOfImport(bool plural) =>
            plural ? "ALM4Dataverse Deployment Packages" : "ALM4Dataverse Deployment Package";

        public override string GetImportPackageDescriptionText =>
            "Deploys Dataverse solutions using ALM4Dataverse PowerShell scripts.";

        public override string GetLongNameOfImport =>
            "ALM4Dataverse Deployment Package";

        public override void InitializeCustomExtension()
        {
            PackageLog.Log("ALM4Dataverse Package Deployer initializing...");

            if (RuntimeSettings != null)
            {
                foreach (var setting in RuntimeSettings)
                {
                    var value = setting.Value?.ToString() ?? "";
                    _runtimeSettings[setting.Key] = value;
                    PackageLog.Log($"Runtime Setting: {setting.Key} = {value}");
                }
            }
        }

        public override bool BeforeImportStage()
        {
            return true;
        }

        public override bool AfterPrimaryImport()
        {
            PackageLog.Log("Starting ALM4Dataverse deployment via PowerShell scripts...");

            try
            {
                var pkgDir = GetPkgAssetsPath();
                var envUrl = GetEnvironmentUrl();

                PackageLog.Log($"Package assets directory: {pkgDir}");
                PackageLog.Log($"Environment URL: {envUrl}");

                var scriptsDir = Path.Combine(pkgDir, "alm", "pipelines", "scripts");

                var script = string.Join(Environment.NewLine,
                    "$ErrorActionPreference = 'Stop'",
                    $"& '{Escape(Path.Combine(scriptsDir, "installdependencies.ps1"))}'",
                    // Use PD's access token if available; otherwise fall back to DefaultAzureCredential via connect.ps1
                    "if ($env:DATAVERSE_ACCESS_TOKEN) {",
                    $"  Get-DataverseConnection -SetAsDefault -Url '{Escape(envUrl)}' -AccessToken {{ $env:DATAVERSE_ACCESS_TOKEN }}",
                    "} else {",
                    $"  & '{Escape(Path.Combine(scriptsDir, "connect.ps1"))}' -Url '{Escape(envUrl)}'",
                    "}",
                    $"& '{Escape(Path.Combine(scriptsDir, "deploy.ps1"))}' -ArtifactsPath '{Escape(pkgDir)}'"
                );

                var environmentVariables = BuildEnvironmentVariables();
                RunPowerShell(script, pkgDir, environmentVariables);

                PackageLog.Log("ALM4Dataverse deployment completed successfully.");
                return true;
            }
            catch (Exception ex)
            {
                PackageLog.Log($"ALM4Dataverse deployment failed: {ex}");
                RaiseFailEvent(ex.Message, ex);
                return false;
            }
        }

        /// <summary>
        /// Builds the environment variables to set on the spawned PowerShell process.
        /// Runtime settings are mapped to environment variables so the deployment scripts
        /// can read them (e.g. DataverseConnRef_*, DataverseEnvVar_*, DataverseServiceAccountUpn).
        /// Authentication context from CrmSvc is also forwarded where possible.
        /// </summary>
        private Dictionary<string, string> BuildEnvironmentVariables()
        {
            var env = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

            // Map all runtime settings as environment variables.
            // This allows callers to pass deployment config via:
            //   pac package deploy --settings "DataverseConnRef_MyRef=<id>|DataverseEnvVar_MyVar=value|DataverseServiceAccountUpn=user@org.com"
            // or auth overrides:
            //   pac package deploy --settings "AZURE_CLIENT_ID=<id>|AZURE_CLIENT_SECRET=<secret>|AZURE_TENANT_ID=<tid>"
            foreach (var setting in _runtimeSettings)
            {
                env[setting.Key] = setting.Value;
                PackageLog.Log($"Setting env var from runtime setting: {setting.Key}");
            }

            // Marker consumed by deploy.ps1 to avoid re-entering pac package deploy
            // when the script is already running inside a deployment package.
            env["ALM4DATAVERSE_IN_PACKAGE_DEPLOY"] = "true";

            // Forward CrmSvc access token so the connect script can use it as a fallback.
            // The Rnwood module's Get-DataverseConnection will use DefaultAzureCredential,
            // which picks up AZURE_* env vars. If those aren't set, having the current
            // access token available enables custom connection logic.
            try
            {
                var token = CrmSvc?.CurrentAccessToken;
                if (!string.IsNullOrEmpty(token) && !env.ContainsKey("DATAVERSE_ACCESS_TOKEN"))
                {
                    env["DATAVERSE_ACCESS_TOKEN"] = token;
                }
            }
            catch
            {
                // CurrentAccessToken may not be available for all auth types
            }

            return env;
        }

        private string GetPkgAssetsPath()
        {
            var assemblyDir = Path.GetDirectoryName(GetType().Assembly.Location);
            var pkgDir = Path.Combine(assemblyDir!, GetImportPackageDataFolderName);

            if (!Directory.Exists(pkgDir))
                throw new DirectoryNotFoundException(
                    $"Package assets directory not found: {pkgDir}");

            return pkgDir;
        }

        private string GetEnvironmentUrl()
        {
            var orgUri = CrmSvc?.CrmConnectOrgUriActual;
            if (orgUri == null)
                throw new InvalidOperationException(
                    "Not connected to a Dataverse environment. Ensure Package Deployer has an active connection.");

            return $"{orgUri.Scheme}://{orgUri.Host}";
        }

        private void RunPowerShell(string script, string workingDirectory, Dictionary<string, string> additionalEnvVars)
        {
            // Set environment variables on the current process so the in-process
            // PowerShell runspace can see them via $env:VAR_NAME.
            var savedEnvVars = new Dictionary<string, string>(additionalEnvVars.Count, StringComparer.OrdinalIgnoreCase);
            foreach (var kvp in additionalEnvVars)
            {
                savedEnvVars[kvp.Key] = Environment.GetEnvironmentVariable(kvp.Key);
                Environment.SetEnvironmentVariable(kvp.Key, kvp.Value);
            }

            try
            {
                using (var ps = PowerShell.Create())
                {
                    ps.AddCommand("Set-Location").AddParameter("Path", workingDirectory);
                    ps.AddStatement();
                    ps.AddScript(script);

                    ps.Streams.Information.DataAdded += (s, e) =>
                        PackageLog.Log(ps.Streams.Information[e.Index].ToString());
                    ps.Streams.Warning.DataAdded += (s, e) =>
                        PackageLog.Log($"WARNING: {ps.Streams.Warning[e.Index]}");
                    ps.Streams.Error.DataAdded += (s, e) =>
                        PackageLog.Log($"ERROR: {ps.Streams.Error[e.Index]}");
                    ps.Streams.Verbose.DataAdded += (s, e) =>
                        PackageLog.Log($"VERBOSE: {ps.Streams.Verbose[e.Index]}");

                    try
                    {
                        var results = ps.Invoke();
                        foreach (var result in results)
                        {
                            if (result != null)
                                PackageLog.Log(result.ToString());
                        }
                    }
                    catch (RuntimeException ex)
                    {
                        throw new InvalidOperationException(
                            $"PowerShell script error: {ex.ErrorRecord?.Exception?.Message ?? ex.Message}", ex);
                    }

                    if (ps.HadErrors)
                    {
                        var sb = new StringBuilder("PowerShell deployment script had errors:");
                        foreach (var error in ps.Streams.Error)
                            sb.AppendLine().Append("  ").Append(error);
                        throw new InvalidOperationException(sb.ToString());
                    }
                }
            }
            finally
            {
                // Restore previous environment variable values
                foreach (var kvp in savedEnvVars)
                    Environment.SetEnvironmentVariable(kvp.Key, kvp.Value);
            }
        }

        private static string Escape(string value) => value.Replace("'", "''");
    }
}
