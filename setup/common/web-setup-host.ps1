# Shared library: dot-sourced after the common setup sources. The console flow stays
# in charge of setup decisions; web mode swaps the presentation and input helpers at
# runtime, so both front ends execute the same provisioning code.
function Get-SetupWebServerType {
    <#
    .SYNOPSIS
        Compiles and returns the loopback HTTP host used by browser setup.
    .DESCRIPTION
        The server type is process-wide and compiled once. It serves only loopback
        requests and never calls back into a PowerShell runspace, so browser polling
        continues while setup waits inside a blocking prompt.
    .OUTPUTS
        System.Type for ALM4Dataverse.SetupWebHost.
    #>
    [CmdletBinding()]
    [OutputType([type])]
    param()

    $typeName = 'ALM4Dataverse.SetupWebHost'
    $existingType = ([System.Management.Automation.PSTypeName]$typeName).Type
    if ($null -ne $existingType) {
        return $existingType
    }

    $source = @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

namespace ALM4Dataverse
{
    // Local-only HTTP host for the browser setup experience. It owns no PowerShell
    // state so request threads never need a runspace; the setup thread exchanges a
    // JSON state snapshot and JSON actions through this object.
    public sealed class SetupWebHost : IDisposable
    {
        private sealed class WebAsset
        {
            public string ContentType;
            public byte[] Body;
        }

        private readonly object syncRoot = new object();
        private readonly Dictionary<string, WebAsset> assets =
            new Dictionary<string, WebAsset>(StringComparer.OrdinalIgnoreCase);
        private readonly ConcurrentQueue<string> actionQueue = new ConcurrentQueue<string>();
        private readonly AutoResetEvent actionSignal = new AutoResetEvent(false);
        private TcpListener listener;
        private Thread acceptThread;
        private volatile bool running;
        private int port;
        private string token = "";
        private string stateJson = "{}";
        private long stateVersion;
        private string deviceCode = "";
        private DateTime lastRequestUtc = DateTime.MinValue;

        public int Port
        {
            get { return port; }
        }

        public DateTime LastRequestUtc
        {
            get
            {
                lock (syncRoot)
                {
                    return lastRequestUtc;
                }
            }
        }

        public void Start(int preferredPort)
        {
            if (running)
            {
                return;
            }

            listener = new TcpListener(IPAddress.Loopback, preferredPort < 0 ? 0 : preferredPort);
            listener.Start();
            port = ((IPEndPoint)listener.LocalEndpoint).Port;
            running = true;
            acceptThread = new Thread(AcceptLoop);
            acceptThread.IsBackground = true;
            acceptThread.Name = "ALM4DataverseSetupWeb";
            acceptThread.Start();
        }

        public void Stop()
        {
            running = false;
            actionSignal.Set();
            TcpListener currentListener = listener;
            listener = null;
            if (currentListener != null)
            {
                try
                {
                    currentListener.Stop();
                }
                catch (SocketException)
                {
                }
            }
        }

        public void Dispose()
        {
            Stop();
        }

        public void SetToken(string value)
        {
            lock (syncRoot)
            {
                token = value ?? "";
            }
        }

        public void SetAsset(string path, string contentType, string content)
        {
            WebAsset asset = new WebAsset();
            asset.ContentType = contentType;
            asset.Body = Encoding.UTF8.GetBytes(content ?? "");
            SetAsset(path, asset);
        }

        public void SetBinaryAsset(string path, string contentType, byte[] content)
        {
            WebAsset asset = new WebAsset();
            asset.ContentType = contentType;
            asset.Body = content ?? new byte[0];
            SetAsset(path, asset);
        }

        private void SetAsset(string path, WebAsset asset)
        {
            string key = NormalizePath(path);
            lock (syncRoot)
            {
                assets[key] = asset;
            }
        }

        public void SetState(string json)
        {
            lock (syncRoot)
            {
                stateJson = string.IsNullOrEmpty(json) ? "{}" : json;
                stateVersion++;
            }
        }

        public long GetStateVersion()
        {
            lock (syncRoot)
            {
                return stateVersion;
            }
        }

        public void PublishDeviceCode(string message)
        {
            lock (syncRoot)
            {
                deviceCode = message ?? "";
            }
        }

        public void ClearDeviceCode()
        {
            lock (syncRoot)
            {
                deviceCode = "";
            }
        }

        public string WaitForAction(int timeoutMs)
        {
            DateTime deadline = timeoutMs < 0 ? DateTime.MaxValue : DateTime.UtcNow.AddMilliseconds(timeoutMs);
            while (running)
            {
                string value;
                if (actionQueue.TryDequeue(out value))
                {
                    return value;
                }

                int waitMilliseconds = 50;
                if (timeoutMs >= 0)
                {
                    double remaining = (deadline - DateTime.UtcNow).TotalMilliseconds;
                    if (remaining <= 0)
                    {
                        return null;
                    }
                    if (remaining < waitMilliseconds)
                    {
                        waitMilliseconds = (int)remaining;
                    }
                }
                actionSignal.WaitOne(waitMilliseconds);
            }

            return null;
        }

        private void EnqueueAction(string json)
        {
            actionQueue.Enqueue(string.IsNullOrEmpty(json) ? "{}" : json);
            actionSignal.Set();
        }

        private void AcceptLoop()
        {
            while (running)
            {
                TcpClient client = null;
                try
                {
                    client = listener.AcceptTcpClient();
                }
                catch (Exception)
                {
                    if (!running)
                    {
                        return;
                    }
                    Thread.Sleep(25);
                    continue;
                }

                ThreadPool.QueueUserWorkItem(HandleClient, client);
            }
        }

        private void HandleClient(object stateObject)
        {
            TcpClient client = (TcpClient)stateObject;
            try
            {
                client.ReceiveTimeout = 10000;
                client.SendTimeout = 10000;
                using (NetworkStream stream = client.GetStream())
                {
                    string method;
                    string rawTarget;
                    Dictionary<string, string> headers;
                    if (!ReadRequestHead(stream, out method, out rawTarget, out headers))
                    {
                        return;
                    }

                    byte[] body = ReadRequestBody(stream, headers);
                    HandleRequest(method, rawTarget, headers, body, stream);
                }
            }
            catch (Exception)
            {
                // A browser can close a request early; a failed request must not stop
                // the local listener or surface as a setup failure.
            }
            finally
            {
                try
                {
                    client.Close();
                }
                catch (Exception)
                {
                }
            }
        }

        private void HandleRequest(
            string method,
            string rawTarget,
            Dictionary<string, string> headers,
            byte[] requestBody,
            NetworkStream stream)
        {
            lock (syncRoot)
            {
                lastRequestUtc = DateTime.UtcNow;
            }

            Uri target;
            try
            {
                target = new Uri("http://127.0.0.1" + rawTarget);
            }
            catch (UriFormatException)
            {
                WriteResponse(stream, 400, "Bad Request", "text/plain; charset=utf-8", Encoding.UTF8.GetBytes("Bad request."));
                return;
            }

            string path = target.AbsolutePath;
            if (string.Equals(path, "/api/state", StringComparison.OrdinalIgnoreCase))
            {
                if (method != "GET")
                {
                    WriteResponse(stream, 405, "Method Not Allowed", "text/plain; charset=utf-8", Encoding.UTF8.GetBytes("Use GET."));
                    return;
                }
                if (!IsAuthorized(GetProvidedToken(target, headers)))
                {
                    WriteResponse(stream, 403, "Forbidden", "text/plain; charset=utf-8", Encoding.UTF8.GetBytes("Invalid setup token."));
                    return;
                }

                string state;
                long version;
                string currentDeviceCode;
                lock (syncRoot)
                {
                    state = stateJson;
                    version = stateVersion;
                    currentDeviceCode = deviceCode;
                }
                string payload = "{\"version\":" + version.ToString() +
                    ",\"state\":" + state +
                    ",\"deviceCode\":\"" + EscapeJsonString(currentDeviceCode) + "\"}";
                WriteResponse(stream, 200, "OK", "application/json; charset=utf-8", Encoding.UTF8.GetBytes(payload));
                return;
            }

            if (string.Equals(path, "/api/action", StringComparison.OrdinalIgnoreCase))
            {
                if (method != "POST")
                {
                    WriteResponse(stream, 405, "Method Not Allowed", "text/plain; charset=utf-8", Encoding.UTF8.GetBytes("Use POST."));
                    return;
                }
                if (!IsAuthorized(GetProvidedToken(target, headers)))
                {
                    WriteResponse(stream, 403, "Forbidden", "text/plain; charset=utf-8", Encoding.UTF8.GetBytes("Invalid setup token."));
                    return;
                }
                if (requestBody.Length > 1048576)
                {
                    WriteResponse(stream, 413, "Payload Too Large", "text/plain; charset=utf-8", Encoding.UTF8.GetBytes("Action too large."));
                    return;
                }

                EnqueueAction(Encoding.UTF8.GetString(requestBody));
                WriteResponse(stream, 200, "OK", "application/json; charset=utf-8", Encoding.UTF8.GetBytes("{\"ok\":true}"));
                return;
            }

            if (string.Equals(path, "/api/heartbeat", StringComparison.OrdinalIgnoreCase))
            {
                if (!IsAuthorized(GetProvidedToken(target, headers)))
                {
                    WriteResponse(stream, 403, "Forbidden", "text/plain; charset=utf-8", Encoding.UTF8.GetBytes("Invalid setup token."));
                    return;
                }
                WriteResponse(stream, 200, "OK", "application/json; charset=utf-8", Encoding.UTF8.GetBytes("{\"ok\":true}"));
                return;
            }

            if (method != "GET" && method != "HEAD")
            {
                WriteResponse(stream, 405, "Method Not Allowed", "text/plain; charset=utf-8", Encoding.UTF8.GetBytes("Use GET."));
                return;
            }

            if (string.Equals(path, "/", StringComparison.Ordinal) || string.Equals(path, "/index.html", StringComparison.OrdinalIgnoreCase))
            {
                path = "/index.html";
            }
            else if (string.Equals(path, "/favicon.ico", StringComparison.OrdinalIgnoreCase))
            {
                path = "/logo.png";
            }

            WebAsset asset;
            lock (syncRoot)
            {
                if (!assets.TryGetValue(path, out asset))
                {
                    asset = null;
                }
            }
            if (asset == null)
            {
                WriteResponse(stream, 404, "Not Found", "text/plain; charset=utf-8", Encoding.UTF8.GetBytes("Not found."));
                return;
            }

            WriteResponse(stream, 200, "OK", asset.ContentType, asset.Body);
        }

        private static bool ReadRequestHead(
            NetworkStream stream,
            out string method,
            out string rawTarget,
            out Dictionary<string, string> headers)
        {
            method = "";
            rawTarget = "";
            headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

            string requestLine = ReadLine(stream);
            if (string.IsNullOrEmpty(requestLine))
            {
                return false;
            }
            string[] requestParts = requestLine.Split(' ');
            if (requestParts.Length < 2)
            {
                return false;
            }
            method = requestParts[0].ToUpperInvariant();
            rawTarget = requestParts[1];

            while (true)
            {
                string line = ReadLine(stream);
                if (line == null)
                {
                    return false;
                }
                if (line.Length == 0)
                {
                    break;
                }
                int colon = line.IndexOf(':');
                if (colon > 0)
                {
                    headers[line.Substring(0, colon).Trim()] = line.Substring(colon + 1).Trim();
                }
            }

            return true;
        }

        private static string ReadLine(NetworkStream stream)
        {
            MemoryStream buffer = new MemoryStream();
            while (buffer.Length < 8192)
            {
                int value = stream.ReadByte();
                if (value < 0)
                {
                    return null;
                }
                if (value == 10)
                {
                    byte[] bytes = buffer.ToArray();
                    int length = bytes.Length;
                    if (length > 0 && bytes[length - 1] == 13)
                    {
                        length--;
                    }
                    return Encoding.UTF8.GetString(bytes, 0, length);
                }
                buffer.WriteByte((byte)value);
            }
            return null;
        }

        private static byte[] ReadRequestBody(NetworkStream stream, Dictionary<string, string> headers)
        {
            string contentLengthText;
            if (!headers.TryGetValue("Content-Length", out contentLengthText))
            {
                return new byte[0];
            }
            int contentLength;
            if (!int.TryParse(contentLengthText, out contentLength) || contentLength <= 0)
            {
                return new byte[0];
            }
            if (contentLength > 1048576)
            {
                return new byte[0];
            }

            byte[] buffer = new byte[contentLength];
            int offset = 0;
            while (offset < contentLength)
            {
                int read = stream.Read(buffer, offset, contentLength - offset);
                if (read <= 0)
                {
                    break;
                }
                offset += read;
            }
            if (offset == contentLength)
            {
                return buffer;
            }
            byte[] partial = new byte[offset];
            Array.Copy(buffer, partial, offset);
            return partial;
        }

        private static void WriteResponse(
            NetworkStream stream,
            int statusCode,
            string reason,
            string contentType,
            byte[] body)
        {
            StringBuilder header = new StringBuilder();
            header.Append("HTTP/1.1 ").Append(statusCode).Append(' ').Append(reason).Append("\r\n");
            header.Append("Content-Type: ").Append(contentType).Append("\r\n");
            header.Append("Content-Length: ").Append(body.Length).Append("\r\n");
            header.Append("Cache-Control: no-store\r\n");
            header.Append("Connection: close\r\n");
            header.Append("X-Content-Type-Options: nosniff\r\n");
            header.Append("Referrer-Policy: no-referrer\r\n");
            header.Append("Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'\r\n");
            header.Append("\r\n");

            byte[] headerBytes = Encoding.ASCII.GetBytes(header.ToString());
            try
            {
                stream.Write(headerBytes, 0, headerBytes.Length);
                if (body.Length > 0)
                {
                    stream.Write(body, 0, body.Length);
                }
                stream.Flush();
            }
            catch (IOException)
            {
            }
        }

        private bool IsAuthorized(string providedToken)
        {
            string expectedToken;
            lock (syncRoot)
            {
                expectedToken = token;
            }
            return expectedToken.Length > 0 &&
                string.Equals(providedToken, expectedToken, StringComparison.Ordinal);
        }

        private static string GetProvidedToken(Uri target, Dictionary<string, string> headers)
        {
            string headerValue;
            if (headers.TryGetValue("X-Setup-Token", out headerValue) && !string.IsNullOrEmpty(headerValue))
            {
                return headerValue;
            }
            return GetQueryValue(target, "token");
        }

        private static string GetQueryValue(Uri target, string name)
        {
            string query = target.Query;
            if (query.StartsWith("?", StringComparison.Ordinal))
            {
                query = query.Substring(1);
            }
            if (query.Length == 0)
            {
                return "";
            }

            string[] pairs = query.Split('&');
            foreach (string pair in pairs)
            {
                int equalsIndex = pair.IndexOf('=');
                string rawKey = equalsIndex >= 0 ? pair.Substring(0, equalsIndex) : pair;
                if (string.Equals(Uri.UnescapeDataString(rawKey), name, StringComparison.OrdinalIgnoreCase))
                {
                    return equalsIndex >= 0
                        ? Uri.UnescapeDataString(pair.Substring(equalsIndex + 1).Replace("+", " "))
                        : "";
                }
            }
            return "";
        }

        private static string NormalizePath(string path)
        {
            if (string.IsNullOrEmpty(path))
            {
                return "/";
            }
            return path.StartsWith("/", StringComparison.Ordinal) ? path : "/" + path;
        }

        private static string EscapeJsonString(string value)
        {
            if (string.IsNullOrEmpty(value))
            {
                return "";
            }

            StringBuilder builder = new StringBuilder(value.Length + 8);
            foreach (char character in value)
            {
                switch (character)
                {
                    case '"':
                        builder.Append("\\\"");
                        break;
                    case '\\':
                        builder.Append("\\\\");
                        break;
                    case '\b':
                        builder.Append("\\b");
                        break;
                    case '\f':
                        builder.Append("\\f");
                        break;
                    case '\n':
                        builder.Append("\\n");
                        break;
                    case '\r':
                        builder.Append("\\r");
                        break;
                    case '\t':
                        builder.Append("\\t");
                        break;
                    default:
                        if (character < ' ')
                        {
                            builder.Append("\\u").Append(((int)character).ToString("x4"));
                        }
                        else
                        {
                            builder.Append(character);
                        }
                        break;
                }
            }
            return builder.ToString();
        }
    }
}

'@

    Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
    $serverType = ([System.Management.Automation.PSTypeName]$typeName).Type
    if ($null -eq $serverType) {
        throw 'Could not load the ALM4Dataverse setup web host type.'
    }

    return $serverType
}

function Get-SetupWebHost {
    # Returns the active browser host context, or null when console setup is running.
    [CmdletBinding()]
    param()

    return (Get-Variable -Name 'SetupWebHost' -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
}

function Initialize-SetupWebHost {
    <#
    .SYNOPSIS
        Starts the local browser setup host and installs web UI overrides.
    .DESCRIPTION
        The listener binds to loopback only and uses a random action token. Assets come
        from the embedded copy so released single-file installers work without adjacent
        files. The browser is opened unless NoBrowser is set; failure to launch a browser
        leaves the printed URL available for manual entry. A second call returns the
        existing host rather than starting another listener.
    .PARAMETER Provider
        Display name for the provider-specific setup flow.
    .PARAMETER ProductVersion
        Version shown beside the logo. Development source runs may show Development.
    .PARAMETER Title
        Browser page title and setup heading.
    .PARAMETER Reference
        Shared-code ref shown in the UI and used for documentation links.
    .PARAMETER DefaultHelpDocRelativePath
        Documentation path used when a prompt has no more specific page.
    .PARAMETER Port
        Optional fixed loopback port; zero chooses an available port.
    .PARAMETER NoBrowser
        Starts the host without launching a browser, for tests and remote sessions.
    .OUTPUTS
        PSCustomObject with Server, Port, Token, Url, Provider, Title and Version.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateSet('Azure DevOps', 'GitHub')][string]$Provider,
        [Parameter()][string]$ProductVersion = 'Development',
        [Parameter()][string]$Title = 'ALM4Dataverse setup',
        [Parameter()][string]$Reference = 'stable',
        [Parameter()][string]$DefaultHelpDocRelativePath,
        [Parameter()][ValidateRange(0, 65535)][int]$Port = 0,
        [Parameter()][switch]$NoBrowser
    )

    $existingWebHost = Get-SetupWebHost
    if ($null -ne $existingWebHost) {
        return $existingWebHost
    }

    $serverType = Get-SetupWebServerType
    $server = [System.Activator]::CreateInstance($serverType)
    try {
        $server.Start($Port)
    }
    catch {
        throw "Could not start the local setup web server on port $Port. $($_.Exception.Message)"
    }

    $token = [guid]::NewGuid().ToString('N')
    $server.SetToken($token)
    $server.SetAsset('/index.html', 'text/html; charset=utf-8', (Get-SetupWebUiAsset -Name 'index.html'))
    $server.SetAsset('/app.css', 'text/css; charset=utf-8', (Get-SetupWebUiAsset -Name 'app.css'))
    $server.SetAsset('/app.js', 'application/javascript; charset=utf-8', (Get-SetupWebUiAsset -Name 'app.js'))
    $server.SetBinaryAsset('/logo.png', 'image/png', (Get-SetupWebLogo))

    $url = "http://127.0.0.1:$($server.Port)/?token=$token"
    $webHost = [pscustomobject]@{
        Server      = $server
        Port        = [int]$server.Port
        Token       = $token
        Url         = $url
        Provider    = $Provider
        Title       = $Title
        Version       = $ProductVersion
        Reference     = $Reference
        Repository    = ''
        RepositoryUrl = ''
    }

    $script:SetupWebHost = $webHost
    $script:SetupWebActivity = [System.Collections.Generic.List[object]]::new()
    $script:SetupWebPrompt = $null
    $script:SetupWebWizard = $null
    $script:SetupWebBusy = 'Preparing setup...'
    $script:SetupWebInteractiveVersion = 0
    $script:SetupWebSection = 'Starting setup'
    $script:SetupWebFinished = $false
    $script:SetupWebPendingBlocks = @()
    $script:SetupWebPendingGuidance = $null
    $script:SetupWebLastPublish = [datetime]::MinValue
    $script:SetupWebCaptureBlocks = $null
    if (-not [string]::IsNullOrWhiteSpace($DefaultHelpDocRelativePath)) {
        $script:SetupDefaultHelpDocRelativePath = $DefaultHelpDocRelativePath
    }

    Enable-SetupWebOverride
    Add-SetupWebActivity -Text "Started $Provider setup in the browser." -Tone 'success'
    Publish-SetupWebState -Force

    Microsoft.PowerShell.Utility\Write-Host "ALM4Dataverse setup is available at: $url" -ForegroundColor Green
    Microsoft.PowerShell.Utility\Write-Host 'Keep this window open while you complete setup. Press Ctrl+C to stop.' -ForegroundColor DarkGray

    if (-not $NoBrowser) {
        if (-not (Open-SetupWebBrowser -Url $url)) {
            Microsoft.PowerShell.Utility\Write-Host 'Could not launch a browser automatically. Open the URL above on this machine.' -ForegroundColor Yellow
        }
    }

    return $webHost
}

function Close-SetupWebHost {
    <#
    .SYNOPSIS
        Stops the local browser setup host and clears its script-scope state.
    .DESCRIPTION
        Safe to call more than once and safe when browser mode was never enabled.
    #>
    [CmdletBinding()]
    param()

    $webHost = Get-SetupWebHost
    if ($null -ne $webHost) {
        try {
            $webHost.Server.Stop()
        }
        catch {
            Write-Verbose "Could not stop the setup web server cleanly: $($_.Exception.Message)"
        }
    }

    Remove-Variable -Name 'SetupWebHost' -Scope Script -ErrorAction SilentlyContinue
}

function Open-SetupWebBrowser {
    <#
    .SYNOPSIS
        Opens one URL with the platform browser launcher.
    .DESCRIPTION
        Returns false when no launcher succeeds so callers can print the URL instead.
        Launch failures are non-fatal and never terminate setup.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Url
    )

    try {
        if ($env:OS -eq 'Windows_NT') {
            Start-Process -FilePath $Url -ErrorAction Stop
            return $true
        }

        $uname = Get-Command -Name 'uname' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($uname -and ((& $uname.Source -s) -eq 'Darwin')) {
            Start-Process -FilePath 'open' -ArgumentList @($Url) -ErrorAction Stop
            return $true
        }

        foreach ($launcherName in @('xdg-open', 'gio', 'sensible-browser')) {
            $launcher = Get-Command -Name $launcherName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -eq $launcher) {
                continue
            }

            $arguments = if ($launcherName -eq 'gio') { @('open', $Url) } else { @($Url) }
            Start-Process -FilePath $launcher.Source -ArgumentList $arguments -ErrorAction Stop
            return $true
        }
    }
    catch {
        Write-Verbose "Browser launch failed: $($_.Exception.Message)"
    }

    return $false
}

function Publish-SetupWebIdentity {
    <#
    .SYNOPSIS
        Updates the browser header metadata after release values are resolved.
    .PARAMETER ProductVersion
        Version shown beside the logo.
    .PARAMETER Reference
        Shared-code ref used by the UI.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][string]$ProductVersion,
        [Parameter()][string]$Reference
    )

    $webHost = Get-SetupWebHost
    if ($null -eq $webHost) {
        return
    }
    if (-not [string]::IsNullOrWhiteSpace($ProductVersion)) {
        $webHost.Version = $ProductVersion
    }
    if (-not [string]::IsNullOrWhiteSpace($Reference)) {
        $webHost.Reference = $Reference
    }
    Publish-SetupWebState -Force
}

function Publish-SetupWebRepository {
    <#
    .SYNOPSIS
        Publishes the application repository shown in the browser header.
    .DESCRIPTION
        Called once the provider and repository are resolved. Repeated calls replace
        the header value, which lets setup show a newly created repository without a
        page reload.
    .PARAMETER Name
        Display name, for example project/repository or owner/repository.
    .PARAMETER Url
        Optional repository web URL.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter()][string]$Url
    )

    $webHost = Get-SetupWebHost
    if ($null -eq $webHost -or [string]::IsNullOrWhiteSpace($Name)) {
        return
    }

    $webHost.Repository = $Name
    $webHost.RepositoryUrl = $Url
    Publish-SetupWebState -Force
}

function Add-SetupWebActivity {
    <#
    .SYNOPSIS
        Appends one timestamped line to the browser activity drawer.
    .DESCRIPTION
        Entries are capped so a long session cannot grow the state payload without
        bound. Publishing is throttled; prompt and section changes force a flush.
    .PARAMETER Text
        Plain text to display. Secrets and entered values must never be logged here.
    .PARAMETER Tone
        Visual tone for the drawer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter()][ValidateSet('info', 'success', 'warn', 'error', 'muted')][string]$Tone = 'info'
    )

    if ($null -eq (Get-SetupWebHost) -or [string]::IsNullOrWhiteSpace($Text)) {
        return
    }

    $script:SetupWebActivity.Add([pscustomobject]@{
            time = (Get-Date).ToString('HH:mm:ss')
            text = $Text
            tone = $Tone
        })
    while ($script:SetupWebActivity.Count -gt 400) {
        $script:SetupWebActivity.RemoveAt(0)
    }

    Publish-SetupWebState
}

function Get-SetupWebStatePayload {
    <#
    .SYNOPSIS
        Builds the JSON-ready state snapshot served to the browser.
    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()

    $webHost = Get-SetupWebHost
    $activity = Get-Variable -Name 'SetupWebActivity' -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    $activityItems = @()
    if ($null -ne $activity) {
        $activityItems = $activity.ToArray()
    }
    return [ordered]@{
        app      = if ($null -ne $webHost) { [string]$webHost.Provider } else { '' }
        title    = if ($null -ne $webHost) { [string]$webHost.Title } else { 'ALM4Dataverse setup' }
        version  = if ($null -ne $webHost) { [string]$webHost.Version } else { 'Development' }
        ref      = if ($null -ne $webHost) { [string]$webHost.Reference } else { '' }
        repository = if ($null -ne $webHost) { [string]$webHost.Repository } else { '' }
        repositoryUrl = if ($null -ne $webHost) { [string]$webHost.RepositoryUrl } else { '' }
        section  = [string](Get-Variable -Name 'SetupWebSection' -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
        interactiveVersion = [long](Get-Variable -Name 'SetupWebInteractiveVersion' -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
        busy     = (Get-Variable -Name 'SetupWebBusy' -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
        prompt   = (Get-Variable -Name 'SetupWebPrompt' -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
        wizard   = (Get-Variable -Name 'SetupWebWizard' -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
        activity = $activityItems
        finished = [bool](Get-Variable -Name 'SetupWebFinished' -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
    }
}

function Publish-SetupWebState {
    <#
    .SYNOPSIS
        Serializes the current browser state to the loopback host.
    .DESCRIPTION
        Normal activity writes are throttled to keep rapid console output cheap;
        Force publishes prompt changes and completion immediately.
    .PARAMETER Force
        Publishes regardless of the activity throttle.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][switch]$Force
    )

    $webHost = Get-SetupWebHost
    if ($null -eq $webHost) {
        return
    }

    $now = [datetime]::UtcNow
    $lastPublish = Get-Variable -Name 'SetupWebLastPublish' -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if (-not $Force -and $null -ne $lastPublish -and ($now - $lastPublish).TotalMilliseconds -lt 350) {
        return
    }

    $script:SetupWebLastPublish = $now
    $payload = Get-SetupWebStatePayload
    $json = ConvertTo-Json -InputObject $payload -Depth 32 -Compress
    $webHost.Server.SetState($json)
}

function Publish-SetupWebBusy {
    <#
    .SYNOPSIS
        Replaces the current prompt with a working state and message.
    .PARAMETER Message
        Short description of the operation in progress.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message
    )

    if ($null -eq (Get-SetupWebHost)) {
        return
    }

    $script:SetupWebPrompt = $null
    $script:SetupWebBusy = $Message
    Publish-SetupWebState -Force
}

function Publish-SetupWebDeviceCode {
    <#
    .SYNOPSIS
        Publishes sign-in instructions in the browser header without changing the prompt.
    .DESCRIPTION
        Native sign-in tools print a one-time code and verification URL while they wait
        for the browser. The message is stored beside the state snapshot so polling can
        show it without republishing or re-rendering the setup screen. An empty value
        hides the banner.
    .PARAMETER Message
        Device-code instructions to display, or an empty string to hide the banner.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowEmptyString()][string]$Message
    )

    $webHost = Get-SetupWebHost
    if ($null -eq $webHost) {
        return
    }

    $webHost.Server.PublishDeviceCode($Message)
}

function Read-SetupWebAction {
    <#
    .SYNOPSIS
        Waits for one browser action or returns null when the host stops.
    .PARAMETER TimeoutSeconds
        Negative waits indefinitely; zero checks once; positive waits that long.
    .OUTPUTS
        PSCustomObject from the posted JSON, or null on timeout/stop.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][int]$TimeoutSeconds = -1
    )

    $webHost = Get-SetupWebHost
    if ($null -eq $webHost) {
        throw 'Browser setup is not active.'
    }

    $timeoutMilliseconds = if ($TimeoutSeconds -lt 0) { -1 } else { $TimeoutSeconds * 1000 }
    $rawAction = $webHost.Server.WaitForAction($timeoutMilliseconds)
    if ([string]::IsNullOrWhiteSpace($rawAction)) {
        return $null
    }

    try {
        return ($rawAction | ConvertFrom-Json)
    }
    catch {
        throw "Could not read the browser setup action. $($_.Exception.Message)"
    }
}

function Read-SetupWebPromptAction {
    <#
    .SYNOPSIS
        Reads an action whose id matches the active prompt.
    .DESCRIPTION
        Stale actions from an earlier prompt are discarded. A null result means the
        host stopped, so setup is cancelled rather than left waiting forever.
    .PARAMETER PromptId
        Active prompt identifier.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PromptId,
        [Parameter()][int]$TimeoutSeconds = -1
    )

    while ($true) {
        $action = Read-SetupWebAction -TimeoutSeconds $TimeoutSeconds
        if ($null -eq $action) {
            throw ([System.OperationCanceledException]::new('The setup window stopped before a response was received.'))
        }

        $actionId = [string](Get-OptionalObjectPropertyValue -InputObject $action -PropertyName 'id')
        if (-not [string]::IsNullOrWhiteSpace($actionId) -and $actionId -ne $PromptId) {
            continue
        }

        return $action
    }
}

function Invoke-SetupWebBackNavigation {
    # Mirrors Escape handling: steps return to the wizard, a root prompt cancels.
    [CmdletBinding()]
    param()

    $wizardContext = Get-SetupWizardContext
    if ($wizardContext -and -not $wizardContext.IsNavigationMenu) {
        Request-SetupWizardBack
    }

    throw ([System.OperationCanceledException]::new('Setup cancelled by user.'))
}

function Invoke-SetupWebCancelNavigation {
    # Mirrors cancelling the root prompt; the setup entrypoint reports the stop.
    [CmdletBinding()]
    param()

    throw ([System.OperationCanceledException]::new('Setup cancelled by user.'))
}

function Get-SetupWebPromptNavigation {
    <#
    .SYNOPSIS
        Resolves back versus cancel controls for the active wizard context.
    .OUTPUTS
        PSCustomObject with AllowBack and CancelLabel.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $wizardContext = Get-SetupWizardContext
    $allowBack = [bool]($wizardContext -and -not $wizardContext.IsNavigationMenu)
    return [pscustomobject]@{
        AllowBack  = $allowBack
        CancelLabel = if ($allowBack) { $null } else { 'Cancel setup' }
    }
}

function Get-SetupWebPromptBase {
    <#
    .SYNOPSIS
        Builds the shared prompt envelope consumed by the browser UI.
    .DESCRIPTION
        Consumes pending guidance and content blocks unless explicit values are
        supplied. The returned ordered dictionary excludes any secret value.
    .PARAMETER Kind
        Browser prompt renderer kind.
    .PARAMETER Title
        Main prompt heading.
    .PARAMETER Eyebrow
        Overline text; defaults to the current setup section.
    .PARAMETER Blocks
        Optional pre-built content blocks; defaults to the pending block list.
    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Title,
        [Parameter()][string]$Eyebrow,
        [Parameter()][object[]]$Blocks,
        [Parameter()][switch]$AllowBack,
        [Parameter()][string]$CancelLabel
    )

    $guidance = Get-SetupWebPendingGuidance
    $effectiveBlocks = if ($PSBoundParameters.ContainsKey('Blocks')) { @($Blocks) } else { @(Get-SetupWebContentQueue) }
    $effectiveEyebrow = if ([string]::IsNullOrWhiteSpace($Eyebrow)) {
        $currentSection = Get-SetupCurrentSectionMessage
        if ([string]::IsNullOrWhiteSpace([string]$currentSection)) { 'Setup' } else { [string]$currentSection }
    }
    else {
        $Eyebrow
    }

    return [ordered]@{
        id          = [guid]::NewGuid().ToString('N')
        kind        = $Kind
        title       = $Title
        eyebrow     = $effectiveEyebrow
        guidance    = @($(if ($null -ne $guidance) { $guidance.Lines } else { @() }) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        helpUrl     = [string]$(if ($null -ne $guidance) { $guidance.HelpUrl } else { '' })
        allowBack   = [bool]$AllowBack
        cancelLabel = $CancelLabel
        error       = $null
        blocks      = @($effectiveBlocks)
    }
}

function Publish-SetupWebPrompt {
    <#
    .SYNOPSIS
        Publishes one prompt and returns its identifier.
    .PARAMETER Prompt
        Ordered dictionary built by the web prompt readers.
    .OUTPUTS
        System.String prompt identifier.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Prompt
    )

    $script:SetupWebPrompt = $Prompt
    $script:SetupWebBusy = $null
    $script:SetupWebFinished = $false
    $script:SetupWebInteractiveVersion = [long]$script:SetupWebInteractiveVersion + 1
    Publish-SetupWebState -Force
    return [string]$Prompt['id']
}

function Get-SetupWebPendingGuidance {
    # Returns the guidance stored by the last prompt frame, or null.
    [CmdletBinding()]
    param()

    return (Get-Variable -Name 'SetupWebPendingGuidance' -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
}

function Get-SetupWebContentQueue {
    # Returns and clears content blocks queued by the previous summary helpers.
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    $blocks = (Get-Variable -Name 'SetupWebPendingBlocks' -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
    $script:SetupWebPendingBlocks = @()
    return @($blocks)
}

function Add-SetupWebContentBlock {
    <#
    .SYNOPSIS
        Queues display content for the next browser prompt or review capture.
    .PARAMETER Block
        JSON-ready display block.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Block
    )

    $capture = Get-Variable -Name 'SetupWebCaptureBlocks' -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $capture) {
        $capture.Add($Block)
        return
    }

    $script:SetupWebPendingBlocks = @(Get-SetupWebContentQueue) + @($Block)
}

function Enable-SetupWebOverride {
    <#
    .SYNOPSIS
        Replaces console presentation and prompt commands with browser versions.
    .DESCRIPTION
        Only the setup script's function scope is changed, so the process host and
        unrelated scripts keep their normal Write-Host and prompt behavior. The
        original helpers remain available under their setup names for reuse.
    #>
    [CmdletBinding()]
    param()

    $overrides = [ordered]@{
        'Select-FromMenu'                 = 'Read-SetupWebMenu'
        'Read-YesNo'                      = 'Read-SetupWebYesNo'
        'Read-TextWithDefault'            = 'Read-SetupWebTextWithDefault'
        'Read-SecretText'                 = 'Read-SetupWebSecretText'
        'Write-Section'                   = 'Write-SetupWebSection'
        'Write-SetupDashboard'            = 'Write-SetupWebDashboard'
        'Write-SetupPromptFrame'          = 'Write-SetupWebPromptFrame'
        'Write-SetupGuidance'             = 'Write-SetupWebGuidance'
        'Show-SetupPromptGuidance'        = 'Show-SetupWebPromptGuidance'
        'Show-SetupStatusBarAtBottom'     = 'Show-SetupWebStatusBar'
        'Clear-SetupStatusBarAtBottom'    = 'Clear-SetupWebStatusBar'
        'Invoke-SetupWizard'              = 'Invoke-SetupWebWizard'
        'Write-SetupWizardApplyFailure'   = 'Write-SetupWebWizardApplyFailure'
        'Show-SetupChangeReview'          = 'Show-SetupWebChangeReview'
        'Show-SetupSideBySideDiff'        = 'Show-SetupWebSideBySideDiff'
        'Show-SetupFileChangeSummary'     = 'Show-SetupWebFileChangeSummary'
        'Show-SetupResourceChangeSummary' = 'Show-SetupWebResourceChangeSummary'
        'Show-SetupCompletionScreen'      = 'Show-SetupWebCompletionScreen'
        'Invoke-WithSpectreStatus'        = 'Invoke-SetupWebStatus'
        'Invoke-WithErrorHandling'        = 'Invoke-SetupWebErrorHandling'
        'Show-SetupActivityOutputPanel'   = 'Show-SetupWebActivityOutputPanel'
        'Wait-ForUserAcknowledgement'     = 'Wait-SetupWebAcknowledgement'
        'Show-KeyValueSummaryTable'       = 'Show-SetupWebKeyValueSummaryTable'
        'Show-BranchEnvironmentMappingTable' = 'Show-SetupWebBranchEnvironmentMappingTable'
        'Show-EnvironmentConfigurationTable' = 'Show-SetupWebEnvironmentConfigurationTable'
        'Show-SpectreMetricCard'          = 'Show-SetupWebMetricCard'
        'Show-SetupFilePreview'           = 'Show-SetupWebFilePreview'
        'Invoke-SetupDeviceCodeAuthentication' = 'Read-SetupWebDeviceCodeAuthentication'
        'Write-Host'                      = 'Write-SetupWebHost'
    }

    foreach ($targetName in $overrides.Keys) {
        $sourceName = $overrides[$targetName]
        $sourceCommand = Get-Command -Name $sourceName -CommandType Function -ErrorAction Stop
        Set-Item -Path "Function:script:$targetName" -Value $sourceCommand.ScriptBlock
    }
}

function Complete-SetupWebPrompt {
    # Clears the answered prompt so the browser immediately shows work in progress.
    [CmdletBinding()]
    param(
        [Parameter()][string]$Message = 'Continuing...'
    )

    if ($null -eq (Get-SetupWebHost)) {
        return
    }

    $script:SetupWebPrompt = $null
    $script:SetupWebBusy = $Message
    Publish-SetupWebState -Force
}

function Write-SetupWebSection {
    # Web equivalent of Write-Section: resets the prompt and publishes the section.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [Parameter()][string[]]$GuidanceLines,
        [Parameter()][string]$GuidanceDocRelativePath,
        [Parameter()][string]$GuidanceRef
    )

    $script:SetupCurrentSectionMessage = $Message
    Clear-SetupPromptDocContext
    $script:SetupGuidancePanelVisible = $false
    $script:SetupWebSection = $Message
    $script:SetupWebPrompt = $null
    $script:SetupWebPendingBlocks = @()
    $script:SetupWebPendingGuidance = $null
    $script:SetupWebBusy = "Working on $Message..."
    Add-SetupWebActivity -Text $Message -Tone 'info'

    if (($GuidanceLines -and @($GuidanceLines).Count -gt 0) -or -not [string]::IsNullOrWhiteSpace($GuidanceDocRelativePath)) {
        Write-SetupWebGuidance `
            -Lines @($GuidanceLines) `
            -DocRelativePath $GuidanceDocRelativePath `
            -Ref $GuidanceRef `
            -Header "$Message guidance"
    }

    Publish-SetupWebState -Force
}

function Write-SetupWebDashboard {
    # The browser shell always shows the logo, so only the section heading changes.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'IncludeTrailingSpacer', Justification = 'Compatibility parameter retained; browser layout owns vertical spacing.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ShowProductBrand', Justification = 'The browser shell always displays the product mark.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [Parameter()][switch]$IncludeTrailingSpacer,
        [Parameter()][switch]$ShowProductBrand
    )

    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        $script:SetupWebSection = $Message
    }
}

function Write-SetupWebGuidance {
    <#
    .SYNOPSIS
        Stores guidance for the next browser prompt instead of drawing a console panel.
    .DESCRIPTION
        Preserves the prompt-document context and help URL behavior of Write-SetupGuidance.
        Blank lines are omitted; no content and no documentation page renders nothing.
    .PARAMETER Header
        Guidance heading or prompt title.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'OmitTrailingSpacer', Justification = 'Compatibility parameter retained; browser layout owns spacing.')]
    [CmdletBinding()]
    param(
        [Parameter()][string[]]$Lines,
        [Parameter()][string]$DocRelativePath,
        [Parameter()][string]$Ref,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Header,
        [Parameter()][switch]$SkipContextUpdate,
        [Parameter()][switch]$OmitTrailingSpacer
    )

    if (-not $SkipContextUpdate) {
        Set-SetupPromptDocContext -DocRelativePath $DocRelativePath -Ref $Ref
    }

    $contentLines = @($Lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $docUrl = Get-SetupPromptHelpUrl -DocRelativePath $DocRelativePath -Ref $Ref
    if ([string]::IsNullOrWhiteSpace($docUrl)) {
        Remove-Variable -Name 'SetupActivePromptHelpUrl' -Scope Script -ErrorAction SilentlyContinue
    }
    else {
        $script:SetupActivePromptHelpUrl = $docUrl
    }

    if ($contentLines.Count -eq 0 -and [string]::IsNullOrWhiteSpace($docUrl)) {
        return
    }

    $effectiveHeader = $Header.Trim()
    if ([string]::IsNullOrWhiteSpace($effectiveHeader)) {
        throw 'Write-SetupGuidance requires a specific non-empty header.'
    }

    $script:SetupWebPendingGuidance = [pscustomobject]@{
        Header  = $effectiveHeader
        Lines   = $contentLines
        HelpUrl = $docUrl
    }
    $script:SetupGuidancePanelVisible = $true
}

function Show-SetupWebPromptGuidance {
    # Stores prompt-local guidance without replacing the section documentation context.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'OmitTrailingSpacer', Justification = 'Compatibility parameter retained; browser layout owns spacing.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PromptText,
        [Parameter()][string[]]$GuidanceLines,
        [Parameter()][string]$DocRelativePath,
        [Parameter()][string]$Ref,
        [Parameter()][switch]$OmitTrailingSpacer
    )

    $effectiveLines = @($GuidanceLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $docUrl = Get-SetupPromptHelpUrl -DocRelativePath $DocRelativePath -Ref $Ref
    if ([string]::IsNullOrWhiteSpace($docUrl) -and $effectiveLines.Count -eq 0) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($docUrl)) {
        Remove-Variable -Name 'SetupActivePromptHelpUrl' -Scope Script -ErrorAction SilentlyContinue
    }
    else {
        $script:SetupActivePromptHelpUrl = $docUrl
    }

    $script:SetupWebPendingGuidance = [pscustomobject]@{
        Header  = $(if ([string]::IsNullOrWhiteSpace($PromptText)) { 'Prompt guidance' } else { $PromptText })
        Lines   = $effectiveLines
        HelpUrl = $docUrl
    }
    $script:SetupGuidancePanelVisible = $true
}

function Write-SetupWebPromptFrame {
    <#
    .SYNOPSIS
        Prepares section, guidance and help metadata for one browser prompt.
    .DESCRIPTION
        Mirrors Write-SetupPromptFrame defaults. PreserveExistingContent keeps the
        current guidance, and SkipPromptGuidance suppresses prompt-specific lines.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ShowProductBrand', Justification = 'The browser shell always displays the product mark.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PromptText,
        [Parameter(Mandatory)][ValidateSet('Menu', 'Text', 'YesNo', 'Secret')][string]$PromptKind,
        [Parameter()][string[]]$PromptGuidanceLines,
        [Parameter()][string]$PromptGuidanceDocRelativePath,
        [Parameter()][string]$PromptGuidanceRef,
        [Parameter()][switch]$ShowProductBrand,
        [Parameter()][switch]$PreserveExistingContent,
        [Parameter()][switch]$SkipPromptGuidance
    )

    $currentSectionMessage = Get-SetupCurrentSectionMessage
    if (-not $PreserveExistingContent) {
        $script:SetupWebSection = if ([string]::IsNullOrWhiteSpace([string]$currentSectionMessage)) { $PromptText } else { [string]$currentSectionMessage }
    }

    $guidancePanelVisible = [bool](Get-Variable -Name 'SetupGuidancePanelVisible' -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
    if ($PreserveExistingContent -and $guidancePanelVisible) {
        return
    }

    $helpUrl = Get-SetupPromptHelpUrl -DocRelativePath $PromptGuidanceDocRelativePath -Ref $PromptGuidanceRef
    if ([string]::IsNullOrWhiteSpace($helpUrl)) {
        Remove-Variable -Name 'SetupActivePromptHelpUrl' -Scope Script -ErrorAction SilentlyContinue
    }
    else {
        $script:SetupActivePromptHelpUrl = $helpUrl
    }

    $effectiveGuidanceLines = if ($SkipPromptGuidance) {
        @()
    }
    else {
        @($PromptGuidanceLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    $effectiveGuidanceLines = @($effectiveGuidanceLines)

    if ($effectiveGuidanceLines.Count -eq 0) {
        $effectiveGuidanceLines = switch ($PromptKind) {
            'Menu' { @('Choose the option that fits your setup.', 'You can return to earlier setup steps at any time.') }
            'Text' { @('Enter the requested value. Leave it blank to accept the shown default when one is available.') }
            'YesNo' { @('Choose Yes or No. The highlighted choice is the default.') }
            'Secret' { @('Input is masked while typing and is never included in setup summaries.') }
        }
    }

    $script:SetupWebPendingGuidance = [pscustomobject]@{
        Header  = $PromptText
        Lines   = $effectiveGuidanceLines
        HelpUrl = $helpUrl
    }
    $script:SetupGuidancePanelVisible = $true
}

function Read-SetupWebMenu {
    <#
    .SYNOPSIS
        Browser replacement for Select-FromMenu.
    .DESCRIPTION
        Renders choices as cards with action and dim styling preserved. Even a single
        item stays a menu choice; callers that need a yes/no answer use Read-YesNo.
        Back unwinds to the wizard; Cancel stops a root prompt. Returns the zero-based
        item index, or null for no items.
    .PARAMETER Title
        Prompt heading.
    .PARAMETER Items
        Choice labels.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'The browser menu returns an item index or null; the analyzer infers the null path as a dictionary.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Items,
        [Parameter()][string[]]$PromptGuidanceLines,
        [Parameter()][string]$PromptGuidanceDocRelativePath,
        [Parameter()][string]$PromptGuidanceRef,
        [Parameter()][switch]$ShowProductBrand,
        [Parameter()][switch]$PreserveExistingContent,
        [Parameter()][switch]$SkipPromptGuidance,
        [Parameter()][string[]]$ActionItems = @(),
        [Parameter()][string]$ActionSectionTitle = '---',
        [Parameter()][switch]$ActionSectionFirst,
        [Parameter()][string[]]$DimItems = @(),
        [Parameter()][System.Collections.IDictionary]$ItemStyles
    )

    if ($Items.Count -eq 0) {
        return $null
    }

    $null = $ItemStyles
    $navigation = Get-SetupWebPromptNavigation
    Write-SetupWebPromptFrame `
        -PromptText $Title `
        -PromptKind 'Menu' `
        -PromptGuidanceLines $PromptGuidanceLines `
        -PromptGuidanceDocRelativePath $PromptGuidanceDocRelativePath `
        -PromptGuidanceRef $PromptGuidanceRef `
        -ShowProductBrand:$ShowProductBrand `
        -PreserveExistingContent:$PreserveExistingContent `
        -SkipPromptGuidance:$SkipPromptGuidance

    $displayItems = @(
        foreach ($item in $Items) {
            $isActionItem = $ActionItems -contains $item
            [ordered]@{
                label   = [string]$item
                action  = $isActionItem
                dimmed  = ($DimItems -contains $item)
            }
        }
    )

    $prompt = Get-SetupWebPromptBase -Kind 'menu' -Title $Title -AllowBack:$navigation.AllowBack -CancelLabel $navigation.CancelLabel
    $prompt['items'] = @($displayItems)
    $prompt['actionFirst'] = [bool]$ActionSectionFirst
    $prompt['actionSectionTitle'] = $ActionSectionTitle
    $promptId = Publish-SetupWebPrompt -Prompt $prompt

    while ($true) {
        $action = Read-SetupWebPromptAction -PromptId $promptId
        switch ([string](Get-OptionalObjectPropertyValue -InputObject $action -PropertyName 'action')) {
            'choose' {
                $selectedIndex = -1
                $selectedValue = Get-OptionalObjectPropertyValue -InputObject $action -PropertyName 'value'
                if ($null -eq $selectedValue -or -not [int]::TryParse([string]$selectedValue, [ref]$selectedIndex) -or
                    $selectedIndex -lt 0 -or $selectedIndex -ge $Items.Count) {
                    return $null
                }

                $selectedLabel = [string]$Items[$selectedIndex]
                Add-SetupWebActivity -Text "Selected: $selectedLabel" -Tone 'muted'
                if ($selectedLabel -eq 'Back' -or $selectedLabel -like '< Back*') {
                    Invoke-SetupWebBackNavigation
                }

                Complete-SetupWebPrompt -Message "Opening $selectedLabel..."
                return $selectedIndex
            }
            'back' { Invoke-SetupWebBackNavigation }
            'cancel' { Invoke-SetupWebCancelNavigation }
        }
    }
}

function Read-SetupWebYesNo {
    <#
    .SYNOPSIS
        Browser replacement for Read-YesNo.
    .DESCRIPTION
        Returns a boolean. Yes is the default unless DefaultNo is set. Back and Cancel
        follow the same wizard navigation contract as the console prompt.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter()][string[]]$PromptGuidanceLines,
        [Parameter()][string]$PromptGuidanceDocRelativePath,
        [Parameter()][string]$PromptGuidanceRef,
        [Parameter()][switch]$DefaultNo
    )

    Write-SetupWebPromptFrame `
        -PromptText $Prompt `
        -PromptKind 'YesNo' `
        -PromptGuidanceLines $PromptGuidanceLines `
        -PromptGuidanceDocRelativePath $PromptGuidanceDocRelativePath `
        -PromptGuidanceRef $PromptGuidanceRef

    $navigation = Get-SetupWebPromptNavigation
    $promptState = Get-SetupWebPromptBase -Kind 'yesno' -Title $Prompt -AllowBack:$navigation.AllowBack -CancelLabel $navigation.CancelLabel
    $promptState['defaultYes'] = (-not $DefaultNo.IsPresent)
    $promptStateId = Publish-SetupWebPrompt -Prompt $promptState

    while ($true) {
        $action = Read-SetupWebPromptAction -PromptId $promptStateId
        switch ([string](Get-OptionalObjectPropertyValue -InputObject $action -PropertyName 'action')) {
            'yes' { Complete-SetupWebPrompt; return $true }
            'no' { Complete-SetupWebPrompt; return $false }
            'back' { Invoke-SetupWebBackNavigation }
            'cancel' { Invoke-SetupWebCancelNavigation }
        }
    }
}

function Read-SetupWebTextWithDefault {
    <#
    .SYNOPSIS
        Browser replacement for Read-TextWithDefault.
    .DESCRIPTION
        Blank input returns a nonblank default, then an allowed empty string, otherwise
        shows a validation message and waits again. Nonblank text is trimmed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter()][string]$DefaultValue,
        [Parameter()][string[]]$PromptGuidanceLines,
        [Parameter()][string]$PromptGuidanceDocRelativePath,
        [Parameter()][string]$PromptGuidanceRef,
        [Parameter()][switch]$AllowEmpty
    )

    $navigation = Get-SetupWebPromptNavigation
    $effectiveDefault = if ([string]::IsNullOrWhiteSpace($DefaultValue)) { $null } else { $DefaultValue }
    $errorMessage = $null

    while ($true) {
        Write-SetupWebPromptFrame `
            -PromptText $Prompt `
            -PromptKind 'Text' `
            -PromptGuidanceLines $PromptGuidanceLines `
            -PromptGuidanceDocRelativePath $PromptGuidanceDocRelativePath `
            -PromptGuidanceRef $PromptGuidanceRef

        $promptState = Get-SetupWebPromptBase -Kind 'text' -Title $Prompt -AllowBack:$navigation.AllowBack -CancelLabel $navigation.CancelLabel
        $promptState['default'] = $effectiveDefault
        $promptState['allowEmpty'] = [bool]$AllowEmpty
        $promptState['valueLabel'] = $Prompt
        if (-not [string]::IsNullOrWhiteSpace($errorMessage)) {
            $promptState['error'] = $errorMessage
        }
        $promptStateId = Publish-SetupWebPrompt -Prompt $promptState

        $submittedValue = $null
        while ($true) {
            $action = Read-SetupWebPromptAction -PromptId $promptStateId
            switch ([string](Get-OptionalObjectPropertyValue -InputObject $action -PropertyName 'action')) {
                'submit' {
                    $submittedValue = [string](Get-OptionalObjectPropertyValue -InputObject $action -PropertyName 'value')
                    break
                }
                'back' { Invoke-SetupWebBackNavigation }
                'cancel' { Invoke-SetupWebCancelNavigation }
            }
            if ($null -ne $submittedValue) {
                break
            }
        }

        if ([string]::IsNullOrWhiteSpace($submittedValue)) {
            if (-not [string]::IsNullOrWhiteSpace($effectiveDefault)) {
                Complete-SetupWebPrompt
                return $effectiveDefault
            }
            if ($AllowEmpty) {
                Complete-SetupWebPrompt
                return ''
            }

            $errorMessage = 'A value is required. Please try again.'
            continue
        }

        Complete-SetupWebPrompt
        return $submittedValue.Trim()
    }
}

function Read-SetupWebSecretText {
    <#
    .SYNOPSIS
        Browser replacement for Read-SecretText.
    .DESCRIPTION
        The value is never published or logged; the prompt only marks the input as
        secret. Nonblank input keeps whitespace. Blank input retries unless AllowEmpty.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter()][string[]]$PromptGuidanceLines,
        [Parameter()][string]$PromptGuidanceDocRelativePath,
        [Parameter()][string]$PromptGuidanceRef,
        [Parameter()][switch]$AllowEmpty
    )

    $navigation = Get-SetupWebPromptNavigation
    $errorMessage = $null

    while ($true) {
        Write-SetupWebPromptFrame `
            -PromptText $Prompt `
            -PromptKind 'Secret' `
            -PromptGuidanceLines $PromptGuidanceLines `
            -PromptGuidanceDocRelativePath $PromptGuidanceDocRelativePath `
            -PromptGuidanceRef $PromptGuidanceRef

        $promptState = Get-SetupWebPromptBase -Kind 'secret' -Title $Prompt -AllowBack:$navigation.AllowBack -CancelLabel $navigation.CancelLabel
        $promptState['allowEmpty'] = [bool]$AllowEmpty
        $promptState['valueLabel'] = $Prompt
        if (-not [string]::IsNullOrWhiteSpace($errorMessage)) {
            $promptState['error'] = $errorMessage
        }
        $promptStateId = Publish-SetupWebPrompt -Prompt $promptState

        $submittedValue = $null
        while ($true) {
            $action = Read-SetupWebPromptAction -PromptId $promptStateId
            switch ([string](Get-OptionalObjectPropertyValue -InputObject $action -PropertyName 'action')) {
                'submit' {
                    $submittedValue = [string](Get-OptionalObjectPropertyValue -InputObject $action -PropertyName 'value')
                    break
                }
                'back' { Invoke-SetupWebBackNavigation }
                'cancel' { Invoke-SetupWebCancelNavigation }
            }
            if ($null -ne $submittedValue) {
                break
            }
        }

        if ([string]::IsNullOrWhiteSpace($submittedValue)) {
            if ($AllowEmpty) {
                Complete-SetupWebPrompt
                return ''
            }

            $errorMessage = 'A value is required. Please try again.'
            continue
        }

        Complete-SetupWebPrompt
        return $submittedValue
    }
}

function Show-SetupWebStatusBar {
    # Browser layout owns prompt hints, so the console status bar is a no-op.
    [CmdletBinding()]
    param(
        [Parameter()][ValidateSet('Menu', 'Text', 'YesNo', 'Secret', 'Diff')][string]$PromptKind = 'Text',
        [Parameter()][switch]$SearchEnabled,
        [Parameter()][string]$StatusDetail
    )

    [void]$PromptKind
    [void]$SearchEnabled
    [void]$StatusDetail
}

function Clear-SetupWebStatusBar {
    # Browser layout owns prompt hints, so clearing the console status bar is a no-op.
    [CmdletBinding()]
    param()
}

function Wait-SetupWebAcknowledgement {
    # Browser replacement for Wait-ForUserAcknowledgement.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [Parameter()][string]$ContinueLabel = 'Continue'
    )

    $navigation = Get-SetupWebPromptNavigation
    $prompt = Get-SetupWebPromptBase -Kind 'notice' -Title $Message -AllowBack:$navigation.AllowBack -CancelLabel $navigation.CancelLabel
    $prompt['continueLabel'] = $ContinueLabel
    $promptId = Publish-SetupWebPrompt -Prompt $prompt

    while ($true) {
        $action = Read-SetupWebPromptAction -PromptId $promptId
        switch ([string](Get-OptionalObjectPropertyValue -InputObject $action -PropertyName 'action')) {
            'continue' { Complete-SetupWebPrompt; return }
            'back' { Invoke-SetupWebBackNavigation }
            'cancel' { Invoke-SetupWebCancelNavigation }
        }
    }
}

function ConvertFrom-SetupWebMarkup {
    # Converts escaped Spectre markup to plain text for the browser log.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return ''
    }

    $markerOpen = [char]1
    $markerClose = [char]2
    $value = $Text.Replace('[[', [string]$markerOpen).Replace(']]', [string]$markerClose)
    $value = [regex]::Replace($value, '\[[a-zA-Z0-9# _/]+\]', '')
    return $value.Replace([string]$markerOpen, '[').Replace([string]$markerClose, ']')
}

function Show-SetupWebActivityOutputPanel {
    <#
    .SYNOPSIS
        Adds captured operation output to the browser activity drawer.
    .PARAMETER Lines
        Spectre markup or plain lines; markup is stripped for display.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Heading,
        [Parameter()][string[]]$Lines,
        [Parameter()][int]$MaxLines = 12
    )

    $effectiveLines = @($Lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { ConvertFrom-SetupWebMarkup -Text $_ })
    if ($effectiveLines.Count -eq 0) {
        Add-SetupWebActivity -Text "$Heading - no additional output." -Tone 'muted'
        return
    }

    if ($effectiveLines.Count -gt $MaxLines) {
        $hiddenCount = $effectiveLines.Count - $MaxLines
        Add-SetupWebActivity -Text "$Heading - $hiddenCount earlier line(s) omitted." -Tone 'muted'
        $effectiveLines = @($effectiveLines[($effectiveLines.Count - $MaxLines)..($effectiveLines.Count - 1)])
    }

    foreach ($line in $effectiveLines) {
        Add-SetupWebActivity -Text $line -Tone 'info'
    }
}

function Write-SetupWebHost {
    <#
    .SYNOPSIS
        Mirrors console output into the browser activity drawer.
    .DESCRIPTION
        Installed as Write-Host only in web mode. The original cmdlet still receives
        every call, so the terminal remains a complete fallback log. No user input or
        secret value is passed through this function by the setup prompts.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)][object[]]$Object,
        [Parameter()][switch]$NoNewline,
        [Parameter()][object]$Separator,
        [Parameter()][ConsoleColor]$ForegroundColor,
        [Parameter()][ConsoleColor]$BackgroundColor
    )

    $null = $NoNewline
    $null = $BackgroundColor
    $separatorText = if ($PSBoundParameters.ContainsKey('Separator') -and $null -ne $Separator) { [string]$Separator } else { ' ' }
    if ($null -ne $Object) {
        $text = (@($Object) | ForEach-Object { [string]$_ }) -join $separatorText
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            $tone = switch ([string]$ForegroundColor) {
                'Red' { 'error' }
                'Yellow' { 'warn' }
                'Green' { 'success' }
                'DarkGray' { 'muted' }
                default { 'info' }
            }
            Add-SetupWebActivity -Text $text -Tone $tone
        }
    }

    Microsoft.PowerShell.Utility\Write-Host @PSBoundParameters
}

function Show-SetupWebMetricCard {
    # Captures Spectre metric cards as a browser metrics block.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][array]$Cards
    )

    $filteredCards = @($Cards | Where-Object { $null -ne $_ })
    if ($filteredCards.Count -eq 0) {
        return
    }

    $metricCards = @(
        foreach ($card in $filteredCards) {
            if ($card -is [System.Collections.IDictionary]) {
                [ordered]@{
                    label  = [string]$card['Label']
                    value  = [string]$card['Value']
                    detail = [string]$card['Detail']
                }
            }
            else {
                [ordered]@{
                    label  = [string]$card.Label
                    value  = [string]$card.Value
                    detail = [string]$card.Detail
                }
            }
        }
    )

    Add-SetupWebContentBlock -Block ([ordered]@{
            type    = 'metrics'
            heading = 'Overview'
            cards   = $metricCards
        })
}

function Show-SetupWebKeyValueSummaryTable {
    # Captures a key/value table for the next prompt or review screen.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Values,
        [Parameter()][string]$Heading = 'Summary'
    )

    $entries = @(
        foreach ($entry in $Values.GetEnumerator()) {
            [ordered]@{
                label = [string]$entry.Key
                value = [string]$entry.Value
            }
        }
    )

    Add-SetupWebContentBlock -Block ([ordered]@{
            type    = 'keyvalue'
            heading = $Heading
            values  = $entries
        })
}

function Show-SetupWebBranchEnvironmentMappingTable {
    # Projects branch state the same way the console table does, without Spectre.
    [CmdletBinding()]
    param(
        [Parameter()][array]$BranchMappings
    )

    $items = @($BranchMappings)
    if ($items.Count -eq 0) {
        Add-SetupWebContentBlock -Block ([ordered]@{
                type    = 'table'
                heading = 'Branch environment mappings'
                columns = @('Branch', 'DEV environment', 'Deployment environments', 'BUILD validation')
                rows    = @()
            })
        return
    }

    $rows = @(
        foreach ($mapping in $items) {
            $devEnvironment = Get-BranchSetupDevEnvironment -BranchState $mapping
            $devEnvironmentLabel = '<none>'
            if ($devEnvironment) {
                foreach ($propertyName in @('ShortName', 'FriendlyName', 'Name', 'Url')) {
                    if ($devEnvironment.PSObject.Properties.Name -contains $propertyName -and
                        -not [string]::IsNullOrWhiteSpace([string]$devEnvironment.$propertyName)) {
                        $devEnvironmentLabel = [string]$devEnvironment.$propertyName
                        break
                    }
                }
            }

            $environmentNames = @($mapping.Environments | ForEach-Object {
                    if ($null -eq $_) { return }
                    if ($_.PSObject.Properties.Name -contains 'ShortName' -and -not [string]::IsNullOrWhiteSpace([string]$_.ShortName)) {
                        [string]$_.ShortName
                    }
                    else {
                        [string]$_.FriendlyName
                    }
                } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

            $buildValidationLabel = 'Disabled'
            if ($mapping.PSObject.Properties.Name -contains 'BuildValidationEnabled' -and $mapping.BuildValidationEnabled) {
                $buildValidationLabel = [string]$mapping.BuildValidationEnvironmentName
                if ([string]::IsNullOrWhiteSpace($buildValidationLabel)) {
                    $buildValidationLabel = 'Enabled'
                }
                if ($mapping.PSObject.Properties.Name -contains 'BuildValidationBaselineRelease' -and
                    -not [string]::IsNullOrWhiteSpace([string]$mapping.BuildValidationBaselineRelease)) {
                    $buildValidationLabel += " (baseline: $([string]$mapping.BuildValidationBaselineRelease))"
                }
            }

            , @(
                [string]$mapping.BranchName
                $devEnvironmentLabel
                $(if ($environmentNames.Count -gt 0) { $environmentNames -join ', ' } else { '<none>' })
                $buildValidationLabel
            )
        }
    )

    Add-SetupWebContentBlock -Block ([ordered]@{
            type    = 'table'
            heading = 'Branch environment mappings'
            columns = @('Branch', 'DEV environment', 'Deployment environments', 'BUILD validation')
            rows    = $rows
        })
}

function Show-SetupWebEnvironmentConfigurationTable {
    # Captures the environment plan as a browser table without credential secrets.
    [CmdletBinding()]
    param(
        [Parameter()][array]$EnvironmentConfigurations
    )

    $items = @($EnvironmentConfigurations)
    if ($items.Count -eq 0) {
        Add-SetupWebContentBlock -Block ([ordered]@{
                type    = 'table'
                heading = 'Environment plan'
                columns = @('Short name', 'Friendly name', 'Dataverse URL', 'Credential', 'Service account')
                rows    = @()
            })
        return
    }

    $rows = @(
        foreach ($environment in $items) {
            $serviceAccount = if ($environment.PSObject.Properties.Name -contains 'ServiceAccountUPN') { [string]$environment.ServiceAccountUPN } else { '' }
            , @(
                [string]$environment.ShortName
                [string]$environment.FriendlyName
                [string]$environment.Url
                (Get-CredentialSummaryText -Credentials $environment.Credentials)
                $serviceAccount
            )
        }
    )

    Add-SetupWebContentBlock -Block ([ordered]@{
            type    = 'table'
            heading = 'Environment plan'
            columns = @('Short name', 'Friendly name', 'Dataverse URL', 'Credential', 'Service account')
            rows    = $rows
        })
}

function Show-SetupWebFilePreview {
    # Captures generated file content as a browser file block.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )

    Add-SetupWebContentBlock -Block ([ordered]@{
            type    = 'file'
            heading = $Path
            path    = $Path
            content = $Content.TrimEnd("`r", "`n")
        })
}

function Get-SetupWebWizardStepView {
    <#
    .SYNOPSIS
        Projects one setup wizard step into the browser card model.
    .DESCRIPTION
        Evaluates summaries and sub-item script blocks exactly when the board renders.
        Unavailable steps stay clickable so the wizard can explain the prerequisite
        instead of hiding the reason.
    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][object]$Step,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][bool]$Complete,
        [Parameter(Mandatory)][bool]$Locked,
        [Parameter(Mandatory)][int]$FurthestStepIndex,
        [Parameter(Mandatory)][bool]$RequireSequentialSteps,
        [Parameter(Mandatory)][int]$CurrentStepIndex
    )

    $properties = @($Step.PSObject.Properties.Name)
    $lockedAfterCompletion = (
        $properties -contains 'LockAfterCompletion' -and
        [bool]$Step.LockAfterCompletion -and
        $Complete
    )
    $isBlocked = $RequireSequentialSteps -and $Index -gt ($FurthestStepIndex + 1)
    $isLocked = $Locked -or $lockedAfterCompletion
    $isAvailable = -not $isLocked -and -not $isBlocked

    $subItems = @()
    if ($properties -contains 'SubItems') {
        $subItemsValue = $Step.SubItems
        if ($subItemsValue -is [scriptblock]) {
            $subItems = @(& $subItemsValue)
        }
        elseif ($null -ne $subItemsValue) {
            $subItems = @($subItemsValue)
        }
    }

    $subItemViews = @()
    for ($subIndex = 0; $subIndex -lt $subItems.Count; $subIndex++) {
        $subItem = $subItems[$subIndex]
        if ($null -eq $subItem) {
            throw "Setup step '$([string]$Step.Name)' returned a null SubItems entry."
        }

        $subProperties = @($subItem.PSObject.Properties.Name)
        if (
            $subProperties -notcontains 'Label' -or
            $subProperties -notcontains 'Depth' -or
            $subProperties -notcontains 'Target'
        ) {
            throw "Setup step '$([string]$Step.Name)' SubItems must have Label, Depth, and Target properties."
        }

        $subLabel = [string]$subItem.Label
        $subDepth = [int]$subItem.Depth
        if ([string]::IsNullOrWhiteSpace($subLabel) -or $subDepth -lt 1 -or $null -eq $subItem.Target) {
            throw "Setup step '$([string]$Step.Name)' returned an invalid SubItems entry."
        }

        $entryId = '{0}:{1}' -f $Index, $subIndex
        if ($null -eq (Get-Variable -Name 'SetupWebWizardSubItemTargets' -Scope Script -ValueOnly -ErrorAction SilentlyContinue)) {
            $script:SetupWebWizardSubItemTargets = @{}
        }
        $script:SetupWebWizardSubItemTargets[$entryId] = $subItem.Target
        $subItemViews += [ordered]@{
            id    = $entryId
            label = $subLabel
            depth = $subDepth
        }
    }

    $summaryText = $null
    if ($subItemViews.Count -eq 0 -and $properties -contains 'Summary') {
        $summaryValue = $Step.Summary
        if ($summaryValue -is [scriptblock]) {
            $summaryValue = @(& $summaryValue) -join ', '
        }
        elseif ($summaryValue -is [array]) {
            $summaryValue = $summaryValue -join ', '
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$summaryValue)) {
            $summaryText = [string]$summaryValue
        }
    }
    $summaryText = if ([string]::IsNullOrWhiteSpace($summaryText)) {
        if ($subItemViews.Count -gt 0) { '' } elseif ($Complete) { 'Complete' } else { 'Not configured' }
    }
    else {
        ([string]$summaryText -replace '\s+', ' ').Trim()
    }

    $status = if ($isLocked -or $isBlocked) {
        'blocked'
    }
    elseif ($Complete) {
        'complete'
    }
    elseif ($Index -eq $CurrentStepIndex) {
        'active'
    }
    else {
        'pending'
    }
    $statusLabel = if ($isLocked) {
        'Locked'
    }
    elseif ($isBlocked) {
        'Earlier steps first'
    }
    elseif ($Complete) {
        'Complete'
    }
    elseif ($Index -eq $CurrentStepIndex) {
        'Next'
    }
    else {
        'Not started'
    }

    return [ordered]@{
        index       = $Index
        name        = [string]$Step.Name
        summary     = $summaryText
        complete    = $Complete
        active      = ($Index -eq $CurrentStepIndex)
        locked      = $isLocked
        blocked     = $isBlocked
        available   = $isAvailable
        status      = $status
        statusLabel = $statusLabel
        subItems    = @($subItemViews)
    }
}

function Get-SetupWebWizardView {
    <#
    .SYNOPSIS
        Builds the serializable step-board model used by the browser wizard.
    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][array]$Steps,
        [Parameter(Mandatory)][bool[]]$CompletedSteps,
        [Parameter(Mandatory)][bool[]]$LockedSteps,
        [Parameter(Mandatory)][int]$FurthestStepIndex,
        [Parameter(Mandatory)][int]$CurrentStepIndex,
        [Parameter(Mandatory)][bool]$RequireSequentialSteps,
        [Parameter(Mandatory)][bool]$AllStepsCompleted,
        [Parameter()][object[]]$Actions = @(),
        [Parameter()][string]$Notice,
        [Parameter()][ValidateSet('info', 'error')][string]$NoticeTone = 'info'
    )

    $script:SetupWebWizardSubItemTargets = @{}
    $stepViews = @(
        for ($stepIndex = 0; $stepIndex -lt $Steps.Count; $stepIndex++) {
            Get-SetupWebWizardStepView `
                -Step $Steps[$stepIndex] `
                -Index $stepIndex `
                -Complete $CompletedSteps[$stepIndex] `
                -Locked $LockedSteps[$stepIndex] `
                -FurthestStepIndex $FurthestStepIndex `
                -RequireSequentialSteps $RequireSequentialSteps `
                -CurrentStepIndex $CurrentStepIndex
        }
    )

    $completedCount = @($CompletedSteps | Where-Object { $_ }).Count
    $totalCount = $CompletedSteps.Count
    $percent = if ($totalCount -eq 0) { 100 } else { [Math]::Round(100.0 * $completedCount / $totalCount, 1) }

    return [ordered]@{
        title    = $Title
        progress = [ordered]@{
            completed   = $completedCount
            total       = $totalCount
            percent     = $percent
            allComplete = $AllStepsCompleted
        }
        steps    = @($stepViews)
        actions  = @($Actions)
        notice   = $Notice
        noticeTone = $NoticeTone
    }
}

function Write-SetupWebWizardFailure {
    # Turns a step, preview or apply failure into a board notice plus activity details.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Context,
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $detail = "$($ErrorRecord.Exception.GetType().Name): $($ErrorRecord.Exception.Message)"
    $script:SetupWebWizardNotice = "$Context - $detail"
    Add-SetupWebActivity -Text $Context -Tone 'error'
    Add-SetupWebActivity -Text $detail -Tone 'error'
    if ($ErrorRecord.InvocationInfo -and $ErrorRecord.InvocationInfo.PositionMessage) {
        Add-SetupWebActivity -Text $ErrorRecord.InvocationInfo.PositionMessage.Trim() -Tone 'muted'
    }
}

function Write-SetupWebWizardApplyFailure {
    # Keeps the existing apply-failure entry point and wording.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OperationName,
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    Write-SetupWebWizardFailure -Context "Apply failed: $OperationName" -ErrorRecord $ErrorRecord
}

function Invoke-SetupWebWizard {
    <#
    .SYNOPSIS
        Browser replacement for Invoke-SetupWizard.
    .DESCRIPTION
        With ApplyAction, renders a step board of clickable cards instead of a menu.
        Every step remains directly reachable when it is available; locked and blocked
        cards explain their prerequisite in a notice. Completion, input signatures,
        sequential constraints, preview, apply failure recovery, exit confirmation and
        nested return semantics match the console wizard. Without ApplyAction the
        wizard executes steps in order while showing a progress trail, and Back returns
        to the previous step.
    .PARAMETER Steps
        Ordered setup step objects using the same properties as the console wizard.
    .PARAMETER ApplyAction
        Final action after every step completes.
    .PARAMETER ReturnToCaller
        Hides the whole-setup exit action and returns null when the board is cancelled.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][array]$Steps,
        [Parameter()][scriptblock]$PreviewAction,
        [Parameter()][string]$PreviewActionName = 'Preview changes',
        [Parameter()][scriptblock]$ApplyAction,
        [Parameter()][string]$ApplyActionName = 'Apply changes',
        [Parameter()][string]$CancelActionName,
        [Parameter()][scriptblock]$PreApplyAction,
        [Parameter()][switch]$IsNewRepository,
        [Parameter()][switch]$RequireSequentialSteps,
        [Parameter()][switch]$ReturnToCaller,
        [Parameter()][string]$HelpDocRelativePath,
        [Parameter()][string]$HelpRef
    )

    if ($PreviewAction -and -not $ApplyAction) {
        throw 'PreviewAction requires ApplyAction.'
    }
    if ($ReturnToCaller -and -not $ApplyAction) {
        throw 'ReturnToCaller requires ApplyAction.'
    }
    if ($Steps.Count -eq 0 -and -not $ApplyAction) {
        return
    }

    $stepNames = @($Steps | ForEach-Object { [string]$_.Name })
    $requireSequential = $IsNewRepository -or $RequireSequentialSteps
    $script:SetupWebPrompt = $null
    $script:SetupWebBusy = 'Preparing the setup board...'
    Publish-SetupWebState -Force

    if (-not $ApplyAction) {
        $currentStepIndex = 0
        $completedSteps = [bool[]]::new($Steps.Count)
        $lockedSteps = [bool[]]::new($Steps.Count)
        try {
            while ($currentStepIndex -lt $Steps.Count) {
                $stepProperties = @($Steps[$currentStepIndex].PSObject.Properties.Name)
                $stepHelpDoc = $HelpDocRelativePath
                $stepHelpRef = $HelpRef
                if ($stepProperties -contains 'HelpDocRelativePath' -and -not [string]::IsNullOrWhiteSpace([string]$Steps[$currentStepIndex].HelpDocRelativePath)) {
                    $stepHelpDoc = [string]$Steps[$currentStepIndex].HelpDocRelativePath
                }
                if ($stepProperties -contains 'HelpRef' -and -not [string]::IsNullOrWhiteSpace([string]$Steps[$currentStepIndex].HelpRef)) {
                    $stepHelpRef = [string]$Steps[$currentStepIndex].HelpRef
                }

                $furthestStepIndex = [Math]::Min($currentStepIndex, $Steps.Count - 1)
                $actions = @(
                    [ordered]@{ id = 'continue'; label = 'Continue'; kind = 'primary'; enabled = $true; reason = '' }
                )
                $script:SetupWebWizard = Get-SetupWebWizardView `
                    -Title $Title `
                    -Steps $Steps `
                    -CompletedSteps $completedSteps `
                    -LockedSteps $lockedSteps `
                    -FurthestStepIndex $furthestStepIndex `
                    -CurrentStepIndex $currentStepIndex `
                    -RequireSequentialSteps $true `
                    -AllStepsCompleted $false `
                    -Actions $actions
                $script:SetupWebInteractiveVersion = [long]$script:SetupWebInteractiveVersion + 1
                $script:SetupWebPrompt = $null
                $script:SetupWebBusy = "Opening $($stepNames[$currentStepIndex])..."
                Publish-SetupWebState -Force

                Set-SetupWizardContext `
                    -Title $Title `
                    -StepNames $stepNames `
                    -CurrentStepIndex $currentStepIndex `
                    -HelpDocRelativePath $stepHelpDoc `
                    -HelpRef $stepHelpRef
                try {
                    & $Steps[$currentStepIndex].Action | Out-Null
                    $completedSteps[$currentStepIndex] = $true
                    $currentStepIndex++
                }
                catch {
                    if (Test-IsSetupWizardBackException -Exception $_.Exception) {
                        if ($currentStepIndex -gt 0) {
                            $completedSteps[$currentStepIndex - 1] = $false
                            $currentStepIndex--
                            continue
                        }

                        throw ([System.OperationCanceledException]::new('Setup cancelled by user.'))
                    }

                    throw
                }
            }
        }
        finally {
            $script:SetupWebWizard = $null
            Clear-SetupWizardContext
            Publish-SetupWebState -Force
        }
        return
    }

    $menuStepNames = @($stepNames)
    $previewActionIndex = -1
    if ($PreviewAction) {
        $previewActionIndex = $menuStepNames.Count
        $menuStepNames += $PreviewActionName
    }
    $applyActionIndex = $menuStepNames.Count
    $menuStepNames += $ApplyActionName
    $cancelActionIndex = -1
    if (-not [string]::IsNullOrWhiteSpace($CancelActionName)) {
        $cancelActionIndex = $menuStepNames.Count
        $menuStepNames += $CancelActionName
    }
    $exitActionIndex = -1
    if (-not $ReturnToCaller) {
        $exitActionIndex = $menuStepNames.Count
        $menuStepNames += 'Exit without applying changes'
    }

    # Capture the same initial completion and lock state as the console wizard.
    $lockedSteps = [bool[]]::new($Steps.Count)
    $completedSteps = [bool[]]::new($Steps.Count)
    $completedStepSignatures = [object[]]::new($Steps.Count)
    for ($stepIndex = 0; $stepIndex -lt $Steps.Count; $stepIndex++) {
        $stepProperties = @($Steps[$stepIndex].PSObject.Properties.Name)
        $lockedSteps[$stepIndex] = $stepProperties -contains 'IsLocked' -and [bool]$Steps[$stepIndex].IsLocked
        $completedSteps[$stepIndex] = (
            $lockedSteps[$stepIndex] -or
            ($stepProperties -contains 'IsComplete' -and [bool]$Steps[$stepIndex].IsComplete)
        )
        if ($completedSteps[$stepIndex]) {
            $completedStepSignatures[$stepIndex] = Get-SetupWizardStepInputSignature -Step $Steps[$stepIndex]
        }
    }

    $furthestStepIndex = -1
    while (($furthestStepIndex + 1) -lt $Steps.Count -and $completedSteps[$furthestStepIndex + 1]) {
        $furthestStepIndex++
    }

    $notice = $null
    $noticeTone = 'info'
    try {
        while ($true) {
            $allStepsCompleted = -not ($completedSteps -contains $false)
            $nextStepIndex = [Array]::IndexOf($completedSteps, $false)
            $currentStepIndex = if ($allStepsCompleted) { $applyActionIndex } else { $nextStepIndex }

            $actions = @()
            if ($PreviewAction) {
                $actions += [ordered]@{
                    id      = 'preview'
                    label   = $PreviewActionName
                    kind    = 'secondary'
                    enabled = $allStepsCompleted
                    reason  = $(if ($allStepsCompleted) { '' } else { 'Complete every setup step before previewing changes.' })
                }
            }
            $actions += [ordered]@{
                id      = 'apply'
                label   = $ApplyActionName
                kind    = 'primary'
                enabled = $allStepsCompleted
                reason  = $(if ($allStepsCompleted) { '' } else { 'Complete every setup step before applying changes.' })
            }
            if ($cancelActionIndex -ge 0) {
                $actions += [ordered]@{
                    id      = 'cancelAction'
                    label   = $CancelActionName
                    kind    = 'ghost'
                    enabled = $true
                    reason  = ''
                }
            }
            if ($ReturnToCaller) {
                $actions += [ordered]@{
                    id      = 'cancel'
                    label   = 'Back'
                    kind    = 'ghost'
                    enabled = $true
                    reason  = ''
                }
            }
            elseif ($exitActionIndex -ge 0) {
                $actions += [ordered]@{
                    id      = 'exit'
                    label   = 'Exit without applying changes'
                    kind    = 'danger'
                    enabled = $true
                    reason  = ''
                }
            }

            $script:SetupWebWizard = Get-SetupWebWizardView `
                -Title $Title `
                -Steps $Steps `
                -CompletedSteps $completedSteps `
                -LockedSteps $lockedSteps `
                -FurthestStepIndex $furthestStepIndex `
                -CurrentStepIndex $currentStepIndex `
                -RequireSequentialSteps $requireSequential `
                -AllStepsCompleted $allStepsCompleted `
                -Actions @($actions) `
                -Notice $notice `
                -NoticeTone $noticeTone
            $script:SetupWebInteractiveVersion = [long]$script:SetupWebInteractiveVersion + 1
            $script:SetupWebPrompt = $null
            $script:SetupWebBusy = $null
            Set-SetupWizardContext `
                -Title $Title `
                -StepNames $menuStepNames `
                -CurrentStepIndex $currentStepIndex `
                -IsNavigationMenu `
                -HelpDocRelativePath $HelpDocRelativePath `
                -HelpRef $HelpRef
            Publish-SetupWebState -Force
            $notice = $null
            $noticeTone = 'info'
            $script:SetupWebWizardNotice = $null

            $action = Read-SetupWebAction
            if ($null -eq $action) {
                if ($ReturnToCaller) {
                    return $null
                }
                throw 'Setup cancelled before changes were applied.'
            }

            if ([string](Get-OptionalObjectPropertyValue -InputObject $action -PropertyName 'action') -ne 'wizard') {
                continue
            }
            $operation = [string](Get-OptionalObjectPropertyValue -InputObject $action -PropertyName 'operation')

            switch ($operation) {
                'selectStep' {
                    $selectedStepIndex = -1
                    $stepValue = Get-OptionalObjectPropertyValue -InputObject $action -PropertyName 'index'
                    if (-not [int]::TryParse([string]$stepValue, [ref]$selectedStepIndex) -or
                        $selectedStepIndex -lt 0 -or $selectedStepIndex -ge $Steps.Count) {
                        $notice = 'Choose a setup step card to continue.'
                        break
                    }

                    $selectedStepProperties = @($Steps[$selectedStepIndex].PSObject.Properties.Name)
                    $lockedAfterCompletion = (
                        $selectedStepProperties -contains 'LockAfterCompletion' -and
                        [bool]$Steps[$selectedStepIndex].LockAfterCompletion -and
                        $completedSteps[$selectedStepIndex]
                    )
                    if ($lockedSteps[$selectedStepIndex] -or $lockedAfterCompletion) {
                        $notice = 'This setup step is locked because it has already been completed.'
                        break
                    }
                    if ($requireSequential -and $selectedStepIndex -gt ($furthestStepIndex + 1)) {
                        $notice = 'Complete the earlier setup steps before moving forward.'
                        break
                    }

                    $stepHelpDoc = $HelpDocRelativePath
                    $stepHelpRef = $HelpRef
                    if ($selectedStepProperties -contains 'HelpDocRelativePath' -and -not [string]::IsNullOrWhiteSpace([string]$Steps[$selectedStepIndex].HelpDocRelativePath)) {
                        $stepHelpDoc = [string]$Steps[$selectedStepIndex].HelpDocRelativePath
                    }
                    if ($selectedStepProperties -contains 'HelpRef' -and -not [string]::IsNullOrWhiteSpace([string]$Steps[$selectedStepIndex].HelpRef)) {
                        $stepHelpRef = [string]$Steps[$selectedStepIndex].HelpRef
                    }

                    Set-SetupWizardContext `
                        -Title $Title `
                        -StepNames $menuStepNames `
                        -CurrentStepIndex $selectedStepIndex `
                        -HelpDocRelativePath $stepHelpDoc `
                        -HelpRef $stepHelpRef
                    $script:SetupWebPrompt = $null
                    $script:SetupWebBusy = "Opening $($stepNames[$selectedStepIndex])..."
                    Publish-SetupWebState -Force
                    try {
                        & $Steps[$selectedStepIndex].Action | Out-Null
                    }
                    catch {
                        if (Test-IsSetupWizardBackException -Exception $_.Exception) {
                            continue
                        }
                        if ($_.Exception -is [System.OperationCanceledException] -or (Test-IsUserInterruptException -Exception $_.Exception)) {
                            throw
                        }
                        Write-SetupWebWizardFailure -Context "Error in $($stepNames[$selectedStepIndex])" -ErrorRecord $_
                        $notice = [string](Get-Variable -Name 'SetupWebWizardNotice' -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
                        $noticeTone = 'error'
                        continue
                    }

                    $script:SetupWebPrompt = $null
                    $script:SetupWebBusy = 'Updating setup steps...'
                    Publish-SetupWebState -Force
                    $completedSteps[$selectedStepIndex] = $true
                    $completedStepSignatures[$selectedStepIndex] = Get-SetupWizardStepInputSignature -Step $Steps[$selectedStepIndex]
                    for ($laterStepIndex = $selectedStepIndex + 1; $laterStepIndex -lt $Steps.Count; $laterStepIndex++) {
                        if ($lockedSteps[$laterStepIndex]) {
                            continue
                        }

                        $laterStepProperties = @($Steps[$laterStepIndex].PSObject.Properties.Name)
                        if ($laterStepProperties -contains 'InputSignature' -and $completedSteps[$laterStepIndex]) {
                            $currentSignature = Get-SetupWizardStepInputSignature -Step $Steps[$laterStepIndex]
                            if ($currentSignature -ceq [string]$completedStepSignatures[$laterStepIndex]) {
                                continue
                            }
                        }

                        $completedSteps[$laterStepIndex] = $false
                        $completedStepSignatures[$laterStepIndex] = $null
                    }

                    $furthestStepIndex = -1
                    while (($furthestStepIndex + 1) -lt $Steps.Count -and $completedSteps[$furthestStepIndex + 1]) {
                        $furthestStepIndex++
                    }
                }
                'selectEntry' {
                    $entryId = [string](Get-OptionalObjectPropertyValue -InputObject $action -PropertyName 'entryId')
                    $targets = Get-Variable -Name 'SetupWebWizardSubItemTargets' -Scope Script -ValueOnly -ErrorAction SilentlyContinue
                    if ([string]::IsNullOrWhiteSpace($entryId) -or $null -eq $targets -or -not $targets.ContainsKey($entryId)) {
                        $notice = 'That branch or environment is no longer available.'
                        break
                    }

                    $selectedStepIndex = -1
                    $stepValue = Get-OptionalObjectPropertyValue -InputObject $action -PropertyName 'index'
                    if (-not [int]::TryParse([string]$stepValue, [ref]$selectedStepIndex) -or
                        $selectedStepIndex -lt 0 -or $selectedStepIndex -ge $Steps.Count) {
                        $notice = 'Choose a setup step card to continue.'
                        break
                    }
                    if ($requireSequential -and $selectedStepIndex -gt ($furthestStepIndex + 1)) {
                        $notice = 'Complete the earlier setup steps before moving forward.'
                        break
                    }

                    $selectedStepProperties = @($Steps[$selectedStepIndex].PSObject.Properties.Name)
                    $stepHelpDoc = $HelpDocRelativePath
                    $stepHelpRef = $HelpRef
                    if ($selectedStepProperties -contains 'HelpDocRelativePath' -and -not [string]::IsNullOrWhiteSpace([string]$Steps[$selectedStepIndex].HelpDocRelativePath)) {
                        $stepHelpDoc = [string]$Steps[$selectedStepIndex].HelpDocRelativePath
                    }
                    if ($selectedStepProperties -contains 'HelpRef' -and -not [string]::IsNullOrWhiteSpace([string]$Steps[$selectedStepIndex].HelpRef)) {
                        $stepHelpRef = [string]$Steps[$selectedStepIndex].HelpRef
                    }

                    Set-SetupWizardContext `
                        -Title $Title `
                        -StepNames $menuStepNames `
                        -CurrentStepIndex $selectedStepIndex `
                        -HelpDocRelativePath $stepHelpDoc `
                        -HelpRef $stepHelpRef
                    $script:SetupWebPrompt = $null
                    $script:SetupWebBusy = "Opening $($stepNames[$selectedStepIndex])..."
                    Publish-SetupWebState -Force
                    try {
                        & $Steps[$selectedStepIndex].Action $targets[$entryId] | Out-Null
                    }
                    catch {
                        if (Test-IsSetupWizardBackException -Exception $_.Exception) {
                            continue
                        }
                        if ($_.Exception -is [System.OperationCanceledException] -or (Test-IsUserInterruptException -Exception $_.Exception)) {
                            throw
                        }
                        Write-SetupWebWizardFailure -Context "Error in $($stepNames[$selectedStepIndex])" -ErrorRecord $_
                        $notice = [string](Get-Variable -Name 'SetupWebWizardNotice' -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
                        $noticeTone = 'error'
                        continue
                    }

                    $script:SetupWebPrompt = $null
                    $script:SetupWebBusy = 'Updating setup steps...'
                    Publish-SetupWebState -Force
                    $completedSteps[$selectedStepIndex] = $true
                    $completedStepSignatures[$selectedStepIndex] = Get-SetupWizardStepInputSignature -Step $Steps[$selectedStepIndex]
                    for ($laterStepIndex = $selectedStepIndex + 1; $laterStepIndex -lt $Steps.Count; $laterStepIndex++) {
                        if ($lockedSteps[$laterStepIndex]) {
                            continue
                        }

                        $laterStepProperties = @($Steps[$laterStepIndex].PSObject.Properties.Name)
                        if ($laterStepProperties -contains 'InputSignature' -and $completedSteps[$laterStepIndex]) {
                            $currentSignature = Get-SetupWizardStepInputSignature -Step $Steps[$laterStepIndex]
                            if ($currentSignature -ceq [string]$completedStepSignatures[$laterStepIndex]) {
                                continue
                            }
                        }

                        $completedSteps[$laterStepIndex] = $false
                        $completedStepSignatures[$laterStepIndex] = $null
                    }

                    $furthestStepIndex = -1
                    while (($furthestStepIndex + 1) -lt $Steps.Count -and $completedSteps[$furthestStepIndex + 1]) {
                        $furthestStepIndex++
                    }
                }
                'preview' {
                    if (-not $allStepsCompleted) {
                        $notice = 'Complete every setup step before previewing changes.'
                        break
                    }

                    Set-SetupWizardContext `
                        -Title $Title `
                        -StepNames $menuStepNames `
                        -CurrentStepIndex $previewActionIndex `
                        -HelpDocRelativePath $HelpDocRelativePath `
                        -HelpRef $HelpRef
                    $script:SetupWebPrompt = $null
                    $script:SetupWebBusy = 'Preparing the change preview...'
                    Publish-SetupWebState -Force
                    try {
                        & $PreviewAction | Out-Null
                    }
                    catch {
                        if (Test-IsSetupWizardBackException -Exception $_.Exception) {
                            continue
                        }
                        if ($_.Exception -is [System.OperationCanceledException] -or (Test-IsUserInterruptException -Exception $_.Exception)) {
                            throw
                        }
                        Write-SetupWebWizardFailure -Context "Preview failed" -ErrorRecord $_
                        $notice = [string](Get-Variable -Name 'SetupWebWizardNotice' -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
                        $noticeTone = 'error'
                        continue
                    }
                }
                'apply' {
                    if (-not $allStepsCompleted) {
                        $notice = 'Complete every setup step before applying changes.'
                        break
                    }

                    Set-SetupWizardContext `
                        -Title $Title `
                        -StepNames $menuStepNames `
                        -CurrentStepIndex $applyActionIndex `
                        -HelpDocRelativePath $HelpDocRelativePath `
                        -HelpRef $HelpRef
                    $script:SetupWebPrompt = $null
                    $script:SetupWebBusy = "Applying $ApplyActionName..."
                    Publish-SetupWebState -Force
                    try {
                        if ($PreApplyAction) {
                            & $PreApplyAction
                        }
                        return (& $ApplyAction)
                    }
                    catch {
                        if (Test-IsSetupWizardBackException -Exception $_.Exception) {
                            continue
                        }
                        if (Test-IsUserInterruptException -Exception $_.Exception) {
                            throw
                        }

                        Write-SetupWebWizardApplyFailure -OperationName $ApplyActionName -ErrorRecord $_
                        $notice = [string](Get-Variable -Name 'SetupWebWizardNotice' -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
                        $noticeTone = 'error'
                        continue
                    }
                }
                'cancelAction' {
                    return $null
                }
                'cancel' {
                    if ($ReturnToCaller) {
                        return $null
                    }
                    throw 'Setup cancelled before changes were applied.'
                }
                'exit' {
                    Set-SetupWizardContext `
                        -Title $Title `
                        -StepNames $menuStepNames `
                        -CurrentStepIndex $exitActionIndex `
                        -HelpDocRelativePath $HelpDocRelativePath `
                        -HelpRef $HelpRef
                    try {
                        $exitWithoutApplying = Read-SetupWebYesNo `
                            -Prompt 'Exit setup without applying changes?' `
                            -PromptGuidanceLines @(
                                'Your current setup selections will not be applied.',
                                'Resources created during earlier setup prerequisites are not rolled back.'
                            ) `
                            -DefaultNo
                    }
                    catch {
                        if (Test-IsSetupWizardBackException -Exception $_.Exception) {
                            continue
                        }
                        throw
                    }

                    if ($exitWithoutApplying) {
                        throw 'Setup exited without applying changes.'
                    }
                }
                default {
                    $notice = 'Choose a setup step or action card to continue.'
                }
            }
        }
    }
    finally {
        $script:SetupWebWizard = $null
        Clear-SetupWizardContext
        Publish-SetupWebState -Force
    }
}

function Show-SetupWebFileChangeSummary {
    # Captures the repository file status list for the browser review screen.
    [CmdletBinding()]
    param(
        [Parameter()][AllowEmptyCollection()][object[]]$FileChanges = @()
    )

    $files = @(
        foreach ($change in @($FileChanges | Sort-Object Path -CaseSensitive)) {
            [ordered]@{
                path   = [string]$change.Path
                status = [string]$change.Status
            }
        }
    )

    Add-SetupWebContentBlock -Block ([ordered]@{
            type    = 'files'
            heading = 'Repository files'
            files   = $files
        })
}

function Show-SetupWebResourceChangeSummary {
    # Captures the deferred external-resource plan; secrets must never be included.
    [CmdletBinding()]
    param(
        [Parameter()][AllowEmptyCollection()][object[]]$ResourceChanges = @(),
        [Parameter()][string]$Note = 'Resources already provisioned earlier to support setup are excluded.'
    )

    $items = @()
    for ($index = 0; $index -lt $ResourceChanges.Count; $index++) {
        $change = $ResourceChanges[$index]
        foreach ($propertyName in @('Action', 'Resource', 'Target')) {
            if ($change.PSObject.Properties.Name -notcontains $propertyName -or [string]::IsNullOrWhiteSpace([string]$change.$propertyName)) {
                throw "Resource change at index $index is missing required '$propertyName' text."
            }
        }

        $items += [ordered]@{
            action  = [string]$change.Action
            resource = [string]$change.Resource
            target  = [string]$change.Target
            details = [string](Get-OptionalObjectPropertyValue -InputObject $change -PropertyName 'Details')
        }
    }

    Add-SetupWebContentBlock -Block ([ordered]@{
            type    = 'resources'
            heading = 'Deferred external resource changes'
            items   = $items
            note    = $Note
        })
}

function Show-SetupWebSideBySideDiff {
    <#
    .SYNOPSIS
        Renders a before/after file comparison in the browser.
    .DESCRIPTION
        Displays one file and waits for the close action. Rows use the same pairing
        helper as the console viewer. NoPaging is accepted for caller compatibility;
        the browser scrolls instead of paging.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'NoPaging', Justification = 'Compatibility parameter retained; the browser viewer always shows the complete file.')]
    [CmdletBinding()]
    param(
        [Parameter()][AllowEmptyCollection()][object[]]$FileChanges = @(),
        [Parameter()][string]$Title = 'Repository file changes',
        [Parameter()][switch]$NoPaging
    )

    if ($FileChanges.Count -gt 1) {
        throw 'The side-by-side diff viewer displays one file at a time.'
    }
    if ($FileChanges.Count -eq 0) {
        Add-SetupWebActivity -Text 'No file changes to display.' -Tone 'muted'
        return
    }

    $change = $FileChanges[0]
    $diffRows = @(Get-SetupSideBySideDiffRow -BeforeContent $change.BeforeContent -AfterContent $change.AfterContent)
    $hasTextChanges = @($diffRows | Where-Object { $_.Type -ne 'Context' }).Count -gt 0
    if (-not $hasTextChanges) {
        $noticeText = if ($change.Status -eq 'Modified') {
            'Text is unchanged; only file encoding or line endings differ.'
        }
        else {
            '(empty file)'
        }
        $diffRows = @([pscustomobject]@{
                Type      = 'Notice'
                LeftText  = if ($change.Status -eq 'Deleted') { $noticeText } else { '' }
                RightText = if ($change.Status -eq 'Deleted') { '' } else { $noticeText }
            })
    }

    $rows = @(
        foreach ($diffRow in $diffRows) {
            [ordered]@{
                type = [string]$diffRow.Type
                left = [string]$diffRow.LeftText
                right = [string]$diffRow.RightText
            }
        }
    )

    $prompt = Get-SetupWebPromptBase -Kind 'diff' -Title $Title
    $prompt['file'] = [ordered]@{
        path   = [string]$change.Path
        status = [string]$change.Status
    }
    $prompt['rows'] = $rows
    $prompt['summary'] = if ($hasTextChanges) {
        "$(@($diffRows | Where-Object { $_.Type -in @('Added', 'Modified') }).Count) added or changed line(s), $(@($diffRows | Where-Object { $_.Type -in @('Deleted', 'Modified') }).Count) removed or changed line(s)."
    }
    else {
        ''
    }
    $promptId = Publish-SetupWebPrompt -Prompt $prompt

    while ($true) {
        $action = Read-SetupWebPromptAction -PromptId $promptId
        switch ([string](Get-OptionalObjectPropertyValue -InputObject $action -PropertyName 'action')) {
            'diff' { Complete-SetupWebPrompt; return }
            'back' { Complete-SetupWebPrompt; return }
            'cancel' { Invoke-SetupWebCancelNavigation }
        }
    }
}

function Show-SetupWebChangeReview {
    <#
    .SYNOPSIS
        Browser replacement for Show-SetupChangeReview.
    .DESCRIPTION
        Captures the summary action's tables and the resource and file plans, then
        renders a single review surface. Selecting a file opens its diff; Done returns.
        SkipReview prints no interactive surface, matching unattended output.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowEmptyCollection()][object[]]$FileChanges = @(),
        [Parameter()][AllowEmptyCollection()][object[]]$ResourceChanges = @(),
        [Parameter()][string]$ResourceChangeNote = 'Resources already provisioned earlier to support setup are excluded.',
        [Parameter(Mandatory)][scriptblock]$SummaryAction,
        [Parameter()][switch]$PreviewOnly,
        [Parameter()][switch]$SkipReview
    )

    $capture = [System.Collections.Generic.List[object]]::new()
    $previousCapture = Get-Variable -Name 'SetupWebCaptureBlocks' -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    $script:SetupWebCaptureBlocks = $capture
    try {
        & $SummaryAction
        Show-SetupWebResourceChangeSummary -ResourceChanges $ResourceChanges -Note $ResourceChangeNote
        Show-SetupWebFileChangeSummary -FileChanges $FileChanges
    }
    finally {
        $script:SetupWebCaptureBlocks = $previousCapture
    }

    $repositoryFileChanges = @($FileChanges | Sort-Object Path -CaseSensitive)
    $fileList = @(
        foreach ($change in $repositoryFileChanges) {
            [ordered]@{
                path   = [string]$change.Path
                status = [string]$change.Status
            }
        }
    )

    if ($SkipReview) {
        Add-SetupWebActivity -Text "Review prepared with $($repositoryFileChanges.Count) repository file change(s)." -Tone 'info'
        return
    }

    $reviewTitle = if ($PreviewOnly) { 'Preview setup changes' } else { 'Review setup changes' }
    while ($true) {
        $prompt = Get-SetupWebPromptBase -Kind 'review' -Title $reviewTitle -Blocks @($capture)
        $prompt['files'] = $fileList
        $prompt['doneLabel'] = if ($PreviewOnly) { 'Done previewing' } else { 'Done reviewing' }
        $promptId = Publish-SetupWebPrompt -Prompt $prompt

        $republish = $false
        while ($true) {
            $action = Read-SetupWebPromptAction -PromptId $promptId
            switch ([string](Get-OptionalObjectPropertyValue -InputObject $action -PropertyName 'action')) {
                'review' {
                    $operation = [string](Get-OptionalObjectPropertyValue -InputObject $action -PropertyName 'operation')
                    if ($operation -eq 'done') {
                        Complete-SetupWebPrompt
                        return
                    }
                    if ($operation -eq 'openFile') {
                        $selectedIndex = -1
                        $fileValue = Get-OptionalObjectPropertyValue -InputObject $action -PropertyName 'index'
                        if ([int]::TryParse([string]$fileValue, [ref]$selectedIndex) -and
                            $selectedIndex -ge 0 -and $selectedIndex -lt $repositoryFileChanges.Count) {
                            Show-SetupWebSideBySideDiff -Title 'Repository file changes' -FileChanges @($repositoryFileChanges[$selectedIndex])
                            $republish = $true
                            break
                        }
                    }
                }
                'back' { Invoke-SetupWebBackNavigation }
                'cancel' { Invoke-SetupWebCancelNavigation }
            }
            if ($republish) {
                break
            }
        }
    }
}

function Show-SetupWebCompletionScreen {
    <#
    .SYNOPSIS
        Browser replacement for Show-SetupCompletionScreen.
    .DESCRIPTION
        Publishes the completion page with summary values and next-step links. The page
        acknowledges the state so the process can exit after the browser rendered it;
        a missing acknowledgement times out without failing successful setup.
    .PARAMETER NextStepLinks
        URLs as strings, dictionaries or custom objects with Url and optional Label,
        Description or Text.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Heading,
        [Parameter(Mandatory)][string]$AccessLabel,
        [Parameter(Mandatory)][string]$AccessUrl,
        [Parameter()][hashtable]$SummaryValues,
        [Parameter()][array]$NextStepLinks
    )

    $summary = @()
    if ($SummaryValues -and $SummaryValues.Count -gt 0) {
        $summary = @(
            foreach ($entry in $SummaryValues.GetEnumerator()) {
                [ordered]@{
                    label = [string]$entry.Key
                    value = [string]$entry.Value
                }
            }
        )
    }

    $nextSteps = @(
        foreach ($nextStep in @($NextStepLinks)) {
            $nextStepUrl = $null
            $nextStepLabel = $null
            if ($nextStep -is [string]) {
                $nextStepUrl = $nextStep
                $nextStepLabel = $nextStep
            }
            elseif ($nextStep -is [System.Collections.IDictionary]) {
                if ($nextStep.Contains('Url')) { $nextStepUrl = [string]$nextStep['Url'] }
                if ($nextStep.Contains('Label') -and -not [string]::IsNullOrWhiteSpace([string]$nextStep['Label'])) {
                    $nextStepLabel = [string]$nextStep['Label']
                }
                elseif ($nextStep.Contains('Description') -and -not [string]::IsNullOrWhiteSpace([string]$nextStep['Description'])) {
                    $nextStepLabel = [string]$nextStep['Description']
                }
                elseif ($nextStep.Contains('Text') -and -not [string]::IsNullOrWhiteSpace([string]$nextStep['Text'])) {
                    $nextStepLabel = [string]$nextStep['Text']
                }
            }
            elseif ($null -ne $nextStep) {
                $nextStepUrl = [string](Get-OptionalObjectPropertyValue -InputObject $nextStep -PropertyName 'Url')
                foreach ($labelProperty in @('Label', 'Description', 'Text')) {
                    $candidate = [string](Get-OptionalObjectPropertyValue -InputObject $nextStep -PropertyName $labelProperty)
                    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                        $nextStepLabel = $candidate
                        break
                    }
                }
            }

            if ([string]::IsNullOrWhiteSpace($nextStepUrl)) {
                continue
            }
            if ([string]::IsNullOrWhiteSpace($nextStepLabel)) {
                $nextStepLabel = $nextStepUrl
            }

            [ordered]@{
                label = $nextStepLabel
                url   = $nextStepUrl
            }
        }
    )

    $script:SetupWebPendingGuidance = $null
    $script:SetupWebPendingBlocks = @()
    $prompt = Get-SetupWebPromptBase -Kind 'complete' -Title $Heading -Eyebrow 'Setup finished' -Blocks @()
    $prompt['heading'] = $Heading
    $prompt['summary'] = $summary
    $prompt['access'] = [ordered]@{
        label = $AccessLabel
        url   = $AccessUrl
    }
    $prompt['nextSteps'] = $nextSteps
    $script:SetupWebFinished = $true
    $script:SetupWebWizard = $null
    $script:SetupWebPrompt = $prompt
    $script:SetupWebBusy = $null
    $script:SetupWebInteractiveVersion = [long]$script:SetupWebInteractiveVersion + 1
    Add-SetupWebActivity -Text $Heading -Tone 'success'
    Publish-SetupWebState -Force

    $promptId = [string]$prompt['id']
    try {
        [void](Read-SetupWebPromptAction -PromptId $promptId -TimeoutSeconds 60)
    }
    catch [System.OperationCanceledException] {
        Write-Verbose 'The browser did not acknowledge the completion screen before setup exited.'
    }
}

function Show-SetupWebFailure {
    <#
    .SYNOPSIS
        Publishes an unhandled setup failure to the browser before the host closes.
    .DESCRIPTION
        Entrypoint catch blocks use this in web mode so an unexpected exception does
        not leave the last working screen waiting forever. The exception type and
        message appear on the stop page; the full detail and source location are kept
        in the Activity drawer. No-op when browser setup is not active.
    .PARAMETER Title
        Stop-page heading.
    .PARAMETER ErrorRecord
        The unhandled error.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    if ($null -eq (Get-SetupWebHost)) {
        return
    }

    $detail = "$($ErrorRecord.Exception.GetType().Name): $($ErrorRecord.Exception.Message)"
    Add-SetupWebActivity -Text "$Title - $detail" -Tone 'error'
    if ($ErrorRecord.InvocationInfo -and $ErrorRecord.InvocationInfo.PositionMessage) {
        Add-SetupWebActivity -Text $ErrorRecord.InvocationInfo.PositionMessage.Trim() -Tone 'muted'
    }
    Show-SetupWebStopScreen -Title $Title -Message $detail
}

function Show-SetupWebStopScreen {
    <#
    .SYNOPSIS
        Publishes a final browser page when setup stops before completion.
    .PARAMETER Title
        Stop heading.
    .PARAMETER Message
        Explanation shown beneath the heading.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message
    )

    if ($null -eq (Get-SetupWebHost)) {
        return
    }

    $script:SetupWebPendingGuidance = $null
    $script:SetupWebPendingBlocks = @()
    $prompt = Get-SetupWebPromptBase -Kind 'stopped' -Title $Title -Eyebrow 'Setup stopped' -Blocks @()
    $prompt['message'] = $Message
    $script:SetupWebFinished = $true
    $script:SetupWebWizard = $null
    $script:SetupWebPrompt = $prompt
    $script:SetupWebBusy = $null
    $script:SetupWebInteractiveVersion = [long]$script:SetupWebInteractiveVersion + 1
    Add-SetupWebActivity -Text $Title -Tone 'warn'
    Publish-SetupWebState -Force

    try {
        [void](Read-SetupWebPromptAction -PromptId ([string]$prompt['id']) -TimeoutSeconds 10)
    }
    catch [System.OperationCanceledException] {
        Write-Verbose 'The browser did not acknowledge the stopped screen before setup exited.'
    }
}

function Invoke-SetupWebStatus {
    <#
    .SYNOPSIS
        Browser replacement for Invoke-WithSpectreStatus.
    .DESCRIPTION
        Publishes the operation as busy activity, forwards a null status context to the
        callback, and returns the last non-string result. Captured stream records are
        mirrored into the activity drawer. Failures propagate after the busy state is
        cleared; Back and interrupt exceptions are never retried here.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [Parameter()][switch]$CaptureOutputInPanel
    )

    if ($null -eq (Get-SetupWebHost)) {
        return (& $ScriptBlock $null)
    }

    $script:SetupWebBusy = $Status
    $script:SetupWebPrompt = $null
    Add-SetupWebActivity -Text $Status -Tone 'info'
    Publish-SetupWebState -Force

    try {
        if (-not $CaptureOutputInPanel) {
            return (& $ScriptBlock $null)
        }

        $capturedOutput = @(& { & $ScriptBlock $null } 6>&1 5>&1 4>&1 3>&1 2>&1)
        $capturedResult = $null
        foreach ($entry in $capturedOutput) {
            $tone = 'info'
            $text = $null
            if ($entry -is [System.Management.Automation.InformationRecord]) { $text = [string]$entry.MessageData; $tone = 'muted' }
            elseif ($entry -is [System.Management.Automation.WarningRecord]) { $text = [string]$entry.Message; $tone = 'warn' }
            elseif ($entry -is [System.Management.Automation.VerboseRecord]) { $text = [string]$entry.Message; $tone = 'muted' }
            elseif ($entry -is [System.Management.Automation.DebugRecord]) { $text = [string]$entry.Message; $tone = 'muted' }
            elseif ($entry -is [System.Management.Automation.ErrorRecord]) { $text = [string]$entry.ToString(); $tone = 'error' }
            elseif ($entry -is [string]) { $text = $entry; $tone = 'info' }

            if ($null -ne $text) {
                Add-SetupWebActivity -Text (ConvertFrom-SetupWebMarkup -Text $text) -Tone $tone
            }
            else {
                $capturedResult = $entry
            }
        }

        return $capturedResult
    }
    finally {
        $script:SetupWebBusy = $null
        Publish-SetupWebState -Force
    }
}

function Invoke-SetupWebErrorHandling {
    <#
    .SYNOPSIS
        Browser replacement for Invoke-WithErrorHandling.
    .DESCRIPTION
        Displays retry, optional skip and abort choices as a browser error card.
        Back propagates to the wizard. Headless runs rethrow instead of displaying a
        prompt they cannot answer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [Parameter(Mandatory)][string]$OperationName,
        [Parameter()][switch]$AllowSkip,
        [Parameter()][string]$StatusMessage,
        [Parameter()][switch]$CaptureOutputInPanel
    )

    while ($true) {
        try {
            if ([string]::IsNullOrWhiteSpace($StatusMessage)) {
                return (& $ScriptBlock)
            }
            return Invoke-SetupWebStatus -Status $StatusMessage -ScriptBlock $ScriptBlock -CaptureOutputInPanel:$CaptureOutputInPanel
        }
        catch {
            if (Test-IsSetupWizardBackException -Exception $_.Exception) { throw }
            if (Test-IsUserInterruptException -Exception $_.Exception) { throw }

            $headlessMode = Get-Variable -Name 'headlessMode' -Scope Script -ValueOnly -ErrorAction SilentlyContinue
            if ($headlessMode) { throw }

            $details = [System.Collections.Generic.List[string]]::new()
            $details.Add("Error type: $($_.Exception.GetType().Name)")
            $details.Add("Error message: $($_.Exception.Message)")
            $innerException = $_.Exception.InnerException
            while ($null -ne $innerException -and $null -ne $innerException.InnerException) {
                $innerException = $innerException.InnerException
            }
            if ($innerException) {
                $details.Add("Inner error type: $($innerException.GetType().Name)")
                $details.Add("Inner error message: $($innerException.Message)")
                if ($innerException -is [System.Management.Automation.RuntimeException] -and $innerException.ErrorRecord) {
                    if ($innerException.ErrorRecord.InvocationInfo.PositionMessage) {
                        $details.Add("Inner location: $($innerException.ErrorRecord.InvocationInfo.PositionMessage.Trim())")
                    }
                    if ($innerException.ErrorRecord.ScriptStackTrace) {
                        $details.Add("Inner stack trace: $($innerException.ErrorRecord.ScriptStackTrace.Trim())")
                    }
                }
                elseif ($innerException.StackTrace) {
                    $details.Add("Inner stack trace: $($innerException.StackTrace.Trim())")
                }
            }
            if ($_.InvocationInfo.PositionMessage) {
                $details.Add("Location: $($_.InvocationInfo.PositionMessage.Trim())")
            }
            if ($_.ScriptStackTrace) {
                $details.Add("Stack trace: $($_.ScriptStackTrace.Trim())")
            }

            Add-SetupWebActivity -Text "Error in ${OperationName}: $($_.Exception.Message)" -Tone 'error'
            $options = @(
                [ordered]@{ id = 'retry'; label = 'Retry'; kind = 'primary' }
            )
            if ($AllowSkip) {
                $options += [ordered]@{ id = 'skip'; label = 'Skip (Not Recommended)'; kind = 'ghost' }
            }
            $options += [ordered]@{ id = 'abort'; label = 'Abort Setup'; kind = 'danger' }

            $prompt = Get-SetupWebPromptBase -Kind 'error' -Title "Error in $OperationName" -Eyebrow 'Setup error'
            $prompt['message'] = 'Choose how you would like to proceed. Setup selections remain available.'
            $prompt['details'] = @($details)
            $prompt['options'] = $options
            $promptId = Publish-SetupWebPrompt -Prompt $prompt

            $retryOperation = $false
            while ($true) {
                $action = Read-SetupWebPromptAction -PromptId $promptId
                switch ([string](Get-OptionalObjectPropertyValue -InputObject $action -PropertyName 'action')) {
                    'error' {
                        $decision = [string](Get-OptionalObjectPropertyValue -InputObject $action -PropertyName 'value')
                        switch ($decision) {
                            'retry' { $retryOperation = $true }
                            'skip' { Complete-SetupWebPrompt; return $null }
                            'abort' { throw "Setup aborted by user after error in $OperationName." }
                        }
                    }
                    'back' { Invoke-SetupWebBackNavigation }
                    'cancel' { Invoke-SetupWebCancelNavigation }
                }
                if ($retryOperation) {
                    break
                }
            }
            if ($retryOperation) {
                continue
            }
        }
    }
}

function Read-SetupWebDeviceCodeAuthentication {
    <#
    .SYNOPSIS
        Browser replacement for Invoke-SetupDeviceCodeAuthentication.
    .DESCRIPTION
        MSAL invokes the device-code callback on a thread without a PowerShell runspace,
        so the callback is compiled to call the C# host directly. The verification
        message therefore reaches the browser while this thread waits for the token.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Application,
        [Parameter(Mandatory)][string[]]$Scopes
    )

    $webHost = Get-SetupWebHost
    if ($null -eq $webHost) {
        throw 'Device-code sign-in requires the browser setup host.'
    }

    $prompt = Get-SetupWebPromptBase -Kind 'device' -Title 'Sign in to Microsoft' -Eyebrow 'Authentication'
    $prompt['message'] = 'Complete sign-in in your browser. The verification code is shown at the top of this page.'
    [void](Publish-SetupWebPrompt -Prompt $prompt)

    $server = $webHost.Server
    $server.ClearDeviceCode()
    $parameter = [System.Linq.Expressions.Expression]::Parameter([Microsoft.Identity.Client.DeviceCodeResult], 'deviceCodeResult')
    $messageProperty = [System.Linq.Expressions.Expression]::Property($parameter, 'Message')
    $publishMethod = $server.GetType().GetMethod('PublishDeviceCode', [Type[]]@([string]))
    $call = [System.Linq.Expressions.Expression]::Call([System.Linq.Expressions.Expression]::Constant($server), $publishMethod, $messageProperty)
    $body = [System.Linq.Expressions.Expression]::Block(
        $call,
        [System.Linq.Expressions.Expression]::Constant([System.Threading.Tasks.Task]::CompletedTask)
    )
    $lambda = [System.Linq.Expressions.Expression]::Lambda(
        [System.Func[Microsoft.Identity.Client.DeviceCodeResult, System.Threading.Tasks.Task]],
        $body,
        $parameter
    )
    $deviceCodeCallback = [System.Func[Microsoft.Identity.Client.DeviceCodeResult, System.Threading.Tasks.Task]]($lambda.Compile())

    try {
        return $Application.AcquireTokenWithDeviceCode($Scopes, $deviceCodeCallback).ExecuteAsync().GetAwaiter().GetResult()
    }
    finally {
        $server.ClearDeviceCode()
        $script:SetupWebPrompt = $null
        $script:SetupWebBusy = 'Completing sign-in...'
        Publish-SetupWebState -Force
    }
}
