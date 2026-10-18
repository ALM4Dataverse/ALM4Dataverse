using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.ComponentModel.Composition;
using System.Diagnostics;
using System.IO;
using System.Text;
using Microsoft.Xrm.Tooling.PackageDeployment.CrmPackageExtentionBase;

namespace ALM4Dataverse.PackageDeployer
{
    [Export(typeof(IImportExtensions))]
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
                    PackageLog.Log($"Runtime Setting received: {setting.Key}");
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
            catch (Exception ex)
            {
                PackageLog.Log($"Package Deployer access token is unavailable; deployment will use the configured Azure credential. {ex.Message}");
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
            RestorePowerShellModuleAssemblies(workingDirectory);

            var encodedScript = Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
            var startInfo = new ProcessStartInfo
            {
                FileName = "pwsh.exe",
                Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " + encodedScript,
                WorkingDirectory = workingDirectory,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true
            };
            foreach (var kvp in additionalEnvVars)
                startInfo.EnvironmentVariables[kvp.Key] = kvp.Value;

            using (var process = new Process { StartInfo = startInfo })
            {
                try
                {
                    if (!process.Start())
                        throw new InvalidOperationException("PowerShell 7 process failed to start.");
                }
                catch (Win32Exception ex)
                {
                    throw new InvalidOperationException(
                        "PowerShell 7 (pwsh.exe) must be installed and available on PATH to run this package.", ex);
                }

                var standardOutputTask = process.StandardOutput.ReadToEndAsync();
                var standardErrorTask = process.StandardError.ReadToEndAsync();
                process.WaitForExit();

                var standardOutput = standardOutputTask.GetAwaiter().GetResult();
                var standardError = standardErrorTask.GetAwaiter().GetResult();
                foreach (var line in standardOutput.Split(new[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries))
                    PackageLog.Log(line);
                foreach (var line in standardError.Split(new[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries))
                    PackageLog.Log($"PowerShell stderr: {line}");

                if (process.ExitCode != 0)
                {
                    var message = new StringBuilder($"PowerShell deployment process failed with exit code {process.ExitCode}.");
                    var details = !string.IsNullOrWhiteSpace(standardError) ? standardError : standardOutput;
                    if (!string.IsNullOrWhiteSpace(details))
                        message.AppendLine().Append(details.Trim());
                    throw new InvalidOperationException(message.ToString());
                }
            }
        }

        private void RestorePowerShellModuleAssemblies(string packageAssetsDirectory)
        {
            var modulesDirectory = Path.Combine(packageAssetsDirectory, "modules");
            if (!Directory.Exists(modulesDirectory))
                return;

            var preservedAssemblies = Directory.GetFiles(
                modulesDirectory,
                "*.dll.bin",
                SearchOption.AllDirectories
            );
            foreach (var preservedAssembly in preservedAssemblies)
            {
                var assemblyPath = preservedAssembly.Substring(
                    0,
                    preservedAssembly.Length - ".bin".Length
                );
                if (File.Exists(assemblyPath))
                    throw new IOException($"Cannot restore packaged module assembly because '{assemblyPath}' already exists.");

                File.Move(preservedAssembly, assemblyPath);
            }

            if (preservedAssemblies.Length > 0)
                PackageLog.Log($"Restored {preservedAssemblies.Length} packaged PowerShell module assemblies.");
        }

        private static string Escape(string value) => value.Replace("'", "''");
    }
}
